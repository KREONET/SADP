import type { DraftEnvVar, NewAppDraft } from "../types/domain";

const API_FIELD_TO_DRAFT: Record<string, keyof NewAppDraft> = {
  appName: "name",
  project: "project",
  gitRepository: "repositoryUrl",
  branch: "branch",
  dockerfile: "dockerfilePath",
  containerPort: "port",
  resourceSize: "resourceSize",
  replicas: "replicas",
  exposure: "exposureMode",
  authentication: "authMode",
  "networkPolicy.egressMode": "egressMode",
  "networkPolicy.allowedCIDRs": "allowedCidrs",
  envVars: "envVars",
};

/** Go의 배열 행 오류를 위저드가 가진 가장 가까운 입력 묶음으로 옮긴다. */
export function draftFieldForApiError(
  field: string,
): keyof NewAppDraft | undefined {
  const exact = API_FIELD_TO_DRAFT[field];
  if (exact) return exact;
  if (field.startsWith("networkPolicy.allowedCIDRs[")) return "allowedCidrs";
  if (field.startsWith("envVars[") || field.startsWith("envVars.")) {
    return "envVars";
  }
  return undefined;
}

/** sessionStorage에서 의도적으로 지운 OpenBao 값 중 다시 입력해야 할 key 목록. */
export function missingOpenBaoKeys(draft: {
  envVars: readonly DraftEnvVar[];
}): string[] {
  return draft.envVars
    .filter(
      (item) => item.classification === "openbao" && item.value.length === 0,
    )
    .map((item) => item.key.trim() || "(이름 없음)");
}

/** 서버 net.ParseCIDR + "/0 금지"와 같은 판단. */
export function isSafeAllowedCidr(value: string): boolean {
  const trimmed = value.trim();
  const slash = trimmed.lastIndexOf("/");
  if (slash <= 0 || slash !== trimmed.indexOf("/")) return false;

  const address = trimmed.slice(0, slash);
  const prefixText = trimmed.slice(slash + 1);
  if (
    !/^\d{1,3}$/.test(prefixText) ||
    (prefixText.length > 1 && prefixText.startsWith("0"))
  ) {
    return false;
  }
  const prefix = Number(prefixText);

  if (address.includes(":")) {
    // URL의 bracketed host parser는 압축형·IPv4-mapped IPv6를 포함해 IPv6 문법을
    // 검증한다. zone id와 잘못된 이중 압축은 거부하므로 Go net.ParseCIDR과 맞는다.
    try {
      const parsed = new URL(`http://[${address}]/`);
      if (!parsed.hostname.startsWith("[") || !parsed.hostname.endsWith("]")) {
        return false;
      }
    } catch {
      return false;
    }
    return prefix >= 1 && prefix <= 128;
  }

  const octets = address.split(".");
  if (
    octets.length !== 4 ||
    octets.some(
      (part) =>
        !/^\d{1,3}$/.test(part) ||
        (part.length > 1 && part.startsWith("0")) ||
        Number(part) > 255,
    )
  ) {
    return false;
  }
  // /0 은 인터넷 전체다. 그건 '웹 통신만 허용'(web) 모드가 할 일이다.
  return prefix >= 1 && prefix <= 32;
}
