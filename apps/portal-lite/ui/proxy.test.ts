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
