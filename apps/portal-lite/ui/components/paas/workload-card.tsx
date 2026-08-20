"use client";

import { PlusCircle } from "lucide-react";
import Link from "next/link";

import { MonoKeyValueBox } from "@/components/paas/mono-kv-box";
import { StatusPill } from "@/components/paas/status-pill";
import { Card } from "@/components/ui/card";
import { useI18n } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";
import type { WorkloadSummary } from "@/types/domain";

/** 상태별 좌측 컬러 바 + 배지 톤/라벨. */
const statusStyle = {
  RUNNING: {
    rail: "border-l-status-ok",
    label: "Running",
    pill: "bg-status-ok-soft text-status-ok-strong",
  },
  BETA: {
    rail: "border-l-nav-active",
    label: "Beta",
    pill: "bg-nav-active text-status-warn-strong",
  },
  STOPPED: {
    rail: "border-l-border",
    label: "Stopped",
    pill: "bg-status-idle-soft text-muted-foreground",
  },
  // PR 이 만들어졌을 뿐 아직 클러스터에 뜨지 않은 상태.
  PENDING: {
    rail: "border-l-status-warn",
    label: "Pending",
    pill: "bg-status-warn-soft text-status-warn-strong",
  },
  FAILED: {
    rail: "border-l-status-error",
    label: "Failed",
    pill: "bg-status-error-soft text-status-error-strong",
  },
} as const;

/** 화면 2 My Applications 카드. 타입 라벨 + 상태 배지 + 이름 + 모노 박스. */
export function WorkloadCard({ workload }: { workload: WorkloadSummary }) {
  const { dict } = useI18n();
  const style = statusStyle[workload.status];
  const rows = [
    ...(workload.namespace
      ? [{ label: "namespace", value: workload.namespace }]
      : []),
    ...(workload.internalAddress
      ? [
          {
            label: dict.dashboard.internalAddress,
            value: workload.internalAddress,
          },
        ]
      : []),
    ...(workload.url
      ? [{ label: "url", value: workload.url }]
      : []),
    { label: "replicas", value: workload.replicas ?? "-" },
  ];

  return (
    <Card
      className={cn(
        "gap-3 border-l-4 p-5 transition-shadow hover:shadow-sm",
        style.rail,
      )}
    >
      <div className="flex items-start justify-between gap-3">
        <p className="text-xs font-semibold tracking-[0.12em] text-muted-foreground uppercase">
          {workload.kind}
        </p>
        <StatusPill className={style.pill}>{style.label}</StatusPill>
      </div>
      <p className="text-lg font-bold text-brand-900">{workload.name}</p>
      <MonoKeyValueBox rows={rows} variant="inline" tone="muted" />
    </Card>
  );
}

/** 마지막 칸의 점선 플레이스홀더 카드. */
export function DeployNewAppCard({ href }: { href: string }) {
  const { dict } = useI18n();

  return (
    <Link
      href={href}
      className="flex min-h-35 flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-border bg-transparent text-muted-foreground transition-colors hover:border-brand-accent hover:text-brand-accent"
    >
      <PlusCircle className="size-8" strokeWidth={1.5} aria-hidden />
      <span className="text-sm font-medium">{dict.dashboard.deployNewApp}</span>
    </Link>
  );
}
