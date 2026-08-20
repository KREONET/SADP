import type { ReactNode } from "react";

import { Label } from "@/components/ui/label";
import { cn } from "@/lib/utils";

export interface FormFieldProps {
  id: string;
  label: ReactNode;
  /** 라벨 뒤 빨간 * */
  required?: boolean;
  /** 입력 아래 회색 도움말 */
  helper?: ReactNode;
  /** 값이 있으면 helper 대신 빨간 에러 문구를 보여준다. */
  error?: string | null;
  className?: string;
  children: ReactNode;
}

/**
 * 화면 4·5 위저드가 공유하는 Label + Input + helper/error 묶음.
 * 라벨-입력-보조문구의 간격을 한 곳에서 고정한다.
 */
export function FormField({
  id,
  label,
  required = false,
  helper,
  error,
  className,
  children,
}: FormFieldProps) {
  const describedBy = error ? `${id}-error` : helper ? `${id}-helper` : undefined;

  return (
    <div className={cn("space-y-2", className)} data-field={id}>
      <Label htmlFor={id} className="text-sm font-semibold text-foreground">
        {label}
        {required ? (
          <span className="text-destructive" aria-hidden>
            *
          </span>
        ) : null}
      </Label>

      <div data-described-by={describedBy}>{children}</div>

      {error ? (
        <p id={`${id}-error`} role="alert" className="text-xs text-destructive">
          {error}
        </p>
      ) : helper ? (
        <p id={`${id}-helper`} className="text-xs text-muted-foreground">
          {helper}
        </p>
      ) : null}
    </div>
  );
}

/** 위저드 카드 안에서 쓰는 아이콘 붙은 입력 래퍼. */
export function InputWithIcon({
  icon,
  children,
  className,
}: {
  icon: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("relative", className)}>
      <span className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-muted-foreground [&_svg]:size-4">
        {icon}
      </span>
      {children}
    </div>
  );
}
