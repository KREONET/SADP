"use server";

import {
  getWizardOptions,
  submitAppGroup,
  validateAppGroup,
  type AppGroupInput,
} from "@/lib/paas-api";
import { composeServiceOverrides } from "@/lib/compose-stack-input";
import { hasPortalApiRole } from "@/lib/portal-api-bff";
import { paasIdentity, requirePaasSession } from "@/lib/require-session";
import type { ComposePlan, ComposeServiceDraft } from "@/types/domain";

/**
 * Git/Compose 다중 앱 화면의 서버 액션.
 *
 * 브라우저가 백엔드를 직접 부르지 않는다 — 신청자(`X-Portal-User`)는 세션에서
 * 나와야 하고, 백엔드 주소는 클러스터 내부라 사용자가 닿을 수 없다.
 * `environment` 도 사용자가 보낸 값을 믿지 않고 카탈로그에서 다시 읽는다.
 */

export interface ComposeFormInput {
  group: string;
  project: string;
  sourceMode: "git" | "compose";
  repository: string;
  repositoryRevision: string;
  compose: string;
  resourceSize: string;
  services: ComposeServiceDraft[];
}

export type ComposeValidateResult =
  | { ok: true; plan: ComposePlan }
  | { ok: false; reason: string; fieldErrors: Record<string, string> };

export type ComposeSubmitResult =
  | { ok: true; group: string; namespace: string; count: number }
  | { ok: false; reason: string; fieldErrors: Record<string, string> };

async function toApiInput(form: ComposeFormInput): Promise<AppGroupInput> {
  const options = await getWizardOptions();
  return {
    group: form.group.trim(),
    project: form.project.trim(),
    environment: options.environment,
    ...(form.sourceMode === "git"
      ? {
          repository: form.repository.trim(),
          ...(form.repositoryRevision
            ? { repositoryRevision: form.repositoryRevision }
            : {}),
        }
      : { compose: form.compose }),
    resourceSize: form.resourceSize.trim(),
    services: composeServiceOverrides(form.services),
  };
}

/** 저장하지 않고 서비스 목록과 배포 계획만 계산한다. */
export async function validateComposeStack(
  form: ComposeFormInput,
): Promise<ComposeValidateResult> {
  const { requester, roles } = paasIdentity(await requirePaasSession());
  if (!hasPortalApiRole(roles, "deployments:write")) {
    return { ok: false, reason: "배포 신청 권한이 없습니다.", fieldErrors: {} };
  }
  if (!requester) {
    return {
      ok: false,
      reason: "로그인 정보를 확인하지 못했습니다. 다시 로그인해 주세요.",
      fieldErrors: {},
    };
  }
  return validateAppGroup(await toApiInput(form), requester);
}

/** 서비스 수만큼 배포 요청을 만든다. */
export async function submitComposeStack(
  form: ComposeFormInput,
  idempotencyKey: string,
): Promise<ComposeSubmitResult> {
  const { requester, roles } = paasIdentity(await requirePaasSession());
  if (!hasPortalApiRole(roles, "deployments:write")) {
    return { ok: false, reason: "배포 신청 권한이 없습니다.", fieldErrors: {} };
  }
  if (!requester) {
    return {
      ok: false,
      reason: "로그인 정보를 확인하지 못했습니다. 다시 로그인해 주세요.",
      fieldErrors: {},
    };
  }
  const options = await getWizardOptions();
  if (!options.submissionEnabled) {
    return {
      ok: false,
      reason: "지금은 배포 신청을 받지 않습니다. 잠시 후 다시 시도해 주세요.",
      fieldErrors: {},
    };
  }
  return submitAppGroup(await toApiInput(form), requester, idempotencyKey);
}
