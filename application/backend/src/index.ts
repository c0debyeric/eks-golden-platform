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
import { logger } from "./logger.js";
import { buildMcpServer } from "./mcp.js";
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

// Kubernetes probes. Liveness = process is up; readiness = ready for traffic.
app.get("/healthz", (_req, res) => res.status(200).json({ status: "ok" }));
app.get("/readyz", (_req, res) => res.status(200).json({ status: "ready" }));

const httpServer = app.listen(config.port, () => {
  const { port } = httpServer.address() as AddressInfo;
  logger.info("MCP backend listening", {
    port,
    mcpPath: config.mcpPath,
    environment: config.environment,
    otlpEndpoint: config.otel.endpoint,
    instanceId: randomUUID(),
  });
});

let shuttingDown = false;

async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info("shutting down", { signal });

  // Stop accepting new connections, then flush telemetry.
  await new Promise<void>((resolve) => httpServer.close(() => resolve()));
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
