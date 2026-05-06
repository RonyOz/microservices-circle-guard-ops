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
  description = "Node pool size. s-4vcpu-8gb is the largest slug DOKS exposes on starter accounts. Larger sizes (s-8vcpu-16gb, m-2vcpu-16gb, etc.) require account upgrade and are not returned by doks-list-options."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "node_count" {
  description = "2 nodes × 8 GB = 16 GB allocatable. Fits one full namespace (infra stack + 7 microservices ~7-8 GB) with headroom for Jenkins-triggered rollouts. With droplet_limit=3 (Jenkins + 2 DOKS nodes), running dev+stage+prod concurrently is not possible — cycle namespaces between deploys."
  type        = number
  default     = 2
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
