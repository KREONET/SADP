import { headers } from "next/headers";
import { forbidden, redirect } from "next/navigation";
import type { Session } from "next-auth";

import { auth } from "@/auth";
import { isUsablePaasSession } from "@/lib/paas-session-policy";
import {
  hasPortalApiRole,
  type PortalApiRole,
} from "@/lib/portal-api-bff";

/**
 * PaaS 화면(`app/(paas)/**`) 공통 로그인 게이트.
 *
 * - 로그인 O → 세션을 그대로 돌려준다.
 * - 로그인 X + 홈(`/`) → 기존 SADP 메인(`/portal`)
 * - 로그인 X + 그 외 → `/login?callbackUrl=<원래 주소>` 로 보내고,
 *   로그인 성공 후 원래 가려던 화면으로 되돌린다.
 *
 * 경로는 서버 컴포넌트가 스스로 알 수 없어서 proxy.ts 가 넣어주는
 * `x-pathname` 헤더에 의존한다. 프리페치 요청처럼 헤더가 없으면 `/` 로 간주한다.
 */
export async function requirePaasSession(): Promise<Session> {
  const session = await paasSession();
  if (session) return session;

  const requestPath = (await headers()).get("x-pathname") ?? "/";
  if (requestPath === "/") redirect("/portal");
  redirect(`/login?callbackUrl=${encodeURIComponent(requestPath)}`);
}

/**
 * 리다이렉트 없이 현재 PaaS 세션을 읽는다.
 *
 * 공개 HTTP 엔드포인트인 Route Handler에서는 `requirePaasSession()`의 로그인 화면
 * 리다이렉트 대신 401 Problem Details를 돌려줘야 한다. Auth.js와 개발 우회 판정은
 * 화면과 API가 서로 달라지지 않도록 이 함수 하나를 공유한다.
 */
export async function paasSession(): Promise<Session | null> {
  const session = await auth();
  // claim이 남아 있더라도 갱신 실패 토큰으로 권한을 계속 행사하면 안 된다. 이 경우는
  // 명시적인 개발 우회도 적용하지 않고 다시 로그인하게 한다.
  if (session?.error === "RefreshTokenError") return null;
  if (isUsablePaasSession(session)) return session;
  return devBypassSession();
}

/**
 * 서버 컴포넌트가 내부 Portal API를 읽기 전에 쓰는 공통 권한 게이트.
 * Route Handler와 같은 역할 호환표를 사용하므로 화면과 BFF의 허용 범위가 갈리지 않는다.
 */
export async function requirePaasRole(required: PortalApiRole): Promise<Session> {
  const session = await requirePaasSession();
  if (!hasPortalApiRole(paasIdentity(session).roles, required)) forbidden();
  return session;
}

/**
 * 개발 서버 전용 로그인 우회. 외부 OIDC client 자격증명 없이 `(paas)` 화면을
 * 열기 위한 장치다.
 *
 * 🔴 인증을 끄는 코드이므로 두 조건을 **모두** 만족할 때만 동작한다.
 *   1. `NODE_ENV === "development"` — `next build` 산출물은 "production" 이라
 *      이 분기 자체가 죽는다. standalone 서버로는 켤 수 없다.
 *   2. `PAAS_DEV_AUTH_BYPASS === "true"` — 개발자가 명시적으로 켜야 한다.
 *      기본값이 없으므로 변수를 빠뜨리면 평소대로 로그인 화면으로 간다.
 *
 * 이 변수는 `.env.development`(gitignore 대상)에만 둔다. 배포 values 에 들어가는
 * 것은 `scripts/ci-guard.sh` 가 차단한다.
 */
function devBypassSession(): Session | null {
  if (process.env.NODE_ENV !== "development") return null;
  if (process.env.PAAS_DEV_AUTH_BYPASS !== "true") return null;

  const username = process.env.PAAS_DEV_USER?.trim() || "dev-user";
  // 화면2 대시보드와 화면7 카탈로그가 역할로 노출을 거르므로 기본값을 넉넉히 준다.
  const roles = (
    process.env.PAAS_DEV_ROLES ??
    "platform-admin,developer,viewer,deployments:read,deployments:write"
  )
    .split(",")
    .map((role) => role.trim())
    .filter(Boolean);

  return {
    user: {
      id: `dev:${username}`,
      username,
      name: username,
      email: `${username}@dev.invalid`,
      groups: roles,
      realmRoles: roles,
      clientRoles: [],
    },
    expires: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
  };
}

/**
 * 백엔드 조회에 쓸 사용자 식별자.
 *
 * `requester` 는 Go API 가 배포 신청을 저장·필터링하는 키다. 이 값이 비면
 * 목록 API 가 전체를 돌려주므로, 데이터 계층에서 "빈 requester = 빈 목록"으로 막는다.
 * OIDC `preferred_username`을 1순위로 쓰고, 없으면 `sub`로 떨어진다.
 */
export function paasIdentity(session: Session): {
  requester: string;
  roles: string[];
} {
  const user = session.user;
  // 현재 realm bootstrap은 권한 이름을 groups claim으로 주는 배포도 있고,
  // deployments:*를 client role로 주는 배포도 있다. 어느 claim에서 왔는지와 무관하게
  // 권한 판정이 같도록 합치되 중복은 제거한다.
  const roles = new Set([
    ...(user?.groups ?? []),
    ...(user?.realmRoles ?? []),
    ...(user?.clientRoles ?? []),
  ]);
  return {
    requester: user?.username?.trim() || user?.id?.trim() || "",
    roles: [...roles],
  };
}
