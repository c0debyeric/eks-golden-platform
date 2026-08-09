/**
 * REST API consumed by the frontend.
 *
 * This sits alongside the MCP endpoint rather than replacing it: MCP is the
 * machine/agent interface (JSON-RPC over Streamable HTTP), while the Next.js UI
 * needs plain CRUD. Sharing one process means one connection pool and one
 * deployment, and the two surfaces operate on the same `api_keys` table.
 *
 * The frontend calls these routes SERVER-SIDE (Next.js route handlers proxy to
 * the ClusterIP Service), so this API is never exposed to the browser directly
 * and stays internal to the cluster.
 */
import { Router, type Request, type RequestHandler, type Response } from "express";
import { z } from "zod";

import { createApiKey, listApiKeys, revokeApiKey, verifyApiKey } from "./apiKeys.js";
import { logger } from "./logger.js";

/**
 * Identify the caller. The platform has no identity provider wired up yet, so
 * the owner comes from a header the frontend sets.
 *
 * This is a TRUST BOUNDARY and it is deliberately narrow: the header is only
 * meaningful because the Service is ClusterIP and the only client is the
 * frontend pod. If this API is ever fronted by an Ingress, this MUST be replaced
 * with a verified identity (OIDC token subject), or any caller could read any
 * owner's keys by setting a header. Flagged here rather than left implicit.
 */
const OWNER_HEADER = "x-owner";
const ownerSchema = z
  .string()
  .trim()
  .min(1)
  .max(128)
  // Constrain the charset so the value cannot smuggle newlines into logs
  // (log injection) or odd bytes into the database.
  .regex(/^[A-Za-z0-9._@-]+$/, "owner may contain only letters, digits and . _ @ -");

function resolveOwner(req: Request): string | null {
  const raw = req.header(OWNER_HEADER);
  const parsed = ownerSchema.safeParse(raw ?? "");
  return parsed.success ? parsed.data : null;
}

const createSchema = z.object({
  name: z.string().trim().min(1, "name is required").max(120),
});

// Reject anything that is not a canonical UUID before it reaches Postgres —
// otherwise a malformed id produces a 500 (invalid input syntax for type uuid)
// where a 400 is correct.
const idSchema = z.string().uuid();

const fail = (res: Response, status: number, message: string): void => {
  res.status(status).json({ error: message });
};

export const apiRouter = Router();

/**
 * Gate the owner-scoped routes.
 *
 * Applied per-route rather than via `apiRouter.use`, because /keys/verify
 * authenticates with the key itself and must NOT require an owner header —
 * the caller presenting a key generally does not know whose it is, and
 * trusting a header there would be meaningless anyway.
 */
const requireOwner: RequestHandler = (req, res, next) => {
  const owner = resolveOwner(req);
  if (!owner) {
    fail(res, 400, `Missing or invalid ${OWNER_HEADER} header.`);
    return;
  }
  res.locals.owner = owner;
  next();
};

apiRouter.get("/keys", requireOwner, async (_req: Request, res: Response) => {
  const owner = res.locals.owner as string;
  try {
    res.json({ keys: await listApiKeys(owner) });
  } catch (err) {
    logger.error("listing api keys failed", { error: (err as Error).message });
    fail(res, 500, "Could not list API keys.");
  }
});

apiRouter.post("/keys", requireOwner, async (req: Request, res: Response) => {
  const owner = res.locals.owner as string;
  const parsed = createSchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    fail(res, 400, parsed.error.issues[0]?.message ?? "Invalid request body.");
    return;
  }

  try {
    const created = await createApiKey(parsed.data.name, owner);
    // The `key` field here is the one and only time the plaintext exists outside
    // the caller's own memory. Note it is NOT logged.
    logger.info("api key created", { id: created.id, owner, name: created.name });
    res.status(201).json(created);
  } catch (err) {
    logger.error("creating api key failed", { error: (err as Error).message });
    fail(res, 500, "Could not create the API key.");
  }
});

apiRouter.delete("/keys/:id", requireOwner, async (req: Request, res: Response) => {
  const owner = res.locals.owner as string;
  const parsed = idSchema.safeParse(req.params.id);
  if (!parsed.success) {
    fail(res, 400, "Invalid key id.");
    return;
  }

  try {
    const revoked = await revokeApiKey(parsed.data, owner);
    if (!revoked) {
      // Same response whether the key belongs to someone else or does not
      // exist — distinguishing them would leak the existence of other owners'
      // key ids.
      fail(res, 404, "No such active API key.");
      return;
    }
    logger.info("api key revoked", { id: revoked.id, owner });
    res.json(revoked);
  } catch (err) {
    logger.error("revoking api key failed", { error: (err as Error).message });
    fail(res, 500, "Could not revoke the API key.");
  }
});

/**
 * Verify a key. Useful for demonstrating that issuance actually persists, and
 * as the hook a future authenticating proxy would call.
 */
apiRouter.post("/keys/verify", async (req: Request, res: Response) => {
  const parsed = z.object({ key: z.string().min(1) }).safeParse(req.body ?? {});
  if (!parsed.success) {
    fail(res, 400, "A key is required.");
    return;
  }

  try {
    const record = await verifyApiKey(parsed.data.key);
    if (!record) {
      fail(res, 401, "Invalid or revoked API key.");
      return;
    }
    res.json({ valid: true, key: record });
  } catch (err) {
    logger.error("verifying api key failed", { error: (err as Error).message });
    fail(res, 500, "Could not verify the API key.");
  }
});
