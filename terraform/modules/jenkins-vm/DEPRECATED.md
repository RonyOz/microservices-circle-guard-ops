# DEPRECATED — jenkins-vm Terraform module

**Deprecated:** 2026-05-23  
**Reason:** Platform migrated from DigitalOcean + Jenkins to AWS + GitHub Actions.

This module provisioned a DigitalOcean Droplet (`s-2vcpu-4gb`) running Jenkins with a persistent 25 GB volume attached for `JENKINS_HOME`.

**Replacement:** CI/CD is now handled by GitHub Actions with OIDC federation to AWS IAM. No self-hosted Jenkins VM is required.

Do not apply this module. It is retained for historical reference only.
