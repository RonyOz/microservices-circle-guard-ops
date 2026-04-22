terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.39"
    }
  }
}

# ---------------------------------------------------------------
# Container Registry (free tier: 1 repo, 500 MB)
# ---------------------------------------------------------------
resource "digitalocean_container_registry" "registry" {
  name                   = var.registry_name
  subscription_tier_slug = "free"
  region                 = var.do_region
}

# Grant the cluster read access to the registry
resource "digitalocean_container_registry_docker_credentials" "registry_creds" {
  registry_name = digitalocean_container_registry.registry.name
  write         = false
}

# ---------------------------------------------------------------
# DOKS cluster
# ---------------------------------------------------------------
resource "digitalocean_kubernetes_cluster" "cluster" {
  name    = var.cluster_name
  region  = var.do_region
  version = "1.30.1-do.0"  # pin to a stable version; update deliberately

  node_pool {
    name       = "default-pool"
    size       = var.node_size
    node_count = var.node_count

    labels = {
      "circleguard/pool" = "default"
    }
  }
}

# ---------------------------------------------------------------
# Kubernetes namespaces: dev / stage / production
# Bulkhead pattern — full isolation between environments
# ---------------------------------------------------------------
resource "digitalocean_kubernetes_node_pool" "cluster_ref" {
  # This resource is only here to create a dependency anchor.
  # Namespaces are created via kubectl after kubeconfig is fetched.
  # See scripts/bootstrap-namespaces.sh
  cluster_id = digitalocean_kubernetes_cluster.cluster.id
  name       = "default-pool"
  size       = var.node_size
  node_count = var.node_count

  lifecycle {
    ignore_changes = [node_count]
  }
}
