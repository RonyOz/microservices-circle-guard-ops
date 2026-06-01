# Secrets Management — CircleGuard

## Overview

CircleGuard uses a layered secrets model:

| Layer | Tool | Used for |
|-------|------|----------|
| CI-time | GitHub Actions Secrets | AWS role assumption, image push, K8s secret injection |
| Runtime (K8s) | Kubernetes Secrets | Pod env var injection via `envFrom.secretRef` |
| Runtime (AWS) | AWS Secrets Manager + IRSA | Planned — file-service S3 credentials (roadmap) |

---

## Migration from Jenkins

| Jenkins Credential | New Location | Notes |
|-------------------|--------------|-------|
| `db-credentials` (username) | Hardcoded `circleguard` in workflow | Not sensitive — same across all envs |
| `db-credentials` (password) | GHA Secret: `DB_PASSWORD` | Injected into K8s Secret at deploy time |
| `jwt-secret` | GHA Secret: `JWT_SECRET` | Injected into K8s Secret at deploy time |
| `github-token` | Built-in `GITHUB_TOKEN` | Auto-provided by GHA, no migration needed |
| `kubeconfig-doks` | GHA Secret: `AWS_ROLE_ARN` + OIDC | OIDC replaces static kubeconfig — no credentials stored |
| `do-api-token` | Retired | DigitalOcean deprecated; AWS uses OIDC |

---

## GitHub Actions Secrets required

Set these in **both repos** unless noted:

### `microservices-circle-guard-ops` (ops repo)

| Secret | Description | Used by |
|--------|-------------|---------|
| `AWS_ROLE_ARN` | ARN of `circleguard-gha-role` IAM role (Terraform output `gha_role_arn`) | All deploy + infra workflows |
| `DB_PASSWORD` | PostgreSQL + Neo4j password | deploy-dev, deploy-stage, deploy-prod |
| `JWT_SECRET` | JWT signing key (min 32 chars, random) | deploy-dev, deploy-stage, deploy-prod |

### `microservices-circle-guard-dev` (dev repo)

| Secret | Description | Used by |
|--------|-------------|---------|
| `AWS_ROLE_ARN` | Same ARN as above | `_reusable-service-ci.yml` (ECR push) |
| `OPS_REPO_TOKEN` | PAT with `repo` scope for cross-repo `repository_dispatch` | `_reusable-service-ci.yml` |

---

## Kubernetes Secrets — structure per service

Each service gets a K8s Secret named `<service>-secret` created by the deploy workflow before Helm upgrade:

```bash
kubectl create secret generic <service>-secret \
  --from-literal=DB_USERNAME=circleguard \
  --from-literal=DB_PASSWORD=<DB_PASSWORD> \
  --from-literal=NEO4J_USERNAME=neo4j \
  --from-literal=NEO4J_PASSWORD=<DB_PASSWORD> \
  --from-literal=JWT_SECRET=<JWT_SECRET> \
  --namespace <namespace> \
  --dry-run=client -o yaml | kubectl apply -f -
```

Pods consume secrets via `envFrom.secretRef` in Helm chart `deployment.yaml`. Only the keys each service actually uses are read; unused keys are ignored.

### Key usage per service

| Service | DB_USERNAME | DB_PASSWORD | NEO4J_* | JWT_SECRET |
|---------|:-----------:|:-----------:|:-------:|:----------:|
| auth-service | ✅ | ✅ | — | ✅ |
| identity-service | ✅ | ✅ | — | — |
| promotion-service | ✅ | ✅ | ✅ | — |
| notification-service | — | — | — | ✅ |
| form-service | ✅ | ✅ | — | — |
| gateway-service | — | — | — | ✅ |
| dashboard-service | ✅ | ✅ | — | — |
| file-service | — | — | — | — |
| mobile | — | — | — | — |

---

## Shared infrastructure secrets (bootstrap)

Created per namespace when the `circleguard-infra` chart is deployed (`deploy-data-plane.yml`); runtime values are synced from AWS Secrets Manager via External Secrets Operator. _(Full secrets-matrix rewrite tracked in plan task 0.5.17.)_

| K8s Secret | Keys | Default (dev/stage) |
|------------|------|---------------------|
| `postgres-secret` | `password` | Set from `DB_PASSWORD` GHA secret |
| `neo4j-secret` | `NEO4J_AUTH` | `neo4j/<DB_PASSWORD>` |
| `openldap-secret` | `admin-password` | Set at bootstrap time |

---

## Secret rotation procedure

1. Generate new value: `openssl rand -base64 32`
2. Update GHA Secret in GitHub UI (Settings → Secrets → Actions)
3. Re-run deploy workflow for each service to recreate K8s Secrets with new value
4. Restart pods: `kubectl rollout restart deployment/<service> -n <namespace>`

---

## AWS Secrets Manager + IRSA (implemented)

Runtime secrets (`DB_PASSWORD`, `JWT_SECRET`, `NEO4J_PASSWORD`) are stored in AWS Secrets Manager and delivered to pods via external-secrets-operator (ESO) without storing credentials in CI environment at pod runtime.

### Architecture

```
AWS Secrets Manager
  circleguard/dev       ← JSON with all runtime keys
  circleguard/stage
  circleguard/production

IRSA role: circleguard-eso-role
  → bound to ServiceAccount external-secrets/external-secrets
  → policy: secretsmanager:GetSecretValue on circleguard/* paths

external-secrets-operator (Helm, namespace: external-secrets)
  → SecretStore per namespace (circleguard-secret-store)
  → ExternalSecret per service → creates <service>-secret K8s Secret

Pods
  → envFrom.secretRef: <service>-secret (unchanged)
```

### How deploy workflows interact with SM

Each deploy workflow run calls `aws secretsmanager put-secret-value` to push current GHA secret values to SM before deploying. ESO reconciles and syncs to K8s secrets within its `refreshInterval` (1h).

### Terraform resources (module irsa-secrets)

| Resource | Name |
|----------|------|
| `aws_secretsmanager_secret` | `circleguard/dev`, `circleguard/stage`, `circleguard/production` |
| `aws_iam_role` | `circleguard-eso-role` |
| `aws_iam_policy` | `circleguard-eso-role-sm-read` |

### Rotation procedure

1. Generate new value: `openssl rand -base64 32`
2. Update GHA Secret in GitHub UI (Settings → Secrets → Actions)
3. Re-run any deploy workflow — it pushes new value to SM automatically
4. ESO syncs within 1h (force: `kubectl annotate externalsecret <name> force-sync=$(date +%s) -n <ns>`)
