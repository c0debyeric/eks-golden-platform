/**
 * API key issuance and lifecycle, persisted in PostgreSQL.
 *
 * SECURITY MODEL — the plaintext key is shown EXACTLY ONCE, at creation, and is
 * never stored. Only a SHA-256 digest goes to the database, so a dump of
 * `api_keys` (or a read-replica leak, or a snapshot restored to a laptop) yields
 * nothing usable. This is the same reason password hashes exist; the previous
 * frontend-only implementation generated keys with `Math.random()` in the
 * browser and stored nothing at all, which is neither secret nor durable.
 *
 * WHY SHA-256 and not bcrypt/argon2: API keys here are 256 bits of CSPRNG output,
 * not user-chosen passwords. There is no dictionary to attack and no meaningful
 * offline-cracking risk, so a slow KDF buys nothing and would add ~100ms to every
 * verification. Key stretching protects LOW-entropy secrets; this secret is
 * high-entropy by construction.
 */
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { pool } from "./db.js";

/** Human-recognisable prefix so a leaked key is greppable and attributable. */
const KEY_PREFIX = "egp_";
/** 32 bytes = 256 bits of entropy, base64url-encoded to 43 chars. */
const KEY_BYTES = 32;

export type ApiKeyRecord = {
  id: string;
  name: string;
  owner: string;
  keyPrefix: string;
  createdAt: string;
  lastUsedAt: string | null;
  revokedAt: string | null;
};

/** Only ever returned from `createApiKey`, and only once. */
export type CreatedApiKey = ApiKeyRecord & { key: string };

type Row = {
  id: string;
  name: string;
  owner: string;
  key_prefix: string;
  created_at: Date;
  last_used_at: Date | null;
  revoked_at: Date | null;
};

const toRecord = (row: Row): ApiKeyRecord => ({
  id: row.id,
  name: row.name,
  owner: row.owner,
  keyPrefix: row.key_prefix,
  createdAt: row.created_at.toISOString(),
  lastUsedAt: row.last_used_at?.toISOString() ?? null,
  revokedAt: row.revoked_at?.toISOString() ?? null,
});

const hashKey = (key: string): string =>
  createHash("sha256").update(key, "utf8").digest("hex");

/**
 * Mint a new key. The returned `key` field is the ONLY time the caller can see
 * the plaintext — it is not recoverable afterwards.
 */
export async function createApiKey(name: string, owner: string): Promise<CreatedApiKey> {
  // base64url avoids '+' and '/', which would otherwise need escaping every time
  // the key travels in a URL, header or shell command.
  const key = `${KEY_PREFIX}${randomBytes(KEY_BYTES).toString("base64url")}`;

  // Store enough of the key to identify it in a list view without being enough
  // to reconstruct it: prefix + 6 chars is ~36 bits, useless as a credential.
  const keyPrefix = key.slice(0, KEY_PREFIX.length + 6);

  const { rows } = await pool.query<Row>(
    `INSERT INTO api_keys (name, owner, key_prefix, key_hash)
     VALUES ($1, $2, $3, $4)
     RETURNING id, name, owner, key_prefix, created_at, last_used_at, revoked_at`,
    [name, owner, keyPrefix, hashKey(key)],
  );

  // A RETURNING clause on a successful single-row INSERT always yields a row;
  // this guard exists to satisfy noUncheckedIndexedAccess, not because it is
  // reachable.
  const row = rows[0];
  if (!row) throw new Error("INSERT ... RETURNING produced no row");

  return { ...toRecord(row), key };
}

/** List keys for an owner, newest first. Never includes key material. */
export async function listApiKeys(owner: string, limit = 100): Promise<ApiKeyRecord[]> {
  const { rows } = await pool.query<Row>(
    `SELECT id, name, owner, key_prefix, created_at, last_used_at, revoked_at
       FROM api_keys
      WHERE owner = $1
      ORDER BY created_at DESC
      LIMIT $2`,
    [owner, limit],
  );
  return rows.map(toRecord);
}

/**
 * Soft-delete: stamp `revoked_at` rather than DELETE.
 *
 * WHY not a hard delete: the row is the audit record. Hard-deleting destroys the
 * evidence of which key was live during an incident window, and it also frees
 * the `key_hash` unique constraint, so a future key could theoretically collide
 * with one you have no record of ever issuing.
 *
 * Scoped by owner so a caller cannot revoke someone else's key by guessing a
 * UUID (an IDOR — OWASP A01 Broken Access Control).
 */
export async function revokeApiKey(id: string, owner: string): Promise<ApiKeyRecord | null> {
  const { rows } = await pool.query<Row>(
    `UPDATE api_keys
        SET revoked_at = now()
      WHERE id = $1 AND owner = $2 AND revoked_at IS NULL
      RETURNING id, name, owner, key_prefix, created_at, last_used_at, revoked_at`,
    [id, owner],
  );
  return rows[0] ? toRecord(rows[0]) : null;
}

/**
 * Verify a presented key and record the usage. Returns the owning record, or
 * null if the key is unknown or revoked.
 *
 * The lookup is by hash, so the database index does the work and the plaintext
 * never appears in a query log. `timingSafeEqual` guards the final comparison;
 * with a hashed unique-index lookup the timing channel is already negligible,
 * but the constant-time compare costs nothing and removes the argument.
 */
export async function verifyApiKey(presented: string): Promise<ApiKeyRecord | null> {
  if (!presented.startsWith(KEY_PREFIX)) return null;

  const digest = hashKey(presented);
  const { rows } = await pool.query<Row & { key_hash: string }>(
    `SELECT id, name, owner, key_prefix, key_hash, created_at, last_used_at, revoked_at
       FROM api_keys
      WHERE key_hash = $1 AND revoked_at IS NULL`,
    [digest],
  );

  const row = rows[0];
  if (!row) return null;

  const a = Buffer.from(row.key_hash, "hex");
  const b = Buffer.from(digest, "hex");
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;

  // Fire-and-forget: last_used_at is telemetry, not correctness. Awaiting it
  // would put a write on the hot path of every authenticated request.
  void pool
    .query("UPDATE api_keys SET last_used_at = now() WHERE id = $1", [row.id])
    .catch(() => undefined);

  return toRecord(row);
}
