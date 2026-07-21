# 02 — GitOps Delivery Layer (ArgoCD + Helm)

> Golden-standard research for the GitOps layer: ArgoCD, app-of-apps / ApplicationSets, Helm
> packaging, sync waves, and secrets in a PUBLIC repo. Platform (EKS) is doc 01; observability
> workloads are doc 03. Research date: 2026-07.

---

## 0. TL;DR

```
+---------------------------------------------------------------+
|  ArgoCD 3.1.x  (installed by Terraform helm_release, once)    |
|      |                                                         |
|      v                                                         |
|  root "app-of-apps" Application  (points at gitops/bootstrap) |
|      |                                                         |
|      +--> Application: aws-load-balancer-controller  (wave 0) |
|      +--> Application: karpenter NodePools/EC2NodeClass (wave 0)|
|      +--> Application: external-secrets-operator      (wave 1) |
|      +--> Application: kube-prometheus-stack          (wave 2) |
|      +--> Application: loki                           (wave 2) |
|      +--> Application: opentelemetry-operator         (wave 2) |
|      +--> Application: otel-collector + Alloy         (wave 3) |
+---------------------------------------------------------------+
```

Secrets: **External Secrets Operator + EKS Pod Identity** → nothing sensitive ever in Git.

---

## 1. ArgoCD version & install (the bootstrap chicken-and-egg)

- **Current:** ArgoCD **3.1.x** (3.1 GA Aug 2025; 3.2 in flight). Source:
  https://endoflife.date/argo-cd
- **The bootstrap problem:** Terraform provisions the cluster, but ArgoCD must exist before it can
  manage anything. Resolve it with a single `helm_release` in Terraform that installs ArgoCD, then
  ArgoCD manages everything else (including itself, via a self-managed Application).

```hcl
# In Terraform, AFTER the EKS module. This is the ONLY app-layer thing
# Terraform installs — everything else is ArgoCD's job.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.x"          # chart version; pin it

  # Minimal values; the rest of ArgoCD config is GitOps-managed after bootstrap.
  values = [file("${path.module}/argocd-bootstrap-values.yaml")]
}

# The root app-of-apps, applied once so ArgoCD starts pulling from Git.
resource "kubectl_manifest" "root_app" {
  yaml_body  = file("${path.module}/../gitops/bootstrap/root-app.yaml")
  depends_on = [helm_release.argocd]
}
```

Ranked install methods:

```
1. Helm chart via Terraform helm_release   ← RECOMMENDED (bootstrap once)
   + One-command bootstrap, versioned, fits make up/down
2. Raw manifests (kubectl apply -n argocd)
   + Simple, but unversioned and manual
3. argocd-operator
   - Overkill for single-cluster; adds an operator to manage
```

After bootstrap, add a self-managed ArgoCD `Application` so ArgoCD upgrades itself from Git —
Terraform never touches ArgoCD config again.

---

## 2. App-of-apps vs ApplicationSets

```
Rank  Pattern              Best for
1.    App-of-apps          single cluster, explicit control  ← THIS PROJECT
      (one root App whose
       manifests are child
       Applications)
2.    ApplicationSet       many clusters / many envs / dynamic fan-out
      (generators: git,
       cluster, matrix)
```

**Decision:** app-of-apps as the spine (one root `Application` → a directory of child
`Application` manifests). It's explicit, readable in a portfolio, and every reviewer knows it.
Add an **ApplicationSet with a git-directory generator** ONLY if you later want "drop a folder in
`apps/`, get an Application automatically." For a single cluster, app-of-apps is the clearer
story. Source: https://argo-cd.readthedocs.io/en/latest/operator-manual/cluster-bootstrapping/

Root Application (the app-of-apps):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/eks-golden-platform.git
    path: gitops/bootstrap        # dir of child Application manifests
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }   # full GitOps: drift is reverted
    syncOptions: [CreateNamespace=true]
```

---

## 3. Repo layout (monorepo GitOps structure)

```
eks-golden-platform/
├── terraform/                 # doc 01 — platform only
│
└── gitops/
    ├── bootstrap/             # root app-of-apps points HERE
    │   ├── root-app.yaml      # the root Application (§2)
    │   ├── alb-controller.yaml
    │   ├── karpenter-nodepools.yaml
    │   ├── external-secrets.yaml
    │   ├── kube-prometheus-stack.yaml
    │   ├── loki.yaml
    │   ├── otel-operator.yaml
    │   └── otel-collector.yaml     # each is a child Application
    │
    └── apps/                  # values + local manifests per component
        ├── alb-controller/values.yaml
        ├── karpenter/{nodepool.yaml,ec2nodeclass.yaml}
        ├── external-secrets/{values.yaml,clustersecretstore.yaml}
        ├── kube-prometheus-stack/values.yaml
        ├── loki/values.yaml
        ├── otel-operator/values.yaml
        └── otel-collector/{collector.yaml,instrumentation.yaml}
```

Each child `Application` in `bootstrap/` points at an upstream Helm chart with a `values.yaml`
override living in `apps/<component>/`. Karpenter NodePools/EC2NodeClass and OTel CRDs are plain
manifests in `apps/` (no chart) synced by their own Application.

---

## 4. Helm in an ArgoCD context

```
Rank  Approach                                    Use for
1.    One Application per component, each          <- RECOMMENDED
      pointing at the UPSTREAM chart + a
      values override file (multi-source)
2.    Umbrella/parent chart with sub-charts
      as dependencies
      - Couples unrelated components; one bad
        bump blocks the whole umbrella
```

**Decision:** one Application per component pointing at the upstream chart, with values overrides.
Keeps components independently versioned and syncable. Use ArgoCD **multiple sources** so the
chart comes from the upstream Helm repo while `values.yaml` comes from YOUR git repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"          # ordering, see section 5
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 87.16.1                   # PIN the chart version
      helm:
        valueFiles:
          - $values/gitops/apps/kube-prometheus-stack/values.yaml
    - repoURL: https://github.com/<you>/eks-golden-platform.git
      targetRevision: main
      ref: values                               # $values resolves to this repo
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- **Always pin `targetRevision`** to an exact chart version — never `*` or a floating range, or a
  reviewer's clone drifts from yours.
- `$values` multi-source keeps your overrides in Git (auditable, PR-reviewable) without vendoring
  the whole upstream chart. Source: https://argo-cd.readthedocs.io/en/latest/user-guide/helm

---

## 5. Sync policies, waves & options

```
Sync policy      automated + prune + selfHeal   full GitOps; Git is truth, drift reverted
Sync waves       argocd.argoproj.io/sync-wave   ordering (low number syncs first)
CreateNamespace  syncOption                     ArgoCD makes the ns
ServerSideApply  syncOption                     needed for big CRDs (Prometheus, OTel)
```

### Sync-wave ordering (CRDs before the workloads that use them)

```
wave 0  aws-load-balancer-controller, karpenter NodePool/EC2NodeClass
wave 1  external-secrets-operator            (CRDs: ExternalSecret, SecretStore)
wave 2  kube-prometheus-stack, loki,         (Prometheus Operator installs its CRDs)
        opentelemetry-operator               (installs OpenTelemetryCollector CRD)
wave 3  OpenTelemetryCollector + Instrumentation CRs, ServiceMonitors, ExternalSecrets
        (these DEPEND on wave 1/2 CRDs existing first)
```

The classic failure without waves: an `OpenTelemetryCollector` custom resource syncs before the
OTel Operator has registered its CRD -> sync fails. Waves force the operator (wave 2) ahead of its
CRs (wave 3). `ServerSideApply=true` avoids the "annotation too long" error on the huge
Prometheus/OTel CRDs.

---

## 6. Secrets in a PUBLIC repo (nothing sensitive in Git, ever)

```
Rank  Approach                          Public-repo safe?   Notes
1.    External Secrets Operator (ESO)   YES  <- RECOMMENDED  refs live in AWS SM/SSM
      + EKS Pod Identity                                     via Pod Identity; only a
                                                             POINTER is committed
2.    Sealed Secrets (Bitnami)          YES                  encrypted blob in Git;
                                                             cluster-key bound, awkward rebuild
3.    SOPS + age/KMS                     YES                  encrypted files in Git; extra tooling
4.    Plain K8s Secret in Git            NO                   never
```

**Decision:** External Secrets Operator + EKS Pod Identity. Secrets live in AWS Secrets Manager /
SSM Parameter Store; the repo commits only an `ExternalSecret` that NAMES the secret. ESO's
`ServiceAccount` gets a Pod Identity association (doc 01 section 3) with read access to those
specific secret ARNs — so a public clone reveals only the secret's *name*, never its value, and
survives cluster teardown/rebuild (the secret stays in AWS). Source:
https://external-secrets.io/latest/provider/aws-secrets-manager/

```yaml
# gitops/apps/external-secrets/clustersecretstore.yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: { name: aws-secrets-manager }
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth: {}          # empty -> uses the SA's Pod Identity credentials
---
# An ExternalSecret is the ONLY secret-related thing in Git. No values.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: grafana-admin, namespace: monitoring }
spec:
  secretStoreRef: { name: aws-secrets-manager, kind: ClusterSecretStore }
  target: { name: grafana-admin-credentials }   # the K8s Secret ESO creates
  data:
    - secretKey: admin-password
      remoteRef: { key: eks-golden/grafana, property: admin-password }
```

Public-repo hygiene checklist:
- No `*.tfvars`, no kubeconfig, no `.env`, no plaintext Secret manifests committed.
- `.gitignore` excludes `*.tfstate*`, `.terraform/`, `*.tfvars`, `kubeconfig*`.
- Grafana admin password, any API tokens -> AWS Secrets Manager, referenced via ESO only.

---

## Sources

- Argo CD versions / EOL — https://endoflife.date/argo-cd
- Cluster bootstrapping (app-of-apps) — https://argo-cd.readthedocs.io/en/latest/operator-manual/cluster-bootstrapping/
- ApplicationSet git generator — https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Generators-Git/
- Helm in Argo CD (multi-source, $values) — https://argo-cd.readthedocs.io/en/latest/user-guide/helm
- External Secrets Operator (AWS SM) — https://external-secrets.io/latest/provider/aws-secrets-manager/
