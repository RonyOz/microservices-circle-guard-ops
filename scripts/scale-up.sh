#!/usr/bin/env bash
# scripts/scale-up.sh
# Temporarily scale the EKS managed node group up (e.g. to run dev/stage/production
# namespaces at the same time, or for the demo). Revert with scripts/scale-down.sh.
#
# Usage:
#   ./scripts/scale-up.sh [DESIRED_SIZE]      # default 4
#   DESIRED_SIZE=6 WAIT=false ./scripts/scale-up.sh
#
# Manual scaling does not conflict with Terraform: the node group has
# lifecycle { ignore_changes = [scaling_config[0].desired_size] }.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-circleguard-eks}"
REGION="${AWS_REGION:-us-east-1}"
DESIRED_SIZE="${1:-${DESIRED_SIZE:-4}}"
WAIT="${WAIT:-true}"

if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Cluster $CLUSTER_NAME not found in $REGION." >&2
  exit 1
fi

NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --query 'nodegroups[*]' --output text)

if [[ -z "$NODEGROUPS" ]]; then
  echo "No node groups found in $CLUSTER_NAME." >&2
  exit 1
fi

for ng in $NODEGROUPS; do
  read -r MIN MAX DES < <(aws eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" \
    --query 'nodegroup.scalingConfig.[minSize,maxSize,desiredSize]' --output text)

  echo "[$ng] current: min=$MIN max=$MAX desired=$DES -> target desired=$DESIRED_SIZE"

  NEW_MAX="$MAX"
  if (( DESIRED_SIZE > MAX )); then
    NEW_MAX="$DESIRED_SIZE"
    echo "[$ng] raising max $MAX -> $NEW_MAX to fit desired"
  fi

  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" \
    --scaling-config "minSize=${MIN},maxSize=${NEW_MAX},desiredSize=${DESIRED_SIZE}" >/dev/null

  if [[ "$WAIT" == "true" ]]; then
    echo "[$ng] waiting for node group ACTIVE..."
    aws eks wait nodegroup-active \
      --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION"
  fi
  echo "[$ng] scaled to desired=$DESIRED_SIZE (max=$NEW_MAX)"
done

echo ""
echo "Done. Check nodes: kubectl get nodes"
echo "Revert when finished: ./scripts/scale-down.sh"
