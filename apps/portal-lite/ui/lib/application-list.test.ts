import { describe, expect, it } from "vitest";

import {
  filterApplicationList,
  groupApplicationList,
} from "./application-list";
import type { Application, ApplicationStatus } from "@/types/domain";

function application(
  id: string,
  name: string,
  status: ApplicationStatus,
  group?: string,
): Application {
  return {
    id,
    name,
    project: "research",
    group,
    status,
    cluster: "rke2",
    zone: group ? `app-${group}` : "zone-a",
    internalAddress: `${name}.app-${group ?? "zone-a"}.svc.cluster.local`,
    replicas: "1/1",
    lastDeployedAt: "2026-08-20T00:00:00Z",
    lastDeployedBy: "tester",
  };
}

describe("application list grouping", () => {
  it("assigns every service to exactly one AppGroup or standalone card", () => {
    const input = [
      application("api", "api", "RUNNING", "stack"),
      application("single", "single", "RUNNING"),
      application("worker", "worker", "STOPPED", "stack"),
      application("other-api", "api", "PENDING", "other"),
    ];

    const items = groupApplicationList(input);
    expect(items.map((item) => item.kind)).toEqual([
      "group",
      "application",
      "group",
    ]);

    const assignedIds = items.flatMap((item) =>
      item.kind === "group"
        ? item.applications.map((app) => app.id)
        : [item.application.id],
    );
    expect(assignedIds).toEqual(["api", "worker", "single", "other-api"]);
    expect(new Set(assignedIds).size).toBe(input.length);
  });

  it("matches a group by an inner service while retaining all active services", () => {
    const items = groupApplicationList([
      application("api", "api", "RUNNING", "stack"),
      application("worker", "worker", "STOPPED", "stack"),
      application("single", "single", "RUNNING"),
    ]);

    const byName = filterApplicationList(items, {
      query: "worker",
      project: "all",
      status: "all",
    });
    expect(byName).toHaveLength(1);
    expect(byName[0]).toMatchObject({ kind: "group", name: "stack" });
    expect(
      byName[0]?.kind === "group" ? byName[0].applications : [],
    ).toHaveLength(2);

    const byStatus = filterApplicationList(items, {
      query: "",
      project: "all",
      status: "STOPPED",
    });
    expect(byStatus).toHaveLength(1);
    expect(byStatus[0]).toMatchObject({ kind: "group", name: "stack" });
  });
});
