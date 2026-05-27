# User Stories

Five user stories covering the major feature areas of CircleGuard. Format: role → goal → benefit, with Given/When/Then acceptance criteria.

---

## US-01 — Campus Check-In via QR Code

**Priority:** High  
**Feature area:** Access control / gateway-service  
**Rubric:** Section 1 (Agile), Section 4 (CI/CD — gateway-service pipeline)

**User story:**  
As a **university student**, I want to scan my QR code at the campus gate so that I can enter the campus without revealing my real identity.

### Acceptance Criteria

**AC-01.1 — QR code generation:**
- Given: student is authenticated (valid JWT token from `auth-service`)
- When: student calls `GET /api/v1/auth/qr/generate`
- Then: a short-lived QR token (TTL ≤ 5 minutes) is returned and stored in Redis

**AC-01.2 — Gate validation:**
- Given: campus gate scanner has a valid QR token string
- When: scanner calls `POST /api/v1/gate/validate` with the token
- Then: response is `200 OK` with `{ "access": true }` and the campus door opens

**AC-01.3 — Expired token rejected:**
- Given: QR token has exceeded its TTL (expired from Redis)
- When: scanner calls `POST /api/v1/gate/validate` with the expired token
- Then: response is `401 Unauthorized` with `{ "access": false, "reason": "token_expired" }`

**AC-01.4 — Real identity never transmitted:**
- Given: any request to `gateway-service`
- When: the gate validation succeeds or fails
- Then: no real name, student ID, or email appears in any request/response payload or log

---

## US-02 — Confirm a COVID Case and Trigger Status Promotion

**Priority:** High  
**Feature area:** Health status management / promotion-service  
**Rubric:** Section 5 (Tests — HealthStatusServiceTest), Section 7 (Observability — metrics on promotions triggered)

**User story:**  
As a **health center administrator**, I want to mark a student as CONFIRMED positive so that the system automatically identifies and notifies all individuals in their exposure circles.

### Acceptance Criteria

**AC-02.1 — Mark as CONFIRMED:**
- Given: health center admin has a valid JWT with `ROLE_HEALTH_CENTER`
- When: admin calls `POST /api/v1/health/confirmed` with `{ "anonymousId": "<uuid>" }`
- Then: the user node in Neo4j is updated to status `CONFIRMED` and a `promotion.status.changed` Kafka event is emitted within 5 seconds

**AC-02.2 — Cascade to PROBABLE contacts:**
- Given: user X is marked CONFIRMED and has encounter edges to users A, B, C within the last 14 days
- When: the status promotion graph traversal runs
- Then: users A, B, C are promoted to `PROBABLE` and receive their own `promotion.status.changed` events

**AC-02.3 — Cascade to SUSPECT contacts:**
- Given: user A is promoted to `PROBABLE` and has encounter edges to users D, E within the 14-day window
- When: the recursive traversal reaches the second hop
- Then: users D, E are promoted to `SUSPECT`

**AC-02.4 — Containment speed:**
- Given: a CONFIRMED case is submitted
- When: the graph traversal completes
- Then: all reachable contacts receive their status update within 60 seconds (NFR: containment speed)

**AC-02.5 — Status cache invalidated:**
- Given: a user's status changes
- When: the Neo4j write commits
- Then: the Redis cache entry for that `anonymousId` is invalidated so subsequent reads reflect the new status

---

## US-03 — Submit a Health Survey

**Priority:** High  
**Feature area:** Form submission / form-service → promotion-service pipeline  
**Rubric:** Section 3 (Event-Driven pattern), Section 5 (E2E tests)

**User story:**  
As a **university student**, I want to submit a daily health survey with my current symptoms so that the system can proactively flag me as a potential exposure risk before a confirmed case is reported.

### Acceptance Criteria

**AC-03.1 — Survey submission:**
- Given: student is authenticated (valid JWT)
- When: student calls `POST /api/v1/surveys` with `{ "hasFever": true, "hasCough": true }`
- Then: response is `201 Created` with the survey ID; survey is persisted in PostgreSQL

**AC-03.2 — Kafka event emitted:**
- Given: survey is persisted with `hasSymptoms: true`
- When: `HealthSurveyService.submitSurvey()` completes
- Then: a `survey.submitted` event is emitted to Kafka with `{ anonymousId, hasSymptoms: true, timestamp }`

**AC-03.3 — Promotion-service receives event:**
- Given: `survey.submitted` event is on the Kafka topic
- When: `SurveyListener` in promotion-service processes it
- Then: the student's health status is evaluated for potential escalation to `SUSPECT`

**AC-03.4 — No-symptom survey does not trigger escalation:**
- Given: student submits survey with `hasFever: false, hasCough: false`
- When: promotion-service processes the event
- Then: the student's status remains unchanged (`ACTIVE`)

**AC-03.5 — Anonymous submission:**
- Given: any survey submission
- When: stored in PostgreSQL
- Then: the survey record contains only `anonymousId` (UUID), not real name or student email

---

## US-04 — Receive Exposure Alert Notification

**Priority:** High  
**Feature area:** Notification delivery / notification-service  
**Rubric:** Section 5 (integration tests — promotion → notification flow)

**User story:**  
As a **student who was in contact with a confirmed case**, I want to receive an automated notification as soon as my health status is updated so that I can self-isolate immediately without waiting for a manual call.

### Acceptance Criteria

**AC-04.1 — Notification triggered on status change:**
- Given: a `promotion.status.changed` Kafka event is published with `{ anonymousId, status: "PROBABLE" }`
- When: `ExposureNotificationListener` in notification-service consumes the event
- Then: notification delivery is attempted within 10 seconds of the event being published

**AC-04.2 — Push notification sent:**
- Given: the student has a registered push token
- When: notification-service processes the event
- Then: a push notification is sent via Gotify with message "Your health status has been updated to PROBABLE. Please self-isolate."

**AC-04.3 — Email notification sent:**
- Given: the student has a registered email address (via identity-service)
- When: notification-service processes the event
- Then: an email is dispatched via SMTP (Mailhog in dev) with exposure guidance

**AC-04.4 — Notification failure does not block status promotion:**
- Given: Gotify push server is unavailable
- When: notification-service attempts push delivery
- Then: the failure is logged but does NOT cause a retry that blocks or reverts the status promotion in promotion-service

**AC-04.5 — No real identity in notification payload:**
- Given: any notification dispatched by notification-service
- When: notification content is constructed
- Then: the notification body contains only guidance text and status label, not the student's real name or contact details

---

## US-05 — View Anonymized Analytics Dashboard

**Priority:** Medium  
**Feature area:** Analytics / dashboard-service  
**Rubric:** Section 3 (Externalized Config, Graceful Degradation patterns), Section 5 (dashboard E2E tests)

**User story:**  
As a **health center analyst**, I want to view aggregated campus health trends by location and time so that I can identify outbreak hotspots and allocate health resources proactively.

### Acceptance Criteria

**AC-05.1 — Campus health board:**
- Given: analyst is authenticated with `ROLE_HEALTH_CENTER`
- When: analyst calls `GET /api/v1/analytics/health-board`
- Then: response includes aggregated counts of `ACTIVE`, `SUSPECT`, `PROBABLE`, `CONFIRMED`, `RECOVERED` statuses campus-wide

**AC-05.2 — Department stats with k-anonymity:**
- Given: analyst requests `GET /api/v1/analytics/department/{department}`
- When: the count of individuals in that department is below the k-anonymity threshold (k=5)
- Then: the endpoint returns `{ "suppressed": true }` instead of the raw count, preventing individual re-identification

**AC-05.3 — Time series data:**
- Given: analyst calls `GET /api/v1/analytics/time-series?period=hourly&limit=24`
- When: dashboard-service queries its data source
- Then: response includes 24 hourly data points with entry counts and status distributions

**AC-05.4 — Graceful degradation when promotion-service is down:**
- Given: `promotion-service` is unavailable (e.g., rolling deploy in progress)
- When: dashboard-service calls `PromotionClient.getHealthStats()`
- Then: dashboard-service returns a valid response with zero/empty stats rather than a `500` error

**AC-05.5 — No raw identity data exposed:**
- Given: any analytics endpoint in dashboard-service
- When: any response is returned
- Then: no `anonymousId` UUIDs, no raw counts below k=5, and no real names appear in the response body
