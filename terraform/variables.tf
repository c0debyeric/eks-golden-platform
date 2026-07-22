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
  description = <<-EOT
    CIDR block for the VPC. Chosen to NOT overlap other VPCs in the sandbox account:
    ExampleVPC (10.0.0.0/16), example-vpc-b (10.0.0.0/24), example-vpc-c (10.0.0.0/24).
    10.20.0.0/16 is clear of all three, with room for 3x /20 private + 3x /24 public +
    3x /24 database subnets (see the subnet-CIDR derivation in main.tf locals).
  EOT
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to span. 3 for HA; the module derives subnets from this."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = <<-EOT
    NAT gateway HA vs cost lever. Default false = one NAT per AZ (~$97/mo, full HA) —
    the RECOMMENDED production posture: an AZ's NAT failure only affects that AZ's private
    egress, and there's no cross-AZ NAT data hop. Set true in tfvars for one shared NAT
    (~$32/mo, single-AZ SPOF for all private egress) when running a throwaway demo cluster.
  EOT
  type        = bool
  default     = false
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

variable "create_rds" {
  description = <<-EOT
    Toggle the demonstration RDS PostgreSQL deployment (Multi-AZ primary + 2 read replicas)
    into the isolated database subnet tier. Default false so the base platform stays cheap
    and fast to stand up; set true in tfvars to provision the ~4-instance database topology
    (~$50/mo on db.t4g.micro). See rds.tf and docs/NETWORK-ARCHITECTURE.md.
  EOT
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "Instance class for the RDS primary and its read replicas. db.t4g.micro = cheapest Graviton."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_engine_version" {
  description = "PostgreSQL engine version for the RDS demo. Keep current for security patches."
  type        = string
  default     = "18.4"
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

variable "ci_role_arn" {
  description = <<-EOT
    IAM role ARN of the CI runner (GitHub Actions OIDC role). When set, the EKS module
    grants it a read-only EKS access entry (AmazonEKSViewPolicy) so `terraform plan` in CI
    can refresh in-cluster resources (helm_release, kubectl_manifest) instead of failing
    with 'server has asked for the client to provide credentials'. Empty = no CI access entry.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "eks-golden-platform"
    ManagedBy = "terraform"
  }
}
