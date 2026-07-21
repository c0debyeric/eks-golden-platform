# Provider & module version constraints.
# Convention: pin a floor with `>=` at the current major and keep it uniform across the repo
# (avoids `~>` lock-in while still preventing an accidental jump to an untested next major).
terraform {
  required_version = ">= 1.9"

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
  # Fill in via `terraform init -backend-config=...` or a backend.hcl (gitignored).
  backend "s3" {}
}
