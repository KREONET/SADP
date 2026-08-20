import { describe, expect, it } from "vitest";

import type { ComposeServiceDraft } from "../types/domain";
import { composeServiceOverrides } from "./compose-stack-input";

function draft(patch: Partial<ComposeServiceDraft> = {}): ComposeServiceDraft {
  return {
    name: "api",
    port: 8080,
    serviceEnabled: true,
    exposureMode: "internal",
    authMode: "none",
    egressMode: "blocked",
    allowedCidrs: [],
    secretKeys: [],
    allowedApps: [],
    ingressApps: [],
    ...patch,
  };
}

describe("Compose AppGroup API serialization", () => {
  it("serializes custom CIDR, port and protocol", () => {
    const [service] = composeServiceOverrides([
      draft({
        egressMode: "custom",
        allowedCidrs: [
          { cidr: " 203.0.113.10/32 ", port: "443", protocol: "TCP" },
        ],
      }),
    ]);

    expect(service.networkPolicy?.allowedCIDRs).toEqual([
      { cidr: "203.0.113.10/32", port: 443, protocol: "TCP" },
    ]);
  });

  it("does not silently delete an incomplete app connection", () => {
    const [service] = composeServiceOverrides([
      draft({
        allowedApps: [{ app: "", port: "", protocol: "TCP" }],
        ingressApps: [{ app: "", port: "", protocol: "TCP" }],
      }),
    ]);

    expect(service.networkPolicy?.allowedApps).toEqual([
      { app: "", port: 0, protocol: "TCP" },
    ]);
    expect(service.networkPolicy?.ingress?.allowedApps).toEqual([
      { app: "", port: 0, protocol: "TCP" },
    ]);
  });

  it("does not send dormant CIDRs outside custom mode", () => {
    const [service] = composeServiceOverrides([
      draft({
        allowedCidrs: [{ cidr: "203.0.113.10/32", port: "443", protocol: "TCP" }],
      }),
    ]);
    expect(service.networkPolicy).not.toHaveProperty("allowedCIDRs");
  });

  it("sends only trimmed OpenBao key names, never a value field", () => {
    const [service] = composeServiceOverrides([
      draft({ secretKeys: [" DATABASE_PASSWORD ", "API_TOKEN"] }),
    ]);
    expect(service.secretKeys).toEqual(["DATABASE_PASSWORD", "API_TOKEN"]);
    expect(JSON.stringify(service)).not.toContain("secretValue");
  });
});
