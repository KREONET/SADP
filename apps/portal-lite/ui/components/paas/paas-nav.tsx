"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { useI18n } from "@/lib/i18n/context";
import { NAV_ITEMS } from "@/lib/site-config";
import { cn } from "@/lib/utils";

function isActive(pathname: string, match: string) {
  if (match === "/") return pathname === "/";
  return pathname === match || pathname.startsWith(`${match}/`);
}

export function PaasNav({ className }: { className?: string }) {
  const pathname = usePathname() ?? "/";
  const { dict } = useI18n();

  return (
    <nav className={cn("flex items-center gap-1", className)}>
      {NAV_ITEMS.map((item) => {
        const active = isActive(pathname, item.match);
        return (
          <Link
            key={item.key}
            href={item.href}
            aria-current={active ? "page" : undefined}
            className={cn(
              "relative flex h-16 items-center px-3 text-sm font-medium transition-colors",
              "after:absolute after:inset-x-3 after:bottom-0 after:h-[3px] after:rounded-full after:content-['']",
              active
                ? "text-nav-active after:bg-nav-active"
                : "text-white/75 hover:text-white after:bg-transparent",
            )}
          >
            {dict.common.nav[item.key]}
          </Link>
        );
      })}
    </nav>
  );
}
