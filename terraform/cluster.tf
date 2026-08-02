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
    # PREFIX DELEGATION. Without it the CNI hands out individual secondary IPs, so max-pods is
    # ENI-limited: every 1-vCPU m*.medium the NodePool can pick tops out at 8 pods, and roughly
    # six of those are the platform's own DaemonSets. Prefix delegation assigns /28 blocks
    # instead, taking that same instance to 98.
    #
    # ORDER MATTERS, and getting it wrong caused the 2026-08-02 outage. This setting only takes
    # effect on nodes created AFTER it applies (max-pods is fixed at kubelet bootstrap), and
    # Karpenter does NOT inspect the CNI to discover it -- confirmed in Karpenter's own
    # troubleshooting guide, which pairs "enable prefix delegation" with "set maxPods". So the
    # EC2NodeClass carries an explicit kubelet.maxPods. Apply in this order, no shortcuts:
    #   1. apply THIS (prefix delegation on the addon)
    #   2. verify on the live DaemonSet -- the addon reporting ACTIVE is not sufficient proof:
    #        kubectl get ds aws-node -n kube-system \
    #          -o jsonpath='{.spec.template.spec.containers[0].env}' | grep PREFIX_DELEGATION
    #   3. only then raise kubelet.maxPods in gitops/apps/karpenter/ec2nodeclass.yaml
    #   4. recycle nodes one at a time
    # Reversing 2 and 3 makes kubelet advertise capacity the CNI cannot back; the scheduler
    # fills the node and every pod past the real IP limit hangs in ContainerCreating with
    # "failed to assign an IP address to container".
    #
    # THE ADDRESS OF THIS ADDON IS NOT WHAT YOU EXPECT. Because before_compute = true, the
    # module declares it in a SEPARATE resource block, so its state address is
    #   module.eks.aws_eks_addon.before_compute["vpc-cni"]      <-- correct
    #   module.eks.aws_eks_addon.this["vpc-cni"]                <-- does NOT exist
    # Confirm before targeting anything: terraform state list | grep addon
    #
    # That mistake is what caused the 2026-08-02 outage, and the way it failed is worth
    # understanding. The apply used -target=...aws_eks_addon.this["vpc-cni"]. No such instance
    # exists, so prefix delegation was never planned -- but the run was NOT a no-op. -target
    # is not a scalpel: it pulls in the target's DEPENDENCIES, and the after-compute
    # aws_eks_addon.this block depends on the managed node group. The node group had an
    # unrelated pending AMI bump, so that rode along and rolled the fleet. Terraform printed
    # "Apply complete! Resources: 0 added, 1 changed, 0 destroyed" -- the 1 was the node group,
    # not the addon. The roll evicted ArgoCD and cert-manager onto a node whose kubelet had
    # already been told maxPods=44 by a CNI that was still ENI-limited to 8.
    #
    # Two habits prevent a repeat:
    #   1. Plan into a file and read WHICH resources it lists, then apply that exact file:
    #        terraform plan -target='module.eks.aws_eks_addon.before_compute["vpc-cni"]' \
    #          -out=cni.tfplan
    #        terraform apply cni.tfplan
    #      "Apply complete!" says nothing about WHICH resource changed. The plan file does.
    #   2. Verify the effect on the live DaemonSet, not the addon's ACTIVE status (step 2 above).
    #
    # WARM_PREFIX_TARGET=1 keeps exactly one spare /28 per node: enough to absorb a burst
    # without reserving a second block on every node in the fleet.
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
