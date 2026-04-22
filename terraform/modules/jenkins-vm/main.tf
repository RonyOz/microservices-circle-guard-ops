terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.39"
    }
  }
}

# ---------------------------------------------------------------
# Droplet: Jenkins + Docker
#
# Lifecycle: power off when not working, power on to resume.
#   doctl compute droplet-action power-off --droplet-id <id>
#   doctl compute droplet-action power-on  --droplet-id <id>
#
# State (Jenkins config, jobs, plugins) lives on the disk and
# survives power cycles. Only a `terraform destroy` removes it.
# ---------------------------------------------------------------
resource "digitalocean_droplet" "jenkins" {
  name     = "circleguard-jenkins"
  region   = var.do_region
  size     = var.droplet_size
  image    = "ubuntu-22-04-x64"
  ssh_keys = var.ssh_key_ids

  # cloud-init: install Docker + Java 21 on first boot (~3 min)
  user_data = <<-CLOUD_INIT
    #!/bin/bash
    set -e

    # System update
    apt-get update -y
    apt-get install -y curl gnupg lsb-release ca-certificates

    # Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) \
      signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io

    # Java 21 (required by Jenkins LTS)
    apt-get install -y openjdk-21-jdk-headless

    # Jenkins LTS
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
      | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
      https://pkg.jenkins.io/debian-stable binary/" \
      > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins

    # Allow jenkins user to run Docker without sudo
    usermod -aG docker jenkins

    # kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -Ls \
      https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

    # Helm
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
      | bash

    # doctl (to fetch kubeconfig from DOKS)
    curl -sL https://github.com/digitalocean/doctl/releases/download/v1.110.0/doctl-1.110.0-linux-amd64.tar.gz \
      | tar -xzv
    mv doctl /usr/local/bin

    systemctl enable jenkins
    systemctl start jenkins
  CLOUD_INIT

  tags = ["circleguard", "jenkins", "ci"]
}

# Firewall: only allow SSH + Jenkins UI + outbound
resource "digitalocean_firewall" "jenkins" {
  name        = "circleguard-jenkins-fw"
  droplet_ids = [digitalocean_droplet.jenkins.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "8080"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
