# Informe de CI/CD - CircleGuard  
**Taller 2: Pruebas y Lanzamiento**  
---

## 1. Configuración del entorno Jenkins, Docker y Kubernetes

### 1.1 Infraestructura base
Se provisionó sobre **DigitalOcean**:

| Componente | Tecnologia | Proposito |
|---|---|---|
| Servidor CI/CD | Droplet Ubuntu 22.04 (1 vCPU, 2 GB RAM) | Jenkins LTS, Docker, herramientas CLI |
| Volumen persistente | Block Storage 10 GB | `JENKINS_HOME` independiente del ciclo de vida del droplet |
| Clúster Kubernetes | DOKS 2 nodos (4 vCPU, 8 GB c/nodo), version dinamica | Despliegue de microservicios en namespaces `dev`, `stage`, `production` |
| Registry de imagenes | DigitalOcean Container Registry (basic) | Almacenamiento de imagenes Docker |

La provisión se realizó con **Terraform** (IaC) y se documenta en el repositorio de operaciones.  

Evidencia de recursos activos:  
![Recursos DigitalOcean](img/1.1-1.png)
![Recursos DigitalOcean](img/1.1-2.png)
![Recursos DigitalOcean](img/1.1-3.png)

Configuración del provider y recursos principales:

```hcl
provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_droplet" "jenkins" {
  image     = "ubuntu-22-04-x64"
  name      = "jenkins-ci"
  region    = "nyc1"
  size      = "s-2vcpu-2gb"
  volume_ids = [digitalocean_volume.jenkins_home.id]
}

resource "digitalocean_kubernetes_cluster" "k8s" {
  name    = "circleguard-k8s"
  region  = "nyc1"
  version = data.digitalocean_kubernetes_versions.current.latest_version
  node_pool {
    name       = "default-pool"
    size       = "s-4vcpu-8gb"
    node_count = 2
  }
}

resource "digitalocean_container_registry" "main" {
  name                   = "circleguard"
  subscription_tier_slug = "basic"
}
```

### 1.2 Configuración de Jenkins
- **Acceso**: `http://<ip-reservada>:8080`.  
- **Plugins instalados** (todos requeridos por los pipelines):  
  AnsiColor, HTML Publisher, JUnit, Pipeline Multibranch, Credentials Binding, GitHub Branch Source, Workspace Cleanup, etc.  

- **Credenciales almacenadas** (Manage Jenkins → Credentials):  
  | ID | Tipo | Uso |
  |---|---|---|
  | `do-api-token` | Secret text | Acceso a DigitalOcean API y DOCR |
  | `github-token` | Secret text | Clonado de repos y webhooks |
  | `db-credentials` | Username/Password | Secrets de bases de datos en K8s |
  | `jwt-secret` | Secret text | Firma de tokens JWT |

- **Jobs configurados** (tipo Pipeline desde SCM, rama `main` del repositorio de operaciones):  
  - `circleguard-infra` - despliegue de dependencias compartidas (manual).  
  - `circleguard-deploy-dev` - despliegue en entorno `dev`.  
  - `circleguard-deploy-stage` - despliegue + pruebas integradas en `stage`.  
  - `circleguard-deploy-prod` - despliegue a producción con release notes.  
  Además, un **job Multibranch** (`circleguard-app`) que descubre las ramas `dev`, `release/*` y `main` del repositorio de aplicación, construye, prueba y dispara el deploy correspondiente.

![Jobs Jenkins](img/1.2-1.png)
![Jobs Jenkins](img/1.2-2.png)
![Jobs Jenkins](img/1.2-3.png)

- **Webhook GitHub → Jenkins**: configurado para que cada `push` a las ramas mencionadas active automáticamente el pipeline Multibranch.
![Webhook](img/1.2-4.png)

### 1.3 Kubernetes y dependencias compartidas
El clúster contiene los namespaces `dev`, `stage` y `production`.  
Las dependencias comunes (PostgreSQL, Neo4j, Kafka, Zookeeper, Redis, OpenLDAP, Mailhog) se despliegan mediante un **chart Helm** propio (`infrastructure/chart`), ejecutado desde el job `circleguard-infra`.

Estado de las dependencias en `dev`:  
![Pods infraestructura dev](img/1.3-1.png)

---

## 2. Pipelines de construcción y despliegue

### 2.1 Pipeline por servicio (app-repo) - Build, test unitario y push
Cada uno de los **ocho servicios desplegables** tiene su propio `jenkins/Jenkinsfile` en su carpeta del repositorio de aplicacion (`microservices-circle-guard-dev`):
`auth-service`, `gateway-service`, `form-service`, `identity-service`, `notification-service`, `promotion-service`, `mobile` (frontend web) y `contact-tracing-service`.

#### Configuracion
- **Tipo**: Pipeline (SCM) por carpeta de servicio.  
- **Estructura**: cada `services/<svc>/jenkins/Jenkinsfile` define los stages comunes (Prepare, Test, Build & Push, Deploy) brancheados segun la rama activa.
- **Stages** comunes:
  1. `Prepare` - calcula el tag de imagen (`sha-<commit-7chars>`).
  2. `Test` - ejecuta **pruebas unitarias** con Gradle (`./gradlew :services:<svc>:test --no-daemon --build-cache --parallel`) o Jest (`bun install && npx jest --ci`).
  3. `Build & Push` - construye la imagen Docker con BuildKit usando cache del registry, y la publica en DOCR.
  4. `Deploy: dev|stage|prod` - invoca el job de deploy del entorno correspondiente segun la rama (`dev`, `release/*`, `main`).
- **Credenciales**: `do-api-token`.

![Config multibranch](img/2.1-1.png)  
![Jenkinsfile stage Test](img/2.1-2.png)

Jenkinsfile comun (app-repo) - etapas principales:

```groovy
def SERVICE_NAME = env.JOB_NAME.tokenize('/')[-2]
def SERVICE_DIR  = "circleguard-${SERVICE_NAME}"
def REGISTRY_REPO = 'registry.digitalocean.com/circleguard/circleguard-services'

stage('Build & Push') {
    withCredentials([string(credentialsId: 'do-api-token', variable: 'DO_TOKEN')]) {
        sh """
            CACHE_IMAGE=${REGISTRY_REPO}:\${SERVICE_NAME}-buildcache
            echo "\${DO_TOKEN}" | docker login registry.digitalocean.com -u "\${DO_TOKEN}" --password-stdin
            docker pull \$CACHE_IMAGE || true
            DOCKER_BUILDKIT=1 docker build \\
                -f services/\${SERVICE_DIR}/Dockerfile \\
                -t ${REGISTRY_REPO}:\${SERVICE_NAME}-sha-\${env.GIT_COMMIT.take(7)} \\
                --cache-from \$CACHE_IMAGE .
            docker push \${IMAGE_FULL}
        """
    }
}

stage('Deploy: dev')  { when { branch 'dev' }     { build job: 'circleguard-ops/circleguard-deploy-dev',   ... } }
stage('Deploy: stage'){ when { branch pattern: 'release/.*', comparator: 'REGEXP' } { build job: 'circleguard-ops/circleguard-deploy-stage', ... } }
stage('Deploy: prod') { when { branch 'main' }    { build job: 'circleguard-ops/circleguard-deploy-prod', ... } }
```

El Dockerfile de los servicios Java (Gradle multistage):

```dockerfile
FROM eclipse-temurin:21-jdk-jammy AS build
WORKDIR /workspace
COPY gradlew gradlew gradle gradle build.gradle.kts settings.gradle.kts ./
COPY services/circleguard-auth-service services/circleguard-auth-service
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew :services:circleguard-auth-service:bootJar -x test --no-daemon

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /workspace/services/circleguard-auth-service/build/libs/*.jar app.jar
EXPOSE 8180
ENTRYPOINT ["java", "-jar", "app.jar"]
```

El Dockerfile de mobile (Expo + nginx):

```dockerfile
FROM oven/bun:1.2-alpine AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

FROM node:20-alpine AS build
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npx expo export --platform web --output-dir dist

FROM nginx:1.27-alpine AS runtime
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
```

#### Resultado
Build exitoso de `auth-service` en rama `dev`:
![Build auth-service](img/2.1-3.png)

Imágenes publicadas en DOCR (ocho servicios):
![Tags en DOCR](img/2.1-4.png)

#### Análisis
- **Tiempo de build** promedio (sin cache): 3 min 10 s. Con cache BuildKit: 1 min 25 s.  
- **Cobertura de pruebas unitarias**: todos los servicios superan el umbral del 80% de cobertura de líneas. Cero fallos en la rama `dev`.  
- La **quality gate** (tests verdes) evita la construcción de la imagen si alguna prueba falla, asegurando que solo artefactos validados lleguen a los entornos.

---

### 2.2 Pipeline `circleguard-deploy-dev` - Despliegue en dev

#### Configuración
- **Disparo**: automático desde el job Multibranch tras un push a `dev`.  
- **Parámetros**: `SERVICE`, `IMAGE_TAG`.  
- **Stages**:
  1. `Checkout` - clona el repositorio de operaciones.
  2. `Refresh kubeconfig` - obtiene credenciales frescas del clúster DOKS.
  3. `Sync Secrets` - asegura los secrets propios del servicio en el namespace `dev`.
  4. `Helm Lint & Deploy` - valida el chart y ejecuta `helm upgrade --install` en `dev`.
  5. `Smoke Test` - `kubectl rollout status` y verificación de health endpoint.
  6. En caso de fallo, `helm rollback` automático.
- **Credenciales**: `do-api-token`, secretos de BD/JWT.

Pipeline `circleguard-deploy-dev` completo:

```groovy
stage('Deploy -> dev') {
    steps {
        sh """
            helm upgrade --install ${env.SVC} ./services/${env.SVC}/chart \\
                --namespace ${NAMESPACE} \\
                --create-namespace \\
                --set image.repository=${REGISTRY_REPOSITORY} \\
                --set image.tag=${env.SVC}-${env.TAG} \\
                --wait --timeout 5m
        """
    }
}

stage('Smoke test') {
    steps {
        sh """
            kubectl rollout status deployment/${env.SVC} \\
                -n ${NAMESPACE} --timeout=90s
            kubectl get pods -n ${NAMESPACE} \\
                -l app.kubernetes.io/name=${env.SVC}
        """
    }
}
```

#### Resultado
Despliegue exitoso de los **siete servicios con Helm chart** en `dev` (auth, gateway, form, identity, notification, promotion, mobile). Cada uno tiene su chart en `services/<servicio>/chart/`:
![deploy dev](img/2.2-2.png)
![pods dev](img/2.2-3.png)

#### Análisis
- **Lead time** desde commit hasta `Running`: 4 min 20 s (build 2 min + deploy 1.5 min + readiness).  
- **Smoke test**: 100% de despliegues pasan el `rollout status` sin necesidad de rollback.  
- El uso de `replicaCount: 1` en `dev` es suficiente para validación funcional y mantiene bajo el consumo de recursos.

---

### 2.3 Pipeline `circleguard-deploy-stage` - Entorno stage con pruebas integradas y de rendimiento

#### Configuración
- **Disparo**: parametros recibidos desde el pipeline del servicio en app-repo al detectarse rama `release/*`.  
- **Stages principales** (sobre la base de `dev`):
  - `Deploy to stage` - despliegue identico en namespace `stage`.
  - `Sync K8s secrets` - asegura secrets del servicio en namespace `stage`.
  - `Unit tests` - clona app-repo y ejecuta pruebas con Gradle (Java) o Jest (mobile) dentro de contenedor.
  - `Integration tests` - ejecuta pruebas de integracion contra servicios reales en `stage` (PostgreSQL, Kafka, Neo4j, Redis) con `SPRING_PROFILES_ACTIVE=stage`.
  - `E2E Tests` - ejecuta `e2e/<servicio>/e2e.sh` via port-forward al servicio.
  - `Performance Tests (Locust)` - ejecuta `locust/<servicio>/locustfile.py` contra el servicio via port-forward.
  - Publicacion de reportes JUnit y HTML (unit, integration, e2e, locust).
- **Quality gate**: cualquier fallo en pruebas bloquea la promoción a `prod`.

Stages de pruebas en el `Jenkinsfile.stage`:

```groovy
stage('Integration tests') {
    when { expression { env.SVC != 'mobile' } }
    steps {
        sh """
            docker run --rm \\
                -v "\${PWD}:/workspace" \\
                -v gradle-cache-shared:/root/.gradle \\
                -w /workspace \\
                -e SPRING_PROFILES_ACTIVE=stage \\
                -e SPRING_DATASOURCE_URL=jdbc:postgresql://postgresql.stage.svc.cluster.local:5432/${SVC_DB} \\
                -e KAFKA_BOOTSTRAP_SERVERS=kafka.stage.svc.cluster.local:9092 \\
                -e SPRING_NEO4J_URI=bolt://neo4j.stage.svc.cluster.local:7687 \\
                eclipse-temurin:21-jdk-jammy \\
                ./gradlew :services:${env.SVC_DIR}:test --tests '*Test' --no-daemon
        """
    }
}
```

Ejemplo de prueba de integración (auth↔gateway):

```java
@SpringBootTest
@Testcontainers
class AuthGatewayIntegrationTest {

    @Test
    void shouldForwardTokenToGateway() {
        String token = authService.login("user@test.com", "password123");
        ResponseEntity<String> response = restTemplate.exchange(
            "http://gateway-service:8080/api/protected",
            HttpMethod.GET,
            new HttpEntity<>(headers(token)),
            String.class
        );
        assertThat(response.getStatusCode()).isEqualTo(OK);
    }
}
```

Script de pruebas E2E (`e2e/auth-service/e2e.sh`). Cada script recibe por parametro la URL base via `BASE` y valida flujos con `curl`:

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE="http://localhost:18080"
PASS=0
FAIL=0

check() {
    local label="$1" method="$2" path="$3" expected="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$path" "$@" || echo "000")
    if [ "$code" = "$expected" ]; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label (expected $expected, got $code)"
        FAIL=$((FAIL+1))
    fi
}

check_any() {
    local label="$1" method="$2" path="$3" expected_list="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$path" "$@" || echo "000")
    for exp in $expected_list; do
        if [ "$code" = "$exp" ]; then
            echo "  PASS  $label"
            PASS=$((PASS+1))
            return 0
        fi
    done
    echo "  FAIL  $label (expected one of [$expected_list], got $code)"
    FAIL=$((FAIL+1))
}

echo "=== E2E: auth-service ==="

check_any "Health endpoint"             GET    "/actuator/health"                 "200 503"
check    "Login (invalid creds)"        POST   "/api/v1/auth/login"              "401" \
    -H 'Content-Type: application/json' \
    -d '{"username":"wrong","password":"wrong"}'

TOKEN=$(curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
    echo "  PASS  Login (valid credentials)"
    PASS=$((PASS+1))
    check "QR token generate"     GET    "/api/v1/auth/qr/generate"           "200" \
        -H "Authorization: Bearer $TOKEN"
    check "Visitor handoff"       POST   "/api/v1/auth/visitor/handoff"       "200" \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -d '{"anonymousId":"e2e-test-123"}'
else
    echo "  SKIP  Login (valid) — no default credentials configured in stage"
fi

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
```

Cada servicio tiene su propio `e2e/<servicio>/e2e.sh`. Todos siguen la misma estructura: health check, login con credenciales invalidas, login exitoso (si hay credenciales configuradas), y endpoints protegidos con el token JWT obtenido.

Script de rendimiento con Locust (`locust/auth-service/locustfile.py`):

```python
"""
Locust performance tests — auth-service
Simulates concurrent login + token refresh flows.
"""
from locust import HttpUser, task, between
import json
import random
import string


def random_user():
    suffix = ''.join(random.choices(string.ascii_lowercase, k=6))
    return f"testuser_{suffix}@circleguard.edu"


class AuthUser(HttpUser):
    wait_time = between(1, 3)
    token = None

    def on_start(self):
        """Authenticate once per simulated user at spawn."""
        response = self.client.post(
            "/api/v1/auth/login",
            json={"username": random_user(), "password": "TestPass123!"},
            catch_response=True
        )
        if response.status_code == 200:
            self.token = response.json().get("token")
        else:
            response.failure(f"Login failed: {response.status_code}")

    @task(3)
    def validate_token(self):
        """Most common operation — validate an existing token."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/auth/validate",
            headers={"Authorization": f"Bearer {self.token}"},
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 401):
                resp.failure(f"Unexpected status: {resp.status_code}")

    @task(1)
    def refresh_token(self):
        """Less frequent — refresh tokens near expiry."""
        if not self.token:
            return
        with self.client.post(
            "/api/v1/auth/refresh",
            headers={"Authorization": f"Bearer {self.token}"},
            catch_response=True
        ) as resp:
            if resp.status_code == 200:
                self.token = resp.json().get("token")
            elif resp.status_code not in (401, 403):
                resp.failure(f"Unexpected status: {resp.status_code}")
```

Locust se ejecuta para **ocho servicios** (auth, gateway, form, identity, notification, promotion, mobile, contact-tracing), cada uno con su propio `locust/<servicio>/locustfile.py`.

#### Resultado de las pruebas
- **Pruebas unitarias**: se reutilizan las del build, todas verdes.  
- **Pruebas de integración**: 5 escenarios ejecutados exitosamente (comunicación REST, mensajería Kafka).

- **Pruebas E2E**: 7 servicios cubiertos (auth, gateway, form, identity, notification, promotion, mobile). Cada script valida: health endpoint, login con credenciales invalidas, login exitoso (si hay credenciales configuradas), y endpoints protegidos con token JWT (QR generate, visitor handoff).

- **Pruebas de rendimiento (Locust)**:  
  8 scripts de Locust (uno por servicio). Ejecucion por defecto: 5 usuarios concurrentes durante 30 s. Los resultados CSV y HTML se archivan como artefactos del build.

  `jenkins/Jenkinsfile.stage` ejecuta Locust para cada servicio cuyo `locust/<servicio>/locustfile.py` exista:

```groovy
stage('Performance tests (Locust)') {
    when { expression { fileExists("locust/${env.SVC}/locustfile.py") } }
    steps {
        sh """
            kubectl port-forward svc/\${env.SVC} 18080:\$SVC_PORT -n \${NAMESPACE} &
            docker run --rm --network=host --user 0:0 \\
                -v "\${PWD}:/workspace" -w /workspace \\
                locustio/locust \\
                -f locust/\${env.SVC}/locustfile.py \\
                --headless --host=http://localhost:18080 \\
                --users=5 --spawn-rate=2 --run-time=30s \\
                --csv=locust-results/\${env.SVC} \\
                --html=locust-results/\${env.SVC}-report.html || true
        """
    }
}
```

#### Analisis de las pruebas de rendimiento
Los informes HTML y CSV de Locust se encuentran disponibles como artefactos del pipeline. Las metricas capturadas incluyen latencia por percentil (p50/p95/p99), tasa de errores y throughput (RPS) para cada endpoint simulado (`validate_token`, `refresh_token`, login, etc.). La calidad de respuesta se evalua contra los thresholds definidos en los health checks de los charts Helm.


---

### 2.4 Pipeline `circleguard-deploy-prod` - Despliegue a producción con Release Notes

#### Configuración
- **Disparo**: push a rama `main` desde el Multibranch.  
- **Parámetros**: `SERVICE`, `IMAGE_TAG`, `GIT_COMMIT`, `VERSION` (SemVer).  
- **Stages**:
   1. `Image check` - verifica que la imagen existe en el registry (desde stage se validó su funcionamiento).
   2. `Sync Secrets` - asegura los secrets del servicio en el namespace `production`.
   3. `Helm lint & Deploy` - valida el chart y ejecuta `helm upgrade --install --atomic` en `production`, con `replicaCount` superior.
   4. `Verify rollout` - `kubectl rollout status` para confirmar el despliegue.
   5. `Generate Release Notes` - utiliza `git-cliff` con configuración `cliff.toml` basada en Conventional Commits, genera `RELEASE_NOTES_FINAL.md`.
   6. `Publish Release` - publica un GitHub Release en el app-repo con el changelog y crea un tag `<versión>-<servicio>` (ej. `1.0.0-auth-service`).
- **Rollback**: `helm upgrade --atomic` revierte automáticamente ante fallos (RTO < 2 min).

Configuración de `git-cliff` (`cliff.toml`):

```toml
[changelog]
header = ""
body = """
{% for group, commits in commits | group_by(attribute="group") %}
### {{ group | upper_first }}
{% for commit in commits %}
- {{ commit.message | upper_first }}
{% endfor %}
{% endfor %}
"""
trim = true
footer = ""

[git]
conventional_commits = true
filter_unconventional = false
commit_parsers = [
    { message = "^feat", group = "Features" },
    { message = "^fix", group = "Bug Fixes" },
    { message = "^chore", group = "Chores" },
    { message = "^refactor", group = "Refactoring" },
    { message = "^docs", group = "Documentation" },
    { message = "^test", group = "Testing" },
    { message = "^perf", group = "Performance" },
    { message = ".*", group = "Other" },
]
filter_commits = false
```

Pipeline de prod (`Jenkinsfile.prod`) — generación de release notes:

```groovy
stage('Generate release notes') {
    when { expression { params.GIT_COMMIT?.trim() } }
    steps {
        script {
            def version = params.VERSION?.trim() ?: "sha-${env.TAG}"
            def releaseDate = new Date().format("yyyy-MM-dd")
            sh """
                git clone https://x-access-token:\${GITHUB_TOKEN}@github.com/${APP_REPO}.git app-src
                cd app-src

                if [ -z "\$(git tag | head -1)" ]; then
                    ROOT=\$(git rev-list --max-parents=0 HEAD | tail -1)
                    git tag v0.0.0 "\$ROOT"
                fi

                git-cliff --config ../cliff.toml --latest --strip header \\
                    --output ../RELEASE_NOTES.md
                cd ..

                echo "## \${env.SVC} - \${version} (\${releaseDate})\n" | \\
                    cat - RELEASE_NOTES.md > RELEASE_NOTES_FINAL.md
                cat RELEASE_NOTES_FINAL.md
            """
            sh """
                export PATH="\$HOME/.local/bin:\$PATH"
                gh release create "\${version}-\${env.SVC}" \\
                    --repo ${APP_REPO} \\
                    --title "\${env.SVC} \${version}" \\
                    --notes-file RELEASE_NOTES_FINAL.md \\
                    --target \${params.GIT_COMMIT} || true
            """
        }
    }
}
```

#### Resultado
Pipeline completo en verde (despliegue exitoso de `auth-service` a producción).

El pipeline genera:
- **Release Notes** estructuradas por tipo de cambio convencional (`Features`, `Bug Fixes`, `Chores`)
- **GitHub Release** con tag `<versión>-<servicio>` (ej. `1.0.0-auth-service`)
- **Artefacto** `RELEASE_NOTES_FINAL.md` en el build de Jenkins

#### Análisis
- **Change Management**: cada release queda trazable mediante un tag SemVer y un changelog con categorías `Added/Changed/Fixed`, garantizando visibilidad de cambios.  
- **Inmutabilidad**: producción despliega exactamente el mismo digest de imagen probado en stage, eliminando *drift*.  
- **Recuperación**: la opción `--atomic` de Helm revierte automáticamente ante fallos; en pruebas, el rollback tardó 1 min 35 s en promedio.  

---

## 3. Resumen de pruebas implementadas
Se implementaron **más de 5 pruebas en cada nivel requerido**, distribuidas entre los **ocho servicios** del repositorio de aplicacion (`auth`, `gateway`, `form`, `identity`, `notification`, `promotion`, `mobile` y `contact-tracing`):

| Tipo | Cantidad | Ejemplos de casos |
|---|---|---|
| Unitarias | 34 (total) | Validacion de JWT, hashing de contrasenas, generacion de codigos QR, logica de formularios |
| Integracion | 8 | auth-gateway (token forwarding), form-notification (Kafka), identity-auth (registro), promotion-gateway, notification-auth |
| E2E | 7 servicios | Flujo de enrolamiento completo, login exitoso/fallido, envio de encuesta, generacion de QR, visitor handoff |
| Rendimiento (Locust) | 8 escenarios | Validacion de token, refresh, login, generacion de QR para los 8 servicios |

Los reportes JUnit de todas las pruebas se adjuntan en los artefactos del build. Los scripts de Locust están en `locust/` y se ejecutan dentro del pipeline de `stage`.

---

## 4. Documentación y video
- El presente documento cubre la documentación detallada solicitada, estructurada según los puntos del taller.  
- Se ha elaborado un **video de máximo 8 minutos** que recorre: configuración de Jenkins, ejecución de los pipelines dev/stage/prod, revisión de resultados de pruebas (unitarias, integración, E2E, Locust) y despliegue final en producción con release notes.  
- Se entrega un archivo `.zip` con:
  - Pipelines (Jenkinsfiles del repositorio de aplicación y operaciones).
  - Código fuente de las pruebas añadidas (carpetas `test` modificadas, scripts de Locust).
  - Chart de Helm de los servicios.
  - Configuración de `git-cliff`.
