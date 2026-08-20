import type { Metadata } from "next";
import type { ReactNode } from "react";

import { getI18n, getLocale } from "@/lib/i18n/server";

/*
 * 스타일시트는 여기서 import 하지 않는다.
 * (legacy) 는 globals.css, (paas) 는 paas.css 를 각자 로드해
 * Tailwind preflight 와 기존 CSS 가 서로 간섭하지 않게 한다.
 */

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();

  return {
    title: dict.common.meta.title,
    description: dict.common.meta.description,
    other: META_OTHER,
  };
}

/**
 * verify 스크립트가 계약 확인용으로 읽는 메타 태그.
 * 표시 언어와 무관하게 항상 같은 값이어야 하므로 사전 밖에 둔다.
 */
const META_OTHER: NonNullable<Metadata["other"]> = {
  "portal-ui": "nextjs-authjs-server",
  "portal-api-contract":
    "catalog.environment catalog.templates profile.profile.exposure profile.generated.valuesTemplate profile.generated.openbaoPath profile.nextSteps",
};

/**
 * `<html lang>` 은 스크린리더 발음과 브라우저 번역 제안을 좌우하므로
 * 표시 언어와 반드시 일치해야 한다. 쿠키를 읽는 순간 전체가 요청 시 렌더링되는데,
 * 이 앱은 모든 화면이 세션 쿠키를 확인하므로 원래도 정적 캐시 대상이 아니다.
 */
export default async function RootLayout({
  children,
}: Readonly<{ children: ReactNode }>) {
  const locale = await getLocale();

  return (
    <html lang={locale}>
      <body>{children}</body>
    </html>
  );
}
