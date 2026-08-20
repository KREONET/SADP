import { describe, expect, it } from "vitest";

import {
  deploymentIdentityKey,
  deploymentNamespace,
} from "./deployment-identity";

describe("deployment application identity", () => {
  it("keeps the same service name in different AppGroups distinct", () => {
    const first = deploymentIdentityKey({
      name: "api",
      project: "research",
      environment: "prod",
      group: "mobility",
    });
    const second = deploymentIdentityKey({
      name: "api",
      project: "research",
      environment: "prod",
      group: "climate",
    });

    expect(first).not.toBe(second);
  });

  it("derives an AppGroup namespace from the catalog prefix", () => {
    expect(
      deploymentNamespace({ group: "mobility" }, "research-prod", "team-"),
    ).toBe("team-mobility");
    expect(deploymentNamespace({}, "research-prod", "team-")).toBe(
      "research-prod",
    );
  });

  it("does not invent a namespace when the AppGroup prefix is unavailable", () => {
    expect(deploymentNamespace({ group: "mobility" }, "research-prod", "")).toBe(
      "-",
    );
  });
});
