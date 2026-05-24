variable "role_name" {
  type    = string
  default = "circleguard-gha-role"
}

variable "subject_patterns" {
  description = "GHA subject claim patterns. Use repo:<owner>/<repo>:* for full repo access or :ref:refs/heads/main for branch-scoped."
  type        = list(string)
  default = [
    "repo:RonyOz/microservices-circle-guard-dev:*",
    "repo:RonyOz/microservices-circle-guard-ops:*",
  ]
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the GHA role may push to."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
