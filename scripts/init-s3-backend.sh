#!/usr/bin/env bash
# scripts/init-s3-backend.sh
#
# Run ONCE per AWS account, LOCALLY with admin credentials, BEFORE `terraform init`.
#
# Creates the S3 bucket that holds Terraform remote state. This is the ONLY piece
# that can't live in Terraform itself — the state bucket can't store the state of
# its own creation (chicken-and-egg). Everything else (VPC, EKS, ECR, OIDC role,
# IRSA, EKS access entry) is created by a normal `terraform apply` in terraform/aws/.
#
# Locking is S3-native (backend `use_lockfile = true`, Terraform >= 1.10) — no DynamoDB.
set -euo pipefail

BUCKET="circleguard-tfstate-1779832348"
REGION="us-east-1"

echo "==> Verifying S3 bucket: $BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "    Already exists — skipping."
else
  echo "    Creating..."
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "    Created and hardened."
fi

echo ""
echo "Backend ready. Provision everything else locally (admin creds):"
echo "  cd terraform/aws"
echo "  cp terraform.tfvars.example terraform.tfvars   # set gha_subject_patterns to your repo"
echo "  terraform init"
echo "  terraform apply -target=module.vpc   # network first"
echo "  terraform apply                      # VPC + ECR + OIDC role + EKS (+ access entry) + IRSA"
echo ""
echo "  Then: set the 'gha_role_arn' output as the AWS_ROLE_ARN secret (ops + dev repos)."
echo "  CI handles the rest: bootstrap-eso -> deploy-data-plane -> deploy-{dev,stage,prod}."
