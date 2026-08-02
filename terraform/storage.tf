# S3 buckets backing Loki (chunks + ruler). Defined here so a fresh `terraform apply`
# from a clean clone reproduces the whole platform — Loki's values.yaml references these
# bucket names, and without them the ingester/compactor fail on first write.
#
# NOTE: created out-of-band via CLI during initial bring-up, then imported into state
# (see docs/TEARDOWN-GOTCHAS.md). Kept in Terraform for reproducibility.

locals {
  loki_buckets = toset(["${var.name}-loki-chunks", "${var.name}-loki-ruler"])
}

resource "aws_s3_bucket" "loki" {
  for_each = local.loki_buckets
  bucket   = each.value
  tags     = var.tags
}

# WHY block ALL public access: log data is sensitive (may contain tokens, PII in log lines).
# Golden standard is private + encrypted; never rely on default ACLs.
resource "aws_s3_bucket_public_access_block" "loki" {
  for_each                = local.loki_buckets
  bucket                  = aws_s3_bucket.loki[each.value].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-KMS at rest. aws:kms (not SSE-S3) so access is auditable via KMS CloudTrail events.
resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  for_each = local.loki_buckets
  bucket   = aws_s3_bucket.loki[each.value].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Two rules, two very different jobs.
#
# 1. abort_incomplete_multipart_upload — Loki writes chunks with multipart uploads. Any upload
#    interrupted by a pod eviction (Karpenter consolidation, OOMKill, `make down` mid-flush)
#    leaves orphaned parts behind. Those parts are BILLED but do not appear in the object list
#    or in the bucket size shown in the console, so the cost is invisible until you go looking
#    for it with `s3api list-multipart-uploads`. On a cluster that is torn down and rebuilt on
#    purpose, this is not a hypothetical.
#
# 2. expiration — a safety net, NOT the retention mechanism. Retention is enforced by Loki's
#    compactor (compactor.retention_enabled in gitops/apps/loki/values.yaml, 168h). This rule
#    sits well behind it at 30 days so that if the compactor is disabled, crash-looping, or
#    loses its IAM permissions, the bucket still cannot grow without bound. Deliberately not
#    set to 7 days: matching the app-level retention would let S3 delete chunks the compactor
#    still has indexed, producing query errors instead of a clean 7-day window.
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  for_each = local.loki_buckets
  bucket   = aws_s3_bucket.loki[each.value].id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "safety-net-expiration"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

########################################
# Tempo trace storage (single object-storage bucket)
########################################
# WHY a dedicated bucket: Tempo (like Loki) is object-storage-native — traces (blocks + WAL
# flushes) live in S3 so they survive `make down`/`make up`, and the trace tier stays isolated
# from Loki's log chunks for independent lifecycle/retention and least-priv IAM scoping.
# Tempo needs only ONE bucket (vs Loki's chunks+ruler split), so a plain resource is clearer
# than a for_each here.
resource "aws_s3_bucket" "tempo" {
  bucket = "${var.name}-tempo-traces"
  tags   = var.tags
}

# Block ALL public access: traces can carry request paths, headers, and IDs that are sensitive.
resource "aws_s3_bucket_public_access_block" "tempo" {
  bucket                  = aws_s3_bucket.tempo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-KMS at rest (auditable via KMS CloudTrail), matching the Loki bucket posture.
resource "aws_s3_bucket_server_side_encryption_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Same two-rule posture as the Loki buckets; see the comment there for the full reasoning.
# Tempo's own retention is 72h (tempo.retention in gitops/apps/tempo/values.yaml) and its
# compactor does the deleting; 14 days here is the backstop against a compactor that has
# stopped working. Traces are far higher volume than logs, so the backstop is tighter.
resource "aws_s3_bucket_lifecycle_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "safety-net-expiration"
    status = "Enabled"
    filter {}
    expiration {
      days = 14
    }
  }
}
