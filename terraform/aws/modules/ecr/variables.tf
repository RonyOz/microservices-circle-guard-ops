variable "repository_name" {
  type    = string
  default = "circleguard"
}

variable "max_image_count" {
  description = "Lifecycle policy: expire images beyond this count."
  type        = number
  default     = 20
}

variable "tags" {
  type    = map(string)
  default = {}
}
