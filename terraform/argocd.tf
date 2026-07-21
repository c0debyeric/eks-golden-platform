# ArgoCD bootstrap: the ONLY application-layer thing Terraform installs.
# After this, ArgoCD reconciles the entire stack from Git (gitops/). This is the architectural
# spine: Terraform owns the disposable cluster; Git owns everything running on it.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version # pinned (variables.tf)

  # Minimal bootstrap values. Everything else about ArgoCD is GitOps-managed after bootstrap
  # via a self-managed Application in gitops/, so Terraform never touches ArgoCD config again.
  values = [
    yamlencode({
      # Run the ArgoCD controllers on the bootstrap node group (they tolerate the small nodes).
      configs = {
        params = {
          # Reduce resource footprint on a cost-conscious cluster.
          "server.insecure" = true # TLS terminated at the ALB/ingress layer later
        }
      }
    })
  ]

  # Karpenter + add-ons must be live before ArgoCD schedules; the managed node group provides
  # initial capacity regardless, but ordering keeps the first sync clean.
  depends_on = [module.eks]
}

# The root app-of-apps. Applying this single manifest points ArgoCD at gitops/bootstrap/,
# from which it discovers and syncs every child Application (see gitops/ and docs 02).
resource "kubectl_manifest" "root_app" {
  yaml_body = templatefile("${path.module}/templates/root-app.yaml.tftpl", {
    git_repo_url = var.git_repo_url
  })

  depends_on = [helm_release.argocd]
}
