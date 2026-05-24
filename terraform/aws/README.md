# AWS Infrastructure — CircleGuard

## Account

| Field | Value |
|-------|-------|
| Account ID | `354287460358` |
| Primary region | `us-east-1` |
| AWS profile | `circleguard` |
| Budget cap | $20 / month (alert threshold) |
| Budget total | ~$100 USD (academic credit) |

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
| S3+DynamoDB backend | `modules/s3-backend/` |

## Region rationale

`us-east-1` chosen for: lowest latency from Colombia among AWS US regions, full service coverage (EKS, ECR, Secrets Manager, Budgets), and cheapest data transfer rates.
