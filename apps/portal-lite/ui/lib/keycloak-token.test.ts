import { describe, expect, it, vi } from "vitest";

import {
  endKeycloakSession,
  extractKeycloakIdentity,
  keycloakBrowserLogoutURL,
  refreshKeycloakAccessToken,
} from "./keycloak-token";

function jwt(payload: Record<string, unknown>) {
  return `${Buffer.from("{}").toString("base64url")}.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.signature`;
}

describe("Keycloak token mapping", () => {
  it("maps subject, groups, realm roles and the configured client roles", () => {
    const accessToken = jwt({
      sub: "user-123",
      preferred_username: "researcher",
      groups: ["viewer", "platform-admin"],
      realm_access: { roles: ["viewer", "offline_access"] },
      resource_access: {
        "portal-beta": { roles: ["deployments:read", "deployments:write"] },
        other: { roles: ["ignored"] },
      },
    });

    expect(extractKeycloakIdentity(undefined, accessToken, "portal-beta")).toEqual({
      userId: "user-123",
      username: "researcher",
      groups: ["platform-admin", "viewer"],
      realmRoles: ["offline_access", "viewer"],
      clientRoles: ["deployments:read", "deployments:write"],
    });
  });

  it("refreshes an expired access token and rotates the refresh token", async () => {
    const newAccessToken = jwt({
      sub: "user-123",
      realm_access: { roles: ["viewer"] },
      resource_access: { "portal-beta": { roles: ["deployments:read"] } },
    });
    const fetcher = vi.fn(async () =>
      new Response(
        JSON.stringify({
          access_token: newAccessToken,
          refresh_token: "rotated",
          id_token: "rotated-id-token",
          expires_in: 120,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const result = await refreshKeycloakAccessToken(
      {
        accessToken: "expired",
        accessTokenExpiresAt: 1,
        refreshToken: "server-only-refresh",
        idToken: "old-id-token",
        groups: [],
        realmRoles: [],
        clientRoles: [],
      },
      {
        issuer: "https://sso.example.test/realms/platform",
        clientId: "portal-beta",
        clientSecret: "server-only-secret",
        fetcher,
        now: 1_000,
      },
    );

    expect(result.accessToken).toBe(newAccessToken);
    expect(result.refreshToken).toBe("rotated");
    expect(result.idToken).toBe("rotated-id-token");
    expect(result.accessTokenExpiresAt).toBe(121_000);
    expect(result.realmRoles).toEqual(["viewer"]);
    expect(result.clientRoles).toEqual(["deployments:read"]);
    expect(fetcher).toHaveBeenCalledWith(
      "https://sso.example.test/realms/platform/protocol/openid-connect/token",
      expect.objectContaining({
        method: "POST",
        cache: "no-store",
        signal: expect.any(AbortSignal),
      }),
    );
  });

  it("does not include credentials in refresh errors", async () => {
    const fetcher = vi.fn(async () => new Response("denied", { status: 401 }));
    await expect(
      refreshKeycloakAccessToken(
        {
          refreshToken: "must-not-appear",
          groups: [],
          realmRoles: [],
          clientRoles: [],
        },
        {
          issuer: "https://sso.example.test/realms/platform",
          clientId: "portal-beta",
          clientSecret: "must-not-appear-either",
          fetcher,
        },
      ),
    ).rejects.toThrow("Keycloak token refresh failed (401)");
  });

  it("bounds a stalled refresh request", async () => {
    const fetcher = vi.fn((_input: URL | RequestInfo, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
      }),
    );

    await expect(
      refreshKeycloakAccessToken(
        { refreshToken: "server-only-refresh" },
        {
          issuer: "https://sso.example.test/realms/platform",
          clientId: "portal-beta",
          clientSecret: "server-only-secret",
          fetcher,
          timeoutMs: 10,
        },
      ),
    ).rejects.toMatchObject({ name: "TimeoutError" });
  });
});

describe("Keycloak session logout", () => {
  it("builds an RP-initiated browser logout with the ID token hint", () => {
    const result = new URL(
      keycloakBrowserLogoutURL(
        { idToken: "server-only-id-token" },
        {
          issuer: "https://sso.example.test/realms/platform",
          clientId: "portal-beta",
          postLogoutRedirectUri: "https://portal.example.test/portal",
        },
      ),
    );

    expect(result.origin + result.pathname).toBe(
      "https://sso.example.test/realms/platform/protocol/openid-connect/logout",
    );
    expect(Object.fromEntries(result.searchParams)).toEqual({
      client_id: "portal-beta",
      post_logout_redirect_uri: "https://portal.example.test/portal",
      id_token_hint: "server-only-id-token",
    });
  });

  it("rejects a plaintext post logout redirect", () => {
    expect(() =>
      keycloakBrowserLogoutURL(
        {},
        {
          issuer: "https://sso.example.test/realms/platform",
          clientId: "portal-beta",
          postLogoutRedirectUri: "http://portal.example.test/portal",
        },
      ),
    ).toThrow("Keycloak post logout redirect must use HTTPS");
  });

  it("ends the Keycloak session with the refresh token and client credentials", async () => {
    const fetcher = vi.fn(async () => new Response(null, { status: 204 }));

    await endKeycloakSession(
      { refreshToken: "server-only-refresh" },
      {
        issuer: "https://sso.example.test/realms/platform",
        clientId: "portal-beta",
        clientSecret: "server-only-secret",
        fetcher,
      },
    );

    expect(fetcher).toHaveBeenCalledTimes(1);
    const [url, init] = fetcher.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://sso.example.test/realms/platform/protocol/openid-connect/logout");
    expect(init).toMatchObject({
      method: "POST",
      cache: "no-store",
      signal: expect.any(AbortSignal),
    });
    expect(Object.fromEntries(new URLSearchParams(init.body as string))).toEqual({
      client_id: "portal-beta",
      client_secret: "server-only-secret",
      refresh_token: "server-only-refresh",
    });
  });

  it("skips the call when no refresh token is stored", async () => {
    const fetcher = vi.fn(async () => new Response(null, { status: 204 }));

    await endKeycloakSession(
      {},
      {
        issuer: "https://sso.example.test/realms/platform",
        clientId: "portal-beta",
        clientSecret: "server-only-secret",
        fetcher,
      },
    );

    expect(fetcher).not.toHaveBeenCalled();
  });

  it("does not include credentials in logout errors", async () => {
    const fetcher = vi.fn(async () => new Response("denied", { status: 400 }));

    await expect(
      endKeycloakSession(
        { refreshToken: "must-not-appear" },
        {
          issuer: "https://sso.example.test/realms/platform",
          clientId: "portal-beta",
          clientSecret: "must-not-appear-either",
          fetcher,
        },
      ),
    ).rejects.toThrow("Keycloak session logout failed (400)");
  });

  it("bounds a stalled logout so Auth.js can clear its session cookie", async () => {
    const fetcher = vi.fn((_input: URL | RequestInfo, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
      }),
    );

    await expect(
      endKeycloakSession(
        { refreshToken: "server-only-refresh" },
        {
          issuer: "https://sso.example.test/realms/platform",
          clientId: "portal-beta",
          clientSecret: "server-only-secret",
          fetcher,
          timeoutMs: 10,
        },
      ),
    ).rejects.toMatchObject({ name: "TimeoutError" });
  });
});
