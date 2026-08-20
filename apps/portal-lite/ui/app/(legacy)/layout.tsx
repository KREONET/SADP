import type { ReactNode } from "react";

import { I18nProvider } from "@/lib/i18n/context";
import { getI18n } from "@/lib/i18n/server";

import "../globals.css";

/**
 * (legacy) 는 Tailwind 를 쓰지 않는 순수 CSS 화면이지만, 문구는 (paas) 와 같은
 * 사전을 쓴다. 로그인 화면에서 고른 언어가 포털에 그대로 이어져야 하기 때문이다.
 */
export default async function LegacyLayout({
  children,
}: {
  children: ReactNode;
}) {
  const i18n = await getI18n();

  return <I18nProvider value={i18n}>{children}</I18nProvider>;
}
