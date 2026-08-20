"use client";

import Link from "next/link";

import { useI18n } from "@/lib/i18n/context";
import type { Dictionary } from "@/lib/i18n/dictionary";
import { FOOTER_LINKS, SITE } from "@/lib/site-config";
import { cn } from "@/lib/utils";

/** 푸터 링크 문구는 사전에서만 온다. 화면에서 문자열을 넘기지 않는다. */
type FooterMessageKey = keyof Dictionary["common"]["footer"];

export interface AppFooterProps {
  /**
   * 외부 정책·지원 URL이 정해진 화면에서만 추가하는 링크.
   * 기본 링크가 없어도 빈 탐색 landmark를 만들지 않는다.
   */
  extraLinks?: { key: FooterMessageKey; href: string }[];
  /** 버전 옆에 표시할 환경·상태 보조 인디케이터 */
  note?: string;
  className?: string;
}

export function AppFooter({ extraLinks, note, className }: AppFooterProps) {
  const { dict } = useI18n();
  const links = [...FOOTER_LINKS, ...(extraLinks ?? [])];

  return (
    <footer className={cn("mt-auto w-full border-t border-border", className)}>
      <div className="mx-auto flex w-full max-w-[1200px] flex-col gap-3 px-6 py-5 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
        <p className="flex flex-wrap items-center gap-2">
          <span>
            © {SITE.copyrightYear} {SITE.name}.{" "}
            {dict.common.footer.rightsReserved}
          </span>
          <span className="font-mono text-xs text-muted-foreground/80">
            {SITE.version}
          </span>
          {note ? (
            <span className="flex items-center gap-1.5 font-mono text-xs">
              <span className="size-1.5 rounded-full bg-status-ok" aria-hidden />
              {note}
            </span>
          ) : null}
        </p>

        {links.length > 0 ? (
          <nav className="flex flex-wrap items-center gap-5">
            {links.map((link) => (
              <Link
                key={link.href}
                href={link.href}
                className="transition-colors hover:text-foreground"
              >
                {dict.common.footer[link.key]}
              </Link>
            ))}
          </nav>
        ) : null}
      </div>
    </footer>
  );
}
