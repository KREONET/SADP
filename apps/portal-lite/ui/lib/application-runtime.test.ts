import { describe, expect, it } from "vitest";

import {
  applicationReplicaSummary,
  applicationStatusFromRequestState,
  isApplicationRuntimeTarget,
  runtimeActionForRequestState,
} from "./application-runtime";

describe("application runtime presentation", () => {
  it("distinguishes stopped apps from transitional pipeline states", () => {
    expect(applicationStatusFromRequestState("deployed")).toBe("RUNNING");
    expect(applicationStatusFromRequestState("stopped")).toBe("STOPPED");
    expect(applicationStatusFromRequestState("stopping")).toBe("PENDING");
    expect(applicationStatusFromRequestState("starting")).toBe("PENDING");
    expect(applicationStatusFromRequestState("failed")).toBe("FAILED");
  });

  it("only claims replica observations in terminal runtime states", () => {
    expect(applicationReplicaSummary("deployed", 3)).toBe("3/3");
    expect(applicationReplicaSummary("stopped", 3)).toBe("0/3");
    expect(applicationReplicaSummary("stopping", 3)).toBe("-/3");
    expect(applicationReplicaSummary("starting", 3)).toBe("-/3");
    expect(applicationReplicaSummary("failed", 3)).toBe("-/3");
    expect(applicationReplicaSummary("deployed", undefined)).toBeUndefined();
    expect(applicationReplicaSummary("deployed", 0)).toBeUndefined();
  });

  it("offers one mutation only from stable runtime states", () => {
    expect(runtimeActionForRequestState("deployed")).toBe("stop");
    expect(runtimeActionForRequestState("stopped")).toBe("resume");
    expect(runtimeActionForRequestState("stopping")).toBeNull();
    expect(runtimeActionForRequestState("starting")).toBeNull();
    expect(runtimeActionForRequestState("failed")).toBeNull();
  });

  it("retries only failures that came from a matching runtime transition", () => {
    expect(
      runtimeActionForRequestState("failed", "stopped", "stopping"),
    ).toBe("stop");
    expect(
      runtimeActionForRequestState("failed", "running", "starting"),
    ).toBe("resume");
    expect(
      runtimeActionForRequestState("failed", "running", "deploying"),
    ).toBeNull();
    expect(
      runtimeActionForRequestState("failed", "running", "stopping"),
    ).toBeNull();
  });

  it("rejects arbitrary runtime targets at the Server Action boundary", () => {
    expect(isApplicationRuntimeTarget("running")).toBe(true);
    expect(isApplicationRuntimeTarget("stopped")).toBe(true);
    expect(isApplicationRuntimeTarget("deleted")).toBe(false);
    expect(isApplicationRuntimeTarget({ state: "running" })).toBe(false);
  });
});
