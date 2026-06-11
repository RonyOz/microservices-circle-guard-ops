# Guía Técnica Completa — Diagramas de Arquitectura CircleGuard

**Proyecto:** CircleGuard — Sistema de rastreo de contactos universitario  
**Repositorio:** `microservices-circle-guard-ops`  
**Diagramas:** `doc/drawio/`

---

## Índice

1. [Glosario de Conceptos Fundamentales](#1-glosario-de-conceptos-fundamentales)
2. [Application Components](#2-application-components)
3. [AWS Deployment Topology](#3-aws-deployment-topology)
4. [CI-CD GitOps](#4-ci-cd-gitops)
5. [Cloud Architecture Diagram](#5-cloud-architecture-diagram)
6. [Cómo se relacionan los cuatro diagramas](#6-cómo-se-relacionan-los-cuatro-diagramas)

---

## 1. Glosario de Conceptos Fundamentales

Antes de entrar a los diagramas, estos son los conceptos que aparecen en todos ellos. Entenderlos de raíz hace que los diagramas sean obvios.

---

### Microservicio

Un microservicio es una aplicación pequeña, autónoma y especializada que hace **una sola cosa bien**. En lugar de tener un programa gigante ("monolito") que gestiona usuarios, formularios, notificaciones y trazabilidad al mismo tiempo, cada responsabilidad vive en su propio proceso separado.

**Ventajas:**
- Se puede desplegar y escalar cada servicio de forma independiente.
- Un fallo en notification-service no tira abajo auth-service.
- Equipos distintos pueden trabajar en servicios distintos sin coordinación constante.

**Desventaja principal:** la red introduce latencia y puntos de fallo entre servicios. Por eso existen patrones como Circuit Breaker.

CircleGuard tiene 8 microservicios Spring Boot.

---

### API Gateway

Es el único punto de entrada público para todos los clientes (web, móvil). Actúa como portero y enrutador: recibe la petición, valida el JWT, y la reenvía al servicio interno correcto.

**Sin gateway:** el cliente necesita conocer la IP/puerto de cada microservicio. Inseguro y frágil.  
**Con gateway:** el cliente solo habla con una URL. Los servicios internos no son accesibles desde internet.

En CircleGuard: `gateway-service` corre en puerto 8086 y usa Spring Cloud Gateway.

---

### JWT (JSON Web Token)

Token de autenticación firmado criptográficamente. Tiene tres partes separadas por puntos: `header.payload.signature`.

- **Header:** algoritmo de firma (ej. HS256).
- **Payload:** claims — quién es el usuario, sus roles, cuándo expira.
- **Signature:** firma HMAC/RSA que garantiza que nadie alteró el payload.

Flujo en CircleGuard:
1. Cliente manda usuario/contraseña a auth-service.
2. auth-service verifica contra LDAP, emite JWT firmado.
3. Cliente incluye JWT en cada request: `Authorization: Bearer <token>`.
4. gateway-service valida firma antes de routear.

**Diferencia con sesiones:** JWT es *stateless* — el servidor no necesita guardar nada. Toda la info está en el token.

---

### Circuit Breaker (Resilience4j)

Patrón de resiliencia que protege contra fallos en cascada. Funciona como un fusible eléctrico.

**Tres estados:**
- **CLOSED (normal):** las llamadas pasan. Si X% fallan en una ventana de tiempo, abre.
- **OPEN (cortado):** las llamadas se rechazan inmediatamente (sin esperar timeout). Después de N segundos, pasa a half-open.
- **HALF-OPEN (prueba):** deja pasar algunas llamadas de prueba. Si pasan, cierra; si fallan, vuelve a open.

**Por qué importa:** si promotion-service tarda 30s en responder (por sobrecarga), sin CB todos los threads de dashboard-service quedarían bloqueados esperando, lo que tiraría dashboard también. Con CB, falla rápido y puede devolver datos cacheados o un error claro.

En CircleGuard: `[CB]` en el diagrama marca `auth-service → identity-service` y `dashboard-service → promotion-service`.

---

### Apache Kafka

Sistema de mensajería distribuida basado en el modelo **publish-subscribe** con persistencia en disco. No es una cola simple — es un *log* distribuido.

**Conceptos clave:**
- **Topic:** canal nombrado donde se publican mensajes (ej. `survey.submitted`).
- **Producer:** servicio que publica mensajes en un topic.
- **Consumer:** servicio que lee mensajes de un topic.
- **Partition:** un topic se divide en particiones para paralelismo. Cada mensaje tiene un offset dentro de su partición.
- **Consumer group:** varios consumers pueden trabajar en paralelo si están en el mismo grupo — cada uno lee particiones distintas.
- **Retention:** Kafka guarda mensajes por tiempo (ej. 7 días) o tamaño, no por consumo. Un consumer puede releer desde el principio.

**Por qué no HTTP síncrono:** cuando form-service registra un formulario, no necesita esperar a que promotion-service procese el grafo Neo4j (que puede tardar). Con Kafka, form-service publica y sigue; promotion-service consume a su ritmo.

**Zookeeper:** coordinador de Kafka (modo legado). Gestiona elección de líderes de partición y metadata del cluster. Kafka moderno (KRaft) no lo necesita, pero CircleGuard usa la imagen Confluent clásica.

---

### Neo4j (Base de datos de grafos)

Base de datos donde los datos son **nodos** (entidades) y **relaciones** (aristas con propiedades). Usa Cypher como lenguaje de consulta.

**Por qué un grafo para rastreo de contactos:**
- En SQL, encontrar "todos los contactos de los contactos de X en los últimos 14 días" requiere múltiples JOINs recursivos — lento y complejo.
- En Neo4j, es un traversal de grafo: `MATCH (p:Person)-[:CONTACT_WITH*1..3]->(q) WHERE contact.date > date()-14 RETURN q`.

**Modelo CircleGuard:**
- Nodo `Person` (ID anónimo, sin nombre real).
- Relación `CONTACT_WITH` con propiedad `timestamp`.
- promotion-service recorre el grafo filtrando por ventana de 14 días para determinar quién está en el "círculo de exposición" y promueve su estado de salud.

---

### Redis

Base de datos en memoria (key-value) con estructuras de datos ricas (strings, hashes, sets, sorted sets, streams). Persistencia opcional.

**Usos típicos:**
- **Cache:** guardar resultados costosos de BD por un TTL.
- **Session store:** guardar sesiones de usuario.
- **Rate limiting:** contadores atómicos por IP.
- **Queue:** listas como colas simples.

En CircleGuard: `gateway-service` usa Redis para cachear tokens QR (tokens de un solo uso para escaneo de QR en acceso). El token vive segundos/minutos; si ya fue usado, está marcado como consumido.

---

### OpenLDAP

LDAP (Lightweight Directory Access Protocol) es un protocolo para directorios de usuarios. OpenLDAP es la implementación open-source más usada.

**Estructura:** árbol jerárquico (`dc=circleguard,dc=com` → `ou=users` → `cn=juan`). Cada entrada tiene atributos (`mail`, `userPassword`, grupos).

En CircleGuard: `auth-service` hace **LDAP bind** — intenta autenticar al usuario contra OpenLDAP con sus credenciales. Si el bind tiene éxito, el usuario existe y la contraseña es correcta; auth-service emite JWT.

---

### Kubernetes (K8s)

Orquestador de contenedores. Toma tus imágenes Docker y las corre como **Pods** en un cluster de máquinas, gestionando despliegue, escalado, reinicio automático, service discovery y más.

**Conceptos clave:**
- **Pod:** unidad mínima. Uno o más contenedores que comparten red y disco.
- **Deployment:** define cuántas réplicas de un Pod deben correr y cómo actualizarlas.
- **Service:** IP estable que balancea tráfico a un conjunto de Pods (DNS interno: `auth-service.dev.svc.cluster.local`).
- **Namespace:** partición lógica del cluster. CircleGuard usa `dev`, `stage`, `production` — mismo cluster físico, aislamiento por namespace.
- **ConfigMap / Secret:** inyección de configuración y secretos en Pods via variables de entorno o archivos montados.
- **PersistentVolumeClaim (PVC):** solicitud de almacenamiento persistente. K8s la satisface con un **PersistentVolume** (PV) provisionado por un CSI driver.
- **StatefulSet:** como Deployment pero para workloads con estado (bases de datos). Garantiza identidad de red estable y orden de arranque.
- **HorizontalPodAutoscaler (HPA):** escala réplicas automáticamente basado en CPU/memoria u otras métricas.
- **Ingress:** regla que expone servicios HTTP/S al exterior, usando un Ingress Controller.

---

### Helm

Gestor de paquetes para Kubernetes. Un **Chart** es un directorio con templates YAML parametrizados. Permite instalar/actualizar/rollback aplicaciones K8s con un comando.

```
helm upgrade --install auth-service ./services/auth-service/chart \
  --namespace dev \
  --set image.tag=auth-service-sha-abc1234
```

**Por qué importa:** sin Helm, tendrías que editar decenas de archivos YAML para cambiar la versión de imagen de un servicio. Con Helm, es un `--set`.

`helm upgrade --atomic` (en producción) hace rollback automático si el deploy no pasa los health checks dentro del timeout.

---

### Amazon EKS (Elastic Kubernetes Service)

Kubernetes gestionado por AWS. AWS opera el **control plane** (API server, etcd, scheduler, controller manager) — tú solo gestionas los **worker nodes** (EC2 donde corren tus Pods).

**Beneficio:** sin EKS tendrías que instalar, actualizar y operar Kubernetes manualmente en VMs. Con EKS, AWS garantiza disponibilidad del control plane, parches de seguridad y upgrades de versión.

CircleGuard usa EKS con cluster `circleguard-eks`, Kubernetes 1.30, en `us-east-1`.

---

### Amazon ECR (Elastic Container Registry)

Registro privado de imágenes Docker gestionado por AWS. Alternativa a Docker Hub pero dentro de tu cuenta AWS con IAM para control de acceso.

**Tag mutable vs inmutable:**
- **Mutable (CircleGuard):** puedes sobrescribir `auth-service-sha-abc1234`. En la práctica no hay problema porque el SHA del commit ya garantiza unicidad.
- **Inmutable:** un tag escrito no puede ser sobrescrito. Más estricto para auditoría.

Formato de tag CircleGuard: `<account>.dkr.ecr.us-east-1.amazonaws.com/circleguard:<service>-sha-<commit7>`. Un solo repo, el servicio va en el tag.

---

### Amazon VPC (Virtual Private Cloud)

Red virtual privada dentro de AWS. Define tu espacio de IPs, subnets, tablas de ruteo, y firewalls (Security Groups / NACLs).

**Conceptos:**
- **CIDR block:** rango de IPs. `10.0.0.0/16` = 65,536 IPs disponibles.
- **Subnet:** subdivisión del CIDR. `/24` = 256 IPs. Las subnets son regionales a una AZ.
- **Subnet pública:** tiene una tabla de ruteo con `0.0.0.0/0 → Internet Gateway`. Los recursos con IP pública son accesibles desde internet.
- **Subnet privada:** tabla de ruteo con `0.0.0.0/0 → NAT Gateway`. Los recursos solo pueden salir a internet, no recibir conexiones entrantes.
- **Internet Gateway (IGW):** puerta de entrada/salida entre el VPC e internet.
- **NAT Gateway:** permite a recursos en subnets privadas hacer requests salientes a internet (ej. para bajar imágenes de ECR), sin exponerse al internet entrante. Va en una subnet pública.
- **Availability Zone (AZ):** datacenter físicamente separado dentro de la misma región. Usar 2 AZs da alta disponibilidad — si una falla, la otra sigue.

---

### Application Load Balancer (ALB)

Balanceador de carga de capa 7 (HTTP/HTTPS). Distribuye tráfico entre targets (Pods K8s en este caso) con soporte para:
- Terminación TLS (el ALB descifra HTTPS; habla HTTP plano a los Pods).
- Routing por path o header.
- Health checks (si un Pod falla el check, se saca de la rotación).

En CircleGuard: el **AWS Load Balancer Controller** corre dentro del cluster K8s y crea ALBs automáticamente cuando detecta un objeto `Ingress` con `ingressClassName: alb`. Hay dos ALBs:
- **Internet-facing:** acepta tráfico del internet → `gateway-service`.
- **Internal:** solo accesible desde dentro del VPC → `dashboard-service`.

---

### IAM OIDC + IRSA

**IAM (Identity and Access Management):** sistema de permisos de AWS. Define *quién* puede hacer *qué* sobre *qué recursos*.

**OIDC (OpenID Connect):** protocolo de identidad federada. Permite que un proveedor externo (GitHub Actions, un K8s service account) demuestre su identidad a AWS sin necesidad de credenciales estáticas (access keys).

**IRSA (IAM Roles for Service Accounts):** mecanismo específico de EKS. Un Pod puede asumir un IAM Role directamente usando su K8s Service Account + OIDC, sin access keys hardcodeadas.

Flujo IRSA en CircleGuard:
1. ESO (External Secrets Operator) corre en un Pod con `ServiceAccount: circleguard-eso-sa`.
2. Ese ServiceAccount tiene una anotación apuntando al IAM role `circleguard-eso-role`.
3. Cuando el Pod hace una llamada a Secrets Manager, AWS verifica el token OIDC firmado por EKS → asume el role temporalmente → otorga permiso solo a `circleguard/*`.

**Por qué importa:** sin IRSA tendrías que meter access keys en Secrets o ConfigMaps — un riesgo de seguridad enorme. Con IRSA, las credenciales son temporales, automáticamente rotadas, y nunca tocan el filesystem.

---

### External Secrets Operator (ESO)

Operador de Kubernetes que sincroniza secretos de fuentes externas (AWS Secrets Manager, Vault, GCP Secret Manager) hacia K8s Secrets nativos.

**Sin ESO:** tienes que crear manualmente los K8s Secrets con los valores correctos en cada namespace y acordarte de actualizarlos cuando rotan.  
**Con ESO:** defines un `ExternalSecret` (objeto K8s) que dice "busca el secreto `circleguard/dev/db-credentials` en Secrets Manager y crea un K8s Secret llamado `db-secret`". ESO lo mantiene sincronizado.

Los Pods consumen el K8s Secret via `envFrom.secretRef` — ni saben que vino de AWS.

---

### GitHub Actions + OIDC

**GitHub Actions:** plataforma de CI/CD integrada en GitHub. Define workflows en archivos YAML (`.github/workflows/`). Se activan por eventos: push, pull request, `repository_dispatch`, manual.

**OIDC con AWS:** en lugar de guardar `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` como secrets de GitHub (estáticos, que pueden filtrarse), GitHub Actions genera un token OIDC firmado por GitHub para cada ejecución. AWS verifica ese token con el IAM Identity Provider y asume el role `circleguard-gha-role` por la duración del workflow.

El rol tiene permisos mínimos: ECR push + EKS deploy + Secrets Manager seed en `circleguard/*`. No puede crear ni destruir infraestructura — eso es deliberado.

---

### Terraform

Herramienta de IaC (Infrastructure as Code). Describe infraestructura en archivos `.tf` (HCL) y la crea/actualiza/destruye en el proveedor (AWS, Azure, GCP).

**Flujo:**
1. `terraform plan` — muestra qué va a crear/cambiar/destruir sin hacer nada.
2. `terraform apply` — ejecuta los cambios.
3. `terraform destroy` — destruye todo lo declarado.

**State:** Terraform guarda el estado actual de la infraestructura en un archivo `terraform.tfstate`. CircleGuard lo guarda en S3 (`circleguard-tfstate`) para que cualquier máquina pueda operar. El bucket NO es gestionado por Terraform (para que sobreviva un `destroy`).

**Módulo:** agrupación reutilizable de recursos. CircleGuard tiene 5 módulos: `vpc`, `eks-cluster`, `ecr`, `github-oidc`, `irsa-secrets`.

**Por qué el provisionamiento es LOCAL (no CI):** crear VPC/EKS/IAM requiere permisos de administrador. El rol de GitHub Actions intencionalmente NO puede crear infra — solo desplegar aplicaciones. Así, incluso si el repo de ops es comprometido, un atacante no puede crear recursos AWS.

---

### Observabilidad: los tres pilares

**Métricas (Prometheus + Grafana):**
- **Prometheus:** scraper de métricas. Los servicios exponen `/actuator/prometheus` (Micrometer en Spring Boot) con contadores, histogramas, gauges. Prometheus los recoge periodicamente y los guarda en su base de datos de series de tiempo.
- **Grafana:** visualización. Se conecta a Prometheus como datasource y muestra dashboards con gráficas de latencia, tasa de errores, uso de CPU/memoria, etc.
- **AlertManager:** gestor de alertas. Prometheus le envía alertas cuando una regla se dispara; AlertManager decide a quién notificar (email, Slack, PagerDuty). En CircleGuard lo manda por SMTP a MailHog.

**Trazas (Jaeger):**
- **Distributed tracing:** cuando una petición pasa por gateway → auth → identity, hay una "traza" que muestra cada salto con su latencia. Imprescindible para debuggear cuál servicio está introduciendo latencia.
- **OpenTelemetry (OTel):** SDK estándar para instrumentar código. Spring Boot lo incluye via `micrometer-tracing`. Los spans se exportan a Jaeger.
- **Jaeger all-in-one:** colector, almacenamiento y UI en un solo contenedor (modo no-producción). En producción se separa en componentes.

**Logs (ELK Stack):**
- **Elasticsearch:** motor de búsqueda e indexado de documentos JSON. Los logs se indexan aquí.
- **Kibana:** UI para buscar y visualizar logs en Elasticsearch.
- **Filebeat:** agente ligero que corre en cada nodo, recoge los logs de los contenedores (stdout/stderr) y los envía a Elasticsearch.

---

### Chaos Engineering (Chaos Mesh)

Disciplina de probar la resiliencia del sistema inyectando fallos de forma controlada, **antes** de que ocurran en producción.

**Tipos de experimentos en CircleGuard (`chaos-experiments.yml`, solo en stage):**
- **Pod-kill:** mata Pods aleatoriamente. Verifica que K8s los reinicia y el servicio sigue disponible.
- **Network partition:** corta la red entre servicios. Verifica que los Circuit Breakers activan y el sistema degrada con gracia.
- **CPU/memory stress:** sobrecarga recursos. Verifica que el HPA escala y las alertas de Prometheus se disparan.

**Chaos Mesh:** operador K8s que define experimentos como objetos CRD (Custom Resource Definition). Se instala con `bootstrap-chaos.yml`.

---

### SonarQube / SonarCloud

Herramienta de análisis estático de código. Detecta:
- **Bugs:** código que probablemente fallará en runtime.
- **Vulnerabilidades:** patrones de seguridad peligrosos (SQL injection, XSS, etc.).
- **Code smells:** código funcional pero difícil de mantener.
- **Cobertura:** qué porcentaje de líneas son ejecutadas por los tests.

**Quality Gate:** umbral configurable. Si el análisis no pasa (ej. cobertura < 80% o hay vulnerabilidades críticas), el pipeline falla y no se construye la imagen.

En CircleGuard: `_reusable-service-ci.yml` llama a SonarCloud (versión cloud de SonarQube) después de los tests. El chart de SonarQube en el cluster está `enabled: false` porque el análisis se hace en CI, no como servicio del cluster.

---

### Trivy + OWASP ZAP

**Trivy (seguridad de imágenes):**
- Escanea imágenes Docker en busca de CVEs (Common Vulnerabilities and Exposures) en las dependencias del SO y del código.
- En stage: escanea y sube reporte SARIF a GitHub Security tab (informativo).
- En prod: gate con `--exit-code 1` — si hay vulnerabilidades HIGH o CRITICAL, el deploy se cancela.

**OWASP ZAP (seguridad dinámica — DAST):**
- No analiza código fuente. Lanza peticiones HTTP reales contra el servicio desplegado y busca vulnerabilidades en comportamiento (OWASP Top 10: XSS, injection, CSRF, etc.).
- "Baseline scan" = escaneo pasivo, no intrusivo. Más rápido.
- Solo corre en stage — en prod el sistema ya tiene usuarios reales.

---

### git-cliff + Release Notes

**git-cliff:** herramienta que lee el historial de commits con formato **Conventional Commits** (`feat:`, `fix:`, `chore:`, etc.) y genera un CHANGELOG automáticamente.

**Conventional Commits:** convención de mensajes de commit: `<tipo>[scope opcional]: descripción`. Permite automatización porque el tipo es parseable por máquinas.

En CircleGuard: el pipeline de producción (`deploy-prod.yml`) corre git-cliff después de un deploy exitoso y crea un GitHub Release con las notas de los commits desde el tag anterior. Así el historial de versiones es automático.

---

## 2. Application Components

**Archivo:** `doc/drawio/Application Components.drawio`  
**Propósito:** mostrar la topología de los 8 microservicios — qué llama a qué, cómo y con qué datos.

### Flujo del contacto-tracing (pasos ①②③)

Este es el corazón del sistema. Entender este flujo es entender CircleGuard:

```
Usuario llena formulario de salud
        ↓ HTTP POST /form via gateway
form-service valida y persiste en PostgreSQL
        ↓ Kafka: survey.submitted
promotion-service consume el evento
        ↓ ② Traversal Neo4j: 14-day window
        ↓ Calcula círculo de exposición
        ↓ Promueve estados: Healthy → Suspect → Probable → Confirmed
        ↓ Kafka: promotion.status.changed
notification-service consume el evento
        ↓ Envía email/push por SMTP/FCM
```

**¿Por qué asíncrono?** El traversal de grafo en Neo4j puede tomar cientos de ms o segundos dependiendo del tamaño del círculo. Con Kafka, form-service responde al usuario inmediatamente ("formulario recibido") y el procesamiento ocurre en background sin que el usuario espere.

### El grafo de exposición

promotion-service mantiene un grafo en Neo4j donde:
- Cada persona es un nodo `Person` con un ID anónimo (nunca nombre real — privacy by design).
- Cada contacto físico registrado es una relación `CONTACT_WITH(timestamp)`.

Cuando alguien reporta síntomas (o es confirmado), promotion-service ejecuta una query Cypher para encontrar todos los nodos a N saltos de distancia donde la relación tenga `timestamp > now - 14 days`. Esos nodos reciben promoción de estado.

Los estados son ordenados: `Healthy < Suspect < Probable < Confirmed`. Un nodo nunca retrocede de estado (regla de negocio: si ya eres Probable, un nuevo contacto Suspect no te "baja").

### Los 8 servicios

| Servicio | Puerto | Responsabilidad principal | DBs |
|---|---|---|---|
| `gateway-service` | 8086 | Routing, validación JWT, cache QR tokens | Redis |
| `auth-service` | 8081 | Login, emisión JWT, bind LDAP | PostgreSQL, OpenLDAP |
| `identity-service` | 8082 | Vault de identidades anónimas (mapeo persona real ↔ ID anónimo) | PostgreSQL |
| `form-service` | 8085 | Formularios de salud dinámicos | PostgreSQL |
| `promotion-service` | 8083 | Motor de rastreo, traversal grafo, promoción de estados | Neo4j, PostgreSQL |
| `dashboard-service` | 8087 | Estadísticas agregadas, filtro K-anonimato | PostgreSQL, Neo4j |
| `notification-service` | 8084 | Envío de alertas | SMTP/FCM |
| `file-service` | 8088 | Adjuntos y certificados de salud | S3-compatible |

### K-anonimato en dashboard-service

El dashboard muestra estadísticas de exposición. Para proteger privacidad, aplica el principio de **K-anonimato**: un grupo de datos solo se muestra si contiene al menos K individuos. Si un grupo tiene menos de K personas (ej. "3 personas en el aula 201"), no se muestra — evita que se pueda identificar a una persona específica por deducción.

### Kafka Topics

| Topic | Producer | Consumer | Semántica |
|---|---|---|---|
| `survey.submitted` | form-service | promotion-service | Formulario nuevo para procesar |
| `promotion.status.changed` | promotion-service | notification-service | Estado de salud cambiado |
| `proximity.detected` | (futuro/mobile) | promotion-service | Contacto bluetooth detectado |
| `audit.identity.accessed` | identity-service | audit log consumer | Acceso a identidad para trazabilidad legal |

### Convenciones del diagrama

- **Flecha sólida:** llamada HTTP síncrona (RestClient/WebClient). El caller espera respuesta.
- **Flecha punteada:** evento Kafka asíncrono. El producer no espera.
- **[CB]:** Circuit Breaker Resilience4j activo en esa llamada.
- **Flecha abierta sin label:** conexión a base de datos (el servicio es dueño de su DB — principio de microservicios).

---

## 3. AWS Deployment Topology

**Archivo:** `doc/drawio/AWS Deployment Topology.drawio`  
**Complemento:** `doc/drawio/AWS Deployment Topology.md`  
**Propósito:** mostrar dónde corre físicamente todo — red, compute, storage y cómo fluye el tráfico.

### La red: VPC y subnets

```
VPC 10.0.0.0/16 (us-east-1)
│
├── AZ us-east-1a
│   ├── Subnet PÚBLICA  10.0.0.0/24   → ruta: 0.0.0.0/0 → IGW
│   │   └── NAT Gateway (con Elastic IP)
│   └── Subnet PRIVADA  10.0.10.0/24  → ruta: 0.0.0.0/0 → NAT
│       └── EC2 worker node (m7i-flex.large) + Pods + EBS gp2 PVCs
│
└── AZ us-east-1b
    ├── Subnet PÚBLICA  10.0.1.0/24   → ruta: 0.0.0.0/0 → IGW
    │   └── Nodo ALB (AZ-b)
    └── Subnet PRIVADA  10.0.11.0/24  → ruta: 0.0.0.0/0 → NAT (en AZ-a)
        └── EC2 worker node (m7i-flex.large) + Pods + EBS gp2 PVCs
```

**Por qué los worker nodes en subnets privadas:** los Pods no deben tener IPs públicas — no hay razón para que internet llegue directamente a ellos. El tráfico legítimo entra por el ALB. El egress (bajar imágenes, llamar Secrets Manager) va por NAT.

**Por qué un solo NAT Gateway:** los NAT Gateway cuestan ~$0.045/hora + $0.045/GB procesado. Con dos AZs lo "correcto" en producción es tener uno por AZ (para que si AZ-a falla, AZ-b siga teniendo egress propio). Para un proyecto académico con presupuesto ajustado, uno solo ahorra ~$30/mes. Los Pods de AZ-b hacen egress cruzando a AZ-a (cross-AZ traffic tiene un costo mínimo pero aceptable).

**Por qué dos AZs:** alta disponibilidad. Si un datacenter falla, los Pods en la otra AZ siguen funcionando. El ALB y EKS están configurados para balancear entre ambas.

### Los 5 flujos del diagrama

**① Acceso del cliente (sólido):**
```
Cliente web/móvil → Internet → IGW → ALB (subnet pública)
```
El cliente solo ve la IP del ALB (DNS público). El IGW es transparente — solo conecta el VPC con internet.

**② Routing del Ingress (sólido):**
```
ALB → gateway-service Pods (en worker nodes, ambas AZs)
```
El AWS Load Balancer Controller (corriendo en el cluster) creó el ALB leyendo el objeto `Ingress` de K8s. El ALB tiene los Pods directamente como targets (`target-type: ip`) — sin pasar por el K8s NodePort. Más eficiente.

Hay un segundo ALB **interno** para dashboard-service (`scheme: internal`). Solo accesible desde dentro del VPC — por ejemplo desde otros servicios del cluster o una VPN.

**③ Pull de imágenes (punteado):**
```
Worker node (kubelet) → ECR (endpoint regional fuera del VPC)
```
Cuando K8s va a arrancar un Pod, el kubelet del nodo baja la imagen de ECR. Como los nodos están en subnets privadas, el tráfico va por NAT → IGW → ECR endpoint público. Alternativamente se puede configurar un VPC Endpoint para ECR (sin salir a internet), pero no está en este diseño.

**④ Secretos en runtime (punteado):**
```
ESO Pod → Secrets Manager (endpoint regional)
```
El External Secrets Operator usa IRSA para autenticarse contra AWS y leer los secretos de `circleguard/<namespace>`. Los crea como K8s Secrets; los Pods los leen como variables de entorno. Los secretos nunca están hardcodeados en imágenes ni en el repo.

**⑤ Egress general (punteado):**
```
Worker nodes (subnets privadas) → NAT Gateway (AZ-a) → IGW → Internet
```
Además de ECR y Secrets Manager, los Pods pueden necesitar salir a internet (dependencias de Gradle en build-time no aplica aquí, pero sí llamadas a APIs externas como FCM para notificaciones push).

### EKS y el EBS CSI Driver

Los StatefulSets (PostgreSQL, Neo4j, Kafka, etc.) necesitan disco persistente. En EKS eso se gestiona así:

1. El StatefulSet declara un `volumeClaimTemplate` con `storageClassName: gp2`.
2. K8s crea automáticamente un `PersistentVolumeClaim`.
3. El **EBS CSI Driver** (addon de EKS) ve el PVC y crea un volumen EBS gp2 en AWS.
4. El volumen se monta en el Pod.

Si el Pod se mueve a otro nodo (por reinicio o rebalanceo), EBS se desmonta del nodo anterior y se monta en el nuevo. EBS es zonal — solo se puede montar en la misma AZ donde está el volumen.

**gp2 vs gp3:** gp3 es la generación más nueva (más barata, más IOPS configurables). CircleGuard usa gp2 porque es el StorageClass por defecto de EKS sin configuración adicional. Se puede migrar a gp3 creando un StorageClass custom.

### Servicios AWS fuera del VPC

| Servicio | Propósito | ¿Quién lo usa? |
|---|---|---|
| **ECR** | Registro de imágenes Docker | Nodos al arrancar Pods |
| **S3 `circleguard-tfstate`** | Estado Terraform | Terraform (local, admin) |
| **Secrets Manager** | Secretos de runtime (DB passwords, JWT secret) | ESO via IRSA |
| **IAM OIDC + `circleguard-gha-role`** | Identidad federada para GitHub Actions | Workflows de deploy |

### Namespaces como ambientes

```
EKS cluster: circleguard-eks
├── namespace: dev          ← para desarrollo, deploy automático en cada push
├── namespace: stage        ← para testing, deploy + E2E + Locust + ZAP
└── namespace: production   ← usuarios reales, deploy con aprobación manual
```

No son clusters separados — todo está en el mismo EKS. Los namespaces son **aislamiento lógico**, no de red (los Pods en distintos namespaces pueden hablarse por DNS si tienen permisos de Service). Para aislamiento de red real se necesitarían NetworkPolicies o Istio.

**Ventaja de namespaces:** costo — un solo cluster EKS en lugar de tres.  
**Desventaja:** un bug en un Pod malicioso en `dev` podría afectar `production` si no hay NetworkPolicies. Aceptable para un proyecto académico.

---

## 4. CI-CD GitOps

**Archivo:** `doc/drawio/CI-CD GitOps.drawio`  
**Propósito:** mostrar el pipeline completo desde que un developer hace `git push` hasta que el código está en producción.

### El modelo GitOps

**GitOps** es la práctica de usar Git como fuente de verdad para el estado del sistema. Cualquier cambio en infraestructura o configuración pasa por un PR. El estado real del cluster debe coincidir con lo que está en Git.

En CircleGuard:
- El repo `microservices-circle-guard-dev` es la fuente de verdad para el **código**.
- El repo `microservices-circle-guard-ops` es la fuente de verdad para el **estado de despliegue** (Helm charts, valores por ambiente, Terraform).
- Nadie hace `kubectl apply` manual en producción — todo pasa por el pipeline.

### Separación de repos (dev vs ops)

**¿Por qué dos repos?** Hay varios motivos:

1. **Permisos distintos:** el rol de GitHub Actions del ops repo tiene permisos de deploy a K8s. Si estuviera en el mismo repo que el código, cualquier developer podría modificar el pipeline de producción.
2. **Historial limpio:** el historial del ops repo muestra solo cambios de infraestructura/configuración. Fácil de auditar quién cambió qué en producción.
3. **Frecuencias distintas:** el código cambia decenas de veces al día; la infraestructura cambia raramente. Mezclarlos crea ruido.
4. **El ops repo es service-agnostic:** no sabe de Go vs Java — solo recibe `(SERVICE, IMAGE_TAG)` y despliega.

### El pipeline completo

```
Developer hace git push (rama develop)
        │
        ▼
GitHub Actions — per-service CI (_reusable-service-ci.yml)
  ├── 1. Test (Gradle test + JaCoCo coverage)
  ├── 2. SonarQube analysis → SonarCloud quality gate (wait)
  ├── 3. Build Docker image (buildx, multi-arch)
  ├── 4. Push a ECR con tag <service>-sha-<commit7>
  ├── 5. Trivy scan → SARIF upload a GitHub Security
  └── 6. repository_dispatch → ops repo (SERVICE + IMAGE_TAG)
        │
        ▼
Ops repo — deploy-dev.yml (namespace: dev)
  ├── 1. Configure AWS credentials via OIDC
  ├── 2. aws eks update-kubeconfig
  ├── 3. Sync secrets (Secrets Manager → K8s)
  ├── 4. helm lint <chart>
  ├── 5. helm upgrade --install
  ├── 6. kubectl rollout status (espera pods Ready)
  └── 7. e2e/smoke test (e2e.sh)
        │
        ▼
Ops repo — deploy-stage.yml (namespace: stage)
  ├── 1. Trivy scan (mismo tag)
  ├── 2. Deploy (igual que dev)
  ├── 3. E2E tests (e2e/<service>/e2e.sh)
  ├── 4. OWASP ZAP baseline scan
  ├── 5. Locust load test
  └── 6. Cross-service E2E
        │
        ▼ (solo rama main)
Ops repo — deploy-prod.yml (namespace: production)
  ├── 1. Verificar imagen existe en ECR
  ├── 2. Trivy gate — si HIGH/CRITICAL: ABORT
  ├── 3. Aprobación manual (GitHub Environment protection rules)
  ├── 4. helm upgrade --atomic (rollback automático si falla)
  └── 5. git-cliff → GitHub Release con notas
```

### OIDC en detalle

Cuando `_reusable-service-ci.yml` corre:

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: us-east-1
```

Lo que ocurre:
1. GitHub genera un JWT OIDC firmado por `token.actions.githubusercontent.com`.
2. AWS STS verifica ese JWT contra el IAM Identity Provider registrado.
3. Si la claim `sub` matchea (ej. `repo:org/repo:ref:refs/heads/develop`), AWS entrega credenciales temporales (15-60 min) para el role `circleguard-gha-role`.
4. El workflow puede llamar ECR, EKS, etc. con esas credenciales.

**Ventaja crítica:** si el repositorio es comprometido, no hay credenciales de larga duración que rotar. Las temporales expiran solas.

### repository_dispatch

Mecanismo de GitHub para que un repo desencadene un workflow en otro repo.

```yaml
# En dev repo — dispara al ops repo
- name: Trigger ops deployment
  uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.GH_TOKEN }}
    repository: org/microservices-circle-guard-ops
    event-type: deploy-dev
    client-payload: |
      {
        "service": "${{ inputs.service }}",
        "image_tag": "${{ env.IMAGE_TAG }}"
      }
```

El ops repo tiene un workflow con `on: repository_dispatch: types: [deploy-dev]` que lee `github.event.client_payload.service` y `github.event.client_payload.image_tag`.

### Provisionamiento local (no CI) — por qué es deliberado

```
scripts/init-s3-backend.sh   ← UNA vez, admin local: crea el bucket S3
scripts/aws-up.sh             ← terraform apply: VPC + EKS + ECR + IAM + IRSA
scripts/aws-down.sh           ← terraform destroy: borra todo (menos el bucket S3)
```

El rol OIDC de GitHub Actions (`circleguard-gha-role`) tiene permisos explícitamente limitados a:
- `ecr:PutImage`, `ecr:BatchCheckLayerAvailability` (push de imágenes)
- `eks:DescribeCluster` (para `update-kubeconfig`)
- `secretsmanager:PutSecretValue` en `circleguard/*` (seed inicial de secretos)

**No puede:**
- Crear/modificar/destruir recursos VPC, EKS, ECR, IAM.
- Acceder a otras cuentas o regiones.

Esto implementa el **principio de mínimo privilegio**: incluso si el pipeline es comprometido, el atacante no puede crear recursos en AWS.

### Bootstrap de cluster (orden de operaciones)

Cuando se crea el cluster desde cero, el orden importa:

```
0a. init-s3-backend.sh           ← S3 bucket para tfstate (prereq de Terraform)
0b. aws-up.sh (terraform apply)  ← VPC, EKS, ECR, IAM OIDC, IRSA roles
                                    → output: gha_role_arn → GitHub Secret AWS_ROLE_ARN
1.  bootstrap-eso.yml            ← instala ESO + ClusterSecretStore (prereq de secretos)
2.  bootstrap-chaos.yml          ← instala Chaos Mesh (prereq de experimentos)
3.  deploy-data-plane.yml        ← PostgreSQL, Neo4j, Kafka, Redis, etc. (por namespace)
4.  deploy-{dev,stage,prod}.yml  ← servicios de la aplicación
```

Si el paso 1 no se hizo, los Pods fallarán porque no pueden leer secretos. Si el paso 3 no se hizo, los servicios fallarán porque no tienen BD. El orden es causal.

---

## 5. Cloud Architecture Diagram

**Archivo:** `doc/drawio/Cloud Architecture Diagram.drawio`  
**Propósito:** vista ejecutiva de todo el sistema — repos, AWS, pipeline, datos y bonus en un solo diagrama.

### Capas del diagrama

Este diagrama tiene 5 capas conceptuales que conviene leer de izquierda a derecha:

```
[Developer]
    ↓
[Dev repo (código)]  ──────────────────────────────────────────┐
    ↓ CI (GitHub Actions)                                       │
[ECR (imágenes)]     ← push con tag <service>-sha-<commit>     │
    ↓                                                           │
[Ops repo (deploy)]  ←── repository_dispatch ──────────────────┘
    ↓ helm upgrade via OIDC
[EKS cluster]        ← 3 namespaces: dev / stage / production
    ↑
[AWS global: IAM OIDC, S3 tfstate, Secrets Manager, ECR]
    ↑ (Terraform local)
[Terraform en máquina del admin]
```

### El dev repo en detalle

```
microservices-circle-guard-dev/
├── services/
│   ├── circleguard-auth-service/
│   ├── circleguard-identity-service/
│   ├── ...
│   └── circleguard-file-service/
├── mobile/                          ← Expo/React Native
├── .github/workflows/
│   ├── _reusable-service-ci.yml     ← CI común a todos
│   ├── auth-service.yml             ← llama al reusable con service=auth
│   ├── ...
│   └── release.yml                  ← git-cliff en main
└── docker-compose.dev.yml           ← stack local para desarrollo
```

`docker-compose.dev.yml` levanta PostgreSQL, Neo4j, Kafka, Zookeeper, Redis y OpenLDAP localmente para que los developers puedan correr los servicios sin necesitar AWS.

### Ambiente dev vs stage vs production

| Característica | dev | stage | production |
|---|---|---|---|
| Trigger | push a `develop` | push a `develop` (después de dev) | push a `main` |
| Réplicas | 1 | 2 | 2+ |
| HPA | no | no | sí (auth, gateway) |
| Resilience4j CB | básico | activo | activo |
| Trivy | solo reporte | reporte | gate (bloquea) |
| OWASP ZAP | no | baseline scan | no |
| Locust | no | sí | no |
| Chaos Mesh | no | sí | no |
| Aprobación manual | no | no | sí |
| Release notes | no | no | sí (git-cliff) |

### HPA — cuándo escala

HPA observa métricas (CPU por defecto) y ajusta el número de réplicas:

```
si CPU promedio > 70% por > 1 min → scale up
si CPU promedio < 30% por > 5 min → scale down
```

Solo `auth-service` y `gateway-service` tienen HPA. Son los que reciben tráfico externo directo y tienen picos predecibles. Los servicios de backend (promotion, form) escalan menos — sus picos vienen de Kafka (que actúa como buffer).

### Observabilidad — stack completo

```
Spring Boot (Micrometer + OTel)
    ↓ HTTP /actuator/prometheus          ↓ OTLP gRPC
Prometheus ──────────────────────────→ Jaeger
    ↓ alerting rules                       ↓ UI
AlertManager                            http://jaeger:16686
    ↓ SMTP
MailHog (UI: http://mailhog:8025)

Filebeat (cada nodo)
    ↓ leer /var/log/containers/*.log
Elasticsearch
    ↓ índice
Kibana (UI: http://kibana:5601)

kube-state-metrics
    ↓ expone métricas de objetos K8s
Prometheus ──→ Grafana
               (dashboards: http://grafana:3000)
```

Todos estos componentes corren como Pods en el cluster, desplegados por el Helm chart `circleguard-infra`. El mismo chart que despliega PostgreSQL y Kafka también despliega Prometheus y Jaeger — simplifica las operaciones porque un solo `helm upgrade` actualiza todo.

### Bonus planificados (líneas punteadas)

**Bonus 1 — Multi-cloud (Azure):**
- Objetivo: desplegar un subconjunto de servicios en AKS (Azure Kubernetes Service) además de EKS.
- Mecanismo: `_reusable-service-ci.yml` empujaría la imagen también a ACR (Azure Container Registry). Un segundo paso en los workflows de ops haría `helm upgrade` en AKS.
- Estado actual: planificado, sin código. Aparece en el diagrama con líneas punteadas para documentar la intención.
- **¿Por qué AWS + Azure y no AWS + GCP?** AWS y Azure son el pairing más documentado en entornos enterprise. El ops repo del equipo auxiliar tenía Terraform para Azure, lo que reduciría el tiempo de implementación.

**Bonus 2 — Service Mesh (Istio):**
- Objetivo: mTLS entre todos los microservicios (encriptación pod-a-pod), control de tráfico via VirtualService (canary deployments, circuit breaking a nivel de red), y observabilidad de malla en Kiali.
- Estado actual: planificado, sin código. Istio es complejo de operar y tiene overhead de CPU por los sidecars Envoy.

---

## 6. Cómo se relacionan los cuatro diagramas

Cada diagrama es una **vista** del mismo sistema. Son complementarios, no redundantes:

```
┌─────────────────────────────────────────────────────────────────┐
│              ¿Qué hace el sistema?                              │
│           Application Components                                │
│  (servicios, APIs, Kafka, DBs, flujo de negocio)               │
└──────────────────────────┬──────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
┌─────────────────┐  ┌──────────────┐  ┌──────────────────────┐
│ ¿Dónde corre?   │  │ ¿Cómo llega  │  │ Vista completa +     │
│ AWS Deployment  │  │  el código?  │  │ roadmap              │
│ Topology        │  │ CI-CD GitOps │  │ Cloud Architecture   │
│ (red, VMs,      │  │ (pipeline,   │  │ Diagram              │
│  K8s, storage,  │  │  test gates, │  │ (todo junto +        │
│  tráfico)       │  │  deploy,     │  │  bonus items)        │
│                 │  │  OIDC)       │  │                      │
└─────────────────┘  └──────────────┘  └──────────────────────┘
```

**Pregunta práctica → diagrama a consultar:**

| Situación | Diagrama |
|---|---|
| "¿Por qué notification-service recibe el evento Y?" | Application Components |
| "¿Qué le pasa a un Pod si AZ-a se cae?" | AWS Deployment Topology |
| "¿Qué tiene que pasar para que un commit llegue a producción?" | CI-CD GitOps |
| "¿Qué aprobaciones faltan para el Proyecto Final?" | Cloud Architecture (bonus punteados) |
| "¿Qué métricas y logs tenemos disponibles?" | Cloud Architecture (observabilidad) |
| "¿Cómo se autentica GitHub Actions con AWS?" | CI-CD GitOps + AWS Deployment Topology |
| "¿Dónde está el secreto de la base de datos?" | AWS Deployment Topology (ESO/IRSA flow) |

---

*Documento generado a partir del estado actual del repositorio `microservices-circle-guard-ops` — 2026-06-10.*
