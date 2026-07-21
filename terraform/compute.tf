# Compute layer: Karpenter's AWS-side plumbing (IAM node role, SQS interruption queue,
# instance profile, Pod Identity association). The Karpenter CONTROLLER itself is installed
# via Helm/ArgoCD (gitops/bootstrap/karpenter.yaml) — this only provisions what it needs in AWS.

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = ">= 21.0"

  cluster_name = module.eks.cluster_name

  # Pod Identity is the karpenter sub-module's default credential mechanism (no IRSA/OIDC).
  # This creates the association between the controller SA and the generated IAM role.
  create_pod_identity_association = true

  # Pin a stable, predictable node role name (no random suffix) so the EC2NodeClass
  # manifest (gitops/apps/karpenter/ec2nodeclass.yaml) can reference it by name and the
  # repo stays reproducible from a clean clone.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.name}-karpenter"

  # Least-priv node role; attach the SSM policy so nodes are manageable without SSH.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}
