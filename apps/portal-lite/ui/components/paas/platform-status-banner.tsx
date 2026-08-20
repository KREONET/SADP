import { GitMerge } from "lucide-react";
import type { ReactNode } from "react";

import { Card } from "@/components/ui/card";
import { getI18n } from "@/lib/i18n/server";
import { cn } from "@/lib/utils";
import type { OverallStatus } from "@/types/domain";

function StatusChip({
  label,
  value,
  icon,
  className,
}: {
  label: string;
  value: string;
  icon: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex min-w-45 items-center gap-3 rounded-lg px-4 py-3",
        className,
      )}
    >
      <span className="shrink-0">{icon}</span>
      <span className="min-w-0">
        <span className="block text-[11px] font-semibold tracking-[0.1em] text-muted-foreground uppercase">
          {label}
        </span>
        <span className="block truncate text-lg font-bold text-brand-900">
          {value}
        </span>
      </span>
    </div>
  );
}

/** 화면 2 최상단 플랫폼 현황 배너. 좌측 제목·설명 + 우측 상태 칩 2개. */
export async function PlatformStatusBanner({
  title,
  summary,
  overall,
  gitlab,
}: {
  title: string;
  summary: string[];
  overall: OverallStatus;
  gitlab: OverallStatus;
}) {
  const { dict } = await getI18n();

  return (
    <Card className="flex-col gap-6 p-8 lg:flex-row lg:items-center lg:justify-between">
      <div className="space-y-2">
        <h1 className="text-3xl font-bold tracking-tight text-brand-900">
          {title}
        </h1>
        <div className="text-sm leading-relaxed text-muted-foreground">
          {summary.map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-4">
        <StatusChip
          label={dict.dashboard.overallStatus}
          value={overall.label}
          className="bg-status-ok-soft"
          icon={
            <span
              className="block size-2.5 rounded-full bg-status-ok"
              aria-hidden
            />
          }
        />
        <StatusChip
          label={dict.dashboard.gitlabIntegration}
          value={gitlab.label}
          className="bg-secondary"
          icon={<GitMerge className="size-5 text-brand-900" aria-hidden />}
        />
      </div>
    </Card>
  );
}
