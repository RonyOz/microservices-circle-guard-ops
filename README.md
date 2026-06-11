# circleguard-ops

**Operations repository for CircleGuard** — Infrastructure as Code, Helm charts, CI/CD pipelines, and quality gates for the university contact-tracing platform.

> Service-agnostic. The application code (8 Spring Boot microservices + Expo mobile) lives in [`microservices-circle-guard-dev`](../microservices-circle-guard-dev). The dev repo triggers this repo via `repository_dispatch`, passing the service name and image tag.

![AWS Deployment Topology](doc/img/AWS%20Deployment%20Topology.png)
---

## Platform

| Concern | Technology |
|:---|:---|
| **Primary cloud** | AWS — EKS (Kubernetes), ECR (images), S3 (Terraform state), IAM OIDC + IRSA (federation) |
| **Secondary cloud** | Azure — AKS + ACR (Multi-Cloud bonus only) |
| **CI/CD** | GitHub Actions with hosted runners + OIDC federation to AWS (no long-lived keys) |
| **Secrets** | GitHub Actions Secrets (CI-time) + AWS Secrets Manager via External Secrets Operator (runtime) |
| **Release notes** | git-cliff (conventional commits → GitHub Release) |

> **One shared EKS cluster** (`circleguard-eks`). The three environments — `dev`, `stage`, `production` — are **Kubernetes namespaces**, not separate clusters (academic-budget decision). Environment isolation happens at the K8s + Helm layer, not at the IaC layer.

---

## Repository structure

```
circleguard-ops/
├── terraform/
│   └── aws/                            # Control plane (single shared cluster, single state)
│       ├── main.tf                     # Orchestrates the modules below
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars.example    # Copy → terraform.tfvars (gitignored)
│       └── modules/
│           ├── vpc/                     # VPC + public/private subnets (2 AZs) + NAT
│           ├── eks-cluster/             # EKS control plane + node group + OIDC provider
│           ├── ecr/                     # Single ECR repo `circleguard` + lifecycle policy
│           ├── github-oidc/             # IAM OIDC provider + role for GHA workflows
│           └── irsa-secrets/            # IRSA role for External Secrets Operator
│
├── infrastructure/
│   └── chart/                          # `circleguard-infra` Helm chart (data plane)
│       ├── Chart.yaml                  # Postgres, Neo4j, Kafka+Zookeeper, Redis,
│       ├── values.yaml                 #   OpenLDAP, MailHog (SMTP catcher)
│       └── templates/                  #   + ExternalSecret per service
│
├── services/<name>/chart/             # Helm chart per microservice (8 backend services)
│   ├── Chart.yaml
│   ├── values.yaml                     # image.repository set at deploy time (--set)
│   └── templates/                      # deployment + service + probes
│
├── .github/workflows/
│   ├── bootstrap-eso.yml              # Install External Secrets Operator + ClusterSecretStore
│   ├── deploy-data-plane.yml          # Deploy circleguard-infra chart per namespace
│   ├── deploy-dev.yml                 # helm lint → deploy → smoke test
│   ├── deploy-stage.yml               # deploy → E2E → Locust
│   └── deploy-prod.yml                # verify image → approval → --atomic → git-cliff release
│
├── locust/<name>/locustfile.py        # Performance tests per service
├── e2e/<name>/e2e.sh                  # E2E curl scripts per service
├── scripts/
│   ├── init-s3-backend.sh             # Run ONCE (local): create S3 tfstate bucket
│   ├── aws-up.sh                      # Local: terraform apply (provision infra)
│   ├── aws-down.sh                    # Local: drain LB Services + terraform destroy
│   ├── deploy-infrastructure.sh       # Local wrapper for the data-plane chart
│   └── port-forward-dev.sh            # Local port-forward helper
└── cliff.toml                          # git-cliff config (release notes)
```

---

## CI/CD flow

```
dev repo push                          ops repo (this) — repository_dispatch
─────────────                          ──────────────────────────────────────
push to dev branch   ─────────────►    deploy-dev.yml    → namespace dev
                                          (helm lint → deploy → smoke)

push to release/*    ─────────────►    deploy-stage.yml  → namespace stage
                                          (deploy → E2E → Locust)

push to main         ─────────────►    deploy-prod.yml   → namespace production
                                          (verify image → approval → --atomic → release)
```

The dev repo's reusable workflow tests → builds → pushes to ECR (via OIDC), then fires
`peter-evans/repository-dispatch` with `client_payload` carrying the service, image tag,
and registry URL. This repo's deploy workflows consume that payload.

### Image naming

All services share a single ECR repository; the microservice is encoded in the tag:

```
<account>.dkr.ecr.<region>.amazonaws.com/circleguard:<service>-sha-<commit7>
```

Example: `circleguard:auth-service-sha-a1b2c3d`. The account ID is never hardcoded —
it is derived at runtime from the assumed OIDC role / `aws sts get-caller-identity`.

---

## Bootstrap a fresh cluster

Prerequisites: `awscli` (authenticated), `terraform >= 1.10`, `kubectl`, `helm`.

**Step 0 — provision (LOCAL, admin creds).** Provisioning runs locally, **not in CI**
(VPC/EKS/IAM = rare, high-privilege; the GHA OIDC role is deliberately narrow and cannot
create infra — see [Why provisioning is local](#why-provisioning-is-local)). First create
the S3 state bucket (the only piece that can't live in Terraform), then `aws-up.sh`
provisions everything else (VPC/EKS/ECR/OIDC/IRSA + EKS access entry):

```bash
./scripts/init-s3-backend.sh                   # S3 tfstate bucket (once per account)
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars   # set gha_subject_patterns to your repo
cd -
./scripts/aws-up.sh
# → copy the gha_role_arn output into the AWS_ROLE_ARN secret (ops + dev repos)
```

Everything after this runs **in CI via OIDC**:

| Order | Step | Scope | How |
|:---|:---|:---|:---|
| 1 | External Secrets Operator + ClusterSecretStore | once per cluster | `bootstrap-eso.yml` |
| 2 | Data plane (Postgres, Neo4j, Kafka, Redis, LDAP, SMTP) | per namespace | `deploy-data-plane.yml` |
| 3 | Application services | per namespace | `deploy-{dev,stage,prod}.yml` |

#### Why provisioning is local

The OIDC role CI assumes (`circleguard-gha-role`) is scoped to **ECR push + EKS deploy +
SecretsManager seed on `circleguard/*`** — it cannot touch VPC/EKS/IAM. Granting infra
create/destroy to a role assumable from the repo on any branch would be a god-role: any
workflow trigger could nuke the account. Provisioning is therefore a deliberate local op.

> **Infra changes & teardown** are local too: `./scripts/aws-up.sh` / `./scripts/aws-down.sh`
> (wrapping `terraform apply` / `terraform destroy`). `destroy` removes everything Terraform
> manages (VPC/EKS/ECR/OIDC/IRSA); the S3 state bucket survives (not Terraform-managed), so a
> later provision re-uses it cleanly.

---

## Secrets model

- **CI-time** ephemeral values (kubeconfig context, GitHub token) → **GitHub Actions Secrets**.
- **Runtime** long-lived values (DB passwords, JWT signing key) → **AWS Secrets Manager**,
  read by pods through **External Secrets Operator** via IRSA — no secrets baked into images.
- The `ClusterSecretStore` (cluster-scoped) is created by `bootstrap-eso.yml`; each
  `ExternalSecret` (namespaced) is created by the `circleguard-infra` chart. See
  `doc/secrets-management.md`.

---

## Branching strategy

**Trunk-Based Development.** PRs mandatory. Commits follow **Conventional Commits**
(`feat`/`fix`/`chore`/`refactor`/`test`/`perf`) — git-cliff parses them for release notes.

| Type | Pattern | Max lifetime |
|:---|:---|:---|
| Permanent | `main` | Indefinite |
| Feature/update | `update/<component>` | 2 days |
| Fix | `fix/<description>` | 2 days |

---

## Design patterns

- **Bulkhead** — `dev` / `stage` / `production` namespaces are isolated; a stage failure cannot reach production.
- **Retry / atomic deploy** — `helm upgrade --atomic` (prod) auto-rolls back on failure; charts expose `/actuator/health/{liveness,readiness}` probes.
- **Automated release notes** — git-cliff generates the CHANGELOG + GitHub Release on every production deploy.

---

## FinOps — cost breakdown

Full analysis with assumptions: [`doc/md/cost-analysis.md`](doc/md/cost-analysis.md).

| Scenario | USD/month | Notes |
|:---|---:|:---|
| Naive always-on (3× on-demand nodes, 730 h) | ≈ $380 | baseline, no optimization |
| On-demand usage (~120 h/month, `aws-down.sh`) | ≈ $146 | −62% |
| **Spot + 120 h + scale-to-zero idle (current setup)** | **≈ $95–105** | **−73%** |

Active strategies (10 of 11 — see `cost-analysis.md` §7):

- **Spot node group** — `node_capacity_type = "SPOT"` with 3 equivalent instance types (~60–70% off compute).
- **Scale-to-zero** — `./scripts/scale-down.sh --zero` (compute → $0; cluster, PVCs and data survive). Restore with `./scripts/scale-up.sh`.
- **HPA** on gateway + auth (min=1 / max=3 / CPU 70%).
- **AWS Budgets** — $20/month with 80% actual + 100% forecast email alerts (`terraform/aws/budgets.tf`).
- **Cost monitoring** — all resources tagged `Project=circleguard` (filter in Cost Explorer); Grafana dashboard `circleguard-finops` shows utilization, HPA activity and estimated $/h, $/month, and cost per service.
- Single NAT gateway, ECR lifecycle policy (keep 20 images), burstable `m7i-flex` nodes, on-demand shutdown scripts.

Pending: Graviton (`m7g`) nodes — requires multi-arch image builds (~20% extra off compute).

---

## Documentation

| Doc | Purpose |
|:---|:---|
| `terraform/aws/README.md` | AWS account, modules, state backend |
| `doc/infrastructure.md` | Infra architecture + namespace-as-environment |
| `doc/secrets-management.md` | Secrets matrix (ESO + Secrets Manager) |
| `doc/design-patterns.md` | Resilience + deployment patterns |
| `doc/branching-strategy.md` | Trunk-based workflow |
| `doc/change-management.md` | PR template, CODEOWNERS, definition of done |
| `doc/operations-manual.md` | Deploy, rollback, logs, scaling runbook |
| `doc/performance-analysis.md` | Locust results (p95 / throughput / error-rate) |
| `doc/cost-analysis.md` | FinOps: cost breakdown, savings strategies, spot/scale-to-zero analysis |
| `doc/sprints.md` | Sprint retros, velocity, burndown |
| `doc/user-stories.md` | Backlog / user stories |

