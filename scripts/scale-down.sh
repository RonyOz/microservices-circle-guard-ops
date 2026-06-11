#!/usr/bin/env bash
# scripts/scale-down.sh
# Return the EKS managed node group to its baseline size after a temporary
# scale-up (scripts/scale-up.sh). Baseline matches terraform.tfvars
# (node_desired_count=2, node_min_count=0, node_max_count=4).
#
# Usage:
#   ./scripts/scale-down.sh [DESIRED_SIZE]    # default 2
#   DESIRED_SIZE=1 WAIT=false ./scripts/scale-down.sh
#   ./scripts/scale-down.sh --zero            # scale to ZERO nodes (FinOps:
#                                             # compute cost -> $0; control
#                                             # plane + EBS keep billing).
#                                             # Pods stay Pending; recover with
#                                             # ./scripts/scale-up.sh
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-circleguard-eks}"
REGION="${AWS_REGION:-us-east-1}"

if [[ "${1:-}" == "--zero" ]]; then
  DESIRED_SIZE=0
  MIN_SIZE=0
else
  DESIRED_SIZE="${1:-${DESIRED_SIZE:-2}}"
  MIN_SIZE="${MIN_SIZE:-0}"
fi
MAX_SIZE="${MAX_SIZE:-4}"
WAIT="${WAIT:-true}"

if (( DESIRED_SIZE < MIN_SIZE || DESIRED_SIZE > MAX_SIZE )); then
  echo "DESIRED_SIZE=$DESIRED_SIZE must be within [$MIN_SIZE, $MAX_SIZE]." >&2
  exit 1
fi

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

  echo "[$ng] current: min=$MIN max=$MAX desired=$DES -> baseline min=$MIN_SIZE max=$MAX_SIZE desired=$DESIRED_SIZE"

  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" \
    --scaling-config "minSize=${MIN_SIZE},maxSize=${MAX_SIZE},desiredSize=${DESIRED_SIZE}" >/dev/null

  if [[ "$WAIT" == "true" ]]; then
    echo "[$ng] waiting for node group ACTIVE (node drain may take a few minutes)..."
    aws eks wait nodegroup-active \
      --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION"
  fi
  echo "[$ng] scaled to desired=$DESIRED_SIZE"
done

echo ""
echo "Done. Check nodes: kubectl get nodes"
