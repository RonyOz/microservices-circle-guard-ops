# Design Patterns

CircleGuard implementa seis patrones de diseño cloud. Tres son patrones de infraestructura/ops; tres son patrones de aplicación. Todos están referenciados en la clasificación estándar de Microsoft Azure Architecture Patterns.

---

## Patrón 1 — Bulkhead

**Categoría:** Resiliencia  
**Dónde implementado:** Kubernetes namespace isolation (`microservices-circle-guard-ops`)

### Definición

El patrón Bulkhead aísla elementos críticos de una aplicación en grupos independientes, de modo que si uno falla, los demás siguen funcionando. El nombre viene de los compartimentos estancos de un barco: si uno se inunda, no hunde al resto.

### Implementación en CircleGuard

Los 8 microservicios se despliegan en tres namespaces Kubernetes independientes — `dev`, `stage`, `production` — sobre un mismo cluster EKS. Cada namespace es un compartimento Bulkhead:

**Aislamiento de recursos:** Cada Helm chart define `resources.limits` por contenedor. Un pod que consume CPU en exceso no puede afectar pods de otro namespace.

```yaml
# services/auth-service/chart/values.yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

**Aislamiento de secretos:** Cada namespace sincroniza desde su propio path en AWS Secrets Manager (`circleguard/dev`, `circleguard/stage`, `circleguard/production`). Un secreto comprometido en `dev` no expone `production`.

**Aislamiento de despliegues:** Un deploy fallido en `stage` no afecta los pods de `production`. Los workflows `deploy-dev.yml`, `deploy-stage.yml`, `deploy-prod.yml` son pipelines independientes.

```
Sin Bulkhead:
[Cluster único]  ← deploy roto en stage afecta a todos

Con Bulkhead (CircleGuard):
[namespace: dev]   ← deploy roto aquí
[namespace: stage] ← aislado
[namespace: production] ← sin impacto
```

**Archivos relevantes:**
- `.github/workflows/deploy-dev.yml`, `deploy-stage.yml`, `deploy-prod.yml`
- `services/<service>/chart/values.yaml` — resource limits
- `terraform/aws/modules/irsa-secrets/main.tf` — un secret de SM por namespace

### Beneficios

- Fallos en `dev` o `stage` no propagan a `production`
- Permite experimentación agresiva en `dev` sin riesgo
- Escalamiento independiente por ambiente

---

## Patrón 2 — Publisher/Subscriber

**Categoría:** Mensajería / Arquitectura  
**Dónde implementado:** `circleguard-form-service`, `circleguard-promotion-service`, `circleguard-notification-service` (`microservices-circle-guard-dev`)

### Definición

En Pub/Sub, los productores (publishers) publican mensajes en un canal (topic) sin saber quiénes los consumen. Todos los suscriptores registrados al topic reciben su propia copia del mensaje. Cada suscriptor puede reaccionar de forma independiente.

```
Publisher → [Topic] → Subscriber A (recibe copia)
                    → Subscriber B (recibe copia)
                    → Subscriber C (recibe copia)
```

### Implementación en CircleGuard

Apache Kafka (desplegado in-cluster via `infrastructure/chart/templates/kafka.yaml`) actúa como message broker. Hay dos flows Pub/Sub principales:

**Flow 1 — Health Survey → Status Evaluation:**

```
form-service (publisher)
  HealthSurveyService.submitSurvey()
  topic: survey.submitted
  payload: { anonymousId, hasSymptoms, timestamp }
       ↓
promotion-service (subscriber, group: promotion-service-group)
  SurveyListener → evalúa si el estudiante debe escalar a SUSPECT
```

**Flow 2 — Status Change → Notification:**

```
promotion-service (publisher)
  HealthStatusService.updateStatus()
  topic: promotion.status.changed
  payload: { anonymousId, status, timestamp }
       ↓
notification-service (subscriber)
  ExposureNotificationListener → push (Gotify) + email (SMTP) + SMS (Twilio)
```

El publisher (`promotion-service`) no sabe que `notification-service` existe. Si mañana se agrega un `audit-service` que escuche `promotion.status.changed`, no se modifica una línea de `promotion-service`.

**Archivos relevantes:**
- `services/circleguard-form-service/src/main/java/…/service/HealthSurveyService.java` — producer
- `services/circleguard-promotion-service/src/main/java/…/listener/SurveyListener.java` — consumer
- `services/circleguard-promotion-service/src/main/java/…/service/HealthStatusService.java` — producer
- `services/circleguard-notification-service/src/main/java/…/listener/ExposureNotificationListener.java` — consumer
- `infrastructure/chart/templates/kafka.yaml` — Kafka StatefulSet

### Beneficios

- Desacoplamiento total: `form-service` no conoce a `promotion-service`; `promotion-service` no conoce a `notification-service`
- Agregar un nuevo subscriber (ej. audit logger) requiere cero cambios en el publisher
- Fallos en `notification-service` no bloquean el pipeline de promoción de estado
- Kafka persiste mensajes: pueden reprocessarse si un consumer falla

---

## Patrón 3 — Cache Aside

**Categoría:** Rendimiento  
**Dónde implementado:** `circleguard-auth-service`, `circleguard-gateway-service`, `circleguard-promotion-service` (`microservices-circle-guard-dev`)

### Definición

Cache Aside (Lazy Loading) es el patrón donde la aplicación gestiona explícitamente la caché: primero busca en caché; si no encuentra (cache miss), busca en la fuente de datos y guarda el resultado en caché para consultas futuras.

```
Lectura:
1. App busca en caché → HIT: retorna dato
                      → MISS: busca en DB → guarda en caché → retorna dato

Escritura:
1. App escribe en DB → invalida/actualiza entrada en caché
```

### Implementación en CircleGuard

Redis (desplegado via `infrastructure/chart/templates/redis.yaml`) actúa como caché. Hay dos usos principales:

**Uso 1 — QR Token Cache (auth-service + gateway-service):**

El flujo de entrada al campus requiere validación de QR en tiempo real. El token no puede ir a PostgreSQL en cada scan (latencia inaceptable para una puerta física):

1. `auth-service` genera token → escribe en Redis con TTL de 5 minutos
2. `gateway-service` valida token → lee de Redis (cache hit en <1ms)
3. Token expirado → Redis lo elimina automáticamente (TTL enforcement)
4. Redis actúa como cache de tokens de corta vida: la "DB" es la lógica de negocio, no un store persistente

**Uso 2 — Health Status Cache (promotion-service):**

El grafo Neo4j es costoso de consultar para cada lectura de estado. El `HealthStatusService` cachea el estado actual de cada `anonymousId` en Redis:

1. Consulta de estado → busca en Redis primero
2. Cache miss → consulta Neo4j → guarda en Redis
3. Actualización de estado → `HealthStatusService.updateStatus()` invalida la entrada Redis del `anonymousId` afectado

Esto es crítico para el NFR de contención: las notificaciones de exposición deben reflejar el estado actualizado en <60 segundos.

**Archivos relevantes:**
- `services/circleguard-auth-service/src/main/java/…/controller/QrTokenController.java`
- `services/circleguard-gateway-service/src/main/java/…/service/QrValidationService.java`
- `services/circleguard-promotion-service/src/main/java/…/service/HealthStatusService.java`
- `infrastructure/chart/templates/redis.yaml` — Redis StatefulSet
- `services/gateway-service/chart/values.yaml` — `REDIS_HOST` env var

### Beneficios

- Validación de QR en tiempo real sin hits a PostgreSQL/Neo4j
- TTL automático de Redis elimina tokens expirados sin lógica explícita de revocación
- Si Redis falla, `gateway-service` puede caer back a validación directa (degraded mode)
- Reducción de carga en Neo4j para lecturas frecuentes de estado de salud

---

## Patrón 4 — External Configuration Store

**Categoría:** Configuración  
**Dónde implementado:** AWS Secrets Manager + External Secrets Operator + IRSA (`microservices-circle-guard-ops`)

### Definición

External Configuration Store extrae la configuración de la aplicación fuera del código y binarios, almacenándola en un sistema externo centralizado que puede modificarse sin redesplegar la aplicación. Es uno de los principios del 12-Factor App.

```
[Config Store centralizado]
        |
   -----+---------
   |              |
[Instancia 1]  [Instancia 2]  ← Todos leen la misma config
```

### Implementación en CircleGuard

Cadena de tres capas:

```
AWS Secrets Manager
  secret: circleguard/dev
  value:  { DB_USERNAME, DB_PASSWORD, NEO4J_USERNAME, NEO4J_PASSWORD, JWT_SECRET }
       ↓  (ESO poll cada 1h via IRSA — IAM Role for Service Accounts)
External Secrets Operator
  ExternalSecret CR por servicio en cada namespace
       ↓  (crea/actualiza)
Kubernetes Secret: <service>-secret
       ↓  (montado por pod)
Spring Boot application
  envFrom:
    - secretRef:
        name: <service>-secret
  → ${DB_PASSWORD}, ${JWT_SECRET} resueltos en runtime
```

La configuración no-sensible (DB host, service URLs, puerto) también es externa: viene de los Helm chart `env:` values, no de la imagen Docker.

**Rotación de secretos sin redesploy:**
1. Actualizar valor en AWS Secrets Manager
2. ESO sincroniza a K8s Secret dentro de 1 hora (o forzar con `kubectl annotate`)
3. `kubectl rollout restart deployment/<service>` para que los pods lean el nuevo Secret
4. Cero rebuilding de imagen Docker

**Archivos relevantes (un dueño por recurso, sin solape):**
- `.github/workflows/bootstrap-eso.yml` — (cluster, una vez) instala ESO + crea el ClusterSecretStore
- `infrastructure/chart/templates/external-secrets.yaml` — (namespaced, vía deploy-data-plane.yml) ExternalSecret por servicio
- `.github/workflows/deploy-{dev,stage,prod}.yml` — seed de AWS Secrets Manager por ambiente (`put-secret-value`)
- `terraform/aws/modules/irsa-secrets/main.tf` — IAM role para ESO + contenedores de SM secrets
- `services/<service>/chart/templates/deployment.yaml` — `envFrom.secretRef`
- `docs/secrets-management.md` — documentación completa de la cadena

### Beneficios

- Cero secretos en imágenes Docker o en git
- Rotación de contraseñas DB/JWT sin rebuilding de imagen
- Audit trail en AWS CloudTrail de cada acceso a Secrets Manager
- Un solo lugar para gestionar la configuración sensible de todos los servicios

### Extensión — ConfigMaps para configuración no sensible

Complementando la cadena de secretos, la configuración no-sensible (DB host, service URLs, feature flags) se externaliza vía **Kubernetes ConfigMaps** generados por los Helm charts:

```yaml
# services/auth-service/chart/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "chart.fullname" . }}-config
data:
  DB_HOST: "postgres"
  DB_NAME: "circleguard_auth"
  LDAP_HOST: "openldap"
  IDENTITY_SERVICE_URL: "http://identity-service:8082"
```

El `deployment.yaml` referencia ambas fuentes (ConfigMap + Secret) vía `envFrom`:

```yaml
envFrom:
  - configMapRef:
      name: auth-service-config      # config no-sensible
  - secretRef:
      name: auth-service-secret      # secretos (DB_PASSWORD, JWT_SECRET)
```

**Servicios con ConfigMap wired:** auth-service, form-service, gateway-service, dashboard-service.

**Ventaja clave:** un operador puede cambiar `DB_HOST` o `IDENTITY_SERVICE_URL` modificando el ConfigMap y ejecutando `kubectl rollout restart`, sin rebuild de imagen ni cambio de Helm values en git.

---

## Patrón 5 — Gatekeeper

**Categoría:** Seguridad  
**Dónde implementado:** `circleguard-gateway-service` (`microservices-circle-guard-dev`)

### Definición

Gatekeeper es un proxy de seguridad que actúa como punto de entrada único para solicitudes externas, validando, autenticando y autorizando antes de que lleguen a los servicios backend. Los servicios backend son inaccesibles directamente desde el exterior.

```
Exterior → [Gatekeeper] → [Servicio Backend]
            Valida
            Autentica
            Autoriza
            Sanitiza
```

### Implementación en CircleGuard

`gateway-service` (port 8086) es el Gatekeeper para el acceso físico al campus universitario. El hardware externo (scanner de la puerta) solo puede llamar al gateway — nunca a `auth-service` o `identity-service` directamente.

**Flujo completo del token QR:**

```
1. Estudiante autenticado → auth-service genera JWT
2. Estudiante solicita QR → auth-service genera token de corta vida
                           → escribe token en Redis (TTL: 5min)
3. Scanner de puerta llama:
   POST /api/v1/gate/validate  { "token": "..." }
        ↓
   gateway-service:
   → QrValidationService lee Redis
   → valida firma + expiración
   → retorna { "access": true/false }
4. auth-service, identity-service, Neo4j → nunca expuestos al scanner
```

**Propiedad de seguridad clave:** El scanner de la puerta solo necesita conocer un endpoint (`/api/v1/gate/validate`). No tiene credenciales de JWT, no conoce la estructura interna de los servicios. Si el scanner es comprometido, el atacante tiene acceso a un solo endpoint de validación read-only.

**Archivos relevantes:**
- `services/circleguard-gateway-service/src/main/java/…/controller/GateController.java`
- `services/circleguard-gateway-service/src/main/java/…/service/QrValidationService.java`
- `services/circleguard-auth-service/src/main/java/…/controller/QrTokenController.java` — genera el token
- `infrastructure/chart/templates/redis.yaml` — Redis como store del token

### Diferencia con API Gateway

Un API Gateway hace routing, aggregation, transformación. El Gatekeeper de CircleGuard es de propósito específico: validación de acceso físico. No agrega respuestas de múltiples servicios; solo verifica un token en Redis.

### Beneficios

- Hardware externo (scanner) tiene superficie de ataque mínima: un solo endpoint
- Lógica de validación centralizada — cambiar el algoritmo de token requiere actualizar un solo servicio
- TTL de Redis hace expiración automática sin lógica explícita de revocación
- Privacidad: el scanner nunca recibe identidad real del estudiante

---

## Patrón 6 — Pipes and Filters

**Categoría:** Procesamiento / CI/CD  
**Dónde implementado:** GitHub Actions workflows (`microservices-circle-guard-ops`)

### Definición

Pipes and Filters descompone el procesamiento en una secuencia de pasos independientes (filtros) conectados por canales (pipes). Cada filtro realiza una transformación específica y pasa el resultado al siguiente. Los filtros son independientes entre sí y pueden reemplazarse, reordenarse o escalarse individualmente.

```
[Input] → [Filtro 1] → [Pipe] → [Filtro 2] → [Pipe] → [Filtro 3] → [Output]
          (Validar)              (Transformar)           (Enriquecer)
```

### Implementación en CircleGuard

El pipeline de CI/CD es una implementación textbook de Pipes and Filters. Cada step del workflow es un filtro independiente; GitHub Actions conecta los steps como pipes secuenciales (o paralelos cuando hay matrix builds).

**Pipeline de un servicio (dev repo → ops repo):**

```
[Source code commit]
      |
      ▼
[Filtro 1: Unit Tests]          ./gradlew test
      | pasa artifacts de build
      ▼
[Filtro 2: Docker Build]        docker build → imagen local
      | pasa image digest
      ▼
[Filtro 3: ECR Push]            aws ecr get-login-password | docker push
      | pasa image tag
      ▼
[Filtro 4: repository_dispatch] notifica ops repo con { service, image_tag }
      |
      ▼ (ops repo: deploy-dev.yml)
[Filtro 5: Helm Lint]           helm lint services/<service>/chart/
      | pasa chart validado
      ▼
[Filtro 6: Helm Deploy]         helm upgrade --install ... --namespace dev
      | pasa release name
      ▼
[Filtro 7: Rollout Verify]      kubectl rollout status deployment/<service>
      | pasa pod status
      ▼
[Filtro 8: Smoke Test]          kubectl port-forward + ./e2e/<service>/e2e.sh
      |
      ▼
[Output: service running in dev namespace]
```

Cada filtro tiene responsabilidad única:
- Filtro 1 falla → el build no continúa (no se construye imagen de código roto)
- Filtro 5 falla → no se deploya un chart con syntax errors
- Filtro 7 falla → el deploy se rollback automáticamente (`--atomic` en prod)

**El pipeline de producción agrega filtros adicionales:**

```
[Filtro extra: ECR image verification] → imagen debe existir antes de pedir aprobación
[Filtro extra: Manual approval gate]   → GitHub Environment 'production' required reviewer
[Filtro extra: git-cliff release notes] → genera CHANGELOG desde conventional commits
[Filtro extra: GitHub Release create]   → publica release con notas
```

**Archivos relevantes:**
- `.github/workflows/_reusable-service-ci.yml` — filtros 1-4 (test → build → push → dispatch)
- `.github/workflows/deploy-dev.yml` — filtros 5-8 (lint → deploy → verify → smoke)
- `.github/workflows/deploy-prod.yml` — pipeline completo con filtros de aprobación y release

### Beneficios

- Cada filtro es testeable independientemente (se puede correr `helm lint` localmente sin el pipeline completo)
- Un filtro que falla detiene el pipeline antes de causar daño downstream
- Filtros pueden reordenarse: ej. mover Trivy scan entre Push y Deploy sin afectar otros filtros
- La adición de nuevos filtros (SonarQube, OWASP ZAP) no requiere modificar los filtros existentes

---

## Patrón 7 — Circuit Breaker

**Categoría:** Resiliencia  
**Dónde implementado:** `circleguard-auth-service` → `identity-service`, `circleguard-dashboard-service` → `promotion-service` (`microservices-circle-guard-dev`)

### Definición

Circuit Breaker envuelve llamadas a servicios remotos con un interruptor que tiene tres estados: CLOSED (tráfico normal), OPEN (falla detectada — bloquea llamadas y usa fallback), HALF_OPEN (prueba recuperación con tráfico limitado). Evita que fallos en cascada de un servicio agoten recursos en otros servicios.

```
CLOSED ──(50% fallos en 10 llamadas)──► OPEN ──(10s)──► HALF_OPEN
  ▲                                                           │
  └─────────────────(3 llamadas exitosas)─────────────────────┘
```

### Implementación en CircleGuard

**Librería:** `io.github.resilience4j:resilience4j-spring-boot3:2.2.0` + `spring-boot-starter-aop`

**auth-service → identity-service (fail-fast):**

`IdentityClient` llama a `identity-service` para mapear identidades reales a UUIDs anónimos. El UUID resultante se firma dentro del JWT, así que **no** se puede fabricar un valor de fallback: si `identity-service` recuperara luego un mapeo distinto, los tokens emitidos durante la caída referenciarían una identidad inexistente. Por eso el fallback hace *fail-fast* — lanza una excepción determinística (se traduce a 503) en lugar de inventar un UUID. El breaker aún corta el tráfico para no acumular timeouts.

```java
// services/circleguard-auth-service/src/main/java/.../client/IdentityClient.java
@CircuitBreaker(name = "identityService", fallbackMethod = "getAnonymousIdFallback")
public UUID getAnonymousId(String realIdentity) {
    // llamada HTTP a identity-service
}

private UUID getAnonymousIdFallback(String realIdentity, Throwable t) {
    log.error("Circuit breaker fallback: identity-service unavailable", t);
    throw new IllegalStateException("identity-service unavailable (circuit breaker open)", t);
}
```

**dashboard-service → promotion-service (degradación elegante):**

`PromotionClient` consulta estadísticas de salud del `promotion-service`. Si cae, el dashboard retorna un mapa de estado degradado en lugar de propagar un 500. Cada método anotado tiene su propio fallback (la firma del fallback debe replicar los argumentos del método + un `Throwable`).

```java
// services/circleguard-dashboard-service/src/main/java/.../client/PromotionClient.java
@CircuitBreaker(name = "promotionService", fallbackMethod = "healthStatsFallback")
public Map<String, Object> getHealthStats() { ... }

private Map<String, Object> healthStatsFallback(Throwable t) {
    return Map.of("error", "Service unavailable", "timestamp", new Date());
}

@CircuitBreaker(name = "promotionService", fallbackMethod = "departmentStatsFallback")
public Map<String, Object> getHealthStatsByDepartment(String department) { ... }

private Map<String, Object> departmentStatsFallback(String department, Throwable t) {
    return Map.of("error", "Service unavailable", "department", department, "timestamp", new Date());
}
```

**Configuración (ambos servicios en `application.yml`):**

```yaml
resilience4j:
  circuitbreaker:
    instances:
      identityService:      # o promotionService
        register-health-indicator: true   # aparece en /actuator/health
        sliding-window-type: COUNT_BASED
        sliding-window-size: 10
        minimum-number-of-calls: 5
        failure-rate-threshold: 50        # abre con 50% de fallos
        wait-duration-in-open-state: 10s  # espera 10s antes de HALF_OPEN
        permitted-number-of-calls-in-half-open-state: 3
        automatic-transition-from-open-to-half-open-enabled: true
```

Además se habilita el health indicator y se exponen las métricas (`resilience4j_circuitbreaker_state`, `_calls`) — ya capturadas por el registry de Micrometer/Prometheus existente:

```yaml
management:
  endpoint:
    health:
      show-details: always
  health:
    circuitbreakers:
      enabled: true
```

**Archivos relevantes:**
- `services/circleguard-auth-service/src/main/java/.../client/IdentityClient.java`
- `services/circleguard-auth-service/src/main/resources/application.yml`
- `services/circleguard-auth-service/build.gradle.kts`
- `services/circleguard-dashboard-service/src/main/java/.../client/PromotionClient.java`
- `services/circleguard-dashboard-service/src/main/resources/application.yml`
- `services/circleguard-dashboard-service/build.gradle.kts`

### Beneficios

- Fallos de `identity-service` no agotan recursos del flujo de login: el breaker en OPEN corta el tráfico y responde rápido (503 determinístico) en vez de colgar en timeouts de red. No se fabrican UUIDs para no corromper el mapeo de identidad firmado en el JWT
- Fallos de `promotion-service` no propagan errores 500 al dashboard — el usuario ve estado degradado ("Service unavailable") en lugar de pantalla de error
- El breaker en OPEN hace fail-fast: no espera timeout de red en cada llamada mientras el servicio está caído
- Recuperación automática via HALF_OPEN — no requiere intervención manual para restablecer tráfico
- Estado y métricas del breaker visibles en `/actuator/health` y `/actuator/prometheus` para alerting

---

## Patrón 8 — Feature Toggle

**Categoría:** Extensibilidad / Control  
**Dónde implementado:** `circleguard-dashboard-service` (`microservices-circle-guard-dev`)

### Definición

Feature Toggle (también llamado Feature Flag) es un patrón que permite activar o desactivar funcionalidades de una aplicación en runtime mediante configuración externa, sin necesidad de rebuild o redeploy del binario. Permite desacoplamiento entre deploy de código y activación de funcionalidades.

```
[Feature Flag: FEATURE_KANONYMITY_ENABLED=true]
              |
     [AnalyticsService]
              |
    +---------+---------+
    |                   |
[kAnonymityFilter.apply()]  [raw data]   ← toggle selects branch
    |                   |
[k-anonymized response]  [unfiltered response]
```

### Implementación en CircleGuard

**Funcionalidad controlada:** El filtro de K-anonimato (k=5) en `dashboard-service`. Este filtro suprime estadísticas de grupos con menos de 5 individuos para prevenir re-identificación. El toggle permite deshabilitarlo para entornos de desarrollo o testing donde la privacidad no aplica.

**Spring Boot (`AnalyticsService.java`):**

```java
@Value("${feature.kanonymity.enabled:true}")
private boolean kAnonymityEnabled;

public Map<String, Object> getDepartmentStats(String department) {
    Map<String, Object> raw = promotionClient.getHealthStatsByDepartment(department);
    return kAnonymityEnabled ? kAnonymityFilter.apply(raw) : raw;
}
```

**Binding de configuración:** no se necesita una entrada explícita en `application.yml`. La env var del chart `FEATURE_KANONYMITY_ENABLED` mapea por *relaxed binding* de Spring a la propiedad `feature.kanonymity.enabled`; el default `:true` del `@Value` garantiza comportamiento privacy-first si la var no está presente.

**Helm chart (`values.yaml`):**

```yaml
env:
  FEATURE_KANONYMITY_ENABLED: "true"   # production: true; dev/testing: false
```

**Cambiar el toggle sin redeploy:**

```bash
# Deshabilitar k-anonimato en dev namespace (para testing)
kubectl patch configmap dashboard-service-config -n dev \
  --type merge -p '{"data":{"FEATURE_KANONYMITY_ENABLED":"false"}}'
kubectl rollout restart deployment/dashboard-service -n dev
```

**Archivos relevantes:**
- `services/circleguard-dashboard-service/src/main/java/.../service/AnalyticsService.java`
- `services/circleguard-dashboard-service/src/main/resources/application.yml`
- `services/dashboard-service/chart/values.yaml`
- `services/dashboard-service/chart/templates/configmap.yaml`

### Beneficios

- Funcionalidad de privacidad configurable por ambiente: `true` en stage/production, `false` en dev para facilitar pruebas con datos reales
- Zero downtime para activar/desactivar: solo patch ConfigMap + rollout restart
- El valor default `true` garantiza que un deploy sin ConfigMap explícito es seguro (privacy-first)
- Combinado con el patrón de External Configuration (Patrón 4), el toggle se propaga desde Helm values → ConfigMap → pod sin tocar código

---

## Resumen

| # | Patrón | Categoría | Dónde en CircleGuard |
|---|--------|-----------|----------------------|
| 1 | Bulkhead | Resiliencia | K8s namespaces dev/stage/production, Helm resource limits |
| 2 | Publisher/Subscriber | Mensajería | Kafka: form→promotion, promotion→notification |
| 3 | Cache Aside | Rendimiento | Redis: QR tokens (gateway), health status (promotion) |
| 4 | External Configuration Store | Configuración | AWS SM + ESO + IRSA → K8s ConfigMaps + Secrets → Spring `envFrom` |
| 5 | Gatekeeper | Seguridad | gateway-service: validación QR para acceso físico al campus |
| 6 | Pipes and Filters | Procesamiento | CI/CD pipeline: test → build → push → deploy → verify → smoke |
| 7 | Circuit Breaker | Resiliencia | auth-service→identity-service, dashboard-service→promotion-service |
| 8 | Feature Toggle | Extensibilidad | dashboard-service: K-anonimato habilitado/deshabilitado via ConfigMap |
