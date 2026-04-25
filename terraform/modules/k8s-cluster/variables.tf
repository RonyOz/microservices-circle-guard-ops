variable "do_region" { type = string }
variable "cluster_name" { type = string }
variable "node_size" { type = string }
variable "node_count" { type = number }
variable "registry_name" { type = string }
variable "registry_region" { type = string }
variable "vpc_uuid" { type = string }

variable "k8s_version_prefix" {
  description = "Kubernetes minor-version prefix to pin to. The provider resolves this to the latest matching slug via the digitalocean_kubernetes_versions data source."
  type        = string
  default     = "1.33."
}
