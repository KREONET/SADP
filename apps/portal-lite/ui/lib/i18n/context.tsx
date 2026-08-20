"use client";

import { createContext, useContext, type ReactNode } from "react";

import type { Dictionary } from "@/lib/i18n/dictionary";
import type { Locale } from "@/lib/i18n/locale";

export interface I18nValue {
  locale: Locale;
  dict: Dictionary;
}

const I18nContext = createContext<I18nValue | null>(null);

/**
 * 서버 레이아웃이 읽은 로케일/사전을 클라이언트 컴포넌트 트리에 흘려준다.
 * 사전은 순수 객체라 RSC 페이로드로 그대로 직렬화된다.
 */
export function I18nProvider({
  value,
  children,
}: {
  value: I18nValue;
  children: ReactNode;
}) {
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nValue {
  const value = useContext(I18nContext);
  if (!value) {
    // 프로바이더를 빠뜨린 화면을 조용히 영어로 렌더링하는 것보다 즉시 터지는 편이 낫다.
    throw new Error("useI18n() 은 <I18nProvider /> 안에서만 사용할 수 있다.");
  }
  return value;
}
