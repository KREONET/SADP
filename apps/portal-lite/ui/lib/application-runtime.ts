import type { ApplicationStatus } from "@/types/domain";

export type ApplicationRuntimeAction = "stop" | "resume";
export type ApplicationRuntimeTarget = "running" | "stopped";

/**
 * 백엔드 파이프라인 상태를 사용자가 이해할 실행 상태로 줄인다.
 * 전환 중에는 실제 Ready Pod 수가 아직 확정되지 않으므로 PENDING으로 남긴다.
 */
export function applicationStatusFromRequestState(
  state: string,
): ApplicationStatus {
  if (state === "deployed") return "RUNNING";
  if (state === "stopped") return "STOPPED";
  return state === "failed" ? "FAILED" : "PENDING";
}

/**
 * 프로필의 replicas는 목표 수일 뿐이다. 관측값이 확실한 terminal 상태만 N/N 또는 0/N으로
 * 표시하고, 시작·정지 중이나 실패 상태를 실제 replica 수처럼 단정하지 않는다.
 */
export function applicationReplicaSummary(
  state: string,
  replicas: number | undefined,
): string | undefined {
  if (!Number.isInteger(replicas) || !replicas || replicas < 1) return undefined;
  if (state === "deployed") return `${replicas}/${replicas}`;
  if (state === "stopped") return `0/${replicas}`;
  return `-/${replicas}`;
}

/** terminal 상태에서만 같은 앱에 다음 runtime 변경을 허용한다. */
export function runtimeActionForRequestState(
  state: string,
  desiredRuntimeState?: string,
  failedFromState?: string,
): ApplicationRuntimeAction | null {
  if (state === "deployed") return "stop";
  if (state === "stopped") return "resume";
  // 일반 배포 실패와 runtime 전환 실패를 섞지 않는다. 백엔드가 남긴 목표와
  // checkpoint가 모두 일치할 때만 같은 멱등 전환을 다시 요청한다.
  if (
    state === "failed" &&
    desiredRuntimeState === "stopped" &&
    failedFromState === "stopping"
  ) {
    return "stop";
  }
  if (
    state === "failed" &&
    desiredRuntimeState === "running" &&
    failedFromState === "starting"
  ) {
    return "resume";
  }
  return null;
}

/** Server Action으로 들어온 문자열을 백엔드가 받는 두 목표 상태로 제한한다. */
export function isApplicationRuntimeTarget(
  value: unknown,
): value is ApplicationRuntimeTarget {
  return value === "running" || value === "stopped";
}
