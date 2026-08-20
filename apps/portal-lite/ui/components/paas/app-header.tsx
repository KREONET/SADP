"use client";

import Link from "next/link";
import { Search, UserRound } from "lucide-react";

import { LocaleToggle } from "@/components/paas/locale-toggle";
import { PaasNav } from "@/components/paas/paas-nav";
import { useI18n } from "@/lib/i18n/context";
import { SITE } from "@/lib/site-config";

/**
 * 전 화면 공통 상단 내비게이션.
 * 활성 링크 판정과 로케일 전환에 클라이언트 훅이 필요해 전체를 클라이언트로 둔다.
 */
export function AppHeader() {
  const { dict } = useI18n();

  return (
    <header className="w-full bg-brand-900 text-white">
      <div className="mx-auto flex h-16 w-full max-w-[1200px] items-center gap-6 px-6">
        <Link
          href="/"
          className="text-lg font-bold tracking-tight whitespace-nowrap"
        >
          {SITE.name}
        </Link>

        <PaasNav />

        <div className="ml-auto flex items-center gap-2">
          <LocaleToggle />

          <div className="relative hidden md:block">
            <Search
              className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-white/50"
              aria-hidden
            />
            <input
              type="search"
              placeholder={dict.common.header.searchPlaceholder}
              aria-label={dict.common.header.searchLabel}
              className="h-9 w-56 rounded-md border border-white/15 bg-white/10 pr-3 pl-9 text-sm text-white placeholder:text-white/55 focus-visible:border-nav-active focus-visible:ring-[3px] focus-visible:ring-nav-active/30 focus-visible:outline-none"
            />
          </div>

          {/*
            /account는 별도 레거시 전역 CSS를 로드한다. Next.js는 soft navigation 뒤
            전역 stylesheet를 제거하지 않으므로 이 경계만 hard navigation으로 넘겨
            account에서 돌아왔을 때 레거시 색상/폰트 규칙이 남지 않게 한다.
          */}
          <a
            href="/account"
            aria-label={dict.common.header.account}
            className="flex size-9 items-center justify-center rounded-full bg-white/10 text-white/90 transition-colors hover:bg-white/20"
          >
            <UserRound className="size-[18px]" />
          </a>
        </div>
      </div>
    </header>
  );
}
