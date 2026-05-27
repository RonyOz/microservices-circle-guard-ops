# Design Patterns

CircleGuard implements six design patterns across its microservices and DevOps infrastructure. Three are infrastructure/ops patterns; three are application-level patterns.

---

## Pattern 1 — Bulkhead

**Category:** Resilience  
**Where implemented:** Kubernetes namespace isolation (`microservices-circle-guard-ops`)

### Purpose

The Bulkhead pattern isolates failures to a compartment so they cannot cascade to other parts of the system. Named after ship bulkheads that prevent flooding from sinking the entire vessel.

### Implementation

CircleGuard deploys the same 8 microservices into three independent Kubernetes namespaces — `dev`, `stage`, and `production` — on a shared EKS cluster. Each namespace is a Bulkhead:

- A failing deploy in `stage` cannot affect `production` pods
- Resources (CPU, memory) are bounded per namespace via `ResourceQuota` and container `limits` in each Helm chart
- Secrets are isolated: each namespace syncs from its own AWS Secrets Manager path (`circleguard/dev`, `circleguard/stage`, `circleguard/production`)
- Network isolation: pods in `dev` cannot address pods in `production` by default

**Relevant files:**
- `infrastructure/chart/values.yaml` — resource limits per service
- `.github/workflows/deploy-dev.yml`, `deploy-stage.yml`, `deploy-prod.yml` — separate deploy pipelines per namespace
- `terraform/aws/modules/irsa-secrets/main.tf` — one Secrets Manager secret per namespace

### Benefits

- Production deployments are unaffected by broken dev/stage deploys
- Allows aggressive experimentation in `dev` without risk
- Independent scaling per environment

---

## Pattern 2 — Retry with Atomic Rollback

**Category:** Resilience  
**Where implemented:** `deploy-prod.yml` GitHub Actions workflow (`microservices-circle-guard-ops`)

### Purpose

When a deployment fails (health checks do not pass), automatically retry rolling back to the last known-good state rather than leaving the cluster in a partial or broken state.

### Implementation

Production deploys use `helm upgrade --atomic`:

```yaml
# .github/workflows/deploy-prod.yml
- name: Deploy to production
  run: |
    helm upgrade --install ${{ github.event.client_payload.service }} \
      services/${{ github.event.client_payload.service }}/chart/ \
      --namespace production \
      --atomic \          # ← key: rollback automatically on failure
      --wait \
      --timeout 10m
```

`--atomic` means: if any pod fails its liveness/readiness probes within the timeout, Helm rolls back to the previous revision automatically and exits with a non-zero code, which fails the GHA job and triggers the failure notification step.

Additionally, all Helm charts define startup, liveness, and readiness probes on `/actuator/health/liveness` and `/actuator/health/readiness`, giving Kubernetes the health signals needed to detect a bad deploy quickly.

**Relevant files:**
- `.github/workflows/deploy-prod.yml` — `--atomic` flag
- `services/<service>/chart/values.yaml` — liveness/readiness/startup probe config

### Benefits

- Zero manual intervention on bad production deploys
- Cluster never left in degraded state
- Pairs with Conventional Commits + git-cliff to produce a clear audit trail per release

---

## Pattern 3 — Event-Driven / Publish-Subscribe

**Category:** Architecture  
**Where implemented:** `circleguard-form-service`, `circleguard-promotion-service`, `circleguard-notification-service` (`microservices-circle-guard-dev`)

### Purpose

Decouple producers from consumers using an event bus. Producers emit domain events without knowing who consumes them; consumers react independently and can be added without modifying producers.

### Implementation

Apache Kafka (deployed in-cluster via `infrastructure/chart/`) serves as the event bus. Two primary event flows:

**Flow 1 — Health Survey → Status Promotion:**
```
form-service (producer)
  topic: survey.submitted
  payload: { anonymousId, hasSymptoms, timestamp }
       ↓
promotion-service (consumer, group: promotion-service-group)
  SurveyListener → triggers status evaluation
```

**Flow 2 — Status Change → Notification:**
```
promotion-service (producer)
  HealthStatusService.updateStatus()
  topic: promotion.status.changed
  payload: { anonymousId, status, timestamp }
       ↓
notification-service (consumer)
  ExposureNotificationListener → push + email + SMS
```

**Relevant files:**
- `services/circleguard-form-service/src/main/java/…/service/HealthSurveyService.java` — Kafka producer
- `services/circleguard-promotion-service/src/main/java/…/listener/SurveyListener.java` — consumer
- `services/circleguard-promotion-service/src/main/java/…/service/HealthStatusService.java` — producer
- `services/circleguard-notification-service/src/main/java/…/listener/ExposureNotificationListener.java` — consumer
- `infrastructure/chart/templates/kafka.yaml` — Kafka StatefulSet

### Benefits

- Services are loosely coupled: adding a new consumer (e.g., audit logger) requires zero changes to the producer
- Notification failures do not block the status promotion pipeline
- Kafka's persistence allows replaying events for debugging or new consumer onboarding

---

## Pattern 4 — API Gateway

**Category:** Structural  
**Where implemented:** `circleguard-gateway-service` (`microservices-circle-guard-dev`)

### Purpose

A single entry point that enforces cross-cutting concerns (authentication, rate limiting, token validation) before requests reach internal services. External clients talk to the gateway, never directly to backend services.

### Implementation

`gateway-service` (port 8086) exposes one critical validation endpoint:

```
POST /api/v1/gate/validate
  → QrValidationService reads token from Redis cache
  → validates token signature + expiry
  → returns access granted / denied
```

The QR token lifecycle:
1. Student authenticates via `auth-service` → JWT issued
2. Student requests short-lived QR token → `auth-service` writes token to Redis (TTL: 5 min)
3. Campus gate scanner calls `gateway-service /api/v1/gate/validate`
4. Gateway reads Redis, validates, responds — `auth-service` and `identity-service` are never exposed to the scanner

**Relevant files:**
- `services/circleguard-gateway-service/src/main/java/…/controller/GateController.java`
- `services/circleguard-gateway-service/src/main/java/…/service/QrValidationService.java`
- `services/circleguard-auth-service/src/main/java/…/controller/QrTokenController.java` — token generator
- `infrastructure/chart/templates/redis.yaml` — Redis for token cache

### Benefits

- Campus gate hardware has a single, minimal API surface to call
- Token validation logic centralized; changing the algorithm requires updating one service
- Redis TTL enforces automatic token expiry without explicit revocation logic

---

## Pattern 5 — Externalized Configuration

**Category:** Configuration  
**Where implemented:** AWS Secrets Manager + External Secrets Operator + IRSA (`microservices-circle-guard-ops`)

### Purpose

Store configuration (especially secrets) outside the application artifact. The application reads its configuration at startup from an external store, not from the Docker image or source code. This enables secret rotation without rebuilding images and prevents secrets from leaking into git history.

### Implementation

Three-layer externalized configuration chain:

```
AWS Secrets Manager
  secret: circleguard/dev
  value:  { DB_USERNAME, DB_PASSWORD, NEO4J_USERNAME, NEO4J_PASSWORD, JWT_SECRET }
       ↓ (ESO polls every 1h via IRSA)
External Secrets Operator
  ExternalSecret CR per service in each namespace
       ↓ (creates/updates)
Kubernetes Secret: <service>-secret
       ↓ (mounted by pod)
Spring Boot application
  envFrom:
    - secretRef:
        name: <service>-secret
  → ${DB_PASSWORD}, ${JWT_SECRET} resolved at runtime
```

Non-secret configuration (DB host, service URLs, port) uses Kubernetes ConfigMap-equivalent via Helm chart `env:` values — also external to the image.

**Relevant files:**
- `.github/workflows/bootstrap-eso.yml` — installs ESO, creates ClusterSecretStore + ExternalSecrets
- `infrastructure/chart/templates/external-secrets.yaml` — ExternalSecret per service
- `infrastructure/chart/templates/secret-store.yaml` — ClusterSecretStore (AWS Secrets Manager provider)
- `terraform/aws/modules/irsa-secrets/main.tf` — IAM role for ESO + SM secrets
- `services/<service>/chart/templates/deployment.yaml` — `envFrom.secretRef`
- `docs/secrets-management.md` — full chain documentation

### Benefits

- Zero secrets in Docker images or Helm chart values committed to git
- Secret rotation in AWS Secrets Manager propagates to pods within 1 hour (ESO refresh interval) without redeployment
- Audit trail in AWS CloudTrail for every secret access

---

## Pattern 6 — Graceful Degradation / Fallback

**Category:** Resilience  
**Where implemented:** `circleguard-dashboard-service` (`microservices-circle-guard-dev`)

### Purpose

When a downstream service is unavailable, return a safe default response instead of propagating the error to the user. The system degrades gracefully — partial functionality is better than a 500 error.

### Implementation

`dashboard-service` calls `promotion-service` via HTTP (RestTemplate) to fetch health statistics. If `promotion-service` is down or returns an error, `PromotionClient` catches the exception and returns an empty map:

```java
// services/circleguard-dashboard-service/src/main/java/…/client/PromotionClient.java
public Map<String, Object> getHealthStats() {
    try {
        return restTemplate.getForObject(
            promotionServiceUrl + "/api/v1/health-status/stats",
            Map.class
        );
    } catch (Exception e) {
        log.warn("promotion-service unavailable: {}", e.getMessage());
        return Collections.emptyMap();   // ← fallback: empty stats, not 500
    }
}
```

`AnalyticsService` handles the empty map gracefully — the dashboard renders with zero values rather than crashing. The k-anonymity filter (k=5) in `AnalyticsService` also protects against small-group data leakage in department stats.

**Relevant files:**
- `services/circleguard-dashboard-service/src/main/java/…/client/PromotionClient.java`
- `services/circleguard-dashboard-service/src/main/java/…/service/AnalyticsService.java`

### Benefits

- Dashboard remains operational even during promotion-service maintenance or rolling deploys
- Users see "no data available" rather than an error page
- Establishes the pattern for adding full Resilience4j circuit breakers in a future iteration

---

## Pattern Summary

| # | Pattern | Type | Services/Files involved |
|---|---------|------|------------------------|
| 1 | Bulkhead | Resilience (ops) | K8s namespaces, Helm charts, GHA deploy workflows |
| 2 | Retry + Atomic Rollback | Resilience (ops) | `deploy-prod.yml` (`--atomic`), Helm probes |
| 3 | Event-Driven Pub/Sub | Architecture | Kafka, form-service, promotion-service, notification-service |
| 4 | API Gateway | Structural | gateway-service, auth-service (QR token), Redis |
| 5 | Externalized Configuration | Configuration | AWS SM, ESO, IRSA, K8s Secrets, Spring `envFrom` |
| 6 | Graceful Degradation | Resilience (app) | dashboard-service `PromotionClient` |
