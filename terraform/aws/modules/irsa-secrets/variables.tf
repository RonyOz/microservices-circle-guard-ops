variable "role_name" {
  type    = string
  default = "circleguard-eso-role"
}

variable "namespaces" {
  type    = list(string)
  default = ["dev", "stage", "production"]
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
