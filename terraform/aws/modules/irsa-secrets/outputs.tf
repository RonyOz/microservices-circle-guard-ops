output "eso_role_arn" {
  value = aws_iam_role.eso.arn
}

output "secret_arns" {
  value = { for ns, s in aws_secretsmanager_secret.runtime : ns => s.arn }
}
