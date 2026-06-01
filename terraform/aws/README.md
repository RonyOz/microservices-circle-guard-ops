# AWS Infrastructure — CircleGuard

## Account

| Field | Value |
|-------|-------|
| Account ID (current deploy) | `888900520630` |
| Primary region | `us-east-1` |
| AWS profile | `circleguard` |
| Budget cap | $20 / month (alert threshold) |
| Budget total | ~$100 USD (academic credit) |

> **Account is swappable.** The ID above documents the current deployment only —
> Terraform and the workflows never hardcode it (provider derives it from your
> credentials; the ESO ARN is built at runtime via `aws sts get-caller-identity`).
> To deploy on a different account, just authenticate with it; you only need to
> change the S3 backend bucket name (globally unique) in `main.tf` + `bootstrap/bootstrap.sh`.

## Verify access

```bash
aws sts get-caller-identity --profile circleguard
# or using default profile (already set to us-east-1):
aws sts get-caller-identity
```

## Modules

| Module | Path |
|--------|------|
| VPC | `modules/vpc/` |
| EKS cluster | `modules/eks-cluster/` |
| ECR | `modules/ecr/` |
| GitHub OIDC | `modules/github-oidc/` |
| IRSA / Secrets Manager | `modules/irsa-secrets/` |

> **State backend** is not a module: the S3 bucket is created by `bootstrap/bootstrap.sh`
> (run once, locally) and wired via the `backend "s3"` block in `main.tf`. Locking is
> S3-native (`use_lockfile = true`, Terraform ≥ 1.10) — **no DynamoDB**.
>
> **Bootstrap (once per account, local, admin creds):** `bootstrap/bootstrap.sh` creates
> the S3 bucket **and** the identity layer (`module.github_oidc` → OIDC provider + GHA
> role, pulling in `module.ecr`), then prints the `gha_role_arn` to set as the
> `AWS_ROLE_ARN` GitHub secret. Everything else (VPC/EKS/IRSA) runs in CI via OIDC.

## Region rationale

`us-east-1` chosen for: lowest latency from Colombia among AWS US regions, full service coverage (EKS, ECR, Secrets Manager, Budgets), and cheapest data transfer rates.
