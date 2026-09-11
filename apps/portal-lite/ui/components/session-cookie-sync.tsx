"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { startSessionCookieSync } from "@/lib/session-cookie-sync";

export function SessionCookieSync() {
  const pathname = usePathname();
  useEffect(() => {
    const sync = startSessionCookieSync();
    const refresh = () => { void sync.refresh(); };
    refresh();
    window.addEventListener("focus", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      sync.stop();
    };
  }, [pathname]);
  return null;
}
