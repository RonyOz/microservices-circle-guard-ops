#!/usr/bin/env bash
# scripts/deploy-infrastructure.sh <namespace>
#
# Installs Kafka, PostgreSQL, Neo4j and Redis into the given namespace.
# Idempotent — safe to re-run.

set -euo pipefail

NS="${1:?Usage: $0 <namespace>  (dev|stage|production)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "→ Deploying shared infrastructure to namespace: $NS"

helm upgrade --install postgresql bitnami/postgresql \
  --namespace "$NS" \
  --values "$REPO_ROOT/infrastructure/values-postgresql.yaml" \
  --set auth.existingSecret=postgresql-secret \
  --wait --timeout 5m

helm upgrade --install neo4j neo4j/neo4j \
  --namespace "$NS" \
  --values "$REPO_ROOT/infrastructure/values-neo4j.yaml" \
  --wait --timeout 8m

helm upgrade --install kafka bitnami/kafka \
  --namespace "$NS" \
  --values "$REPO_ROOT/infrastructure/values-kafka.yaml" \
  --wait --timeout 8m

helm upgrade --install redis bitnami/redis \
  --namespace "$NS" \
  --values "$REPO_ROOT/infrastructure/values-redis.yaml" \
  --wait --timeout 5m

echo "✅ Infrastructure deployed to $NS"
