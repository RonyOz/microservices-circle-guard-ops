# Informe de operaciones — CircleGuard

**Curso**: DevOps / Pruebas y Calidad de Software
**Repositorio de operaciones**: [microservices-circle-guard-ops](https://github.com/RonyOz/microservices-circle-guard-ops)
**Repositorio de aplicación**: [microservices-circle-guard-dev](https://github.com/RonyOz/microservices-circle-guard-dev)
  **Proveedor de nube**: DigitalOcean

---

## Resumen

Este documento registra, en orden cronológico, la implementación de la plataforma de CI/CD para los microservicios CircleGuard. La infraestructura se gestiona con **Terraform** sobre **DigitalOcean**, los pipelines se orquestan con **Jenkins** sobre un droplet dedicado, y los despliegues se realizan sobre un clúster **DOKS** (DigitalOcean Kubernetes) hacia los namespaces `dev`, `stage` y `production`.

Cada procedimiento está documentado con (a) el contexto operativo, (b) los comandos ejecutados, (c) el resultado verificable, y (d) cuando aplica, los incidentes encontrados y su corrección. La bitácora de incidentes (sección 8) actúa como evidencia de la capacidad de diagnóstico y resolución del autor.

---

## 1. Inventario y arquitectura

### 1.1 Recursos provisionados

| Componente | Tecnología | Rol |
|---|---|---|
| Infraestructura como código | Terraform 1.6+, provider `digitalocean ~> 2.39` | Definición declarativa, idempotente y versionada de toda la infraestructura |
| VPC | DigitalOcean VPC `10.20.0.0/16` | Red privada compartida entre Jenkins y DOKS, aislada de Internet |
| Servidor de CI | Droplet `s-1vcpu-2gb` Ubuntu 22.04 | Ejecuta Jenkins LTS y todas las herramientas necesarias para los pipelines |
| Estado de Jenkins | Block Storage 10 GB ext4 | `JENKINS_HOME` persistente, independiente del ciclo de vida del droplet |
| Clúster Kubernetes | DOKS 1 nodo `s-2vcpu-4gb`, versión 1.33.9-do.3 | Plataforma de despliegue para microservicios y dependencias |
| Registro de imágenes | DigitalOcean Container Registry (tier starter) | Repositorio único `registry.digitalocean.com/circleguard/circleguard-services` con tags por servicio |

### 1.2 Diagrama de arquitectura

```
                          DigitalOcean
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                  │
  │   VPC circleguard-vpc (10.20.0.0/16)                             │
  │   ┌────────────────────┐         ┌────────────────────────────┐  │
  │   │ Droplet            │         │ DOKS cluster (1.33.9-do.3) │  │
  │   │ circleguard-jenkins│ ──────> │ namespaces dev/stage/prod  │  │
  │   │ Jenkins + Docker   │  helm/  │ + Postgres / Kafka / Neo4j │  │
  │   │ Volume jenkins-home│  kubectl│   / Redis (vía Helm)       │  │
  │   └────────────────────┘         └────────────────────────────┘  │
  │              │                                  ^                │
  │              │ docker push                      │ image pull     │
  │              v                                  │                │
  │   ┌─────────────────────────────────────────────┴──────────────┐ │
  │   │  DOCR registry.digitalocean.com/circleguard/circleguard-services │ │
  │   └────────────────────────────────────────────────────────────┘ │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
```

### 1.3 Decisiones de diseño relevantes

| Decisión | Justificación técnica |
|---|---|
| **VPC explícita** en Terraform | DigitalOcean no auto-provisiona una VPC default en todas las regiones para cuentas nuevas; declararla explícitamente evita el error `Failed to resolve VPC` documentado en la sección 8.3. |
| **Volumen persistente para JENKINS_HOME** | Los droplets apagados en DigitalOcean **siguen facturando** según su [documentación de billing](https://docs.digitalocean.com/products/billing/billing-faq/). Para minimizar costos sin perder estado, el droplet se trata como recurso efímero (se destruye fuera de horas de trabajo) y `JENKINS_HOME` reside en un Block Storage independiente que sobrevive a la destrucción. Costo idle ~$1/mes vs ~$13/mes de mantener el droplet apagado. |
| **DOCR en región distinta del clúster** | DOCR solo está disponible en `nyc3, sfo3, ams3, sgp1, fra1, syd1`. El clúster opera en `nyc1` y el registry en `nyc3`; la separación se modeló como variable independiente `registry_region`. El pull funciona correctamente porque DOCR expone un endpoint global. |
| **Repo único en DOCR starter** | El tier starter limita el número de repositorios. Para evitar bloqueos de despliegue multi-servicio, se consolidó en `circleguard-services` y se usa tagging `<service>-sha-<commit>`. |
| **Patrón Bulkhead vía namespaces** | Los tres ambientes (`dev`, `stage`, `production`) viven en el mismo clúster pero en namespaces aislados. Un fallo o consumo excesivo en `stage` no afecta a `production`. Reduce el costo de un clúster por ambiente sin sacrificar aislamiento lógico. |
| **Versión de Kubernetes resuelta dinámicamente** | El módulo usa el data source `digitalocean_kubernetes_versions` con prefijo `1.33.` en lugar de un slug hardcoded. Evita que el Terraform se rompa cuando DigitalOcean retira versiones antiguas (incidente 8.1). |

---

## 2. Estructura del repositorio de operaciones

```
microservices-circle-guard-ops/
├── terraform/
│   ├── main.tf                    Composición top-level (VPC + volumen + módulos)
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── jenkins-vm/            Droplet, firewall, cloud-init, montaje de volumen
│       └── k8s-cluster/           DOKS, DOCR, data source de versiones
├── infrastructure/
│   └── chart/                     Helm chart de dependencias compartidas (postgres, neo4j, kafka, zookeeper, redis, openldap, mailhog)
├── services/
│   ├── auth-service/chart/
│   ├── form-service/chart/
│   ├── gateway-service/chart/
│   ├── identity-service/chart/
│   ├── notification-service/chart/
│   └── promotion-service/chart/
├── jenkins/
│   ├── Jenkinsfile.infra          Despliegue de infra compartida
│   ├── Jenkinsfile.dev            Deploy a dev por servicio
│   ├── Jenkinsfile.stage          Deploy + pruebas completas en stage por servicio
│   └── Jenkinsfile.prod           Unit test + deploy --atomic + release notes en production
├── locust/                        Escenarios de carga por servicio (consumidos por Jenkinsfile.stage)
├── scripts/
│   ├── up-jenkins.sh              Levanta VPC + volumen + droplet
│   ├── down-jenkins.sh            Destruye droplet, conserva volumen
│   ├── up-cluster.sh              Levanta DOKS + DOCR
│   ├── down-cluster.sh            Destruye DOKS + DOCR
│   ├── bootstrap-cluster.sh       Invocado desde Jenkinsfile.infra
│   └── deploy-infrastructure.sh   Invocado desde Jenkinsfile.infra
├── doc/
│   └── informe.md                 Este documento
└── cliff.toml                     Config de generación de release notes
```

---

## 3. Procedimiento — Provisión de la infraestructura base

> **Criterio de evaluación**: punto 1 del taller (10%) — *Configurar Jenkins, Docker y Kubernetes*.

### 3.1 Prerrequisitos

```bash
brew install terraform doctl kubectl helm   # macOS
# o el equivalente Apt/Chocolatey según plataforma

doctl auth init   # autenticar contra el API de DigitalOcean
```

Se requiere un *Personal Access Token* generado en `https://cloud.digitalocean.com/account/api/tokens` con scope al menos lectura/escritura sobre Droplets, Kubernetes, Container Registry y VPC.

### 3.2 Configuración de variables

El archivo `terraform/terraform.tfvars` (excluido de Git) contiene:

```hcl
do_token     = "dop_v1_..."
ssh_key_ids  = ["aa:bb:cc:..."]   # fingerprint listado por `doctl compute ssh-key list`
do_region    = "nyc1"
```

Los valores restantes (nombre del clúster, tamaño del nodo, región del registry, etc.) usan los defaults de [terraform/variables.tf](../terraform/variables.tf).

### 3.3 Aplicación por capas

Se utilizan scripts wrapper que ejecutan `terraform apply` con el flag `-target` para cada módulo. Esto permite levantar y destruir Jenkins y el clúster de forma independiente y minimizar costos.

```bash
./scripts/up-jenkins.sh    # Crea VPC + Volume + Droplet (~5 min de provisión + cloud-init)
./scripts/up-cluster.sh    # Crea DOKS + DOCR (~6 min)
```

### 3.4 Verificación

Tras la ejecución, se comprueba el estado real consultando el API de DigitalOcean:

```bash
doctl compute droplet list --format ID,Name,Status,PublicIPv4
# 567635712   circleguard-jenkins   active   157.245.89.61

doctl kubernetes cluster list --format ID,Name,Region,Version,Status
# ee80328c-...   circleguard-k8s   nyc1   1.33.9-do.3   running

doctl registry get
# circleguard   registry.digitalocean.com/circleguard   nyc3
```

---

## 4. Procedimiento — Estrategia de costos y ciclo de vida

> Justificación operativa para el uso responsable de créditos académicos.

### 4.1 Modelo de costos

| Recurso | Costo cuando existe | Política aplicada |
|---|---|---|
| VPC | $0 | Permanente |
| DOCR (starter) | $0 | Permanente |
| Volume `jenkins-home` (10 GB) | ~$1/mes | Permanente; preserva estado de Jenkins |
| Droplet Jenkins | $0.018/hr (~$13/mes 24×7) | Crear al inicio de la sesión, **destruir** al cierre |
| DOKS 1 nodo | $0.033/hr (~$24/mes 24×7) | Crear únicamente cuando se va a desplegar/probar |

**Costo en idle** (todo destruido excepto VPC, DOCR y volumen): aproximadamente $1 USD al mes.

**Costo de una sesión típica de 8 h con todos los recursos activos**: $1/mes prorrateado + 8 × ($0.018 + $0.033) ≈ **$0.41 USD por sesión**.

### 4.2 Workflow operativo

**Inicio de sesión**:
```bash
./scripts/up-jenkins.sh
./scripts/up-cluster.sh
# → Disparar el job circleguard-infra en Jenkins con ENVIRONMENT=dev
```

**Cierre de sesión**:
```bash
./scripts/down-cluster.sh    # ~2 min
./scripts/down-jenkins.sh    # ~30 s; el volumen sobrevive
```

En la siguiente sesión, `up-jenkins.sh` recrea el droplet, monta el volumen existente y Jenkins arranca con todos los jobs, plugins y credenciales de la sesión previa intactos. El único atributo que cambia entre sesiones es la IP pública del droplet.

### 4.3 Mecánica del volumen persistente

El cloud-init del droplet ejecuta, en cada arranque:

```bash
DEVICE=/dev/disk/by-id/scsi-0DO_Volume_jenkins-home
# Espera hasta 120 s a que el dispositivo esté presente
for i in $(seq 1 60); do [ -b "$DEVICE" ] && break; sleep 2; done
# Formatea solo si no tiene filesystem (primera ejecución absoluta)
if ! blkid "$DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -F "$DEVICE"
fi
mkdir -p /var/lib/jenkins
echo "$DEVICE /var/lib/jenkins ext4 defaults,nofail,discard 0 2" >> /etc/fstab
mount /var/lib/jenkins
# Posteriormente apt instala Jenkins y --recursivamente reasigna ownership
chown -R jenkins:jenkins /var/lib/jenkins
```

La primera vez formatea el disco; en arranques posteriores reconoce el filesystem y monta sin reformatear, preservando el contenido. La reasignación de ownership es necesaria porque el UID del usuario `jenkins` puede diferir entre droplets recreados.

---

## 5. Procedimiento — Configuración inicial de Jenkins

> **Criterio de evaluación**: punto 1 del taller (10%) — *Configurar Jenkins*.

### 5.1 Acceso

Tras `up-jenkins.sh`, se espera ~5 minutos a que el cloud-init termine la instalación de Docker, Java 21, Jenkins LTS, kubectl, helm y doctl. Verificación:

```bash
ssh root@<jenkins_ip> 'cloud-init status'        # esperado: status: done
ssh root@<jenkins_ip> 'systemctl is-active jenkins'   # esperado: active
curl -sI http://<jenkins_ip>:8080                # esperado: HTTP/1.1 403
```

El código 403 es esperado: corresponde a la pantalla de login del setup wizard.

### 5.2 Setup wizard

1. Obtener la contraseña inicial:
   ```bash
   ssh root@<jenkins_ip> 'cat /var/lib/jenkins/secrets/initialAdminPassword'
   ```
2. Acceder a `http://<jenkins_ip>:8080`, pegar la contraseña, completar `Install suggested plugins` (~5 min).
3. Crear el usuario administrador. Como `JENKINS_HOME` reside en el volumen persistente, este usuario sobrevive a destrucciones del droplet.

### 5.3 Plugins adicionales requeridos

Instalados desde `Manage Jenkins → Plugins → Available`, seguidos de un reinicio explícito (`systemctl restart jenkins`).

| Plugin | Uso |
|---|---|
| AnsiColor | Coloreado de la consola (declarativa `options { ansiColor('xterm') }`) |
| Kubernetes CLI | Integración de `kubectl`/`helm` dentro de pipelines |
| HTML Publisher | Publicación de reportes Locust como contenido HTML embebido en Jenkins |
| Pipeline: Groovy | Soporte de Jenkins Declarative Pipeline usado en todos los Jenkinsfile |

### 5.4 Credenciales

`Manage Jenkins → Credentials → System → Global credentials`:

| ID | Tipo | Origen del valor |
|---|---|---|
| `do-api-token` | Secret text | Mismo token del archivo `terraform.tfvars` |
| `github-token` | Secret text | *Personal Access Token* de GitHub con scopes `repo` y `workflow` |
| `db-credentials` | Username/Password | Usuario/clave compartida para secretos de BD en K8s |
| `jwt-secret` | Secret text | Secreto JWT inyectado en secretos por servicio |

### 5.5 Jobs de pipeline

Los jobs de ops son del tipo *Pipeline* con `Definition: Pipeline script from SCM` apuntando a este repositorio (rama `main`):

| Nombre del job | Script Path | Disparo |
|---|---|---|
| `circleguard-infra` | `jenkins/Jenkinsfile.infra` | Manual (Build with Parameters) |
| `circleguard-deploy-dev` | `jenkins/Jenkinsfile.dev` | Trigger desde pipelines de servicio del app-repo (`branch=dev`) |
| `circleguard-deploy-stage` | `jenkins/Jenkinsfile.stage` | Trigger desde pipelines de servicio del app-repo (`branch=release/*`) |
| `circleguard-deploy-prod` | `jenkins/Jenkinsfile.prod` | Trigger desde pipelines de servicio del app-repo (`branch=main`) |

Los tres jobs de deploy reciben parámetros `SERVICE` e `IMAGE_TAG` (y en prod además `GIT_COMMIT`, `VERSION`) para desplegar cada servicio de forma independiente.

## 6. Procedimiento — Pipeline `circleguard-infra`

> **Criterio de evaluación**: punto 1 (10%) — *Configurar Kubernetes con dependencias*.

### 6.1 Propósito

Despliega de forma idempotente las dependencias compartidas (PostgreSQL, Neo4j, Kafka, Zookeeper, Redis, OpenLDAP y Mailhog) en el namespace seleccionado. Reemplaza la ejecución manual de los scripts `bootstrap-cluster.sh` y `deploy-infrastructure.sh`, manteniéndolos como librería reutilizable para troubleshooting local.

### 6.2 Parámetros

| Parámetro | Tipo | Default | Significado |
|---|---|---|---|
| `ENVIRONMENT` | choice | `dev` | Namespace de destino: `dev`, `stage` o `production` |
| `RUN_BOOTSTRAP` | boolean | `true` | Ejecuta la fase de preparación del clúster (namespaces, vinculación DOCR y secrets base). Idempotente; puede dejarse activo siempre |

### 6.3 Etapas

1. **Checkout** — Clona el ops-repo (`checkout scm`).
2. **Refresh kubeconfig** — Genera un kubeconfig fresco en `${WORKSPACE}/.kube/config` mediante `doctl kubernetes cluster kubeconfig save`. Esta etapa hace el pipeline inmune a recreaciones del clúster: no depende del kubeconfig estático almacenado en credenciales.
3. **Bootstrap cluster** *(condicional)* — Crea namespaces, vincula DOCR a las cuentas de servicio default y asegura los secrets `postgres-secret`, `neo4j-secret`, `openldap-secret` en cada namespace. El uso de credenciales predecibles en entorno académico evita lockouts cuando los PVCs se conservan entre reinstalaciones.
4. **Deploy infrastructure** — Ejecuta `helm upgrade --install` del chart `infrastructure/chart` (postgres, neo4j, kafka, zookeeper, redis, openldap, mailhog). Espera hasta 10 minutos por la fase `--wait`.
5. **Verify** — Lista pods, servicios y releases de Helm en el namespace destino como evidencia diagnóstica.

### 6.4 Concepto de bootstrap

Un *bootstrap*, en este contexto, es el conjunto de operaciones que sólo tienen sentido la primera vez que se opera contra un clúster recién provisionado. En `circleguard-infra` esas operaciones son:

- Crear los tres namespaces (`dev`, `stage`, `production`) — solo se necesitan crear una vez.
- Vincular DOCR — solo se vincula una vez por clúster.
- Agregar repos Helm — solo se agregan una vez al `JENKINS_HOME`.
- Crear los secrets de credenciales de las dependencias — sólo se crean una vez, se preservan para que las claves coincidan con los datos persistidos en PVCs.
  
Cada operación está implementada de forma **idempotente** (`kubectl apply -f -` desde un `--dry-run=client -o yaml`, o `kubectl get secret || kubectl create secret`), por lo que ejecutar la fase repetidamente no produce errores ni efectos colaterales destructivos. Por eso `RUN_BOOTSTRAP` puede dejarse activado por defecto.

---

<!-- Documentación de ayuda pero que no irá en el informe final: -->

## 7. Procedimiento — Integración con DigitalOcean MCP (apoyo operativo)

> Componente auxiliar no evaluado por la rúbrica, pero útil para auditoría e introspección.

DigitalOcean expone servidores MCP remotos por servicio (Droplets, Kubernetes, Networking, Accounts). Configurar el archivo `.mcp.json` (excluido de Git) permite a herramientas compatibles con MCP consultar el estado de la infraestructura sin recurrir a invocaciones manuales de `doctl`.

```json
{
  "mcpServers": {
    "do-droplets":   { "type": "http", "url": "https://droplets.mcp.digitalocean.com/mcp",   "headers": { "Authorization": "<DO_TOKEN>" } },
    "do-kubernetes": { "type": "http", "url": "https://doks.mcp.digitalocean.com/mcp",       "headers": { "Authorization": "<DO_TOKEN>" } },
    "do-networking": { "type": "http", "url": "https://networking.mcp.digitalocean.com/mcp", "headers": { "Authorization": "<DO_TOKEN>" } },
    "do-accounts":   { "type": "http", "url": "https://accounts.mcp.digitalocean.com/mcp",   "headers": { "Authorization": "<DO_TOKEN>" } }
  }
}
```

Detalle relevante: contrario a la API REST de DigitalOcean, el gateway MCP **no admite el prefijo `Bearer`** en el header `Authorization`. Esta inconsistencia se documenta en la sección 8.5.

---

## 8. Bitácora de incidentes y resoluciones

Cada incidente registra contexto, error observado, causa raíz, corrección aplicada y archivo o referencia afectada. Los incidentes están listados en orden cronológico de aparición.

### 8.1 Incidente — Versión de Kubernetes inválida

**Contexto**: primer `terraform apply` del módulo `k8s_cluster`.

**Error**:
```
Error: Error creating Kubernetes cluster: 422
validation error: invalid version slug
```

**Causa raíz**: el módulo declaraba `version = "1.30.1-do.0"` como literal. DigitalOcean retira periódicamente versiones antiguas; al momento del despliegue las versiones soportadas eran `1.33.9-do.3`, `1.34.5-do.3` y `1.35.1-do.3`.

**Corrección**: introducción del data source `digitalocean_kubernetes_versions` con `version_prefix` configurable, de modo que Terraform resuelva automáticamente al último patch disponible para la minor solicitada.

```hcl
data "digitalocean_kubernetes_versions" "current" {
  version_prefix = var.k8s_version_prefix   # default "1.33."
}
resource "digitalocean_kubernetes_cluster" "cluster" {
  version = data.digitalocean_kubernetes_versions.current.latest_version
  ...
}
```

**Archivo afectado**: [terraform/modules/k8s-cluster/main.tf](../terraform/modules/k8s-cluster/main.tf).

### 8.2 Incidente — Región no soportada para Container Registry

**Error**:
```
Error: Error creating container registry: 422
invalid or unsupported region: nyc1
```

**Causa raíz**: DOCR sólo opera en `nyc3, sfo3, ams3, sgp1, fra1, syd1`. El módulo reutilizaba `do_region` para el clúster y el registry, asumiendo equivalencia de cobertura.

**Corrección**: introducción de la variable independiente `registry_region` con default `nyc3`. El pull desde el clúster a través de la red de DigitalOcean no se ve afectado por la diferencia regional.

**Archivos afectados**: [terraform/variables.tf](../terraform/variables.tf), [terraform/modules/k8s-cluster/main.tf](../terraform/modules/k8s-cluster/main.tf).

### 8.3 Incidente — VPC no resoluble al crear el droplet

**Error**:
```
Error: Error creating droplet: 422 Failed to resolve VPC
```

**Causa raíz**: cuentas DigitalOcean nuevas no disponen de una VPC default auto-provisionada en todas las regiones. El droplet, al no especificar `vpc_uuid`, intentaba usar la default inexistente.

**Corrección**: declaración explícita de la VPC a nivel raíz (`main.tf`) y propagación del `vpc_uuid` tanto al droplet como al clúster, garantizando además que ambos recursos comparten la misma red privada.

**Archivo afectado**: [terraform/main.tf](../terraform/main.tf).

### 8.4 Incidente — Cloud-init falla por llave GPG de Jenkins expirada

**Síntoma observado**: tras `up-jenkins.sh`, el droplet quedaba accesible por SSH pero Jenkins no levantaba. `cloud-init status --long` reportaba:

```
errors: ('scripts_user', RuntimeError('Runparts: 1 failures (part-001)'))
```

`/var/log/cloud-init-output.log`:

```
W: GPG error: https://pkg.jenkins.io/debian-stable binary/ Release:
   The following signatures couldn't be verified because the public key is not available:
   NO_PUBKEY 7198F4B714ABFC68
E: The repository ... is not signed.
```

**Diagnóstico**: inspección del keyring entregado por la URL de la documentación oficial:

```bash
gpg --no-default-keyring --keyring /usr/share/keyrings/jenkins-keyring.gpg --list-keys
# pub   rsa4096 2023-03-27 [SC] [expired: 2026-03-26]
#       63667EE74BBA1F0A08A698725BA31D57EF5975CA
```

La llave servida en `https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key` (URL aún vigente en la documentación oficial) **expiró el 26 de marzo de 2026**. El repositorio APT de Jenkins está firmado actualmente por la nueva llave `7198F4B714ABFC68`, válida hasta diciembre de 2028 y publicada en una URL distinta.

**Corrección**: actualización del cloud-init para apuntar a la nueva URL `jenkins.io-2026.key`. Para el droplet ya provisionado al momento del incidente, se aplicó la misma corrección manualmente vía SSH sin necesidad de recrear la VM (preservando el volumen persistente).

```bash
ssh root@<jenkins_ip> '
  rm -f /usr/share/keyrings/jenkins-keyring.gpg
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
    | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
  apt-get update -y && apt-get install -y jenkins
  chown -R jenkins:jenkins /var/lib/jenkins
  systemctl enable --now jenkins
'
```

Verificación posterior:
```
HTTP/1.1 403 Forbidden
Server: Jetty(12.1.6)
X-Jenkins: 2.555.1
```

**Archivo afectado**: [terraform/modules/jenkins-vm/main.tf](../terraform/modules/jenkins-vm/main.tf).

### 8.5 Incidente — Autenticación MCP rechazada con prefijo `Bearer`

**Síntoma**: el archivo `.mcp.json` configurado con `"Authorization": "Bearer dop_v1_..."` producía error 401 en todas las llamadas a servidores MCP de DigitalOcean. El mismo token contra la API REST respondía HTTP 200.

**Causa raíz**: el gateway MCP de DigitalOcean acepta el token raw, sin el prefijo `Bearer`. Es una inconsistencia respecto a la API REST documentada.

**Corrección**: ajustar el header a `"Authorization": "<token>"` literal y recargar la ventana de VS Code (la extensión Claude Code lee `.mcp.json` solamente al iniciar la sesión).

### 8.6 Incidente — Plugin instalado pero no cargado por Jenkins

**Síntoma**: tras instalar el plugin AnsiColor desde la UI con la opción *"Restart Jenkins when installation is complete and no jobs are running"*, los pipelines seguían fallando con:
```
Invalid option type "ansiColor". Valid option types: [authorizationMatrix, …]
```

**Diagnóstico**: comparación de timestamps:
```bash
systemctl show jenkins --property=ActiveEnterTimestamp
# ActiveEnterTimestamp=2026-04-27 21:50:36 UTC

stat /var/lib/jenkins/plugins/ansicolor.jpi | grep Modify
# Modify: 2026-04-27 22:35:26
```

El plugin se instaló 45 minutos después del último arranque del proceso Jenkins. El reinicio "graceful" de la UI no se disparó (es un comportamiento conocido en versiones recientes cuando Jenkins detecta cualquier actividad).

**Corrección**: reinicio explícito vía `systemctl restart jenkins`.

### 8.7 Incidente — Permission denied al sobrescribir kubeconfig en el pipeline

**Error**:
```
Notice: Adding cluster credentials to kubeconfig file found in "****"
Error: open ****: permission denied
```

**Causa raíz**: la directiva `KUBECONFIG = credentials('kubeconfig-doks')` en el bloque `environment { }` provoca que Jenkins materialice la credencial de tipo *Secret file* en una ruta temporal con modo `0400` (read-only). El comando `doctl kubernetes cluster kubeconfig save` intenta sobrescribir ese archivo y falla.

**Corrección**: eliminar la dependencia de la credencial estática y apuntar `KUBECONFIG` a una ruta del workspace (`${WORKSPACE}/.kube/config`), donde `doctl` puede escribir libremente. El kubeconfig se regenera fresco en cada ejecución del pipeline a partir del token DigitalOcean, lo que adicionalmente hace al pipeline inmune a recreaciones del clúster.

**Archivo afectado**: [jenkins/Jenkinsfile.infra](../jenkins/Jenkinsfile.infra).

### 8.8 Incidente — Templates Go no renderizados en values.yaml

**Error** (durante `helm install postgresql`):
```
Error: 1 error occurred:
* StatefulSet in version "v1" cannot be handled as a StatefulSet:
  quantities must match the regular expression '^([+-]?[0-9.]+)([eEinumkKMGTP]*[-+]?[0-9]*)$'
```

**Causa raíz**: el chart de infraestructura tenía expresiones tipo `{{ if eq .environment "production" }}...{{ end }}` dentro de `values.yaml`. Helm no renderiza templates Go en `values.yaml`; sólo en archivos bajo `templates/`. Esas expresiones se enviaban literales al API de Kubernetes y fallaban en validación.

**Corrección**: eliminación de templates embebidos en values y estandarización de valores estáticos para el clúster académico de 1 nodo. Los overrides por ambiente se manejan con `-f values-<env>.yaml` o `--set`.

**Archivo afectado**: [infrastructure/chart/values.yaml](../infrastructure/chart/values.yaml).

### 8.9 Incidente — Secrets referenciados pero no creados

**Síntoma**: los manifests de infraestructura referenciaban secrets de Kubernetes (`postgres-secret`, `neo4j-secret`, `openldap-secret`) que no se creaban automáticamente en clúster nuevo.

**Corrección**: extensión de `bootstrap-cluster.sh` para crear esos secrets en cada namespace (`dev`, `stage`, `production`) con patrón idempotente (`kubectl get secret || kubectl create secret`). Se usan credenciales fijas de laboratorio para reproducibilidad.

**Archivos afectados**: [scripts/bootstrap-cluster.sh](../scripts/bootstrap-cluster.sh), [infrastructure/chart/templates/neo4j.yaml](../infrastructure/chart/templates/neo4j.yaml).

---

## 9. Estado actual y trabajo pendiente

### 9.1 Avance real (corte 2026-05-03)

| Componente | Estado |
|---|---|
| Infraestructura Terraform (VPC, volumen, Jenkins VM, DOKS, DOCR) | Operativa |
| Pipeline `circleguard-infra` | Operativo en `dev` (bootstrap + deploy de dependencias compartidas) |
| Selección de microservicios del taller | Cerrada en 6 servicios (`auth`, `identity`, `promotion`, `gateway`, `notification`, `form`) |
| Pipelines de aplicación `dev` / `stage` / `prod` | Implementados en ops-repo y conectados por trigger desde app-repo |
| Estrategia de imágenes DOCR | Migrada a **repositorio único** `registry.digitalocean.com/circleguard/circleguard-services` con tag `<service>-sha-<commit>` |
| Charts Helm de servicios | Alineados al repositorio único de DOCR |
| Notification service tests | Corregidos (se reemplazó uso innecesario de `@SpringBootTest` por tests unitarios Mockito) |
| Promotion service tests en CI | Corregidos para entorno Jenkins sin Docker disponible: clases Testcontainers marcadas con `@Testcontainers(disabledWithoutDocker = true)` y perfil `test` |

### 9.2 Estado del ambiente `dev`

Se validó despliegue en namespace `dev` con pods `Running` para servicios de negocio y dependencias compartidas.

**Servicios de negocio desplegados en dev:**
- `auth-service`
- `form-service`
- `gateway-service`
- `identity-service`
- `notification-service`
- `promotion-service` (pipeline desbloqueado tras corrección de tests)

**Dependencias compartidas desplegadas en dev:**
- `postgres`
- `neo4j`
- `kafka`
- `redis`
- `zookeeper`
- `openldap`
- `mailhog`

### 9.3 Trabajo pendiente (siguiente tramo)

| Componente | Estado |
|---|---|
| Evidencias finales de ejecución `stage` y `prod` | Pendiente captura de pantallazos finales |
| Consolidación de conteo formal (≥5 unitarias, ≥5 integración, ≥5 E2E) por servicio | Pendiente tabla final de trazabilidad |
| Análisis final de rendimiento Locust (latencia p95/p99, throughput, error rate) | Pendiente consolidación de métricas y conclusiones |
| Video corto (máx. 8 min) | Pendiente grabación |

---

## 10. Mapeo del trabajo realizado contra los criterios de evaluación

| # | Criterio del taller | Peso | Sección(es) del informe | Estado |
|---|---|---|---|---|
| 1 | Configurar Jenkins, Docker y Kubernetes | 10% | 3, 5, 6 | Cubierto |
| 2 | Pipelines `dev` (build / test / deploy) para microservicios | 15% | 9.1, 9.2 | Cubierto (con evidencia en curso) |
| 3 | Pruebas unitarias / integración / E2E / Locust con análisis | 30% | 9.1, 9.3 | En progreso |
| 4 | Pipelines `stage` con despliegue y pruebas en Kubernetes | 15% | 6, 9.3 | En progreso |
| 5 | Pipelines `prod` con Release Notes y Change Management | 15% | 6, 9.3 | En progreso |
| 6 | Documentación y video del proceso | 15% | Este documento + video | En progreso |

---

## 11. Evidencias (placeholders para imágenes)

> Reemplazar cada placeholder con el pantallazo final correspondiente en `doc/img/`.

### 11.1 Configuración de pipelines (Jenkins)

![EVIDENCIA - Job circleguard-infra configuración](img/placeholder-jenkins-infra-config.png)
![EVIDENCIA - Job circleguard-deploy-dev configuración](img/placeholder-jenkins-dev-config.png)
![EVIDENCIA - Job circleguard-deploy-stage configuración](img/placeholder-jenkins-stage-config.png)
![EVIDENCIA - Job circleguard-deploy-prod configuración](img/placeholder-jenkins-prod-config.png)

### 11.2 Resultado de ejecución — `dev`

![EVIDENCIA - Build exitoso app-repo (servicio)](img/placeholder-dev-build-success.png)
![EVIDENCIA - Deploy exitoso ops-repo a namespace dev](img/placeholder-dev-deploy-success.png)
![EVIDENCIA - Pods running en namespace dev](img/placeholder-dev-pods-running.png)
![EVIDENCIA - Helm releases en namespace dev](img/placeholder-dev-helm-list.png)

### 11.3 Resultado de ejecución — `stage`

![EVIDENCIA - Pipeline stage completo](img/placeholder-stage-pipeline-success.png)
![EVIDENCIA - Reporte unit/integration/E2E en stage](img/placeholder-stage-test-reports.png)
![EVIDENCIA - Reporte Locust stage](img/placeholder-stage-locust-report.png)

### 11.4 Resultado de ejecución — `production`

![EVIDENCIA - Pipeline prod exitoso](img/placeholder-prod-pipeline-success.png)
![EVIDENCIA - Rollout/health production](img/placeholder-prod-rollout-health.png)
![EVIDENCIA - Release notes generadas](img/placeholder-prod-release-notes.png)

### 11.5 Análisis de pruebas (tablas/gráficas)

![EVIDENCIA - Métricas latencia y throughput](img/placeholder-analysis-latency-throughput.png)
![EVIDENCIA - Tasa de error y conclusiones](img/placeholder-analysis-error-rate.png)

---

## Apéndice A — Comandos de diagnóstico frecuentes

```bash
# Estado del droplet de Jenkins
ssh root@<ip> 'cloud-init status --long; systemctl is-active jenkins; ss -tlnp | grep 8080'

# Estado del clúster
doctl kubernetes cluster get circleguard-k8s
kubectl get nodes; kubectl get ns

# Estado de Helm en un namespace
helm list -n dev
kubectl get pods,svc,pvc -n dev

# Inspección de credenciales montadas en un build (vía SSH al droplet)
ssh root@<ip> 'ls -la /var/lib/jenkins/workspace/circleguard-infra/.kube/'

# Logs de Jenkins
ssh root@<ip> 'journalctl -u jenkins --no-pager -n 200'
```

## Apéndice B — Referencias

- DigitalOcean — Billing FAQ (cobro de droplets apagados): https://docs.digitalocean.com/products/billing/billing-faq/
- DigitalOcean — Disponibilidad regional de servicios: https://docs.digitalocean.com/products/platform/availability-matrix/
- DigitalOcean — Configuración de MCP remotos: https://docs.digitalocean.com/reference/mcp/configure-mcp/
- Jenkins — Pipeline syntax reference: https://www.jenkins.io/doc/book/pipeline/syntax/
- Bitnami PostgreSQL chart: https://github.com/bitnami/charts/tree/main/bitnami/postgresql
- Bitnami Kafka chart: https://github.com/bitnami/charts/tree/main/bitnami/kafka
- Bitnami Redis chart: https://github.com/bitnami/charts/tree/main/bitnami/redis
- Neo4j Helm chart: https://github.com/neo4j/helm-charts
