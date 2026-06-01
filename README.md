# circleguard-ops

**Operations repository for CircleGuard** — Infrastructure as Code, Helm charts, CI/CD pipelines, and quality gates for the university contact-tracing platform.

> Service-agnostic. The application code (8 Spring Boot microservices + Expo mobile) lives in [`microservices-circle-guard-dev`](../microservices-circle-guard-dev). The dev repo triggers this repo via `repository_dispatch`, passing the service name and image tag.

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
│       ├── bootstrap/bootstrap.sh      # Run ONCE (local): S3 state bucket + OIDC/GHA role
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
│   ├── provision-aws.yml              # Terraform plan/apply/destroy (control plane)
│   ├── bootstrap-eso.yml              # Install External Secrets Operator + ClusterSecretStore
│   ├── deploy-data-plane.yml          # Deploy circleguard-infra chart per namespace
│   ├── deploy-dev.yml                 # helm lint → deploy → smoke test
│   ├── deploy-stage.yml               # deploy → E2E → Locust
│   └── deploy-prod.yml                # verify image → approval → --atomic → git-cliff release
│
├── locust/<name>/locustfile.py        # Performance tests per service
├── e2e/<name>/e2e.sh                  # E2E curl scripts per service
├── scripts/
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

**Step 0 — foundation (once per account, LOCAL, admin creds).** Breaks the
chicken-and-egg: CI authenticates via the GHA OIDC role, which doesn't exist until
this runs. `bootstrap.sh` creates the S3 state bucket **and** the identity layer
(OIDC provider + GHA role, pulling in ECR), then prints the role ARN:

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars   # set gha_subject_patterns to your repo
./bootstrap/bootstrap.sh
# → copy the printed gha_role_arn into the AWS_ROLE_ARN secret (ops + dev repos)
```

Everything after this runs **in CI via OIDC** — no more local Terraform:

| Order | Step | Scope | How |
|:---|:---|:---|:---|
| 1 | Control plane: VPC + EKS + IRSA | once per cluster | `provision-aws.yml` (action=apply) |
| 2 | External Secrets Operator + ClusterSecretStore | once per cluster | `bootstrap-eso.yml` |
| 3 | Data plane (Postgres, Neo4j, Kafka, Redis, LDAP, SMTP) | per namespace | `deploy-data-plane.yml` |
| 4 | Application services | per namespace | `deploy-{dev,stage,prod}.yml` |

> **Teardown:** `provision-aws.yml` (action=destroy) removes **everything** Terraform
> manages (VPC/EKS/ECR/OIDC/IRSA). The S3 state bucket survives (not Terraform-managed).
> To re-provision afterwards, re-run `bootstrap.sh` locally first — it recreates the
> GHA role CI logs in with (same step 0 as a fresh account).

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

## Documentation

| Doc | Purpose |
|:---|:---|
| `terraform/aws/README.md` | AWS account, modules, state backend |
| `doc/infrastructure.md` | Infra architecture + namespace-as-environment |
| `doc/secrets-management.md` | Secrets matrix (ESO + Secrets Manager) |
| `doc/design-patterns.md` | Resilience + deployment patterns |
| `doc/branching-strategy.md` | Trunk-based workflow |
| `doc/taller2.md` | Historical (pre-pivot DigitalOcean + Jenkins) — archive only |

> Full workspace context: `/home/ronyoz/dev/cg/CLAUDE.md` · Completeness tracker: `PROJECT-FINAL-PLAN.md`.
