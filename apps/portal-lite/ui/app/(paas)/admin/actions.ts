"use server";

import { revalidatePath } from "next/cache";

import {
  decideDeploymentApproval,
  updateAutoApprovalPolicy,
} from "@/lib/paas-api";
import { paasIdentity, requirePortalAdmin } from "@/lib/require-session";
import type { AdminMutationResult } from "@/types/domain";

const REQUEST_ID = /^[0-9a-f]{16}$/;

/** UI를 우회해 action을 직접 호출해도 세션의 platform-admin 역할을 다시 검사한다. */
export async function decideAdminDeployment(
  requestId: string,
  decision: "approved" | "rejected",
  reason: string,
): Promise<AdminMutationResult> {
  const { requester, roles } = paasIdentity(await requirePortalAdmin());
  const normalizedID = requestId.trim();
  const normalizedReason = reason.trim();
  if (!requester || !REQUEST_ID.test(normalizedID)) {
    return { ok: false, reason: "배포 신청 식별자가 올바르지 않습니다." };
  }
  if (decision !== "approved" && decision !== "rejected") {
    return { ok: false, reason: "승인 결정이 올바르지 않습니다." };
  }
  if (decision === "rejected" && !normalizedReason) {
    return { ok: false, reason: "반려 사유를 반드시 입력해야 합니다." };
  }
  if (normalizedReason.length > 2000 || normalizedReason.includes("\0")) {
    return { ok: false, reason: "반려 사유는 제어문자 없이 2000자 이하여야 합니다." };
  }

  const result = await decideDeploymentApproval(
    normalizedID,
    decision,
    normalizedReason,
    requester,
    roles,
  );
  if (result.ok) revalidatePath("/admin");
  return result;
}

/** 사용자별 예외 변경도 관리자 세션을 다시 확인하고 서버가 감사 이력을 영속화한다. */
export async function setAdminAutoApprovalPolicy(
  policyRequester: string,
  enabled: boolean,
): Promise<AdminMutationResult> {
  const { requester, roles } = paasIdentity(await requirePortalAdmin());
  const target = policyRequester.trim();
  if (
    !requester ||
    !target ||
    target.length > 128 ||
    target.includes("/") ||
    target.includes("\\") ||
    [...target].some((character) => /\p{Cc}/u.test(character))
  ) {
    return { ok: false, reason: "자동 승인 대상 사용자 식별자가 올바르지 않습니다." };
  }

  const result = await updateAutoApprovalPolicy(
    target,
    enabled,
    requester,
    roles,
  );
  if (result.ok) revalidatePath("/admin");
  return result;
}
