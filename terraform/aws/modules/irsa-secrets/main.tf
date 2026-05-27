terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── Secrets Manager secrets (one per namespace) ───────────────────────────────

resource "aws_secretsmanager_secret" "runtime" {
  for_each = toset(var.namespaces)

  name                    = "circleguard/${each.key}"
  description             = "CircleGuard runtime secrets for namespace ${each.key}"
  recovery_window_in_days = 0
  tags                    = var.tags
}

# ── IAM policy: read secrets ──────────────────────────────────────────────────

data "aws_iam_policy_document" "sm_read" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      for ns, secret in aws_secretsmanager_secret.runtime : secret.arn
    ]
  }
}

resource "aws_iam_policy" "sm_read" {
  name   = "${var.role_name}-sm-read"
  policy = data.aws_iam_policy_document.sm_read.json
  tags   = var.tags
}

# ── IRSA role for external-secrets-operator ───────────────────────────────────

data "aws_iam_policy_document" "eso_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "eso_sm_read" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.sm_read.arn
}
