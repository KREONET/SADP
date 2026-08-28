/**
 * 사용자당 자원 상한 계산. 서버(apps/portal-lite/backend/quota.go)와 같은 규칙을 쓴다.
 * UI에서 통과한 입력이 서버에서 막히면 사용자는 이유를 알 수 없으므로,
 * 파싱·비교 방식(정수 millicore, 이진 접두사)을 서버와 동일하게 맞춘다.
 */

/** 기본 상한. 서버 defaultUserQuota*, 네임스페이스 ResourceQuota와 같은 값이다. */
export const USER_QUOTA = {
  cpu: "3",
  memory: "5Gi",
} as const;

/** 한 앱이 만들 수 있는 Pod 수 상한. 서버 maxAppReplicas와 같다. */
export const MAX_APP_REPLICAS = 5;

/** "500m" | "1" | "1.5" → millicore. 해석 불가면 null. */
export function parseCpuMilli(value: string): number | null {
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.endsWith("m")) {
    const rest = trimmed.slice(0, -1).trim();
    if (!/^\d+$/.test(rest)) return null;
    return Number(rest);
  }
  if (!/^\d+(\.\d+)?$/.test(trimmed)) return null;
  return Math.round(Number(trimmed) * 1000);
}

/** 큰 단위부터 봐야 "Mi"가 "M"으로 잘리지 않는다. */
const MEMORY_SUFFIXES: ReadonlyArray<readonly [string, number]> = [
  ["Ki", 1024],
  ["Mi", 1024 ** 2],
  ["Gi", 1024 ** 3],
  ["Ti", 1024 ** 4],
  ["K", 1000],
  ["M", 1000 ** 2],
  ["G", 1000 ** 3],
  ["T", 1000 ** 4],
];

/** "512Mi" | "5Gi" | "2G" | "1073741824" → byte. 해석 불가면 null. */
export function parseMemoryBytes(value: string): number | null {
  const trimmed = value.trim();
  if (!trimmed) return null;
  for (const [suffix, factor] of MEMORY_SUFFIXES) {
    if (!trimmed.endsWith(suffix)) continue;
    const rest = trimmed.slice(0, -suffix.length).trim();
    if (!/^\d+(\.\d+)?$/.test(rest)) return null;
    return Math.round(Number(rest) * factor);
  }
  if (!/^\d+$/.test(trimmed)) return null;
  return Number(trimmed);
}

/** 1500 → "1500m", 2000 → "2". */
export function formatCpuMilli(milli: number): string {
  return milli % 1000 === 0 ? String(milli / 1000) : `${milli}m`;
}

/** 나누어떨어지는 큰 단위를 고른다. */
export function formatMemoryBytes(bytes: number): string {
  if (bytes >= 1024 ** 3 && bytes % 1024 ** 3 === 0) {
    return `${bytes / 1024 ** 3}Gi`;
  }
  if (bytes >= 1024 ** 2 && bytes % 1024 ** 2 === 0) {
    return `${bytes / 1024 ** 2}Mi`;
  }
  return String(bytes);
}

export interface QuotaCheck {
  /** 상한을 넘었는지. 입력이 아직 해석 불가면 false(다른 검증이 먼저 잡는다). */
  cpuOver: boolean;
  memoryOver: boolean;
  /** 사람이 읽는 사용량 표기. 해석 불가면 빈 문자열. */
  usedCpu: string;
  usedMemory: string;
}

/**
 * limit × replicas가 상한을 넘는지 본다.
 * 스케줄러는 request를 보지만 사용자에게 약속한 상한은 "최대 얼마까지"이므로
 * 서버와 같이 limit 기준으로 계산한다.
 */
export function checkUserQuota(
  cpuLimit: string,
  memoryLimit: string,
  replicas: string,
  /** 카탈로그가 알려준 상한. 못 읽었으면 기본값으로 검사한다. */
  quota: { cpu: string; memory: string } = USER_QUOTA,
): QuotaCheck {
  const empty: QuotaCheck = {
    cpuOver: false,
    memoryOver: false,
    usedCpu: "",
    usedMemory: "",
  };

  const count = Number(replicas.trim());
  if (!Number.isInteger(count) || count < 1) return empty;

  const limitCpu = parseCpuMilli(quota.cpu);
  const limitMemory = parseMemoryBytes(quota.memory);
  if (limitCpu === null || limitMemory === null) return empty;

  const cpu = parseCpuMilli(cpuLimit);
  const memory = parseMemoryBytes(memoryLimit);
  const usedCpu = cpu === null ? null : cpu * count;
  const usedMemory = memory === null ? null : memory * count;

  return {
    cpuOver: usedCpu !== null && usedCpu > limitCpu,
    memoryOver: usedMemory !== null && usedMemory > limitMemory,
    usedCpu: usedCpu === null ? "" : formatCpuMilli(usedCpu),
    usedMemory: usedMemory === null ? "" : formatMemoryBytes(usedMemory),
  };
}
