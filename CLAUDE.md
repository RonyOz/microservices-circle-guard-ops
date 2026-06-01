# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Context

This is the **ops repo** for CircleGuard (Proyecto Final IngeSoft V).

Full workspace context: `/home/ronyoz/dev/cg/CLAUDE.md`
Project plan + completeness tracker: `/home/ronyoz/dev/cg/PROJECT-FINAL-PLAN.md`

Read both files before starting any task.

## This repo's role

Service-agnostic CI/CD, infrastructure, and deployment config. The app code lives in `microservices-circle-guard-dev`. The dev repo triggers this repo via `repository_dispatch`, passing the service name and image tag.

**Platform:** AWS (EKS/ECR/S3/IAM-OIDC) + GitHub Actions. One shared EKS cluster `circleguard-eks`; environments `dev`/`stage`/`production` are **Kubernetes namespaces**, not separate clusters. (The pre-pivot DigitalOcean + Jenkins stack has been removed — see `doc/taller2.md` for history.)

## Key files

| Path | Purpose |
|------|---------|
| `terraform/aws/` | AWS IaC — single shared cluster, single state (modules: vpc, eks-cluster, ecr, github-oidc, irsa-secrets) |
| `.github/workflows/provision-aws.yml` | Terraform plan/apply/destroy (control plane) |
| `.github/workflows/bootstrap-eso.yml` | Install External Secrets Operator + ClusterSecretStore (once per cluster) |
| `.github/workflows/deploy-data-plane.yml` | Deploy `circleguard-infra` chart (PG/Neo4j/Kafka/Redis/LDAP/SMTP) per namespace |
| `.github/workflows/deploy-{dev,stage,prod}.yml` | Deploy application services per namespace |
| `services/<name>/chart/` | Helm chart per microservice |
| `infrastructure/chart/` | `circleguard-infra` Helm chart (shared backing services + ExternalSecrets) |
| `locust/<name>/locustfile.py` | Locust perf tests per service |
| `e2e/<name>/e2e.sh` | E2E curl scripts per service |
| `cliff.toml` | git-cliff config for release notes |

## Image naming convention

All services use a single ECR repo; the service is encoded in the tag (account derived at runtime, never hardcoded):
```
<account>.dkr.ecr.<region>.amazonaws.com/circleguard:<service>-sha-<commit7>
```

## Secrets

- CI-time (ephemeral): **GitHub Actions Secrets** (`AWS_ROLE_ARN`, GitHub token).
- Runtime (long-lived): **AWS Secrets Manager** read by pods via **External Secrets Operator** (IRSA).
- ClusterSecretStore → `bootstrap-eso.yml`; ExternalSecret (per service) → `infrastructure/chart`.

## Bootstrap order (fresh cluster)

```
0. terraform/aws/bootstrap/bootstrap.sh      # once per account, LOCAL: S3 bucket + OIDC provider + GHA role
                                             #   → set printed gha_role_arn as AWS_ROLE_ARN secret
1. provision-aws.yml      (apply)            # VPC + EKS + IRSA (in CI via OIDC)
2. bootstrap-eso.yml                         # External Secrets Operator + ClusterSecretStore
3. deploy-data-plane.yml  (per namespace)    # backing services
4. deploy-{dev,stage,prod}.yml               # application services
```

The bootstrap is LOCAL+admin to break the chicken-and-egg (CI auth needs the GHA role, which `bootstrap.sh` creates). `provision-aws.yml destroy` is a FULL teardown (incl. the GHA role); the S3 state bucket survives. Re-provisioning after a destroy = re-run `bootstrap.sh` locally (same step 0).

Local convenience wrappers: `scripts/deploy-infrastructure.sh <ns>`, `scripts/port-forward-dev.sh`.
