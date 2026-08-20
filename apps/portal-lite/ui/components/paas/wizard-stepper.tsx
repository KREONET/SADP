import { cn } from "@/lib/utils";
import type { WizardStep } from "@/types/domain";

export interface WizardStepperProps {
  steps: WizardStep[];
  /** 1-based 현재 스텝 */
  current: number;
  className?: string;
}

/**
 * 화면 4·5 좌측 세로 스테퍼.
 * - 현재 스텝: 딥그린 filled 원 + 볼드 텍스트
 * - 그 외: 연블루 원 + 회색 텍스트
 * - 스텝 사이는 세로 커넥터로 연결한다.
 */
export function WizardStepper({ steps, current, className }: WizardStepperProps) {
  return (
    <ol className={cn("relative space-y-0", className)}>
      {steps.map((item, index) => {
        const isCurrent = item.step === current;
        const isLast = index === steps.length - 1;

        return (
          <li key={item.step} className="relative flex gap-3 pb-6 last:pb-0">
            {!isLast ? (
              <span
                aria-hidden
                className="absolute top-7 bottom-0 left-[13px] w-px bg-border"
              />
            ) : null}

            <span
              className={cn(
                "relative z-10 flex size-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
                isCurrent
                  ? "bg-brand-900 text-white"
                  : "bg-secondary text-muted-foreground",
              )}
            >
              {item.step}
            </span>

            <div className="min-w-0 pt-0.5">
              <p
                className={cn(
                  "text-sm leading-tight",
                  isCurrent
                    ? "font-semibold text-brand-900"
                    : "font-medium text-foreground",
                )}
              >
                {item.title}
              </p>
              <p className="mt-1 text-xs text-muted-foreground">{item.subtitle}</p>
            </div>
          </li>
        );
      })}
    </ol>
  );
}
