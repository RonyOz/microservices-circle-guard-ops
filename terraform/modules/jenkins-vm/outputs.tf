output "droplet_ip" {
  value = digitalocean_droplet.jenkins.ipv4_address
}

output "reserved_ip" {
  description = "Stable floating IP. Use this for GitHub webhooks and DNS."
  value       = digitalocean_reserved_ip.jenkins.ip_address
}

output "droplet_id" {
  description = "Use this ID to power on/off: doctl compute droplet-action power-off --droplet-id <id>"
  value       = digitalocean_droplet.jenkins.id
}
