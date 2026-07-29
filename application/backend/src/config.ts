/**
 * Central runtime configuration, resolved once from the environment.
 *
 * Everything is driven by env vars so the same image runs unchanged across
 * local dev, CI, and the cluster (12-factor). OpenTelemetry endpoint/service
 * settings intentionally mirror the standard `OTEL_*` names so they can also
 * be tuned by operators without a rebuild.
 */

const bool = (value: string | undefined, fallback: boolean): boolean => {
  if (value === undefined) return fallback;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
};

const list = (value: string | undefined): string[] =>
  (value ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);

export const config = {
  serviceName: process.env.OTEL_SERVICE_NAME ?? "mcp-backend",
  serviceVersion: process.env.npm_package_version ?? "0.1.0",
  environment: process.env.OTEL_DEPLOYMENT_ENVIRONMENT ?? "dev",

  port: Number.parseInt(process.env.PORT ?? "8080", 10),
  mcpPath: process.env.MCP_HTTP_PATH ?? "/mcp",

  /** Host header allow-list for DNS-rebinding protection; empty = disabled. */
  allowedHosts: list(process.env.MCP_ALLOWED_HOSTS),

  otel: {
    endpoint:
      process.env.OTEL_EXPORTER_OTLP_ENDPOINT ??
      "http://gateway-collector.observability.svc:4318",
    debug: bool(process.env.OTEL_DEBUG, false),
  },
} as const;

export type AppConfig = typeof config;
