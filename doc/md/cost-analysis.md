# CircleGuard — Análisis de Costos de Infraestructura

**Plataforma:** AWS · Región `us-east-1` (N. Virginia)
**Modelo de precios:** On-Demand, precios de lista AWS (junio 2026)
**Fuente de los recursos:** `terraform/aws/` (config real, no estimación arbitraria)
**Última actualización:** 2026-06-09

> Las cifras son **estimaciones de lista** para dimensionar el proyecto académico.
> El costo real depende del tráfico (datos procesados por NAT/ALB, transferencia
> de salida) y de cuántas horas el cluster está encendido. Verificar siempre con
> [AWS Pricing Calculator](https://calculator.aws) y Cost Explorer para la factura real.

---

## 1. Recursos provisionados (derivados de Terraform)

| Recurso | Definición en código | Cantidad |
|---------|---------------------|----------|
| EKS control plane | `modules/eks-cluster` | 1 cluster (`circleguard-eks`, K8s 1.30) |
| Nodos EC2 | `node_instance_types = ["m7i-flex.large"]`, `node_desired_count = 3` | 3 × m7i-flex.large (2 vCPU / 8 GB) |
| EBS de nodos | EKS managed node group (default gp3 20 GB) | 3 × 20 GB = 60 GB |
| EBS de datos (PVC) | `infrastructure/chart/values.yaml` (postgres 2Gi, neo4j 2Gi, ES 10Gi…) | ~15–20 GB gp3 |
| NAT Gateway | `modules/vpc` — **1 solo NAT** (no per-AZ) | 1 |
| Elastic IP | `aws_eip.nat` (asociada al NAT) | 1 |
| Application Load Balancer | gateway (internet-facing) + dashboard (internal) | 2 |
| ECR | `modules/ecr` — repo único `circleguard`, lifecycle keep 20 | 1 repo |
| S3 (tfstate) | backend `circleguard-tfstate` | 1 bucket |
| Secrets Manager | `circleguard/{dev,stage,production}` + IRSA | 3–6 secrets |
| ACM certificate | self-signed importado | 1 (gratis) |

Aislamiento de ambientes = **namespaces** (`dev`/`stage`/`production`) en **un solo
cluster** → un único control plane y un único node group para los tres ambientes.

---

## 2. Costo mensual estimado — producción always-on (3 nodos, 730 h)

| Recurso | Cálculo | USD/mes |
|---------|---------|--------:|
| EKS control plane | $0.10/h × 730 h | **$73.00** |
| EC2 nodos (3× m7i-flex.large) | ~$0.0958/h × 3 × 730 h | **$209.70** |
| NAT Gateway (horas) | $0.045/h × 730 h | **$32.85** |
| NAT Gateway (datos) | ~$0.045/GB × ~100 GB | **~$4.50** |
| ALB × 2 (horas) | $0.0225/h × 2 × 730 h | **$32.85** |
| ALB × 2 (LCU) | tráfico bajo, ~$5/ALB | **~$10.00** |
| EBS gp3 (~80 GB total) | $0.08/GB-mes × 80 | **$6.40** |
| ECR storage | ~5 GB × $0.10/GB-mes | **$0.50** |
| Secrets Manager | $0.40/secret × ~4 | **$1.60** |
| S3 tfstate + requests | mínimo | **~$0.20** |
| Transferencia de salida | variable, estimado | **~$5.00** |
| CloudWatch logs/métricas | uso básico | **~$3.00** |
| **TOTAL producción always-on** | | **≈ $380 / mes** |

> Nota m7i-flex: las instancias *flex* dan rendimiento base con ráfagas; el precio
> de lista es ~5% menor que `m7i.large`. Si el burst se agota bajo carga sostenida,
> el rendimiento (no el costo) baja — adecuado para cargas académicas intermitentes.

---

## 3. Escenario realista de proyecto académico (encendido por demanda)

El cluster **no necesita estar 24/7**. Con `scripts/aws-down.sh` / `aws-up.sh` y uso
típico de ~6 h/día, 20 días/mes (~120 h vs 730 h):

| Componente | Always-on | Encendido ~120 h/mes | Ahorro |
|------------|----------:|---------------------:|-------:|
| Nodos EC2 (3×) | $209.70 | ~$34.50 | $175 |
| ALB × 2 | $42.85 | ~$12.00 | $31 |
| NAT Gateway | $37.35 | ~$10.00 | $27 |
| EKS control plane | $73.00 | $73.00 (no se apaga) | $0 |
| EBS (persiste) | $6.40 | $6.40 | $0 |
| Otros | ~$15 | ~$10 | $5 |
| **TOTAL** | **≈ $380** | **≈ $146 / mes** | **~$234 (~62%)** |

**Costo fijo inevitable** mientras el cluster exista: EKS control plane ($73) + EBS de
PVCs ($6). Para llevarlo casi a $0 hay que `terraform destroy` completo (`aws-down.sh`)
— el bucket S3 de estado sobrevive intencionalmente (<$1/mes) para recrear.

---

## 4. Estrategias de optimización (FinOps)

| Estrategia | Estado | Impacto |
|------------|--------|---------|
| 1 solo NAT gateway (no per-AZ) | ✅ implementado | ahorra ~$33/mes/AZ extra evitada |
| ECR lifecycle policy (keep 20 imágenes) | ✅ implementado | acota crecimiento de storage |
| Apagado por demanda (`aws-down.sh`) | ✅ script listo | ~62% en cómputo |
| `m7i-flex` (burstable) sobre `m7i` fijo | ✅ implementado | ~5% sobre nodos |
| Spot instances para node group | ❌ pendiente | hasta -70% en nodos |
| Graviton (`m7g`/`t4g`) en lugar de x86 | ❌ pendiente | ~20% sobre nodos |
| HPA (gateway + auth, min=1/max=3/CPU 70%) | ✅ implementado | ~$12–15/mes en horas valle |
| AWS Budgets + alerta de costo ($20/mes, 80%+100%) | ✅ implementado (IaC) | gobernanza |

> El bonus **FinOps** del enunciado pediría: Budgets en Terraform, dashboards de costo
> en Grafana, y spot/scale-to-zero. Las dos primeras filas ✅ ya cubren parte de
> "políticas de ahorro"; spot + KEDA son el siguiente paso de mayor impacto.

---

## 5. Comparación rápida con alternativa multi-cloud (referencia)

El bonus Multi-Cloud desplegaría también en Azure AKS. Para dimensionar:

| Concepto | AWS EKS | Azure AKS |
|----------|---------|-----------|
| Control plane | $0.10/h (~$73/mes) | gratis (tier estándar de pago: ~$73/mes por SLA) |
| Nodo equivalente (2vCPU/8GB) | m7i-flex.large ~$0.096/h | Standard_D2s_v5 ~$0.096/h |
| Load balancer | ALB ~$0.0225/h + LCU | Standard LB ~$0.025/h + reglas |

Costos comparables; la elección AWS+Azure es por documentación/ecosistema, no precio.

---

*Cifras de lista us-east-1, junio 2026. Para la factura real usar AWS Cost Explorer
filtrando por tag `Project=circleguard` (aplicado vía `default_tags` en `main.tf`).*

---

## 6. Ahorros con HPA (implementado — gateway-service y auth-service)

Con `HorizontalPodAutoscaler` activado (min=1, max=3, target CPU 70%) en los dos
servicios de mayor tráfico externo:

| Escenario | Réplicas promedio | EC2 equivalente | USD/mes (nodo ~$0.096/h) |
|-----------|------------------:|-----------------|------------------------:|
| Sin HPA (fijo 1 réplica/servicio) | 2 pods activos siempre | 2 × 100m CPU / 128Mi mem | —$0 ahorro |
| Con HPA en horas valle (~12h/día) | escala a 1 pod c/u | ahorra ~1 pod × 12h × 20d = 240h | ~$12–15 / mes |

> El ahorro real depende del perfil de carga. En entorno académico con tráfico muy
> bajo en horas no laborables, el HPA mantiene mínimo 1 réplica y evita que el
> scheduler tenga que provisionar nodos extra bajo picos cortos.

---

## 7. Resumen consolidado de estrategias FinOps implementadas

| # | Estrategia | Estado | Ahorro estimado/mes |
|---|------------|--------|--------------------:|
| 1 | NAT Gateway único (no per-AZ) | ✅ | ~$33 vs. multi-NAT |
| 2 | ECR lifecycle policy (keep 20 imgs) | ✅ | acota storage; ~$0 en escala actual |
| 3 | `m7i-flex.large` (burstable) vs `m7i` | ✅ | ~$10 sobre 3 nodos |
| 4 | Apagado por demanda (`aws-down.sh`) | ✅ | ~$234 (62%) en modo on-demand 120h |
| 5 | Resource tagging (`Project=circleguard`) | ✅ | gobernanza — filtra en Cost Explorer |
| 6 | **HPA** gateway + auth (min=1, max=3) | ✅ | ~$12–15 en horas valle |
| 7 | **AWS Budgets** $20/mes alerta 80%/100% | ✅ (IaC) | gobernanza — evita sorpresas |
| 8 | **Dashboard Grafana FinOps** (CPU/mem utilization + HPA) | ✅ | visibilidad continua |
| 9 | Spot instances para node group | ❌ pendiente | hasta -70% en nodos |
| 10 | Graviton (`m7g`) en lugar de x86 | ❌ pendiente | ~20% en nodos |

**Total estrategias activas:** 8 de 10. Ahorro máximo realizable con configuración
actual (modo on-demand 120h/mes): **≈ $270–290 / mes** vs. always-on sin optimizar.
