import "server-only";

import { cookies } from "next/headers";

import { getDictionary, type Dictionary } from "@/lib/i18n/dictionary";
import { LOCALE_COOKIE, normalizeLocale, type Locale } from "@/lib/i18n/locale";

/**
 * 현재 요청의 표시 언어를 읽는다.
 *
 * cookies() 를 부르는 순간 그 라우트는 동적 렌더링으로 넘어간다.
 * (paas) 레이아웃은 이미 force-dynamic 이고, (legacy) 도 언어를 반영하려면
 * 어차피 요청 시점에 렌더링돼야 하므로 의도한 동작이다.
 */
export async function getLocale(): Promise<Locale> {
  const store = await cookies();
  return normalizeLocale(store.get(LOCALE_COOKIE)?.value);
}

/** 서버 컴포넌트에서 로케일과 사전을 한 번에 받는다. */
export async function getI18n(): Promise<{
  locale: Locale;
  dict: Dictionary;
}> {
  const locale = await getLocale();
  return { locale, dict: getDictionary(locale) };
}
