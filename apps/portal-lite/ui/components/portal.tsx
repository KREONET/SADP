"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { signIn } from "next-auth/react";
import type { Session } from "next-auth";
import {
  ArrowRight,
  Boxes,
  CheckCircle2,
  GitPullRequest,
  KeyRound,
  LockKeyhole,
  ShieldCheck,
} from "lucide-react";

import { LocaleToggle } from "@/components/paas/locale-toggle";
import { signOutFromKeycloak } from "@/app/auth-actions";
import { useI18n } from "@/lib/i18n/context";

type CatalogResponse = {
  environment: string;
  baseDomain: string;
};

/**
 * 미인증 사용자가 처음 만나는 소개 화면.
 *
 * 실제 앱 등록/환경변수 분류는 (paas) 화면들이 담당하고, 여기서는 카탈로그의
 * `environment` 만 읽어 "지금 보고 있는 환경"을 알려준다.
 */
export function Portal({ session }: { session: Session | null }) {
  const { dict } = useI18n();
  const t = dict.legacy.portal;
  const [catalog, setCatalog] = useState<CatalogResponse | null>(null);

  useEffect(() => {
    const controller = new AbortController();

    async function loadCatalog() {
      try {
        const response = await fetch("/api/v1/catalog", {
          headers: { Accept: "application/json" },
          signal: controller.signal,
        });
        if (!response.ok) throw new Error(`catalog HTTP ${response.status}`);
        setCatalog((await response.json()) as CatalogResponse);
      } catch {
        // 카탈로그는 부가 정보다. 실패하면 기본 환경 라벨로 조용히 떨어진다.
      }
    }

    void loadCatalog();
    return () => controller.abort();
  }, []);

  return (
    <>
      <a className="skip" href="#main">
        {t.skipToContent}
      </a>
      <header className="topbar">
        {/* eslint-disable-next-line @next/next/no-html-link-for-pages -- PaaS CSS로 전환할 때 레거시 CSS를 확실히 내린다. */}
        <a className="brand" href="/" aria-label={t.brandLabel}>
          <span>
            <strong>{t.brandName}</strong>
            <small>{t.brandNote}</small>
          </span>
        </a>
        <div className="topbar-actions">
          <LocaleToggle className="legacy-locale-toggle" />
          {session?.user ? (
            <div className="auth-menu">
              <span className="auth-user">
                <small>KEYCLOAK</small>
                <strong>
                  {session.user.username ??
                    session.user.name ??
                    session.user.email}
                </strong>
                {session.user.groups.length > 0 && (
                  <em>{session.user.groups.join(" · ")}</em>
                )}
              </span>
              {/* 로그인 상태에서 홈(대시보드)으로 바로 들어가는 통로. */}
              {/* eslint-disable-next-line @next/next/no-html-link-for-pages -- PaaS CSS로 전환할 때 레거시 CSS를 확실히 내린다. */}
              <a className="session-link" href="/">
                {t.dashboard}
              </a>
              <Link className="session-link" href="/account">
                {t.session}
              </Link>
              <form action={signOutFromKeycloak} className="auth-logout-form">
                <button type="submit" className="auth-button quiet-auth">
                  {t.signOut}
                </button>
              </form>
            </div>
          ) : (
            <button
              type="button"
              className="auth-button"
              onClick={() => void signIn("keycloak", { redirectTo: "/" })}
            >
              {t.signIn}
            </button>
          )}
        </div>
      </header>

      <main id="main">
        <section className="hero" aria-labelledby="hero-title">
          <div className="hero-copy">
            <p className="hero-badge">
              <span aria-hidden="true" />
              {t.heroBadge}
            </p>
            <h1 id="hero-title">
              {t.heroTitleFirst}
              <br />
              <em>{t.heroTitleSecond}</em>
            </h1>
            <p className="lead">{t.heroLead}</p>
            <div className="hero-actions">
              {session?.user ? (
                /* PaaS 화면으로 넘어갈 때 레거시 전역 CSS를 확실히 내리기 위해 hard navigation 한다. */
                /* eslint-disable-next-line @next/next/no-html-link-for-pages -- 라우트 그룹의 전역 CSS 경계를 넘으므로 hard navigation이 필요하다. */
                <a className="button primary" href="/">
                  {t.dashboard}
                  <ArrowRight aria-hidden="true" />
                </a>
              ) : (
                <button
                  type="button"
                  className="button primary"
                  onClick={() => void signIn("keycloak", { redirectTo: "/" })}
                >
                  {t.heroPrimary}
                  <ArrowRight aria-hidden="true" />
                </button>
              )}
              <a className="button secondary" href="#platform-benefits">
                {t.heroSecondary}
              </a>
            </div>
          </div>
          <aside
            className="environment-card"
            aria-label={t.envCardLabel}
          >
            <div className="card-head">
              <span className="card-title">
                <ShieldCheck aria-hidden="true" />
                {t.envCurrent}
              </span>
              <strong aria-live="polite">
                {(catalog?.environment ?? "beta").toUpperCase()}
              </strong>
            </div>
            <p className="environment-health">
              <CheckCircle2 aria-hidden="true" />
              {t.envSummary}
            </p>
            <dl>
              <div>
                <dt>{t.envCluster}</dt>
                <dd>RKE2 3 nodes</dd>
              </div>
              <div>
                <dt>{t.envGateway}</dt>
                <dd>Envoy · Ready</dd>
              </div>
              <div>
                <dt>{t.envHttps}</dt>
                <dd>Wildcard TLS</dd>
              </div>
              <div>
                <dt>{t.envAuth}</dt>
                <dd>Keycloak OIDC</dd>
              </div>
              <div>
                <dt>{t.envUser}</dt>
                <dd>
                  {session?.user
                    ? (session.user.username ??
                      session.user.name ??
                      t.envSignedIn)
                    : t.envSignedOut}
                </dd>
              </div>
            </dl>
          </aside>
        </section>
        {/* 우리 플랫폼의 장점 */}
        <section
          id="platform-benefits"
          className="section benefits-section"
          aria-labelledby="trust-title"
        >
          <div className="section-heading">
            <div>
              <p className="eyebrow">PLATFORM PRINCIPLES</p>
              <h2 id="trust-title">{t.trustTitle}</h2>
            </div>
            <p>{t.trustLead}</p>
          </div>
          <div className="trust-strip">
            <div>
              <span className="trust-icon" aria-hidden="true">
                <LockKeyhole />
              </span>
              <p>
                <strong>{t.trustHttps}</strong>
                <small>{t.trustHttpsNote}</small>
              </p>
            </div>
            <div>
              <span className="trust-icon" aria-hidden="true">
                <KeyRound />
              </span>
              <p>
                <strong>{t.trustSso}</strong>
                <small>{t.trustSsoNote}</small>
              </p>
            </div>
            <div>
              <span className="trust-icon" aria-hidden="true">
                <ShieldCheck />
              </span>
              <p>
                <strong>{t.trustSecret}</strong>
                <small>{t.trustSecretNote}</small>
              </p>
            </div>
            <div>
              <span className="trust-icon" aria-hidden="true">
                <GitPullRequest />
              </span>
              <p>
                <strong>{t.trustGitops}</strong>
                <small>{t.trustGitopsNote}</small>
              </p>
            </div>
          </div>
        </section>
      </main>

      <footer>
        <div>
          <strong>SADP</strong>
          <span>{t.footerNote}</span>
        </div>
        <p>{t.footerSecret}</p>
      </footer>
    </>
  );
}
