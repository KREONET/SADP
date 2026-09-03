import { describe, expect, it } from "vitest";

import {
  hasPortalApiRole,
  isSafePortalApiPath,
  portalApiRequiredRole,
  portalApiJsonHeaders,
  portalApiUpstreamHeaders,
  portalApiUpstreamURL,
} from "./portal-api-bff";

describe("Portal API BFF boundary", () => {
  it("strips every requester query parameter while retaining other filters", () => {
    const target = portalApiUpstreamURL(
      "https://portal.example/api/v1/deployment-requests?requester=other&ReQuEsTeR=again&limit=20",
      ["deployment-requests"],
      "http://127.0.0.1:8081",
    );

    expect(target.toString()).toBe(
      "http://127.0.0.1:8081/api/v1/deployment-requests?limit=20",
    );
  });

  it("keeps catch-all paths inside the fixed API prefix", () => {
    expect(isSafePortalApiPath(["deployment-requests", "abc123"])).toBe(true);
    for (const path of [["..", "health"], ["."], ["a/b"], ["a\\b"], [""]]) {
      expect(isSafePortalApiPath(path)).toBe(false);
      expect(() =>
        portalApiUpstreamURL(
          "https://portal.example/api/v1/x",
          path,
          "http://127.0.0.1:8081",
        ),
      ).toThrow("unsafe Portal API path");
    }
  });

  it("ignores an external identity header and forwards the idempotency key", () => {
    const headers = portalApiUpstreamHeaders(
      new Headers({
        "X-Portal-User": "attacker",
        requester: "attacker",
        "Idempotency-Key": "request-123",
        Authorization: "Bearer external-token",
      }),
      "session-user",
    );

    expect(Object.fromEntries(headers)).toEqual({
      "idempotency-key": "request-123",
      "x-portal-user": "session-user",
    });
  });

  it("adds the authenticated requester to a server-side JSON validation call", () => {
    expect(Object.fromEntries(portalApiJsonHeaders("session-user"))).toEqual({
      accept: "application/json",
      "content-type": "application/json",
      "x-portal-user": "session-user",
    });
  });

  it("requires read for safe methods and write for mutations", () => {
    expect(portalApiRequiredRole("GET")).toBe("deployments:read");
    expect(portalApiRequiredRole("HEAD")).toBe("deployments:read");
    expect(portalApiRequiredRole("POST")).toBe("deployments:write");
    expect(portalApiRequiredRole("PUT")).toBe("deployments:write");
    expect(portalApiRequiredRole("DELETE")).toBe("deployments:write");
  });

  it("supports exact API scopes and the external OIDC role contract", () => {
    expect(hasPortalApiRole(["deployments:read"], "deployments:read")).toBe(true);
    expect(hasPortalApiRole(["deployments:write"], "deployments:read")).toBe(true);
    expect(hasPortalApiRole(["deployments:write"], "deployments:write")).toBe(true);

    for (const role of ["platform-admin", "app-admin", "developer"]) {
      expect(hasPortalApiRole([role], "deployments:read")).toBe(true);
      expect(hasPortalApiRole([role], "deployments:write")).toBe(true);
    }
    expect(hasPortalApiRole(["viewer"], "deployments:read")).toBe(true);
    expect(hasPortalApiRole(["viewer"], "deployments:write")).toBe(false);
    expect(hasPortalApiRole(["deployments:read"], "deployments:write")).toBe(false);
    expect(hasPortalApiRole(["unrelated"], "deployments:read")).toBe(false);
  });
});
