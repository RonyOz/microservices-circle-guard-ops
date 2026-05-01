#!/usr/bin/env bash
# scripts/bootstrap-cluster.sh
#
# Run ONCE after a fresh DOKS cluster (i.e. tras up-cluster.sh).
# Fetches kubeconfig, creates namespaces, links DOCR, y crea los secrets
# que necesitan los manifests de infrastructure/manifests/.
#
# Las credenciales coinciden con docker-compose.yml del repo de aplicación
# (admin/password en Postgres, neo4j/password en Neo4j) para que los
# microservicios se conecten sin reconfiguración.
#
# Idempotente: namespaces, DOCR link y secrets sólo se tocan si faltan.

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

echo "==> Linking DOCR to cluster (image pulls without extra secrets)"
doctl registry kubernetes-manifest | kubectl apply -f -
for ns in dev stage production; do
  kubectl patch serviceaccount default \
    -n "$ns" \
    -p '{"imagePullSecrets": [{"name": "registry-circleguard"}]}'
done

echo "==> Ensuring backing-service secrets exist in each namespace"
for ns in dev stage production; do
  kubectl get secret postgres-secret -n "$ns" >/dev/null 2>&1 || \
    kubectl create secret generic postgres-secret -n "$ns" \
      --from-literal=password="password"

  kubectl get secret neo4j-secret -n "$ns" >/dev/null 2>&1 || \
    kubectl create secret generic neo4j-secret -n "$ns" \
      --from-literal=NEO4J_AUTH="neo4j/password"

  kubectl get secret openldap-secret -n "$ns" >/dev/null 2>&1 || \
    kubectl create secret generic openldap-secret -n "$ns" \
      --from-literal=admin-password="admin"
done

echo ""
echo "[ OK ] Cluster bootstrap complete."
