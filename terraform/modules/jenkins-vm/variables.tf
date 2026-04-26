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

variable "vpc_uuid" {
  description = "UUID of the VPC where the Jenkins droplet is placed."
  type        = string
}

variable "volume_id" {
  description = "ID of the persistent DO volume to attach. Mounted at /var/lib/jenkins."
  type        = string
}

variable "volume_name" {
  description = "Name of the persistent DO volume. Used to compute the device path /dev/disk/by-id/scsi-0DO_Volume_<name>."
  type        = string
}
