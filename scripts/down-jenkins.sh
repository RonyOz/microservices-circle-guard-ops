#!/usr/bin/env bash
# Destroys the Jenkins droplet to stop hourly billing. The volume,
# VPC and DOCR remain so state and routing survive intact.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

terraform destroy -target=module.jenkins_vm -auto-approve

echo
echo "Jenkins droplet destroyed. Volume 'jenkins-home' kept (~\$1/mo at 10 GB)."
echo "Run scripts/up-jenkins.sh to resume — JENKINS_HOME will be remounted."
