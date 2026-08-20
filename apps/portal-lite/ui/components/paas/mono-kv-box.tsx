import { cn } from "@/lib/utils";

export interface MonoKeyValueRow {
  label: string;
  value: string;
}

export interface MonoKeyValueBoxProps {
  rows: MonoKeyValueRow[];
  /**
   * split  - 라벨 좌측 / 값 우측 정렬(화면 1 앱 카드)
   * inline - `label: value` 한 줄(화면 2 워크로드 카드)
   */
  variant?: "split" | "inline";
  /** info 는 코드/정보 박스(secondary), muted 는 비활성 톤. */
  tone?: "info" | "muted";
  className?: string;
}

/**
 * 모노스페이스 key/value 박스.
 * 스펙상 URL·네임스페이스·env key 는 전부 모노스페이스이므로 이 컴포넌트로만 그린다.
 */
export function MonoKeyValueBox({
  rows,
  variant = "split",
  tone = "info",
  className,
}: MonoKeyValueBoxProps) {
  return (
    <dl
      className={cn(
        "rounded-md px-3 py-2 font-mono text-xs",
        tone === "info" ? "bg-secondary" : "bg-muted",
        className,
      )}
    >
      {rows.map((row) =>
        variant === "split" ? (
          <div
            key={row.label}
            className="flex items-baseline justify-between gap-4 py-1"
          >
            <dt className="shrink-0 text-muted-foreground">{row.label}</dt>
            <dd
              className="truncate text-right text-foreground"
              title={row.value}
            >
              {row.value}
            </dd>
          </div>
        ) : (
          <div key={row.label} className="flex items-baseline gap-1.5 py-0.5">
            <dt className="shrink-0 text-muted-foreground">{row.label}:</dt>
            <dd className="truncate text-foreground" title={row.value}>
              {row.value}
            </dd>
          </div>
        ),
      )}
    </dl>
  );
}
