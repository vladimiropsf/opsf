module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = var.environment
  cidr = var.vpc_cidr

  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets
  azs             = var.availability_zones

  enable_nat_gateway      = true
  single_nat_gateway      = true
  enable_vpn_gateway      = false
  enable_dns_hostnames    = true
  map_public_ip_on_launch = false

  private_subnet_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}