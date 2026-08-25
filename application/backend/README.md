# MCP Backend — OpenTelemetry-instrumented Model Context Protocol server

A small, production-shaped **[Model Context Protocol](https://modelcontextprotocol.io) (MCP)**
server in TypeScript. It speaks the **Streamable HTTP** transport in **stateless** mode and is
wired into the platform's **OpenTelemetry** pipeline (traces → Tempo, metrics → Prometheus,
logs → Loki), so it drops straight into the EKS Golden Platform observability stack.

**Stack:** Node.js 24 LTS · TypeScript (ESM, NodeNext) · `@modelcontextprotocol/sdk` · Express 5 ·
OpenTelemetry SDK · Docker (multi-stage, non-root) · Zod

---

## How it fits the platform

```
  MCP client (Cursor / Claude / Inspector / agent)
        |  Streamable HTTP  (POST /mcp)
        v
  +----------------------+     OTLP/HTTP :4318      +--------------------+
  |   mcp-backend (this) | -----------------------> |  OTel gateway      |
  |  Express + MCP SDK   |   traces + metrics       |  collector         |
  |  OTel auto-instr.    |                          |  (observability)   |
  +----------------------+                          +----+----+----+-----+
        |  stdout (structured JSON logs)                 |    |    |
        v                                          traces| metrics|logs
  node OTel Collector DaemonSet --- logs -----------> Tempo Prom  Loki
```

- Traces and metrics are pushed over **OTLP/HTTP** to the gateway collector at
  `http://gateway-collector.observability.svc:4318` (see `gitops/apps/otel-collector/`).
- Logs are written as **structured JSON to stdout**; the platform's node-level OTel Collector
  DaemonSet (`gitops/apps/otel-collector/logs-daemonset.yaml`) reads them from `/var/log/pods`,
  parses the JSON, and forwards them through the gateway to Loki. Each log line carries
  `trace_id`/`span_id` when emitted inside a span, and the DaemonSet promotes those onto the OTLP
  log record so Grafana can pivot Tempo ⇄ Loki in both directions.

---

## Tools exposed

```
Tool              Input                                  Returns
----------------  -------------------------------------  ---------------------------------------
echo              { message: string }                    the same text (connectivity check)
add               { a: number, b: number }               a + b
get_server_time   { timeZone?: string }                  current time (ISO-8601, or in the zone)
create_api_key    { name: string, owner: string }        the new key — PLAINTEXT, shown ONCE
list_api_keys     { owner: string }                      that owner's keys (metadata only)
revoke_api_key    { id: uuid, owner: string }            the revoked key's audit record
```

The last three are RDS-backed and operate on the same `api_keys` table as the REST API in
[`src/routes.ts`](src/routes.ts), so a key an agent mints over MCP appears in the web UI and vice
versa. `create_api_key` returns the plaintext key exactly once — only its SHA-256 digest is
stored, so it cannot be retrieved afterwards.

Every tool call gets its own span (`mcp.tool/<name>`) and increments the
`mcp.tool.invocations` counter (labelled `tool` + `status`). Add your own tools in
[`src/mcp.ts`](src/mcp.ts) using the same `instrument()` wrapper.

---

## Project layout

```
application/backend/
├── src/
│   ├── telemetry.ts   # OpenTelemetry bootstrap (loaded via --import, first)
│   ├── config.ts      # env-driven config (12-factor)
│   ├── logger.ts      # structured JSON logs + trace correlation
│   ├── mcp.ts         # McpServer factory + tool definitions
│   └── index.ts       # Express app, Streamable HTTP transport, health, lifecycle
├── Dockerfile         # multi-stage, non-root, healthcheck
├── .env.example       # documented runtime configuration
├── tsconfig.json
└── package.json
```

---

## Local development

Requires Node.js ≥ 22 (24 LTS recommended).

```bash
npm install
cp .env.example .env      # optional; defaults are sensible

# Hot-reload dev server (OTLP export off unless a collector is reachable):
OTEL_DEBUG=true npm run dev

# Or run the compiled build the same way the container does:
npm run build
OTEL_DEBUG=true npm start
```

`OTEL_DEBUG=true` prints spans/metrics to the console instead of exporting them — handy when no
collector is running locally.

### Try it

The server is a standard Streamable HTTP MCP endpoint at `POST /mcp`. The easiest client is the
official inspector:

```bash
npx @modelcontextprotocol/inspector
# then connect to: http://127.0.0.1:8080/mcp  (Transport: "Streamable HTTP")
```

Health endpoints for probes/load balancers:

```bash
curl http://127.0.0.1:8080/healthz   # {"status":"ok"}
curl http://127.0.0.1:8080/readyz    # {"status":"ready"}
```

---

## Configuration

All configuration is environment-driven (see [`.env.example`](.env.example)).

```
Variable                      Default                                              Purpose
----------------------------  ---------------------------------------------------  ------------------------------
PORT                          8080                                                 HTTP listen port
MCP_HTTP_PATH                 /mcp                                                 MCP endpoint path
MCP_ALLOWED_HOSTS             (empty = disabled)                                   DNS-rebinding allow-list (bare hostnames)
OTEL_SERVICE_NAME             mcp-backend                                          service.name resource attribute
OTEL_EXPORTER_OTLP_ENDPOINT   http://gateway-collector.observability.svc:4318      OTLP/HTTP collector base URL
OTEL_DEPLOYMENT_ENVIRONMENT   dev                                                  deployment.environment.name
OTEL_DEBUG                    false                                                console exporters instead of OTLP
```

---

## Container

```bash
# Build
docker build -t mcp-backend:0.1.0 .

# Run (point OTLP at your collector, or use OTEL_DEBUG for a standalone smoke test)
docker run --rm -p 8080:8080 --init \
  -e OTEL_DEBUG=true \
  mcp-backend:0.1.0
```

The image is multi-stage: a build stage compiles TypeScript, and the runtime stage contains only
production `node_modules` + `dist/`, runs as the unprivileged `node` user, declares a
`HEALTHCHECK`, and honours `SIGTERM` for graceful shutdown.

---

## CI/CD — image build (GitHub Actions → ECR)

[`.github/workflows/build-image.yml`](../../.github/workflows/build-image.yml) builds and pushes
the image on every push to `main` that touches `application/backend/**` (or via manual dispatch).
It is **keyless** — the same OIDC model as the Terraform workflow:

- Assumes the repo CI role via `vars.AWS_ROLE_ARN` (already configured for the Terraform workflow —
  no new secret or IAM role needed; that role can push to ECR).
- Ensures the `mcp-backend` ECR repo exists (IMMUTABLE tags, scan-on-push), logs in, then builds +
  pushes `mcp-backend:<12-char git SHA>` for `linux/amd64,linux/arm64` with layer caching. Both
  architectures are required: the Karpenter NodePool allows amd64 and arm64, and an amd64-only
  image pulls fine on a Graviton node and then dies with "exec format error". CI enforces the
  match (`scripts/build_arch_gate.py`).
- Prints the exact image reference + digest to the run summary.

The workflow writes the resulting tag and digest straight into
`gitops/apps/mcp-backend/values-dev.yaml`; ArgoCD then rolls it out. Promotion to stage and prod
goes through `.github/workflows/promote.yml`, which copies an already-built digest forward and
opens a PR. The ECR repository itself is Terraform-managed (`terraform/ecr.tf`).

## Kubernetes (GitOps) deployment

This service is stateless, so it scales horizontally with no session affinity. The
ArgoCD-managed manifests are committed to the repo and reconciled automatically:

```
gitops/bootstrap/mcp-backend.yaml     ApplicationSet -> one Application per environment
charts/mcp-backend/                   the Helm chart (templates + safe defaults)
├── templates/deployment.yaml         non-root, probes, OTLP + DB env, zone spread
├── templates/service.yaml            ClusterIP :80 -> :8080 (internal only)
├── templates/pdb.yaml                PodDisruptionBudget
└── templates/externalsecret.yaml     RDS credentials via External Secrets Operator
gitops/apps/mcp-backend/
├── values-dev.yaml                   mcp-dev,   1 replica,  PDB off,           auto-sync
├── values-stage.yaml                 mcp-stage, 2 replicas, minAvailable 1,    auto-sync
└── values-prod.yaml                  mcp-prod,  3 replicas, minAvailable 2,    MANUAL sync
```

The root app-of-apps discovers `gitops/bootstrap/mcp-backend.yaml`, whose ApplicationSet creates
three Applications that roll out in order at **sync waves 5 / 6 / 7** (dev → stage → prod) — all
after the observability stack (OTel operator wave 2, gateway collector wave 4), so the OTLP
endpoint exists before any pod starts. Each environment lands in its own namespace; there is no
shared `application` namespace.

The Application uses **two sources**: the chart directory, plus the same repo again with
`ref: values` so the per-environment values file can be referenced as
`$values/gitops/apps/mcp-backend/values-<env>.yaml`. This keeps environment configuration out of
the chart while still versioning both together.

The chart deliberately ships **no default `image.tag`** — the template calls Helm's `required`, so
rendering without a per-environment pin fails loudly instead of silently inheriting a plausible
default. Each values file pins the ECR repo, the tag, **and** the digest, so an environment can
only run an image someone explicitly moved into it. `scripts/helm_values_gate.py` enforces this in
CI: it rejects empty, placeholder, or duplicated pins and re-renders every environment.

Notes:
- Uses the **explicit OTel SDK** (in `telemetry.ts`) rather than the operator's zero-code
  `Instrumentation` CRD annotation — full control over spans/metrics, no
  `instrumentation.opentelemetry.io/inject-*` annotation and no `ServiceMonitor` needed (metrics
  are pushed via OTLP, not scraped). Telemetry flows to Tempo/Prometheus/Loki automatically.
- The Service is **ClusterIP (internal)** by design: an unauthenticated MCP server should not be
  exposed publicly. To expose it, add auth (MCP spec: OAuth 2.1) + an Ingress on the ALB
  controller, and set `MCP_ALLOWED_HOSTS` to the public hostname(s) for DNS-rebinding protection.

---

## Design decisions

```
Decision                      Why
----------------------------  --------------------------------------------------------------
Streamable HTTP transport     current standard for remote/containerised MCP (SSE is legacy)
Stateless (no session id)     any replica serves any request -> clean HPA, no sticky sessions
Explicit OTel SDK (--import)  full control of traces+metrics; loads before http/express
OTLP/HTTP :4318               matches the platform gateway collector (OTLP http receiver)
Logs to stdout (not OTLP)     DaemonSet already ships stdout -> Loki; avoids double-ingest
Zod input schemas             validated tool inputs, auto-generated JSON Schema for clients
Non-root multi-stage image    small runtime surface, no build toolchain, least privilege
```

---

## Scripts

```
npm run dev        # hot-reload dev server (tsx) with telemetry preloaded
npm run build      # tsc -> dist/
npm start          # run compiled server with OTel preloaded (prod entrypoint)
npm run typecheck  # tsc --noEmit
npm run clean      # remove dist/
```
