export type KeycloakIdentityClaims = {
  userId?: string;
  username?: string;
  groups: string[];
  realmRoles: string[];
  clientRoles: string[];
};

export type KeycloakTokenState = Partial<KeycloakIdentityClaims> & {
  accessToken?: string;
  accessTokenExpiresAt?: number;
  refreshToken?: string;
  idToken?: string;
};

type RefreshOptions = {
  issuer: string;
  clientId: string;
  clientSecret: string;
  fetcher?: typeof fetch;
  now?: number;
  timeoutMs?: number;
};

type LogoutOptions = {
  issuer: string;
  clientId: string;
  clientSecret: string;
  fetcher?: typeof fetch;
  timeoutMs?: number;
};

type BrowserLogoutOptions = {
  issuer: string;
  clientId: string;
  postLogoutRedirectUri: string;
};

const KEYCLOAK_REFRESH_TIMEOUT_MS = 5_000;
const KEYCLOAK_LOGOUT_TIMEOUT_MS = 3_000;

function object(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function unique(values: string[]): string[] {
  return [...new Set(values)].sort();
}

export function decodeJwtPayload(encoded?: string): Record<string, unknown> {
  if (!encoded) return {};
  const parts = encoded.split(".");
  if (parts.length !== 3) return {};
  try {
    return object(JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")));
  } catch {
    return {};
  }
}

export function extractKeycloakIdentity(
  profile: unknown,
  accessToken: string | undefined,
  clientId: string,
): KeycloakIdentityClaims {
  const sources = [object(profile), decodeJwtPayload(accessToken)];
  const firstString = (key: string) =>
    sources.map((source) => source[key]).find((value): value is string => typeof value === "string");

  const groups = unique(sources.flatMap((source) => strings(source.groups)));
  const realmRoles = unique(
    sources.flatMap((source) => strings(object(source.realm_access).roles)),
  );
  const clientRoles = unique(
    sources.flatMap((source) => {
      const resourceAccess = object(source.resource_access);
      return strings(object(resourceAccess[clientId]).roles);
    }),
  );

  return {
    userId: firstString("sub"),
    username: firstString("preferred_username"),
    groups,
    realmRoles,
    clientRoles,
  };
}

// issuer 는 서버 전용 값이지만, 잘못된 설정으로 평문 HTTP 에 토큰이 실려 나가는 것을 막기 위해
// refresh/logout 양쪽에서 동일하게 HTTPS 를 강제한다.
function keycloakEndpoint(issuer: string, name: "token" | "logout"): string {
  const url = new URL(issuer);
  if (url.protocol !== "https:") throw new Error("Keycloak issuer must use HTTPS");
  return `${url.toString().replace(/\/$/, "")}/protocol/openid-connect/${name}`;
}

/**
 * 브라우저가 Keycloak 세션 쿠키를 직접 지우게 하는 RP-Initiated Logout URL이다.
 * id_token_hint는 서버 세션에만 보관하고 이 최종 redirect에서만 Keycloak에 돌려준다.
 */
export function keycloakBrowserLogoutURL(
  token: Pick<KeycloakTokenState, "idToken">,
  options: BrowserLogoutOptions,
): string {
  const postLogout = new URL(options.postLogoutRedirectUri);
  if (postLogout.protocol !== "https:") {
    throw new Error("Keycloak post logout redirect must use HTTPS");
  }

  const url = new URL(keycloakEndpoint(options.issuer, "logout"));
  url.searchParams.set("client_id", options.clientId);
  url.searchParams.set("post_logout_redirect_uri", postLogout.toString());
  if (token.idToken) url.searchParams.set("id_token_hint", token.idToken);
  return url.toString();
}

/**
 * 포털 세션을 끊을 때 Keycloak SSO 세션까지 함께 종료한다(백채널 RP-initiated logout).
 *
 * refresh_token 을 client 자격증명과 함께 logout 엔드포인트로 POST 하면 Keycloak 이 해당
 * 사용자 세션을 제거한다. 프런트채널 리다이렉트와 달리 Keycloak 클라이언트에
 * post_logout_redirect_uri 를 등록할 필요가 없어서 배포 설정 변경 없이 동작한다.
 * 브라우저에 남는 KEYCLOAK_IDENTITY 쿠키는 이미 삭제된 세션을 가리키므로
 * 다음 로그인 때 자격증명을 다시 요구한다.
 */
export async function endKeycloakSession(
  token: Pick<KeycloakTokenState, "refreshToken">,
  options: LogoutOptions,
): Promise<void> {
  if (!token.refreshToken) return;

  const response = await (options.fetcher ?? fetch)(keycloakEndpoint(options.issuer, "logout"), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: options.clientId,
      client_secret: options.clientSecret,
      refresh_token: token.refreshToken,
    }),
    cache: "no-store",
    // Auth.js는 이 이벤트가 끝난 뒤에 세션 쿠키를 지운다. Keycloak 장애가 포털의
    // 로컬 로그아웃까지 붙잡아 두지 않도록 짧은 상한을 반드시 둔다.
    signal: AbortSignal.timeout(options.timeoutMs ?? KEYCLOAK_LOGOUT_TIMEOUT_MS),
  });

  if (!response.ok) throw new Error(`Keycloak session logout failed (${response.status})`);
}

export async function refreshKeycloakAccessToken<T extends KeycloakTokenState>(
  token: T,
  options: RefreshOptions,
): Promise<T> {
  if (!token.refreshToken) throw new Error("Keycloak refresh token is unavailable");

  const tokenEndpoint = keycloakEndpoint(options.issuer, "token");
  const response = await (options.fetcher ?? fetch)(tokenEndpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: options.clientId,
      client_secret: options.clientSecret,
      grant_type: "refresh_token",
      refresh_token: token.refreshToken,
    }),
    cache: "no-store",
    // 만료된 쿠키를 읽는 모든 auth() 호출이 이 요청을 기다리므로 무제한 대기는
    // 로그인 화면 자체를 멈춘다. 실패하면 상위 jwt callback이 재로그인으로 보낸다.
    signal: AbortSignal.timeout(options.timeoutMs ?? KEYCLOAK_REFRESH_TIMEOUT_MS),
  });

  if (!response.ok) throw new Error(`Keycloak token refresh failed (${response.status})`);
  const refreshed = object(await response.json());
  if (typeof refreshed.access_token !== "string") {
    throw new Error("Keycloak token refresh response is missing access_token");
  }
  const expiresIn = Number(refreshed.expires_in);
  if (!Number.isFinite(expiresIn) || expiresIn <= 0) {
    throw new Error("Keycloak token refresh response has invalid expires_in");
  }

  return {
    ...token,
    accessToken: refreshed.access_token,
    accessTokenExpiresAt: (options.now ?? Date.now()) + expiresIn * 1000,
    refreshToken:
      typeof refreshed.refresh_token === "string" ? refreshed.refresh_token : token.refreshToken,
    idToken: typeof refreshed.id_token === "string" ? refreshed.id_token : token.idToken,
    ...extractKeycloakIdentity(undefined, refreshed.access_token, options.clientId),
  };
}
