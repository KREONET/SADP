import { afterEach, describe, expect, it, vi } from "vitest";
import type { NextAuthConfig } from "next-auth";

const captured = vi.hoisted(() => ({ config: undefined as undefined | (() => NextAuthConfig) }));
vi.mock("next-auth", () => ({
  default: (config: () => NextAuthConfig) => {
    captured.config = config;
    return { handlers: {}, auth: vi.fn(), signIn: vi.fn(), signOut: vi.fn() };
  },
}));
afterEach(() => { vi.unstubAllEnvs(); vi.resetModules(); });

describe("runtime OIDC configuration", () => {
  it("loads the build module without deployment credentials but refuses runtime authentication", async () => {
    vi.stubEnv("AUTH_OIDC_ISSUER", "");
    await expect(import("./auth")).resolves.toBeDefined();
    expect(() => captured.config?.()).toThrow("AUTH_OIDC_ISSUER is required at runtime");
  });
  it("requires the client secret even when public OIDC coordinates are configured", async () => {
    vi.stubEnv("AUTH_OIDC_ISSUER", "https://identity.example.test/realm");
    vi.stubEnv("AUTH_OIDC_ID", "portal");
    vi.stubEnv("AUTH_OIDC_SECRET", "");
    await import("./auth");
    expect(() => captured.config?.()).toThrow("AUTH_OIDC_SECRET is required at runtime");
  });
});
