# OIDC bootstrap: GitHub Actions -> AWS federation for this repo.
#
# WHY a separate root module with LOCAL state:
# This module creates the IAM role that CI uses to run the MAIN Terraform. It therefore cannot
# be created by that same CI (chicken-and-egg), so you apply it ONCE locally with your own admin
# credentials. Local state is fine — it's a tiny, rarely-changed, bootstrap-only config.
#
# WHY a data source (not a resource) for the OIDC provider:
# Account 123456789012 ALREADY has the GitHub OIDC provider (shared across repos). Creating a
# second would fail with EntityAlreadyExists. One provider per account is correct; roles are
# per-repo. We look the existing one up and reference its ARN.

terraform {
  required_version = ">= 1.15"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
  # Local state on purpose (see header). Do NOT point this at the same S3 backend the main
  # module uses — that backend may not exist yet on first bootstrap.
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub org/user that owns the repo."
  type        = string
  default     = "c0debyeric"
}

variable "github_repo" {
  description = "Repository name."
  type        = string
  default     = "eks-golden-platform"
}

variable "allowed_ref" {
  description = <<-EOT
    The GitHub ref allowed to assume the role. Tightest scope = a single branch.
    Format is the OIDC `sub` claim suffix, e.g. "ref:refs/heads/main".
    Other examples: "environment:production", "pull_request".
  EOT
  type        = string
  default     = "ref:refs/heads/main"
}

variable "subject_override" {
  description = <<-EOT
    Full OIDC `sub` claim to trust, when non-empty. This account's GitHub OIDC provider has
    immutable-numeric-ID subjects ENABLED, so the real sub is
    "repo:<org>@<orgID>/<repo>@<repoID>:ref:refs/heads/main" — the plain name does NOT match.
    Set this to the exact decoded sub (see docs/OIDC-SETUP.md for how to read it from a run).
    Leave empty to fall back to the constructed repo:<org>/<repo>:<allowed_ref> form.
  EOT
  type        = string
  default     = "repo:c0debyeric@52612730/eks-golden-platform@1307860662:ref:refs/heads/main"
}
