import {
  hasPortalApiRole,
  isSafePortalApiPath,
  PORTAL_API_ORIGIN,
  portalApiRequiredRole,
  portalApiUpstreamHeaders,
  portalApiUpstreamURL,
} from "@/lib/portal-api-bff";
import { paasIdentity, paasSession } from "@/lib/require-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteHandlerContext = {
  params: Promise<{ path: string[] }>;
};

const RESPONSE_HEADERS = [
  "content-type",
  "content-disposition",
  "location",
  "retry-after",
  "etag",
  "last-modified",
] as const;

function problem(status: number, title: string, detail: string): Response {
  return Response.json(
    {
      type: "about:blank",
      title,
      status,
      detail,
    },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
        "Content-Type": "application/problem+json",
      },
    },
  );
}

async function forward(request: Request, context: RouteHandlerContext): Promise<Response> {
  const session = await paasSession();
  if (!session?.user) {
    return problem(401, "인증 필요", "외부 OIDC 로그인 세션이 필요합니다.");
  }

  const { requester, roles } = paasIdentity(session);
  if (!requester) {
    return problem(401, "인증 정보 불완전", "로그인 사용자 식별자를 확인할 수 없습니다.");
  }

  const role = portalApiRequiredRole(request.method);
  if (!hasPortalApiRole(roles, role)) {
    return problem(403, "권한 없음", `${role} 역할이 필요합니다.`);
  }

  const { path } = await context.params;
  if (!Array.isArray(path) || !isSafePortalApiPath(path)) {
    return problem(404, "API 경로 없음", "전달할 API 경로를 찾을 수 없습니다.");
  }

  const hasBody = request.method !== "GET" && request.method !== "HEAD";
  const init: RequestInit & { duplex?: "half" } = {
    method: request.method,
    headers: portalApiUpstreamHeaders(request.headers, requester),
    body: hasBody ? request.body : undefined,
    cache: "no-store",
    redirect: "manual",
    signal: AbortSignal.any([request.signal, AbortSignal.timeout(30_000)]),
    ...(hasBody ? { duplex: "half" as const } : {}),
  };

  let upstream: Response;
  try {
    upstream = await fetch(
      portalApiUpstreamURL(request.url, path, PORTAL_API_ORIGIN),
      init,
    );
  } catch {
    return problem(502, "Portal API 연결 실패", "내부 Portal API가 응답하지 않습니다.");
  }

  const headers = new Headers({ "Cache-Control": "no-store" });
  for (const name of RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("X-Content-Type-Options", "nosniff");

  return new Response(request.method === "HEAD" ? null : upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
}

export const GET = forward;
export const HEAD = forward;
export const POST = forward;
export const PUT = forward;
export const PATCH = forward;
export const DELETE = forward;
