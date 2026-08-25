/**
 * HTTP entrypoint: an Express app that serves the MCP server over the
 * Streamable HTTP transport in **stateless** mode.
 *
 * Stateless (sessionIdGenerator: undefined) is the right default for a
 * containerised, horizontally-scaled service: any replica can serve any
 * request, so it scales cleanly behind an ALB / Kubernetes HPA with no sticky
 * sessions or shared session store. A fresh McpServer + transport is created
 * per request and torn down when the response closes.
 *
 * This module assumes telemetry.ts has already been loaded via `--import`.
 */
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

import { hostHeaderValidation } from "@modelcontextprotocol/sdk/server/middleware/hostHeaderValidation.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import express, { type Request, type Response } from "express";

import { config } from "./config.js";
import { closePool, isHealthy, migrate } from "./db.js";
import { logger } from "./logger.js";
import { buildMcpServer } from "./mcp.js";
import { apiRouter } from "./routes.js";
import { shutdownTelemetry } from "./telemetry.js";

const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "1mb" }));

// Optional DNS-rebinding protection. Uses the SDK's dedicated, port-agnostic
// host-header middleware (the transport's built-in `allowedHosts` option is
// deprecated). `allowedHosts` are bare hostnames, e.g. 127.0.0.1, localhost,
// [::1], or the service's public DNS name. Empty list = disabled (fine behind
// a trusted ingress/ALB that terminates and sets the Host).
if (config.allowedHosts.length > 0) {
  app.use(config.mcpPath, hostHeaderValidation(config.allowedHosts));
}

// JSON-RPC error for HTTP methods the stateless transport does not support.
const methodNotAllowed = (_req: Request, res: Response): void => {
  res.status(405).json({
    jsonrpc: "2.0",
    error: { code: -32000, message: "Method not allowed." },
    id: null,
  });
};

app.post(config.mcpPath, async (req: Request, res: Response) => {
  // One server + transport per request; no session state is retained.
  const server = buildMcpServer();
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
  });

  res.on("close", () => {
    void transport.close();
    void server.close();
  });

  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (err) {
    logger.error("MCP request handling failed", { error: (err as Error).message });
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: { code: -32603, message: "Internal server error." },
        id: null,
      });
    }
  }
});

// Stateless mode: server-initiated SSE (GET) and session teardown (DELETE)
// are not applicable.
app.get(config.mcpPath, methodNotAllowed);
app.delete(config.mcpPath, methodNotAllowed);

// REST surface for the Next.js frontend (API key CRUD, backed by RDS).
app.use("/api", apiRouter);

// Kubernetes probes.
//
// LIVENESS is deliberately database-INDEPENDENT: if it checked Postgres, an RDS
// failover or a brief connection blip would make the kubelet kill and restart
// every replica simultaneously, turning a ~2-minute recoverable event into a
// CrashLoopBackOff across the whole Deployment. The process being up is the only
// thing a restart can fix, so that is all liveness asserts.
app.get("/healthz", (_req, res) => res.status(200).json({ status: "ok" }));

// READINESS does check the database: a replica that cannot reach Postgres cannot
// serve /api, so it should be pulled from the Service endpoints — but left
// running, so it rejoins automatically once the database returns.
app.get("/readyz", async (_req, res) => {
  if (!schemaReady) {
    res.status(503).json({ status: "degraded", reason: "schema migration pending" });
    return;
  }
  if (await isHealthy()) {
    res.status(200).json({ status: "ready" });
  } else {
    res.status(503).json({ status: "degraded", reason: "database unreachable" });
  }
});

// Declared before migrateWithRetry runs: the retry loop reads `shuttingDown` on
// its very first synchronous iteration, so a `let` declared further down would
// be in the temporal dead zone and throw ReferenceError at startup.
let shuttingDown = false;

// Bring the schema up to date before accepting traffic.
//
// WHY this does not block listen(): if it did, a database outage would stop the
// pod from ever binding a port, so the kubelet's liveness probe would fail and
// restart it forever — a database problem escalated into a crash loop. Instead
// the server starts, readiness reports 503 until migration succeeds, and the
// retry loop keeps trying.
let schemaReady = false;

async function migrateWithRetry(): Promise<void> {
  for (let attempt = 1; !shuttingDown; attempt += 1) {
    try {
      await migrate();
      schemaReady = true;
      return;
    } catch (err) {
      // Cap the backoff so a long outage does not push retries hours apart.
      const delayMs = Math.min(30_000, 2 ** Math.min(attempt, 5) * 1000);
      logger.error("schema migration failed; retrying", {
        attempt,
        delayMs,
        error: (err as Error).message,
      });
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}

void migrateWithRetry();

const httpServer = app.listen(config.port, () => {
  const { port } = httpServer.address() as AddressInfo;
  logger.info("MCP backend listening", {
    port,
    mcpPath: config.mcpPath,
    environment: config.environment,
    otlpEndpoint: config.otel.endpoint,
    // Host only — never the password, and never a full connection string.
    database: `${config.database.host}:${config.database.port}/${config.database.name}`,
    instanceId: randomUUID(),
  });
});

/**
 * How long to let in-flight requests finish before forcing sockets closed.
 * Must stay comfortably below the pod's terminationGracePeriodSeconds (30s by
 * default), or the kubelet SIGKILLs the process mid-cleanup and the bound
 * becomes meaningless.
 */
const SHUTDOWN_GRACE_MS = 10_000;

/**
 * Stop accepting connections and drain in-flight requests, but never wait
 * longer than `graceMs`.
 *
 * WHY this is not just `httpServer.close()`: close() fires its callback only
 * once every ACTIVE socket has finished, and it will wait for that forever.
 * Idle keep-alive sockets are not the problem — Node >= 19 closes those on
 * close() by itself — but a socket with a request still in progress is. A
 * client that stops mid-request (a dropped mobile connection, a stalled proxy,
 * a slow-loris probe on a public ALB) leaves one, and then the whole shutdown
 * blocks behind it.
 *
 * That is not a hypothetical ordering nit; it silently deletes the cleanup.
 * Measured against this server with one unfinished request open: unbounded
 * close() never returned, the kubelet SIGKILLed the pod, and neither of the two
 * steps that follow — draining the Postgres pool, flushing the final telemetry
 * batch — ran at all. Bounded, it exits at graceMs having run both.
 *
 * closeIdleConnections() is still called so the ordinary case settles at once
 * rather than idling until the timer; the timer bounds the pathological one and
 * then closes the remaining sockets by force.
 */
function closeHttpServer(graceMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
    let settled = false;
    const settle = (): void => {
      if (settled) return;
      settled = true;
      resolve();
    };

    const timer = setTimeout(() => {
      logger.warn("in-flight requests did not finish in time; forcing sockets closed", {
        graceMs,
      });
      httpServer.closeAllConnections();
      settle();
    }, graceMs);
    // Do not let this timer keep the event loop alive on a clean, fast shutdown.
    timer.unref();

    httpServer.close(() => {
      clearTimeout(timer);
      settle();
    });

    // Release keep-alive sockets that are not currently serving a request.
    httpServer.closeIdleConnections();
  });
}

async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info("shutting down", { signal });

  // Stop accepting new connections, then drain the pool and flush telemetry.
  await closeHttpServer(SHUTDOWN_GRACE_MS);
  await closePool().catch((err) =>
    logger.error("failed to close the database pool", { error: (err as Error).message }),
  );
  await shutdownTelemetry();

  logger.info("shutdown complete");
  process.exit(0);
}

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => void shutdown(signal));
}

process.on("unhandledRejection", (reason) => {
  logger.error("unhandled promise rejection", { reason: String(reason) });
});
