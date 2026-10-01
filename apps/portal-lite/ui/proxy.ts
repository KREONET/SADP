import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

/*
 * Auth.js 세션 쿠키(분할 시 `.0`, `.1` …, HTTPS면 `__Secure-` 접두사). Proxy는 인증 모듈을
 * 쓰지 않으므로(아래 시험이 강제) 유효성은 판정하지 않고 "쿠키가 아예 없다 = 확실한 비로그인"만
 * 본다. 쿠키가 있는데 세션이 무효면 지금처럼 (paas) 로그인 게이트가 처리한다.
 */
const SESSION_COOKIE = /^(?:__Secure-)?authjs\.session-token(?:\.\d+)?$/;

// 내부 rewrite(`/` → `/portal`)도 Proxy를 다시 지난다. 표시가 없으면 아래 `/portal` → `/`
// redirect가 그 요청을 다시 밖으로 돌려 무한 redirect가 된다. 외부에서 이 헤더를 붙여도
// 주소 정리 redirect를 건너뛸 뿐 인증·권한 판정에는 쓰지 않는다.
const HOME_REWRITE_HEADER = "x-sadp-home-rewrite";

function hasSessionCookie(request: NextRequest): boolean {
  return request.cookies.getAll().some((cookie) => SESSION_COOKIE.test(cookie.name));
}

export function proxy(request: NextRequest) {
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

  /*
   * 주소창에 `/portal`이 남지 않게 한다. 비로그인 `/`는 메인 페이지를 내부 rewrite로 보여 주고
   * (주소는 `/` 그대로), 예전 `/portal` 링크·북마크는 `/`로 영구 이동시킨다.
   * - 로그인 쿠키가 있으면 둘 다 건드리지 않는다. `/`는 대시보드이고, 대시보드 권한이 없는
   *   사용자는 forbidden 화면의 `/portal` 링크로 메인 페이지에 남을 수 있어야 한다.
   * - 같은 주소가 쿠키에 따라 달라지므로 redirect도 no-store로 캐시를 막는다. 브라우저가 308을
   *   기억하면 로그인 뒤에도 `/portal`이 `/`로 가 버린다.
   */
  const anonymous = !hasSessionCookie(request);
  const pathname = request.nextUrl.pathname;
  let response: NextResponse;
  const rewritten = request.headers.get(HOME_REWRITE_HEADER) === "1";
  if (anonymous && pathname === "/portal" && !rewritten) {
    const target = new URL(`/${request.nextUrl.search}`, request.url);
    response = NextResponse.redirect(target, 308);
  } else if (anonymous && pathname === "/") {
    requestHeaders.set(HOME_REWRITE_HEADER, "1");
    response = NextResponse.rewrite(new URL(`/portal${request.nextUrl.search}`, request.url), {
      request: { headers: requestHeaders },
    });
  } else {
    response = NextResponse.next({ request: { headers: requestHeaders } });
  }
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
