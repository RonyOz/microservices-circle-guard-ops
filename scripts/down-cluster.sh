#!/usr/bin/env bash
# Destroys the DOKS cluster and DOCR. All in-cluster state (Postgres,
# Kafka, Neo4j, Redis) is wiped — bootstrap-cluster.sh + deploy-infrastructure.sh
# must be re-run after the next up-cluster.sh.
#
# Optional:
#   PRUNE_PVC_VOLUMES=true ./scripts/down-cluster.sh
# Deletes unattached DigitalOcean volumes named pvc-* after cluster teardown.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

terraform destroy -target=module.k8s_cluster -auto-approve

echo
echo "Cluster destroyed. VPC kept (free) so Jenkins networking stays intact."

ORPHAN_PVC_IDS="$(
  doctl compute volume list --format ID,Name,DropletIDs --no-header 2>/dev/null \
    | awk '$2 ~ /^pvc-/ && ($3 == "" || $3 == "-") {print $1}'
)"

if [[ -n "${ORPHAN_PVC_IDS}" ]]; then
  echo
  echo "Detected unattached pvc-* volumes:"
  doctl compute volume list --format ID,Name,DropletIDs --no-header \
    | awk '$2 ~ /^pvc-/ && ($3 == "" || $3 == "-") {print "  - "$1" ("$2")"}'

  if [[ "${PRUNE_PVC_VOLUMES:-false}" == "true" ]]; then
    for volume_id in ${ORPHAN_PVC_IDS}; do
      doctl compute volume delete "${volume_id}" --force || doctl compute volume delete "${volume_id}" -f
    done
    echo "Orphan pvc-* volumes deleted."
  else
    echo "To prune them automatically: PRUNE_PVC_VOLUMES=true ./scripts/down-cluster.sh"
  fi
fi
