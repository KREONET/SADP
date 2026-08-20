import { cva, type VariantProps } from "class-variance-authority";

import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import type { StatusTone } from "@/types/domain";

const statusPillVariants = cva("gap-1.5 border-transparent font-medium", {
  variants: {
    tone: {
      ok: "bg-status-ok-soft text-status-ok-strong",
      warn: "bg-status-warn-soft text-status-warn-strong",
      error: "bg-status-error-soft text-status-error-strong",
      idle: "bg-status-idle-soft text-muted-foreground",
    },
    size: {
      sm: "px-2 py-0.5 text-[11px]",
      md: "px-2.5 py-1 text-xs",
    },
  },
  defaultVariants: { tone: "idle", size: "sm" },
});

const dotVariants = cva("size-1.5 rounded-full", {
  variants: {
    tone: {
      ok: "bg-status-ok",
      warn: "bg-status-warn",
      error: "bg-status-error",
      idle: "bg-status-idle",
    },
  },
  defaultVariants: { tone: "idle" },
});

export interface StatusPillProps
  extends React.ComponentProps<"span">,
    VariantProps<typeof statusPillVariants> {
  tone?: StatusTone;
  /** 라벨 앞 ● 표시 */
  dot?: boolean;
}

export function StatusPill({
  tone = "idle",
  size,
  dot = false,
  className,
  children,
  ...props
}: StatusPillProps) {
  return (
    <Badge
      className={cn(statusPillVariants({ tone, size }), className)}
      {...props}
    >
      {dot ? <span className={cn(dotVariants({ tone }))} aria-hidden /> : null}
      {children}
    </Badge>
  );
}

export { statusPillVariants };
