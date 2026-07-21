# IAM roles for workloads that touch AWS, wired via EKS Pod Identity associations.
# Pod Identity (not IRSA) so the associations are cluster-agnostic and survive teardown/rebuild.

########################################
# External Secrets Operator -> AWS Secrets Manager (read-only)
########################################
data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"] # Pod Identity trust principal
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "eso_read" {
  statement {
    # Least-priv: read only secrets under this project's path prefix.
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.region}:*:secret:${var.name}/*"]
  }
}

resource "aws_iam_role_policy" "eso_read" {
  name   = "read-project-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.eso_read.json
}

# Associate the role with the ESO service account. ESO is deployed by ArgoCD (gitops/), but the
# association can exist ahead of the SA — Pod Identity resolves it when the pod starts.
resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

########################################
# AWS Load Balancer Controller -> ELB/EC2 (via Pod Identity)
########################################
data "aws_iam_policy_document" "alb_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume.json
  tags               = var.tags
}

# The controller's IAM policy is large and versioned upstream; fetch the official JSON at apply
# time rather than vendoring a stale copy. Pinned to a release tag for reproducibility.
data "http" "alb_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.2/docs/install/iam_policy.json"
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "alb-controller"
  role   = aws_iam_role.alb_controller.id
  policy = data.http.alb_iam_policy.response_body
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller.arn
}
