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

# Persistent /var/lib/jenkins. Lives outside the jenkins_vm module so the
# droplet can be destroyed/recreated without losing Jenkins state (jobs,
# plugins, credentials). The volume costs ~$1/month at 10 GB.
#
# To truly clean up: comment out the module reference, or run
#   doctl compute volume delete jenkins-home
resource "digitalocean_volume" "jenkins_home" {
  name                    = "jenkins-home"
  region                  = var.do_region
  size                    = var.jenkins_volume_size
  initial_filesystem_type = "ext4"
  description             = "Persistent JENKINS_HOME — survives droplet destroys."
}

module "jenkins_vm" {
  source = "./modules/jenkins-vm"

  do_region    = var.do_region
  ssh_key_ids  = var.ssh_key_ids
  droplet_size = var.jenkins_droplet_size
  vpc_uuid     = digitalocean_vpc.main.id
  volume_id    = digitalocean_volume.jenkins_home.id
  volume_name  = digitalocean_volume.jenkins_home.name
}

module "k8s_cluster" {
  source = "./modules/k8s-cluster"

  do_region       = var.do_region
  cluster_name    = var.cluster_name
  node_size       = var.node_size
  node_count      = var.node_count
  registry_name   = var.registry_name
  registry_region            = var.registry_region
  registry_subscription_tier = var.registry_subscription_tier
  vpc_uuid                   = digitalocean_vpc.main.id
}
