terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── OIDC provider for GitHub Actions ─────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's OIDC thumbprint — stable, rotated by GitHub with 6-month notice
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

# ── IAM role assumed by GHA workflows ────────────────────────────────────────

data "aws_iam_policy_document" "gha_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.subject_patterns
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gha" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
  tags               = var.tags
}

# ── ECR push policy ───────────────────────────────────────────────────────────

resource "aws_iam_policy" "ecr_push" {
  name = "${var.role_name}-ecr-push"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
          "ecr:ListImages",
          "ecr:DescribeRepositories",
        ]
        Resource = var.ecr_repository_arn
      }
    ]
  })
}

# ── EKS deploy policy (helm upgrade via kubeconfig) ───────────────────────────

resource "aws_iam_policy" "eks_deploy" {
  name = "${var.role_name}-eks-deploy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:ListClusters",
        "eks:AccessKubernetesApi",
      ]
      Resource = "*"
    }]
  })
}

# ── Secrets Manager policy (deploy workflows seed runtime secrets) ─────────────
# deploy-{dev,stage,prod}.yml push current GHA secret values into the
# circleguard/<env> secrets (created by module.irsa-secrets) before each deploy.
# Scoped to the circleguard/* name prefix — NOT account-wide secret access.

resource "aws_iam_policy" "secrets_seed" {
  name = "${var.role_name}-secrets-seed"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:PutSecretValue",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:*:*:secret:circleguard/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_push" {
  role       = aws_iam_role.gha.name
  policy_arn = aws_iam_policy.ecr_push.arn
}

resource "aws_iam_role_policy_attachment" "eks_deploy" {
  role       = aws_iam_role.gha.name
  policy_arn = aws_iam_policy.eks_deploy.arn
}

resource "aws_iam_role_policy_attachment" "secrets_seed" {
  role       = aws_iam_role.gha.name
  policy_arn = aws_iam_policy.secrets_seed.arn
}
