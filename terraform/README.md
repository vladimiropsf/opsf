# EKS Cluster with Karpenter

Terraform configuration that deploys an EKS cluster into a dedicated VPC with Karpenter for node autoscaling. Supports both x86 and ARM64 (Graviton) architectures using spot instances for cost optimization.

## What Gets Deployed

- VPC with public/private subnets across 3 availability zones
- EKS cluster with a managed node group (2x `t3.small`) for system workloads
- Karpenter with two spot node pools - one for x86, one for ARM64 (Graviton)
- IAM roles, security groups, and SQS queue for spot interruption handling
- EKS add-ons: VPC CNI (`before_compute`), kube-proxy (`before_compute`), CoreDNS, EKS Pod Identity Agent (`before_compute`)

## Prerequisites

```bash
brew install terraform awscli kubectl helm
```

- Terraform >= 1.8
- AWS CLI with configured credentials
- kubectl
- Helm

## Multi-Environment Setup

Each environment (dev, staging, prod) has its own `.tfvars` and `.backend` files under `environments/`:

```
terraform/
  environments/
    development.tfvars     # Dev variable values
    development.backend    # Dev state location
    staging.tfvars
    staging.backend
    production.tfvars
    production.backend
```

Each environment uses a separate VPC CIDR range and its own Terraform state file to keep them fully isolated.

## Deployment

### 0. Bootstrap the S3 state bucket (one-time)

Before using remote state, create the S3 bucket:

```bash
cd terraform/bootstrap/
terraform init
terraform plan -var-file=environments/<environment>.tfvars
terraform apply -var-file=environments/<environment>.tfvars
```

This uses local state intentionally - the bucket must exist before it can be used as a backend. After this, update the bucket name in your `environments/*.backend` files.

### 1. Initialize for a specific environment

Update the bucket name in `environments/<env>.backend`, then:

```bash
cd terraform/
terraform init -backend-config=environments/development.backend
```

To switch environments, re-init with `-reconfigure`:

```bash
terraform init -backend-config=environments/staging.backend -reconfigure
```

For local state (no S3), just run `terraform init` without `-backend-config`.

### 2. Plan and apply

```bash
terraform plan -var-file=environments/development.tfvars
terraform apply -var-file=environments/development.tfvars
```

This takes around 15-20 minutes.

### 3. Configure kubectl

```bash
aws eks update-kubeconfig --region us-west-2 --name eks-dev
kubectl get nodes
```

You should see 2 nodes in `Ready` state.

## Running Workloads on x86 vs Graviton

Karpenter watches for pending pods and provisions the right node type based on scheduling constraints. To target a specific architecture, use `nodeSelector` and tolerations.

### Deploy on x86 (amd64)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: x86-spot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: x86-spot
  template:
    metadata:
      labels:
        app: x86-spot
    spec:
      nodeSelector:
        node-type: spot-x86
      tolerations:
        - key: karpenter.sh/spot
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
```

### Deploy on ARM64 (Graviton)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: arm64-spot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: arm64-spot
  template:
    metadata:
      labels:
        app: arm64-spot
    spec:
      nodeSelector:
        node-type: spot-arm64
      tolerations:
        - key: karpenter.sh/spot
          operator: Exists
          effect: NoSchedule
        - key: kubernetes.io/arch
          value: arm64
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
```

Full example manifests are available in the `manifests/` directory.

### Verify node provisioning

```bash
# Apply a test deployment
kubectl apply -f manifests/x86-spot.yaml

# Watch Karpenter provision a node
kubectl logs -f -n karpenter deployment/karpenter

# Check node architecture and capacity type
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type

# Check Karpenter resources
kubectl get nodepools,ec2nodeclasses
```

## Node Pool Configuration

| Pool | Architecture | Capacity | Instance Categories | Sizes |
|------|-------------|----------|---------------------|-------|
| spot-x86 | amd64 | Spot | t | micro, small |
| spot-arm64 | arm64 | Spot | t | micro, small |

The Spot service-linked role is created automatically via Terraform (`aws_iam_service_linked_role.spot`).

Both pools use only `t`-family instances in `micro` and `small` sizes. Disruption policy is set to consolidate when empty after 30 seconds.

## Cleanup

```bash
# Remove test workloads first so Karpenter can drain nodes
kubectl delete deploy x86-spot arm64-spot

# Destroy all infrastructure for a specific environment
terraform destroy -var-file=environments/development.tfvars
```

## CI/CD

Two GitHub Actions workflows handle deployments:

### Deploy (`.github/workflows/deploy.yml`)

| Trigger | Behavior |
|---------|----------|
| **Manual dispatch** | Choose environment + branch, runs plan then apply with approval gate |

The workflow runs `plan` first, then `apply` as a separate job that requires `plan` to pass. Configure [GitHub environments](https://docs.github.com/en/actions/deployment/targeting-different-environments) (`development`, `staging`, `production`) with protection rules for approval gates.

### Destroy (`.github/workflows/destroy.yml`)

| Trigger | Behavior |
|---------|----------|
| **Manual dispatch** | Choose environment, type the environment name to confirm |

Requires typing the environment name as a safety check before destroying.

### Setup

1. Create an IAM OIDC identity provider for GitHub Actions in your AWS account
2. Create an IAM role with permissions to manage EKS, VPC, IAM, SQS, etc.
3. Add the role ARN as a repository variable named `AWS_ROLE_ARN`
4. Configure [GitHub environments](https://docs.github.com/en/actions/deployment/targeting-different-environments) with protection rules for production

> **Note:** The Spot service-linked role (`aws_iam_service_linked_role.spot`) is created by Terraform. On accounts that already have this role, you may need to import it: `terraform import aws_iam_service_linked_role.spot arn:aws:iam::<account-id>:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot`
