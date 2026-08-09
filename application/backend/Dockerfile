# syntax=docker/dockerfile:1

# Multi-stage build for the OpenTelemetry-instrumented MCP server.
# Base image is the current Node.js LTS on Debian slim. For production, pin by
# digest (node:24-bookworm-slim@sha256:...) — a CI step (e.g. Renovate, which
# this repo already uses) keeps the digest current.
ARG NODE_IMAGE=node:24-bookworm-slim

# ── deps: production-only node_modules (from the lockfile) ───────────────────
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-fund --no-audit

# ── build: install dev deps and compile TypeScript -> dist/ ──────────────────
FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-fund --no-audit
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ── certs: the Amazon RDS trust bundle ───────────────────────────────────────
# RDS presents a certificate chained to an Amazon RDS root CA that is NOT in the
# system trust store. The usual "fix" is rejectUnauthorized:false, which yields a
# connection that is encrypted but UNAUTHENTICATED — indistinguishable from a
# working one, and MITM-able by anything on the path inside the VPC. Baking the
# real bundle in lets pg verify properly (see src/db.ts).
#
# The global bundle covers every region, so this image stays region-agnostic.
FROM ${NODE_IMAGE} AS certs
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL --retry 3 \
        https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
        -o /tmp/rds-global-bundle.pem \
    # Assert we got a certificate and not an error page or a truncated body —
    # a corrupt bundle would otherwise only surface as a TLS failure at runtime.
    && grep -q "BEGIN CERTIFICATE" /tmp/rds-global-bundle.pem

# ── runtime: minimal image, non-root, no build toolchain ─────────────────────
FROM ${NODE_IMAGE} AS runtime
ENV NODE_ENV=production \
    PORT=8080 \
    OTEL_SERVICE_NAME=mcp-backend \
    PGSSLROOTCERT=/app/certs/rds-global-bundle.pem
WORKDIR /app

# The official Node image ships an unprivileged `node` user (uid 1000).
COPY --chown=node:node package.json ./
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=certs --chown=node:node /tmp/rds-global-bundle.pem ./certs/rds-global-bundle.pem

USER node
EXPOSE 8080
STOPSIGNAL SIGTERM

# Liveness parity with the Kubernetes probe; uses Node's built-in global fetch.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# `--import ./dist/telemetry.js` loads the OpenTelemetry SDK before app code so
# auto-instrumentation can patch http/express.
CMD ["node", "--import", "./dist/telemetry.js", "dist/index.js"]
