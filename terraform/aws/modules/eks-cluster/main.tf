terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ── IAM: control plane ────────────────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── IAM: worker nodes ─────────────────────────────────────────────────────────

resource "aws_iam_role" "nodes" {
  name = "${var.cluster_name}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.nodes.name
  policy_arn = each.value
}

# ── EKS cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # Access Entries API is how IAM principals get Kubernetes RBAC identities.
  # bootstrap_cluster_creator_admin_permissions keeps the local admin that runs
  # bootstrap.sh as cluster-admin (so local kubectl works without extra wiring).
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ── Access entry: GitHub Actions deploy role → Kubernetes RBAC ─────────────────
# The gha role authenticates to AWS via OIDC, but kubectl/helm talk to the K8s
# API server, which needs this explicit IAM→RBAC binding. Without it, deploy-*
# and bootstrap-eso fail with Unauthorized. ClusterAdmin scope: bootstrap-eso
# creates cluster-scoped CRDs (ClusterSecretStore) that namespaced admin can't.

resource "aws_eks_access_entry" "deploy_role" {
  count         = var.deploy_role_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.deploy_role_arn
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "deploy_role_admin" {
  count         = var.deploy_role_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.deploy_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.deploy_role]
}

# ── OIDC provider (enables IRSA) ─────────────────────────────────────────────

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  tags            = var.tags
}

# ── Managed node group ────────────────────────────────────────────────────────

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-default"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_count
    max_size     = var.node_max_count
    min_size     = var.node_min_count
  }

  update_config {
    max_unavailable = 1
  }

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.nodes]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
