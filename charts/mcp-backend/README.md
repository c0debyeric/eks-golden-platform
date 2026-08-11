# mcp-backend chart

Deploys the API-key service: an Express REST API plus an MCP endpoint, backed by
RDS PostgreSQL.

Rendered per environment by the ApplicationSet in
`gitops/bootstrap/mcp-backend.yaml`, which supplies
`gitops/apps/mcp-backend/values-<env>.yaml` through Argo CD's multi-source
`$values` reference. The chart is never installed with its own defaults alone —
several values are deliberately unset so that an unconfigured environment fails
to render instead of quietly starting up wrong.

## Values that MUST be set per environment

These have no default and are wrapped in `required`. Each one guards a failure
that is silent rather than loud.

| Value | Guards against |
| --- | --- |
| `image.tag` / `image.digest` | An environment inheriting a plausible-looking default tag and running something nobody promoted. |
| `environment` | Two environments reporting the same telemetry tag, so production signal is diluted by pre-production noise. |
| `database.schema` | **Data leaking across environments.** All three point at one RDS database; a shared schema means a shared `api_keys` table. |

`scripts/helm_values_gate.py` enforces the same invariants in CI and additionally
rejects two environments claiming the same `environment` or the same
`database.schema`.

## Values reference

| Key | Default | Notes |
| --- | --- | --- |
| `replicaCount` | `1` | dev 1, stage 2, prod 3. |
| `image.repository` | ECR repo URL | Repository is Terraform-managed (`terraform/ecr.tf`). |
| `image.tag` | *(required)* | 12-char git SHA. |
| `image.digest` | *(required)* | Rendered as `repo:tag@sha256:…` so the tag stays readable while the digest pins the bytes. |
| `environment` | *(required)* | `dev` \| `stage` \| `prod`. |
| `service.port` | `80` | ClusterIP only — never exposed directly. |
| `database.secretsManagerKey` | `eks-golden/rds-master` | Read by External Secrets Operator. |
| `database.secretName` | `mcp-backend-db` | Kubernetes Secret ESO writes. |
| `database.schema` | *(required)* | Postgres schema this environment owns. |
| `database.sslMode` | `"true"` | TLS to RDS, verified against the CA bundle baked into the image. |
| `database.poolMax` | `5` | Keep low: `db.t4g.micro` has few connections and there are three environments plus replicas. |
| `podDisruptionBudget.enabled` | `false` | Off in dev: `minAvailable: 1` on a single replica blocks eviction outright and deadlocks Karpenter consolidation. |
| `podDisruptionBudget.minAvailable` | `1` | Chart fails to render if `>= replicaCount`. |
| `resources` | small | prod raises the memory ceiling; the default is sized for an idle pod. |

## What it renders

| Template | Purpose |
| --- | --- |
| `deployment.yaml` | Non-root, `readOnlyRootFilesystem`, probes, OTLP + Postgres env, topology spread across zones. |
| `service.yaml` | ClusterIP `:80 → :8080`. |
| `pdb.yaml` | Optional PodDisruptionBudget. |
| `externalsecret.yaml` | Projects the RDS credentials into the namespace. |

## Details worth knowing

**`checksum/db-externalsecret` annotation.** The pod template carries a hash of
the ExternalSecret spec, so a credential rotation rolls the Deployment rather
than leaving pods holding a stale password until something else restarts them.

**Liveness is deliberately database-independent.** `/healthz` does not touch
Postgres; only `/readyz` does. If liveness checked the database, a normal ~2
minute Multi-AZ failover would restart every replica and turn a brief outage into
a CrashLoopBackOff.

**`selectorLabels` excludes volatile labels.** A Deployment's selector is
immutable, so anything that can change between releases — `app.kubernetes.io/version`
and friends — must stay out of it or the next upgrade fails to apply.

**`external-secrets.io/v1`, not `v1beta1`.** The older API stopped being served
in ESO 2.8, and the failure message is the unhelpful "one or more synchronization
tasks are not valid".

## Rendering it yourself

```bash
helm template mcp-backend charts/mcp-backend \
  -f gitops/apps/mcp-backend/values-dev.yaml

# all environments, both charts, plus the gates:
make app-render
```
