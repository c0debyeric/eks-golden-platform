# The IAM role GitHub Actions assumes, plus its trust + permissions policies.

# Reference the EXISTING account-wide GitHub OIDC provider (do not recreate).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}

# --- TRUST POLICY: WHO may assume the role ---
# This is the security-critical part. Two conditions, both mandatory:
#   1. aud (audience) == sts.amazonaws.com  -> the token was minted for AWS STS, not some other service
#   2. sub (subject)  == repo:ORG/REPO:REF  -> ONLY this repo + this ref. StringEquals (exact),
#      never StringLike with a wildcard, or other repos could assume the role.
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals" # EXACT match — the single most important line for security
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:${var.allowed_ref}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "gha-${var.github_repo}"
  description          = "Assumed by GitHub Actions in ${var.github_org}/${var.github_repo} (${var.allowed_ref}) via OIDC."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600 # 1h; CI jobs are short. Raise only if a plan/apply needs longer.

  tags = {
    Project   = "eks-golden-platform"
    ManagedBy = "terraform-bootstrap"
    Purpose   = "github-oidc-ci"
  }
}

# --- PERMISSIONS POLICY: WHAT the role can do ---
# The main module provisions VPC + EKS + IAM + KMS + SQS + S3-state access, which is inherently
# broad. For a portfolio/sandbox account, AdministratorAccess is the pragmatic choice AND is
# honestly labeled as such. For a shared/prod account, replace this with a scoped policy (see
# docs/OIDC-SETUP.md for the least-privilege guidance and why we didn't ship it by default).
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arn" {
  description = "Set this as the GitHub repo variable AWS_ROLE_ARN (used by the workflow)."
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "The existing account-wide GitHub OIDC provider referenced by the role."
  value       = data.aws_iam_openid_connect_provider.github.arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
