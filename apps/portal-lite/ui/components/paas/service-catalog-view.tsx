"use client";

import * as React from "react";

import { EmptyState } from "@/components/paas/empty-state";
import { ServiceCard } from "@/components/paas/service-card";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { useI18n } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";
import type {
  ServiceCatalogItem,
  ServiceStatus,
  ServiceVisibility,
} from "@/types/domain";

interface VisibilityOption {
  key: ServiceVisibility;
  label: string;
  /** 권한이 없어 조작할 수 없는 필터. 회색 + disabled. */
  disabled?: boolean;
}

const VISIBILITY_OPTIONS: VisibilityOption[] = [
  { key: "public", label: "Public" },
  { key: "sso", label: "SSO" },
  { key: "admin", label: "Admin Only", disabled: true },
];

const STATUS_OPTIONS: { key: ServiceStatus; label: string; dot: string }[] = [
  { key: "Available", label: "Available", dot: "bg-status-ok" },
  { key: "Beta", label: "Beta", dot: "bg-status-warn" },
  { key: "Degraded", label: "Degraded", dot: "bg-status-error" },
];

/** 스크린샷 초기값: Public·SSO on / Admin Only off, Available·Beta on / Degraded off. */
const INITIAL_VISIBILITY: ServiceVisibility[] = ["public", "sso"];
const INITIAL_STATUS: ServiceStatus[] = ["Available", "Beta"];

/** disabled 필터는 조작이 불가하므로 필터 조건에서 제외한다(해당 카드는 항상 노출). */
const LOCKED_VISIBILITY = new Set(
  VISIBILITY_OPTIONS.filter((o) => o.disabled).map((o) => o.key),
);

function toggle<T>(list: T[], value: T): T[] {
  return list.includes(value)
    ? list.filter((v) => v !== value)
    : [...list, value];
}

export interface ServiceCatalogViewProps {
  services: ServiceCatalogItem[];
}

export function ServiceCatalogView({ services }: ServiceCatalogViewProps) {
  const { dict } = useI18n();
  const t = dict.services;
  const [visibility, setVisibility] =
    React.useState<ServiceVisibility[]>(INITIAL_VISIBILITY);
  const [status, setStatus] = React.useState<ServiceStatus[]>(INITIAL_STATUS);

  const filtered = React.useMemo(
    () =>
      services.filter(
        (s) =>
          (LOCKED_VISIBILITY.has(s.visibility) ||
            visibility.includes(s.visibility)) &&
          status.includes(s.status),
      ),
    [services, visibility, status],
  );

  return (
    <div className="flex flex-col gap-8 lg:flex-row lg:gap-10">
      {/* 좌측 필터 패널 (280px 고정) */}
      <aside className="w-full shrink-0 lg:w-[280px]">
        <fieldset className="space-y-3">
          <legend className="text-xs font-semibold tracking-[0.12em] text-muted-foreground uppercase">
            Visibility
          </legend>
          {VISIBILITY_OPTIONS.map((option) => (
            <div key={option.key} className="flex items-center gap-2.5">
              <Checkbox
                id={`vis-${option.key}`}
                checked={visibility.includes(option.key)}
                disabled={option.disabled}
                onCheckedChange={() =>
                  setVisibility((prev) => toggle(prev, option.key))
                }
              />
              <Label
                htmlFor={`vis-${option.key}`}
                className={cn(
                  "text-sm font-medium",
                  option.disabled
                    ? "text-muted-foreground"
                    : "text-brand-900",
                )}
              >
                {option.label}
              </Label>
            </div>
          ))}
        </fieldset>

        <fieldset className="mt-8 space-y-3">
          <legend className="text-xs font-semibold tracking-[0.12em] text-muted-foreground uppercase">
            Status
          </legend>
          {STATUS_OPTIONS.map((option) => (
            <div key={option.key} className="flex items-center gap-2.5">
              <Checkbox
                id={`st-${option.key}`}
                checked={status.includes(option.key)}
                onCheckedChange={() =>
                  setStatus((prev) => toggle(prev, option.key))
                }
              />
              <Label
                htmlFor={`st-${option.key}`}
                className="flex items-center gap-2 text-sm font-medium text-brand-900"
              >
                <span
                  className={cn("size-1.5 rounded-full", option.dot)}
                  aria-hidden
                />
                {option.label}
              </Label>
            </div>
          ))}
        </fieldset>
      </aside>

      {/* 카드 그리드 (3열) */}
      <div className="min-w-0 flex-1">
        {filtered.length > 0 ? (
          <div className="grid gap-6 sm:grid-cols-2 xl:grid-cols-3">
            {filtered.map((item) => (
              <ServiceCard key={item.id} item={item} />
            ))}
          </div>
        ) : (
          <EmptyState
            title={t.emptyTitle}
            description={t.emptyDescription}
          />
        )}
      </div>
    </div>
  );
}
