/**
 * Server-side client for the mcp-backend REST API.
 *
 * This module must only ever be imported from server components / route
 * handlers. The backend Service is ClusterIP, so the browser cannot reach it at
 * all — every call is made from the Next.js Node process inside the cluster and
 * proxied out through the route handlers in src/app/api.
 *
 * WHY proxy rather than call the backend from the browser: a ClusterIP Service
 * has no route from outside the cluster, so exposing it would mean a second
 * Ingress and a public, unauthenticated API. Proxying keeps exactly one public
 * surface (the frontend's own origin) and keeps the owner identity server-side
 * where a user cannot forge it.
 */
import "server-only";

/** In-cluster DNS name of the backend Service; overridden per environment. */
const BACKEND_URL = process.env.BACKEND_URL ?? "http://mcp-backend.mcp-dev.svc.cluster.local";

/**
 * The identity all keys are filed under.
 *
 * The platform has no IdP wired up yet, so this is a single fixed tenant rather
 * than a per-user identity. It is resolved SERVER-SIDE and injected into the
 * upstream request; the browser never supplies it, so a user cannot read another
 * owner's keys by tampering with a request. When OIDC lands, this is the one
 * function that changes.
 */
export const resolveOwner = (): string => process.env.APP_OWNER ?? "demo";

export type ApiKey = {
  id: string;
  name: string;
  owner: string;
  keyPrefix: string;
  createdAt: string;
  lastUsedAt: string | null;
  revokedAt: string | null;
};

/** Only present on the response to a create call — never retrievable again. */
export type CreatedApiKey = ApiKey & { key: string };

export class BackendError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "BackendError";
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${BACKEND_URL}${path}`, {
      ...init,
      headers: {
        "content-type": "application/json",
        "x-owner": resolveOwner(),
        ...init.headers,
      },
      // API keys are mutable state; a cached list would show revoked keys as
      // live. Next.js caches fetch aggressively by default, so this is required.
      cache: "no-store",
      // Bound the wait so a wedged backend surfaces as a 502 rather than hanging
      // the request until the ALB's own idle timeout.
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    throw new BackendError(`Backend unreachable: ${(err as Error).message}`, 502);
  }

  if (!response.ok) {
    // Surface the backend's message when it sent one, but never its raw body —
    // that could carry internal detail we do not want on a public page.
    const detail = await response
      .json()
      .then((body: { error?: string }) => body.error)
      .catch(() => undefined);
    throw new BackendError(detail ?? `Backend returned ${response.status}`, response.status);
  }

  return (await response.json()) as T;
}

export const listKeys = (): Promise<{ keys: ApiKey[] }> => request("/api/keys");

export const createKey = (name: string): Promise<CreatedApiKey> =>
  request("/api/keys", { method: "POST", body: JSON.stringify({ name }) });

export const revokeKey = (id: string): Promise<ApiKey> =>
  request(`/api/keys/${encodeURIComponent(id)}`, { method: "DELETE" });
