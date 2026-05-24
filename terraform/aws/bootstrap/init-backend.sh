#!/usr/bin/env bash
# Bootstrap script — creates S3 + DynamoDB backend resources.
# Run ONCE before `terraform init` in terraform/aws/.
# These resources are managed outside Terraform to avoid bootstrap chicken-and-egg.
set -euo pipefail

BUCKET="circleguard-tfstate"
TABLE="circleguard-tflock"
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

echo "==> Verifying DynamoDB table: $TABLE"
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" &>/dev/null; then
  echo "    Already exists — skipping."
else
  echo "    Creating..."
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  echo "    Created."
fi

echo ""
echo "Backend ready. Run:"
echo "  cd terraform/aws"
echo "  cp terraform.tfvars.example terraform.tfvars"
echo "  terraform init"
echo "  terraform apply -target=module.vpc -target=module.ecr -target=module.github_oidc"
echo "  terraform apply -target=module.eks  # after VPC is up"
echo "  terraform apply                     # full apply"
