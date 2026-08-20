import type { ReactNode } from "react";

import { AppHeader } from "@/components/paas/app-header";
import { I18nProvider } from "@/lib/i18n/context";
import { getI18n } from "@/lib/i18n/server";
import { requirePaasRole } from "@/lib/require-session";

import "./paas.css";

/**
 * proxy.ts 가 요청마다 새 nonce 로 CSP(`script-src 'nonce-...' 'strict-dynamic'`)를
 * 내려주는데, 정적 프리렌더된 HTML 에는 빌드 시점 기준이라 nonce 가 아예 박히지 않는다.
 * 그러면 헤더의 nonce 와 매칭되는 script 가 하나도 없어서 전체 스크립트가 CSP 로 차단되고,
 * hydration 이 안 돌아 Suspense fallback(스켈레톤)에서 화면이 멈춘다.
 * 요청 시 렌더링해야 Next 가 `x-nonce` 를 읽어 script 태그에 nonce 를 붙인다.
 */
export const dynamic = "force-dynamic";

/**
 * PaaS 화면 공통 셸.
 * 헤더는 여기서 한 번만 렌더링한다. 푸터는 화면마다 링크 구성이 달라서
 * 각 page 가 <AppFooter /> 를 직접 렌더링한다.
 *
 * 로그인 게이트도 여기서 한 번만 건다. (paas) 그룹 전체가 보호되므로
 * 개별 page 가 각자 auth() 를 확인하다 빠뜨리는 일이 없다.
 */
export default async function PaasLayout({ children }: { children: ReactNode }) {
  await requirePaasRole("deployments:read");
  const i18n = await getI18n();

  return (
    <I18nProvider value={i18n}>
      <div className="flex min-h-screen flex-col bg-background text-foreground">
        <AppHeader />
        {children}
        {/*
          토스트(sonner)는 이 플랫폼에서 쓰지 않는다. CSP 가 style-src 에 'unsafe-inline'
          을 주지 않는데 sonner 는 위치·스택을 인라인 style 속성으로 지정하므로, 토스트가
          위치를 잃고 화면 아래에 그대로 흘러 붙는다(§7.2 의 인라인 style 금지와 같은 뿌리).
          알림은 클래스만 쓰는 인라인 배너나 AlertDialog 로 띄운다.
        */}
      </div>
    </I18nProvider>
  );
}
