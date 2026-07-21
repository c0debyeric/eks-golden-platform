# Outputs consumed by the Makefile (kubeconfig, cluster identity) and useful for verification.

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region (for `aws eks update-kubeconfig`)."
  value       = var.region
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "karpenter_node_iam_role_name" {
  description = "Node IAM role name Karpenter's EC2NodeClass must reference."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  description = "SQS interruption queue Karpenter watches for spot reclamation."
  value       = module.karpenter.queue_name
}

output "external_secrets_role_arn" {
  description = "IAM role ARN associated with the External Secrets Operator service account."
  value       = aws_iam_role.external_secrets.arn
}

########################################
# RDS (only populated when var.create_rds = true)
########################################
output "rds_primary_endpoint" {
  description = "Writer endpoint of the RDS primary — point writes + write-through reads here."
  value       = var.create_rds ? module.rds_primary[0].db_instance_endpoint : null
}

output "rds_replica_endpoints" {
  description = "Reader endpoints of the RDS read replicas — point read-heavy queries here."
  value       = var.create_rds ? [for r in module.rds_replica : r.db_instance_endpoint] : []
}

output "rds_master_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding the RDS-managed master credentials (username/password).
    Apps consume this via External Secrets Operator, never plaintext. Null unless create_rds.
  EOT
  value       = var.create_rds ? module.rds_primary[0].db_instance_master_user_secret_arn : null
}

