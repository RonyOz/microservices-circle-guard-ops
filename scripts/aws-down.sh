#!/usr/bin/env bash
# scripts/aws-down.sh
# Teardown counterpart to scripts/aws-up.sh.
# Deletes LoadBalancer Services, NodeGroups, orphan ELBs, and orphan IAM role
# attachments before `terraform destroy` — all of these live in the VPC/cluster
# but outside TF state, so destroy would hit DependencyViolation without this.
set -euo pipefail

cd "$(dirname "$0")/../terraform/aws"

CLUSTER_NAME="${CLUSTER_NAME:-circleguard-eks}"
REGION="${AWS_REGION:-us-east-1}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

echo "==> Removing LoadBalancer Services and NodeGroups"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
  kubectl delete svc --all-namespaces \
    --field-selector spec.type=LoadBalancer --ignore-not-found --wait=true || true

  echo "==> Deleting NodeGroups (required before cluster destroy)"
  NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --query 'nodegroups[*]' --output text 2>/dev/null)
  for ng in $NODEGROUPS; do
    echo "    Deleting nodegroup: $ng"
    aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
      --region "$REGION" >/dev/null
  done
  for ng in $NODEGROUPS; do
    echo "    Waiting for nodegroup deletion: $ng"
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
      --region "$REGION"
  done

  echo "==> Detaching orphan IAM roles from TF-managed policies"
  TF_POLICIES=$(aws iam list-policies --scope Local --query \
    'Policies[?starts_with(PolicyName, `circleguard-`)].Arn' --output text 2>/dev/null)
  for policy_arn in $TF_POLICIES; do
    ROLES=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" \
      --query 'PolicyRoles[*].RoleName' --output text 2>/dev/null)
    for role in $ROLES; do
      echo "    Detaching $policy_arn from $role"
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
    done
  done
else
  echo "    Cluster $CLUSTER_NAME not found — skipping."
fi

echo "==> Cleaning up orphaned ELBs in circleguard VPCs"
# EKS-provisioned ELBs are not in TF state; if kubectl delete didn't reach them
# (cluster already gone), they block VPC destroy with DependencyViolation.
VPC_IDS=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=circleguard" \
  --query 'Vpcs[*].VpcId' --output text 2>/dev/null)
for vpc_id in $VPC_IDS; do
  # Classic ELBs
  ELB_NAMES=$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].LoadBalancerName" \
    --output text 2>/dev/null)
  for elb in $ELB_NAMES; do
    echo "    Deleting classic ELB: $elb"
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$elb" || true
  done
  # ALBs / NLBs (v2)
  ELBv2_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" \
    --output text 2>/dev/null)
  for elb_arn in $ELBv2_ARNS; do
    echo "    Deleting ALB/NLB: $elb_arn"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$elb_arn" || true
  done
done
# Wait for ENIs to detach before TF destroy touches the VPC
if [[ -n "${VPC_IDS// /}" ]]; then
  echo "    Waiting 20s for ENIs to release..."
  sleep 20
fi

echo "==> terraform destroy"
if [[ "$AUTO_APPROVE" == "true" ]]; then
  terraform destroy -input=false -auto-approve
else
  terraform destroy -input=false
fi
