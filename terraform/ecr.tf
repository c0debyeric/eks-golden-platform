# Container image registries for the two first-party workloads.
#
# These repositories predate this file — they were created ad hoc with the AWS
# CLI while bootstrapping. They are declared here and imported (see the `import`
# blocks below) so the registry's security posture is reviewable in code rather
# than being whatever someone typed once. The attribute values below match the
# live repositories exactly, so the import produces a zero-diff plan.

locals {
  # One repository per deployable image. Keyed by name so adding a third
  # workload is a one-line change and the key becomes the repository name.
  ecr_repositories = toset(["mcp-backend", "mcp-frontend"])
}

resource "aws_ecr_repository" "app" {
  for_each = local.ecr_repositories

  name = each.key

  # IMMUTABLE is the single most important setting here. The GitOps values files
  # pin images by tag AND digest, but immutability is what makes the tag half of
  # that pin meaningful: without it, a pushed tag can be silently repointed at
  # different content, so what CI tested and what the cluster runs can diverge.
  # It also makes `mcp-backend:<sha>` a durable audit record.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Basic scanning on push. Cheap, and catches known-vulnerable base layers at
    # the point of publication rather than at the point of incident.
    scan_on_push = true
  }

  encryption_configuration {
    # AES256 = ECR-managed keys. A CMK would allow key-level access revocation
    # and its own audit trail, but adds KMS cost and a key policy that must
    # grant the EKS node role decrypt. Not worth it for a demo registry;
    # switching later forces repository replacement, so it is called out here.
    encryption_type = "AES256"
  }

  tags = var.tags
}

# NOTE: no aws_ecr_lifecycle_policy is defined, deliberately.
#
# With IMMUTABLE tags every CI build adds a new image, so storage grows without
# bound and an expiry rule is the obvious next step. It is omitted because the
# obvious rule ("keep the last N images") deletes by push recency, not by what
# is actually deployed. Production is pinned to a digest and is intentionally
# slow to move, so a busy period on dev could expire the image prod is pinned
# to — which surfaces only later, as an ImagePullBackOff the first time a prod
# pod reschedules onto a new node. Adding expiry safely needs a rule that
# excludes digests referenced by gitops/apps/*/values-*.yaml.

# Adopt the pre-existing repositories into state. Declarative import blocks
# (Terraform >= 1.5) rather than `terraform import` CLI calls, so the adoption
# is reviewable, replayable, and survives a state rebuild.
import {
  to = aws_ecr_repository.app["mcp-backend"]
  id = "mcp-backend"
}

import {
  to = aws_ecr_repository.app["mcp-frontend"]
  id = "mcp-frontend"
}
