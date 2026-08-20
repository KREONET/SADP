export interface DeploymentAppCoordinates {
  name?: string;
  project?: string;
  environment?: string;
  group?: string;
}

const coordinate = (value: string | undefined) => value?.trim() ?? "";

/** 최신 신청을 고를 때 앱 이름뿐 아니라 서버 저장소와 같은 전체 좌표를 사용한다. */
export function deploymentIdentityKey(app: DeploymentAppCoordinates): string {
  return JSON.stringify([
    coordinate(app.project),
    coordinate(app.environment),
    coordinate(app.group),
    coordinate(app.name),
  ]);
}

/** AppGroup 앱은 공유 Zone이 아니라 해당 그룹의 전용 Namespace에 표시한다. */
export function deploymentNamespace(
  app: DeploymentAppCoordinates,
  zoneLabel: string,
  namespacePrefix: string,
): string {
  const group = coordinate(app.group);
  const prefix = namespacePrefix.trim();
  if (group) return prefix ? `${prefix}${group}` : "-";
  return zoneLabel.trim() || "-";
}
