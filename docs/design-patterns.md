# Design Patterns — CircleGuard

Cloud design patterns implemented across the CircleGuard microservices platform.

---

## 1. Circuit Breaker

**Pattern:** Resilience  
**Services:** `auth-service`  
**Library:** Resilience4j 2.2.0

Prevents cascading failures when `identity-service` is unavailable. The breaker wraps outbound HTTP calls from `auth-service` to `identity-service`. If the failure rate exceeds the threshold, the circuit opens and subsequent calls fail-fast with a fallback response instead of waiting for a timeout.

**Implementation:**
- `services/circleguard-auth-service/src/main/java/com/circleguard/auth/client/IdentityClient.java`
- Annotation: `@CircuitBreaker(name = "identityService", fallbackMethod = "...")`
- Three states: CLOSED → OPEN (fail fast) → HALF-OPEN (probe recovery)

**Configuration** (via External Config Store — see §3):
```yaml
resilience4j.circuitbreaker.instances.identityService:
  failure-rate-threshold: ${CIRCUIT_BREAKER_FAILURE_RATE:50}      # % failures to open
  wait-duration-in-open-state: ${CIRCUIT_BREAKER_WAIT_DURATION:10s}
  sliding-window-size: ${CIRCUIT_BREAKER_SLIDING_WINDOW_SIZE:10}
```

Health indicator exposed at `/actuator/health` (`management.health.circuitbreakers.enabled: true`).

---

## 2. Event-Driven / Publisher-Subscriber

**Pattern:** Messaging  
**Services:** `promotion-service` → `notification-service`, `form-service`  
**Broker:** Apache Kafka

Health status changes (Healthy → Suspect → Probable → Confirmed) are published as events on Kafka topics. `notification-service` subscribes to receive alerts; `dashboard-service` subscribes for aggregate updates. Publishers and subscribers are fully decoupled — neither knows the other exists.

**Implementation:**
- Producer: `promotion-service` — publishes `HealthStatusChangedEvent` on `health-status-changes` topic
- Consumer: `notification-service` — `@KafkaListener(topics = "health-status-changes")`
- Consumer: `dashboard-service` — separate consumer group, independent processing

---

## 3. Bulkhead

**Pattern:** Resilience  
**Services:** `auth-service`  
**Library:** Resilience4j — `BulkheadRegistry`

Isolates the thread pool used for `identity-service` calls from the general request-handling pool. If identity-service calls block and exhaust their dedicated pool, the rest of auth-service continues handling login and token operations.

---

## 4. Retry

**Pattern:** Resilience  
**Services:** `auth-service`, `promotion-service`  
**Library:** Resilience4j — `@Retry`

Wraps transient failures (network blips, temporary service unavailability) with exponential backoff. Combined with Circuit Breaker: Retry handles occasional failures; Circuit Breaker handles systematic ones.

---

## 5. External Configuration Store

**Pattern:** Configuration  
**Services:** `auth-service`, `gateway-service` (and all 8 services via Helm env injection)  
**Store:** Kubernetes ConfigMap (populated from Helm `values.yaml`)

All environment-specific configuration lives in `services/<name>/chart/values.yaml` and is injected into pods as `envFrom: configMapRef`. The application image contains **no** environment-specific values — parameters are resolved at pod startup from the ConfigMap.

This implements the 12-Factor App §III (Config) principle: configuration is stored in the environment, not the code.

**How it works:**

```
Helm values.yaml                  K8s ConfigMap                  Spring application.yml
────────────────────────────────────────────────────────────────────────────────────────
RATE_LIMIT_REQUESTS_PER_WINDOW: 60 ──→ ConfigMap data key/value ──→ ${RATE_LIMIT_REQUESTS_PER_WINDOW:60}
CIRCUIT_BREAKER_FAILURE_RATE: 50   ──→ ConfigMap data key/value ──→ ${CIRCUIT_BREAKER_FAILURE_RATE:50}
JWT_EXPIRATION_MS: 3600000         ──→ ConfigMap data key/value ──→ ${JWT_EXPIRATION_MS:3600000}
```

**To change a parameter without rebuilding the image:**
```bash
helm upgrade gateway-service services/gateway-service/chart/ \
  --set env.RATE_LIMIT_REQUESTS_PER_WINDOW=120 \
  --reuse-values
```

**Configurable parameters by service:**

| Service | Parameter | Default | Effect |
|---------|-----------|---------|--------|
| gateway-service | `RATE_LIMIT_REQUESTS_PER_WINDOW` | 60 | Requests allowed per window |
| gateway-service | `RATE_LIMIT_WINDOW_SECONDS` | 60 | Sliding window duration |
| gateway-service | `QR_EXPIRATION_SECONDS` | 300 | QR token TTL |
| auth-service | `CIRCUIT_BREAKER_FAILURE_RATE` | 50 | % failures to open breaker |
| auth-service | `CIRCUIT_BREAKER_WAIT_DURATION` | 10s | Open state wait before probe |
| auth-service | `CIRCUIT_BREAKER_SLIDING_WINDOW_SIZE` | 10 | Calls counted for failure rate |
| auth-service | `JWT_EXPIRATION_MS` | 3600000 | JWT token lifetime (ms) |

---

## 6. Rate Limiting (Throttling)

**Pattern:** Control / Resilience  
**Service:** `gateway-service`  
**Store:** Redis (sliding window via sorted set)

Protects the QR validation endpoint from abuse and denial-of-service. Each client IP is tracked in a Redis sorted set keyed `rl:<ip>`. The sliding window implementation prunes stale entries before counting, providing accurate per-IP rate limiting across multiple pod replicas.

**Implementation:** `services/circleguard-gateway-service/src/main/java/com/circleguard/gateway/interceptor/RateLimitInterceptor.java`

**Algorithm — Sliding Window (Redis ZSET):**
```
1. ZREMRANGEBYSCORE rl:<ip>  0  (now - windowMs)   # remove expired entries
2. ZADD rl:<ip>  <now>  <uuid>                      # record this request
3. EXPIRE rl:<ip>  windowSeconds+1                  # auto-cleanup
4. ZCARD rl:<ip>  → count
5. if count > limit → HTTP 429 + Retry-After header
```

Advantages over fixed-window: no burst allowed at window boundaries; count reflects actual requests in the last N seconds regardless of clock alignment.

**Response when limit exceeded:**
```http
HTTP 429 Too Many Requests
Retry-After: 60
Content-Type: application/json

{"error":"Too Many Requests","retryAfter":60}
```

**Configuration** (via External Config Store — see §5):
```yaml
# gateway-service/chart/values.yaml
env:
  RATE_LIMIT_REQUESTS_PER_WINDOW: "60"   # max requests per window
  RATE_LIMIT_WINDOW_SECONDS: "60"        # window size in seconds
```

**Relationship with other patterns:**
- Rate Limiting sits at the **Gatekeeper** entry point (gateway-service is the only public-facing service)
- Circuit Breaker protects downstream services; Rate Limiting protects the gateway itself
- Clients should implement Retry with Retry-After respect to avoid amplifying load

---

## 7. Cache Aside

**Pattern:** Performance  
**Service:** `gateway-service`  
**Store:** Redis

QR token validation reads the user's current health status from Redis (cache). The `promotion-service` writes the health status to Redis whenever a promotion event is processed. The gateway never queries PostgreSQL or Neo4j directly for the hot validation path — Redis is the read cache.

Cache key: `user:status:<anonymousId>` | TTL: managed by promotion-service on write.

---

## 8. Gateway Aggregation / Gatekeeper

**Pattern:** API / Security  
**Service:** `gateway-service`

`gateway-service` is the single entry point for physical access control (QR scanning at campus gates). It:
1. Validates the QR JWT signature
2. Checks health status from Redis cache
3. Returns a binary GREEN/RED access decision

Backend services (identity, promotion, dashboard) are unreachable from outside the cluster — only reachable via ClusterIP from within the K8s namespace.

---

## Pattern Dependency Map

```
[Client / Scanner]
       │
       ▼
[gateway-service] ──Rate Limiting──▶ HTTP 429 if over limit
       │
       ├── Cache Aside ──▶ Redis (health status)
       │
       └── Gatekeeper ──▶ binary access decision
               │
[auth-service] ──Circuit Breaker──▶ [identity-service]
       │              Retry
       │
[promotion-service] ──Pub/Sub──▶ Kafka ──▶ [notification-service]
       │                                 ──▶ [dashboard-service]
       └── External Config Store ◀── K8s ConfigMap ◀── values.yaml
```
