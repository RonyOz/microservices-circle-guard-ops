output "cluster_id" {
  value = digitalocean_kubernetes_cluster.cluster.id
}

output "cluster_endpoint" {
  value = digitalocean_kubernetes_cluster.cluster.endpoint
}

output "registry_endpoint" {
  value = "${digitalocean_container_registry.registry.endpoint}"
}

output "registry_name" {
  value = digitalocean_container_registry.registry.name
}
