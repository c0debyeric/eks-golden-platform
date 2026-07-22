# EKS Golden Platform

Production-grade Amazon EKS platform built to the 2026 golden standard, delivered entirely via
Infrastructure-as-Code and GitOps — with a documented cheap teardown/spin-up lifecycle so it costs
~$0 when idle.

**Stack:** EKS · Helm · ArgoCD · Prometheus · Grafana · Loki · OpenTelemetry · Karpenter · RDS PostgreSQL

![Architecture](docs/architecture.svg)

---

## Architectural spine

> **Terraform owns the disposable cluster; Git owns everything running on it.**

1. **Terraform** provisions the platform (VPC with 3-tier subnets, EKS 1.33, Karpenter, Pod Identity
   roles, managed add-ons, an optional RDS PostgreSQL data tier) and installs exactly one
   application-layer thing: **ArgoCD**, plus a root app-of-apps manifest.
2. **ArgoCD** then reconciles the *entire* workload layer from this Git repo — the AWS Load
   Balancer Controller, External Secrets Operator, and the full observability stack — using
   pinned upstream Helm charts and sync-wave ordering.
3. Tear the cluster down with `make down` and the platform disappears (~$0). `make up` rebuilds it
   and ArgoCD restores the whole stack from Git. State (S3) and logs (Loki→S3) survive.

Design rationale and every version/decision is documented in [`docs/research/`](docs/research/RESEARCH.md).

---

## Repository layout

```
eks-golden-platform/
├── Makefile                    # make up / down / status / argocd-ui
├── terraform/                  # PLATFORM layer (disposable cluster)
│   ├── versions.tf             # provider pins (>= at current major, uniform) + S3 backend
│   ├── variables.tf            # cost vs. HA knobs (single_nat, endpoint access, RDS, ci_role)
│   ├── network.tf              # VPC + 3-tier subnets (public/private/database) + NAT + S3 endpoint
│   ├── cluster.tf              # EKS control plane + managed add-ons + bootstrap node group + CI access entry
│   ├── compute.tf              # Karpenter AWS side (node IAM role, SQS interruption queue)
│   ├── iam.tf                  # Pod Identity roles (ALB ctrl, External Secrets, EBS CSI, Loki)
│   ├── storage.tf              # Loki S3 buckets (chunks + ruler)
│   ├── rds.tf                  # PostgreSQL 18.4 — Multi-AZ primary + 2 read replicas (gated)
│   ├── argocd.tf               # ArgoCD bootstrap + root app-of-apps (the handoff)
│   ├── providers.tf            # aws/helm/kubernetes/kubectl (token exec, no kubeconfig)
│   ├── outputs.tf
│   ├── bootstrap/              # ONE-TIME: creates the S3 state bucket + GitHub OIDC CI role
│   └── templates/root-app.yaml.tftpl
├── gitops/                     # APPLICATION layer (GitOps, ArgoCD-managed)
│   ├── bootstrap/              # one child Application per component (+ sync waves)
│   └── apps/                   # Helm values + plain manifests per component
└── docs/
    ├── architecture.svg
    └── research/               # golden-standard reference (READ THIS)
        ├── RESEARCH.md         # index + BLUF + cross-file synthesis
        ├── 01-eks-platform.md
        ├── 02-gitops-argocd-helm.md
        └── 03-observability.md
```

---

## Golden-standard decisions (why each choice)

| Layer | Decision | Why |
|-------|----------|-----|
| Cluster IaC | `terraform-aws-modules/eks ~> 21` | community standard; Karpenter + access-entries built in |
| Compute | Karpenter v1.x, spot-first | cheapest steady state; NodePool/EC2NodeClass CRDs |
| Identity | EKS **Pod Identity** | cluster-agnostic; survives teardown/rebuild (IRSA breaks) |
| Cluster auth | **Access Entries API** | no `aws-auth` ConfigMap lockout risk |
| NAT | one NAT **per AZ** (default) | full AZ-fault isolation; flip `single_nat_gateway=true` for ~$32/mo demo |
| GitOps | ArgoCD **app-of-apps** + sync-waves | explicit single-cluster clarity; CRD-ordered installs |
| Secrets | External Secrets Op + Pod Identity | **public-repo-safe** — only pointers in Git |
| Metrics | kube-prometheus-stack 87.x | Operator + Prometheus + Grafana + Alertmanager |
| Logs | Loki 3.x SingleBinary → S3 | cheap; logs survive teardown; native OTLP ingest |
| Telemetry | OpenTelemetry Operator + Collector | unified metrics+logs+traces pipeline |
| Data | RDS PostgreSQL 18.4, **Multi-AZ + 2 read replicas** | HA standby (failover) + read scaling; isolated NAT-less DB tier |
| Network | 3-tier subnets (public/private/**database**) | database tier has no egress route — defense in depth |
| CI | GitHub OIDC + AWS-layer `terraform plan` | keyless; CI role scoped to infra (GitOps-managed resources excluded) |

*(This is the only markdown table in the repo — the research docs use ASCII/ranked lists for
messaging-app legibility.)*

---

## Prerequisites

- Terraform >= 1.15, AWS CLI v2, `kubectl`, `helm`
- AWS credentials with permissions to create VPC/EKS/IAM (an admin-ish role)
- **One-time bootstrap** (`terraform/bootstrap/`, run once with local state): creates the **S3 state
  bucket** and the **GitHub OIDC role** for CI. State locking is **S3-native**
  (`use_lockfile = true`, Terraform >= 1.11) — **no DynamoDB table**.
- Loki's two S3 buckets (chunks + ruler) are created by `terraform/storage.tf` — no manual step.
- A secret in AWS Secrets Manager at `eks-golden/grafana` with keys `admin-user`, `admin-password`
  (resolved into the cluster by External Secrets Operator).
- **Optional RDS** (`create_rds = true`): a self-managed master password is generated and stored in
  Secrets Manager at `eks-golden/rds-master` automatically — no manual secret needed.

## Quick start

```bash
# 1. Configure backend + vars
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
#   edit git_repo_url to your fork; create backend.hcl for the S3 backend

# 2. Init + validate
make init
make validate

# 3. Bring the platform up (Terraform, then ArgoCD bootstraps the rest)
make up

# 4. Watch ArgoCD sync the stack
make status
make argocd-ui          # https://localhost:8080
make argocd-password    # initial admin password

# 4b. (if create_rds=true) inspect the data tier
make rds-info           # primary + replica endpoints, secret ARN
make db-password        # RDS master password from Secrets Manager

# 5. Tear it all down (~$0). S3 state + Loki chunks are retained.
make down
```

## Cost

```
EKS control plane        ~$73/mo   (fixed, per cluster)
NAT gateways (per-AZ x3)  ~$97/mo   (+ data processing) — default production posture
2x t3.medium bootstrap   ~$30/mo   (spot-eligible via Karpenter for workloads)
EBS + S3                 ~$6-20/mo
RDS (opt-in, create_rds) ~$50/mo   Multi-AZ primary + 2 read replicas (db.t4g.micro)
-----------------------------------
Production floor          ~$200-240/mo   ->   make down -> ~$0
Demo floor (single NAT,   ~$110-140/mo   set single_nat_gateway=true, create_rds=false
  no RDS)
```

⚠️ **Keep `kubernetes_version` current.** Falling into EKS *extended support* raises the control
plane to ~$438/mo. See [`docs/research/01-eks-platform.md`](docs/research/01-eks-platform.md) §7.

## Security & public-repo safety

- No secret values in Git — External Secrets Operator commits only *pointers* to AWS Secrets
  Manager, resolved at runtime via Pod Identity.
- `.gitignore` blocks `*.tfstate*`, `*.tfvars`, `kubeconfig*`, `*.pem`, `.env`.
- IMDSv2 required on all nodes (`http_tokens=required`, hop limit 1); KMS-encrypted K8s secrets;
  nodes in private subnets; Access Entries instead of `aws-auth`.

## Production vs. portfolio posture

This repo **defaults to the production HA posture** (one NAT per AZ, isolated database subnet tier).
Flip to the **cheap portfolio/demo** posture with tfvars, no code changes:

```hcl
single_nat_gateway     = true    # one shared NAT (~$32/mo) — single-AZ egress SPOF
create_rds             = false   # skip the ~$50/mo database tier entirely
endpoint_public_access = true    # public API endpoint (set false + SSM/bastion to harden)
```

For the hardened production endpoint, set `endpoint_public_access = false` and reach the API via
SSM Session Manager or a bastion.

## Data tier (optional)

Set `create_rds = true` to provision PostgreSQL 18.4 in the **isolated database subnet tier** (no
NAT route — the DB physically cannot egress to the internet):

- **Multi-AZ primary** — synchronous standby in a second AZ for automatic failover (HA, *not*
  readable).
- **2 read replicas** — asynchronous, in separate AZs, for read scaling (readable).

The master password is generated locally and stored in Secrets Manager at `eks-golden/rds-master`.
The RDS security group only accepts `:5432` from the EKS node security group. Endpoints are exposed
as Terraform outputs (`rds_primary_endpoint`, `rds_replica_endpoints`, `rds_master_secret_arn`).

> **Note:** RDS-managed master passwords are *incompatible* with Postgres read replicas, so the
> password is self-managed (`password_wo` + a Terraform-owned Secrets Manager secret).

## CI (GitHub Actions)

- **Keyless** — the workflow assumes `AWS_ROLE_ARN` via GitHub OIDC (no static keys in the repo).
- **`lint` job**: `terraform fmt -check` + `validate` (no cloud calls).
- **`plan` job**: OIDC assume → `terraform plan` **scoped to the AWS-infra layer** via `-target`
  (VPC/EKS/Karpenter/IAM/S3). GitOps-managed resources (Helm/ArgoCD CRDs) and the gated RDS module
  are excluded — the CI role stays least-privilege and the plan doesn't show false teardowns of
  resources it isn't allowed to read. Runs with `-lock=false` to avoid contending with local applies.

## License

MIT — see [LICENSE](LICENSE).

---
*Built as a portfolio reference for the 2026 EKS golden standard. Research + decisions in
[`docs/research/`](docs/research/RESEARCH.md).*
