/**
 * Browser-facing API: list and create API keys.
 *
 * These handlers run on the Next.js server, so they can reach the ClusterIP
 * backend. They intentionally accept only a `name` from the client — the owner
 * is resolved server-side (see src/lib/backend.ts), so a caller cannot address
 * another tenant's keys.
 */
import { NextResponse } from "next/server";

import { BackendError, createKey, listKeys } from "@/lib/backend";

// Key state changes on every mutation, so this route must never be statically
// rendered or cached at build time.
export const dynamic = "force-dynamic";

function toErrorResponse(err: unknown): NextResponse {
  if (err instanceof BackendError) {
    return NextResponse.json({ error: err.message }, { status: err.status });
  }
  // Do not leak an unexpected stack/message to the browser.
  console.error("unexpected error in /api/keys", err);
  return NextResponse.json({ error: "Unexpected server error." }, { status: 500 });
}

export async function GET(): Promise<NextResponse> {
  try {
    return NextResponse.json(await listKeys());
  } catch (err) {
    return toErrorResponse(err);
  }
}

export async function POST(request: Request): Promise<NextResponse> {
  let name: unknown;
  try {
    ({ name } = (await request.json()) as { name?: unknown });
  } catch {
    return NextResponse.json({ error: "Body must be JSON." }, { status: 400 });
  }

  if (typeof name !== "string" || name.trim().length === 0 || name.length > 120) {
    return NextResponse.json(
      { error: "A name between 1 and 120 characters is required." },
      { status: 400 },
    );
  }

  try {
    // The response carries the plaintext key. This is the only moment it exists
    // outside the caller's browser, and it is deliberately not logged here.
    return NextResponse.json(await createKey(name.trim()), { status: 201 });
  } catch (err) {
    return toErrorResponse(err);
  }
}
