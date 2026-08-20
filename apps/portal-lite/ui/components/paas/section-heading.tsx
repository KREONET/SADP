import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

export interface SectionHeadingProps {
  title: ReactNode;
  /** 우측 액션(View All 링크, Refresh 버튼 등) */
  action?: ReactNode;
  /**
   * lg - 페이지 섹션 제목(딥그린 H2). 예: Quick Access / My Applications
   * sm - 카드 내부 마이크로 제목(대문자·자간). 예: MY QUOTA USAGE
   */
  size?: "lg" | "sm";
  /** 제목 아래 구분선 */
  divider?: boolean;
  className?: string;
}

/** 화면 2·7 이 공유하는 섹션 제목 줄. */
export function SectionHeading({
  title,
  action,
  size = "lg",
  divider = false,
  className,
}: SectionHeadingProps) {
  return (
    <div
      className={cn(
        "flex items-center justify-between gap-3",
        divider && "border-b border-border pb-3",
        className,
      )}
    >
      <h2
        className={cn(
          size === "lg"
            ? "text-xl font-bold text-brand-900"
            : "text-xs font-semibold tracking-[0.14em] text-foreground uppercase",
        )}
      >
        {title}
      </h2>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  );
}
