import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { auth } from "@/auth";
import { signOutFromOIDC } from "@/app/auth-actions";
import { getI18n } from "@/lib/i18n/server";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return {
    title: dict.legacy.account.metaTitle,
    robots: { index: false, follow: false },
  };
}

export default async function AccountPage() {
  const session = await auth();
  // 갱신에 실패한 JWT에는 user claim이 남으므로 user 유무만 보면 만료 세션을
  // 계정 화면에서 계속 사용하게 된다. 공통 로그인 복구 화면에서 세션을 지우고
  // 새 authorization 요청을 만들 수 있도록 즉시 그쪽으로 보낸다.
  if (!session?.user || session.error === "RefreshTokenError") {
    redirect("/login?callbackUrl=/account");
  }

  const { dict } = await getI18n();
  const t = dict.legacy.account;

  return (
    <main className="auth-page">
      <section className="auth-card account-card" aria-labelledby="account-title">
        <p className="eyebrow">{t.eyebrow}</p>
        <h1 id="account-title">{t.title}</h1>
        <p>{t.description}</p>
        <dl className="account-details">
          <div><dt>{t.username}</dt><dd>{session.user.username ?? t.none}</dd></div>
          <div><dt>{t.name}</dt><dd>{session.user.name ?? t.none}</dd></div>
          <div><dt>{t.email}</dt><dd>{session.user.email ?? t.none}</dd></div>
          <div>
            <dt>{t.accessTokenExpiresAt}</dt>
            <dd>
              {session.accessTokenExpiresAt
                ? new Date(session.accessTokenExpiresAt).toISOString()
                : t.unknown}
            </dd>
          </div>
        </dl>
        <div className="account-actions">
          {/* 레거시 전역 CSS를 내리고 PaaS 전용 CSS만 다시 로드한다. */}
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages -- CSS 경계를 넘을 때는 전체 페이지 이동이 필요하다. */}
          <a className="button secondary" href="/">{t.home}</a>
          <form action={signOutFromOIDC}>
            <button className="button primary" type="submit">{t.signOut}</button>
          </form>
        </div>
      </section>
    </main>
  );
}
