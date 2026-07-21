# 01 — EKS Platform Layer (Terraform)

> Golden-standard research for the EKS platform/infrastructure layer, provisioned by Terraform.
> Scope: cluster, compute (Karpenter/Auto Mode), identity (Pod Identity/IRSA), networking, add-ons,
> security, and cost. GitOps (ArgoCD/Helm) and observability are covered in `02-*` and `03-*`.
> Research date: 2026-07. Versions verified against upstream release pages (cited inline).

---

## 0. TL;DR — the golden stack (2026)

```
+--------------------------------------------------------------+
|  terraform-aws-modules/eks  ~> 21.0   (Kubernetes 1.33)      |
|                                                              |
|  Compute      : Karpenter v1.x (NodePool + EC2NodeClass)     |
|                 spot-first, on-demand fallback               |
|  Identity     : EKS Pod Identity (default) ; IRSA (fallback) |
|  Auth         : Access Entries API (NOT aws-auth ConfigMap)  |
|  Networking   : VPC CNI, 3-AZ, private nodes, SINGLE NAT     |
|  Core add-ons : managed EKS add-ons (vpc-cni, coredns,       |
|                 kube-proxy, ebs-csi, pod-identity-agent,     |
|                 metrics-server)                              |
|  LB           : AWS Load Balancer Controller (Helm, via GitOps)|
|  Security     : private endpoint opt., KMS secrets encryption,|
|                 IMDSv2 required, node IAM least-priv          |
+--------------------------------------------------------------+
```

Cost floor (us-east-1, minimal always-on): **~$110-140/mo**; teardown drops it to ~$0.
Detail in §7.

---

## 1. The Terraform module: `terraform-aws-modules/eks`

Still the community standard — do NOT hand-roll raw `aws_eks_cluster` resources. The module
encapsulates the control plane, node IAM, access entries, add-ons, and a first-class Karpenter
sub-module.

- **Current major:** `~> 21.0` (v21 line as of 2026-07). Use `>=` at the latest major uniformly
  across the repo (Eric's convention: `version = ">= 21.0"` not `~> 21.0` if you want floating
  within-major, but pin a floor). Source: https://github.com/terraform-aws-modules/terraform-aws-eks/releases
- **Kubernetes version:** `1.33` is the module's documented example default and a safe current
  choice. AVOID drifting into EKS *extended support* (adds the $438/mo trap — see §7).
- **v21 breaking changes vs v20:** variable renames (`cluster_*` → top-level, e.g.
  `cluster_version` → `kubernetes_version`), Auto Mode wiring via `compute_config`, and
  `create_auto_mode_iam_resources`. Read the v21 UPGRADE guide before copying old v20 examples.

Minimal module call (Karpenter path, NOT Auto Mode):

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = ">= 21.0"

  name               = "eks-golden"
  kubernetes_version = "1.33"

  # Public endpoint for a portfolio cluster you kubectl into from anywhere.
  # Flip to private + bastion/SSM for a "production hardened" story.
  endpoint_public_access = true

  # Access Entries API path: adds YOU as cluster admin without the aws-auth ConfigMap.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets   # nodes in private subnets

  # A tiny managed node group ONLY to host Karpenter + core controllers.
  # Karpenter then provisions everything else. Solves the chicken-and-egg.
  eks_managed_node_groups = {
    bootstrap = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }

  tags = { Project = "eks-golden-platform" }
}
```

---

## 2. Compute: Karpenter vs Auto Mode vs Managed Node Groups

### Ranked recommendation (cost-conscious portfolio + production story)

```
1. Karpenter v1.x (self-managed)  ← RECOMMENDED for this project
   + Full control, spot-first, best portfolio signal (you configured it)
   + Cheapest at steady state (no Auto Mode 12% surcharge)
   + NodePool / EC2NodeClass are the stable v1 CRDs (GA since v1.0, Aug 2024)
   - You own upgrades + the bootstrap node group chicken-and-egg

2. EKS Auto Mode
   + Zero node ops, AWS-managed Karpenter, Bottlerocket, best-practice defaults
   + Solves chicken-and-egg (controllers run in AWS-managed account)
   - +12% surcharge on top of EC2 cost
   - No SSH/SSM node access, no custom AMI, hard cap 110 pods/node
   - Weaker portfolio signal ("AWS did it for me")

3. Managed Node Groups only (no autoscaler)
   + Simplest
   - No dynamic right-sizing, wastes money, dated pattern
```

**Decision:** Karpenter v1.x. It's the strongest portfolio signal, cheapest at steady state, and
demonstrates the CRDs (NodePool/EC2NodeClass) reviewers expect. Sources:
https://aws.amazon.com/blogs/containers/announcing-karpenter-1-0 ,
https://repost.aws/articles/ARpmjGWmwWQuiGg3_NOnfLDg/eks-automode-vs-karpenter

### Karpenter version & CRDs

- **Karpenter v1.x is GA** (v1.0.0 = Aug 2024). Stable APIs: `NodePool` and `EC2NodeClass`
  (v1beta1 dropped after v1.1). The EKS module's Karpenter sub-module tracks recent Karpenter
  (v1.12-class as of the v21 module releases). Source: https://karpenter.sh/docs/concepts/nodepools/
- Install Karpenter itself via **Helm through ArgoCD** (see doc 02), with its IAM role +
  interruption SQS queue + instance profile created by the module's `karpenter` sub-module in
  Terraform. The controller runs on the small bootstrap managed node group.

### Spot-first NodePool (cost)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: default }
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type      # spot-first for cost
          operator: In
          values: ["spot", "on-demand"]        # falls back to on-demand
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]           # Graviton = cheaper
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: default }
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized   # pack pods, kill idle nodes
    consolidateAfter: 1m
  limits: { cpu: "16" }                        # hard ceiling = cost guardrail
```

The `consolidationPolicy` + `limits.cpu` pair is the single biggest cost lever — Karpenter
actively bin-packs and terminates underutilized nodes, and the limit caps blast radius.

---

## 3. Identity: EKS Pod Identity vs IRSA

### Ranked recommendation

```
1. EKS Pod Identity   ← DEFAULT for new clusters (2026)
   + No OIDC provider per cluster, no trust-policy juggling
   + Role association is a simple EKS API call (Terraform: aws_eks_pod_identity_association)
   + Reusable roles across clusters; cleaner audit
   + Requires the eks-pod-identity-agent add-on (a DaemonSet)
   - Newer; a few controllers historically only documented IRSA (check the chart)

2. IRSA (IAM Roles for Service Accounts)
   + Mature, universally supported by every Helm chart/controller
   + Needed if a workload predates Pod Identity support
   - Per-cluster OIDC provider + fiddly trust policies (federated sub/aud conditions)
```

**Decision:** Pod Identity as the default; keep IRSA available for any chart that still needs it
(e.g. verify Loki S3 — historically IRSA-only, tracked in grafana/loki#12624; use IRSA there if
Pod Identity isn't wired yet). Both are first-class in the EKS module.

Pod Identity association in Terraform:

```hcl
# The agent add-on (required for Pod Identity to work at all)
# is added as an EKS managed add-on in §5.

resource "aws_eks_pod_identity_association" "alb" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller.arn   # least-priv policy
}
```

Why Pod Identity wins operationally: with IRSA every role's trust policy hard-codes the cluster's
OIDC issuer URL + the exact `namespace:serviceaccount` in a `StringEquals` condition — recreate
the cluster and every trust policy breaks. Pod Identity moves that mapping OUT of IAM trust
policies and into an EKS-native association, so roles are cluster-agnostic and survive rebuilds
(critical for the cheap teardown/spin-up lifecycle).

---

## 4. Networking (VPC)

### Topology

```
                          Internet
                             |
                          +--+--+
                          | IGW |
                          +--+--+
                             |
     +-----------------------+------------------------+
     | Public subnets (3 AZ)  — ALB/NLB, single NAT   |
     +-----------------------+------------------------+
                             | (one NAT GW, AZ-a)
     +-----------------------+------------------------+
     | Private subnets (3 AZ) — EKS nodes, Karpenter  |
     +------------------------------------------------+
```

- **Module:** `terraform-aws-modules/vpc` (`~> 5.x`). 3 AZs.
- **VPC CNI:** default EKS pod networking (pods get VPC IPs). Managed as an EKS add-on (§5).
  Prefix delegation (`ENABLE_PREFIX_DELEGATION=true`) to raise pod density per node — set it if
  you hit IP exhaustion, otherwise leave default.
- **Subnet tagging is mandatory** for controllers to discover subnets:
  - Public: `kubernetes.io/role/elb = 1`
  - Private: `kubernetes.io/role/internal-elb = 1` and `karpenter.sh/discovery = <cluster>`
  The `karpenter.sh/discovery` tag is how EC2NodeClass finds where to launch nodes.

### NAT: single vs per-AZ (the big cost decision)

```
Rank  Option              ~Cost/mo   HA        Use for
1.    Single NAT GW       ~$32+data  1 AZ SPOF  portfolio / dev  ← THIS PROJECT
2.    One NAT per AZ (3)  ~$97+data  full HA    real production
```

`single_nat_gateway = true` in the VPC module. A NAT GW is ~$0.045/hr (~$32/mo) PLUS
per-GB data processing. Three of them triples the fixed cost for HA you don't need on a portfolio
cluster. Document the one-line flip to `one_nat_gateway_per_az = true` as the "production HA"
toggle — that's the whole "production-grade with a cheap path" story in a single variable.
Source: https://www.devopsschool.com/blog/aws-architect-design-decision-matrix-nat-per-az-vs-single-nat-vs-regional-nat-for-eks-environments

Optional cost/security add: **VPC gateway endpoints for S3** (free) so Loki/ECR S3 traffic
skips the NAT entirely — meaningful when Loki ships chunks to S3.

---

## 5. Core add-ons: EKS managed add-ons vs Helm

Rule of thumb: **AWS-owned cluster plumbing → EKS managed add-ons** (Terraform `addons` block on
the module). **Everything application-level → Helm via ArgoCD** (doc 02).

```
Managed EKS add-on (Terraform)        Why
------------------------------------  -----------------------------------------
vpc-cni                               core pod networking, AWS-owned
coredns                               cluster DNS, AWS-owned
kube-proxy                            kube networking, AWS-owned
aws-ebs-csi-driver                    PVCs (Prometheus/Loki/Grafana volumes)
eks-pod-identity-agent                REQUIRED for Pod Identity (§3)
metrics-server                        HPA + kubectl top (now available as add-on)

Helm via ArgoCD (doc 02)              Why
------------------------------------  -----------------------------------------
AWS Load Balancer Controller          app-level, moves fast, values-heavy
Karpenter                             Helm chart; IAM created by TF sub-module
kube-prometheus-stack / loki / otel   pure application layer (doc 03)
```

- **vpc-cni, coredns, kube-proxy, ebs-csi** ordering matters: the EKS module handles
  `before_compute`/dependency ordering so CNI is ready before nodes join. Let the module do it;
  don't split these into separate `aws_eks_addon` resources unless you need custom config.
- **AWS Load Balancer Controller:** install via **Helm** (not an EKS add-on). It's actively
  developed, values-heavy, and the community consensus is Helm > add-on for it. Give it a
  Pod Identity association (§3). Source:
  https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
- **metrics-server** is now offered as an EKS add-on — use it instead of a separate Helm chart.

---

## 6. Security baseline

```
Control                     Setting
--------------------------  --------------------------------------------------
Cluster auth                Access Entries API (authentication_mode=API or
                            API_AND_CONFIG_MAP). NO aws-auth ConfigMap editing.
Cluster admin               enable_cluster_creator_admin_permissions = true
Secrets encryption          KMS envelope encryption of K8s secrets (module:
                            create_kms_key = true / encryption_config)
Endpoint                    public for portfolio; private + SSM for "hardened"
Node IAM                    least-priv managed policies; Pod Identity for workloads
IMDSv2                      REQUIRED (http_tokens=required, hop_limit=1) so pods
                            can't steal the node role via IMDS
Node placement              private subnets only
```

### Access Entries API (replaces aws-auth ConfigMap)

The `aws-auth` ConfigMap is legacy and error-prone (one bad edit locks everyone out). The
**Access Entries API** is the 2026 standard: IAM principal → access policy mapping via the EKS
API, managed declaratively in Terraform (`access_entries` on the module). Set
`authentication_mode = "API"` (or `API_AND_CONFIG_MAP` during migration). Source:
https://oneuptime.com/blog/post/2026-02-09-eks-access-entries-authentication/view

### IMDSv2 enforcement

Node/launch-template metadata options: `http_tokens = "required"`, `http_put_response_hop_limit = 1`.
The hop limit of 1 stops a compromised pod from reaching IMDS (which sits at hop 2 from inside a
container) and assuming the node instance role — a classic EKS privilege-escalation path.

---

## 7. Cost & the cheap teardown/spin-up lifecycle

### Monthly cost floor (us-east-1, minimal always-on)

```
Rank  Line item                          ~$/mo    Notes
1.    EKS control plane                  $73      $0.10/hr, per cluster, fixed
2.    Single NAT gateway                 $32+     + per-GB data processing
3.    2x t3.medium bootstrap nodes       ~$30     on-demand; less on spot
4.    Karpenter spot workload nodes      variable scales to ~0 when idle
      EBS volumes (Prom/Loki/Grafana)    ~$5-15   gp3, small
      S3 (Loki chunks)                   ~$1-5    pennies at portfolio scale
      -----------------------------------------
      TOTAL always-on floor              ~$110-140/mo
```

**THE $438/mo TRAP:** if the cluster's Kubernetes version falls out of standard support into
**EKS extended support**, the control plane jumps from $73 to ~$438/mo. Keep `kubernetes_version`
current (upgrade before standard support ends) or you silently 6x your control-plane bill.
Source: https://cloudburn.io/blog/amazon-eks-pricing

### What makes it cheap to tear down & rebuild

1. **Single NAT, spot nodes, Karpenter consolidation** — steady-state cost is mostly the fixed
   $73 + $32; compute scales toward zero when idle.
2. **State survives teardown.** Keep Terraform state in S3 + DynamoDB lock (or HCP). `make down`
   runs `terraform destroy` → control plane + NAT + nodes gone → ~$0. `make up` rebuilds in
   ~15-20 min.
3. **Pod Identity over IRSA** (§3) — associations are cluster-agnostic, so a rebuilt cluster
   doesn't break every IAM trust policy.
4. **GitOps means the cluster is disposable.** ArgoCD re-syncs the entire app layer from Git on a
   fresh cluster (doc 02) — you only Terraform the platform, ArgoCD restores everything else.
5. **No always-on data you can't lose.** Loki→S3 chunks persist across teardown (S3 is cheap and
   survives `destroy`); in-cluster PVCs are ephemeral by design.

```
make up     →  terraform apply  (VPC, EKS, Karpenter IAM, add-ons)
            →  helm install argocd (bootstrap)
            →  ArgoCD syncs app-of-apps  →  full stack live  (~15-20 min)

make down   →  terraform destroy  →  ~$0   (S3 state + Loki chunks retained)
```

---

## Sources

- terraform-aws-eks releases — https://github.com/terraform-aws-modules/terraform-aws-eks/releases
- terraform-aws-eks README (v21, k8s 1.33 example) — https://github.com/terraform-aws-modules/terraform-aws-eks
- Karpenter 1.0 GA — https://aws.amazon.com/blogs/containers/announcing-karpenter-1-0
- Karpenter NodePools — https://karpenter.sh/docs/concepts/nodepools/
- Auto Mode vs Karpenter — https://repost.aws/articles/ARpmjGWmwWQuiGg3_NOnfLDg/eks-automode-vs-karpenter
- EKS Access Entries — https://oneuptime.com/blog/post/2026-02-09-eks-access-entries-authentication/view
- EKS add-ons w/ Terraform — https://oneuptime.com/blog/post/2026-02-09-eks-addons-coredns-vpc-cni-terraform/view
- AWS LB Controller install — https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
- NAT cost matrix — https://www.devopsschool.com/blog/aws-architect-design-decision-matrix-nat-per-az-vs-single-nat-vs-regional-nat-for-eks-environments
- EKS pricing / extended-support trap — https://cloudburn.io/blog/amazon-eks-pricing
