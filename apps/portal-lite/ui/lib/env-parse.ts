import {
  isSensitiveEnvValue,
  SENSITIVE_KEY_PATTERN,
} from "@/lib/env-vars";

/** 마스킹 표시용 문자열. */
export const MASKED_VALUE = "••••••••••";

export interface ParsedEnvLine {
  key: string;
  value: string;
}

/** 키 이름만 보고 민감 여부를 판정한다. 규칙은 lib/env-vars.ts 한 곳에서 관리. */
export function isSensitiveKey(key: string): boolean {
  return SENSITIVE_KEY_PATTERN.test(key);
}

export { isSensitiveEnvValue };

/**
 * .env 원문을 KEY/value 목록으로 파싱한다.
 * - `#` 주석 줄과 빈 줄은 버린다.
 * - `export ` 접두사를 제거한다.
 * - 첫 번째 `=` 만 구분자로 쓴다(값에 `=`가 있어도 안전).
 * - 값을 감싼 홑/겹따옴표는 벗겨낸다.
 * - 같은 키가 여러 번 나오면 마지막 값이 이긴다.
 */
export function parseEnvText(raw: string): ParsedEnvLine[] {
  const result = new Map<string, string>();

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const withoutExport = trimmed.replace(/^export\s+/, "");
    const separator = withoutExport.indexOf("=");
    if (separator <= 0) continue;

    const key = withoutExport.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_.]*$/.test(key)) continue;

    let value = withoutExport.slice(separator + 1).trim();
    const quoted =
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"));
    if (quoted && value.length >= 2) value = value.slice(1, -1);

    result.set(key, value);
  }

  return [...result].map(([key, value]) => ({ key, value }));
}
