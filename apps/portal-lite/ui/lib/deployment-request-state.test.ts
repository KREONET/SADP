import { describe, expect, it } from "vitest";

import { deploymentRequestPresentation } from "./deployment-request-state";

describe("deployment request result labels", () => {
  it("keeps deleting pending", () => {
    expect(deploymentRequestPresentation("deleting")).toEqual({
      status: "Validated",
      result: "Pending",
    });
  });

  it("distinguishes deleted from deployment success", () => {
    expect(deploymentRequestPresentation("deleted")).toEqual({
      status: "Validated",
      result: "Deleted",
    });
    expect(deploymentRequestPresentation("deployed").result).toBe("Success");
  });
});
