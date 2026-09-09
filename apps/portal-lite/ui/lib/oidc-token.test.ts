import { describe, expect, it, vi } from "vitest";

import {
  extractOIDCIdentity,
  oidcBrowserLogoutURL,
  refreshOIDCAccessToken,
} from "./oidc-token";

function jwt(payload: Record<string, unknown>) {
  return `${Buffer.from("{}").toString("base64url")}.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.signature`;
}

describe("OIDC token mapping", () => {
  it("accepts only the Portal client roles alongside group and realm roles", () => {
    const identity = extractOIDCIdentity(undefined, jwt({
      groups: ["viewer"],
      realm_access: { roles: ["platform-admin"] },
      resource_access: {
        "portal-beta": { roles: ["app-admin"] },
        other: { roles: ["untrusted-role"] },
      },
    }), "portal-beta");
    expect(identity.groups).toEqual(["viewer"]);
    expect(identity.realmRoles).toEqual(["platform-admin"]);
    expect(identity.clientRoles).toEqual(["app-admin"]);
  });
  it("maps standard identity and a configurable groups claim", () => {
    const accessToken = jwt({
      sub: "user-123",
      preferred_username: "researcher",
      member_of: ["viewer", "platform-admin"],
    });

    expect(extractOIDCIdentity(undefined, accessToken, "portal-beta", "member_of")).toEqual({
      userId: "user-123",
      username: "researcher",
      groups: ["platform-admin", "viewer"],
      realmRoles: [],
      clientRoles: [],
    });
  });

  it("refreshes through the configured token endpoint", async () => {
    const newAccessToken = jwt({ sub: "user-123", groups: ["viewer"] });
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

    const result = await refreshOIDCAccessToken(
      { refreshToken: "server-only-refresh" },
      {
        tokenEndpoint: "https://idp.example.test/oauth/token",
        clientId: "portal-beta",
        clientSecret: "server-only-secret",
        fetcher,
        now: 1_000,
      },
    );

    expect(result.refreshToken).toBe("rotated");
    expect(result.accessTokenExpiresAt).toBe(121_000);
    expect(result.groups).toEqual(["viewer"]);
    expect(fetcher).toHaveBeenCalledWith(
      "https://idp.example.test/oauth/token",
      expect.objectContaining({ method: "POST", cache: "no-store" }),
    );
  });

  it("does not include credentials in refresh errors", async () => {
    const fetcher = vi.fn(async () => new Response("denied", { status: 401 }));
    await expect(
      refreshOIDCAccessToken(
        { refreshToken: "must-not-appear" },
        {
          tokenEndpoint: "https://idp.example.test/oauth/token",
          clientId: "portal-beta",
          clientSecret: "must-not-appear-either",
          fetcher,
        },
      ),
    ).rejects.toThrow("OIDC token refresh failed (401)");
  });
});

describe("OIDC session logout", () => {
  it("uses the configured RP-initiated logout endpoint", () => {
    const result = new URL(
      oidcBrowserLogoutURL(
        { idToken: "server-only-id-token" },
        {
          endSessionEndpoint: "https://idp.example.test/oauth/end-session",
          clientId: "portal-beta",
          postLogoutRedirectUri: "https://portal.example.test/portal",
        },
      ),
    );

    expect(result.origin + result.pathname).toBe(
      "https://idp.example.test/oauth/end-session",
    );
    expect(Object.fromEntries(result.searchParams)).toEqual({
      client_id: "portal-beta",
      post_logout_redirect_uri: "https://portal.example.test/portal",
      id_token_hint: "server-only-id-token",
    });
  });

  it("rejects a plaintext post logout redirect", () => {
    expect(() =>
      oidcBrowserLogoutURL(
        {},
        {
          endSessionEndpoint: "https://idp.example.test/oauth/end-session",
          clientId: "portal-beta",
          postLogoutRedirectUri: "http://portal.example.test/portal",
        },
      ),
    ).toThrow("OIDC post logout redirect must use HTTPS");
  });
});
