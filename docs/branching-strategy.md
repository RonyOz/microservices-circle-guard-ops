# Branching Strategy

CircleGuard uses **Trunk-Based Development** across both `microservices-circle-guard-dev` and `microservices-circle-guard-ops` repositories.

## Rationale

Trunk-based development minimizes merge conflicts, keeps the main branch always deployable, and maps naturally to a GitHub Actions CI/CD model where every push to `main` can trigger a production pipeline. Short-lived branches enforce small, reviewable changes and prevent long-running divergence.

## Branch Types

| Type | Pattern | Max Lifetime | Purpose |
|------|---------|-------------|---------|
| **Trunk** | `main` | Indefinite | Always deployable; production deploys originate here |
| **Feature / Update** | `update/<component>` | 2 days | New features or enhancements (e.g., `update/auth-jwt-refresh`) |
| **Fix** | `fix/<description>` | 2 days | Bug fixes (e.g., `fix/gateway-probe-port`) |

There are no `develop`, `release/*`, or `hotfix/*` branches. All changes flow through short-lived branches → PR → `main`.

## Commit Message Convention

All commits must follow **Conventional Commits** (`<type>(<scope>): <description>`):

| Type | When to use |
|------|------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `chore` | Tooling, dependencies, config |
| `refactor` | Code restructuring without behavior change |
| `docs` | Documentation only |
| `test` | Adding or updating tests |
| `perf` | Performance improvements |

`git-cliff` parses these types to auto-generate GitHub Release notes on every production deploy. Non-conventional commits appear under "Other" in the changelog.

Examples:
```
feat(promotion): add recursive graph traversal for PROBABLE status
fix(deploy-dev): add kubectl port-forward before smoke test
docs(branching): add formal branching strategy document
chore(deps): bump Spring Boot to 3.2.5
```

## Pull Request Policy

- **PRs are mandatory** for every merge to `main`. No direct pushes.
- PR title must follow Conventional Commits format.
- PR must pass all required CI checks before merge:
  - Build and unit tests (`./gradlew test`)
  - Helm lint (`helm lint services/<service>/chart/`)
  - Docker image build (no push required for dev/PR)
- **Squash merge** is preferred to keep `main` history linear and git-cliff-parseable.
- At least **1 reviewer approval** required before merge.

## Recommended GitHub Branch Protection Rules (for `main`)

Apply these settings under **Settings → Branches → Branch protection rules**:

```
Branch name pattern: main
✅ Require a pull request before merging
  ✅ Require approvals: 1
  ✅ Dismiss stale PR approvals when new commits are pushed
✅ Require status checks to pass before merging
  Required checks: build (CI workflow)
✅ Require branches to be up to date before merging
✅ Do not allow bypassing the above settings
❌ Allow force pushes  (disabled)
❌ Allow deletions     (disabled)
```

## Workflow Integration

```
developer push to update/<x> or fix/<x>
         │
         ▼
    GitHub PR opened
         │
         ▼
    CI runs (build + test + helm lint)
         │
    PR approved + CI green
         │
         ▼
    Squash merge → main
         │
         ▼
    GHA per-service workflow triggers
         │
    (dev branch) → repository_dispatch → deploy-dev
    (main)        → repository_dispatch → deploy-prod
```

## Sprint Branch Hygiene

- Delete branches immediately after merge (GitHub setting: **Automatically delete head branches**).
- If a branch exceeds its 2-day limit without merging, either merge it or close the PR and open a smaller one.
- Stale branches (no activity > 3 days) should be cleaned up weekly.
