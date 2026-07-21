# Provider & module version constraints.
# Convention: pin a floor with `>=` at the current major and keep it uniform across the repo
# (avoids `~>` lock-in while still preventing an accidental jump to an untested next major).
terraform {
  # >= 1.11: required for S3-native state locking (use_lockfile) — no DynamoDB table.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.33"
    }
    # kubectl provider: applies raw manifests (the root app-of-apps) that the
    # kubernetes provider can't model cleanly as a typed resource.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19"
    }
    # http: fetches the upstream AWS LB Controller IAM policy JSON at apply time.
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
  }

  # Remote state so `make down` (terraform destroy) is safe and the cluster stays
  # disposable: state survives teardown, enabling a clean `make up` rebuild.
  #
  # State locking is S3-NATIVE via use_lockfile (GA since Terraform 1.11) — no DynamoDB table.
  # The state bucket is created by terraform/bootstrap/ (its output `state_bucket`).
  # bucket/key are supplied at init time (they embed the account ID), e.g.:
  #   terraform init -backend-config=backend.hcl
  # where backend.hcl contains bucket/key/region (see bootstrap output `backend_config_hint`).
  backend "s3" {
    encrypt      = true
    use_lockfile = true # S3 conditional-write locking; replaces the old dynamodb_table lock
  }
}
