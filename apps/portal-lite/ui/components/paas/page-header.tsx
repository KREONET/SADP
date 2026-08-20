import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

export interface PageHeaderProps {
  /** 제목 위 작은 대문자 라벨. 예: "WORKSPACE OVERVIEW" */
  eyebrow?: string;
  title: ReactNode;
  /** H1 아래 설명. 스크린샷 기준 2줄까지 들어간다. */
  description?: ReactNode;
  /** 우측 상단 액션 버튼 묶음 */
  actions?: ReactNode;
  className?: string;
}

/**
 * 화면 1 / 3 / 6 / 7 이 공유하는 페이지 헤더.
 * eyebrow -> H1 -> 설명 순서와 자간·크기를 한 곳에서 고정한다.
 */
export function PageHeader({
  eyebrow,
  title,
  description,
  actions,
  className,
}: PageHeaderProps) {
  return (
    <header
      className={cn(
        "flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between",
        className,
      )}
    >
      <div className="space-y-2">
        {eyebrow ? (
          <p className="text-xs font-semibold tracking-[0.18em] text-muted-foreground uppercase">
            {eyebrow}
          </p>
        ) : null}
        <h1 className="text-3xl font-bold tracking-tight text-brand-900">
          {title}
        </h1>
        {description ? (
          <div className="max-w-2xl text-sm leading-relaxed text-muted-foreground">
            {description}
          </div>
        ) : null}
      </div>

      {actions ? (
        <div className="flex shrink-0 flex-wrap items-center gap-2">
          {actions}
        </div>
      ) : null}
    </header>
  );
}
