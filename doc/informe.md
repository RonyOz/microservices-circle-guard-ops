# Informe de operaciones — CircleGuard

**Curso**: DevOps / Pruebas y Calidad de Software
**Repositorio de operaciones**: [microservices-circle-guard-ops](https://github.com/RonyOz/microservices-circle-guard-ops)
**Repositorio de aplicación**: [circle-guard-public](https://github.com/jcmunozf/circle-guard-public)
**Proveedor de nube**: DigitalOcean
**Última actualización**: 2026-04-27

---

## Resumen ejecutivo

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
| Registro de imágenes | DigitalOcean Container Registry (tier starter) | Almacenamiento privado de imágenes Docker construidas por los pipelines |

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
  │   │  DOCR registry.digitalocean.com/circleguard                │ │
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
├── infrastructure/                Values.yaml de Postgres, Kafka, Neo4j, Redis
├── jenkins/
│   ├── Jenkinsfile.infra          Despliegue de infra compartida
│   ├── Jenkinsfile.dev            Pipeline de desarrollo (por microservicio)
│   ├── Jenkinsfile.stage          Pipeline de staging con suite completa de tests
│   └── Jenkinsfile.prod           Pipeline de producción con release notes
├── scripts/
│   ├── up-jenkins.sh              Levanta VPC + volumen + droplet
│   ├── down-jenkins.sh            Destruye droplet, conserva volumen
│   ├── up-cluster.sh              Levanta DOKS + DOCR
│   ├── down-cluster.sh            Destruye DOKS + DOCR
│   ├── bootstrap-cluster.sh       Invocado desde Jenkinsfile.infra
│   └── deploy-infrastructure.sh   Invocado desde Jenkinsfile.infra
├── doc/
│   └── informe.md                 Este documento
└── locust/                        Suites de pruebas de carga
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
| Kubernetes CLI | Step `withKubeConfig` en pipelines de aplicación |
| HTML Publisher | Publicación de reportes Locust como contenido HTML embebido en Jenkins |
| Generic Webhook Trigger | Permite que el repositorio de aplicación dispare jobs vía URL parametrizada |

### 5.4 Credenciales

`Manage Jenkins → Credentials → System → Global credentials`:

| ID | Tipo | Origen del valor |
|---|---|---|
| `do-api-token` | Secret text | Mismo token del archivo `terraform.tfvars` |
| `github-token` | Secret text | *Personal Access Token* de GitHub con scopes `repo` y `workflow` |

### 5.5 Jobs de pipeline

Los cuatro jobs son del tipo *Pipeline* con `Definition: Pipeline script from SCM` apuntando a este repositorio (rama `main`):

| Nombre del job | Script Path | Disparo |
|---|---|---|
| `circleguard-infra` | `jenkins/Jenkinsfile.infra` | Manual (Build with Parameters) |
| `circleguard-dev` | `jenkins/Jenkinsfile.dev` | Webhook desde el app-repo (push a `develop` o `feature/*`) |
| `circleguard-stage` | `jenkins/Jenkinsfile.stage` | Webhook desde el app-repo (push a `develop`) |
| `circleguard-prod` | `jenkins/Jenkinsfile.prod` | Webhook desde el app-repo (push a `main`) |

Para los tres últimos se habilita *Trigger builds remotely* con un token compartido que el app-repo usa al hacer la llamada HTTP a:

```
http://<jenkins_ip>:8080/job/<job-name>/buildWithParameters?token=<token>&SERVICE=<svc>&IMAGE_TAG=<tag>
```

---

## 6. Procedimiento — Pipeline `circleguard-infra`

> **Criterio de evaluación**: punto 1 (10%) — *Configurar Kubernetes con dependencias*.

### 6.1 Propósito

Despliega de forma idempotente las dependencias compartidas (PostgreSQL, Apache Kafka en modo KRaft, Neo4j, Redis) en el namespace seleccionado. Reemplaza la ejecución manual de los scripts `bootstrap-cluster.sh` y `deploy-infrastructure.sh`, manteniéndolos como librería reutilizable para troubleshooting local.

### 6.2 Parámetros

| Parámetro | Tipo | Default | Significado |
|---|---|---|---|
| `ENVIRONMENT` | choice | `dev` | Namespace de destino: `dev`, `stage` o `production` |
| `RUN_BOOTSTRAP` | boolean | `true` | Ejecuta la fase de preparación del clúster (namespaces, vinculación DOCR, secrets, repos Helm). Idempotente; puede dejarse activo siempre |

### 6.3 Etapas

1. **Checkout** — Clona el ops-repo (`checkout scm`).
2. **Refresh kubeconfig** — Genera un kubeconfig fresco en `${WORKSPACE}/.kube/config` mediante `doctl kubernetes cluster kubeconfig save`. Esta etapa hace el pipeline inmune a recreaciones del clúster: no depende del kubeconfig estático almacenado en credenciales.
3. **Bootstrap cluster** *(condicional)* — Crea namespaces, vincula DOCR a las cuentas de servicio default, agrega repos Helm de Bitnami y Neo4j, y crea los secrets `postgresql-secret`, `redis-secret`, `neo4j-secret` con contraseñas predefinidas. El uso de fixed credentials en lugar de generación aleatoria es deliberado para asegurar reproducibilidad académica y evitar lockouts cuando los PVCs se conservan entre reinstalaciones de los charts.
4. **Deploy infrastructure** — Ejecuta `helm upgrade --install` para los cuatro charts con sus respectivos `values.yaml` en `infrastructure/`. Espera hasta 5–8 minutos por la fase `--wait` (los pods deben quedar `Ready`).
5. **Verify** — Lista pods, servicios y releases de Helm en el namespace destino como evidencia diagnóstica.

### 6.4 Concepto de bootstrap

Un *bootstrap*, en este contexto, es el conjunto de operaciones que sólo tienen sentido la primera vez que se opera contra un clúster recién provisionado. En `circleguard-infra` esas operaciones son:

- Crear los tres namespaces (`dev`, `stage`, `production`) — solo se necesitan crear una vez.
- Vincular DOCR — solo se vincula una vez por clúster.
- Agregar repos Helm — solo se agregan una vez al `JENKINS_HOME`.
- Crear los secrets de credenciales de las dependencias — sólo se crean una vez, se preservan para que las claves coincidan con los datos persistidos en PVCs.

Cada operación está implementada de forma **idempotente** (`kubectl apply -f -` desde un `--dry-run=client -o yaml`, o `kubectl get secret || kubectl create secret`), por lo que ejecutar la fase repetidamente no produce errores ni efectos colaterales destructivos. Por eso `RUN_BOOTSTRAP` puede dejarse activado por defecto.

---

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

**Causa raíz**: el archivo `values-postgresql.yaml` contenía expresiones tipo `{{ if eq .environment "production" }}10Gi{{ else }}2Gi{{ end }}`. Helm no procesa templates Go en archivos `values.yaml` (los renderiza únicamente en archivos dentro del directorio `templates/` del chart). Las expresiones se enviaban literales al API de Kubernetes, que rechazaba el formato.

**Corrección**: eliminación de los templates y uso de valores estáticos calibrados para el clúster de un solo nodo. La diferenciación entre ambientes, si fuese necesaria, se manejaría con archivos `values-<env>.yaml` separados o flags `--set`.

**Archivo afectado**: [infrastructure/values-postgresql.yaml](../infrastructure/values-postgresql.yaml).

### 8.9 Incidente — Secrets referenciados pero no creados

**Síntoma**: los archivos `values-postgresql.yaml`, `values-redis.yaml` y `values-neo4j.yaml` referencian secrets de Kubernetes (`postgresql-secret`, `redis-secret`, `neo4j-secret`) que ningún script creaba. El despliegue habría fallado al intentar montar los secrets inexistentes.

**Corrección**: extensión de `bootstrap-cluster.sh` para crear los tres secrets en cada namespace (`dev`, `stage`, `production`) usando la primitiva idempotente `kubectl get secret || kubectl create secret`. Los valores son contraseñas predefinidas y documentadas (apropiadas para un ejercicio académico, no para producción). La idempotencia es crítica: si los secrets se rotaran entre ejecuciones, los PVCs preservados de instalaciones previas perderían acceso a las bases de datos.

Adicionalmente, el chart de Neo4j requería la directiva `passwordFromSecret` (en lugar de la `password: ""` que tenía el archivo original), corregida en [infrastructure/values-neo4j.yaml](../infrastructure/values-neo4j.yaml).

**Archivos afectados**: [scripts/bootstrap-cluster.sh](../scripts/bootstrap-cluster.sh), [infrastructure/values-neo4j.yaml](../infrastructure/values-neo4j.yaml).

---

## 9. Estado actual y trabajo pendiente

### 9.1 Completado al cierre de este informe

| Componente | Estado |
|---|---|
| Infraestructura Terraform (VPC, Volume, Droplet, DOKS, DOCR) | Operativa, validada con `terraform validate` y aplicada exitosamente |
| Cloud-init de Jenkins | Corregido tras incidente 8.4; instala Docker, Java 21, Jenkins LTS, kubectl, helm, doctl |
| Volumen persistente para `JENKINS_HOME` | Operativo; preserva estado entre destrucciones del droplet |
| Scripts de up/down por componente | Probados |
| Pipeline `circleguard-infra` | Diseñado, en proceso de validación end-to-end (al cierre del informe el bootstrap completa exitosamente; pendiente confirmar `helm install` de las cuatro dependencias) |
| Bitácora de incidentes | 9 incidentes documentados con causa raíz y corrección |

### 9.2 Pendiente

| Componente | Estado |
|---|---|
| Selección final de los 6 microservicios del taller | Pendiente |
| Pipelines `dev`, `stage`, `prod` para microservicios | Diseñados; pendiente conexión con app-repo y validación end-to-end |
| Suite de pruebas unitarias (≥5 nuevas) | Pendiente |
| Suite de pruebas de integración (≥5 nuevas) | Pendiente |
| Suite de pruebas E2E (≥5 nuevas) | Pendiente |
| Pruebas de carga con Locust | Esqueleto en `locust/`, pendiente desarrollo de escenarios |
| Generación automática de Release Notes con `git-cliff` | Configuración presente en `cliff.toml` y `Jenkinsfile.prod`; pendiente validación con commit real |

---

## 10. Mapeo del trabajo realizado contra los criterios de evaluación

| # | Criterio del taller | Peso | Sección(es) del informe | Estado |
|---|---|---|---|---|
| 1 | Configurar Jenkins, Docker y Kubernetes | 10% | 3, 5, 6 | Cubierto |
| 2 | Pipelines `dev` (build / test / deploy) para los microservicios | 15% | 9 (pendiente) | En progreso |
| 3 | Pruebas unitarias / integración / E2E / Locust con análisis | 30% | 9 (pendiente) | Pendiente |
| 4 | Pipelines `stage` con despliegue completo en Kubernetes | 15% | 9 (pendiente) | Pipeline diseñado, ejecución pendiente |
| 5 | Pipelines `prod` con Release Notes y Change Management | 15% | 9 (pendiente) | Pipeline diseñado, ejecución pendiente |
| 6 | Documentación y video del proceso | 15% | Este documento + video por grabar | En progreso |

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
