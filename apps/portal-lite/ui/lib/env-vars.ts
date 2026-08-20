/**
 * 민감 키 판정 규칙. 화면에 흩어두지 않고 상수로 모아 둔다.
 * 서버·Chart와 같은 축을 쓰되 UI는 `KEY`도 넓게 잡아 애매하면 OpenBao로 유도한다.
 */
export const SENSITIVE_KEY_PATTERN =
  /(PASSWORD|PASSWD|SECRET|TOKEN|KEY|CREDENTIAL|PRIVATE|DSN|DATABASE_URL|DB_URL|CONNECTION_STRING|AUTHORIZATION|BEARER)/i;

/** 키가 평범해도 userinfo가 든 URI나 대표 Secret material은 평문 설정으로 보지 않는다. */
export function isSensitiveEnvValue(value: string): boolean {
  const trimmed = value.trim();
  return (
    /:\/\/[^/@:]+:[^/@]+@/u.test(trimmed) ||
    /-----BEGIN (?:RSA )?PRIVATE KEY-----/iu.test(trimmed) ||
    /^(?:hvs\.|ghp_|github_pat_|AKIA)/iu.test(trimmed)
  );
}
