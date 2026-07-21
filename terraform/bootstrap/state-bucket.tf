# S3 bucket for Terraform remote state, provisioned by the bootstrap (which runs first, locally).
# State locking is S3-native via `use_lockfile = true` in the main module's backend block —
# NO DynamoDB table (deprecated pattern; S3 conditional-write locking is GA since Terraform 1.11).

# Bucket name must be globally unique; suffix with the account ID to avoid collisions.
locals {
  state_bucket_name = "${var.github_repo}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # Guard against accidental `terraform destroy` of the bucket that holds ALL state.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Project   = "eks-golden-platform"
    ManagedBy = "terraform-bootstrap"
    Purpose   = "terraform-remote-state"
  }
}

# Versioning is REQUIRED for safe state: lets you recover a prior state if a write corrupts it.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest (state contains sensitive values — resource IDs, sometimes secrets).
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms" # SSE-KMS; use the account default aws/s3 key
    }
    bucket_key_enabled = true # reduces KMS request cost
  }
}

# State must never be public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  description = "S3 bucket for Terraform state. Use in the main module's backend with use_lockfile=true."
  value       = aws_s3_bucket.tfstate.id
}

output "backend_config_hint" {
  description = "Paste into the main module's backend block (or a backend.hcl)."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.tfstate.id}"
    key          = "eks-golden-platform/terraform.tfstate"
    region       = "${var.region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
