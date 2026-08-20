"use server";

import {
  isApplicationRuntimeTarget,
  type ApplicationRuntimeTarget,
} from "@/lib/application-runtime";
import {
  deleteDeploymentRequest,
  type DeleteResult,
  type RuntimeStateResult,
  updateDeploymentRuntimeState,
} from "@/lib/paas-api";
import { hasPortalApiRole } from "@/lib/portal-api-bff";
import { paasIdentity, requirePaasSession } from "@/lib/require-session";

export async function deleteMyApplication(
  requestId: string,
): Promise<DeleteResult> {
  const { requester, roles } = paasIdentity(await requirePaasSession());
  if (!hasPortalApiRole(roles, "deployments:write")) {
    return { ok: false, reason: "배포 삭제 권한이 없습니다." };
  }
  if (!requester) {
    return { ok: false, reason: "로그인 정보를 확인하지 못했습니다." };
  }
  return deleteDeploymentRequest(requestId, requester);
}

/**
 * 화면에서 버튼을 숨기는 것만으로 권한을 보장할 수 없으므로 Server Action 안에서
 * 세션·write 역할·허용된 목표 상태를 모두 다시 확인한다.
 */
export async function changeMyApplicationRuntimeState(
  requestId: string,
  desiredState: ApplicationRuntimeTarget,
): Promise<RuntimeStateResult> {
  const { requester, roles } = paasIdentity(await requirePaasSession());
  if (!hasPortalApiRole(roles, "deployments:write")) {
    return { ok: false, reason: "앱 실행 상태를 변경할 권한이 없습니다." };
  }
  if (!requester) {
    return { ok: false, reason: "로그인 정보를 확인하지 못했습니다." };
  }
  if (!isApplicationRuntimeTarget(desiredState)) {
    return { ok: false, reason: "요청한 실행 상태가 올바르지 않습니다." };
  }
  return updateDeploymentRuntimeState(requestId, requester, desiredState);
}
