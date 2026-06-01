#!/usr/bin/env bash
# Bootstrap script — creates the S3 backend bucket.
# Run ONCE before `terraform init` in terraform/aws/.
# The bucket is managed outside Terraform to avoid the bootstrap chicken-and-egg.
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
echo "Backend ready. Run:"
echo "  cd terraform/aws"
echo "  cp terraform.tfvars.example terraform.tfvars"
echo "  terraform init"
echo "  terraform apply -target=module.vpc -target=module.ecr -target=module.github_oidc"
echo "  terraform apply -target=module.eks  # after VPC is up"
echo "  terraform apply                     # full apply"
