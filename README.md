# AWS EKS Platform with Karpenter

Infrastructure-as-code and architecture design for deploying a cost-optimized EKS cluster on AWS with Karpenter autoscaling, supporting both x86 and ARM64 (Graviton) spot instances.

## Repository Structure

- **[terraform/](terraform/)** - Terraform code for VPC, EKS cluster, and Karpenter node pools. See [terraform/README.md](terraform/README.md) for deployment instructions and usage guide.
- **[architecture/](architecture/)** - Cloud infrastructure architecture design for Innovate Inc. See [architecture/README.md](architecture/README.md) for the full document.
