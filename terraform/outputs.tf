output "jenkins_ip" {
  description = "Public IP of the Jenkins Droplet. Use this to configure GitHub webhook and SSH."
  value       = module.jenkins_vm.droplet_ip
}

output "jenkins_url" {
  description = "Jenkins web UI URL (port 8080)."
  value       = "http://${module.jenkins_vm.droplet_ip}:8080"
}

output "k8s_cluster_id" {
  description = "DOKS cluster ID."
  value       = module.k8s_cluster.cluster_id
}

output "k8s_endpoint" {
  description = "K8s API endpoint."
  value       = module.k8s_cluster.cluster_endpoint
}

output "registry_endpoint" {
  description = "DOCR endpoint. Tag images as <registry_endpoint>/<image>:<tag>."
  value       = module.k8s_cluster.registry_endpoint
}

output "kubeconfig_command" {
  description = "Command to fetch kubeconfig locally after cluster is ready."
  value       = "doctl kubernetes cluster kubeconfig save ${var.cluster_name}"
}
