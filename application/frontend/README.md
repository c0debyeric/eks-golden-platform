# mcp-frontend

Next.js UI for the API-key management service. It is the only component of this
platform exposed to the internet, and it deliberately owns no data of its own.

## What it does

Create, list and revoke API keys. A newly created key's plaintext is shown
exactly once, at creation, with a copy button and an explicit warning — after
that only its prefix is recoverable, because the backend stores nothing but a
SHA-256 digest.

## Architecture: why the UI does not talk to Postgres

The obvious Next.js design is to query the database from server components and
skip a hop. This does the opposite: **every read and write goes through the
backend's REST API over ClusterIP**, and the frontend has no database
credentials at all.

Three reasons, in order of how much they actually matter here:

1. **Connection pooling.** The database is a `db.t4g.micro`, whose
   `max_connections` is small. Next.js is hostile to pooling: route handlers and
   server components are re-entrant and can be re-instantiated per request, so a
   pool per replica multiplies quickly and is hard to bound. The backend is a
   single long-lived Express process with one explicitly capped pool.
2. **Credential blast radius.** This pod is reachable from the internet. Keeping
   the RDS password out of its environment means a frontend RCE does not become
   direct database access.
3. **One writer, one schema.** Migrations, the advisory lock and the key-hashing
   rules live in exactly one place. Two writers with two copies of the hashing
   logic is how the two drift.

The cost is an extra in-cluster hop (~1ms) and the `x-owner` trust boundary
described below.

```
browser ──HTTP──▶ ALB ──▶ mcp-frontend (Next.js)
                              │  server-side only, never from the browser
                              ▼
                          mcp-backend (ClusterIP) ──TLS──▶ RDS PostgreSQL
```

## Layout

```
src/
├── app/
│   ├── page.tsx                 server component, renders the shell
│   ├── layout.tsx               metadata + fonts
│   ├── ApiKeySection.tsx        client component: the whole create/list/revoke UI
│   └── api/
│       ├── health/route.ts      liveness/readiness probe target
│       ├── keys/route.ts        GET (list), POST (create)
│       └── keys/[id]/route.ts   DELETE (revoke)
└── lib/
    └── backend.ts               the ONLY module that talks to the backend
```

`src/lib/backend.ts` imports `server-only`. That is load-bearing: it turns an
accidental import from a client component into a **build** error rather than a
runtime leak of the internal service URL into the browser bundle.

## The `x-owner` trust boundary

`backend.ts` sends `x-owner: ${APP_OWNER}` on every request, and the backend
scopes all queries to that value. The header is assigned server-side and is not
derived from anything the browser sends, so a visitor cannot read another
owner's keys by tampering with a request.

But `APP_OWNER` is a single fixed value, so **every visitor is currently the same
user**. That is a demo affordance, not an identity system. Replacing it is a
small change gated on a domain: put an HTTPS listener with
`alb.ingress.kubernetes.io/auth-type: oidc` in front, then read the verified
subject the ALB injects as `x-amzn-oidc-identity` instead of reading the env var.
Until then the API behind this UI is unauthenticated.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `BACKEND_URL` | `http://mcp-backend.mcp-dev.svc.cluster.local` | Backend base URL. Namespace-qualified per environment so it cannot resolve to another environment's backend. |
| `APP_OWNER` | `demo` | Value sent as `x-owner`. See above. |
| `HOSTNAME` | set to `0.0.0.0` in the image | See the container note below. |

Requests use `cache: "no-store"` and a 10s `AbortSignal.timeout`, so a hung
backend surfaces as a `502` in the UI rather than an ALB idle timeout.

## Local development

```bash
npm install
npm run dev          # http://localhost:3000
```

You need a backend to talk to. Either port-forward a deployed one:

```bash
kubectl port-forward -n mcp-dev svc/mcp-backend 8080:80
BACKEND_URL=http://localhost:8080 npm run dev
```

or run `../backend` against a local Postgres (see its README).

## Container

Multi-stage build on `node:24-bookworm-slim`, shipping Next's `standalone`
output so the runtime image carries no toolchain and no full `node_modules`.

Two details that are easy to get wrong:

- **`ENV HOSTNAME=0.0.0.0`.** The standalone server binds `localhost` by default.
  In a container that means the readiness probe cannot reach it and the pod never
  becomes Ready — with no error in the logs, because the server started fine.
- **Writable `emptyDir` mounts** at `/tmp` and `/app/.next/cache`. The pod runs
  with `readOnlyRootFilesystem: true`, and Next writes its cache at runtime.

The image is built for `linux/amd64,linux/arm64`. The Karpenter NodePool allows
both, and an amd64-only image will pull happily onto a Graviton node and then die
with `exec format error`.

## Deployment

Chart in [`charts/mcp-frontend`](../../charts/mcp-frontend), per-environment
values in `gitops/apps/mcp-frontend/values-<env>.yaml`, rolled out by the
ApplicationSet in `gitops/bootstrap/mcp-frontend.yaml` at sync waves 6/7/8 — one
wave behind the matching backend, so the first render has something to call.

Each environment gets its **own ALB** (`ingress.groupName`). Sharing one load
balancer while all three match path `/` with no host rule would let ALB rule
ordering decide which environment a visitor reaches. Once real hostnames exist,
move them back onto a shared group and disambiguate with `host` instead.
