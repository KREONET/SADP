import { NextResponse } from "next/server";

import { auth } from "../../../../auth";

export const dynamic = "force-dynamic";

export async function GET() {
  const session = await auth();
  if (!session?.user) return NextResponse.json({ error: "authentication_required" }, { status: 401 });

  const baseUrl = process.env.NMS_API_BASE_URL;
  const statusPath = process.env.NMS_API_STATUS_PATH;
  const requiredRole = process.env.NMS_REQUIRED_ROLE;
  if (!baseUrl || !statusPath || !requiredRole) {
    return NextResponse.json({ error: "nms_integration_not_configured" }, { status: 503 });
  }

  const roles = new Set([...session.user.realmRoles, ...session.user.clientRoles]);
  if (!roles.has(requiredRole)) return NextResponse.json({ error: "forbidden" }, { status: 403 });

  let target: URL;
  try {
    const base = new URL(baseUrl);
    if (!['http:', 'https:'].includes(base.protocol)) throw new Error("unsupported protocol");
    target = new URL(statusPath, base.toString().endsWith("/") ? base : `${base}/`);
    if (target.origin !== base.origin) throw new Error("status path escapes NMS origin");
  } catch {
    return NextResponse.json({ error: "invalid_nms_configuration" }, { status: 503 });
  }

  const headers = new Headers({ Accept: "application/json" });
  if (process.env.NMS_API_TOKEN) headers.set("Authorization", `Bearer ${process.env.NMS_API_TOKEN}`);

  try {
    const response = await fetch(target, {
      method: "GET",
      headers,
      cache: "no-store",
      redirect: "error",
      signal: AbortSignal.timeout(5_000),
    });
    return new Response(response.body, {
      status: response.status,
      headers: {
        "Cache-Control": "no-store",
        "Content-Type": response.headers.get("Content-Type") ?? "application/octet-stream",
      },
    });
  } catch {
    return NextResponse.json({ error: "nms_upstream_unavailable" }, { status: 502 });
  }
}
