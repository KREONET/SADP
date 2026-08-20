"use client";

import { useTransition } from "react";

import { setLocaleAction } from "@/lib/i18n/actions";
import { useI18n } from "@/lib/i18n/context";
import { LOCALES } from "@/lib/i18n/locale";
import { cn } from "@/lib/utils";

/**
 * 헤더의 한국어/English 세그먼트 토글.
 *
 * 쿠키를 굽는 일은 서버 액션이 하고, 액션이 끝나면 Next 가 현재 화면을 다시 렌더링한다.
 * 클라이언트에서 문구를 갈아끼우지 않으므로 서버가 그린 HTML 과 어긋날 일이 없다.
 */
export function LocaleToggle({ className }: { className?: string }) {
  const { locale, dict } = useI18n();
  const [pending, startTransition] = useTransition();

  return (
    <div
      role="group"
      aria-label={dict.common.locale.label}
      className={cn(
        "flex items-center gap-0.5 rounded-md border border-white/15 bg-white/10 p-0.5",
        pending && "opacity-70",
        className,
      )}
    >
      {LOCALES.map((item) => {
        const active = item === locale;
        return (
          <button
            key={item}
            type="button"
            // 라디오처럼 "어느 쪽이 켜져 있는지"를 스크린리더에 알린다.
            aria-pressed={active}
            disabled={pending || active}
            onClick={() => {
              startTransition(async () => {
                await setLocaleAction(item);
              });
            }}
            className={cn(
              "rounded-[5px] px-2 py-1 text-xs font-medium transition-colors",
              active
                ? "bg-white text-brand-900"
                : "text-white/75 hover:bg-white/10 hover:text-white",
              // active 는 disabled 지만 흐려 보이면 안 된다.
              "disabled:pointer-events-none",
              !active && "disabled:opacity-60",
            )}
          >
            {dict.common.locale[item]}
          </button>
        );
      })}
    </div>
  );
}
