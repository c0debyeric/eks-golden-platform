# syntax=docker/dockerfile:1

# Multi-stage build for the Next.js frontend.
#
# Mirrors application/backend/Dockerfile deliberately: same base image, same
# non-root uid 1000, same STOPSIGNAL and HEALTHCHECK shape. Two workloads that
# are containerised two different ways is how a securityContext that works for
# one silently breaks the other.
ARG NODE_IMAGE=node:24-bookworm-slim

# ── deps: full dependency tree, needed to run the Next build ─────────────────
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-fund --no-audit

# ── build: compile the app and emit .next/standalone ────────────────────────
FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Next inlines NEXT_PUBLIC_* at build time, but everything this app needs
# (BACKEND_URL, APP_OWNER) is read at RUNTIME on the server side, so no secrets
# or environment-specific values are baked into the image. That is what makes
# the same digest promotable dev -> stage -> prod unchanged.
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ── runtime: standalone server only, no build toolchain, no full node_modules ─
FROM ${NODE_IMAGE} AS runtime
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
WORKDIR /app

# HOSTNAME=0.0.0.0 is REQUIRED, not cosmetic. The standalone server defaults to
# binding localhost, so without it the container starts, logs "ready", passes no
# traffic, and the kubelet's probe fails with connection refused — which reads
# like a crash rather than a bind-address problem.

# The standalone output already contains the pruned node_modules and its own
# server.js. `static` and `public` are NOT included in it and must be copied
# separately, or every CSS/JS asset 404s and the page renders unstyled.
COPY --from=build --chown=node:node /app/.next/standalone ./
COPY --from=build --chown=node:node /app/.next/static ./.next/static
COPY --from=build --chown=node:node /app/public ./public

USER node
EXPOSE 3000
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
