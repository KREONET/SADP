import { ArrowRight, Globe, KeyRound } from "lucide-react";
import Link from "next/link";

import { getI18n } from "@/lib/i18n/server";
import { cn } from "@/lib/utils";
import type { QuickAccessItem } from "@/types/domain";

const icons = { globe: Globe, key: KeyRound } as const;

/** 화면 2 좌측 Quick Access 목록. 좌측 아이콘 + 라벨 + 우측 화살표. */
export async function QuickAccessList({
  items,
  className,
}: {
  items: QuickAccessItem[];
  className?: string;
}) {
  const { dict } = await getI18n();

  // 신규 사용자는 접근 가능한 서비스가 하나도 없을 수 있다. 빈 <ul> 대신 사유를 알린다.
  if (items.length === 0) {
    return (
      <p className={cn("py-3.5 text-sm text-muted-foreground", className)}>
        {dict.dashboard.emptyQuickAccess}
      </p>
    );
  }

  return (
    <ul className={cn("space-y-3", className)}>
      {items.map((item) => {
        const Icon = icons[item.icon];
        return (
          <li key={item.id}>
            <Link
              href={item.href}
              className="group flex items-center gap-3 rounded-lg border border-border bg-card px-4 py-3.5 transition-colors hover:border-brand-accent hover:bg-secondary"
            >
              <Icon className="size-5 shrink-0 text-brand-900" aria-hidden />
              <span className="min-w-0 flex-1 truncate text-sm font-semibold text-foreground">
                {item.label}
              </span>
              <ArrowRight
                className="size-4 shrink-0 text-muted-foreground transition-transform group-hover:translate-x-0.5 group-hover:text-brand-accent"
                aria-hidden
              />
            </Link>
          </li>
        );
      })}
    </ul>
  );
}
