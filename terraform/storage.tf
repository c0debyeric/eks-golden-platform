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
