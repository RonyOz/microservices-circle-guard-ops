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
  # Multiple equivalent types (2 vCPU / 8 GB) so SPOT can pick the deepest
  # capacity pool and reduce interruption risk.
  type    = list(string)
  default = ["m7i-flex.large", "m6i.large", "m5.large"]
}

variable "node_desired_count" {
  type    = number
  default = 2
}

variable "node_min_count" {
  # 0 allows scale-to-zero (scripts/scale-down.sh --zero) without Terraform drift.
  type    = number
  default = 0
}

variable "node_max_count" {
  type    = number
  default = 4
}

variable "node_capacity_type" {
  description = "Capacity type for the EKS node group: SPOT (~70% cheaper, interruptible — fine for an academic cluster) or ON_DEMAND. Changing this replaces the node group (~10 min downtime)."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_capacity_type)
    error_message = "node_capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "gha_subject_patterns" {
  description = "GitHub Actions OIDC subject patterns allowed to assume the GHA IAM role."
  type        = list(string)
  default = [
    "repo:RonyOz/microservices-circle-guard-dev:*",
    "repo:RonyOz/microservices-circle-guard-ops:*",
  ]
}
