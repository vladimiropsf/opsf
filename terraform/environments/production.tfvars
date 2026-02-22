region           = "us-west-2"
environment      = "production"
cluster_name     = "eks-prod"
cluster_version  = "1.35"

vpc_cidr           = "10.30.0.0/16"
private_subnets    = ["10.30.1.0/24", "10.30.2.0/24", "10.30.3.0/24"]
public_subnets     = ["10.30.101.0/24", "10.30.102.0/24", "10.30.103.0/24"]
availability_zones = ["us-west-2a", "us-west-2b", "us-west-2c"]

karpenter_version = "1.3.3"

admin_iam_user = "dovlica"
ci_iam_role    = "github-actions-terraform"

default_tags = {
  Terraform   = "true"
  ManagedBy   = "terraform"
  Environment = "production"
}
