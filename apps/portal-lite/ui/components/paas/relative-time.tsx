"use client";

import * as React from "react";

import { formatAbsolute, formatRelative } from "@/lib/format-date";
import { useI18n } from "@/lib/i18n/context";

/**
 * 서버는 절대시간(결정적)으로 그리고, 마운트 후 상대시간으로 교체한다.
 * 이렇게 해야 서버/클라이언트 시각차로 인한 hydration mismatch 가 나지 않는다.
 *
 * useSyncExternalStore 를 쓰면 "서버 스냅샷 / 클라이언트 스냅샷"이 언어 차원에서
 * 분리되므로 effect 안에서 setState 를 호출할 필요가 없다.
 */
const subscribeToMinuteTick = (onStoreChange: () => void) => {
  const timer = setInterval(onStoreChange, 60_000);
  return () => clearInterval(timer);
};

export function RelativeTime({
  iso,
  className,
}: {
  iso: string;
  className?: string;
}) {
  const { locale } = useI18n();

  const label = React.useSyncExternalStore(
    subscribeToMinuteTick,
    // 클라이언트: 매 렌더/틱마다 상대시간 재계산. 값이 같으면 문자열 비교로 걸러진다.
    () => formatRelative(iso, locale),
    // 서버 + hydration: 항상 동일한 절대시간.
    () => formatAbsolute(iso, locale),
  );

  return (
    <time
      dateTime={iso}
      className={className}
      title={formatAbsolute(iso, locale)}
    >
      {label}
    </time>
  );
}
