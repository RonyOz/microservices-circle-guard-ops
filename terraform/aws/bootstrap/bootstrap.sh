#!/usr/bin/env bash
# Bootstrap script — run ONCE per AWS account, LOCALLY, with admin credentials.
#
# Solves the chicken-and-egg: GitHub Actions workflows authenticate to AWS by
# assuming the `circleguard-gha-role` IAM role via OIDC — but that role (and the
# S3 state bucket) must already exist before any workflow can run Terraform.
# This script creates exactly that foundation, nothing else:
#
#   1. S3 state bucket            (backend prerequisite for `terraform init`)
#   2. module.github_oidc         (OIDC provider + GHA role; pulls in module.ecr)
#
# Everything else (VPC, EKS, IRSA) is provisioned afterwards by the
# provision-aws.yml workflow via OIDC — no further local Terraform needed.
#
# Locking is S3-native (backend `use_lockfile = true`, Terraform >= 1.10) — no DynamoDB.
set -euo pipefail

BUCKET="circleguard-tfstate-1779832348"
REGION="us-east-1"
TF_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # terraform/aws/

# ── 1. S3 state bucket ────────────────────────────────────────────────────────
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

# ── 2. Identity layer: OIDC provider + GHA role (+ ECR, its dependency) ────────
cd "$TF_DIR"

if [[ ! -f terraform.tfvars ]]; then
  echo "==> terraform.tfvars not found — creating from example."
  cp terraform.tfvars.example terraform.tfvars
  echo "    !! Edit terraform.tfvars (set gha_subject_patterns to your repo) and re-run."
  exit 1
fi

echo "==> terraform init"
terraform init

echo "==> terraform apply -target=module.github_oidc  (creates ECR + OIDC provider + GHA role)"
terraform apply -target=module.github_oidc -var-file=terraform.tfvars

# ── 3. Hand off to GitHub Actions ─────────────────────────────────────────────
ROLE_ARN="$(terraform output -raw gha_role_arn)"
echo ""
echo "Foundation ready."
echo "  Set this as the AWS_ROLE_ARN secret in BOTH repos (ops + dev):"
echo ""
echo "    $ROLE_ARN"
echo ""
echo "  Then run the rest in CI (no more local Terraform needed):"
echo "    provision-aws.yml (apply)  -> VPC + EKS + IRSA"
echo "    bootstrap-eso.yml          -> External Secrets Operator + ClusterSecretStore"
echo "    deploy-data-plane.yml      -> backing services per namespace"
echo "    deploy-{dev,stage,prod}.yml-> application services"
echo ""
echo "  NOTE: provision-aws.yml 'destroy' is a FULL teardown (incl. this GHA role)."
echo "  The S3 state bucket survives. To re-provision afterwards, re-run this"
echo "  bootstrap.sh locally first (it recreates the role CI logs in with)."
