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
