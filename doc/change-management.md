# Change Management

This document describes how changes are proposed, reviewed, deployed, and (if necessary) rolled back in CircleGuard.

---

## Pull Request Process

### PR Title Format

Every PR title must follow Conventional Commits:

```
<type>(<scope>): <short description>

Examples:
feat(promotion): add recursive PROBABLE cascade via Neo4j
fix(deploy-dev): add kubectl port-forward before smoke test
docs(infra): add multi-environment architecture diagram
chore(deps): upgrade Spring Boot to 3.2.5
```

Valid types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`

### PR Description Template

```markdown
## What and why
<!-- What does this PR change and why is it needed? -->

## Changes
- 

## Test evidence
<!-- Screenshot, CI link, or kubectl output showing the change works -->

## Checklist
- [ ] Commits follow Conventional Commits format
- [ ] CI passes (build + tests + Helm lint)
- [ ] No secrets hardcoded (no passwords, keys, or tokens in code)
- [ ] Relevant documentation updated
- [ ] Smoke test passed in dev namespace (for service changes)
```

### Required Reviewers

At minimum **1 approval** from a project teammate before merge. Recommended `CODEOWNERS` file:

```
# .github/CODEOWNERS
*                          @RonyOz @Juanpapb0401
/services/                 @RonyOz
/.github/workflows/        @Juanpapb0401
/terraform/                @Juanpapb0401
```

### Definition of Done

A change is considered done when all of the following are true:

- [ ] CI workflow passes (build, test, Helm lint)
- [ ] PR reviewed and approved by at least 1 teammate
- [ ] Squash-merged into `main`
- [ ] Deploy-dev workflow passes (pod reaches `1/1 Running` in `dev` namespace)
- [ ] Smoke test in dev namespace exits 0 (or no e2e script exists for the service)
- [ ] GitHub Project board item moved to **Done**

---

## Deployment Gates

| Environment | Gate | How |
|------------|------|-----|
| `dev` | Automatic on merge to `main` | `repository_dispatch` from dev repo CI |
| `stage` | Automatic on merge to `main` | `repository_dispatch` from dev repo CI |
| `production` | Manual approval required | GitHub Environment `production` with required reviewers; deploy job waits for approval before running |

Production deploy additionally verifies image existence in ECR before proceeding:
```bash
aws ecr describe-images \
  --repository-name circleguard \
  --image-ids imageTag=<service>-<sha>
```
If the image does not exist, the pipeline fails fast before requesting approval.

---

## Rollback Procedures

### Helm Rollback (recommended for service failures)

Use when a deploy to `stage` or `production` causes service degradation:

```bash
# 1. Check current namespace pod status
kubectl get pods -n production

# 2. View Helm release history
helm history <service-name> -n production

# Output example:
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         deployed    Upgrade complete
# 3         failed      Upgrade failed

# 3. Rollback to last known-good revision
helm rollback <service-name> <revision> -n production

# Example: rollback auth-service to revision 2
helm rollback auth-service 2 -n production

# 4. Verify pods recover
kubectl rollout status deployment/auth-service -n production --timeout=120s
```

Note: `deploy-prod.yml` uses `--atomic`, so production deploys auto-rollback on failure. Manual `helm rollback` is for cases where a deploy succeeded but post-deploy issues are discovered.

### Git Tag Revert (for release rollback)

Use when a git tag needs to be retracted (e.g., bad version tagged and released):

```bash
# Delete the tag locally
git tag -d v<version>

# Delete the tag on remote
git push origin :refs/tags/v<version>

# If the commit itself needs reverting, create a revert commit:
git revert <bad-commit-sha>
# Opens editor for commit message — use: "revert: <original-message>"
git push origin main   # via PR, not direct push
```

### Emergency Procedures

If `production` is completely down and Helm rollback is insufficient:

1. **Check pod logs**: `kubectl logs -n production deployment/<service> --previous`
2. **Check events**: `kubectl get events -n production --sort-by='.lastTimestamp'`
3. **Scale to zero and back**: `kubectl scale deployment/<service> --replicas=0 -n production && kubectl scale deployment/<service> --replicas=1 -n production`
4. **Delete stuck pods**: `kubectl delete pod -n production -l app=<service>`
5. **Last resort**: re-trigger `deploy-prod.yml` workflow manually with the last known-good image tag via `repository_dispatch`

---

## Secrets Change Process

To rotate a runtime secret (DB password, JWT key):

1. Update the secret value in AWS Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id "circleguard/production" \
     --secret-string '{"DB_PASSWORD":"<new>","JWT_SECRET":"<new>","DB_USERNAME":"circleguard","NEO4J_USERNAME":"neo4j","NEO4J_PASSWORD":"<new>"}'
   ```
2. Wait up to 1 hour for ESO to sync the new value to the K8s Secrets (refresh interval: `1h`)
3. Force immediate sync if needed:
   ```bash
   kubectl annotate externalsecret <service>-external-secret \
     -n production force-sync=$(date +%s) --overwrite
   ```
4. Restart pods to pick up the new secret:
   ```bash
   kubectl rollout restart deployment/<service> -n production
   ```
5. Update the corresponding GitHub Actions Secret (same name) for CI-time usage:
   Settings → Secrets → Actions → update `DB_PASSWORD` / `JWT_SECRET`

See `doc/secrets-management.md` for the full secrets matrix and architecture.

---

## Audit Trail

Every production change produces an audit trail via:

- **GitHub Actions run history**: all deploy workflow runs are logged in the repo Actions tab
- **Helm history**: `helm history <service> -n production` shows every revision with timestamps
- **GitHub Releases**: `deploy-prod.yml` creates a GitHub Release with git-cliff-generated CHANGELOG after each successful production deploy
- **AWS CloudTrail**: every Secrets Manager access is logged (useful for security audits)
