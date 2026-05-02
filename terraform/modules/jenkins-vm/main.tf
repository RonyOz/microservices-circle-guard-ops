terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.39"
    }
  }
}

# Droplet runs Jenkins + Docker. JENKINS_HOME is on a separate volume so the
# droplet itself is treated as ephemeral — destroy when not working, recreate
# when resuming. State persists across recreations.
resource "digitalocean_droplet" "jenkins" {
  name       = "circleguard-jenkins"
  region     = var.do_region
  size       = var.droplet_size
  image      = "ubuntu-22-04-x64"
  ssh_keys   = var.ssh_key_ids
  vpc_uuid   = var.vpc_uuid
  volume_ids = [var.volume_id]

  user_data = <<-CLOUD_INIT
    #!/bin/bash
    set -euo pipefail

    apt-get update -y
    apt-get install -y curl gnupg lsb-release ca-certificates

    # ---- Mount persistent volume at /var/lib/jenkins BEFORE installing Jenkins ----
    DEVICE=/dev/disk/by-id/scsi-0DO_Volume_${var.volume_name}
    for i in $(seq 1 60); do
      [ -b "$DEVICE" ] && break
      sleep 2
    done
    if ! blkid "$DEVICE" >/dev/null 2>&1; then
      mkfs.ext4 -F "$DEVICE"
    fi
    mkdir -p /var/lib/jenkins
    grep -q "$DEVICE" /etc/fstab || \
      echo "$DEVICE /var/lib/jenkins ext4 defaults,nofail,discard 0 2" >> /etc/fstab
    mount /var/lib/jenkins

    # ---- Docker ----
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io

    # ---- Java 21 (required by Jenkins LTS) ----
    apt-get install -y openjdk-21-jdk-headless

    # ---- Jenkins LTS ----
    # Note: the 2023 key URL (per official docs) ships an expired key.
    # The 2026 key is the current one as of writing (valid through 2028-12-21).
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
      | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/" \
      > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins

    # Re-own JENKINS_HOME — on droplet recreation the jenkins UID may differ
    # from the one that originally wrote files to the volume.
    chown -R jenkins:jenkins /var/lib/jenkins

    # apt-get install jenkins auto-starts the service. Stop it before usermod
    # so the process picks up the docker group on next start.
    systemctl stop jenkins
    usermod -aG docker jenkins

    # ---- kubectl ----
    curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl

    # ---- Helm ----
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # ---- doctl ----
    curl -fsSL https://github.com/digitalocean/doctl/releases/download/v1.110.0/doctl-1.110.0-linux-amd64.tar.gz \
      | tar -xz -C /tmp
    mv /tmp/doctl /usr/local/bin/

    systemctl enable --now jenkins
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
