#!/usr/bin/env bash
# scripts/aws-up.sh
# Provision the AWS infra (terraform apply). Prerequisite: scripts/init-s3-backend.sh.
# Teardown: scripts/aws-down.sh.
set -euo pipefail

cd "$(dirname "$0")/../terraform/aws"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AUTO_APPROVE="${AUTO_APPROVE:-false}"

if [[ ! -d .terraform ]]; then
  terraform init -input=false -backend-config="bucket=circleguard-tfstate-${ACCOUNT_ID}"
fi

if [[ "$AUTO_APPROVE" == "true" ]]; then
  terraform apply -input=false -auto-approve
else
  terraform apply -input=false
fi

echo ""
echo "gha_role_arn:"
terraform output -raw gha_role_arn 2>/dev/null && echo "" || true
