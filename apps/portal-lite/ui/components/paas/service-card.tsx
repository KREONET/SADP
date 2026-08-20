"use client";

import {
  BadgeCheck,
  ExternalLink,
  FlaskConical,
  Lock,
  LogIn,
  Settings2,
} from "lucide-react";

import { StatusPill } from "@/components/paas/status-pill";
import { Button } from "@/components/ui/button";
import { useI18n } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";
import type {
  ServiceCatalogItem,
  ServiceStatus,
  ServiceVisibility,
  StatusTone,
} from "@/types/domain";

/** 카드 상단 3px 컬러 바 + 상태 배지 톤. */
const STATUS_TONE: Record<ServiceStatus, StatusTone> = {
  Available: "ok",
  Beta: "warn",
  Degraded: "error",
};

const RAIL: Record<ServiceStatus, string> = {
  Available: "bg-status-ok-strong",
  Beta: "bg-status-warn",
  Degraded: "bg-status-error",
};

/** 좌상단 대문자 라벨. */
const VISIBILITY_LABEL: Record<ServiceVisibility, string> = {
  public: "PUBLIC",
  sso: "SSO",
  admin: "ADMIN",
};

/** 서비스명 옆 아이콘: 검증됨 / beta / admin 전용. */
function NameIcon({ item }: { item: ServiceCatalogItem }) {
  const { dict } = useI18n();
  const t = dict.services;

  if (item.visibility === "admin") {
    return (
      <Lock className="size-4 text-muted-foreground" aria-label={t.iconAdminOnly} />
    );
  }
  if (item.status === "Beta") {
    return (
      <FlaskConical
        className="size-4 text-status-warn-strong"
        aria-label={t.iconBeta}
      />
    );
  }
  return (
    <BadgeCheck className="size-4 text-status-ok-strong" aria-label={t.iconVerified} />
  );
}

/** 메타 박스 한 칸. 값은 모노스페이스. */
function MetaCell({ label, value }: { label: string; value: string }) {
  return (
    <div className="space-y-1">
      <p className="font-mono text-[10px] tracking-[0.12em] text-muted-foreground uppercase">
        {label}
      </p>
      <p className="font-mono text-xs leading-relaxed text-foreground">{value}</p>
    </div>
  );
}

export interface ServiceCardProps {
  item: ServiceCatalogItem;
  className?: string;
}

/**
 * 화면 7 서비스 카드.
 * 하단 primary 버튼은 visibility·status·권한 조합으로 결정된다.
 *  - public/Available          → Visit ↗ (새 탭)
 *  - sso/Available + 관리권한  → Manage ⚙
 *  - sso/*                     → Access →
 *  - 접근 권한 없음(admin)      → Admin Only 🔒 (disabled, Details 없이 단독 full-width)
 */
export function ServiceCard({ item, className }: ServiceCardProps) {
  const { dict } = useI18n();
  const t = dict.services;
  const tone = STATUS_TONE[item.status];
  const locked = !item.accessible;

  return (
    <article
      className={cn(
        "flex flex-col overflow-hidden rounded-xl border border-border bg-card shadow-sm",
        className,
      )}
    >
      {/* 상태별 3px 컬러 바 */}
      <div className={cn("h-[3px] w-full", RAIL[item.status])} aria-hidden />

      <div className="flex flex-1 flex-col gap-4 p-5">
        <div className="flex items-start justify-between gap-2">
          <p className="text-xs font-semibold tracking-[0.12em] text-muted-foreground">
            {VISIBILITY_LABEL[item.visibility]}
          </p>
          <StatusPill tone={tone}>{item.status}</StatusPill>
        </div>

        <h2 className="-mt-2 flex items-center gap-1.5 text-lg font-bold tracking-tight text-brand-900">
          {item.name}
          <NameIcon item={item} />
        </h2>

        {/* 설명은 2줄로 truncate */}
        <p className="line-clamp-2 text-sm leading-relaxed text-muted-foreground">
          {item.description}
        </p>

        <div className="mt-auto grid grid-cols-2 gap-4 rounded-lg bg-muted px-4 py-3">
          <MetaCell label={t.metaRoles} value={item.roles.join(", ")} />
          <MetaCell label={t.metaTeam} value={item.team} />
        </div>

        {locked ? (
          <Button
            variant="secondary"
            disabled
            className="w-full text-muted-foreground"
          >
            {t.actionAdminOnly}
            <Lock className="size-4" aria-hidden />
          </Button>
        ) : (
          <div className="grid grid-cols-2 gap-3">
            <Button variant="outline" asChild>
              <a href={`/services/${item.id}`}>{t.actionDetails}</a>
            </Button>
            <PrimaryAction item={item} />
          </div>
        )}
      </div>
    </article>
  );
}

function PrimaryAction({ item }: { item: ServiceCatalogItem }) {
  const { dict } = useI18n();
  const t = dict.services;

  if (item.visibility === "public") {
    return (
      <Button asChild>
        <a href={item.href} target="_blank" rel="noopener noreferrer">
          {t.actionVisit}
          <ExternalLink className="size-4" aria-hidden />
        </a>
      </Button>
    );
  }

  if (item.manageable && item.status === "Available") {
    return (
      <Button asChild>
        <a href={item.href} target="_blank" rel="noopener noreferrer">
          {t.actionManage}
          <Settings2 className="size-4" aria-hidden />
        </a>
      </Button>
    );
  }

  return (
    <Button asChild>
      <a href={item.href} target="_blank" rel="noopener noreferrer">
        {t.actionAccess}
        <LogIn className="size-4" aria-hidden />
      </a>
    </Button>
  );
}
