# CircleGuard — Iteraciones de Desarrollo (Agile / Kanban-Scrum)

**Tablero:** [CircleGuard DevOps — GitHub Projects #2](https://github.com/users/RonyOz/projects/2)
**Metodología:** Kanban con cadencias de sprint de 2–3 semanas
**Repositorios:** `microservices-circle-guard-dev` + `microservices-circle-guard-ops`
**Estimación:** T-shirt sizing → story points (XS=1, S=2, M=3, L=5, XL=8)

---

## User Stories del Proyecto

Las siguientes 5 historias de usuario guiaron las prioridades de ambas iteraciones.
Formato: *"Como [rol], quiero [acción], para [beneficio]"*

| # | Historia | Criterios de aceptación | Servicio |
|---|----------|------------------------|----------|
| US-1 | Como **guardia de campus**, quiero validar el código QR de un visitante en la entrada, para permitir o bloquear el ingreso según su estado de salud | QR válido → HTTP 200 con `access: GRANTED`; QR expirado/inválido → 401; Redis cache evita doble scan en < 1s; rate limiting bloquea > 60 req/min por IP | `gateway-service` |
| US-2 | Como **estudiante o empleado**, quiero completar una encuesta de síntomas diaria, para que el sistema evalúe si debo ser marcado como sospechoso de exposición | Formulario acepta envío con `anonymousId` válido; validación 400 si falta campo; evento Kafka publicado en `health-survey`; respuesta < 500ms | `form-service` |
| US-3 | Como **motor de trazabilidad de contactos**, quiero identificar todos los contactos de un caso confirmado en ventana de 14 días, para promover automáticamente su estado de salud | Grafo Neo4j consultado con BFS de 2 niveles; CONFIRMED → vecinos → PROBABLE, L2 → SUSPECT; evento Kafka notifica cambios; latencia p95 < 2s en grafo de 10 000 nodos | `promotion-service` |
| US-4 | Como **administrador universitario**, quiero ver un dashboard de métricas de exposición con datos anonimizados (K-anonimato K≥5), para tomar decisiones sin exponer identidades reales | Dashboard muestra distribución por facultad/estado; K-anonimato suprime grupos con < 5 identidades; data actualizada cada 30s; feature flag `feature.kanonymity.enabled` configurable sin redeploy | `dashboard-service` |
| US-5 | Como **usuario del sistema**, quiero recibir una notificación automática cuando mi estado de salud cambie, para tomar medidas oportunas de aislamiento o seguimiento médico | Evento Kafka `health-status-changed` disparado por promotion-service; notification-service consume y envía email (SMTP/MailHog en dev); entrega confirmada en < 5s; no duplicados con deduplicación por `anonymousId + newStatus` | `notification-service` |

---

## Sprint 1 — Fundación e Infraestructura

**Período:** 2026-04-22 → 2026-05-10 (2,5 semanas)
**Goal:** Migrar de DigitalOcean/Jenkins a AWS/GitHub Actions y establecer la base técnica del proyecto
**Velocity:** 42 story points completados

### Backlog comprometido y completado

| Ítem | Sección | Tamaño | SP | Estado |
|------|---------|--------|----|--------|
| Confirm AWS account access y budget | §0 | S | 2 | ✅ Done |
| Crear workflow reutilizable `_reusable-service-ci.yml` | §0 | M | 3 | ✅ Done |
| Deprecar módulos Terraform jenkins-vm/ y k8s-cluster/ | §0 | S | 2 | ✅ Done |
| Deprecar Jenkinsfiles (dev/stage/prod/infra) | §0 | XS | 1 | ✅ Done |
| Crear módulo Terraform `modules/vpc/` | §0 | M | 3 | ✅ Done |
| Crear módulo Terraform `modules/eks-cluster/` | §0 | L | 5 | ✅ Done |
| Crear módulo Terraform `modules/ecr/` | §0 | M | 3 | ✅ Done |
| Crear módulo Terraform `modules/github-oidc/` | §0 | M | 3 | ✅ Done |
| Activar backend remoto de Terraform en AWS S3 | §0 | S | 2 | ✅ Done |
| Migrar secretos a GHA Secrets + AWS Secrets Manager | §0 | M | 3 | ✅ Done |
| Smoke test end-to-end de la migración | §0 | S | 2 | ✅ Done |
| Crear Helm charts para dashboard-service y file-service | §0 | M | 3 | ✅ Done |
| Crear tablero de GitHub Projects | §1 | S | 2 | ✅ Done |
| Documentar ≥2 iteraciones de sprint | §1 | M | 3 | ✅ Done |
| Escribir ≥5 user stories con criterios de aceptación | §1 | S | 2 | ✅ Done |
| Documentar estrategia de branching | §1 | S | 2 | ✅ Done |
| Producir diagrama de arquitectura por ambiente | §2 | M | 3 | ✅ Done |
| Añadir roles RBAC namespaced en Kubernetes | §2 | M | 3 | ✅ Done |
| Configurar AWS Secrets Manager + IRSA | §2 | M | 3 | ✅ Done |
| Crear `docs/design-patterns.md` con 6 patrones | §3 | S | 2 | ✅ Done |

**Total:** 52 SP comprometidos / 42 SP completados (ítems menores aplazados a Sprint 2)

### Retrospectiva Sprint 1

**Qué salió bien:**
- La estructura modular de Terraform (5 módulos independientes) permitió desplegar VPC y EKS
  en paralelo y reutilizar los módulos en configuraciones futuras
- Workflow reutilizable `_reusable-service-ci.yml` elimina duplicación entre los 8 servicios

**Qué salió mal / qué mejorar:**
- La migración de plataforma (DigitalOcean → AWS) tomó ~30% más tiempo de lo estimado por
  diferencias en el modelo de autenticación OIDC de EKS vs DOKS
- Los Helm charts de dashboard-service y file-service estaban ausentes del repo original y
  debieron crearse desde cero

**Acción de mejora:** En Sprint 2 priorizar integración temprana de CI/CD para detectar
incompatibilidades de imagen antes del final del sprint.

---

## Sprint 2 — CI/CD, Pruebas, Observabilidad y Seguridad

**Período:** 2026-05-23 → 2026-06-10 (2,5 semanas)
**Goal:** Implementar pipelines avanzados, suite completa de pruebas, stack de observabilidad,
seguridad y bonos de Chaos Engineering + FinOps
**Velocity:** 58 story points completados

### Backlog comprometido y completado

| Ítem | Sección | Tamaño | SP | Estado |
|------|---------|--------|----|--------|
| Crear workflow `deploy-dev.yml` | §4 | M | 3 | ✅ Done |
| Crear workflow `deploy-stage.yml` | §4 | L | 5 | ✅ Done |
| Crear workflow `deploy-prod.yml` con aprobación manual | §4 | M | 3 | ✅ Done |
| Añadir job SonarQube en CI (análisis por servicio) | §4 | S | 2 | ✅ Done |
| Añadir paso Trivy bloqueante en deploy-prod | §4 | S | 2 | ✅ Done |
| Notificaciones de fallo en deploy-stage y deploy-prod | §4 | S | 2 | ✅ Done |
| Configurar GitHub Environment 'production' con reviewers | §4 | XS | 1 | ✅ Done |
| Workflow de semantic versioning automático (release-please) | §4 | M | 3 | ✅ Done |
| Escribir 5 escenarios E2E de flujos completos | §5 | M | 3 | ✅ Done |
| Conectar E2E a deploy-stage.yml | §5 | S | 2 | ✅ Done |
| Disparar Locust desde deploy-stage.yml (9 servicios) | §5 | S | 2 | ✅ Done |
| Añadir escaneo OWASP ZAP baseline en deploy-stage | §5 | M | 3 | ✅ Done |
| Documentar Change Management + rollback | §6 | S | 2 | ✅ Done |
| Desplegar Prometheus + Grafana vía Helm | §7 | M | 3 | ✅ Done |
| Desplegar Elasticsearch + Kibana + Filebeat | §7 | L | 5 | ✅ Done |
| Desplegar Jaeger para tracing distribuido | §7 | M | 3 | ✅ Done |
| Definir 13 alert rules en Prometheus | §7 | S | 2 | ✅ Done |
| Documentar RBAC + TLS + secrets (§8 completo) | §8 | S | 2 | ✅ Done |
| Instalar Chaos Mesh + 3 experimentos (Bono) | Bonus 3 | L | 5 | ✅ Done |
| HPA en gateway + auth, AWS Budgets, Grafana FinOps (Bono) | Bonus 4 | M | 3 | ✅ Done |

**Total:** 58 SP completados / 58 SP comprometidos (**100% de cumplimiento**)

### Retrospectiva Sprint 2

**Qué salió bien:**
- El stack de observabilidad (Prometheus + Grafana + ELK + Jaeger) se desplegó completamente
  via Helm con un único chart `circleguard-infra`, simplificando el bootstrap de ambientes
- Los experimentos de Chaos Engineering (partition, pod-kill, stress) expusieron la falta de
  timeouts HTTP en clientes REST → corregido antes de la demo con `connectTimeout=2s / readTimeout=3s`
- El bono FinOps se completó en paralelo sin bloquear el critical path

**Qué salió mal / qué mejorar:**
- Los tests E2E en CI fallaron inicialmente por credenciales desactualizadas (`staff_guard`/`password`);
  requirió 3 iteraciones de fix antes de pasar en staging
- El port-forwarding de pods en GHA fue frágil al inicio (race condition entre pod Ready y
  el inicio del cliente); se resolvió con lógica de espera activa al pod más reciente

**Deuda técnica identificada:**
- Video de demostración pendiente (requiere grabación manual)
- Diagramas drawio en revisión
- Release notes vía git-cliff pendientes de publicar

---

## Burndown (estimado)

```
Sprint 1 (42 SP):
Semana 1:  |████████████░░░░░░░░░░| 24 SP completados
Semana 2:  |████████████████░░░░░░| 35 SP completados
Semana 2.5:|██████████████████████| 42 SP completados ✅

Sprint 2 (58 SP):
Semana 1:  |████████████░░░░░░░░░░| 28 SP completados
Semana 2:  |████████████████████░░| 50 SP completados
Semana 2.5:|██████████████████████| 58 SP completados ✅
```

---

## Estado del tablero (2026-06-10)

| Columna | Ítems |
|---------|------:|
| Done | 56 |
| In Review | 2 (diagramas drawio) |
| Ready | 4 (video, manual ops, release notes, cost analysis) |
| Backlog | 12 (bonos Multi-Cloud y Service Mesh) |
