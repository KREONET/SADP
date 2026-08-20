"use server";

import { revalidatePath } from "next/cache";
import { cookies } from "next/headers";

import {
  LOCALE_COOKIE,
  LOCALE_COOKIE_MAX_AGE,
  normalizeLocale,
} from "@/lib/i18n/locale";

/**
 * 표시 언어를 쿠키에 굽는다.
 *
 * 언어는 민감 정보가 아니지만 클라이언트가 직접 읽을 일이 없으므로 httpOnly 로 둔다.
 * `secure` 는 일부러 켜지 않는다. 테스트베드에서 평문 HTTP 로도 포털에 접근하는데
 * secure 를 붙이면 그 경로에서 쿠키가 저장되지 않아 언어 전환이 조용히 실패한다.
 */
export async function setLocaleAction(next: string): Promise<void> {
  const locale = normalizeLocale(next);
  const store = await cookies();

  store.set(LOCALE_COOKIE, locale, {
    path: "/",
    maxAge: LOCALE_COOKIE_MAX_AGE,
    httpOnly: true,
    sameSite: "lax",
  });

  // 레이아웃까지 무효화해야 헤더/푸터처럼 셸에 있는 문구도 같이 바뀐다.
  revalidatePath("/", "layout");
}
