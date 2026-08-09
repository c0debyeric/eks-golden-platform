/** Revoke a single API key. */
import { NextResponse } from "next/server";

import { BackendError, revokeKey } from "@/lib/backend";

export const dynamic = "force-dynamic";

// Next.js 15+ passes route params as a Promise.
type Context = { params: Promise<{ id: string }> };

export async function DELETE(_request: Request, { params }: Context): Promise<NextResponse> {
  const { id } = await params;

  // Validate before forwarding so a malformed id is a 400 here rather than a
  // Postgres cast error deeper in the stack.
  const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id);
  if (!isUuid) {
    return NextResponse.json({ error: "Invalid key id." }, { status: 400 });
  }

  try {
    return NextResponse.json(await revokeKey(id));
  } catch (err) {
    if (err instanceof BackendError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("unexpected error revoking key", err);
    return NextResponse.json({ error: "Unexpected server error." }, { status: 500 });
  }
}
