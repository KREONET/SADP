/**
 * 날짜 표기 유틸.
 * 스크린샷마다 "2 hours ago" / "Yesterday" / "Oct 24, 2025" 가 섞여 있어 한 규칙으로 통일한다.
 *  - 7일 이내: 상대 표기
 *  - 7일 초과: 절대 표기
 * 서버/클라이언트 결과가 갈리지 않도록 절대 표기는 항상 UTC 로 계산한다.
 *
 * 로케일별 포매터는 매 렌더마다 새로 만들지 않고 모듈 스코프에 캐시해 둔다.
 * Intl 인스턴스 생성이 이 화면에서 가장 비싼 축에 드는 연산이라서다.
 */

import type { Locale } from "@/lib/i18n/locale";

const ABSOLUTE: Record<Locale, Intl.DateTimeFormat> = {
  en: new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    month: "short",
    day: "numeric",
    year: "numeric",
  }),
  ko: new Intl.DateTimeFormat("ko-KR", {
    timeZone: "UTC",
    year: "numeric",
    month: "long",
    day: "numeric",
  }),
};

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** ko: "2025년 10월 24일" / en: "Oct 24, 2025" */
export function formatAbsolute(iso: string, locale: Locale = "en"): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "—";
  return ABSOLUTE[locale].format(date);
}

const RELATIVE = {
  ko: {
    justNow: "방금 전",
    minutes: (n: number) => `${n}분 전`,
    hours: (n: number) => `${n}시간 전`,
    yesterday: "어제",
    days: (n: number) => `${n}일 전`,
  },
  en: {
    justNow: "just now",
    minutes: (n: number) => `${n} ${n === 1 ? "minute" : "minutes"} ago`,
    hours: (n: number) => `${n} ${n === 1 ? "hour" : "hours"} ago`,
    yesterday: "Yesterday",
    days: (n: number) => `${n} days ago`,
  },
} satisfies Record<Locale, unknown>;

/** 7일 이내면 상대 표기, 넘으면 절대 표기. */
export function formatRelative(
  iso: string,
  locale: Locale = "en",
  now: number = Date.now(),
): string {
  const time = new Date(iso).getTime();
  if (Number.isNaN(time)) return "—";

  const t = RELATIVE[locale];
  const diff = now - time;
  if (diff < MINUTE) return t.justNow;
  if (diff < HOUR) return t.minutes(Math.floor(diff / MINUTE));
  if (diff < DAY) return t.hours(Math.floor(diff / HOUR));
  if (diff < 2 * DAY) return t.yesterday;
  if (diff < 7 * DAY) return t.days(Math.floor(diff / DAY));
  return formatAbsolute(iso, locale);
}
