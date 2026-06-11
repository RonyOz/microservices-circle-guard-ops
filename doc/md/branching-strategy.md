# Branching Strategy

Debido a que software e infraestructura tienen ciclos de vida y riesgos diferentes, CircleGuard aplica estrategias de branching especializadas por repositorio.

| Repositorio | Estrategia | Razón |
|-------------|-----------|-------|
| `microservices-circle-guard-dev` | GitFlow | Ciclo de release controlado; features paralelas; hotfixes urgentes |
| `microservices-circle-guard-ops` | Trunk-Based Development | Cambios de infraestructura pequeños y frecuentes; deploy inmediato requerido |

---

## 2.1 GitFlow para desarrollo (`microservices-circle-guard-dev`)

### Rationale

El repositorio de aplicación maneja 8 microservicios con features que se desarrollan en paralelo, versiones de release formales, y la posibilidad de hotfixes urgentes en producción sin mezclar código incompleto de desarrollo. GitFlow separa estos ciclos claramente.

### Ramas permanentes

| Rama | Estado que representa | Deploy destino |
|------|-----------------------|---------------|
| `main` | Estado de producción — código en `production` namespace | EKS `production` via `deploy-prod.yml` |
| `develop` | Estado de staging — integración continua de features | EKS `stage` via `deploy-stage.yml` |

**Regla crítica:** Nunca se hace merge directo de `feature/*` a `main`. Todo feature pasa por `develop` primero.

### Ramas de corta duración

| Tipo | Patrón | Nace desde | Se mergea a | Propósito |
|------|--------|-----------|------------|-----------|
| Feature | `feature/<historia>` | `develop` | `develop` | Nueva funcionalidad por historia de usuario |
| Hotfix | `hotfix/<descripción>` | `main` | `main` + `develop` | Corrección urgente en producción |
| Release | `release/<descriptor>` | `develop` | `main` + `develop` | Promoción a stage y luego a producción. **El nombre NO lleva versión** — la versión la determina release-please en `main` (ver "Versioning"). Efímera: se elimina tras el merge a `main` |

### Flujo de una feature nueva

```
develop
  │
  ├── feature/us-02-confirm-covid-case
  │        │  (desarrollo, tests)
  │        ▼
  │   PR: feature/* → develop
  │        │  (CI: build + test + helm lint)
  │        ▼
  │   merge a develop ──→ deploy-stage.yml dispara
  │                          (E2E + Locust en stage namespace)
  │
  ├── (cuando listo para release)
  │   release/candidate nace desde develop
  │        │  (estabilización; SIN bump manual de versión)
  │        ▼
  │   push a release/* ──→ deploy-stage.yml dispara (E2E + ZAP + Locust en stage)
  │        │
  │        ▼
  │   PR: release/* → main
  │        │  (aprobación manual requerida)
  │        ▼
  │   merge a main ──→ deploy-prod.yml dispara (--atomic)
  │                ──→ release-please abre/actualiza el release-PR y, al mergearlo,
  │                    publica el tag vN + GitHub Release (notas) en el dev repo
  │                ──→ git-cliff registra el despliegue en el ops repo
  │        │
  │        └──→ borrar release/* (efímera); back-merge no necesario si squash a develop
```

### Flujo de un hotfix urgente

```
main (producción rota)
  │
  ├── hotfix/auth-token-expiry-fix
  │        │  (fix mínimo, tests)
  │        ▼
  │   PR: hotfix/* → main
  │        │  (aprobación requerida — es producción)
  │        ▼
  │   merge a main ──→ deploy-prod.yml dispara
  │        │
  │        └──→ back-merge hotfix/* → develop
  │                  (para que develop no pierda el fix)
```

**Por qué back-merge es obligatorio:** Si el hotfix no se reintegra a `develop`, la siguiente release sobreescribirá el fix en producción.

### Convención de nombres

```
feature/us-01-qr-campus-checkin
feature/us-03-health-survey-submission
hotfix/promotion-kafka-null-pointer
release/candidate          # sin versión en el nombre — release-please la calcula
```

### Commit message convention

Todos los commits siguen **Conventional Commits** (`<type>(<scope>): <description>`):

| Tipo | Cuándo usar |
|------|------------|
| `feat` | Nueva funcionalidad |
| `fix` | Bug fix |
| `chore` | Tooling, deps, config |
| `refactor` | Reestructuración sin cambio de comportamiento |
| `docs` | Solo documentación |
| `test` | Agregar o actualizar tests |
| `perf` | Mejoras de performance |

**release-please** (dev repo) parsea estos tipos para calcular la versión y generar las notas del GitHub Release. **git-cliff** (ops repo) los parsea para el registro de despliegue del ops repo. Ver "Versioning".

### Versioning (release-please es la autoridad)

La versión la gestiona automáticamente **release-please** en `main`, calculándola desde los conventional commits acumulados desde el último release:

| Commit | Bump |
|--------|------|
| `fix:` | patch (`1.0.0 → 1.0.1`) |
| `feat:` | minor (`1.0.0 → 1.1.0`) |
| `feat!:` / `BREAKING CHANGE:` | major (`1.0.0 → 2.0.0`) |

Reglas:
- **Las ramas `release/*` NO llevan la versión en el nombre.** Son ramas efímeras de promoción (a stage primero, luego a prod vía merge a `main`). El número de versión lo decide release-please, no el nombre de la rama — así no hay dos fuentes de verdad.
- La versión canónica es el **tag `vN` + GitHub Release** que release-please publica al mergear su *release-PR* en `main` (dev repo).
- Para **fijar una versión puntual** (override), añade `Release-As: x.y.z` en el cuerpo de un commit del PR a `main`.
- `git-cliff` en `deploy-prod.yml` crea **solo** el registro de despliegue en el **ops repo** (que no usa release-please). No duplica el release del dev repo.

### PR policy (dev repo)

- PRs obligatorios para todo merge — no direct push a `main` ni `develop`
- PR title sigue Conventional Commits
- CI debe pasar: `./gradlew test`, Helm lint, Docker build
- Squash merge para `feature/*` → `develop` (historia lineal)
- Merge commit para `release/*` → `main` (preservar el tag del release)
- Mínimo 1 aprobación

---

## 2.2 Trunk-Based Development para infraestructura (`microservices-circle-guard-ops`)

### Rationale

El repositorio de ops maneja workflows de CI/CD, Helm charts, y Terraform. Los cambios son típicamente pequeños (ajustar un probe, actualizar un timeout, añadir un step de CI) y deben llegar a `main` rápidamente porque `main` es lo que el cluster consume. Una rama de ops que vive 2 semanas puede divergir de la realidad del cluster.

Trunk-Based Development minimiza ese drift: ramas cortas (máx 2 días), PR inmediato, merge frecuente.

### Rama permanente

| Rama | Estado que representa |
|------|-----------------------|
| `main` | Única fuente de verdad — lo que está deployado en el cluster |

No existe `develop` en ops. No hay `feature/*` de larga duración. Todo va directo a `main` via PR.

### Ramas de corta duración

| Tipo | Patrón | Max lifetime | Ejemplo |
|------|--------|-------------|---------|
| Update | `update/<componente>` | 2 días | `update/auth-service-helm-probes` |
| Fix | `fix/<descripción>` | 2 días | `fix/deploy-dev-port-forward` |

### Flujo

```
main
  │
  ├── update/prometheus-helm-chart
  │        │  (cambio pequeño, probado en dev)
  │        ▼
  │   PR: update/* → main
  │        │  (CI: helm lint, workflow syntax check)
  │        ▼
  │   Squash merge → main
  │        │
  │        └──→ (si afecta un servicio) deploy-dev.yml dispara automáticamente
```

### PR policy (ops repo)

- PRs obligatorios, no direct push a `main`
- Helm lint debe pasar en CI antes de merge
- Mínimo 1 aprobación
- Squash merge siempre
- Branches se eliminan inmediatamente post-merge
