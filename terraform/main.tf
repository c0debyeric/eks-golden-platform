# Platform layer: VPC + EKS + Karpenter IAM + managed add-ons.
# This file provisions the DISPOSABLE cluster. The application layer lives in Git and is
# reconciled by ArgoCD (see argocd.tf) — Terraform never manages workloads directly.

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Subnet CIDRs derived from the VPC CIDR: /20 private + /24 public per AZ.
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 48)]
}

########################################
# VPC
########################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 6.0"

  name = "${var.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway # cost lever (see variables.tf)
  enable_dns_hostnames = true

  # S3 gateway endpoint is free and keeps Loki->S3 chunk traffic off the (metered) NAT.
  # Managed here as part of the base VPC.

  # Subnet tags REQUIRED for controllers to discover where to place load balancers and nodes.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1" # public ELBs land here
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"      # internal ELBs
    "karpenter.sh/discovery"          = var.name # Karpenter EC2NodeClass subnet discovery
  }

  tags = var.tags
}

resource "aws_vpc_endpoint" "s3" {
  # Free gateway endpoint: Loki chunk PUT/GET to S3 bypasses NAT data-processing charges.
  vpc_id          = module.vpc.vpc_id
  service_name    = "com.amazonaws.${var.region}.s3"
  route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags            = var.tags
}

########################################
# EKS cluster
########################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = ">= 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = var.endpoint_public_access
  enable_cluster_creator_admin_permissions = true # Access Entries: add caller as admin

  # KMS envelope encryption of Kubernetes secrets at rest.
  encryption_config = {
    resources = ["secrets"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # nodes run in private subnets

  # AWS-owned cluster plumbing as managed add-ons; the module orders CNI before compute.
  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true } # ready before nodes join
    aws-ebs-csi-driver     = {}                        # PVCs for Prometheus/Loki/Grafana
    eks-pod-identity-agent = {}                        # REQUIRED for Pod Identity
    metrics-server         = {}                        # HPA + kubectl top
  }

  # A tiny managed node group ONLY to host Karpenter + core controllers.
  # Karpenter then provisions all workload capacity (spot-first). Solves the chicken-and-egg.
  eks_managed_node_groups = {
    bootstrap = {
      instance_types = var.bootstrap_instance_types
      min_size       = 2
      max_size       = 3
      desired_size   = 2

      # IMDSv2 required + hop limit 1: a compromised pod can't reach IMDS to steal the node role.
      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  # Tag the cluster security group so Karpenter-launched nodes attach to it.
  node_security_group_tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.name
  })

  tags = var.tags
}

########################################
# Karpenter (IAM, SQS interruption queue, instance profile) — controller installed via Helm/ArgoCD
########################################
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = ">= 21.0"

  cluster_name = module.eks.cluster_name

  # Pod Identity is the karpenter sub-module's default credential mechanism (no IRSA/OIDC).
  # This creates the association between the controller SA and the generated IAM role.
  create_pod_identity_association = true

  # Least-priv node role; attach the SSM policy so nodes are manageable without SSH.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}
