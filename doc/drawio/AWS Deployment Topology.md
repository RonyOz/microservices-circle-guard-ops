# AWS Deployment Topology — Resource Reference

Resource inventory for `AWS Deployment Topology.drawio`. One row per diagram element: the label as drawn, the underlying AWS resource, a description, and the Terraform source that provisions it. Scope is the runtime/deployment topology only (CI/CD pipeline is a separate view).

- **Account:** 888900520630
- **Region:** us-east-1
- **Cluster:** `circleguard-eks` (Kubernetes 1.30)
- **Terraform root:** `terraform/aws/main.tf`

---

## Account / Global scope

| Diagram element | AWS resource | Description | Terraform source |
|---|---|---|---|
| AWS Cloud — account 888900520630 | Account boundary | Outermost boundary; all resources below live in this account. | — |
| Identity & Access (global) — GitHub OIDC provider + `circleguard-gha-role` | IAM OIDC identity provider + IAM role | GitHub Actions assumes `circleguard-gha-role` via OIDC (no static keys). Role is scoped to ECR push + EKS deploy + Secrets Manager seed on `circleguard/*`; cannot create/destroy infra. | `modules/github-oidc/` (`role_name = "circleguard-gha-role"`) |

## Region (us-east-1) — services outside the VPC

| Diagram element | AWS resource | Description | Terraform source |
|---|---|---|---|
| Amazon ECR — `circleguard (immutable)` | ECR repository | Single repository for all service images; the service is encoded in the tag (`<service>-sha-<commit7>`). Immutable tags prevent overwrite. | `modules/ecr/` (`repository_name = "circleguard"`) |
| Amazon S3 — `circleguard-tfstate` | S3 bucket | Terraform remote state backend with S3-native locking (`use_lockfile=true`). Written by local `terraform apply`, not CI. Bucket is not Terraform-managed so it survives a `destroy`. | `terraform/aws/main.tf` `backend "s3"`; created by `scripts/init-s3-backend.sh` |
| Secrets Manager — `runtime via IRSA` | AWS Secrets Manager | Holds long-lived runtime secrets (DB credentials, JWT). Pods read them through External Secrets Operator using IRSA. | `modules/irsa-secrets/` |

## VPC — `circleguard-vpc` (10.0.0.0/16)

| Diagram element | AWS resource | Description | Terraform source |
|---|---|---|---|
| VPC `circleguard-vpc` · 10.0.0.0/16 | `aws_vpc` | Network boundary spanning two AZs. | `modules/vpc/main.tf` (`vpc_cidr = "10.0.0.0/16"`) |
| Internet Gateway — `circleguard-vpc-igw` | `aws_internet_gateway` | Ingress/egress to the public internet for public subnets. | `modules/vpc/main.tf` `aws_internet_gateway.this` |
| NAT Gateway — `single-AZ egress` | `aws_nat_gateway` + `aws_eip` | Single NAT in the AZ-a public subnet; provides outbound internet for both private subnets (cost optimization over one-NAT-per-AZ). | `modules/vpc/main.tf` `aws_nat_gateway.this` (subnet `public[0]`) |
| Public subnet 10.0.0.0/24 (AZ-a) | `aws_subnet` (public) | `map_public_ip_on_launch=true`; default route → IGW. Hosts NAT + ALB node. | `modules/vpc/main.tf` `aws_subnet.public[0]` |
| Public subnet 10.0.1.0/24 (AZ-b) | `aws_subnet` (public) | Second public subnet (ALB requires ≥2 AZs); default route → IGW. | `modules/vpc/main.tf` `aws_subnet.public[1]` |
| Private subnet 10.0.10.0/24 (AZ-a) | `aws_subnet` (private) | Worker nodes; default route → NAT. | `modules/vpc/main.tf` `aws_subnet.private[0]` |
| Private subnet 10.0.11.0/24 (AZ-b) | `aws_subnet` (private) | Worker nodes; default route → NAT (cross-AZ to AZ-a NAT). | `modules/vpc/main.tf` `aws_subnet.private[1]` |
| `route → IGW` (public) | `aws_route` + `aws_route_table_association` | Public route table: `0.0.0.0/0` → IGW. | `modules/vpc/main.tf` `aws_route.public_internet` |
| `egress 0.0.0.0/0` (private) | `aws_route` + `aws_route_table_association` | Private route table: `0.0.0.0/0` → NAT. | `modules/vpc/main.tf` `aws_route.private_nat` |

## Compute — EKS

| Diagram element | AWS resource | Description | Terraform source |
|---|---|---|---|
| EKS `circleguard-eks` — control plane (AWS-managed) | `aws_eks_cluster` | Managed Kubernetes 1.30 control plane; spans both AZs. Environments dev/stage/production are namespaces in this single cluster. | `modules/eks-cluster/main.tf` |
| Managed node group `circleguard-eks-default` | `aws_eks_node_group` | Worker nodes in both private subnets. `m7i-flex.large`, desired 2 / min 1 / max 4. `desired_size` ignored on drift (HPA/manual scaling). | `modules/eks-cluster/main.tf` `aws_eks_node_group.default` |
| EC2 node (`m7i-flex.large`) ×2 | EC2 instances (managed by node group) | One node per AZ. `m7i-flex.large` chosen for free-tier eligibility + 8 GiB/node. | `terraform/aws/variables.tf` (`node_instance_types`, counts) |
| Pods (services + data-plane StatefulSets) | Kubernetes workloads | Application services + data plane run as pods across the nodes. Namespaces dev/stage/production are logical, not network boundaries. | Helm charts: `services/<name>/chart/`, `infrastructure/chart/` |

## Networking / Ingress

| Diagram element | AWS resource | Description | Terraform source |
|---|---|---|---|
| Application Load Balancer — `LB Controller v2.8 · ingressClassName` | `aws_lb` (provisioned by AWS Load Balancer Controller) | Public-facing ALB across both public subnets. Created from Kubernetes Ingress via `spec.ingressClassName` (migrated off the deprecated annotation). Routes to `gateway-service`. | K8s Ingress: `services/gateway-service/chart/templates/ingress.yaml` |

## Storage / Secrets (cluster add-ons)

| Diagram element | AWS resource | Description | Terraform source |
|---|---|---|---|
| EBS gp3 — `PVCs (CSI driver)` | `aws_eks_addon` `aws-ebs-csi-driver` + IRSA role | Provides `gp3` PersistentVolumes for StatefulSets. CSI controller authenticates via IRSA (`ebs-csi-controller-sa`). | `modules/eks-cluster/main.tf` `aws_eks_addon.ebs_csi`, `aws_iam_role.ebs_csi` |
| External Secrets Operator (in `ESO · IRSA → secret`) | ESO + ClusterSecretStore | Syncs AWS Secrets Manager secrets into Kubernetes Secrets via IRSA; pods consume them with `envFrom.secretRef`. | `modules/irsa-secrets/`; `bootstrap-eso.yml`; `infrastructure/chart/` |

---

## Data plane (StatefulSets on EKS, EBS-backed)

Run as pods inside the cluster (not AWS managed services); backed by EBS gp3 PVCs.

| Component | Role |
|---|---|
| PostgreSQL | Relational store (auth, identity vault, form, dashboard) |
| Neo4j | Graph store for exposure-circle traversal (promotion, dashboard) |
| Kafka | Event bus for health-status promotion cascade |
| Zookeeper | Kafka coordination |
| Redis | QR token cache (gateway) |
| OpenLDAP | Directory for auth |
| MailHog | SMTP capture (non-production) |

---

## Request & control flow (diagram step badges)

| Step | Flow | Line style |
|---|---|---|
| 1 | Client → ALB over HTTPS (TLS) via IGW | solid |
| 2 | ALB → `gateway-service` pods on worker nodes (both AZ) | solid |
| 3 | Worker nodes → ECR: pull images | dashed |
| 4 | ESO on nodes → Secrets Manager via IRSA | dashed |
| 5 | Private subnets → NAT (AZ-a) → IGW: egress `0.0.0.0/0` | dashed |
