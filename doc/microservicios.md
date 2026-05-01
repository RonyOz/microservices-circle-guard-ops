# Selección de microservicios — CircleGuard Taller 2

**Repositorio:** `RonyOz/microservices-circle-guard-dev`  
**Servicios disponibles:** 8  
**Servicios seleccionados:** 6

---

## Servicios seleccionados

### 1. `circleguard-auth-service`
Autenticación dual: intenta LDAP universitario primero, cae a PostgreSQL si falla (`DualChainAuthenticationProvider`). Genera tokens QR de 60 segundos para acceso al campus. Punto de entrada del flujo completo — es el primer servicio que toca cualquier usuario.

**Dependencias:** PostgreSQL, OpenLDAP  
**Rol en pruebas:** inicio del flujo E2E; pruebas de autenticación y generación de QR.

---

### 2. `circleguard-identity-service`
Vault criptográfico: mapea identidades reales a `anonymousId` UUID mediante AES + índice ciego SHA-256. El `anonymousId` que circula por todo el grafo de `promotion-service` viene de aquí. Tiene migraciones Flyway completas y tests con H2 que ya funcionan.

**Dependencias:** PostgreSQL  
**Rol en pruebas:** prueba de integración directa con `auth-service` (registro → anonimización → ID en el grafo).

---

### 3. `circleguard-promotion-service`
El núcleo del sistema. Detecta proximidad por señal WiFi, construye el grafo de contactos en Neo4j y propaga estados de salud en cascada recursiva (`ACTIVE → POTENTIAL → CONTAGIED`). Escribe el estado en Redis para que `gateway-service` lo consulte en milisegundos. Es el servicio con más lógica real y el más rico para pruebas.

**Dependencias:** PostgreSQL, Neo4j, Kafka, Redis  
**Rol en pruebas:** núcleo de pruebas de integración y rendimiento (Locust); valida la propagación de estados y detección de círculos.

---

### 4. `circleguard-gateway-service`
Valida el token QR generado por `auth-service`, consulta Redis (escrito por `promotion-service`) y devuelve `GREEN` o `RED`. Código completo, sin dependencias de BD relacional ni Kafka. Ideal para pruebas de rendimiento: simula la entrada masiva de estudiantes al campus.

**Dependencias:** Redis  
**Rol en pruebas:** pruebas de rendimiento con Locust (escenario: validación de acceso bajo carga concurrente).

---

### 5. `circleguard-notification-service`
Consume el topic Kafka `promotion.status.changed` y despacha alertas. La implementación actual es un mock que loguea — la integración con email real requiere Mailhog como SMTP local en K8s.

**Dependencias:** Kafka, SMTP (Mailhog en entorno de taller)  
**Rol en pruebas:** prueba de integración asíncrona; verifica que un cambio de estado en `promotion-service` dispara una notificación.

---

### 6. `circleguard-form-service`
Gestiona encuestas de síntomas. Al enviar un formulario, publica en Kafka el evento `survey.submitted`, que `promotion-service` consume para actualizar estados. Conexión real y bidireccional con el núcleo del sistema.

**Dependencias:** PostgreSQL, Kafka  
**Rol en pruebas:** prueba de integración end-to-end: formulario con síntomas → evento Kafka → actualización de estado en el grafo.

---

## Servicios descartados

| Servicio | Razón |
|---|---|
| `circleguard-file-service` | Almacena en disco local con `Files.copy()` — archivos se pierden al reiniciar el pod en K8s. Sin dependencias de infraestructura compartida y sin integración con ningún otro servicio. |
| `circleguard-dashboard-service` | El endpoint principal (`/health-board`) consulta una tabla `institutional_health` que no existe en ninguna migración del repo — falla en runtime. Sin integración real con los demás servicios seleccionados. |

---

## Flujo E2E que habilita esta selección

```
Usuario se registra
  → auth-service obtiene anonymousId de identity-service
  → Usuario llena formulario de síntomas
  → form-service publica en Kafka (survey.submitted)
  → promotion-service actualiza estado en Neo4j + Redis
  → notification-service despacha alerta por Kafka
  → Usuario intenta entrar al campus con QR
  → gateway-service consulta Redis → responde RED
```

Este flujo cubre los cinco puntos de prueba del taller: unitarias, integración, E2E, rendimiento (Locust en gateway) y análisis de resultados.

---

## Infraestructura requerida

| Servicio | PostgreSQL | Neo4j | Kafka | Redis | OpenLDAP | SMTP |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| auth-service | ✓ | | | | ✓ | |
| identity-service | ✓ | | | | | |
| promotion-service | ✓ | ✓ | ✓ | ✓ | | |
| gateway-service | | | | ✓ | | |
| notification-service | | | ✓ | | | ✓ |
| form-service | ✓ | | ✓ | | | |

OpenLDAP: requerido por `auth-service`. El `DualChainAuthenticationProvider` intenta LDAP primero — si no hay servidor, hay un timeout antes del fallback a PostgreSQL. Desplegar OpenLDAP como pod adicional o configurar un timeout agresivo.

SMTP: usar [Mailhog](https://github.com/mailhog/MailHog) como servidor SMTP falso en K8s. Captura correos sin enviarlos — adecuado para el entorno de taller.