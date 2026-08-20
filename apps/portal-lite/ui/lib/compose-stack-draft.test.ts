import { describe, expect, it } from "vitest";

import type { ComposePlan, ComposeServiceDraft } from "../types/domain";
import {
  composeFormSnapshot,
  reconcileComposeServices,
} from "./compose-stack-draft";

const apiDraft: ComposeServiceDraft = {
  name: "api",
  port: 3000,
  serviceEnabled: true,
  image: "old.example/api:1",
  exposureMode: "external",
  authMode: "oidc",
  egressMode: "custom",
  allowedCidrs: [{ cidr: "203.0.113.10/32", port: "443", protocol: "TCP" }],
  secretKeys: ["DATABASE_PASSWORD"],
  allowedApps: [{ app: "postgres", port: "5432", protocol: "TCP" }],
  ingressApps: [{ app: "frontend", port: "3000", protocol: "TCP" }],
};

function plan(services: ComposePlan["services"]): ComposePlan {
  return {
    group: "mobility",
    namespace: "app-mobility",
    source: { type: "compose" },
    warnings: [],
    services,
  };
}

describe("Compose draft reconciliation", () => {
  it("updates Compose-derived port/image while preserving per-app policy", () => {
    const [next] = reconcileComposeServices(
      [apiDraft],
      plan([
        {
          name: "api",
          namespace: "app-mobility",
          port: 8080,
          serviceEnabled: true,
          image: "new.example/api:2",
          exposureMode: "external",
          authMode: "oidc",
          egressMode: "custom",
        },
      ]),
    );

    expect(next).toEqual({
      ...apiDraft,
      port: 8080,
      image: "new.example/api:2",
      ingressApps: [{ app: "frontend", port: "8080", protocol: "TCP" }],
    });
  });

  it("models a portless service as an internal worker and removes inbound policy", () => {
    const [next] = reconcileComposeServices(
      [{ ...apiDraft, ingressApps: [{ app: "frontend", port: "3000", protocol: "TCP" }] }],
      plan([
        {
          name: "api",
          namespace: "app-mobility",
          port: 0,
          serviceEnabled: false,
          exposureMode: "internal",
          authMode: "none",
          egressMode: "blocked",
        },
      ]),
    );

    expect(next).toMatchObject({
      serviceEnabled: false,
      port: 0,
      exposureMode: "internal",
      authMode: "none",
      ingressApps: [],
    });
  });

  it("uses the validated plan defaults for newly discovered services", () => {
    const [next] = reconcileComposeServices(
      [],
      plan([
        {
          name: "worker",
          namespace: "app-mobility",
          port: 9000,
          serviceEnabled: true,
          exposureMode: "internal",
          authMode: "none",
          egressMode: "blocked",
        },
      ]),
    );

    expect(next).toMatchObject({
      name: "worker",
      port: 9000,
      exposureMode: "internal",
      authMode: "none",
      egressMode: "blocked",
      allowedCidrs: [],
      secretKeys: [],
      allowedApps: [],
      ingressApps: [],
    });
  });

  it("changes the validation snapshot when a nested policy changes", () => {
    const before = composeFormSnapshot({ services: [apiDraft] });
    const after = composeFormSnapshot({
      services: [{ ...apiDraft, egressMode: "blocked" }],
    });
    expect(after).not.toBe(before);
  });
});
