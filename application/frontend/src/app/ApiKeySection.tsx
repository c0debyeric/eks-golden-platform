"use client";

/**
 * API key management UI.
 *
 * Replaces the previous client-side `Math.random()` generator, which produced a
 * string that was neither cryptographically random nor stored anywhere — it
 * vanished on refresh. Keys are now minted by the backend with a CSPRNG and
 * persisted in RDS; the browser only ever sees the plaintext once, in the
 * response to the create call.
 */

import { useCallback, useEffect, useState } from "react";

type ApiKey = {
  id: string;
  name: string;
  keyPrefix: string;
  createdAt: string;
  lastUsedAt: string | null;
  revokedAt: string | null;
};

type CreatedApiKey = ApiKey & { key: string };

const errorFrom = async (response: Response): Promise<string> => {
  const body = (await response.json().catch(() => ({}))) as { error?: string };
  return body.error ?? `Request failed (${response.status})`;
};

export default function ApiKeySection() {
  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [name, setName] = useState("");
  const [freshKey, setFreshKey] = useState<CreatedApiKey | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const response = await fetch("/api/keys");
      if (!response.ok) throw new Error(await errorFrom(response));
      const { keys: fetched } = (await response.json()) as { keys: ApiKey[] };
      setKeys(fetched);
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function handleCreate(event: React.FormEvent) {
    event.preventDefault();
    if (!name.trim() || busy) return;

    setBusy(true);
    setError(null);
    try {
      const response = await fetch("/api/keys", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: name.trim() }),
      });
      if (!response.ok) throw new Error(await errorFrom(response));
      setFreshKey((await response.json()) as CreatedApiKey);
      setName("");
      await refresh();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function handleRevoke(id: string) {
    setBusy(true);
    setError(null);
    try {
      const response = await fetch(`/api/keys/${id}`, { method: "DELETE" });
      if (!response.ok) throw new Error(await errorFrom(response));
      // If the revoked key is the one still on screen, clear it — leaving a
      // dead secret displayed invites someone to copy it into a config.
      setFreshKey((current) => (current?.id === id ? null : current));
      await refresh();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="w-full max-w-3xl px-6 py-10">
      <form onSubmit={handleCreate} className="flex flex-col gap-3 sm:flex-row">
        <input
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder="Key name, e.g. ci-pipeline"
          maxLength={120}
          className="flex-1 rounded-full border border-black/10 bg-white px-5 py-3 text-black outline-none focus:border-black/40 dark:border-white/15 dark:bg-zinc-900 dark:text-white"
        />
        <button
          type="submit"
          disabled={busy || !name.trim()}
          className="h-12 rounded-full bg-black px-6 font-medium text-white transition-colors hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-40 dark:bg-white dark:text-black dark:hover:bg-zinc-200"
        >
          {busy ? "Working…" : "Generate key"}
        </button>
      </form>

      {error && (
        <p
          role="alert"
          className="mt-4 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300"
        >
          {error}
        </p>
      )}

      {freshKey && (
        <div className="mt-6 rounded-xl border border-amber-300 bg-amber-50 p-4 dark:border-amber-800 dark:bg-amber-950">
          <p className="text-sm font-semibold text-amber-900 dark:text-amber-200">
            Copy this key now — it is stored only as a hash and cannot be shown again.
          </p>
          <code className="mt-2 block break-all rounded-lg bg-white px-3 py-2 font-mono text-sm text-black dark:bg-black dark:text-white">
            {freshKey.key}
          </code>
          <button
            onClick={() => void navigator.clipboard.writeText(freshKey.key)}
            className="mt-3 rounded-full border border-amber-400 px-4 py-1.5 text-sm font-medium text-amber-900 hover:bg-amber-100 dark:text-amber-200 dark:hover:bg-amber-900"
          >
            Copy to clipboard
          </button>
        </div>
      )}

      <h2 className="mt-10 text-lg font-semibold text-black dark:text-white">Your keys</h2>

      {loading ? (
        <p className="mt-3 text-sm text-zinc-500">Loading…</p>
      ) : keys.length === 0 ? (
        <p className="mt-3 text-sm text-zinc-500">No keys yet.</p>
      ) : (
        <ul className="mt-3 divide-y divide-black/5 dark:divide-white/10">
          {keys.map((key) => (
            <li key={key.id} className="flex items-center justify-between gap-4 py-3">
              <div className="min-w-0">
                <p className="truncate font-medium text-black dark:text-white">
                  {key.name}
                  {key.revokedAt && (
                    <span className="ml-2 rounded-full bg-zinc-200 px-2 py-0.5 text-xs font-normal text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
                      revoked
                    </span>
                  )}
                </p>
                <p className="font-mono text-xs text-zinc-500">
                  {key.keyPrefix}… · created {new Date(key.createdAt).toLocaleString()}
                </p>
              </div>
              {!key.revokedAt && (
                <button
                  onClick={() => void handleRevoke(key.id)}
                  disabled={busy}
                  className="shrink-0 rounded-full border border-black/10 px-4 py-1.5 text-sm hover:bg-black/5 disabled:opacity-40 dark:border-white/15 dark:hover:bg-white/10"
                >
                  Revoke
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}