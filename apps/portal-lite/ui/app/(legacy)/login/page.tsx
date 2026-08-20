import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { auth, signIn, signOut } from "@/auth";
import { getI18n } from "@/lib/i18n/server";
import {
  needsAuthenticationRecovery,
  safeLoginCallback,
  startKeycloakLogin,
} from "@/lib/login-flow";
import { isUsablePaasSession } from "@/lib/paas-session-policy";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return {
    title: dict.legacy.login.metaTitle,
    robots: { index: false, follow: false },
  };
}

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{
    callbackUrl?: string | string[];
    error?: string | string[];
  }>;
}) {
  const params = await searchParams;
  const callbackUrl = safeLoginCallback(params.callbackUrl);
  const session = await auth();
  const refreshFailed = session?.error === "RefreshTokenError";
  const recovery = needsAuthenticationRecovery(params.error, refreshFailed);
  // 갱신에 실패한 JWT에도 기존 user claim은 남는다. 그것을 로그인 완료로 보면
  // 보호 페이지는 다시 /login으로 보내고 이 페이지는 되돌려 보내는 loop가 생긴다.
  // 새 OAuth 시도에서 오류가 난 경우도 기존 세션으로 자동 복귀시키지 않고 사용자가
  // 명시적으로 복구 버튼을 누르게 해야 오래된 탭의 자동 redirect loop를 막을 수 있다.
  if (!recovery && isUsablePaasSession(session)) redirect(callbackUrl);

  const { dict, locale } = await getI18n();
  const t = dict.legacy.login;

  return (
    <main className="auth-page">
      <section className="auth-card" aria-labelledby="login-title">
        <p className="eyebrow">{t.eyebrow}</p>
        <h1 id="login-title">{t.title}</h1>
        <p>{t.description}</p>
        {recovery && (
          <p className="auth-error" role="alert">
            {t.expired}
          </p>
        )}
        <form
          action={async () => {
            "use server";
            await startKeycloakLogin(
              { signIn, signOut },
              { callbackUrl, locale, fresh: recovery },
            );
          }}
        >
          <button className="button primary" type="submit">
            {recovery ? t.restart : t.submit}
          </button>
        </form>
        {/* 레거시/PaaS 전역 CSS 경계는 전체 페이지 이동으로 넘는다. */}
        {/* eslint-disable-next-line @next/next/no-html-link-for-pages -- CSS 경계를 넘을 때는 전체 페이지 이동이 필요하다. */}
        <a href="/">{t.backHome}</a>
      </section>
    </main>
  );
}
