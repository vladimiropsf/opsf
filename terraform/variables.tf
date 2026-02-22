variable "region" {
  type        = string
  description = "AWS region where resources will be deployed"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region format (e.g., us-west-2)."
  }
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., development, staging, production)"

  validation {
    condition     = can(regex("^[a-z]+$", var.environment))
    error_message = "Environment must contain only lowercase letters."
  }
}

variable "aws_profile_name" {
  type        = string
  description = "AWS CLI profile name to use for authentication (set to null in CI)"
  default     = null
}


## Network
variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "private_subnets" {
  type        = list(string)
  description = "List of private subnet CIDR blocks"
  default     = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
}

variable "public_subnets" {
  type        = list(string)
  description = "List of public subnet CIDR blocks"
  default     = ["10.10.101.0/24", "10.10.102.0/24", "10.10.103.0/24"]
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones"
  default     = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

## EKS
variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]*[a-zA-Z0-9]$", var.cluster_name))
    error_message = "Cluster name must start with a letter, contain only alphanumeric characters and hyphens, and not end with a hyphen."
  }
}

variable "admin_iam_user" {
  type        = string
  description = "IAM username to grant EKS cluster admin access"
}

variable "ci_iam_role" {
  type        = string
  description = "IAM role name used by GHA for EKS cluster admin access"
  default     = "github-actions-terraform"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for the EKS cluster"
  default     = "1.35"
}
## Karpenter
variable "karpenter_version" {
  type        = string
  description = "Version of Karpenter to install"
  default     = "1.3.3"
}

## Tags
variable "default_tags" {
  type        = map(string)
  description = "Default tags to apply to all resources"
  default = {
    Terraform   = "true"
    ManagedBy   = "terraform"
  }
}

variable "additional_tags" {
  type        = map(string)
  description = "Additional tags to merge with default tags"
  default     = {}
}