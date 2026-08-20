import type { Application } from "@/types/domain";

export interface StandaloneApplicationListItem {
  kind: "application";
  id: string;
  application: Application;
}

export interface AppGroupListItem {
  kind: "group";
  id: string;
  name: string;
  applications: Application[];
}

export type ApplicationListItem =
  | StandaloneApplicationListItem
  | AppGroupListItem;

export interface ApplicationListFilters {
  query: string;
  project: string;
  status: string;
}

/**
 * 활성 앱 하나를 단일 카드 또는 AppGroup 카드 한 곳에만 배정한다.
 * 첫 서비스가 있던 위치에 그룹 카드를 두어 API 최신순 정렬도 유지한다.
 */
export function groupApplicationList(
  applications: Application[],
): ApplicationListItem[] {
  const items: ApplicationListItem[] = [];
  const groups = new Map<string, AppGroupListItem>();

  for (const application of applications) {
    const groupName = application.group?.trim();
    if (!groupName) {
      items.push({
        kind: "application",
        id: `application:${application.id}`,
        application,
      });
      continue;
    }

    const existing = groups.get(groupName);
    if (existing) {
      existing.applications.push(application);
      continue;
    }

    const group: AppGroupListItem = {
      kind: "group",
      id: `group:${groupName}`,
      name: groupName,
      applications: [application],
    };
    groups.set(groupName, group);
    items.push(group);
  }

  return items;
}

function matchesProjectAndStatus(
  application: Application,
  filters: ApplicationListFilters,
): boolean {
  if (filters.project !== "all" && application.project !== filters.project) {
    return false;
  }
  return filters.status === "all" || application.status === filters.status;
}

/** 그룹 안의 서비스 하나라도 모든 조건을 만족하면 모든 활성 서비스를 함께 표시한다. */
export function filterApplicationList(
  items: ApplicationListItem[],
  filters: ApplicationListFilters,
): ApplicationListItem[] {
  const needle = filters.query.trim().toLowerCase();

  return items.filter((item) => {
    if (item.kind === "application") {
      return (
        (!needle || item.application.name.toLowerCase().includes(needle)) &&
        matchesProjectAndStatus(item.application, filters)
      );
    }

    const groupNameMatches = !needle || item.name.toLowerCase().includes(needle);
    return item.applications.some(
      (application) =>
        (groupNameMatches || application.name.toLowerCase().includes(needle)) &&
        matchesProjectAndStatus(application, filters),
    );
  });
}
