data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  tags = merge(var.default_tags, var.additional_tags, {
    Name        = var.cluster_name
    Environment = var.environment
  })
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version  = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_private_access      = true

  enable_cluster_creator_admin_permissions = false
  create_cloudwatch_log_group              = false

  access_entries = {
    admin = {
      principal_arn = "arn:aws:iam::${local.account_id}:user/${var.admin_iam_user}"
      policy_associations = {
        cluster_admin = {
          policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope  = { type = "cluster" }
        }
      }
    }
    github_actions = {
      principal_arn = "arn:aws:iam::${local.account_id}:role/${var.ci_iam_role}"
      policy_associations = {
        cluster_admin = {
          policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope  = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    eks-pod-identity-agent = { most_recent = true, before_compute = true }
    vpc-cni                = { most_recent = true, before_compute = true }
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true, before_compute = true }
  }

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.small"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2

      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.tags
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name          = module.eks.cluster_name
  namespace             = "karpenter"
  create_instance_profile = true
  enable_spot_termination = true

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  node_iam_role_additional_policies = {
    AmazonEKSWorkerNodePolicy        = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    AmazonEKS_CNI_Policy             = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    AmazonSSMManagedInstanceCore      = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}