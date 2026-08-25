# 04 — Multi-Environment Promotion (dev → stage → prod on ONE cluster)

> **PARTIALLY SUPERSEDED (2026-08-09) — read this as a decision record, not as current layout.**
> The namespace-per-environment decision, the sync-wave ordering and the promotion model below
> all still hold and are still what the repo does. The **rendering mechanism does not**: the
> `base/` + `overlays/{dev,stage,prod}` kustomize layout described here was replaced by Helm
> charts in `charts/mcp-backend` and `charts/mcp-frontend`, with per-environment values files in
> `gitops/apps/<app>/values-<env>.yaml` supplied via ArgoCD's multi-source `$values` reference.
> `scripts/kustomize_overlay_gate.py` became `scripts/helm_values_gate.py`, which enforces the
> same invariants (pinned digest, no placeholders, unique environment, PDB sanity) plus a render
> check. Reason for the change: a second workload (`mcp-frontend`) arrived, and duplicating an
> eleven-file overlay tree per app is exactly the copy-paste that a chart's values files exist to
> avoid. Everything below is preserved as written for the reasoning, including §6's field-name
> trap, which is why the values files still pin tag *and* digest.

> Golden-standard research + design for turning this single-environment platform into a THREE
> ENVIRONMENT platform without buying a second or third cluster, and for automating the
> `dev → stage → prod` promotion that today does not exist at all. Platform (EKS) is doc 01,
> the GitOps delivery layer is doc 02, observability is doc 03. **Research date: 2026-07-29.**

> **DECISION IS FIXED, NOT UNDER REVIEW:** `dev`, `stage` and `prod` are three **NAMESPACES** on
> the one existing `eks-golden` cluster (`us-east-1`, account `810749429738`). This document does
> not evaluate cluster-per-environment as an option; it specifies how to do namespace-per-env
> *well*, and it is explicit and unsentimental about what that costs you (§7, Accepted risks).
> The honest one-line summary of the tradeoff: **namespace-per-env buys you ~$220/mo and one
> control plane to patch, and it sells you cluster-scoped isolation — CRDs, webhooks, node
> capacity and the Karpenter/ESO failure modes that took this cluster down TODAY.**

---

## 0. TL;DR

```
                        ONE cluster: eks-golden (us-east-1)
+---------------------------------------------------------------------------------+
|  PLATFORM LAYER  — single instance, NOT per-env, cluster-scoped                  |
|  argocd | kube-system(alb) | cert-manager | external-secrets | karpenter         |
|  monitoring | logging | tracing | observability     <- shared by all three envs  |
|  ^ CRDs + webhooks live HERE and are GLOBAL. This is the whole risk (§7.1).      |
+---------------------------------------------------------------------------------+
|  APPLICATION LAYER — per-env namespaces, identical manifests, different values   |
|   ns: dev             ns: stage            ns: prod                              |
|   mcp-backend-dev     mcp-backend-stage    mcp-backend-prod   <- ArgoCD Apps     |
|   1 replica           2 replicas           3 replicas + strict PDB              |
|   auto-promote        auto-promote         PR-gated promotion                    |
+---------------------------------------------------------------------------------+

Git:   gitops/apps/mcp-backend/{base,overlays/{dev,stage,prod}}   (kustomize, dirs NOT branches)
Fan-out: ONE ApplicationSet (list generator) replaces 3 hand-written Applications
Promote: GitHub Actions `promote.yml` -> resolves ECR digest -> rewrites target overlay
         -> opens PR into main. Kargo is the documented upgrade path (§5).
```

**Ranked promotion tooling in §5. #1 for THIS repo today is PR-based GitHub Actions
promotion (SHIPPED, PR #17); Kargo v1.11.0 is #1 on capability and is the recommended
next step if/when promotion volume justifies a dedicated controller.**

**The single most important gap this closes:** `.github/workflows/build-image.yml` builds and pushes
an immutable SHA-tagged image and then *prints a job summary asking a human to hand-edit
`deployment.yaml`*. Nobody did, which is why `mcp-backend` had been sitting in
`InvalidImageName` on the literal string `REPLACE_WITH_GIT_SHA`. A build pipeline whose last
step is "please remember to do the deploy manually" is not a pipeline; it is a TODO with YAML.

**Status: IMPLEMENTED.** PRs #16–#20 merged 2026-07-29. `mcp-backend-dev` is `Synced`/`Healthy`
serving HTTP 200, `mcp-backend-prod` is deliberately `OutOfSync`/`Missing` (manual gate working).

---

## 1. Why namespaces here, and what "environment" actually means on one cluster

The user decision is namespace-per-env. That decision is defensible **for this repo's specific
purpose** and it helps to say why precisely, because the reason bounds the mitigations in §7:

| Property | Namespace-per-env (chosen) | What you give up |
| --- | --- | --- |
| Control-plane cost | 1 × $73/mo | — |
| Node capacity | one Karpenter pool, bin-packed across envs | dev can evict prod pods under pressure |
| CRDs / API versions | **shared, cluster-scoped** | dev cannot test a CRD bump ahead of prod (§7.1) |
| Admission webhooks | shared | a broken webhook breaks all three envs at once |
| RBAC | namespace-scoped, works well | cluster-scoped resources can't be split |
| Network isolation | NetworkPolicy (must be authored, §7.2) | not default-deny out of the box |
| Teardown lifecycle | `make down` still nukes everything for ~$0 | — |
| Reviewer legibility | one cluster, one ArgoCD UI, one story | doesn't demonstrate multi-cluster fan-out |

AWS's own EKS multi-tenancy guidance frames exactly this as *soft multi-tenancy*: namespaces plus
RBAC, quotas and NetworkPolicy give you administrative and workload separation, but **not** a
security boundary and **not** isolation of cluster-scoped resources. That is the correct mental
model for dev/stage/prod-as-namespaces: these are three *deployment targets*, not three
*blast-radius domains*. Design accordingly — treat prod's blast radius as "the cluster."
Source: https://docs.aws.amazon.com/eks/latest/best-practices/multitenancy.html

### 1.1 Namespace names and what goes in them

```
dev        mcp-backend (1 replica)        promotion target of Kargo Stage "dev"
stage      mcp-backend (2 replicas)       promotion target of Kargo Stage "stage"
prod       mcp-backend (3 replicas)       promotion target of Kargo Stage "prod"
```

The existing `application` namespace is **retired** by this design (migration step 6, §8). Keeping
it would leave a fourth, unowned copy of the workload running with `selfHeal: true`, silently
serving traffic from an image nobody is promoting anymore.

---

## 2. Directories, not branches (the one pattern choice that is non-negotiable)

Before any tooling: environments are **directories** in `main`, never long-lived
per-environment branches.

| Approach | Verdict |
| --- | --- |
| `overlays/{dev,stage,prod}` directories on `main` | ✅ **USE THIS** |
| Long-lived `dev`/`stage`/`prod` branches, promote by merge | ❌ documented anti-pattern |
| Separate repo per environment | ❌ triples review surface, guarantees drift |

Branch-per-environment fails for a well-catalogued reason: promotion becomes `git merge`, so
**environment-specific config becomes a permanent merge conflict**. A one-replica dev and a
three-replica prod means `replicas:` conflicts on every single promotion, forever. Teams then
resort to cherry-picking, which decouples the branches, and now no branch is a description of any
environment. Directories make the diff between environments *readable in one `diff -r`* and make
promotion a change to ONE file in ONE branch.
Source: https://codefresh.io/blog/stop-using-branches-deploying-different-gitops-environments/

One nuance worth stating because Kargo's own examples show branches: Kargo's `git-push` +
`git-open-pr` pattern often pushes *rendered* manifests to a `stage/<env>` branch. That is the
"rendered manifests" pattern, which is a different thing from branch-per-env — the branch holds
machine-generated output, not human-edited config. **This design deliberately does NOT use it**
(§5): it opens a PR against `main` that edits one overlay file, because a human-reviewable
one-line diff is worth more in a portfolio repo than a rendered-manifest branch nobody reads.

---

## 3. The per-environment layout

This section describes what is now IMPLEMENTED and merged (PR #17), not a proposal.
`gitops/apps/mcp-backend/` holds an env-agnostic `base/` plus three populated overlays.

```
gitops/
├── bootstrap/                          # root app-of-apps target (unchanged)
│   ├── ...12 platform Applications...  # single-instance, NOT per-env  <- see §7.1
│   └── mcp-backend.yaml                # REPLACED in place: was 1 Application,
│                                       # is now 1 ApplicationSet -> 3 Applications (§4)
└── apps/
    └── mcp-backend/
        ├── base/                       # env-agnostic manifests + kustomization
        │   ├── kustomization.yaml
        │   ├── deployment.yaml          # no namespace, image = PLACEHOLDER_IMAGE
        │   ├── service.yaml
        │   └── pdb.yaml
        └── overlays/
            ├── dev/kustomization.yaml
            ├── stage/kustomization.yaml
            └── prod/kustomization.yaml
```

The base is deliberately NOT applyable on its own: `namespace:` is stripped from all three
manifests and the image is the sentinel `PLACEHOLDER_IMAGE`. If someone re-adds a namespace
to the base, all three envs collapse into one and prod is overwritten by dev's next sync —
so `scripts/helm_values_gate.py` asserts against exactly that (§6).

Env deltas as shipped:

| | dev | stage | prod |
|---|---|---|---|
| namespace | `mcp-dev` | `mcp-stage` | `mcp-prod` |
| replicas | 1 | 2 | 3 |
| PDB | **deleted** | `minAvailable: 1` | `minAvailable: 2` |
| memory limit | 192Mi | 192Mi | 384Mi |
| syncPolicy | automated | automated | **none (manual gate)** |

Each delta has a reason, not a preference:

- **dev deletes the PDB.** A `minAvailable: 1` PDB on a single-replica Deployment blocks
  voluntary eviction outright, so Karpenter consolidation and node drains stall forever
  waiting for a second pod that never exists. Dev is also the env you most want Karpenter
  free to bin-pack and recycle, so the PDB is removed rather than tuned.
- **stage keeps 2 replicas + PDB** because it is a production *rehearsal*. A single-replica
  stage cannot surface rolling-update readiness gaps or PDB/drain deadlocks — precisely the
  defects worth catching before prod.
- **prod runs 3 replicas** because `topologySpreadConstraints` uses `ScheduleAnyway`
  (best-effort), so replica *count* carries the real AZ redundancy; and `minAvailable: 2`
  stops a drain evicting two at once and collapsing capacity to a single pod.

Env-specific values are applied as strategic-merge patches keyed by env var **name**, not
JSON patches on `/env/3` and `/env/5`. Positional indices silently retarget the wrong
variable the moment anyone reorders or inserts an env var in the base; Kubernetes merges
container `env` by the `name` key, so a name-keyed patch stays correct regardless of order.

Why kustomize and not three Helm values files: `mcp-backend` is plain manifests, not a chart.
Introducing a chart purely to get values templating adds a chart version to maintain and a
rendering step to debug for exactly one workload. ArgoCD renders kustomize natively with no
config-management plugin, and the `kubectl` on this box already ships kustomize v5.5.0, so
`kubectl kustomize gitops/apps/mcp-backend/overlays/prod` produces byte-identical output locally,
in CI, and in the repo-server. For the *platform* Helm charts, the existing multi-source
`$values` pattern from doc 02 §4 stays exactly as it is.
Sources: https://argo-cd.readthedocs.io/en/stable/user-guide/helm/ ,
https://octopus.com/blog/helm-values-argocd

> **Field-name trap, found by rendering rather than by reading docs.** The kustomize field
> for a digest is `digest:`, **not** `newDigest:`. Using the latter fails the whole render
> with `error: invalid Kustomization: json: unknown field "newDigest"`. This was caught
> before shipping only because the overlay was actually rendered; on release notes alone
> every promotion PR would have failed at render time. With `newTag` + `digest` both set,
> kustomize emits `repo:tag@sha256:…` — the tag stays human-readable while the digest is
> authoritative.

---


## 4. Fan-out: one ApplicationSet, three Applications

`gitops/bootstrap/mcp-backend.yaml` was a single `Application`. It is now a single
`ApplicationSet` that generates three. The file path is unchanged, so the existing `root`
app-of-apps (`path: gitops/bootstrap`, `recurse: true`) discovers it with no Terraform change.

**Why an ApplicationSet and not three hand-written Applications.** The three envs differ in
exactly four values: namespace, overlay path, sync wave, and syncPolicy. Three near-identical
30-line manifests is how `syncOptions` on one env silently drifts from the others — and a
missing `ServerSideApply` or `CreateNamespace` surfaces only at sync time as the famously
unhelpful `one or more synchronization tasks are not valid`, which names neither the resource
nor the field.

**Why the `list` generator and not `git` directory.** A directory generator auto-discovers
`overlays/*` and would create a real, syncing Application for *any* new directory. For
environments that is a footgun: an experimental overlay committed for local testing would
self-deploy to the cluster. The list is explicit — three envs, reviewed, no surprises.
Source: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-List/

**Why `templatePatch` instead of an inline conditional.** The prod gate needs the
`automated:` block *absent*, not set to false. A `{{- if }}` wrapped around a mapping key
makes the file invalid YAML on disk — unreviewable, and rejected by any linter or
`kubectl --dry-run`. `templatePatch` applies after the template renders, so the committed
file stays parseable:

```yaml
  # dev and stage get automated sync; prod deliberately gets NO `automated` block.
  # WHY: auto-syncing prod makes `git merge` and `deploy to production` the same
  # irreversible action, removing the last checkpoint before customer traffic moves.
  # selfHeal off also means an emergency kubectl mitigation is not reverted out from
  # under the operator mid-incident.
  templatePatch: |
    {{- if ne .env "prod" }}
    spec:
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
    {{- end }}
```

`goTemplateOptions: ["missingkey=error"]` is set so a typo'd key fails the generator loudly
instead of rendering an empty string into a namespace or path field.

**Verified before relying on it**, because both fields are relatively recent additions:

```
kubectl get crd applicationsets.argoproj.io -o json
  -> spec.templatePatch       present: True
  -> spec.goTemplateOptions   present: True
kubectl apply --dry-run=server   -> applicationset.argoproj.io/mcp-backend created
applied live                     -> mcp-backend-dev / -stage / -prod generated
                                    automated = YES / YES / NO  (as designed)
```

Sync waves are 5/6/7 (dev/stage/prod). Wave 5 preserves the pre-split ordering — after
`otel-operator` (wave 2) and the gateway collector (wave 3) — so the OTLP endpoint exists
before any app pod starts and no telemetry is dropped on cold start.

**Progressive Syncs were considered and deliberately NOT used.** They gate one Application
group on the previous group becoming Healthy, which sounds like promotion but is not: it
sequences a *single* sync operation, and it would couple prod's rollout to stage's health
inside ArgoCD. Promotion here is a deliberate, auditable Git change (§5), not an automatic
cascade. Using Progressive Syncs would quietly re-introduce "merge == deploy to prod".
Source: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/

---

## 5. Ranked promotion tooling

Scored for *this* repo: one workload, one cluster, a solo maintainer, and a public
portfolio audience. Weighting is deliberate — "how much does this cost me to keep alive"
counts as heavily as capability, because an unmaintained promotion controller is worse
than a boring workflow that still runs.

| # | Approach | Maturity | Ops cost | $ | Verdict for this repo |
|---|---|---|---|---|---|
| **1** | **GitHub Actions PR-based** (`promote.yml`) | Stable | **None** — reuses existing CI | $0 | **SHIPPED.** Zero new infra, reuses the OIDC role + digest capture already present |
| 2 | **Kargo** v1.11.0 | GA since v1.0.0 (2024-10-19), Apache-2.0 | Controller + CRDs in-cluster | $0 self-hosted / $495+/mo managed | **Best capability.** Real Freight/Stage model, `git-open-pr` step. The upgrade path once >1 app |
| 3 | **argocd-image-updater** v1.2.2 | Maintained (pushed 2026-07-28) | Controller in-cluster | $0 | Wrong tool: it *auto-tracks* new images, which is the opposite of a gate |
| 4 | **Argo Rollouts** | Stable | Controller + CRDs | $0 | Solves a different problem — progressive delivery *within* one env, not across envs. Complementary, not a substitute |
| 5 | **Flux image automation** | Stable | Second GitOps engine | $0 | Would mean running Flux alongside ArgoCD. Rejected outright |
| — | **Environment branches** | n/a | n/a | n/a | **Anti-pattern.** See §2 |

### Why #1 beats #2 *today*

Kargo is genuinely the better tool and it is not close on capability — Warehouses discover
artifacts, Freight is a first-class promotable unit, Stages model the pipeline explicitly,
and `git-open-pr` does exactly what `promote.yml` hand-rolls. It is Apache-2.0, GA for ~21
months, and free self-hosted.

It is still #2 here for one reason: **it adds a controller and a CRD group to a cluster whose
two outages today were both caused by controller/CRD skew.** Kargo's CRDs would be
cluster-scoped, shared by all three namespaces, and subject to the same upgrade hazard
documented in §7.1. Paying that risk to orchestrate *one* workload's promotion is a bad
trade. `promote.yml` needs no runtime, cannot skew, and cannot break the cluster.

**Revisit when any of these becomes true:**
- more than ~3 workloads need promotion (the workflow stops scaling by copy-paste)
- promotion needs verification steps (smoke tests, metric checks) between stages
- more than one person is promoting and you want a UI + audit trail
- you want auto-promotion to dev on artifact discovery rather than on git push

### What `promote.yml` actually does

```
workflow_dispatch(from, to)
  -> reject any hop that is not dev->stage or stage->prod
  -> read source overlay's newTag from Git        (promote what is RUNNING, not "latest")
  -> aws ecr describe-images -> resolve digest    (assert the image really exists)
  -> yq: set newTag + digest on target overlay    (field is `digest`, NOT `newDigest`)
  -> kubectl kustomize + overlay gate             (fail BEFORE a PR is opened)
  -> peter-evans/create-pull-request@v8           (the audit trail and the human gate)
```

**Why it never rebuilds.** A rebuild produces a different image for the same source, so what
was validated in dev would not be what reaches prod. Promotion copies an existing ECR
reference, so the artifact is byte-identical to the tested one — which is the entire point.

**Why by digest even though ECR tags are already immutable.** Tag immutability prevents a tag
being *repointed*; it does not make the tag a content address. A digest is the artifact
identity, so `kubectl describe` in prod proves byte-for-byte that prod runs the bits that
passed dev, with no trust in the registry's tag bookkeeping. `build-image.yml` already
captures `steps.build.outputs.digest` — the value was free and was being thrown away into a
job summary.

**Why one hop at a time.** `workflow_dispatch` choice inputs cannot express a relation
*between* two inputs, so `dev -> prod` is selectable in the UI. It is rejected in the first
step; skipping stage defeats the gate.

> **Pin a multi-arch INDEX digest, never a per-arch child.** The manifest index
> (`application/vnd.oci.image.index.v1+json`) is what lets the kubelet pick the right variant
> per node. Pinning one of its child digests hard-codes a single architecture and silently
> reintroduces the Graviton crash loop in §6.

Sources: https://docs.kargo.io/user-guide/core-concepts/ ,
https://docs.kargo.io/user-guide/reference-docs/promotion-steps/git-open-pr/ ,
https://codefresh.io/blog/stop-using-branches-deploying-different-gitops-environments/

---

## 6. CI gates added, and the bugs that justified each

Every gate below was written *because a real defect got through*, and every one was verified
by **injecting the defect and confirming exit 1** — not merely by passing on a clean tree. A
gate that has only ever passed is not evidence of anything.

| Gate | Catches | Proven by |
|---|---|---|
| `kustomize_overlay_gate.py` | two overlays claiming one namespace; committed placeholder image; unapplied env patch | 3 injected defects, each exit 1 with a specific message |
| `build_arch_gate.py` | build platforms not covering every arch the NodePool may provision | injected `platforms: linux/amd64` -> exit 1 naming `linux/arm64` |

### 6.1 Why the namespace-collision check exists

Two overlays naming the same namespace is **silent**. Both Applications are individually
valid, both render, both report `Synced` — and the later sync simply overwrites the earlier
env's workloads in place. There is no error anywhere. Dev quietly redeploying over prod is
the single worst outcome available in a namespace-per-env design, so it gets an explicit
assertion rather than a code-review convention.

### 6.2 Why the placeholder check exists

The base carries the sentinel `PLACEHOLDER_IMAGE` so a mistyped overlay fails loudly. But
nothing stopped that sentinel from being *committed in an overlay* — which is exactly the
failure that had `mcp-backend` stuck in `InvalidImageName` on the literal string
`REPLACE_WITH_GIT_SHA`. `kubectl kustomize` exits 0 on it; the render succeeds and the
*content* is wrong. Hence a content assertion.

### 6.3 Why the architecture gate exists (the nastiest bug of the day)

The NodePool intentionally allows `kubernetes.io/arch In [amd64, arm64]` to pick up cheaper
Graviton capacity, and the Deployment sets no `nodeSelector` — so either arch is a legal
placement. The image was built `linux/amd64` only. The result:

```
exec /usr/local/bin/docker-entrypoint.sh: exec format error
```

Why this is worse than it looks:

- **No `ImagePullBackOff`.** The image pulls perfectly; it dies at `exec`.
- The message reads like a corrupt entrypoint or bad base image, so it sends you into the
  Dockerfile instead of the workflow.
- **It only reproduces when the scheduler happens to pick ARM.** It can pass CI, pass a dev
  deploy, then fail hours later when a Karpenter consolidation relocates the pod onto
  Graviton. Observed live on an `m9gd.medium` node.

The two halves of that contract live in different files (`platforms:` in a workflow, the arch
requirement in a NodePool) and nothing linked them. Now `build_arch_gate.py` does. It treats
an **absent** arch requirement as "both", because the permissive case is precisely the one
that breaks a single-arch image.

Fix chosen: build multi-arch (`linux/amd64,linux/arm64` + QEMU), **not** pinning the
Deployment to amd64. Pinning is a one-line fix that forfeits the cheaper Graviton capacity
the NodePool was explicitly configured to use — trading money for convenience.

### 6.4 A race the idempotency check could not cover

`build-image.yml` checks "does this tag already exist in ECR?" before building. That check is
necessary but **not sufficient**: it is check-then-act with a ~3-minute window, and ECR tags
here are IMMUTABLE. Two runs for the same commit (a merge push plus a manual dispatch) both
passed the check, both built, and the loser died:

```
failed to push ...:mcp-backend:a7b96ed603df: unknown: The image tag 'a7b96ed603df'
already exists in the 'mcp-backend' repository and cannot be overwritten because
the tag is immutable
```

Fixed with a per-SHA `concurrency` group. `cancel-in-progress` is deliberately **false**: the
in-flight run may already be mid-push, and cancelling it could leave a partially exported
manifest in ECR. Queueing lets the second run reach the existence check and skip cleanly —
the behaviour that check was written for.

---

## 7. Accepted risks

### 7.1 The big one: CRDs and webhooks are CLUSTER-SCOPED

**dev cannot rehearse a platform upgrade for you. Structurally cannot.** CustomResource
Definitions, admission/conversion webhooks, the Karpenter controller, cert-manager, ESO and
the whole observability stack are single-instance and cluster-wide. A `mcp-dev` namespace
shares all of them with `mcp-prod`. There is no version of namespace-per-env in which this is
not true.

This is not a theoretical concern. Both outages on 2026-07-29 were cluster-wide by nature:

1. **Karpenter controller/CRD skew.** The chart bumped the controller 1.0.8 -> 1.14.0, but
   Helm never manages `crds/`, so the CRDs stayed old and *every* NodeClaim was rejected with
   `spec.requirements[6].operator: Unsupported value: "Gte"`. Zero capacity provisioned,
   cluster-wide.
2. **ESO v1 vs v1beta1.** Chart 2.8.0 serves only `external-secrets.io/v1`, the live CRDs
   served `v1beta1`, and a stale `v1beta1` conversion webhook made every sync fail. The
   controller `CrashLoopBackOff`'d, cluster-wide.

Neither would have been caught by "test it in dev first", because dev *is* prod for these
objects.

**Mitigations, in force:**

- **Platform components are single-instance and are NEVER promoted per-env.** Only app
  workloads flow dev -> stage -> prod. There is no `overlays/dev` for Karpenter. This is the
  primary control and it is why the blast radius stays bounded to "one shared platform" rather
  than "three divergent platforms on one cluster".
- **Chart bumps are gated in CI before merge**, not validated by a dev deploy:
  `crd_apiversion_gate.py` (is the committed CR's apiVersion actually served by the pinned
  chart?) and `crd_schema_gate.py` (do the committed field *values* satisfy the pinned chart's
  CRD `enum` constraints? — this is what would have caught `operator: Gte`).
- **`skipCrds: false` + `ServerSideApply=true`** on charts shipping CRDs in `crds/`, so ArgoCD
  manages CRDs in lockstep with the controller pin.
- **Accepted residual risk:** a chart bump can still break the cluster in a way no static gate
  predicts. The honest mitigation is a throwaway `kind` cluster in CI that installs the pinned
  chart and applies the committed CRs — **not implemented**, and the largest remaining gap in
  this design. Logged as a to-do rather than pretended away.

### 7.2 Smaller accepted risks

| Risk | Why accepted |
|---|---|
| Node capacity is shared, so a dev load test can starve prod | Karpenter scales on demand; ResourceQuotas per namespace are the fix if it ever bites. Not pre-optimised |
| One ArgoCD instance is a single point of failure for all three envs | Already true pre-split; splitting ArgoCD per env is a much larger change than this buys |
| No NetworkPolicy between namespaces, so dev can reach prod Services | Cluster has no CNI policy enforcement configured yet. Real gap, tracked separately |
| Prod's manual sync needs the ArgoCD UI/CLI | Deliberate friction, but deserves a one-click release job |
| `default` AppProject grants all three envs identical RBAC | A per-env AppProject with destination restrictions is the correct hardening and is not yet done |

The $ saving that buys all of this: roughly **$220/mo** and two fewer control planes to patch
versus cluster-per-env. That is a defensible trade for a portfolio platform with one workload;
it would not be defensible for a regulated production system with real customers in prod.

---

## 8. Migration path (as executed)

Recorded as run, so it can be replayed or reversed. Each step was one reviewable PR.

| Step | Action | PR |
|---|---|---|
| 1 | Bump stale action pins in `build-image.yml` (`checkout@v4`->`v7`, `configure-aws-credentials@v4`->`v6`, buildx/build-push majors) | #16 |
| 2 | `git mv` the three manifests into `base/`, strip `namespace:`, replace the image with `PLACEHOLDER_IMAGE`, sentinel the OTel env values | #17 |
| 3 | Write `overlays/{dev,stage,prod}/kustomization.yaml` with per-env namespace, replicas, PDB, memory, telemetry identity | #17 |
| 4 | Replace `gitops/bootstrap/mcp-backend.yaml` in place: one `Application` -> one `ApplicationSet` + `templatePatch` prod gate | #17 |
| 5 | Add `kustomize_overlay_gate.py` and wire into `gitops-contract` | #17 |
| 6 | Add dev write-back to `build-image.yml` + new `promote.yml`; widen workflow permissions to `contents: write` + `pull-requests: write` | #17 |
| 7 | Seed dev with a real ECR digest to validate the pipeline end-to-end against the live cluster | #18 |
| 8 | Multi-arch build + QEMU + `build_arch_gate.py` (found by step 7 crash-looping on Graviton) | #19 |
| 9 | Per-SHA `concurrency` group; re-pin dev to the multi-arch **index** digest | #20 |

The old single `mcp-backend` Application was pruned automatically by the `root` app once step 4
merged — no manual deletion, because `prune: true` was already set on the root.

### Verification performed after migration

```
kubectl get applications -n argocd
  mcp-backend-dev     Synced      Healthy       <- 1/1 Running
  mcp-backend-stage   OutOfSync   Progressing   <- placeholder tag, awaiting first promotion
  mcp-backend-prod    OutOfSync   Missing       <- CORRECT: manual gate, will not self-deploy

pod scheduled on ip-10-20-25-7 (m9gd.medium, arm64)  <- the node that was crash-looping
curl http://mcp-backend.mcp-dev.svc/readyz  -> HTTP 200
terraform plan -> No changes. Your infrastructure matches the configuration.
```

`mcp-backend-prod` reporting `Missing` is the design working, not a failure: its Application has
no `automated` block, so it will not deploy until a promotion PR is merged and a human syncs.

### Remaining work

1. ~~First real promotion run (`dev -> stage`)~~ — **DONE**, see §10. Required two repo
   setting changes documented in §9.
2. **Ephemeral `kind` cluster in CI** for chart-bump validation — the honest fix for §7.1.
3. **One-click prod release job** so the manual gate does not require the ArgoCD UI.
4. **Per-env AppProject** with destination restrictions instead of shared `default`.
5. **NetworkPolicy** between the three app namespaces.
6. Reconcile docs 01–03, which still describe the single-environment topology.

---

## 9. Repository settings the promotion pattern REQUIRES

Neither of these is code, both block promotion completely, and both fail with messages that
sound like a workflow bug. Recorded because the first live run of `promote.yml` hit both.

### 9.1 Allow Actions to create pull requests

The promotion workflow's final step failed with:

```
GitHub Actions is not permitted to create or approve pull requests.
```

Every prior step had succeeded — the digest was resolved, the overlay rewritten, the gate
passed, the branch pushed. Only PR creation was refused. The repo default was:

```json
{ "default_workflow_permissions": "read", "can_approve_pull_request_reviews": false }
```

Fix (also settable in Settings -> Actions -> General -> Workflow permissions):

```bash
gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
```

`default_workflow_permissions` is deliberately left at **read**. Both workflows declare their
own `permissions:` block explicitly, so widening the repo-wide default would grant write to
every workflow for no benefit.

### 9.2 Approve workflows on Actions-authored PRs

CI on the promotion PR sat at `action_required` with only GitGuardian reporting. GitHub does
not auto-run workflows on PRs opened by Actions — the run is created but held:

```
completed  action_required  terraform  pull_request  30460481683  0s
```

This is a deliberate GitHub anti-abuse control, not a misconfiguration, and it means **a
promotion PR needs one click before its own gates run**. Approve with:

```bash
gh api -X POST repos/<owner>/<repo>/actions/runs/<run-id>/approve
```

Once approved, `lint` and `gitops-contract` (including both new overlay gates) ran and passed
normally. This friction is arguably a feature for a *prod* promotion; for `dev -> stage` it is
pure noise, and it is the strongest practical argument for Kargo (§5) if promotion frequency
ever rises — Kargo promotes from inside the cluster and does not depend on Actions being
allowed to author PRs.

---

## 10. First live promotion: verified end to end

`dev -> stage`, run 30460437938, PR #22, merged 2026-07-29.

```
Source dev is pinned to tag: a7b96ed603df
Resolved a7b96ed603df -> sha256:feeeae5e3c0764a2d79f34bbac1150c568a0f0e93c102f01d341b2631bd75761
--- resulting images: block ---
  newTag: a7b96ed603df
  digest: sha256:feeeae5e...
PASS: overlay 'dev'   -> namespace 'mcp-dev'
PASS: overlay 'stage' -> namespace 'mcp-stage'
PASS: overlay 'prod'  -> namespace 'mcp-prod'
```

Post-merge cluster state:

| Application | Sync | Health | Replicas | Notes |
|---|---|---|---|---|
| `mcp-backend-dev` | Synced | Healthy | 1/1 | `/readyz` -> HTTP 200 |
| `mcp-backend-stage` | Synced | Healthy | 2/2 | `/readyz` -> HTTP 200 |
| `mcp-backend-prod` | OutOfSync | Missing | 0 | **correct** — manual gate, awaits promotion + human sync |

**The property that matters**, checked directly against the running Deployments rather than
inferred from the diff:

```
mcp-dev   image digest: sha256:feeeae5e3c0764a2d79f34bbac1150c568a0f0e93c102f01d341b2631bd75761
mcp-stage image digest: sha256:feeeae5e3c0764a2d79f34bbac1150c568a0f0e93c102f01d341b2631bd75761
```

Identical. Stage is running the *same bytes* dev validated — no rebuild, no tag ambiguity.
That is the entire point of the pipeline, and it is now demonstrated rather than asserted.

One cosmetic wart: `yq -i` strips blank lines between top-level blocks in the rewritten
overlay. All WHY-comments survive (verified: zero comment lines removed in the PR #22 diff),
only vertical whitespace is lost. Not worth a `yq` wrapper or a formatter step for a
two-line diff, but noted so the next reader does not mistake it for accidental damage.
