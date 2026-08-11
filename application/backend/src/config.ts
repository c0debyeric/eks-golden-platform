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

const int = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) ? parsed : fallback;
};

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

  /**
   * PostgreSQL (Amazon RDS). Host/port/dbname/user/password are supplied as
   * DISCRETE variables rather than one DATABASE_URL because that is the shape
   * External Secrets Operator produces from the `eks-golden/rds-master` secret
   * — the Secrets Manager JSON has separate `host`, `port`, `username`,
   * `password`, `dbname` keys. Assembling a URL would mean templating a
   * password into a string in the manifest, which puts it in the pod spec and
   * therefore in `kubectl describe` output. Discrete secretKeyRefs keep it out.
   */
  database: {
    host: process.env.PGHOST ?? "127.0.0.1",
    port: int(process.env.PGPORT, 5432),
    name: process.env.PGDATABASE ?? "postgres",
    user: process.env.PGUSER ?? "postgres",
    password: process.env.PGPASSWORD ?? "",
    /** TLS is on by default; only disable for a local docker-compose Postgres. */
    ssl: bool(process.env.PGSSL, true),
    /** Path to the Amazon RDS CA bundle mounted by the Helm chart. */
    caFile: process.env.PGSSLROOTCERT ?? "",
    /**
     * Postgres schema this environment owns.
     *
     * dev/stage/prod are three namespaces against ONE RDS instance and one
     * database, so without this they share a single `api_keys` table and a key
     * created in dev is readable in prod. A schema per environment restores
     * isolation without paying for an instance per environment.
     */
    schema: process.env.PGSCHEMA ?? "public",
    poolMax: int(process.env.PG_POOL_MAX, 5),
  },
} as const;

export type AppConfig = typeof config;
