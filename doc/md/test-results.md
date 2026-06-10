# CircleGuard — Informe Consolidado de Resultados de Pruebas

**Proyecto:** Proyecto Final IngeSoft V
**Última verificación:** 2026-06-09
**Alcance:** 8 microservicios Spring Boot + app móvil (Expo)

Este documento consolida la **calidad y cobertura de pruebas** del sistema (Enunciado §5
y §9). El análisis de rendimiento detallado vive en
[`performance-analysis.md`](./performance-analysis.md); aquí se resume.

---

## 1. Resumen ejecutivo

| Dimensión | Estado | Evidencia |
|-----------|--------|-----------|
| Cobertura unitaria (línea) | ✅ ≥60% en los 8 servicios | §2 (medido 2026-06-09) |
| Pruebas de integración servicio-a-servicio | ✅ 5 escenarios | §3 |
| Pruebas E2E | ✅ 9 por servicio + 5 flujos cross-service | §4 |
| Rendimiento y estrés (Locust) | ✅ corrida real, 0% error | §5 |
| Seguridad (OWASP ZAP) | ✅ baseline en pipeline stage | §6 |
| Escaneo de vulnerabilidades (Trivy) | ✅ CI + gate prod | §6 |
| Reportes en CI (Jacoco, Sonar) | ✅ artefactos por run | §7 |

---

## 2. Cobertura de pruebas unitarias (Jacoco)

Medición real ejecutando `./gradlew test jacocoTestReport` (2026-06-09).
Reportes XML/HTML por servicio en `build/reports/jacoco/test/`.

| Servicio | Cobertura de línea | Cobertura de rama | ≥60% línea |
|----------|-------------------:|------------------:|:----------:|
| gateway-service | 100.0 % | 83.3 % | ✅ |
| dashboard-service | 91.8 % | 94.7 % | ✅ |
| auth-service | 91.7 % | 46.4 % | ✅ |
| file-service | 87.5 % | 0.0 % | ✅ |
| form-service | 83.3 % | 5.2 % | ✅ |
| identity-service | 78.5 % | 3.5 % | ✅ |
| notification-service | 74.4 % | 80.0 % | ✅ |
| promotion-service | 62.6 % | 10.8 % | ✅ |

**Quality Gate SonarCloud** (`CircleGuard Gate`): cobertura ≥ 60 % en código nuevo →
los 8 servicios cumplen por línea.

**Exclusiones de cobertura** (en `build.gradle.kts`): clases `*Application`, `config/**`,
`configuration/**` — boilerplate de Spring Boot sin lógica de negocio testeable.

> **Observación honesta — cobertura de rama:** varios servicios tienen rama baja
> (file 0 %, identity 3.5 %, form 5.2 %, promotion 10.8 %). El gate es por **línea**
> (cumple), pero la cobertura de ramas/condicionales es un área de mejora: los tests
> ejercitan el camino feliz más que las bifurcaciones de error. promotion-service mide
> con Testcontainers (requiere Docker); en runners de CI con Docker corre completo.

---

## 3. Pruebas de integración (servicio-a-servicio)

5 escenarios que verifican contratos entre servicios con dependencias reales o emuladas
(WireMock para HTTP, EmbeddedKafka para eventos):

| # | Test | Servicios | Mecanismo |
|---|------|-----------|-----------|
| 1 | `IdentityClientIntegrationTest` | auth → identity | WireMock + Circuit Breaker (verifica fallback) |
| 2 | `PromotionClientIntegrationTest` | dashboard → promotion | WireMock (contrato REST) |
| 3 | `HealthSurveyKafkaIntegrationTest` | form → promotion | EmbeddedKafka (publish de encuesta) |
| 4 | `SurveyListenerKafkaIntegrationTest` | form → promotion | EmbeddedKafka (consume del listener) |
| 5 | `ExposureNotificationListenerIntegrationTest` | promotion → notification | EmbeddedKafka (cascada de notificación) |

Además, `promotion-service` corre tests de integración con **Testcontainers**
(Neo4j 5 + PostgreSQL 16 reales, `AbstractIntegrationTest` como base).

**Inventario total de archivos de test:** 49 (`*Test.java`):
auth 9 · promotion 13 · form 8 · notification 6 · dashboard 4 · identity 4 · gateway 3 · file 2.
Móvil: `mobile/__tests__/sanity.test.js` (Jest).

---

## 4. Pruebas E2E

**Por servicio:** scripts curl en `e2e/<service>/e2e.sh` para los 9 servicios (8 backend +
mobile) — smoke de health + al menos un endpoint funcional cada uno.

**Cross-service** (`e2e/cross-service/e2e.sh`) — 5 flujos completos de usuario:

| Flujo | Recorrido | Verifica |
|-------|-----------|----------|
| 1 | Autenticación + generación de QR token | login válido → token QR no vacío |
| 2 | Anonimización de identidad (auth → identity) | mapa devuelve `anonymousId` (nunca nombre real) |
| 3 | Envío de encuesta de salud (auth → form) | encuesta persiste (HTTP 2xx) |
| 4 | Validación de entrada por QR (auth → gateway) | gate valida token en Redis |
| 5 | Analítica dashboard + K-anonimato (auth → dashboard) | stats agregadas con filtro k≥5 |

Ejecutados automáticamente en `deploy-stage.yml` (puerto-forward al namespace `stage`).
Cada flujo reporta `PASS`/`FAIL`/`SKIP` con conteo final.

---

## 5. Rendimiento y estrés (Locust) — resumen

Corrida real (2026-06-06, 50 usuarios / spawn 10 / 60 s, local). CSV en `locust/results/`.

| Servicio | Reqs | Errores | RPS/réplica | p50 | p95 | p99 |
|----------|-----:|--------:|------------:|----:|----:|----:|
| file-service (agregado) | 9 399 | 0 (0 %) | 159.1 | 2 ms | 4 ms | 6 ms |
| gateway-service (agregado) | 9 379 | 0 (0 %) | 158.8 | 4 ms | 8 ms | 10 ms |

**Lectura:** ~159 RPS por réplica con **0 % de error** y p95 de un dígito en ms — 2-3
órdenes de magnitud bajo los SLO modelados. El overhead de Redis (rate-limiter sliding
window de gateway) es medible (~3-4 ms p95 vs file-service) pero despreciable.

Modelo de carga, SLOs por endpoint, plan de estrés (ramp a 500 usuarios) e interpretación
en Grafana: ver [`performance-analysis.md`](./performance-analysis.md) §2–§6.
Locust corre también en `deploy-stage.yml` (10 users/30 s, informativo, no bloquea).

---

## 6. Pruebas de seguridad

| Herramienta | Dónde | Modo |
|-------------|-------|------|
| **OWASP ZAP** (baseline) | `deploy-stage.yml` → `zaproxy/action-baseline@v0.12.0` | reporte HTML como artefacto; reglas en `.zap/rules.tsv`; `continue-on-error` |
| **Trivy** (imágenes) | `_reusable-service-ci.yml` (CI) | SARIF informativo |
| **Trivy gate** | `deploy-prod.yml` | **bloquea** en HIGH/CRITICAL con fix (`exit-code: 1`) |

---

## 7. Reportes y automatización en CI

| Reporte | Generación | Publicación |
|---------|-----------|-------------|
| Cobertura Jacoco (HTML/XML) | `jacocoTestReport` por servicio | artefacto GHA por run |
| Quality Gate SonarCloud | `./gradlew sonar` en CI reutilizable | gate `qualitygate.wait=true` |
| Reporte Trivy (SARIF) | tras build de imagen | artefacto GHA |
| Reporte OWASP ZAP (HTML) | stage deploy | artefacto GHA |
| Reporte Locust (HTML/CSV) | stage deploy | artefacto GHA |

Todos se ejecutan automáticamente en los pipelines (Enunciado §5.7 — ejecución
automatizada en pipelines). ✅

---

## 8. Brechas conocidas y mejoras propuestas

- **Cobertura de rama baja** en file/identity/form/promotion — añadir tests de caminos de
  error (validaciones, excepciones) para subir branch coverage por encima de ~50 %.
- **Mobile** sólo tiene un test de sanidad — ampliar a componentes/pantallas clave.
- **Locust** medido localmente para 2 servicios; el run contra EKS (stage) cubre el resto
  pero no se ha capturado un informe de carga sostenida (5 min) contra el clúster.
- **Tests de estrés / punto de quiebre** (§3 de performance-analysis) están diseñados pero
  no ejecutados — pendiente una corrida de ramp-up documentada.

---

*Cobertura y conteos verificados localmente el 2026-06-09 contra el código actual.*
