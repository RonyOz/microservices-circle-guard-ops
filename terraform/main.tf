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

# ---------------------------------------------------------------
# Module: Jenkins VM  (power on/off independently)
# Deploy:  terraform apply -target=module.jenkins_vm
# Destroy: terraform destroy -target=module.jenkins_vm
# ---------------------------------------------------------------
module "jenkins_vm" {
  source = "./modules/jenkins-vm"

  do_region    = var.do_region
  ssh_key_ids  = var.ssh_key_ids
  droplet_size = var.jenkins_droplet_size
}

# ---------------------------------------------------------------
# Module: K8s cluster  (longer-lived, shared by all environments)
# Deploy:  terraform apply -target=module.k8s_cluster
# ---------------------------------------------------------------
module "k8s_cluster" {
  source = "./modules/k8s-cluster"

  do_region     = var.do_region
  cluster_name  = var.cluster_name
  node_size     = var.node_size
  node_count    = var.node_count
  registry_name = var.registry_name
}
