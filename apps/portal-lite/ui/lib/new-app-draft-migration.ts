import { EMPTY_DRAFT } from "./wizard";
import type { DraftEnvVar, NewAppDraft } from "../types/domain";

function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/**
 * 저장된 구형 초안을 현재의 독립된 노출·인증 모델로 올린다.
 *
 * 예전 화면은 `visibility: public|oidc`만 저장했다. 단순히 EMPTY_DRAFT와 합치면
 * `oidc` 초안도 기본값(external+none)이 되어 사용자가 모르는 사이 SSO가 꺼진다.
 */
export function migrateStoredDraft(value: unknown): NewAppDraft {
  const stored = record(value);
  const legacyVisibility = stored.visibility;
  const exposureMode =
    stored.exposureMode === "external" || stored.exposureMode === "internal"
      ? stored.exposureMode
      : legacyVisibility === "public" || legacyVisibility === "oidc"
        ? "external"
        : EMPTY_DRAFT.exposureMode;
  const storedAuthMode =
    stored.authMode === "none" || stored.authMode === "oidc"
      ? stored.authMode
      : legacyVisibility === "oidc"
        ? "oidc"
        : "none";
  // 저장 당시에는 가능한 조합이었더라도 internal에는 SecurityPolicy가 붙을
  // HTTPRoute가 없다. 오래된 모순 상태를 다시 화면에 살리지 않는다.
  const authMode = exposureMode === "internal" ? "none" : storedAuthMode;
  const egressMode =
    stored.egressMode === "blocked" ||
    stored.egressMode === "web" ||
    stored.egressMode === "custom"
      ? stored.egressMode
      : EMPTY_DRAFT.egressMode;

  const text = (key: keyof NewAppDraft): string =>
    typeof stored[key] === "string"
      ? (stored[key] as string)
      : (EMPTY_DRAFT[key] as string);

  const allowedCidrs = Array.isArray(stored.allowedCidrs)
    ? stored.allowedCidrs.flatMap((raw) => {
        const item = record(raw);
        if (typeof item.cidr !== "string" || typeof item.port !== "string") return [];
        return [
          {
            cidr: item.cidr,
            port: item.port,
            protocol: item.protocol === "UDP" ? ("UDP" as const) : ("TCP" as const),
          },
        ];
      })
    : [];
  const envVars = Array.isArray(stored.envVars)
    ? stored.envVars.flatMap((raw) => {
        const item = record(raw);
        if (
          typeof item.key !== "string" ||
          typeof item.value !== "string" ||
          (item.classification !== "configmap" &&
            item.classification !== "secret" &&
            item.classification !== "openbao")
        ) {
          return [];
        }
        return [
          {
            key: item.key,
            value: item.value,
            // 구형 초안의 secret 분류는 현재 OpenBao 경로와 같은 의미다. configmap으로
            // 떨어지면 값이 Git에 들어갈 수 있으므로 반드시 openbao로 올린다.
            classification: (item.classification === "secret"
              ? "openbao"
              : item.classification) as DraftEnvVar["classification"],
          },
        ];
      })
    : [];

  return {
    name: text("name"),
    project: text("project"),
    repositoryUrl: text("repositoryUrl"),
    branch: text("branch"),
    dockerfilePath: text("dockerfilePath"),
    port: text("port"),
    resourceSize: text("resourceSize"),
    replicas: text("replicas"),
    exposureMode,
    authMode,
    egressMode,
    allowedCidrs,
    envVars,
  };
}
