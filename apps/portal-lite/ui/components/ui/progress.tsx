"use client"

import * as React from "react"
import { Progress as ProgressPrimitive } from "radix-ui"

import { cn } from "@/lib/utils"

function Progress({
  className,
  value,
  ...props
}: React.ComponentProps<typeof ProgressPrimitive.Root>) {
  // 플랫폼 CSP 가 style 속성을 차단하므로 inline transform 대신 정적 width 클래스를 쓴다.
  // 0~100% 클래스는 app/paas.css 의 `@source inline("w-[{0..100}%]")` 로 미리 생성된다.
  const percent = Math.round(Math.min(100, Math.max(0, value ?? 0)))

  return (
    <ProgressPrimitive.Root
      data-slot="progress"
      className={cn(
        "relative h-2 w-full overflow-hidden rounded-full bg-primary/20",
        className
      )}
      {...props}
    >
      <ProgressPrimitive.Indicator
        data-slot="progress-indicator"
        className={cn(
          "h-full flex-1 rounded-full bg-primary transition-all",
          `w-[${percent}%]`
        )}
      />
    </ProgressPrimitive.Root>
  )
}

export { Progress }
