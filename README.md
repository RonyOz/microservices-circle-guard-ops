# circleguard-ops

Repositorio de operaciones para CircleGuard. Contiene la infraestructura como código (Terraform), los Helm charts de los microservicios y los pipelines de Jenkins para los tres ambientes del taller 2.

---

## Estructura del repositorio

```
circleguard-ops/
├── terraform/
│   ├── main.tf                        # Módulos: jenkins-vm + k8s-cluster
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example       # Copiar → terraform.tfvars (no commitear)
│   └── modules/
│       ├── jenkins-vm/                # Droplet DO: Jenkins + Docker (encender/apagar)
│       └── k8s-cluster/               # DOKS + DOCR + namespaces
│
├── infrastructure/
│   ├── values-postgresql.yaml         # Bitnami PostgreSQL
│   ├── values-kafka.yaml              # Bitnami Kafka (KRaft)
│   ├── values-neo4j.yaml              # Neo4j
│   └── values-redis.yaml              # Bitnami Redis
│
├── {servicio}/chart/                  # Helm chart por microservicio
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       └── service.yaml
│
├── jenkins/
│   ├── Jenkinsfile.dev                # Deploy a namespace dev
│   ├── Jenkinsfile.stage              # Deploy + tests completos a stage
│   └── Jenkinsfile.prod               # Deploy + release notes a production
│
├── locust/
│   ├── auth-service/locustfile.py
│   └── contact-tracing-service/locustfile.py
│
├── scripts/
│   ├── bootstrap-cluster.sh           # Ejecutar UNA VEZ tras terraform apply
│   └── deploy-infrastructure.sh       # Instalar Kafka/PG/Neo4j/Redis en un namespace
│
└── cliff.toml                         # Configuración git-cliff (release notes)
```

---

## Flujo CI/CD completo

```
app-repo (develop push)
    │
    ▼
Jenkins webhook recibido
    ├── Jenkinsfile.dev   → namespace dev   (deploy + smoke test)
    └── Jenkinsfile.stage → namespace stage  (deploy + unit + integration + E2E + Locust)

app-repo (main push)
    │
    ▼
Jenkins webhook recibido
    └── Jenkinsfile.prod  → namespace production (unit tests + deploy --atomic + release notes)
```

---

## Primeros pasos

### 1. Requisitos locales

```bash
# Terraform >= 1.6
brew install terraform

# doctl (Digital Ocean CLI)
brew install doctl
doctl auth init   # pega tu DO API token

# kubectl + helm
brew install kubectl helm
```

### 2. Provisionar infraestructura

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars: do_token, ssh_key_ids, etc.

# Crear SOLO el clúster K8s primero
terraform init
terraform apply -target=module.k8s_cluster

# Crear la VM de Jenkins
terraform apply -target=module.jenkins_vm
```

### 3. Bootstrap del clúster (una sola vez)

```bash
chmod +x scripts/bootstrap-cluster.sh
./scripts/bootstrap-cluster.sh circleguard-k8s circleguard
```

Este script: obtiene el kubeconfig, crea los namespaces `dev`/`stage`/`production`, vincula DOCR al clúster y agrega los repos de Helm.

### 4. Desplegar infraestructura compartida

```bash
chmod +x scripts/deploy-infrastructure.sh
./scripts/deploy-infrastructure.sh dev
./scripts/deploy-infrastructure.sh stage
./scripts/deploy-infrastructure.sh production
```

Instala PostgreSQL, Neo4j, Kafka y Redis en cada namespace.

### 5. Configurar Jenkins

Acceder a `http://<jenkins_ip>:8080` (ver output de Terraform).

Credenciales a crear en Jenkins → Manage → Credentials:

| ID | Tipo | Descripción |
|---|---|---|
| `kubeconfig-doks` | Secret file | kubeconfig del clúster DOKS |
| `do-api-token` | Secret text | DO API token |
| `github-token` | Secret text | GitHub token (release notes) |

Crear tres Pipeline jobs apuntando a este repo:
- `circleguard-dev`   → `jenkins/Jenkinsfile.dev`
- `circleguard-stage` → `jenkins/Jenkinsfile.stage`
- `circleguard-prod`  → `jenkins/Jenkinsfile.prod`

### 6. Gestión del ciclo de vida de la VM Jenkins

```bash
# Obtener el ID del Droplet
terraform output  # muestra jenkins_ip, etc.
doctl compute droplet list --format ID,Name,Status

# Apagar cuando termines de trabajar
doctl compute droplet-action power-off --droplet-id <ID> --wait

# Encender cuando retomes
doctl compute droplet-action power-on --droplet-id <ID> --wait

# La IP puede cambiar al encender — revisar con:
doctl compute droplet get <ID> --format PublicIPv4
```

> Si la IP cambia, actualizar el webhook en GitHub y la credencial `kubeconfig-doks` si el servidor de API del clúster es el mismo (DOKS mantiene IP fija).

---

## Estrategia de branching — ops-repo

**Trunk-Based Development** (igual que en taller 1):

| Tipo | Patrón | Vida máxima |
|---|---|---|
| Permanente | `main` | Indefinida |
| Actualización | `update/<componente>` | 2 días |
| Fix | `fix/<descripción>` | 2 días |

Los PRs son obligatorios. El ambiente destino llega como parámetro del trigger desde app-repo.

---

## Patrones de diseño implementados

**Bulkhead** — namespaces `dev`, `stage` y `production` completamente aislados. Un fallo en stage no afecta producción.

**Retry** — `helm upgrade --atomic` en Jenkinsfile.prod hace rollback automático si el deploy falla. Los Helm charts incluyen `livenessProbe` y `readinessProbe`.

**Release notes automáticas** — `git-cliff` parsea conventional commits (`feat`/`fix`/`chore`) y genera el CHANGELOG + GitHub Release en cada deploy a producción.

---

## Costos estimados (Digital Ocean)

| Recurso | Tamaño | Costo |
|---|---|---|
| VM Jenkins | s-1vcpu-2gb | ~$0.018/hr (solo cuando está encendida) |
| DOKS nodo | s-2vcpu-4gb | ~$24/mes |
| DOCR | Free tier | $0 |
| **Total activo** | | **~$24/mes + horas Jenkins** |
