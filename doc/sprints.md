# Sprint History — CircleGuard Proyecto Final

Two completed sprint iterations following Scrum methodology. Trunk-based development; all sprint items map to GitHub Projects board #2.

---

## Sprint 1 — Platform Migration (May 1–15, 2026)

**Goal:** Migrate from DigitalOcean + Jenkins to AWS EKS + GitHub Actions; establish working CI/CD foundation.  
**Duration:** 2 weeks  
**Team:** 2 developers (Rony + Juan Pablo)  
**Velocity:** 34 story points completed

### Backlog (selected for sprint)

| ID | Item | Points | Assignee |
|----|------|--------|----------|
| S1-01 | Create AWS VPC module (Terraform) | 5 | Rony |
| S1-02 | Create EKS cluster module (Terraform) | 8 | Rony |
| S1-03 | Create ECR module with lifecycle policy | 3 | Rony |
| S1-04 | Create GitHub OIDC IAM role (Terraform) | 3 | Rony |
| S1-05 | Activate S3 remote backend for Terraform state | 2 | Rony |
| S1-06 | Create reusable `_reusable-service-ci.yml` workflow | 5 | Juan Pablo |
| S1-07 | Create 9 per-service trigger workflows | 3 | Juan Pablo |
| S1-08 | Create `deploy-dev/stage/prod/infra.yml` ops workflows | 5 | Juan Pablo |

### In Progress (snapshot mid-sprint, May 8)

- S1-02 EKS module: node group IAM roles wiring in review
- S1-06 Reusable workflow: ECR push via OIDC working; `repository_dispatch` wiring pending

### Done (sprint end, May 15)

- ✅ S1-01 — VPC + subnets + NAT Gateway provisioned in `us-east-1`
- ✅ S1-02 — EKS 1.30 cluster live; managed node group (t3.small × 6) running
- ✅ S1-03 — ECR repo `circleguard` created; tag immutability + 30-image lifecycle policy
- ✅ S1-04 — OIDC IAM role assumed by GHA; scoped to `RonyOz/microservices-circle-guard-dev`
- ✅ S1-05 — S3 bucket `circleguard-tfstate` with S3-native locking active
- ✅ S1-06 — Reusable CI: test → Gradle build → ECR push → `repository_dispatch` to ops repo
- ✅ S1-07 — All 9 service workflows wired with path filters
- ✅ S1-08 — `deploy-dev`: helm lint + deploy + smoke; `deploy-stage`: deploy + E2E; `deploy-prod`: verify + approval gate + `--atomic`; `infra`: manual Terraform plan/apply

### Retrospective

**What went well:**
- Terraform OIDC federation eliminated long-lived AWS keys; zero secrets in repo
- EKS managed node groups reduced ops overhead vs. self-managed nodes
- Reusable workflow pattern made per-service onboarding trivial (1 file each)

**What to improve:**
- EKS provisioning took 20 min per `terraform apply`; next sprint: pre-provision cluster and iterate on configs only
- `deploy-stage` E2E tests not yet wired (moved to Sprint 2 backlog)

---

## Sprint 2 — CI/CD Hardening + Design Patterns (May 15–27, 2026)

**Goal:** Close CI/CD quality gaps (Trivy, Jacoco, SemVer) and implement missing design patterns (Circuit Breaker, External Configuration, Feature Toggle) required by the rubric.  
**Duration:** 12 days  
**Team:** 2 developers  
**Velocity:** 28 story points completed

### Backlog (selected for sprint)

| ID | Item | Points | Assignee |
|----|------|--------|----------|
| S2-01 | Add Trivy scan (report-only) to `_reusable-service-ci.yml` | 2 | Juan Pablo |
| S2-02 | Add Trivy blocking gate to `deploy-prod.yml` | 3 | Juan Pablo |
| S2-03 | Add Jacoco plugin to root `build.gradle.kts` | 2 | Rony |
| S2-04 | Upload Jacoco artifact in CI workflow | 1 | Juan Pablo |
| S2-05 | Implement SemVer auto-compute from conventional commits | 3 | Juan Pablo |
| S2-06 | Implement Circuit Breaker (Resilience4j) in auth-service + dashboard-service | 5 | Rony |
| S2-07 | Implement External Configuration pattern via K8s ConfigMaps (4 services) | 3 | Juan Pablo |
| S2-08 | Implement Feature Toggle for K-anonymity in dashboard-service | 2 | Juan Pablo |
| S2-09 | Document all design patterns in `doc/design-patterns.md` | 2 | Rony |
| S2-10 | Fix auth-service OOMKill (raise memory limit 256Mi → 512Mi) | 1 | Rony |
| S2-11 | Deprecate Jenkins/DigitalOcean artifacts (rename to `.deprecated`) | 2 | Juan Pablo |

### In Progress (snapshot mid-sprint, May 21)

- S2-06 Circuit Breaker: `PromotionClient` CB done; `IdentityClient` in review
- S2-07 External Configuration: ConfigMap template written; deployment.yaml wiring pending

### Done (sprint end, May 27)

- ✅ S2-01 — Trivy scan step added; results uploaded as GHA artifact per service build
- ✅ S2-02 — `trivy-gate` job added to `deploy-prod.yml`; blocks on HIGH/CRITICAL; `approve` job depends on it
- ✅ S2-03 — Jacoco plugin applied to all subprojects via root `build.gradle.kts`; XML + HTML reports generated
- ✅ S2-04 — Jacoco artifact uploaded per service build (path: `build/reports/jacoco/`)
- ✅ S2-05 — SemVer computed from conventional commits since last tag; `feat:` → minor, `fix:` → patch, `BREAKING CHANGE:` → major; version passed in `repository_dispatch` payload
- ✅ S2-06 — `@CircuitBreaker` on `IdentityClient.getAnonymousId` (auth-service) + `PromotionClient.getHealthStats/getHealthStatsByDepartment` (dashboard-service); fallback returns safe defaults; sliding window 10 calls / 50% failure threshold / 10s wait
- ✅ S2-07 — `configmap.yaml` template added to auth, form, gateway, dashboard-service charts; `deployment.yaml` updated to `envFrom.configMapRef`
- ✅ S2-08 — `FEATURE_KANONYMITY_ENABLED` env var controls K-anonymity in `AnalyticsService`; default `true`; can be toggled via ConfigMap without redeploy
- ✅ S2-09 — `doc/design-patterns.md` documents 7 patterns (Bulkhead, Retry+Rollback, Event-Driven, Strangler Fig, Ambassador, Sidecar, Circuit Breaker)
- ✅ S2-10 — `services/auth-service/chart/values.yaml` memory limit raised; OOMKill resolved; pod stable
- ✅ S2-11 — All Jenkinsfiles renamed to `.deprecated`; DigitalOcean Terraform modules marked deprecated

### Retrospective

**What went well:**
- Resilience4j Circuit Breaker wired with zero changes to callers — `@CircuitBreaker` annotation + AOP proxy is invisible to service controllers
- ConfigMap pattern decouples non-secret config from pod spec; operators can patch ConfigMap without rolling a new deployment
- SemVer auto-computation from conventional commit history works without a separate release bot

**What to improve:**
- auth-service OOMKill discovered post-deploy, not pre-deploy; next sprint: add memory pressure test to `deploy-stage` before prod gate
- Trivy scan runs after image push (not before); consider multi-stage build with scan-before-push for faster fail
