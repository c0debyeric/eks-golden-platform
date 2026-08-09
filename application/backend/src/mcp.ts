/**
 * MCP server definition: the tools this service exposes.
 *
 * A fresh `McpServer` is built per HTTP request (stateless transport — see
 * index.ts), so this module only describes *how* to build one. Tool handlers
 * are wrapped with a custom OpenTelemetry span + invocation counter so every
 * call is traced (Tempo) and counted (Prometheus) alongside the auto-generated
 * HTTP spans.
 */
import { metrics, SpanStatusCode, trace } from "@opentelemetry/api";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

import { config } from "./config.js";
import { createApiKey, listApiKeys, revokeApiKey } from "./apiKeys.js";
import { logger } from "./logger.js";

const tracer = trace.getTracer(config.serviceName, config.serviceVersion);
const meter = metrics.getMeter(config.serviceName, config.serviceVersion);

const toolInvocations = meter.createCounter("mcp.tool.invocations", {
  description: "Number of MCP tool invocations, labelled by tool and outcome.",
});

/**
 * Wrap a tool handler so each invocation gets its own span and is counted.
 * Errors are recorded on the span and surfaced to the caller as an MCP tool
 * error result (isError) rather than crashing the request.
 */
function instrument<Args>(
  toolName: string,
  handler: (args: Args) => Promise<CallToolResult> | CallToolResult,
): (args: Args) => Promise<CallToolResult> {
  return (args: Args) =>
    tracer.startActiveSpan(`mcp.tool/${toolName}`, async (span) => {
      span.setAttribute("mcp.tool.name", toolName);
      try {
        const result = await handler(args);
        const status = result.isError ? "error" : "ok";
        toolInvocations.add(1, { tool: toolName, status });
        span.setStatus({ code: SpanStatusCode.OK });
        return result;
      } catch (err) {
        const error = err as Error;
        toolInvocations.add(1, { tool: toolName, status: "exception" });
        span.recordException(error);
        span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
        logger.error("tool handler threw", { tool: toolName, error: error.message });
        return {
          isError: true,
          content: [{ type: "text", text: `Tool "${toolName}" failed: ${error.message}` }],
        } satisfies CallToolResult;
      } finally {
        span.end();
      }
    });
}

const text = (value: string): CallToolResult => ({ content: [{ type: "text", text: value }] });

/** Build a fully-configured MCP server instance with all tools registered. */
export function buildMcpServer(): McpServer {
  const server = new McpServer(
    { name: config.serviceName, version: config.serviceVersion },
    { capabilities: { tools: {}, logging: {} } },
  );

  server.registerTool(
    "echo",
    {
      title: "Echo",
      description: "Echo back the provided text. Useful as a connectivity smoke test.",
      inputSchema: { message: z.string().min(1).describe("Text to echo back") },
    },
    instrument("echo", ({ message }) => text(message)),
  );

  server.registerTool(
    "add",
    {
      title: "Add",
      description: "Add two numbers and return the sum.",
      inputSchema: {
        a: z.number().describe("First addend"),
        b: z.number().describe("Second addend"),
      },
    },
    instrument("add", ({ a, b }) => text(String(a + b))),
  );

  server.registerTool(
    "get_server_time",
    {
      title: "Get server time",
      description: "Return the current server time as an ISO-8601 timestamp.",
      inputSchema: {
        timeZone: z
          .string()
          .optional()
          .describe('IANA time zone, e.g. "America/New_York". Defaults to UTC.'),
      },
    },
    instrument("get_server_time", ({ timeZone }) => {
      const now = new Date();
      if (!timeZone) return text(now.toISOString());
      // Throws RangeError on an invalid zone -> surfaced as a tool error.
      const formatted = new Intl.DateTimeFormat("en-CA", {
        dateStyle: "short",
        timeStyle: "long",
        timeZone,
      }).format(now);
      return text(formatted);
    }),
  );

  // ── API key tools (RDS-backed) ────────────────────────────────────────────
  // Same table the REST API serves, so a key minted by an agent shows up in the
  // web UI and vice versa.

  server.registerTool(
    "create_api_key",
    {
      title: "Create API key",
      description:
        "Issue a new API key. The plaintext key is returned ONCE and is not recoverable afterwards.",
      inputSchema: {
        name: z.string().min(1).max(120).describe("Human-readable label for the key"),
        owner: z.string().min(1).max(128).describe("Owner the key belongs to"),
      },
    },
    instrument("create_api_key", async ({ name, owner }) => {
      const created = await createApiKey(name, owner);
      return text(
        JSON.stringify(
          { id: created.id, name: created.name, owner: created.owner, key: created.key },
          null,
          2,
        ),
      );
    }),
  );

  server.registerTool(
    "list_api_keys",
    {
      title: "List API keys",
      description:
        "List an owner's API keys. Returns metadata only — key material is never retrievable.",
      inputSchema: {
        owner: z.string().min(1).max(128).describe("Owner whose keys to list"),
      },
    },
    instrument("list_api_keys", async ({ owner }) =>
      text(JSON.stringify(await listApiKeys(owner), null, 2)),
    ),
  );

  server.registerTool(
    "revoke_api_key",
    {
      title: "Revoke API key",
      description: "Revoke an active API key. The audit row is retained, not deleted.",
      inputSchema: {
        id: z.string().uuid().describe("Key id to revoke"),
        owner: z.string().min(1).max(128).describe("Owner the key belongs to"),
      },
    },
    instrument("revoke_api_key", async ({ id, owner }) => {
      const revoked = await revokeApiKey(id, owner);
      if (!revoked) {
        return {
          isError: true,
          content: [{ type: "text", text: "No such active API key for that owner." }],
        } satisfies CallToolResult;
      }
      return text(JSON.stringify(revoked, null, 2));
    }),
  );

  return server;
}
