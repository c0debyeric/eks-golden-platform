/**
 * Kubernetes probe endpoints.
 *
 * Deliberately does NOT check the backend or the database. A frontend replica
 * whose backend is briefly unavailable can still serve pages (it renders an
 * error state), so tying its readiness to a dependency would take the whole UI
 * out of the Service endpoints during a backend rollout — turning a partial
 * degradation into a full outage. This asserts only that Next.js is serving.
 */
import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export function GET(): NextResponse {
  return NextResponse.json({ status: "ok" });
}
