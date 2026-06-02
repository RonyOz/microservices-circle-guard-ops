#!/usr/bin/env bash
# scripts/aws-down.sh
# Teardown counterpart to scripts/aws-up.sh.
# Deletes LoadBalancer Services before `terraform destroy`: their EKS-provisioned ELB/SG
# live in the VPC but not in TF state, so destroy would hit DependencyViolation.
# kubectl delete blocks on the finalizer until the ELB is gone.
set -euo pipefail

cd "$(dirname "$0")/../terraform/aws"

CLUSTER_NAME="${CLUSTER_NAME:-circleguard-eks}"
REGION="${AWS_REGION:-us-east-1}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

echo "==> Removing LoadBalancer Services"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
  kubectl delete svc --all-namespaces \
    --field-selector spec.type=LoadBalancer --ignore-not-found --wait=true || true
else
  echo "    Cluster $CLUSTER_NAME not found — skipping."
fi

echo "==> terraform destroy"
if [[ "$AUTO_APPROVE" == "true" ]]; then
  terraform destroy -input=false -auto-approve
else
  terraform destroy -input=false
fi
