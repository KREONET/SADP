"use client";

import { MonoKeyValueBox } from "@/components/paas/mono-kv-box";
import { RelativeTime } from "@/components/paas/relative-time";
import { ReviewStatus } from "@/components/paas/review-status";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { StatusPill } from "@/components/paas/status-pill";
import { cn } from "@/lib/utils";
import { useI18n } from "@/lib/i18n/context";
import type { Application } from "@/types/domain";
import Link from "next/link";

/** RUNNING 그린 · PENDING 앰버 · FAILED 레드 · STOPPED 회색. */
const TONE_BY_STATUS = {
  RUNNING: "ok",
  PENDING: "warn",
  FAILED: "error",
  STOPPED: "idle",
} as const;

const toneOf = (status: Application["status"]) => TONE_BY_STATUS[status];

/**
 * 화면 1 의 애플리케이션 카드.
 * RUNNING / STOPPED 에 따라 정보 행 배경과 카드 보더 진하기가 달라진다.
 */
export function AppCard({
  app,
  view = "grid",
  className,
}: {
  app: Application;
  view?: "grid" | "list";
  className?: string;
}) {
  const { dict } = useI18n();
  const card = dict.myApps.card;
  // internal 앱에는 Route가 없어도 정상 실행될 수 있으므로 실제 runtime 상태를 쓴다.
  const running = app.status === "RUNNING";

  const infoRows = [
    { label: card.cluster, value: app.cluster },
    { label: card.zone, value: app.zone },
    ...(app.internalAddress
      ? [{ label: card.internalAddress, value: app.internalAddress }]
      : []),
    ...(app.route ? [{ label: card.route, value: app.route }] : []),
    { label: card.replicas, value: app.replicas ?? "-" },
  ];

  return (
    <Card
      className={cn(
        "gap-0 overflow-hidden py-0 transition-shadow hover:shadow-sm",
        running ? "border-border" : "border-border/60",
        view === "list" && "sm:flex-row sm:items-center",
        className,
      )}
    >
      <div className={cn("flex-1 space-y-3 p-5", view === "list" && "sm:py-4")}>
        <div className="flex items-start justify-between gap-3">
          <p className="text-xs font-semibold tracking-[0.12em] text-muted-foreground uppercase">
            {app.project}
          </p>
          <StatusPill tone={toneOf(app.status)} dot>
            {app.status}
          </StatusPill>
        </div>

        <p className="text-lg font-bold text-brand-900">{app.name}</p>

        <MonoKeyValueBox rows={infoRows} tone={running ? "info" : "muted"} />
        <ReviewStatus
          approval={app.approvalStatus}
          security={app.securityReviewStatus}
          labels={card}
        />
      </div>

      <div
        className={cn(
          "flex items-center justify-between gap-4 border-t border-border px-5 py-3",
          view === "list" && "sm:w-80 sm:border-t-0 sm:border-l",
        )}
      >
        <div className="min-w-0">
          <p className="text-[11px] font-semibold tracking-[0.12em] text-muted-foreground uppercase">
            {card.lastDeployed}
          </p>
          <p className="truncate text-xs text-muted-foreground">
            <RelativeTime iso={app.lastDeployedAt} />
            {" · "}
            {app.lastDeployedBy}
          </p>
        </div>
        <Button variant="outline" size="sm" className="shrink-0" asChild>
          <Link href={`/my-apps/${encodeURIComponent(app.id)}`}>
            {card.details}
          </Link>
        </Button>
      </div>
    </Card>
  );
}
