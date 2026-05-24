# DEPRECATED — k8s-cluster Terraform module

**Deprecated:** 2026-05-23  
**Reason:** Platform migrated from DigitalOcean DOKS to AWS EKS.

This module provisioned a DigitalOcean Kubernetes Service (DOKS) cluster with a DOCR registry and three namespaces (dev / stage / production).

**Replacement:** See `terraform/aws/modules/eks-cluster/` (in progress) — provisions an AWS EKS cluster backed by managed node groups. Container registry moves to ECR (`terraform/aws/modules/ecr/`).

Do not apply this module. It is retained for historical reference only.
