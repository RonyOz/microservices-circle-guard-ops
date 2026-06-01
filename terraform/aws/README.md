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
> change the S3 backend bucket name (globally unique) in `main.tf` + `scripts/init-s3-backend.sh`.

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

> **State backend** is not a module: the S3 bucket is created by `scripts/init-s3-backend.sh`
> (run once, locally) and wired via the `backend "s3"` block in `main.tf`. Locking is
> S3-native (`use_lockfile = true`, Terraform ≥ 1.10) — **no DynamoDB**.
>
> **Bootstrap (once per account, local, admin creds):** run `scripts/init-s3-backend.sh`
> (S3 bucket), then `terraform apply` here — it provisions VPC/EKS/ECR/OIDC/IRSA and the
> EKS access entry. Set the `gha_role_arn` output as the `AWS_ROLE_ARN` GitHub secret.
> Provisioning runs locally (admin), NOT in CI — the GHA OIDC role is narrow by design.

## Region rationale

`us-east-1` chosen for: lowest latency from Colombia among AWS US regions, full service coverage (EKS, ECR, Secrets Manager, Budgets), and cheapest data transfer rates.
