variable "do_region" {
  type = string
}

variable "droplet_size" {
  type    = string
  default = "s-1vcpu-2gb"
}

variable "ssh_key_ids" {
  type = list(string)
}
