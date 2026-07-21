# EKS Golden Platform — Research & Reference

> **Bottom line up front:** the 2026 golden-standard EKS portfolio stack is a **Terraform platform
> layer** (VPC + `terraform-aws-modules/eks ~> 21.0`, K8s 1.33, Karpenter v1.x, EKS Pod Identity,
> Access Entries) that bootstraps **ArgoCD**, which then GitOps-syncs the **entire application
> layer** (AWS LB Controller, External Secrets, and the observability stack) via an app-of-apps of
> pinned upstream Helm charts. The architectural spine is: **Terraform owns the disposable cluster;
> Git owns everything running on it.** That split is what makes it both production-grade and cheap
> to tear down/rebuild.

This directory is the reference documentation researched before building. It reflects upstream
versions and recommendations verified 2026-07 (sources cited inline in each doc).

---

## Companion documents

```
docs/research/
├── RESEARCH.md                 <- you are here (index + synthesis)
├── 01-eks-platform.md          Terraform: VPC, EKS module, Karpenter, Pod Identity,
│                               Access Entries, add-ons, security, COST + teardown lifecycle
├── 02-gitops-argocd-helm.md    ArgoCD 3.1, app-of-apps, Helm multi-source, sync waves,
│                               External Secrets Operator (public-repo-safe secrets)
└── 03-observability.md         kube-prometheus-stack, Grafana, Loki 3.x (S3, SingleBinary),
                                OpenTelemetry Operator/Collector, Promtail->Alloy/OTel shift
```

---

## The stack at a glance (ranked decisions across all three docs)

```
Layer          Decision                          Runner-up (why not)
-------------  --------------------------------  ---------------------------------
Cluster IaC    terraform-aws-modules/eks ~>21    raw resources (reinvents the wheel)
Compute        Karpenter v1.x (spot-first)       EKS Auto Mode (+12% fee, weaker signal)
Identity       EKS Pod Identity                  IRSA (per-cluster OIDC, breaks on rebuild)
Cluster auth   Access Entries API                aws-auth ConfigMap (legacy, lockout risk)
NAT            Single NAT GW                     NAT-per-AZ (3x cost, HA you don't need)
GitOps         ArgoCD app-of-apps                ApplicationSet (for multi-cluster only)
Helm delivery  1 App/component + $values         umbrella chart (couples components)
Secrets        External Secrets Op + Pod Identity Sealed Secrets/SOPS (rebuild friction)
Metrics        kube-prometheus-stack 87.x        standalone Prometheus (more wiring)
Logs collect   OTel Collector (otlphttp)         Promtail (DEPRECATED Feb 2025)
Logs store     Loki 3.x SingleBinary -> S3       loki-stack chart (deprecated)
Telemetry      OpenTelemetry Operator+Collector  Grafana Alloy (valid alt; pick one)
```

---

## Cross-file synthesis — how it all connects

1. **Terraform stops at ArgoCD.** The platform layer (doc 01) provisions VPC/EKS/Karpenter-IAM/
   add-ons and installs exactly ONE app-layer thing: ArgoCD (via `helm_release`) plus the root
   app-of-apps manifest. Everything else is Git-driven (doc 02).

2. **Pod Identity is the seam between doc 01 and doc 03.** The observability workloads that touch
   AWS (Loki→S3, External Secrets→Secrets Manager) get their credentials via Pod Identity
   associations created in Terraform (doc 01 §3) but consumed by Helm-deployed pods (doc 02/03).
   This is why Pod Identity beats IRSA here: associations are cluster-agnostic and survive the
   teardown/rebuild lifecycle.

3. **Sync waves enforce the dependency order** (doc 02 §5): operators and CRDs (Prometheus
   Operator, OTel Operator, External Secrets) sync BEFORE the custom resources that depend on them
   (ServiceMonitors, OpenTelemetryCollectors, ExternalSecrets). Skip this and a fresh `make up`
   fails on missing CRDs.

4. **The OTel Collector is the observability spine** (doc 03): one pipeline ingests OTLP from apps
   and fans out — metrics→Prometheus (remote-write), logs→Loki (native `/otlp/v1/logs` via
   `otlphttp`), traces→Tempo (out of scope). This replaces the old Promtail+scrape-only pattern.

5. **Public-repo safety is designed in, not bolted on** (doc 02 §6): no secret value ever lands in
   Git. External Secrets Operator commits only a POINTER (`ExternalSecret`) to AWS Secrets Manager;
   the value is fetched at runtime via Pod Identity. `.gitignore` blocks tfstate/tfvars/kubeconfig.

6. **Cost + disposability is the through-line** (doc 01 §7): $73 control plane + $32 single NAT +
   spot nodes = ~$110-140/mo floor; `make down` → ~$0 with S3-backed Loki logs and Terraform state
   surviving. Watch the **$438/mo extended-support trap** — keep the K8s version current.

---

## Build order (what the scaffold implements)

```
1. terraform apply   -> VPC, EKS 1.33, Karpenter IAM+SQS, managed add-ons, Pod Identity roles
2. helm_release      -> ArgoCD (bootstrap, once)
3. kubectl apply     -> root app-of-apps Application
4. ArgoCD sync waves -> ALB controller & Karpenter NodePools (w0) -> ESO (w1) ->
                        kube-prometheus-stack, Loki, OTel Operator (w2) ->
                        OTel Collectors, ServiceMonitors, ExternalSecrets (w3)
5. result            -> full observable cluster; tear down with `make down`
```

See the repo root `README.md` for the `make up` / `make down` runbook and prerequisites.
