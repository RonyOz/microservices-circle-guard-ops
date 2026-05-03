variable "do_token" {
  description = "Digital Ocean API token. Set via TF_VAR_do_token env var — never hardcode."
  type        = string
  sensitive   = true
}

variable "do_region" {
  description = "DO region slug. nyc1, sfo3, ams3, fra1, etc."
  type        = string
  default     = "nyc1"
}

variable "ssh_key_ids" {
  description = "List of DO SSH key fingerprints or IDs to inject into the Jenkins Droplet."
  type        = list(string)
}

variable "jenkins_droplet_size" {
  description = "Droplet size for Jenkins VM. s-1vcpu-2gb gives Jenkins + Docker breathing room."
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "jenkins_volume_size" {
  description = "Size in GB of the persistent volume mounted at /var/lib/jenkins. 10 GB is plenty for jobs + plugins."
  type        = number
  default     = 10
}

variable "cluster_name" {
  description = "Name for the DOKS cluster."
  type        = string
  default     = "circleguard-k8s"
}

variable "node_size" {
  description = "Node pool size. s-4vcpu-8gb is the practical minimum for 6 services + infra."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "node_count" {
  description = "Number of nodes. 1 is enough for the taller."
  type        = number
  default     = 1
}

variable "registry_name" {
  description = "Name for the DO Container Registry. Must be globally unique."
  type        = string
  default     = "circleguard"
}

variable "registry_region" {
  description = "DOCR region. DOCR only supports: nyc3, sfo3, ams3, sgp1, fra1, syd1."
  type        = string
  default     = "nyc3"
}

variable "registry_subscription_tier" {
  description = "DOCR subscription tier: starter (500MB free), basic ($5/mo 5GB), professional ($20/mo 100GB)."
  type        = string
  default     = "basic"
}
