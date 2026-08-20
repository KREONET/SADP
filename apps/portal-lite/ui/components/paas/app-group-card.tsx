"use client";

import Link from "next/link";

import { StatusPill } from "@/components/paas/status-pill";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { useI18n } from "@/lib/i18n/context";
import type { AppGroupListItem } from "@/lib/application-list";
import { cn } from "@/lib/utils";
import type { Application } from "@/types/domain";

const TONE_BY_STATUS = {
  RUNNING: "ok",
  PENDING: "warn",
  FAILED: "error",
  STOPPED: "idle",
} as const;

/** AppGroup의 활성 서비스를 누락 없이 한 카드 안에 표시한다. */
export function AppGroupCard({
  group,
  view = "grid",
}: {
  group: AppGroupListItem;
  view?: "grid" | "list";
}) {
  const { dict } = useI18n();
  const card = dict.myApps.card;
  const projects = [...new Set(group.applications.map((app) => app.project))];

  return (
    <Card
      className={cn(
        "gap-0 overflow-hidden py-0",
        view === "grid" && "md:col-span-2",
      )}
      data-testid="app-group-card"
    >
      <div className="flex flex-col gap-2 border-b border-border px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <p className="text-xs font-semibold tracking-[0.12em] text-muted-foreground uppercase">
            {card.appGroup} · {projects.join(", ")}
          </p>
          <p className="truncate text-lg font-bold text-brand-900">
            {group.name}
          </p>
        </div>
        <p className="shrink-0 text-sm text-muted-foreground">
          {card.serviceCount.replace(
            "{count}",
            String(group.applications.length),
          )}
        </p>
      </div>

      <div className="divide-y divide-border">
        {group.applications.map((application) => (
          <AppGroupServiceRow key={application.id} application={application} />
        ))}
      </div>
    </Card>
  );
}

function AppGroupServiceRow({ application }: { application: Application }) {
  const { dict } = useI18n();
  const card = dict.myApps.card;
  const address = application.route ?? application.internalAddress;
  const addressLabel = application.route ? card.route : card.internalAddress;

  return (
    <div className="grid gap-3 px-5 py-4 sm:grid-cols-[minmax(0,1fr)_minmax(0,2fr)_auto] sm:items-center">
      <div className="min-w-0">
        <p className="truncate font-semibold text-foreground">
          {application.name}
        </p>
        <p className="truncate font-mono text-xs text-muted-foreground">
          {application.zone}
        </p>
      </div>

      <div className="min-w-0">
        <p className="text-xs font-semibold text-muted-foreground">
          {addressLabel}
        </p>
        <p className="truncate font-mono text-sm text-foreground">
          {address ?? "-"}
        </p>
      </div>

      <div className="flex items-center justify-between gap-3 sm:justify-end">
        <StatusPill tone={TONE_BY_STATUS[application.status]} dot>
          {application.status}
        </StatusPill>
        <Button variant="outline" size="sm" asChild>
          <Link href={`/my-apps/${encodeURIComponent(application.id)}`}>
            {card.details}
          </Link>
        </Button>
      </div>
    </div>
  );
}
