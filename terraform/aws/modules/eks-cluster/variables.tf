variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "subnet_ids" {
  description = "Private subnet IDs for EKS nodes and control plane ENIs."
  type        = list(string)
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

variable "deploy_role_arn" {
  description = "IAM role ARN (GHA OIDC role) granted ClusterAdmin via an EKS access entry, so CI deploy workflows can run kubectl/helm."
  type        = string
  default     = ""
}

variable "enable_deploy_access" {
  description = "Create the EKS access entry binding deploy_role_arn to ClusterAdmin RBAC."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
