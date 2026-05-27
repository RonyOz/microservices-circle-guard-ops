#!/usr/bin/env bash
# scripts/deploy-infrastructure.sh <namespace>
#
# Despliega el chart `circleguard-infra` (Postgres, Neo4j, Kafka, Zookeeper,
# Redis, OpenLDAP) en el namespace dado. Idempotente — `helm upgrade --install`
# crea o actualiza el release según corresponda.
#
# El chart vive en infrastructure/chart/ y referencia imágenes upstream
# oficiales (sin Bitnami). Los secrets que consume los crea bootstrap-cluster.sh.

set -euo pipefail

NS="${1:?Usage: $0 <namespace>  (dev|stage|production)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART_DIR="$REPO_ROOT/infrastructure/chart"
RELEASE_NAME="circleguard-infra"

echo "==> Linting chart"
helm lint "$CHART_DIR"

echo "==> Deploying release '$RELEASE_NAME' to namespace: $NS"
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
  --namespace "$NS" \
  --wait --timeout 10m

echo ""
echo "[ OK ] Release '$RELEASE_NAME' deployed to namespace: $NS"
helm status "$RELEASE_NAME" -n "$NS"
