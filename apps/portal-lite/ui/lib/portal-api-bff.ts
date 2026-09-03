export type PortalApiRole = "deployments:read" | "deployments:write";

// Go API는 같은 Pod의 loopback listener만 연다. 신원 헤더를 붙이는 서버 호출이
// NEXT_PUBLIC 설정으로 외부 origin을 향하면 신뢰 경계가 다시 열리므로 변경 불가 상수다.
export const PORTAL_API_ORIGIN = "http://127.0.0.1:8081";

const REQUEST_HEADERS = ["accept", "content-type", "idempotency-key"] as const;
const READ_ROLES = new Set([
  "deployments:read",
  "deployments:write",
  "platform-admin",
  "app-admin",
  "developer",
  "viewer",
]);
const WRITE_ROLES = new Set([
  "deployments:write",
  "platform-admin",
  "app-admin",
  "developer",
]);

export function portalApiRequiredRole(method: string): PortalApiRole {
  return method === "GET" || method === "HEAD"
    ? "deployments:read"
    : "deployments:write";
}

/**
 * Portal API scope와 외부 OIDC 그룹의 역할을 하나의 권한 계약으로 해석한다.
 * 정확한 deployments:* scope를 우선 지원하되 viewer는 조회에서만 허용한다.
 */
export function hasPortalApiRole(
  roles: readonly string[],
  required: PortalApiRole,
): boolean {
  const allowed = required === "deployments:read" ? READ_ROLES : WRITE_ROLES;
  return roles.some((role) => allowed.has(role));
}

/** catch-all segment가 URL 정규화로 고정 `/api/v1/` 경계를 벗어나지 못하게 한다. */
export function isSafePortalApiPath(path: readonly string[]): boolean {
  return (
    path.length > 0 &&
    path.every(
      (part) =>
        part.length > 0 &&
        part !== "." &&
        part !== ".." &&
        !part.includes("/") &&
        !part.includes("\\") &&
        !/[\u0000-\u001f\u007f]/u.test(part),
    )
  );
}

/** 고정된 upstream origin 아래에 경로를 만들고 외부 requester 필터를 제거한다. */
export function portalApiUpstreamURL(
  requestURL: string,
  path: readonly string[],
  upstreamOrigin: string,
): URL {
  if (!isSafePortalApiPath(path)) {
    throw new TypeError("unsafe Portal API path");
  }
  const encodedPath = path.map((part) => encodeURIComponent(part)).join("/");
  const target = new URL(`/api/v1/${encodedPath}`, upstreamOrigin);
  const incoming = new URL(requestURL);
  for (const [key, value] of incoming.searchParams) {
    if (key.toLowerCase() === "requester") continue;
    target.searchParams.append(key, value);
  }
  return target;
}

/** 신원 헤더는 공개 요청에서 복사하지 않고 세션의 requester로 새로 만든다. */
export function portalApiUpstreamHeaders(
  incoming: Headers,
  requester: string,
): Headers {
  const headers = new Headers();
  for (const name of REQUEST_HEADERS) {
    const value = incoming.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("X-Portal-User", requester);
  return headers;
}

/** 서버 액션이 JSON Portal API를 직접 호출할 때도 BFF와 같은 신원 규칙을 쓴다. */
export function portalApiJsonHeaders(
  requester: string,
  idempotencyKey?: string,
): Headers {
  const incoming = new Headers({
    accept: "application/json",
    "content-type": "application/json",
  });
  if (idempotencyKey) incoming.set("Idempotency-Key", idempotencyKey);
  return portalApiUpstreamHeaders(incoming, requester);
}
