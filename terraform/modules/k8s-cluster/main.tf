terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.39"
    }
  }
}

# Resolve the latest patch release of the configured minor version.
# Avoids hardcoded slugs like "1.30.1-do.0" that DO retires over time.
data "digitalocean_kubernetes_versions" "current" {
  version_prefix = var.k8s_version_prefix
}

# DOCR: free tier is one repo, 500 MB. Region is separate from do_region
# because DOCR only runs in nyc3/sfo3/ams3/sgp1/fra1/syd1.
resource "digitalocean_container_registry" "registry" {
  name                   = var.registry_name
  subscription_tier_slug = "starter"
  region                 = var.registry_region
}

resource "digitalocean_container_registry_docker_credentials" "registry_creds" {
  registry_name = digitalocean_container_registry.registry.name
  write         = false
}

resource "digitalocean_kubernetes_cluster" "cluster" {
  name     = var.cluster_name
  region   = var.do_region
  version  = data.digitalocean_kubernetes_versions.current.latest_version
  vpc_uuid = var.vpc_uuid

  node_pool {
    name       = "default-pool"
    size       = var.node_size
    node_count = var.node_count

    labels = {
      "circleguard/pool" = "default"
    }
  }
}
