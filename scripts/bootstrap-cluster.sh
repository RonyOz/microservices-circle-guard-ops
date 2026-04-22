#!/usr/bin/env bash
# scripts/bootstrap-cluster.sh
#
# Run ONCE after `terraform apply -target=module.k8s_cluster`.
# Fetches kubeconfig, creates namespaces, and links DOCR to the cluster.
#
# Prerequisites: doctl authenticated (`doctl auth init`)

set -euo pipefail

CLUSTER_NAME="${1:-circleguard-k8s}"
REGISTRY_NAME="${2:-circleguard}"

echo "→ Fetching kubeconfig for cluster: $CLUSTER_NAME"
doctl kubernetes cluster kubeconfig save "$CLUSTER_NAME"

echo "→ Creating namespaces (dev / stage / production)"
for ns in dev stage production; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$ns" \
    circleguard/environment="$ns" \
    app.kubernetes.io/managed-by=terraform \
    --overwrite
done

echo "→ Linking DOCR registry to cluster (allows image pulls without extra secrets)"
doctl registry kubernetes-manifest | kubectl apply -f -
# Patch each namespace's default service account to use the registry secret
for ns in dev stage production; do
  kubectl patch serviceaccount default \
    -n "$ns" \
    -p '{"imagePullSecrets": [{"name": "registry-circleguard"}]}'
done

echo "→ Adding Bitnami Helm repo"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add neo4j https://helm.neo4j.com/neo4j
helm repo update

echo ""
echo "✅ Cluster bootstrap complete."
echo "   Run scripts/deploy-infrastructure.sh <namespace> to install Kafka, PostgreSQL, etc."
