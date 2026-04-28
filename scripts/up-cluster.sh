#!/usr/bin/env bash
# Brings up DOKS + DOCR. Cluster is the expensive piece — only spin up
# when actually deploying or running stage/prod tests. ~6 min to provision.
#
# After this completes, trigger the `circleguard-infra` job in Jenkins
# (Build with Parameters -> ENVIRONMENT=dev) to deploy Postgres/Kafka/Neo4j/Redis.
# The bash scripts ./scripts/bootstrap-cluster.sh and deploy-infrastructure.sh
# remain available for local troubleshooting.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

terraform apply \
  -target=digitalocean_vpc.main \
  -target=module.k8s_cluster \
  -auto-approve

echo
echo "Cluster ID: $(terraform output -raw k8s_cluster_id)"
echo "Registry  : $(terraform output -raw registry_endpoint)"
echo
echo "Next: en Jenkins, Build job 'circleguard-infra' -> ENVIRONMENT=dev (RUN_BOOTSTRAP=true)."
