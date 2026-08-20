/**
 * 포털 표시 언어(로케일) 정의.
 *
 * 언어는 URL 이 아니라 쿠키에 담는다. 경로에 /ko, /en 을 붙이면 기존 링크와
 * 북마크가 전부 깨지고 모든 라우트를 [locale] 밑으로 옮겨야 하는데,
 * (paas)/(legacy) 레이아웃이 이미 force-dynamic 이라 쿠키를 읽어도
 * 서버 렌더링 결과가 요청마다 정확히 갈린다.
 */

export const LOCALES = ["ko", "en"] as const;

export type Locale = (typeof LOCALES)[number];

/** 기본 배포 대상의 운영 언어가 한국어라 한국어를 기본값으로 둔다. */
export const DEFAULT_LOCALE: Locale = "ko";

/** 서버 액션이 굽고 레이아웃이 읽는 쿠키 이름. */
export const LOCALE_COOKIE = "portal_locale";

/** 언어는 공개 정보라 1년 유지해도 무방하다(민감 정보 아님). */
export const LOCALE_COOKIE_MAX_AGE = 60 * 60 * 24 * 365;

export function isLocale(value: unknown): value is Locale {
  return typeof value === "string" && LOCALES.includes(value as Locale);
}

/**
 * 쿠키/헤더에서 읽은 임의의 값을 안전한 Locale 로 좁힌다.
 * 값이 없거나 모르는 값이면 기본 로케일로 떨어뜨린다.
 */
export function normalizeLocale(value: unknown): Locale {
  return isLocale(value) ? value : DEFAULT_LOCALE;
}
