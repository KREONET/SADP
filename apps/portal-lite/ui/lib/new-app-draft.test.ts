import { describe, expect, it } from "vitest";

import {
  draftFieldForApiError,
  isSafeAllowedCidr,
  missingOpenBaoKeys,
} from "./new-app-draft-policy";
import { migrateStoredDraft } from "./new-app-draft-migration";

describe("stored new-app draft migration", () => {
  it("preserves legacy public as external without SSO", () => {
    expect(migrateStoredDraft({ name: "hello", visibility: "public" })).toMatchObject({
      name: "hello",
      exposureMode: "external",
      authMode: "none",
    });
  });

  it("preserves legacy oidc as external with SSO", () => {
    expect(migrateStoredDraft({ name: "secure", visibility: "oidc" })).toMatchObject({
      name: "secure",
      exposureMode: "external",
      authMode: "oidc",
    });
  });

  it("does not let a legacy field override the new independent settings", () => {
    expect(
      migrateStoredDraft({
        visibility: "oidc",
        exposureMode: "internal",
        authMode: "none",
        egressMode: "web",
      }),
    ).toMatchObject({ exposureMode: "internal", authMode: "none", egressMode: "web" });
  });

  it("normalizes a contradictory internal plus OIDC draft to no authentication", () => {
    expect(
      migrateStoredDraft({ exposureMode: "internal", authMode: "oidc" }),
    ).toMatchObject({ exposureMode: "internal", authMode: "none" });
  });

  it("migrates a legacy secret classification to OpenBao", () => {
    expect(
      migrateStoredDraft({
        envVars: [{ key: "TOKEN", value: "sensitive", classification: "secret" }],
      }).envVars,
    ).toEqual([{ key: "TOKEN", value: "sensitive", classification: "openbao" }]);
  });

  it("defaults old drafts to Git and preserves an explicit image source", () => {
    expect(migrateStoredDraft({ name: "old" }).sourceMode).toBe("git");
    expect(
      migrateStoredDraft({ sourceMode: "image", image: "registry.example/app:1.2.3" }),
    ).toMatchObject({ sourceMode: "image", image: "registry.example/app:1.2.3" });
  });
});

describe("new-app final validation", () => {
  it("requires an OpenBao value again after persisted drafts clear it", () => {
    const draft = {
      envVars: [{ key: "API_TOKEN", value: "", classification: "openbao" as const }],
    };

    expect(missingOpenBaoKeys(draft)).toEqual(["API_TOKEN"]);
  });

  it("maps indexed backend errors to their visible draft sections", () => {
    expect(draftFieldForApiError("envVars[0]")).toBe("envVars");
    expect(draftFieldForApiError("networkPolicy.allowedCIDRs[2]")).toBe(
      "allowedCidrs",
    );
    expect(draftFieldForApiError("image")).toBe("image");
  });
});

describe("custom egress CIDR validation", () => {
  it("accepts IPv4 and IPv6 CIDRs supported by Go net.ParseCIDR", () => {
    expect(isSafeAllowedCidr("203.0.113.10/32")).toBe(true);
    expect(isSafeAllowedCidr("2001:db8::1/64")).toBe(true);
    expect(isSafeAllowedCidr("::ffff:192.0.2.1/128")).toBe(true);
  });

  it("rejects whole-internet, malformed and non-Go IPv4 forms", () => {
    for (const cidr of [
      "0.0.0.0/0",
      "::/0",
      "2001:db8::1::2/64",
      "01.2.3.4/32",
      "192.0.2.1/032",
    ]) {
      expect(isSafeAllowedCidr(cidr), cidr).toBe(false);
    }
  });
});
