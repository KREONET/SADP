import type { Session } from "next-auth";

/**
 * Auth.js가 access token 갱신에 실패하면 기존 사용자 claim이 세션에 남아 있더라도
 * 권한 판단에 재사용하지 않는다. 다시 로그인하기 전까지는 인증되지 않은 세션이다.
 */
export function isUsablePaasSession(
  session: Session | null | undefined,
): session is Session {
  return Boolean(session?.user) && session?.error !== "RefreshTokenError";
}
