# Input variables for the platform layer.
# Every knob that trades cost vs. production-HA is surfaced here so the "cheap portfolio" and
# "production-grade" postures differ only by tfvars — no code changes.

variable "region" {
  description = "AWS region for the cluster and all regional resources."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for the cluster and tagged resources."
  type        = string
  default     = "eks-golden"
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control-plane Kubernetes version. Keep this CURRENT — letting it drift into EKS
    extended support raises the control plane from ~$73/mo to ~$438/mo (the "extended support trap").
  EOT
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to span. 3 for HA; the module derives subnets from this."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = <<-EOT
    Cost lever. true = one shared NAT GW (~$32/mo, 1-AZ SPOF) for a portfolio cluster.
    Flip to false for one NAT per AZ (~$97/mo, full HA) as the "production" posture.
  EOT
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = <<-EOT
    true exposes the EKS API endpoint publicly so you can kubectl from anywhere (portfolio).
    Set false + reach the API over SSM/bastion for the hardened production posture.
  EOT
  type        = bool
  default     = true
}

variable "bootstrap_instance_types" {
  description = "Instance types for the tiny managed node group that hosts Karpenter + core controllers."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "argocd_chart_version" {
  description = "Pinned argo-cd Helm chart version installed at bootstrap."
  type        = string
  default     = "7.7.0"
}

variable "git_repo_url" {
  description = "HTTPS URL of THIS repo; the root app-of-apps points ArgoCD back here."
  type        = string
  default     = "https://github.com/c0debyeric/eks-golden-platform.git"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "eks-golden-platform"
    ManagedBy = "terraform"
  }
}
