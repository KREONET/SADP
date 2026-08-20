import { describe, expect, it } from "vitest";
import type { Session } from "next-auth";

import { isUsablePaasSession } from "./paas-session-policy";

function session(error?: Session["error"]): Session {
  return {
    user: {
      id: "user-1",
      username: "alice",
      groups: [],
      realmRoles: ["viewer"],
      clientRoles: [],
    },
    expires: new Date(Date.now() + 60_000).toISOString(),
    error,
  };
}

describe("PaaS session policy", () => {
  it("accepts an active authenticated session", () => {
    expect(isUsablePaasSession(session())).toBe(true);
  });

  it("fails closed when Auth.js could not refresh the access token", () => {
    expect(isUsablePaasSession(session("RefreshTokenError"))).toBe(false);
  });

  it("rejects an absent session", () => {
    expect(isUsablePaasSession(null)).toBe(false);
  });
});
