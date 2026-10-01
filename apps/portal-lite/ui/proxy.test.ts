import { expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

// 인증 모듈에 의존하면 세션을 사용하지 않는 Proxy에서도 갱신이 재발한다.
vi.mock("./auth", () => { throw new Error("Proxy must not import auth"); });
import { proxy } from "./proxy";

it("sets CSP and pathname without invoking authentication", () => {
  const response = proxy(new NextRequest("https://portal.example.invalid/my-apps?q=1"));
  expect(response.status).toBe(200);
  expect(response.headers.get("x-middleware-request-x-pathname")).toBe("/my-apps?q=1");
  expect(response.headers.get("Content-Security-Policy")).toContain("'nonce-");
  expect(response.headers.get("X-Frame-Options")).toBe("DENY");
  expect(response.headers.get("Set-Cookie")).toBeNull();
});

it("shows the main page at / for anonymous visitors without a /portal address", () => {
  const response = proxy(new NextRequest("https://portal.example.invalid/"));
  expect(response.status).toBe(200);
  expect(response.headers.get("x-middleware-rewrite")).toBe("https://portal.example.invalid/portal");
  expect(response.headers.get("Location")).toBeNull();
});

it("permanently redirects anonymous /portal links to / without caching", () => {
  const response = proxy(new NextRequest("https://portal.example.invalid/portal?lang=en"));
  expect(response.status).toBe(308);
  expect(response.headers.get("Location")).toBe("https://portal.example.invalid/?lang=en");
  expect(response.headers.get("Cache-Control")).toBe("no-store");
  expect(response.headers.get("X-Frame-Options")).toBe("DENY");
});

it("keeps the dashboard at / and the main page at /portal when a session cookie exists", () => {
  for (const name of ["authjs.session-token", "__Secure-authjs.session-token.0"]) {
    const headers = { cookie: `${name}=opaque` };
    const home = proxy(new NextRequest("https://portal.example.invalid/", { headers }));
    expect(home.headers.get("x-middleware-rewrite")).toBeNull();
    expect(home.status).toBe(200);
    const legacy = proxy(new NextRequest("https://portal.example.invalid/portal", { headers }));
    expect(legacy.status).toBe(200);
    expect(legacy.headers.get("Location")).toBeNull();
  }
});

it("does not redirect the internal / → /portal rewrite back out (no redirect loop)", () => {
  const rewritten = proxy(new NextRequest("https://portal.example.invalid/portal", {
    headers: { "x-sadp-home-rewrite": "1" },
  }));
  expect(rewritten.status).toBe(200);
  expect(rewritten.headers.get("Location")).toBeNull();
});
