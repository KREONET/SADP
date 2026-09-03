import { normalizeLocale, type Locale } from "./i18n/locale";

const CALLBACK_BASE = "https://portal.invalid";

type LoginActions = {
  signOut(options: { redirect: false }): Promise<unknown>;
  signIn(
    provider: "oidc",
    options: { redirectTo: string },
    authorizationParams: Record<string, string>,
  ): Promise<unknown>;
};

type StartOIDCLoginOptions = {
  callbackUrl: unknown;
  locale: unknown;
  fresh: boolean;
};

/**
 * Auth.js와 브라우저가 모두 같은 origin의 절대경로로 해석하는 callback만 허용한다.
 * URL 파서를 같이 쓰는 이유는 `/\\host`도 브라우저에서는 외부 URL이 될 수 있기 때문이다.
 */
export function safeLoginCallback(value: unknown): string {
  if (typeof value !== "string" || !value.startsWith("/")) return "/";
  if (/^\/(?:\/|\\|%2f|%5c)/i.test(value)) return "/";
  if (/[\u0000-\u001f\u007f\\]/u.test(value)) return "/";

  try {
    const parsed = new URL(value, CALLBACK_BASE);
    if (parsed.origin !== CALLBACK_BASE) return "/";
    return `${parsed.pathname}${parsed.search}${parsed.hash}`;
  } catch {
    return "/";
  }
}

/** 오류 코드는 판정에만 쓰고 화면 문구나 로그로 전달하지 않는다. */
export function needsAuthenticationRecovery(
  error: unknown,
  refreshFailed: boolean,
): boolean {
  if (refreshFailed) return true;
  if (typeof error === "string") return error.trim().length > 0;
  return Array.isArray(error)
    ? error.some((item) => typeof item === "string" && item.trim().length > 0)
    : false;
}

export function oidcAuthorizationParams(
  locale: unknown,
  fresh: boolean,
): Record<string, string> {
  const params: Record<string, string> = {
    ui_locales: normalizeLocale(locale),
  };
  if (fresh) params.prompt = "login";
  return params;
}

/**
 * 복구 요청은 사용자가 버튼을 누른 시점에만 기존 앱 세션을 지우고 Auth.js signIn을 새로 호출한다.
 * state/nonce/PKCE는 이 함수가 보관하지 않으며 매 signIn 호출마다 Auth.js가 새로 생성한다.
 */
export async function startOIDCLogin(
  actions: LoginActions,
  options: StartOIDCLoginOptions,
): Promise<void> {
  const callbackUrl = safeLoginCallback(options.callbackUrl);
  const locale: Locale = normalizeLocale(options.locale);

  if (options.fresh) await actions.signOut({ redirect: false });
  await actions.signIn(
    "oidc",
    { redirectTo: callbackUrl },
    oidcAuthorizationParams(locale, options.fresh),
  );
}
