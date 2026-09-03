export type OIDCIdentityClaims = {
  userId?: string;
  username?: string;
  groups: string[];
  realmRoles: string[];
  clientRoles: string[];
};

export type OIDCTokenState = Partial<OIDCIdentityClaims> & {
  accessToken?: string;
  accessTokenExpiresAt?: number;
  refreshToken?: string;
  idToken?: string;
};

type RefreshOptions = {
  tokenEndpoint: string;
  clientId: string;
  clientSecret: string;
  groupsClaim?: string;
  fetcher?: typeof fetch;
  now?: number;
  timeoutMs?: number;
};

type BrowserLogoutOptions = {
  endSessionEndpoint: string;
  clientId: string;
  postLogoutRedirectUri: string;
};

const OIDC_REFRESH_TIMEOUT_MS = 5_000;

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

function httpsEndpoint(raw: string, label: string): string {
  const endpoint = new URL(raw);
  if (endpoint.protocol !== "https:") throw new Error(`${label} must use HTTPS`);
  return endpoint.toString();
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

export function extractOIDCIdentity(
  profile: unknown,
  accessToken: string | undefined,
  clientId: string,
  groupsClaim = "groups",
): OIDCIdentityClaims {
  const sources = [object(profile), decodeJwtPayload(accessToken)];
  const firstString = (key: string) =>
    sources.map((source) => source[key]).find((value): value is string => typeof value === "string");

  const groups = unique(sources.flatMap((source) => strings(source[groupsClaim])));
  // 두 role 배열은 기존 Portal API 권한 계약과의 전환 호환용이다. 일반 OIDC IdP는
  // groups claim만 제공해도 되며, 이 provider별 role 형태 claim을 만들 필요는 없다.
  const realmRoles = unique(
    sources.flatMap((source) => strings(object(source.realm_access).roles)),
  );
  const clientRoles = unique(
    sources.flatMap((source) => strings(object(object(source.resource_access)[clientId]).roles)),
  );

  return {
    userId: firstString("sub"),
    username: firstString("preferred_username") ?? firstString("email"),
    groups,
    realmRoles,
    clientRoles,
  };
}

export function oidcBrowserLogoutURL(
  token: Pick<OIDCTokenState, "idToken">,
  options: BrowserLogoutOptions,
): string {
  const postLogout = new URL(options.postLogoutRedirectUri);
  if (postLogout.protocol !== "https:") {
    throw new Error("OIDC post logout redirect must use HTTPS");
  }
  const url = new URL(httpsEndpoint(options.endSessionEndpoint, "OIDC end session endpoint"));
  url.searchParams.set("client_id", options.clientId);
  url.searchParams.set("post_logout_redirect_uri", postLogout.toString());
  if (token.idToken) url.searchParams.set("id_token_hint", token.idToken);
  return url.toString();
}

export async function refreshOIDCAccessToken<T extends OIDCTokenState>(
  token: T,
  options: RefreshOptions,
): Promise<T & OIDCTokenState> {
  if (!token.refreshToken) throw new Error("OIDC refresh token is unavailable");

  const response = await (options.fetcher ?? fetch)(
    httpsEndpoint(options.tokenEndpoint, "OIDC token endpoint"),
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: options.clientId,
        client_secret: options.clientSecret,
        grant_type: "refresh_token",
        refresh_token: token.refreshToken,
      }),
      cache: "no-store",
      signal: AbortSignal.timeout(options.timeoutMs ?? OIDC_REFRESH_TIMEOUT_MS),
    },
  );

  if (!response.ok) throw new Error(`OIDC token refresh failed (${response.status})`);
  const refreshed = object(await response.json());
  if (typeof refreshed.access_token !== "string") {
    throw new Error("OIDC token refresh response is missing access_token");
  }
  const expiresIn = Number(refreshed.expires_in);
  if (!Number.isFinite(expiresIn) || expiresIn <= 0) {
    throw new Error("OIDC token refresh response has invalid expires_in");
  }

  return {
    ...token,
    accessToken: refreshed.access_token,
    accessTokenExpiresAt: (options.now ?? Date.now()) + expiresIn * 1000,
    refreshToken:
      typeof refreshed.refresh_token === "string" ? refreshed.refresh_token : token.refreshToken,
    idToken: typeof refreshed.id_token === "string" ? refreshed.id_token : token.idToken,
    ...extractOIDCIdentity(
      undefined,
      refreshed.access_token,
      options.clientId,
      options.groupsClaim,
    ),
  };
}
