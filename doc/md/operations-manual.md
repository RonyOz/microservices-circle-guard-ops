# CircleGuard — Manual de Operaciones

**Versión:** 1.0  
**Plataforma:** AWS EKS (us-east-1) + GitHub Actions  
**Cluster:** `circleguard-eks`  
**Ambientes:** `dev` · `stage` · `production` (namespaces del mismo cluster)

---

## 1. Prerrequisitos

| Herramienta | Versión mínima | Instalación |
|-------------|---------------|-------------|
| `aws-cli` | v2 | `brew install awscli` |
| `kubectl` | 1.29 | `brew install kubectl` |
| `helm` | 3.14 | `brew install helm` |
| `terraform` | 1.7 | `brew install terraform` |
| `doctl` / `jq` | cualquiera | opcionales, útiles para debug |

### Configurar credenciales locales

```bash
aws configure                   # access key + us-east-1
aws eks update-kubeconfig \
  --name circleguard-eks \
  --region us-east-1
kubectl get nodes               # debe listar los nodos del cluster
```

---

## 2. Bootstrap — cluster nuevo

Ejecutar en orden. Los pasos 0a/0b son locales y requieren credenciales de administrador AWS.

```bash
# 0a. Crear bucket S3 para estado de Terraform (solo una vez por cuenta)
./scripts/init-s3-backend.sh

# 0b. Provisionar VPC, EKS, ECR, OIDC provider, IRSA roles
./scripts/aws-up.sh
# → al finalizar, copiar la salida gha_role_arn y registrarla como
#   GitHub Secret: AWS_ROLE_ARN en ambos repos (dev y ops)

# 1. Instalar External Secrets Operator (ESO) y ClusterSecretStore
#    Ejecutar en GitHub Actions → bootstrap-eso.yml → Run workflow

# 2. Desplegar backing services (PostgreSQL, Neo4j, Kafka, Redis, LDAP, Jaeger, ELK…)
#    Ejecutar en GitHub Actions → deploy-data-plane.yml → Run workflow
#    Repetir para cada namespace: dev, stage, production

# 3. Desplegar servicios de aplicación
#    Se activan automáticamente vía repository_dispatch desde el dev repo.
#    Para forzar un redeploy manual, ver sección 4.
```

---

## 3. Secretos en runtime

Los secretos se almacenan en **AWS Secrets Manager** y se inyectan en pods via **External Secrets Operator** (IRSA).

| Secret Managers path | Contenido |
|---------------------|-----------|
| `circleguard/dev` | DB_PASSWORD, NEO4J_PASSWORD, JWT_SECRET |
| `circleguard/stage` | ídem |
| `circleguard/production` | ídem |

### Rotar un secreto

```bash
# 1. Actualizar en AWS Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id "circleguard/production" \
  --secret-string "{\"DB_PASSWORD\":\"NUEVO_VALOR\", ...}"

# 2. Forzar que ESO recargue el ExternalSecret (o esperar 1h al refresco automático)
kubectl annotate externalsecret circleguard-secrets \
  -n production \
  force-sync=$(date +%s) --overwrite

# 3. Reiniciar pods afectados para que lean la nueva variable
kubectl rollout restart deployment/<service-name> -n production
```

---

## 4. Despliegues manuales

### Redesplegar un servicio en producción

```bash
IMAGE_TAG="auth-service-sha-abc1234"  # tag existente en ECR

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

helm upgrade --install auth-service services/auth-service/chart/ \
  --namespace production \
  --set image.repository=${REGISTRY}/circleguard \
  --set image.tag=${IMAGE_TAG} \
  --wait --timeout 5m
```

### Habilitar Ingress con TLS (gateway-service)

```bash
CERT_ARN="arn:aws:acm:us-east-1:<account>:certificate/<id>"

helm upgrade gateway-service services/gateway-service/chart/ \
  --namespace production \
  --reuse-values \
  --set ingress.enabled=true \
  --set ingress.host=gateway.circleguard.edu \
  --set "ingress.certificateArn=${CERT_ARN}"
```

> **Requisito:** el AWS Load Balancer Controller debe estar instalado en el cluster.  
> Instalar: `helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=circleguard-eks`

---

## 5. Monitoreo

### Acceso a dashboards (port-forward local)

```bash
# Grafana — http://localhost:3000  (admin / ver GF_SECURITY_ADMIN_PASSWORD en values.yaml)
kubectl port-forward -n production svc/grafana 3000:3000

# Prometheus — http://localhost:9090
kubectl port-forward -n production svc/prometheus 9090:9090

# Jaeger UI (trazas distribuidas) — http://localhost:16686
kubectl port-forward -n production svc/jaeger 16686:16686

# Kibana (logs ELK) — http://localhost:5601
kubectl port-forward -n production svc/kibana 5601:5601

# SonarQube — http://localhost:9000  (admin / admin, cambiar en primer login)
kubectl port-forward -n production svc/sonarqube 9000:9000
```

### Alertas Prometheus activas

| Alerta | Condición | Severidad |
|--------|-----------|-----------|
| `ServiceDown` | Pod inalcanzable por 2 min | critical |
| `HighHttpErrorRate` | >5% de requests con 5xx por 5 min | warning |
| `CircuitBreakerOpen` | Resilience4j circuit abierto >1 min | warning |
| `HighRequestLatency` | p95 > 2s por 5 min | warning |
| `HighExposurePromotionRate` | Tasa anómala de promociones de estado de salud (métrica de negocio) | warning |

---

## 6. Rollback

### Rollback de un servicio (Helm)

```bash
# Ver historial de releases
helm history auth-service -n production

# Rollback a la revisión anterior
helm rollback auth-service -n production

# Rollback a una revisión específica
helm rollback auth-service 3 -n production --wait
```

### Rollback de infraestructura (Terraform)

Los cambios de infraestructura se aplican localmente. Para revertir:

```bash
# Revertir el commit en este repo y re-aplicar
git revert <commit>
./scripts/aws-up.sh    # re-aplica el estado anterior
```

El estado está respaldado en S3 — nunca modificar `terraform.tfstate` manualmente.

---

## 7. Escalado manual

```bash
# Escalar replicas de un servicio
kubectl scale deployment auth-service --replicas=3 -n production

# Ver uso de recursos por pod
kubectl top pods -n production

# Ver eventos recientes (útil para diagnosticar fallos de scheduling)
kubectl get events -n production --sort-by='.lastTimestamp' | tail -20
```

---

## 8. Diagnóstico rápido

```bash
# Estado general del namespace
kubectl get all -n production

# Logs de un servicio (últimas 200 líneas)
kubectl logs -l app.kubernetes.io/name=auth-service -n production --tail=200

# Logs en tiempo real
kubectl logs -f -l app.kubernetes.io/name=gateway-service -n production

# Describir un pod con error
kubectl describe pod <pod-name> -n production

# Revisar circuit breakers vía Actuator
kubectl port-forward -n production svc/auth-service 8081:8081
curl http://localhost:8081/actuator/health | jq '.components.circuitBreakers'

# Métricas Prometheus de un servicio
curl http://localhost:8081/actuator/prometheus | grep resilience4j
```

### Errores comunes

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| Pod en `CrashLoopBackOff` | Falta variable de entorno / secreto no montado | `kubectl describe pod` → ver Events; verificar ExternalSecret |
| `ImagePullBackOff` | Tag de imagen no existe en ECR o permisos IRSA | Verificar tag con `aws ecr list-images --repository-name circleguard` |
| Circuit breaker abierto | Downstream service caído o lento | Revisar logs del servicio destino; esperar `wait-duration-in-open-state` (10s default) |
| Kafka consumer lag alto | Promotion/notification-service saturado | Escalar replicas; revisar `kubectl top pods` |
| DB connection pool exhausted | Demasiadas conexiones simultáneas | Revisar `spring.datasource.hikari.maximum-pool-size` en ConfigMap |

---

## 9. Ciclo de vida de un release

```
feat/fix commit en dev repo
    └─ CI: test → build → push ECR → repository_dispatch
           ├─ deploy-dev.yml     → namespace dev  (automático)
           └─ deploy-stage.yml   → namespace stage (automático)
                  ├─ Trivy scan (reporte)
                  ├─ E2E + ZAP + Locust
                  └─ repository_dispatch → deploy-prod.yml
                         ├─ Trivy gate (bloquea si HIGH/CRITICAL)
                         ├─ Aprobación manual (GitHub Environment: production)
                         ├─ helm upgrade --atomic
                         └─ release-notes (git-cliff → GitHub Release)
```

Para **aprobar un deploy a producción**: ir a la GitHub Action en cola → "Review deployments" → Approve.

Para **rechazar y mantener la versión actual**: "Reject" — el `helm upgrade` no se ejecuta y el release anterior sigue activo.

---

## 10. Apagado de infraestructura (ahorro de costos)

```bash
# Destruir cluster y recursos AWS (⚠️ irreversible para datos en PVCs)
./scripts/aws-down.sh

# El bucket S3 de estado Terraform NO se destruye (intencional — sobrevive para recrear)
```

Para recrear desde cero: `./scripts/aws-up.sh` seguido del bootstrap completo (sección 2).

### Costo de mantener el cluster encendido

Producción always-on ≈ **$380/mes**; con apagado por demanda (`aws-down.sh`/`aws-up.sh`,
~120 h/mes) baja a ≈ **$146/mes**. Costo fijo inevitable mientras exista el cluster:
EKS control plane ($73) + EBS de PVCs ($6). Detalle completo y estrategias FinOps en
[`cost-analysis.md`](./cost-analysis.md).

---

*Última actualización: 2026-06-09*
