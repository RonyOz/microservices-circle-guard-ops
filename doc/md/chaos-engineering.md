# Chaos Engineering — Bonus 3

CircleGuard usa **Chaos Mesh** para validar, con fallos inyectados deliberadamente, que los mecanismos de resiliencia documentados (probes §7.4, Circuit Breaker §3.2, alerting §7.1) funcionan en un cluster real — no solo en papel.

## Herramienta: Chaos Mesh (sobre Litmus)

| Criterio | Chaos Mesh | Litmus |
|---|---|---|
| Instalación | 1 chart Helm + CRDs | Operator + portal + hubs |
| Definición de experimento | 1 CRD declarativo por experimento | ChaosEngine + ChaosExperiment + RBAC por experimento |
| Auto-revert | `duration` nativo en el CRD | Manual / finalizers |
| Footprint | controller + daemonset (requests ~25m/128Mi c/u) | Mayor |

Para un alcance de 3 experimentos académicos, Chaos Mesh minimiza superficie y deuda: cada experimento es un YAML versionado y auto-reversible.

## Instalación

- `bootstrap-chaos.yml` (workflow_dispatch, una vez por cluster): instala `chaos-mesh/chaos-mesh` v2.7.3 en el namespace `chaos-mesh`, con `chaosDaemon.runtime=containerd` y `socketPath=/run/containerd/containerd.sock` (EKS usa containerd; sin esto el daemon no puede inyectar fallos).
- Dashboard incluido para la demo: `kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333`.
- Ejecución: `chaos-experiments.yml` (workflow_dispatch con input `experiment`) — aplica el CRD, **verifica la reacción con asserts reales** y limpia. Un run solo queda verde si la resiliencia funcionó.

Blast radius: todos los experimentos apuntan **solo al namespace `stage`** mediante `selector.namespaces` + `labelSelectors`; production nunca es objetivo.

## Experimento 1 — Pod failure (`chaos/experiments/pod-kill-promotion.yaml`)

| | |
|---|---|
| **Hipótesis** | Si muere un pod de promotion-service, el Deployment lo regenera y el servicio se recupera sin intervención, antes de que la alerta `ServiceDown` (`for: 2m`) dispare. |
| **Inyección** | `PodChaos action: pod-kill, mode: one` sobre `app.kubernetes.io/name=promotion-service`. |
| **Verificación automática** | El workflow captura el pod víctima, inyecta, espera `rollout status` (≤3m) y **falla si el pod nuevo es el mismo que el viejo**. |
| **Qué valida** | Self-healing de Kubernetes + probes (§7.4) + umbral `for:` de alerting (§7.1). |
| **Resultado real** | _[pendiente de ejecución en vivo]_ |

## Experimento 2 — Network partition (`chaos/experiments/partition-dashboard-promotion.yaml`)

| | |
|---|---|
| **Hipótesis** | Si dashboard-service queda incomunicado de promotion-service, el circuit breaker `promotionService` abre tras ≥50% de fallos en su ventana (COUNT_BASED 10, mínimo 5 llamadas) y el dashboard sigue respondiendo 200 con el fallback degradado — sin cascada de 5xx. |
| **Inyección** | `NetworkChaos action: partition, direction: both` entre dashboard y promotion, `duration: 5m` (auto-revert). |
| **Verificación automática** | El workflow genera 10 llamadas a `/api/v1/analytics/health-board` (puebla la ventana del breaker), consulta Prometheus `resilience4j_circuitbreaker_state{name="promotionService",state="open"}` hasta 2 min y **falla si nunca llega a 1**; advierte si el body no contiene el marcador de fallback. |
| **Qué valida** | Circuit Breaker (§3.2) + degradación elegante + alerta `CircuitBreakerOpen` → Alertmanager → MailHog (§7.1). Recuperación: al expirar el duration, HALF_OPEN → CLOSED sin intervención. |
| **Resultado real** | _[pendiente de ejecución en vivo]_ |

> **Ajuste vs el tracker:** el plan original proponía particionar `promotion → notification`, pero ese camino es **Kafka** — no hay circuit breaker que validar ahí (Kafka ya tolera la indisponibilidad del consumidor: los mensajes esperan en el topic). El camino HTTP real protegido por breaker es `dashboard → promotion`, así que el experimento se alineó a la arquitectura real.

> **Hallazgo de diseño (corregido antes del experimento):** los clientes `PromotionClient` y `IdentityClient` no definían timeouts — bajo partición las llamadas colgarían indefinidamente y el breaker **nunca** habría abierto. Se añadieron `connectTimeout=2s` / `readTimeout=3s`; los timeouts son lo que convierte una caída en fallos contables para el breaker. Este es exactamente el tipo de hueco que el chaos engineering existe para exponer.

## Experimento 3 — Resource stress (`chaos/experiments/stress-promotion.yaml`)

| | |
|---|---|
| **Hipótesis** | Bajo presión de CPU dentro del pod, la latencia sube de forma observable (Grafana/Prometheus) pero el límite de CPU del chart contiene el impacto: ni el nodo ni los demás servicios se degradan. |
| **Inyección** | `StressChaos` CPU `workers: 2, load: 80`, `mode: one`, `duration: 5m`. |
| **Verificación automática** | Baseline de `system_cpu_usage{app="promotion-service"}` (≈0.015 medido), inyección, espera 90s y **falla si el valor no se multiplica ≥2× y supera 0.10**. |
| **Qué valida** | Resource limits como bulkhead intra-nodo (§3.1) + paneles p95/CPU (§7.1) + alerta `HighRequestLatency` si se supera el umbral. |
| **Resultado real** | _[pendiente de ejecución en vivo]_ |

## Runbook de la sesión en vivo (~30 min)

1. (Opcional, si el headroom de CPU está justo) `./scripts/scale-up.sh 3`
2. Actions → **Bootstrap Chaos Mesh** → Run (una vez por cluster)
3. Actions → **Chaos Experiments** → Run ×3 (un run por experimento); cada run deja su veredicto en el step summary
4. Evidencia para la sustentación: captura del panel *Circuit Breaker State* en OPEN (Grafana), correo `CircuitBreakerOpen` en MailHog (`:8025`), `kubectl get pods -n stage` mostrando el pod regenerado, y los step summaries
5. Pegar los resultados reales en las secciones _[pendiente de ejecución en vivo]_ de este doc
6. `./scripts/scale-down.sh`

## Lecciones / cambios arquitectónicos derivados

- **Timeouts en clientes HTTP** (ver Experimento 2): añadidos a raíz del diseño del experimento. Sin chaos engineering, el breaker habría sido decorativo ante particiones de red.
- _[completar tras la ejecución en vivo si surgen más]_
