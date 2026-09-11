import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { NextRequest, NextResponse } from "next/server";
import { decode, encode } from "next-auth/jwt";
import { resetOIDCRefreshCoordinator } from "./lib/oidc-refresh-coordinator";

const secret = "fixture-auth-secret-at-least-32-characters";
const cookieName = "__Secure-authjs.session-token";

beforeEach(() => {
  vi.stubEnv("AUTH_SECRET", secret);
  vi.stubEnv("AUTH_URL", "https://portal.example.invalid");
  vi.stubEnv("AUTH_TRUST_HOST", "true");
  vi.stubEnv("AUTH_OIDC_ID", "fixture-client");
  vi.stubEnv("AUTH_OIDC_SECRET", "fixture-client-secret");
  vi.stubEnv("AUTH_OIDC_ISSUER", "https://idp.example.invalid");
  vi.stubEnv("AUTH_OIDC_TOKEN_ENDPOINT", "https://idp.example.invalid/token");
});
afterEach(() => {
  resetOIDCRefreshCoordinator();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

async function sessionRequest(error?: string) {
  const cookie = await encode({ secret, salt: cookieName, token: {
    sub: "fixture-user", accessToken: "old-access", refreshToken: "old-refresh",
    accessTokenExpiresAt: Date.now() - 1, error,
  } });
  return new NextRequest("https://portal.example.invalid/api/auth/session", {
    headers: { cookie: `${cookieName}=${cookie}` },
  });
}

it("merges real Auth.js session handlers and returns writable rotated cookies without exposing tokens", async () => {
  let release!: (response: Response) => void;
  const fetcher = vi.fn(() => new Promise<Response>((resolve) => { release = resolve; }));
  vi.stubGlobal("fetch", fetcher);
  const { handlers } = await import("./auth");
  const request = await sessionRequest();
  const a = handlers.GET(new NextRequest(request));
  const b = handlers.GET(new NextRequest(request));
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  release(Response.json({ access_token: "rotated-access", refresh_token: "rotated-refresh", expires_in: 120 }));
  const responses = await Promise.all([a, b]);
  const late = await handlers.GET(new NextRequest(request));
  expect(fetcher).toHaveBeenCalledTimes(1);
  for (const response of [...responses, late]) {
    expect(response.status).toBe(200);
    expect(response.headers.get("set-cookie")).toContain(cookieName);
    const cookie = new NextResponse(null, { headers: response.headers }).cookies.get(cookieName);
    const jwt = await decode({ token: cookie?.value, secret, salt: cookieName });
    expect(jwt?.refreshToken).toBe("rotated-refresh");
    expect(jwt?.accessToken).toBe("rotated-access");
    const session = await response.json();
    expect(session.error).toBeUndefined();
    expect(session.accessToken).toBeUndefined();
    expect(session.refreshToken).toBeUndefined();
    expect(session.accessTokenExpiresAt).toBeGreaterThan(Date.now());
  }
});

it("does not make RefreshTokenError sticky in the JWT callback", async () => {
  const fetcher = vi.fn(async () => Response.json({ access_token: "retry-access", refresh_token: "retry-refresh", expires_in: 120 }));
  vi.stubGlobal("fetch", fetcher);
  const { handlers } = await import("./auth");
  const response = await handlers.GET(await sessionRequest("RefreshTokenError"));
  expect(fetcher).toHaveBeenCalledTimes(1);
  expect((await response.json()).error).toBeUndefined();
});
