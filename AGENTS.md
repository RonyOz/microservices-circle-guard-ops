# AGENTS.md — microservices-circle-guard-ops

Para opencode. Ver contexto completo del workspace en `/home/ronyoz/dev/cg/AGENTS.md` y `CLAUDE.md`.

## Rol de este repo

Repo service-agnostic con CI/CD, Helm charts, Terraform, Locust y E2E. El dev repo (`microservices-circle-guard-dev`) tiene el código fuente de los 8 microservicios. Plataforma: **AWS (EKS/ECR/S3/OIDC) + GitHub Actions** — un solo cluster EKS, ambientes = namespaces.

## Archivos clave

| Ruta | Propósito |
|------|-----------|
| `services/<name>/chart/` | Helm chart por microservicio |
| `terraform/aws/` | AWS IaC — un solo cluster EKS compartido (modules: vpc, eks-cluster, ecr, github-oidc, irsa-secrets) |
| `locust/<name>/locustfile.py` | Tests de performance por servicio |
| `e2e/<name>/e2e.sh` | E2E curl scripts por servicio |
| `cliff.toml` | git-cliff config para release notes |
| `infrastructure/chart/` | Chart `circleguard-infra` — backing services + ExternalSecrets |
| `.github/workflows/` | GitHub Actions: bootstrap-eso, deploy-data-plane, deploy-{dev,stage,prod} (provisioning NO está en CI — corre local vía `scripts/init-s3-backend.sh` + `scripts/aws-up.sh`) |

## Image naming

Todos los servicios usan un solo ECR repo:
```
<account>.dkr.ecr.<region>.amazonaws.com/circleguard:<service>-sha-<commit7>
```

## Plan activo

`/home/ronyoz/dev/cg/PROJECT-FINAL-PLAN.md` — leer antes de cualquier tarea.
