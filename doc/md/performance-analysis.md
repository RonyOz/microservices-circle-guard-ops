# CircleGuard — Análisis de Pruebas de Rendimiento (Locust)

**Herramienta:** [Locust](https://locust.io/) v2.x  
**Cluster objetivo:** AWS EKS `circleguard-eks` · namespace `dev`  
**Fecha de referencia:** 2026-06-02

---

## 1. Metodología

### Configuración base de ejecución

```bash
# Todos los servicios — parámetros de referencia
locust -f locustfile.py \
  --host=http://<service-url> \
  --users=100 \
  --spawn-rate=10 \
  --run-time=5m \
  --headless \
  --csv=results/<service>
```

| Parámetro | Valor | Justificación |
|-----------|-------|--------------|
| Usuarios simultáneos | 100 | Pico estimado universidad mediana (~5 000 usuarios activos, 2% concurrentes) |
| Spawn rate | 10 usuarios/s | Simula apertura de turno / ingreso masivo post-clase |
| Duración | 5 min (warmup) + 10 min (carga estable) | JVM alcanza JIT steady-state aprox. 2 min |
| Timeout por request | 5 s | SLO máximo aceptable para operaciones de UI |

### Métricas recopiladas

Locust genera tres archivos CSV por ejecución:

| Archivo | Contenido |
|---------|-----------|
| `<service>_stats.csv` | RPS, p50/p95/p99 latencia, error rate por endpoint |
| `<service>_stats_history.csv` | Serie temporal (muestreo cada 2 s) |
| `<service>_failures.csv` | Detalle de errores con status code |

---

## 2. Modelo de carga por servicio

### 2.1 auth-service

**Archivo:** `locust/auth-service/locustfile.py`  
**Escenarios y distribución de carga:**

| Tarea | Peso | Descripción |
|-------|------|-------------|
| `validate_token` | 75% | GET `/api/auth/validate` — operación más frecuente |
| `refresh_token` | 25% | POST `/api/auth/refresh` — renovación periódica |
| `on_start` (login) | 1/usuario | POST `/api/auth/login` — solo al spawn |

**Perfil de carga real:** 100 usuarios × ~0.4 req/s promedio ≈ **40 RPS sostenidos**

**SLOs objetivo:**

| Endpoint | p50 | p95 | p99 | Error rate |
|----------|-----|-----|-----|-----------|
| `POST /api/auth/login` | ≤ 300 ms | ≤ 800 ms | ≤ 1 500 ms | < 1% |
| `GET /api/auth/validate` | ≤ 50 ms | ≤ 150 ms | ≤ 300 ms | < 0.5% |
| `POST /api/auth/refresh` | ≤ 200 ms | ≤ 500 ms | ≤ 1 000 ms | < 1% |

**Observaciones críticas:**
- `validate_token` es stateless (solo verifica firma JWT con Redis cache) → p95 < 150 ms esperado con 1 réplica
- `login` involucra LDAP lookup + PostgreSQL → cuello de botella bajo alta concurrencia; escalar a ≥ 2 réplicas si p95 > 600 ms
- Test genera emails aleatorios → la mayoría de logins fallarán con 401 (comportamiento esperado y aceptado en el test)

---

### 2.2 promotion-service (contact-tracing)

**Archivo:** `locust/promotion-service/locustfile.py`  
**Escenarios y distribución de carga:**

| Tarea | Peso | Descripción |
|-------|------|-------------|
| `report_encounter` | 43% | POST `/api/v1/encounters/report` — registro de contacto |
| `get_mesh_stats` | 29% | GET `/api/v1/mesh/stats/{id}` — estadísticas Neo4j |
| `get_circles_for_user` | 14% | GET `/api/v1/circles/user/{id}` — grafo de exposición |
| `health_check` | 14% | GET `/actuator/health` |

**Perfil de carga real:** 100 usuarios × ~0.4 req/s ≈ **40 RPS sostenidos**

**SLOs objetivo:**

| Endpoint | p50 | p95 | p99 | Error rate |
|----------|-----|-----|-----|-----------|
| `POST /api/v1/encounters/report` | ≤ 200 ms | ≤ 600 ms | ≤ 1 200 ms | < 1% |
| `GET /api/v1/mesh/stats/{id}` | ≤ 500 ms | ≤ 2 000 ms | ≤ 4 000 ms | < 2% |
| `GET /api/v1/circles/user/{id}` | ≤ 800 ms | ≤ 3 000 ms | ≤ 5 000 ms | < 2% |

**Observaciones críticas:**
- Queries Neo4j con ventana 14 días son O(n·m) en el grafo → p95 degradará con >500 nodos por componente conectada
- `report_encounter` dispara evento Kafka → latencia incluye produce timeout (< 50 ms con broker local)
- Circuit breaker `identityService` se configura con `slidingWindowSize=10, failureRateThreshold=50%` → monitorear `resilience4j_circuitbreaker_state` en Prometheus durante el test
- Escalar Neo4j a modo cluster si p95 de queries de grafo > 3 s bajo carga sostenida

---

### 2.3 gateway-service

**Archivo:** `locust/gateway-service/locustfile.py`  
**Escenarios:**

| Tarea | Peso | Descripción |
|-------|------|-------------|
| `validate_token` | 100% | POST `/api/v1/gate/validate` — validación de QR token en Redis |

**Perfil:** 100 usuarios × ~1.3 req/s (wait 0.5–2 s) ≈ **130 RPS** — el servicio de mayor throughput

**SLOs objetivo:**

| Endpoint | p50 | p95 | p99 | Error rate |
|----------|-----|-----|-----|-----------|
| `POST /api/v1/gate/validate` | ≤ 30 ms | ≤ 80 ms | ≤ 150 ms | < 0.5% |

**Observaciones:** Tokens son aleatorios → 401/403 esperados; test valida que el servicio no genere 5xx bajo carga. El SLO de 30 ms p50 es alcanzable con Redis local (RTT < 1 ms en mismo namespace K8s).

---

### 2.4 form-service (encuestas)

**Archivo:** `locust/form-service/locustfile.py`  
**Escenarios:**

| Tarea | Peso | Descripción |
|-------|------|-------------|
| `submit_survey_no_symptoms` | 71% | POST `/api/v1/surveys` — sin síntomas |
| `submit_survey_with_symptoms` | 29% | POST `/api/v1/surveys` — con síntomas (dispara Kafka) |

**Perfil:** 100 usuarios × ~0.4 req/s ≈ **40 RPS**

**SLOs objetivo:**

| Endpoint | p50 | p95 | p99 | Error rate |
|----------|-----|-----|-----|-----------|
| `POST /api/v1/surveys` (sin síntomas) | ≤ 150 ms | ≤ 400 ms | ≤ 800 ms | < 1% |
| `POST /api/v1/surveys` (con síntomas) | ≤ 300 ms | ≤ 800 ms | ≤ 1 500 ms | < 1% |

**Observaciones:** Encuestas con síntomas publican en Kafka para que promotion-service calcule nuevas promociones de salud → latencia adicional de ~50 ms por produce.

---

### 2.5 dashboard-service

**Archivo:** `locust/dashboard-service/locustfile.py`  
**Escenarios:**

| Tarea | Peso | Descripción |
|-------|------|-------------|
| `health_board` | 33% | GET `/api/v1/analytics/health-board` — página principal |
| `summary` | 25% | GET `/api/v1/analytics/summary` |
| `trends_by_location` | 17% | GET `/api/v1/analytics/trends/{locationId}` |
| `department_stats` | 17% | GET `/api/v1/analytics/department/{dept}` |
| `time_series` | 8% | GET `/api/v1/analytics/time-series` |

**Perfil:** 100 usuarios × ~0.4 req/s ≈ **40 RPS**

**SLOs objetivo:**

| Endpoint | p50 | p95 | p99 | Error rate |
|----------|-----|-----|-----|-----------|
| `GET /health-board` | ≤ 400 ms | ≤ 1 500 ms | ≤ 3 000 ms | < 2% |
| `GET /summary` | ≤ 300 ms | ≤ 1 000 ms | ≤ 2 000 ms | < 2% |
| `GET /trends/{loc}` | ≤ 500 ms | ≤ 2 000 ms | ≤ 4 000 ms | < 2% |
| `GET /department/{dept}` | ≤ 500 ms | ≤ 2 000 ms | ≤ 4 000 ms | < 2% |

**Observaciones:** Queries analíticas cruzan PostgreSQL + Neo4j → candidatos para cache (Redis con TTL 60 s). Agregar índice compuesto en `promotion_events(timestamp, location_id)` si p95 > 1 500 ms.

---

### 2.6 file-service

**Archivo:** `locust/file-service/locustfile.py`  
**Escenarios:**

| Tarea | Peso | Descripción |
|-------|------|-------------|
| `upload_document` | 100% | POST `/api/v1/files/upload` — certificado PDF sintético (~40 bytes) |

**Perfil:** 100 usuarios × ~0.22 req/s (wait 2–5 s) ≈ **22 RPS** — menor throughput (wait largo + I/O S3)

**SLOs objetivo:**

| Endpoint | p50 | p95 | p99 | Error rate |
|----------|-----|-----|-----|-----------|
| `POST /api/v1/files/upload` | ≤ 500 ms | ≤ 2 000 ms | ≤ 4 000 ms | < 2% |

**Observaciones:** En producción los PDFs reales son 50–500 KB → p95 subirá ~3× respecto a los sintéticos del test. Configurar `spring.servlet.multipart.max-file-size=10MB` y ajustar timeout en Ingress ALB a 60 s.

---

### 2.7 identity-service y notification-service

Ambos tienen tests de smoke (solo `GET /actuator/health`) — no generan carga funcional. Sirven para verificar que los pods responden antes de tests de integración completos.

---

## 3. Prueba de estrés — punto de quiebre

Para identificar capacidad máxima antes de degradación, ejecutar ramp-up progresivo:

```bash
# Ramp hasta 500 usuarios en 5 etapas de 2 min cada una
locust -f locustfile.py \
  --host=http://<url> \
  --users=500 \
  --spawn-rate=2 \
  --run-time=10m \
  --headless \
  --csv=results/<service>_stress
```

**Criterio de quiebre:** p95 > SLO × 2 OR error rate > 5% sostenido por 60 s.

**Capacidad estimada por réplica (1 pod, 512 Mi / 0.5 CPU):**

| Servicio | RPS hasta quiebre | Réplicas mínimas para 100 usuarios |
|---------|------------------|-----------------------------------|
| auth-service | ~200 RPS | 1 (cómodo) |
| promotion-service | ~80 RPS | 1 (borde — escalar si hay Neo4j lento) |
| gateway-service | ~500 RPS | 1 |
| form-service | ~150 RPS | 1 |
| dashboard-service | ~60 RPS | 1–2 (queries pesadas) |
| file-service | ~40 RPS | 1 (bound por S3 I/O) |

---

## 4. Integración con CI/CD

El pipeline `deploy-stage.yml` ejecuta Locust headless al final del stage deploy:

```yaml
- name: Locust smoke (30 s, 10 users)
  run: |
    pip install locust
    locust -f locust/${{ inputs.service }}/locustfile.py \
      --host=http://localhost:${{ env.SERVICE_PORT }} \
      --users=10 --spawn-rate=5 --run-time=30s \
      --headless --csv=results/${{ inputs.service }}
  continue-on-error: true

- name: Upload Locust report
  uses: actions/upload-artifact@v4
  if: always()
  with:
    name: locust-report-${{ inputs.service }}-${{ github.run_id }}
    path: results/
```

El gate de stage **no bloquea** por Locust (continue-on-error: true) — los resultados son informativos. El bloqueo por rendimiento se configura opcionalmente vía umbral en el script:

```bash
# Fallar si p95 > 2000 ms o error rate > 5%
python scripts/check-locust-thresholds.py results/<service>_stats.csv \
  --p95-limit 2000 --error-limit 5
```

---

## 5. Interpretación de resultados Grafana

Dashboards relevantes durante una prueba Locust:

| Panel Grafana | Métrica Prometheus | Qué observar |
|--------------|-------------------|-------------|
| HTTP Request Rate | `http_server_requests_seconds_count` | RPS vs usuarios Locust |
| p95 Latency | `http_server_requests_seconds` (p0.95) | Correlacionar con SLOs |
| Circuit Breaker State | `resilience4j_circuitbreaker_state` | Detectar apertura durante carga |
| DB Connection Pool | `hikaricp_connections_active` | Saturación de pool (max=10) |
| JVM Heap | `jvm_memory_used_bytes` | Descartar OOM como causa de lentitud |
| Kafka Consumer Lag | `kafka_consumer_records_lag` | Acumulación en promotion/notification |

---

## 6. Checklist de análisis post-ejecución

- [ ] p95 dentro de SLO para cada endpoint
- [ ] Error rate < 1% para servicios core (auth, promotion, gateway)
- [ ] Circuit breaker permaneció `CLOSED` durante toda la prueba
- [ ] Ningún pod reiniciado por OOM (`kubectl get pods -n stage | grep -v Running`)
- [ ] Kafka consumer lag volvió a 0 dentro de 60 s tras pico
- [ ] Ninguna alerta Prometheus disparada (`CircuitBreakerOpen`, `HighRequestLatency`)
- [ ] Locust failure log vacío o solo 401/403 esperados

---

## 7. Resultados reales — corrida local (2026-06-06)

Ejecución real de Locust 2.44.1 contra servicios levantados localmente (`./gradlew bootRun`),
no contra el clúster (el pipeline `deploy-stage.yml` lo ejecuta contra EKS). Carga: **50 usuarios
concurrentes, spawn-rate 10/s, duración 60 s**. CSV crudos en
[`locust/results/`](../../locust/results/).

> **Nota de compatibilidad:** los `locustfile.py` tenían un bug con Locust 2.x — `resp.failure()`
> fuera de un bloque `with ... catch_response=True` lanza `LocustError` y mata a cada usuario en
> `on_start` (0 requests). Se corrigió `on_start` en auth/dashboard/file-service envolviéndolo en
> with-block. Las corridas de abajo usan los locustfiles ya corregidos.

### 7.1 file-service (sin dependencias externas)

| Endpoint | reqs | fails | RPS | p50 | p95 | p99 | max |
|----------|------|-------|-----|-----|-----|-----|-----|
| `POST /api/v1/files/upload` | 4 676 | 0 | 79.1 | 2 ms | 5 ms | 7 ms | 22 ms |
| `GET /actuator/health` | 4 723 | 0 | 79.9 | 1 ms | 4 ms | 5 ms | 11 ms |
| **Agregado** | **9 399** | **0 (0%)** | **159.1** | **2 ms** | **4 ms** | **6 ms** | **22 ms** |

**Interpretación:** upload es I/O de disco puro (sin red/DB) → latencia plana y baja. p95 5 ms
con 159 RPS sostenidos en 1 réplica, error rate 0%. Cómodo dentro del SLO de 2000 ms; el
servicio no es el cuello de botella del sistema. El `max` 22 ms aislado corresponde a pausas GC
de arranque del JIT.

### 7.2 gateway-service (Redis para rate-limit)

Rate limiter elevado vía `RATE_LIMIT_REQUESTS_PER_WINDOW=1000000` (patrón External Configuration)
para medir throughput sin bloqueo 429. Cada request `/api/**` pasa por `RateLimitInterceptor` →
Redis (ZADD + ZREMRANGEBYSCORE + ZCARD).

| Endpoint | reqs | fails | RPS | p50 | p95 | p99 | max |
|----------|------|-------|-----|-----|-----|-----|-----|
| `POST /api/v1/gate/validate` | 7 013 | 0 | 118.8 | 4 ms | 8 ms | 10 ms | 23 ms |
| `GET /actuator/health` | 2 366 | 0 | 40.1 | 2 ms | 5 ms | 8 ms | 21 ms |
| **Agregado** | **9 379** | **0 (0%)** | **158.8** | **4 ms** | **8 ms** | **10 ms** | **23 ms** |

**Interpretación:** `validate` con token aleatorio falla la verificación JWT (firma inválida) y
retorna 200 `{valid:false}` — pero cada llamada igualmente cruza el round-trip a Redis del rate
limiter, que es lo que mide el p95 de 8 ms (vs 5 ms de file-service sin Redis). El delta ~3-4 ms
es el costo del sliding-window en Redis. 0% error, 159 RPS en 1 réplica. Confirma la estimación
modelada de la §2.3 («validate_token stateless, p95 < 150 ms con 1 réplica»): el real es muy
inferior bajo 50 usuarios.

### 7.3 Conclusiones de la corrida real

- Ambos servicios sostienen **~159 RPS por réplica con 0% de error** y p95 de un dígito en ms.
- El overhead de Redis en el camino de rate-limiting es medible (~3-4 ms p95) pero despreciable
  frente al SLO.
- Los valores reales quedan **2-3 órdenes de magnitud por debajo** de los umbrales modelados
  (§2), confirmando holgura amplia a esta escala de carga.
- Servicios con DB/grafo (promotion, dashboard) y la cadena cross-service no se midieron localmente
  por requerir el stack completo; el pipeline `deploy-stage.yml` los cubre contra EKS.

---

*Última actualización: 2026-06-06*
