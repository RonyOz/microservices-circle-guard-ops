# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Context

This is the **ops repo** for CircleGuard (Proyecto Final IngeSoft V).

Full workspace context: `/home/ronyoz/dev/cg/CLAUDE.md`
Project plan + completeness tracker: `/home/ronyoz/dev/cg/PROJECT-FINAL-PLAN.md`

Read both files before starting any task.

## This repo's role

Service-agnostic CI/CD, infrastructure, and deployment config. The app code lives in `microservices-circle-guard-dev`. This repo is triggered by the dev repo passing `SERVICE` and `IMAGE_TAG` parameters.

## Key files

| Path | Purpose |
|------|---------|
| `jenkins/Jenkinsfile.dev` | Deploy to `dev` namespace (smoke test) |
| `jenkins/Jenkinsfile.stage` | Deploy to `stage` (unit + integration + E2E + Locust) |
| `jenkins/Jenkinsfile.prod` | Deploy to `production` (--atomic + release notes) |
| `jenkins/Jenkinsfile.infra` | Manual: install shared infra (PG/Neo4j/Kafka/Redis) |
| `services/<name>/chart/` | Helm chart per microservice |
| `infrastructure/` | Helm values for shared middleware |
| `terraform/` | DigitalOcean IaC (DOKS + Jenkins Droplet + DOCR) |
| `locust/<name>/locustfile.py` | Locust perf tests per service |
| `e2e/<name>/e2e.sh` | E2E curl scripts per service |
| `cliff.toml` | git-cliff config for release notes |

## Image naming convention

All services use a single DOCR repo:
```
registry.digitalocean.com/circleguard/circleguard-services:<service>-sha-<commit7>
```

## Jenkins credentials required

`kubeconfig-doks`, `do-api-token`, `github-token`, `db-credentials`, `jwt-secret`

## Infra bootstrap (run once after terraform apply)

```bash
./scripts/bootstrap-cluster.sh circleguard-k8s circleguard
./scripts/deploy-infrastructure.sh dev
./scripts/deploy-infrastructure.sh stage
./scripts/deploy-infrastructure.sh production
```
