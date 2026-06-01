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
| `scripts/init-s3-backend.sh` | **Local**, once: creates the S3 state bucket (only thing that can't live in TF). Provisioning itself = `terraform apply`, run locally — NOT in CI |
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
0a. scripts/init-s3-backend.sh               # LOCAL, admin, once: create S3 state bucket
0b. cd terraform/aws && terraform apply       # LOCAL, admin: VPC/EKS(+access entry)/ECR/OIDC/IRSA
                                             #   → set gha_role_arn output as AWS_ROLE_ARN secret
1. bootstrap-eso.yml                         # External Secrets Operator + ClusterSecretStore
2. deploy-data-plane.yml  (per namespace)    # backing services
3. deploy-{dev,stage,prod}.yml               # application services
```

**Provisioning runs LOCALLY, not in CI** (deliberate: VPC/EKS/IAM = rare, high-privilege). The GHA OIDC role (`circleguard-gha-role`) is narrow on purpose — ECR push + EKS deploy + SecretsManager seed on `circleguard/*` — it **cannot create or destroy infrastructure**. Infra changes/teardown are local `terraform apply`/`destroy`; the S3 state bucket is not Terraform-managed so it survives a destroy. Rationale in `doc/infrastructure.md`.

Local convenience wrappers: `scripts/deploy-infrastructure.sh <ns>`, `scripts/port-forward-dev.sh`.
