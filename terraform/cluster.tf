# Cluster layer: the EKS control plane, AWS-managed add-ons, and the tiny bootstrap
# node group that exists only to host Karpenter + core controllers. Actual workload
# capacity is provisioned by Karpenter (see compute.tf), not by a static node group.

# Who is actually running Terraform right now. Used ONLY by the guard below.
data "aws_caller_identity" "current" {}

# GUARD: refuse to run as the CI role.
#
# enable_cluster_creator_admin_permissions (below) derives cluster-admin from the caller
# identity AT APPLY TIME. An apply from CI therefore REPLACES the cluster_creator access entry,
# handing cluster-admin to the GitHub Actions OIDC role and REVOKING the human operator's
# kubectl access. That is unrecoverable without a second admin principal.
#
# CI is plan-only today, so this can't happen by accident — but "CI is plan-only" is a
# convention, and conventions get changed by a future PR that adds an apply job. This makes the
# invariant enforceable instead of aspirational.
#
# WHY a lifecycle precondition and NOT a `check` block: a failed `check` assertion is only a
# WARNING — terraform still exits 0 and the apply proceeds. It would politely narrate the
# admin takeover while allowing it. A precondition is a hard ERROR that aborts plan and apply
# (verified: exit 1 vs exit 0). For a guard whose whole job is to STOP something, that
# distinction is the entire point.
#
# terraform_data is a built-in (no provider), so this adds no dependencies.
resource "terraform_data" "apply_identity_guard" {
  # Recorded in state so a change of operator identity is visible in the plan diff.
  input = data.aws_caller_identity.current.arn

  lifecycle {
    precondition {
      # strcontains on the role NAME, because an assumed-role ARN is
      # sts::assumed-role/<name>/<session> and never string-equals the iam::role/<name> ARN in
      # var.ci_role_arn — a naive == would never fire. No-ops when ci_role_arn is unset.
      condition = !(var.ci_role_arn != "" && strcontains(
        data.aws_caller_identity.current.arn,
        reverse(split("/", var.ci_role_arn))[0]
      ))
      error_message = join(" ", [
        "Refusing to run as the CI principal (${data.aws_caller_identity.current.arn}).",
        "enable_cluster_creator_admin_permissions would replace the cluster_creator access entry",
        "and revoke the human operator's cluster-admin. Run as your own IAM principal, or set",
        "enable_cluster_creator_admin_permissions = false and declare admins explicitly in",
        "access_entries first."
      ])
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = ">= 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access = var.endpoint_public_access

  # DANGER — this derives cluster-admin from WHOEVER RUNS `terraform apply`, not from a fixed
  # principal. The module reads the caller identity at apply time and writes it as the
  # "cluster_creator" access entry. Consequences to understand before you apply from anywhere new:
  #
  #   * Applying from a DIFFERENT identity than the original creator REPLACES that entry
  #     (principal_arn forces replacement) and REVOKES the previous admin's kubectl access.
  #   * Applying from CI would therefore hand cluster-admin to the GitHub Actions OIDC role and
  #     lock the human operator out — which is exactly why this repo's CI is plan-only and the
  #     `plan` job is scoped with -target. Never add an `apply` job to CI while this is true.
  #
  # This is safe as-is for a single-operator platform. If this ever becomes a team cluster, set
  # this to false and declare admins EXPLICITLY as access_entries below, so admin identity is
  # reviewable in Git instead of being a side effect of who ran the last apply.
  enable_cluster_creator_admin_permissions = true

  # Grant the CI runner (GitHub Actions OIDC role) a READ-ONLY access entry so `terraform plan`
  # in CI can authenticate to the K8s API and refresh in-cluster resources (helm_release,
  # kubectl_manifest). Without this, CI plan fails: "server has asked for the client to provide
  # credentials". AmazonEKSViewPolicy is read-only — CI can plan but not mutate the cluster.
  # Gated on var.ci_role_arn so a checkout without CI configured still applies cleanly.
  access_entries = var.ci_role_arn == "" ? {} : {
    ci = {
      principal_arn = var.ci_role_arn
      policy_associations = {
        view = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # KMS envelope encryption of Kubernetes secrets at rest.
  encryption_config = {
    resources = ["secrets"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # nodes run in private subnets

  # AWS-owned cluster plumbing as managed add-ons; the module orders CNI before compute.
  addons = {
    coredns    = {}
    kube-proxy = {}
    # before_compute: ready before nodes join.
    #
    # PREFIX DELEGATION: without it, max-pods is derived from ENI IP slots, which is brutal on the
    # small instances this NodePool prefers — an m8g.medium gets max-pods=8. Five platform
    # DaemonSets (CNI, kube-proxy, pod-identity-agent, ebs-csi-node, node-exporter) consume most
    # of that, so the node can host 2-3 workload pods and cannot fit a sixth DaemonSet at all.
    # That is how the OTel logs collector ended up permanently Pending on one node.
    #
    # Prefix delegation assigns /28 prefixes instead of individual IPs, raising the same instance
    # to ~98 pods. NOTE: max-pods is fixed at node bootstrap, so this only affects nodes created
    # AFTER it is applied — existing nodes must be recycled. Karpenter does not read this setting
    # either; its density is set explicitly via kubelet.maxPods in the EC2NodeClass.
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver     = {} # PVCs for Prometheus/Loki/Grafana
    eks-pod-identity-agent = {} # REQUIRED for Pod Identity
    metrics-server         = {} # HPA + kubectl top
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
