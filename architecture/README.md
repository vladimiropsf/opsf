# Innovate Inc. - Cloud Infrastructure Architecture

## Table of Contents

- [Overview](#overview)
- [AWS Account Structure](#aws-account-structure)
- [Network Design](#network-design)
- [Compute - Amazon EKS](#compute--amazon-eks)
- [Database - Aurora PostgreSQL](#database--aurora-postgresql)
- [CI/CD Pipeline (GitOps)](#cicd-pipeline-gitops)
- [Security](#security)
- [Cost Optimization](#cost-optimization)
- [Monitoring & Observability](#monitoring--observability)

---

## Overview

This document covers the proposed AWS infrastructure for Innovate Inc.'s web application - a Flask REST API backend with a React SPA frontend, backed by PostgreSQL

**Key design principles:**

| Principle | How We Apply It |
|-----------|----------------|
| **Scalability** | Karpenter auto-provisions nodes; HPA scales pods; Aurora auto-scales storage |
| **Security** | Network isolation in three tiers; encryption everywhere; least-privilege IAM |
| **Cost efficiency** | Spot instances in non-prod; right-sizing via Karpenter; reserved capacity for prod baseline |
| **Operational simplicity** | GitOps with ArgoCD; IaC with Terraform; managed services where possible |

---

## AWS Account Structure

I recommend a **two-account** setup under AWS Organizations:

| Account | Purpose |
|---------|---------|
| **Production** | Live workloads, strict IAM policies, dedicated billing |
| **Staging / Dev** | Testing and development, mirrors prod config at smaller scale |

**Why two accounts instead of one:**

- **Cost visibility** - separate billing per environment makes spend tracking straightforward
- **Blast radius** - a misconfigured resource in dev can't impact production
- **Compliance** - prod gets stricter controls without slowing down development

**Security baseline applied to both accounts:**

- IAM least-privilege policies scoped per role (developers, operators, CI/CD)
- Automated credential rotation via AWS Secrets Manager
- AWS SSO for centralized identity management across accounts
- CloudTrail enabled for API audit logging in every account
- SCPs (Service Control Policies) at the Organization level to prevent dangerous actions (e.g., disabling CloudTrail, leaving a region boundary)

---

## Network Design

Each account gets its own VPC deployed across **three Availability Zones** for high availability. The VPC is segmented into three tiers to enforce defense in depth.

### Subnet Layout

| Layer | Subnet Type | CIDR Range | What Runs Here | Internet Access |
|-------|------------|------------|----------------|-----------------|
| Public | Public | `10.10.101-103.0/24` | ALB, NAT Gateway | Direct via Internet Gateway |
| Application | Private | `10.10.1-3.0/24` | EKS worker nodes, all app pods | Outbound only via NAT |
| Database | Isolated | (dedicated subnet group) | Aurora PostgreSQL | **None** |

### Network Security Controls

Traffic is locked down layer by layer using Security Groups and NACLs:

- **ALB SG** - inbound 80/443 from the internet only
- **App SG** - inbound only from the ALB security group on application ports
- **DB SG** - inbound 5432 only from the App security group

**Additional network controls:**

- **No public IPs** on any EC2 instances (`map_public_ip_on_launch = false`)
- **VPC Endpoints** (PrivateLink) for AWS services (ECR, S3, STS, CloudWatch) so internal traffic never traverses the public internet
- **NAT Gateway** in public subnets for controlled outbound access from private subnets (external dependencies, OS patching)
- **Flow Logs** enabled on the VPC for network traffic auditing and anomaly detection

> No application workloads run in public subnets. The only public-facing component is the Application Load Balancer.

---

## Compute - Amazon EKS

### Why EKS

Amazon EKS is selected as the compute platform because:

- **Managed control plane** - AWS handles etcd, API server patching, and HA across AZs
- **Karpenter support** - purpose-built for EKS, enabling intelligent node provisioning
- **Compliance** - ISO 27001, HIPAA-eligible, etc. out of the box

### Cluster Setup

EKS runs the latest stable Kubernetes version (currently 1.35) with node groups split by function:

| Node Group | Purpose | Instance Types | Scaling | Workloads |
|-----------|---------|---------------|---------|-----------|
| **System** | Runs Karpenter controller and critical add-ons | `t3.small` (On-Demand) | 2–3 nodes (fixed) | Karpenter, CoreDNS, kube-proxy, VPC CNI |
| **Application** (Karpenter-managed) | Runs user-facing services | Auto-selected by Karpenter | 0–N (dynamic) | Flask API, React SPA |
| **Platform** (Karpenter-managed) | Runs platform tooling | Auto-selected by Karpenter | 0–N (dynamic) | ArgoCD, monitoring, logging |

Separating system nodes from workload nodes ensures Karpenter can always run even when scaling decisions are in flight. Splitting application and platform workloads prevents monitoring tools from competing with user-facing pods during traffic spikes.

### Node Architecture - x86 and ARM64

Karpenter provisions both **x86** and **ARM64 (Graviton)** instances:

| Pool | Architecture | Capacity Type | Instance Category | Use Case |
|------|-------------|---------------|-------------------|----------|
| `spot-x86` | amd64 | Spot | t-family (gen > 3) | Default workloads, broad compatibility |
| `spot-arm64` | arm64 | Spot | t-family (gen > 5) | Cost-optimized workloads (~20% cheaper than x86) |

ARM64 nodes carry a taint (`kubernetes.io/arch=arm64:NoSchedule`) so only workloads with explicit tolerations land there. This lets teams opt into Graviton savings per-service when their container images support it.

### Autoscaling Strategy

**Node-level - Karpenter:**
- Watches for pending pods, then provisions the optimal instance type, size, and purchase option
- Consolidation policy: nodes with no workloads are drained and terminated after 30 seconds
- Spot instance interruption handling via SQS queue for graceful pod migration
- Production environments can use On-Demand instances for baseline capacity with Spot for burst

**Pod-level - Horizontal Pod Autoscaler (HPA):**
- Scales pod replicas based on CPU and memory utilization (target: 70%)
- Frontend: minimum 2 replicas for ALB distribution and basic redundancy
- Backend: minimum 2 replicas for zero-downtime deployments

**Resource Allocation:**
- All pods define CPU and memory `requests` (for scheduling) and `limits` (for protection)
- `LimitRange` and `ResourceQuota` objects enforce per-namespace guardrails to prevent a single team or service from starving others

### Container Strategy

**Multi-stage Docker builds** produce minimal, secure production images:

```dockerfile
# Stage 1 - Build
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

# Stage 2 - Runtime
FROM python:3.12-slim
RUN useradd --create-home appuser
WORKDIR /app
COPY --from=builder /app /app
USER appuser
EXPOSE 5000
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:5000", "app:app"]
```

A typical Flask app builds from a ~1.2GB builder image but ships as a ~150MB runtime image.

**Amazon ECR** for the container registry:
- **Vulnerability scanning** enabled on push (both basic and enhanced scanning via Amazon Inspector)
- **Image signing** with Sigstore/cosign for supply chain integrity
- **Lifecycle policies:** untagged images cleaned daily; dev-prefixed images purged after 14 days
- **Cross-account replication** from Staging/Dev ECR to Production ECR for promoted images

---

## Database - Aurora PostgreSQL

I recommend **Aurora PostgreSQL** over standard RDS PostgreSQL because:

- **Auto-scaling storage** - grows in 10GB increments up to 128TB without manual intervention
- **Performance** - up to 3x throughput compared to standard PostgreSQL via the Aurora storage engine
- **Built-in HA** - six copies of data across three AZs; automatic failover in < 30 seconds
- **Managed patching** - security patches applied automatically during maintenance windows
- **PostgreSQL compatibility** - drop-in replacement; no application code changes required

While Aurora costs ~20% more than standard RDS at low scale, it avoids a painful migration later when Innovate Inc. hits scale. Starting with Aurora means the database layer is ready for millions of users from day one.

### Instance Sizing

| Environment | Instance Class | Storage | Notes |
|------------|---------------|---------|-------|
| Production | `db.r6g.large` (Graviton) | Auto-scaling | Start small, scale vertically as needed |
| Staging/Dev | `db.t4g.medium` (Graviton) | Auto-scaling | Cost-effective for testing |

### Backup, HA, and Disaster Recovery

| Method | RPO | RTO | Retention |
|--------|-----|-----|-----------|
| Continuous backup to S3 | ~5 minutes (point-in-time recovery) | Minutes | 30 days |
| Automated snapshots | Daily | < 1 hour (restore from snapshot) | 35 days |
| Manual snapshots | On-demand (before major changes) | < 1 hour | Indefinite |
| Cross-region read replica | < 1 second replication lag | Minutes (promote replica) | Continuous |

**Disaster recovery strategy:**

- **Regional failure:** Cross-region read replica in a secondary region can be promoted to a standalone writer cluster
- **Data corruption:** Point-in-time recovery (PITR) to any second within the 30-day backup window
- **Schema rollback:** Database migrations versioned in Git; rollback scripts maintained alongside forward migrations

---

## CI/CD Pipeline (GitOps)

The deployment pipeline follows a **GitOps** model - Git is the single source of truth for both application code and cluster state.

### Pipeline Details

| Stage | Tool | What Happens |
|-------|------|-------------|
| **Source** | GitHub | Developer pushes code; PR triggers CI |
| **Build** | GitHub Actions | Unit tests, linting |
| **Containerize** | Docker (multi-stage) | Build minimal production image |
| **Registry** | Amazon ECR | Push image, run vulnerability scan |
| **Promote** | GitHub Actions | Update Helm chart image tag, commit to config repo |
| **Deploy** | ArgoCD | Detects Git change, syncs desired state to cluster |
| **Validate** | Kubernetes probes | Readiness/liveness checks confirm healthy rollout |
| **Rollback** | ArgoCD / `git revert` | Auto-rollback on failed health checks; manual rollback is a Git revert |

Every deployment is tracked in Git. Rollbacks are just a `git revert`. Full audit trail comes for free.

**Environment promotion flow:**
```
Feature branch → Staging (auto-deploy on merge) → Production (manual approval gate)
```

---

## Security

### Defense in Depth - Summary

| Layer | Controls |
|-------|----------|
| **Network** | VPC isolation, security groups, NACLs, VPC endpoints, no public IPs on compute |
| **Identity** | IAM least-privilege, IRSA/Pod Identity, MFA, AWS SSO, SCPs |
| **Data** | TLS 1.3 in transit, KMS encryption at rest, SSL-only DB connections |
| **Application** | Non-root containers, read-only filesystems, Pod Security Standards, OPA/Gatekeeper policies |
| **Supply chain** | ECR vulnerability scanning, image signing, blocked critical CVE deployments |
| **Audit** | CloudTrail, VPC Flow Logs, Kubernetes audit logs, CloudWatch alerts |

### Data Protection

- **TLS 1.3** enforced for all data in transit (ALB terminates TLS, re-encrypts to backend)
- **AWS KMS** customer-managed keys for encryption at rest (EBS volumes, Aurora, S3, ECR)
- **SSL required** for all database connections (`rds.force_ssl = 1`)
- **VPC endpoints** for ECR, S3, STS, and CloudWatch Logs - internal traffic never touches the public internet

### Application Security

- **AWS Secrets Manager** for credentials, API keys, and database passwords with automatic rotation
- **IRSA (IAM Roles for Service Accounts)** - pods assume fine-grained IAM roles instead of sharing node-level permissions
- **ECR image scanning** blocks images with critical CVEs from reaching production

### Kubernetes-Specific Hardening

- EKS API server: private endpoint enabled, public endpoint restricted to known CIDRs
- Kubernetes RBAC: namespace-scoped roles for development teams; cluster-admin limited to platform team
- EKS add-on management: CoreDNS, kube-proxy, VPC CNI managed as EKS add-ons (auto-patched)
- Pod Identity Agent for simplified, secure IAM credential delivery to pods

---

## Cost Optimization

| Strategy | Environment | Expected Savings |
|----------|-------------|-----------------|
| **Spot instances** (via Karpenter) | Dev/Staging | Up to 90% vs On-Demand |
| **Graviton (ARM64) instances** | All | ~20% cheaper than equivalent x86 |
| **Karpenter right-sizing** | All | Matches instance to actual pod requirements - eliminates over-provisioning |
| **Aurora Serverless v2** (future) | Dev/Staging | Scale to zero during off-hours |
| **ECR lifecycle policies** | All | Automatic cleanup of stale images |
| **Reserved capacity / Savings Plans** | Production | 30–40% savings on baseline compute |
| **CloudWatch cost anomaly alerts** | All | Early detection of unexpected spend |

### Monitoring Stack

| Component | Tool | Purpose |
|-----------|------|---------|
| **Infrastructure metrics** | CloudWatch + Container Insights | CPU, memory, disk, network for nodes and pods |
| **Application metrics** | Prometheus + Grafana (in-cluster) | Request latency, error rates, custom business metrics |
| **Logging** | CloudWatch Logs | Centralized log aggregation from all pods and nodes |
| **Tracing** | AWS X-Ray / OpenTelemetry | Distributed request tracing across Flask services |
| **Alerting** | CloudWatch Alarms + SNS | PagerDuty/Slack integration for on-call notifications |

### Dashboards

- **Operations dashboard:** Cluster health, node count, pod status, resource utilization
- **Application dashboard:** Request rate, latency percentiles (p50/p95/p99), error rates by endpoint
- **Cost dashboard:** Daily/weekly spend by service, Spot vs On-Demand breakdown, right-sizing recommendations
