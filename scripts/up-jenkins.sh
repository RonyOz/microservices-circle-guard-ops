#!/usr/bin/env bash
# Brings up Jenkins: VPC + persistent volume + droplet. Idempotent.
# The volume is preserved across runs, so Jenkins state (jobs, plugins,
# credentials) survives `down-jenkins.sh` and is restored on next `up`.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

terraform apply \
  -target=digitalocean_vpc.main \
  -target=digitalocean_volume.jenkins_home \
  -target=module.jenkins_vm \
  -auto-approve

echo
echo "Jenkins URL: $(terraform output -raw jenkins_url)"
echo "First boot takes ~5 min while cloud-init installs Jenkins."
echo "Initial admin password (run after ~5 min):"
echo "  ssh root@$(terraform output -raw jenkins_ip) 'cat /var/lib/jenkins/secrets/initialAdminPassword'"
