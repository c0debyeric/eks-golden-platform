/**
 * PostgreSQL access layer.
 *
 * WHY the backend owns the database and the frontend does not: the Next.js app
 * runs one Node process per replica and server components/route handlers are
 * pool-hostile (a pool per render path, no clean lifecycle hook to drain them).
 * `db.t4g.micro` has a low `max_connections` ceiling, so fanning pools out
 * across two workloads is how you exhaust it. Concentrating all DB access here
 * also keeps the RDS credentials out of the internet-facing pod entirely — the
 * frontend never receives them and its SecurityGroup never needs 5432 reach.
 *
 * Credentials arrive as a Kubernetes Secret materialised by External Secrets
 * Operator from the Secrets Manager entry `eks-golden/rds-master` (see
 * charts/mcp-backend/templates/externalsecret.yaml). They are read from the
 * environment at startup and never logged.
 */
import { readFileSync } from "node:fs";

import pg from "pg";

import { config } from "./config.js";
import { logger } from "./logger.js";

/**
 * RDS terminates TLS with a certificate chained to the Amazon RDS root CA,
 * which is NOT in Node's bundled trust store. The tempting fix is
 * `rejectUnauthorized: false`, which silently downgrades to an unverified
 * connection — encrypted but trivially MITM-able from inside the VPC, and it
 * looks identical to a working setup. Instead the chart mounts the RDS CA
 * bundle and we verify against it properly.
 */
function buildTlsConfig(): pg.ConnectionConfig["ssl"] {
  if (!config.database.ssl) return false;

  if (config.database.caFile) {
    try {
      return {
        ca: readFileSync(config.database.caFile, "utf8"),
        rejectUnauthorized: true,
      };
    } catch (err) {
      // Fail loudly rather than falling back to an unverified connection.
      throw new Error(
        `Could not read the RDS CA bundle at ${config.database.caFile}: ${(err as Error).message}`,
      );
    }
  }

  return { rejectUnauthorized: true };
}

/**
 * A single process-wide pool. `max` is deliberately small: db.t4g.micro allows
 * roughly 85 connections, and this Deployment can scale to 3 replicas per
 * environment across three environments sharing one instance. 5 * 9 = 45 leaves
 * headroom for migrations, psql sessions and the replicas' own overhead.
 */
/**
 * Postgres identifiers are case-folded unless quoted, and a schema name reaches
 * us from the environment. Validate against a conservative charset and then
 * double-quote at every use site: `search_path` and `CREATE SCHEMA` cannot take
 * a bind parameter, so this is the only thing standing between a malformed
 * value and injected DDL.
 */
function assertSafeIdentifier(value: string, what: string): string {
  if (!/^[A-Za-z_][A-Za-z0-9_]{0,62}$/.test(value)) {
    throw new Error(`${what} must match /^[A-Za-z_][A-Za-z0-9_]{0,62}$/, got: ${value}`);
  }
  return value;
}

const SCHEMA_NAME = assertSafeIdentifier(config.database.schema, "database.schema");

export const pool = new pg.Pool({
  host: config.database.host,
  port: config.database.port,
  database: config.database.name,
  user: config.database.user,
  password: config.database.password,
  ssl: buildTlsConfig(),
  max: config.database.poolMax,
  idleTimeoutMillis: 30_000,
  // Fail fast instead of hanging a request for the default (infinite) wait when
  // the database is unreachable — the readiness probe then sheds the pod.
  connectionTimeoutMillis: 5_000,
  application_name: `${config.serviceName}-${config.environment}`,
  // Pin every session in this pool to this environment's schema. Set on the
  // CONNECTION rather than per query so no query can accidentally omit it, and
  // so unqualified DDL in migrate() lands in the right place. `public` is
  // deliberately excluded from the path: falling back to it is exactly the
  // cross-environment leak this prevents.
  options: `-c search_path="${SCHEMA_NAME}"`,
});

// An idle client erroring (e.g. RDS failover severing the connection) emits on
// the pool. Unhandled, this crashes the process. Multi-AZ failover is a normal,
// ~2-minute event here, so it must be survivable: log it and let the pool
// replace the client.
pool.on("error", (err) => {
  logger.error("idle postgres client error", { error: err.message });
});

/**
 * Schema migration. Kept as an idempotent in-process step rather than a
 * separate Job/initContainer: the schema is one table, and a migration Job
 * introduces an ordering problem (Job must complete before the Deployment rolls)
 * that Argo CD sync-waves would have to encode. `IF NOT EXISTS` plus the
 * advisory lock below makes concurrent replica startup safe.
 */
const SCHEMA = `
CREATE TABLE IF NOT EXISTS api_keys (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text        NOT NULL,
  owner        text        NOT NULL DEFAULT 'unknown',
  key_prefix   text        NOT NULL,
  key_hash     text        NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);

CREATE INDEX IF NOT EXISTS api_keys_owner_idx      ON api_keys (owner);
CREATE INDEX IF NOT EXISTS api_keys_created_at_idx ON api_keys (created_at DESC);
`;

/**
 * Run migrations under a Postgres advisory lock.
 *
 * WHY the lock: every replica runs this on boot, simultaneously during a rolling
 * update. Concurrent `CREATE INDEX IF NOT EXISTS` on the same relation is not
 * safe — it deadlocks or errors with "tuple concurrently updated", which
 * surfaces as a random CrashLoop on one replica only. The advisory lock
 * serialises them; the losers block briefly then find the work already done.
 */
export async function migrate(): Promise<void> {
  const client = await pool.connect();
  try {
    // Arbitrary but stable key, unique to this application's schema.
    await client.query("SELECT pg_advisory_lock($1)", [0x6d63_7062]);
    try {
      // pgcrypto supplies gen_random_uuid() on PostgreSQL < 13; on 13+ it is
      // built in, but the extension is harmless and keeps the DDL portable.
      // Created explicitly in `public` because the connection's search_path no
      // longer includes it, and an extension belongs in one shared place rather
      // than once per environment schema.
      await client.query("CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public");
      // The schema must exist before search_path can resolve to it. Identifier
      // is validated at module load, then quoted.
      await client.query(`CREATE SCHEMA IF NOT EXISTS "${SCHEMA_NAME}"`);
      // gen_random_uuid() below resolves via pg_catalog, which is implicitly on
      // the search path regardless of the `options` override, so the DDL does
      // not need qualifying.
      await client.query(SCHEMA);
      logger.info("database schema is up to date", { schema: SCHEMA_NAME });
    } finally {
      await client.query("SELECT pg_advisory_unlock($1)", [0x6d63_7062]);
    }
  } finally {
    client.release();
  }
}

/** Cheap liveness check for the readiness probe. */
export async function isHealthy(): Promise<boolean> {
  try {
    await pool.query("SELECT 1");
    return true;
  } catch (err) {
    logger.error("database health check failed", { error: (err as Error).message });
    return false;
  }
}

export async function closePool(): Promise<void> {
  await pool.end();
}
