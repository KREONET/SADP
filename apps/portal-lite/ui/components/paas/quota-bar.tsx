import { Progress } from "@/components/ui/progress";
import { getI18n } from "@/lib/i18n/server";
import { cn } from "@/lib/utils";
import type { QuotaMetric, StatusTone } from "@/types/domain";

/**
 * 사용률 기준 자동 색 계열(metric.tone 미지정 시).
 * 90% 이상 레드 / 70% 이상 옐로-그린 / 그 외 딥그린.
 */
function autoTone(ratio: number): StatusTone {
  if (ratio >= 0.9) return "error";
  if (ratio >= 0.7) return "warn";
  return "ok";
}

/** 레일 색. 스크린샷 기준 정상 구간은 status-ok 가 아니라 딥그린이다. */
const railTone: Record<StatusTone, string> = {
  ok: "[&>[data-slot=progress-indicator]]:bg-brand-900",
  warn: "[&>[data-slot=progress-indicator]]:bg-nav-active",
  error: "[&>[data-slot=progress-indicator]]:bg-status-error",
  idle: "[&>[data-slot=progress-indicator]]:bg-status-idle",
};

/** 화면 2 MY QUOTA USAGE 한 줄. 라벨 + 우측 사용/총량 + 얇은 진행바. */
export async function QuotaBar({
  metric,
  className,
}: {
  metric: QuotaMetric;
  className?: string;
}) {
  const { dict } = await getI18n();
  const ratio = metric.total > 0 ? metric.used / metric.total : 0;
  const tone = metric.tone ?? autoTone(ratio);

  return (
    <div className={cn("space-y-1.5", className)}>
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-sm font-medium text-foreground">
          {metric.label}
        </span>
        <span className="font-mono text-xs text-muted-foreground">
          {metric.used} / {metric.total}
          {metric.unit ? ` ${metric.unit}` : ""}
        </span>
      </div>
      <Progress
        value={Math.round(ratio * 100)}
        aria-label={dict.dashboard.quotaUsageOf.replace("{name}", metric.label)}
        className={cn("h-1.5 bg-muted", railTone[tone])}
      />
    </div>
  );
}
