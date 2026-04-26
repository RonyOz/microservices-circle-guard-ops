#!/usr/bin/env bash
# Destroys the DOKS cluster and DOCR. All in-cluster state (Postgres,
# Kafka, Neo4j, Redis) is wiped — bootstrap-cluster.sh + deploy-infrastructure.sh
# must be re-run after the next up-cluster.sh.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

terraform destroy -target=module.k8s_cluster -auto-approve

echo
echo "Cluster destroyed. VPC kept (free) so Jenkins networking stays intact."
