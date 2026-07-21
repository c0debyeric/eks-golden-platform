# Cluster layer: the EKS control plane, AWS-managed add-ons, and the tiny bootstrap
# node group that exists only to host Karpenter + core controllers. Actual workload
# capacity is provisioned by Karpenter (see compute.tf), not by a static node group.

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
