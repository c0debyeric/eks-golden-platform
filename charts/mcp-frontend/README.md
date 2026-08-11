# mcp-frontend chart

Deploys the Next.js UI and its public ALB Ingress. This is the only
internet-facing workload on the platform.

Rendered per environment by the ApplicationSet in
`gitops/bootstrap/mcp-frontend.yaml`, using
`gitops/apps/mcp-frontend/values-<env>.yaml` via Argo CD's multi-source
`$values` reference. Sync waves are 6/7/8 — one behind the matching backend, so
the frontend's first server render has something to call instead of emitting a
burst of 502s that looks like a frontend defect.

## Values that MUST be set per environment

| Value | Guards against |
| --- | --- |
| `image.tag` / `image.digest` | Running an image nobody promoted. |
| `backend.url` | Falling back to the chart default and pointing at **another environment's** backend. Always namespace-qualified. |
| `ingress.groupName` (when the Ingress is enabled and no `host` is set) | Two environments merged onto one ALB listener, where rule ordering rather than intent decides which one a visitor reaches. |

The chart calls `fail` on the last of these, and `scripts/helm_values_gate.py`
additionally rejects two environments claiming the same `(groupName, host, path)`.

## Values reference

| Key | Default | Notes |
| --- | --- | --- |
| `replicaCount` | `1` | dev 1, stage 2, prod 3. |
| `image.tag` / `image.digest` | *(required)* | Pinned by tag **and** digest. |
| `environment` | *(required)* | Telemetry tag. |
| `backend.url` | *(required)* | e.g. `http://mcp-backend.mcp-dev.svc.cluster.local`. |
| `appOwner` | `demo` | Sent as `x-owner`. Not an identity system — see below. |
| `ingress.enabled` | `true` | |
| `ingress.groupName` | `""` | ALB group. One per environment today. |
| `ingress.host` | `""` | No host rule until DNS exists. |
| `ingress.path` / `pathType` | `/` / `Prefix` | |
| `service.port` | `80` | ClusterIP; the ALB targets pod IPs directly. |
| `resources` | 192Mi req / 512Mi limit | Higher than the backend: SSR is memory-hungrier than a JSON API. |
| `podDisruptionBudget.*` | disabled in dev | Same single-replica deadlock reasoning as the backend chart. |

## One ALB per environment

Ingresses sharing `alb.ingress.kubernetes.io/group.name` are merged onto a single
load balancer. That is the cheaper arrangement, but with every environment
matching path `/` and no host rule it is also ambiguous: the group's rule
ordering decides the winner, both Ingresses report Healthy, and nothing warns
you.

So each environment currently sets its own `groupName` and gets its own ALB and
its own DNS name (~$16-18/mo each). **When real hostnames exist, collapse them
back onto one shared group and set `host` per environment** — that is both
cheaper and stricter than relying on ordering.

## Security posture

The listener is plain HTTP and the API behind it has no user authentication:
every visitor acts as the single `appOwner` value. Acceptable for a demo holding
no real data; not acceptable for anything else.

The remediation is small but gated on owning a domain:

1. ACM certificate + `alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'`
2. `alb.ingress.kubernetes.io/auth-type: oidc` with an IdP — ALB OIDC requires
   an HTTPS listener
3. Read the verified `x-amzn-oidc-identity` header the ALB injects instead of
   the `APP_OWNER` env var

## Pod details

`readOnlyRootFilesystem: true` with `emptyDir` mounts at `/tmp` and
`/app/.next/cache`, because Next writes its cache at runtime. The image sets
`HOSTNAME=0.0.0.0`; without it Next's standalone server binds `localhost`, the
readiness probe cannot reach it, and the pod never goes Ready while logging a
perfectly normal startup message.

## Rendering it yourself

```bash
helm template mcp-frontend charts/mcp-frontend \
  -f gitops/apps/mcp-frontend/values-dev.yaml

make app-render   # all environments, both charts, plus the gates
make app-url      # public URL of the dev environment
```
