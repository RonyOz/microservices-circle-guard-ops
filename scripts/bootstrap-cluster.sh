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

echo "==> Fetching kubeconfig for cluster: $CLUSTER_NAME"
doctl kubernetes cluster kubeconfig save "$CLUSTER_NAME"

echo "==> Creating namespaces (dev / stage / production)"
for ns in dev stage production; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$ns" \
    circleguard/environment="$ns" \
    app.kubernetes.io/managed-by=terraform \
    --overwrite
done

echo "==> Linking DOCR registry to cluster (allows image pulls without extra secrets)"
doctl registry kubernetes-manifest | kubectl apply -f -
# Patch each namespace's default service account to use the registry secret
for ns in dev stage production; do
  kubectl patch serviceaccount default \
    -n "$ns" \
    -p '{"imagePullSecrets": [{"name": "registry-circleguard"}]}'
done

echo "==> Ensuring infrastructure secrets exist in each namespace"
# Idempotent — only creates the secret if missing. Avoids rotating passwords
# under existing PVCs (which would lock you out of the data).
# Passwords are fixed/well-known on purpose for the academic exercise.
for ns in dev stage production; do
  kubectl get secret postgresql-secret -n "$ns" >/dev/null 2>&1 || \
    kubectl create secret generic postgresql-secret -n "$ns" \
      --from-literal=postgres-password="circleguard-pg-2026" \
      --from-literal=password="circleguard-pg-user-2026"

  kubectl get secret redis-secret -n "$ns" >/dev/null 2>&1 || \
    kubectl create secret generic redis-secret -n "$ns" \
      --from-literal=redis-password="circleguard-redis-2026"

  # Neo4j chart expects key NEO4J_AUTH in the form "user/password".
  kubectl get secret neo4j-secret -n "$ns" >/dev/null 2>&1 || \
    kubectl create secret generic neo4j-secret -n "$ns" \
      --from-literal=NEO4J_AUTH="neo4j/circleguard-neo4j-2026"
done

echo "==> Adding Helm repos"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add neo4j https://helm.neo4j.com/neo4j
helm repo update

echo ""
echo "[ OK ] Cluster bootstrap complete."
