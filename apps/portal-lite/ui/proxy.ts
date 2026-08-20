import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

import { auth } from "./auth";

function securedProxy(request: NextRequest & { auth?: unknown }) {
  // `/api/v1/**`의 인증·역할 검사는 catch-all Route Handler가 데이터 소스 바로 앞에서
  // 다시 수행한다. Proxy에서 먼저 막으면 개발 전용 세션 우회와 Problem Details 응답이
  // 화면 경계와 달라지므로, 여기서는 CSP와 공통 보안 헤더만 적용한다.
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const contentSecurityPolicy = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    `style-src 'self' 'nonce-${nonce}'`,
    "connect-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "upgrade-insecure-requests",
  ].join("; ");

  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-nonce", nonce);
  requestHeaders.set("Content-Security-Policy", contentSecurityPolicy);
  /*
   * 서버 컴포넌트(특히 layout)는 자기 경로를 알 수 없다.
   * 로그인 게이트가 "원래 가려던 주소"로 돌려보내려면 경로가 필요하므로 여기서 넘긴다.
   * 프리페치 요청은 matcher 의 missing 조건으로 제외되어 이 헤더가 없고,
   * 그때는 게이트가 `/portal` 로만 보낸다.
   */
  requestHeaders.set(
    "x-pathname",
    `${request.nextUrl.pathname}${request.nextUrl.search}`,
  );

  const response = NextResponse.next({ request: { headers: requestHeaders } });
  response.headers.set("Content-Security-Policy", contentSecurityPolicy);
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  response.headers.set("Referrer-Policy", "no-referrer");
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("X-Frame-Options", "DENY");
  response.headers.set("Cross-Origin-Opener-Policy", "same-origin");
  response.headers.set("Cross-Origin-Resource-Policy", "same-origin");
  return response;
}

export const proxy = auth(securedProxy);

export const config = {
  matcher: [
    {
      source: "/((?!api/auth|_next/static|_next/image|favicon.ico).*)",
      missing: [
        { type: "header", key: "next-router-prefetch" },
        { type: "header", key: "purpose", value: "prefetch" },
      ],
    },
  ],
};
