terraform {
  required_version = ">= 1.6.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.39"
    }
  }

  # Uncomment when you have a DO Space for remote state:
  # backend "s3" {
  #   endpoint                    = "https://nyc3.digitaloceanspaces.com"
  #   bucket                      = "circleguard-tfstate"
  #   key                         = "circleguard/terraform.tfstate"
  #   region                      = "us-east-1"   # required by s3 backend, value ignored by DO
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }
}

provider "digitalocean" {
  token = var.do_token
}

# Shared VPC for private networking between Jenkins and the DOKS cluster.
# Creating it explicitly avoids the "Failed to resolve VPC" error on regions
# where DO hasn't auto-provisioned a default VPC for the account yet.
resource "digitalocean_vpc" "main" {
  name     = "circleguard-vpc"
  region   = var.do_region
  ip_range = "10.20.0.0/16"
}

module "jenkins_vm" {
  source = "./modules/jenkins-vm"

  do_region    = var.do_region
  ssh_key_ids  = var.ssh_key_ids
  droplet_size = var.jenkins_droplet_size
  vpc_uuid     = digitalocean_vpc.main.id
}

module "k8s_cluster" {
  source = "./modules/k8s-cluster"

  do_region       = var.do_region
  cluster_name    = var.cluster_name
  node_size       = var.node_size
  node_count      = var.node_count
  registry_name   = var.registry_name
  registry_region = var.registry_region
  vpc_uuid        = digitalocean_vpc.main.id
}
