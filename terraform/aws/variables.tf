variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "cluster_name" {
  type    = string
  default = "circleguard-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_count" {
  type    = number
  default = 2
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 4
}

variable "gha_subject_patterns" {
  description = "GitHub Actions OIDC subject patterns allowed to assume the GHA IAM role."
  type        = list(string)
  default = [
    "repo:RonyOz/microservices-circle-guard-dev:*",
    "repo:RonyOz/microservices-circle-guard-ops:*",
  ]
}
