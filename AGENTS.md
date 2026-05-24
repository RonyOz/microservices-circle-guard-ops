# AGENTS.md — microservices-circle-guard-ops

Para opencode. Ver contexto completo del workspace en `/home/ronyoz/dev/cg/AGENTS.md` y `CLAUDE.md`.

## Rol de este repo

Repo service-agnostic con CI/CD, Helm charts, Terraform, Locust y E2E. El dev repo (`microservices-circle-guard-dev`) tiene el código fuente de los 8 microservicios.

## Archivos clave

| Ruta | Propósito |
|------|-----------|
| `services/<name>/chart/` | Helm chart por microservicio |
| `terraform/` | DigitalOcean IaC (deprecated) + AWS IaC en `terraform/aws/` |
| `locust/<name>/locustfile.py` | Tests de performance por servicio |
| `e2e/<name>/e2e.sh` | E2E curl scripts por servicio |
| `cliff.toml` | git-cliff config para release notes |
| `infrastructure/` | Helm values para middleware compartido |
| `.github/workflows/` | GitHub Actions workflows (nuevos, reemplazan Jenkinsfiles) |

## Image naming

Todos los servicios usan un solo ECR repo:
```
<account>.dkr.ecr.<region>.amazonaws.com/circleguard:<service>-sha-<commit7>
```

## Plan activo

`/home/ronyoz/dev/cg/PROJECT-FINAL-PLAN.md` — leer antes de cualquier tarea.
