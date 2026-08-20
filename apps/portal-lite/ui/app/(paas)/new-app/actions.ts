"use server";

import {
  getWizardOptions,
  submitDeploymentRequest,
  type AppProfileInput,
  type SubmitResult,
} from "@/lib/paas-api";
import { hasPortalApiRole } from "@/lib/portal-api-bff";
import { paasIdentity, requirePaasSession } from "@/lib/require-session";
import { draftFieldForApiError } from "@/lib/new-app-draft";
import type { NewAppDraft } from "@/types/domain";

export type SubmitDraftResult =
  | { ok: true; id: string; state: string; host: string }
  | { ok: false; reason: string; fieldErrors: Partial<Record<keyof NewAppDraft, string>> };

/**
 * 위저드 마지막 단계의 제출.
 *
 * 브라우저가 백엔드를 직접 부르지 않는다 — 신청자(`X-Portal-User`)는 세션에서
 * 나와야 하고, 백엔드 주소는 클러스터 내부라 사용자가 닿을 수 없기 때문이다.
 * `environment` 도 사용자가 보낸 값을 믿지 않고 카탈로그에서 다시 읽는다.
 *
 * `idempotencyKey` 는 초안마다 한 번 만들어 두고 재시도에도 같은 값을 쓴다.
 * 같은 키로 두 번 오면 Go 가 먼저 만든 신청을 그대로 돌려주므로 PR 이 두 개
 * 생기지 않는다.
 */
export async function submitNewApp(
  draft: NewAppDraft,
  idempotencyKey: string,
): Promise<SubmitDraftResult> {
  const { requester, roles } = paasIdentity(await requirePaasSession());
  if (!hasPortalApiRole(roles, "deployments:write")) {
    return {
      ok: false,
      reason: "배포 신청 권한이 없습니다.",
      fieldErrors: {},
    };
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

  const normalizedEnvVars = (draft.envVars ?? []).map((item) => {
    const raw = (item as { classification?: unknown }).classification;
    const classification =
      raw === "openbao" || raw === "secret"
        ? ("openbao" as const)
        : raw === "configmap"
          ? ("configmap" as const)
          : null;
    return { key: item.key, value: item.value, classification };
  });
  if (normalizedEnvVars.some((item) => item.classification === null)) {
    return {
      ok: false,
      reason: "환경변수 분류가 올바르지 않습니다. 다시 분류해 주세요.",
      fieldErrors: { envVars: "ConfigMap 또는 OpenBao 분류만 사용할 수 있습니다." },
    };
  }

  const input: AppProfileInput = {
    appName: draft.name.trim(),
    project: draft.project.trim(),
    environment: options.environment,
    gitRepository: draft.repositoryUrl.trim(),
    branch: draft.branch.trim(),
    dockerfile: draft.dockerfilePath.trim(),
    containerPort: Number(draft.port.trim()),
    exposure: { mode: draft.exposureMode },
    // 내부 전용 앱에 oidc를 보내면 서버가 422로 거부한다. 화면에서 이미 막지만
    // 초안이 남아 있을 수 있으므로 여기서도 노출 방식과 맞춘다.
    authentication: {
      mode: draft.exposureMode === "external" ? draft.authMode : "none",
    },
    networkPolicy: {
      egressMode: draft.egressMode,
      ...(draft.egressMode === "custom"
        ? {
            allowedCIDRs: draft.allowedCidrs.map((item) => ({
              cidr: item.cidr.trim(),
              port: Number(item.port.trim()),
              protocol: item.protocol,
            })),
          }
        : {}),
    },
    resourceSize: draft.resourceSize.trim(),
    replicas: Number(draft.replicas.trim()),
    // OpenBao 값은 이 요청에서만 포털 API로 전달되고 Git/PVC에는 저장되지 않는다.
    envVars: normalizedEnvVars.map((item) => ({
      key: item.key,
      value: item.value,
      classification: item.classification!,
    })),
  };

  const result: SubmitResult = await submitDeploymentRequest(
    input,
    requester,
    idempotencyKey,
  );

  if (result.ok) return result;

  const fieldErrors: Partial<Record<keyof NewAppDraft, string>> = {};
  for (const [field, message] of Object.entries(result.fieldErrors)) {
    const key = draftFieldForApiError(field);
    if (key) fieldErrors[key] = message;
  }

  return { ok: false, reason: result.reason, fieldErrors };
}
