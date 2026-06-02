terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # bucket supplied via -backend-config at init
  backend "s3" {
    key          = "global/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Project   = "circleguard"
    ManagedBy = "terraform"
    Env       = var.environment
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  vpc_name             = "circleguard-vpc"
  cluster_name         = var.cluster_name
  vpc_cidr             = "10.0.0.0/16"
  availability_zones   = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
  tags                 = local.common_tags
}

# ── ECR ───────────────────────────────────────────────────────────────────────

module "ecr" {
  source = "./modules/ecr"

  repository_name = "circleguard"
  max_image_count = 20
  tags            = local.common_tags
}

# ── GitHub Actions OIDC ───────────────────────────────────────────────────────

module "github_oidc" {
  source = "./modules/github-oidc"

  role_name          = "circleguard-gha-role"
  subject_patterns   = var.gha_subject_patterns
  ecr_repository_arn = module.ecr.repository_arn
  tags               = local.common_tags
}

# ── EKS ───────────────────────────────────────────────────────────────────────
# Apply after VPC: terraform apply -target=module.vpc first.

module "eks" {
  source = "./modules/eks-cluster"

  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  subnet_ids          = module.vpc.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_count  = var.node_desired_count
  node_min_count      = var.node_min_count
  node_max_count      = var.node_max_count
  deploy_role_arn     = module.github_oidc.role_arn # EKS access entry for CI deploys
  tags                = local.common_tags
}

# ── Secrets Manager + IRSA for external-secrets-operator ─────────────────────

module "irsa_secrets" {
  source = "./modules/irsa-secrets"

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.common_tags
}
