import { describe, expect, it, vi } from "vitest";

import { en, ko } from "./i18n/messages/legacy";
import {
  oidcAuthorizationParams,
  needsAuthenticationRecovery,
  safeLoginCallback,
  startOIDCLogin,
} from "./login-flow";

describe("login recovery presentation", () => {
  it("selects the recovery view for SessionExpired and OAuth callback errors", () => {
    expect(needsAuthenticationRecovery("SessionExpired", false)).toBe(true);
    expect(needsAuthenticationRecovery("OAuthCallbackError", false)).toBe(true);
    expect(needsAuthenticationRecovery(undefined, false)).toBe(false);
  });

  it("selects the recovery view after refresh token renewal fails", () => {
    expect(needsAuthenticationRecovery(undefined, true)).toBe(true);
  });

  it("keeps provider errors out of the localized user-facing copy", () => {
    const providerError = "OAuthCallbackError: code=secret-code state=secret-state";
    expect(needsAuthenticationRecovery(providerError, false)).toBe(true);
    expect(`${ko.login.expired}${ko.login.restart}`).not.toContain(providerError);
    expect(`${en.login.expired}${en.login.restart}`).not.toContain(providerError);
    expect(ko.login.expired).toBe(
      "인증 시간이 만료되었습니다. 아래 버튼을 눌러 새로운 로그인을 시작하세요.",
    );
    expect(en.login.expired).toBe(
      "Your authentication attempt expired. Start a new sign-in below.",
    );
  });
});

describe("safe login callback", () => {
  it("preserves a same-site absolute path, query and fragment", () => {
    expect(safeLoginCallback("/my-apps?view=mine#recent")).toBe(
      "/my-apps?view=mine#recent",
    );
  });

  it.each([
    "https://example.com/steal",
    "//example.com/steal",
    "/\\example.com/steal",
    "/%2Fexample.com/steal",
    "/%5Cexample.com/steal",
    "javascript:alert(1)",
    ["/my-apps", "//example.com"],
  ])("replaces an unsafe or ambiguous callback with root: %j", (value) => {
    expect(safeLoginCallback(value)).toBe("/");
  });
});

describe("OIDC authorization restart", () => {
  function actions(order: string[]) {
    return {
      signOut: vi.fn(async () => {
        order.push("signOut");
      }),
      signIn: vi.fn(async () => {
        order.push("signIn");
      }),
    };
  }

  it("keeps normal login and the selected locale without clearing the session first", async () => {
    const order: string[] = [];
    const authActions = actions(order);

    await startOIDCLogin(authActions, {
      callbackUrl: "/my-apps",
      locale: "ko",
      fresh: false,
    });

    expect(order).toEqual(["signIn"]);
    expect(authActions.signOut).not.toHaveBeenCalled();
    expect(authActions.signIn).toHaveBeenCalledWith(
      "oidc",
      { redirectTo: "/my-apps" },
      { ui_locales: "ko" },
    );
  });

  it("clears the app session before starting a fresh authorization request", async () => {
    const order: string[] = [];
    const authActions = actions(order);

    await startOIDCLogin(authActions, {
      callbackUrl: "/my-apps",
      locale: "en",
      fresh: true,
    });

    expect(order).toEqual(["signOut", "signIn"]);
    expect(authActions.signOut).toHaveBeenCalledWith({ redirect: false });
    expect(authActions.signIn).toHaveBeenCalledWith(
      "oidc",
      { redirectTo: "/my-apps" },
      { prompt: "login", ui_locales: "en" },
    );
  });

  it("does not cache an old-tab request or automatically retry", async () => {
    const order: string[] = [];
    const authActions = actions(order);

    await startOIDCLogin(authActions, {
      callbackUrl: "/my-apps?tab=first",
      locale: "ko",
      fresh: true,
    });
    await startOIDCLogin(authActions, {
      callbackUrl: "/my-apps?tab=second",
      locale: "en",
      fresh: true,
    });

    expect(order).toEqual(["signOut", "signIn", "signOut", "signIn"]);
    expect(authActions.signIn).toHaveBeenNthCalledWith(
      1,
      "oidc",
      { redirectTo: "/my-apps?tab=first" },
      { prompt: "login", ui_locales: "ko" },
    );
    expect(authActions.signIn).toHaveBeenNthCalledWith(
      2,
      "oidc",
      { redirectTo: "/my-apps?tab=second" },
      { prompt: "login", ui_locales: "en" },
    );
  });

  it("builds a fresh authorization parameter set with prompt and locale", () => {
    const query = new URLSearchParams(oidcAuthorizationParams("en", true));
    expect(query.get("prompt")).toBe("login");
    expect(query.get("ui_locales")).toBe("en");
    expect([...query.keys()].sort()).toEqual(["prompt", "ui_locales"]);
  });
});
