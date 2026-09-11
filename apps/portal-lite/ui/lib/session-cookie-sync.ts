type SessionClock = { accessTokenExpiresAt?: number; error?: string; user?: unknown };

/** RSC는 쿠키를 쓸 수 없으므로 브라우저가 Auth.js의 Set-Cookie 응답을 직접 받아야 한다. */
export function startSessionCookieSync({
  fetcher = fetch,
  now = Date.now,
  schedule = (callback: () => void, delay: number) => setTimeout(callback, delay),
  cancel = (timer: ReturnType<typeof setTimeout>) => clearTimeout(timer),
} = {}) {
  let stopped = false;
  let pending: Promise<void> | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;

  function refresh(): Promise<void> {
    if (stopped) return Promise.resolve();
    if (pending) return pending;
    if (timer !== undefined) cancel(timer);
    pending = fetcher("/api/auth/session", { credentials: "same-origin", cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) return;
        const session = await response.json() as SessionClock | null;
        if (stopped || !session?.user || session.error || !session.accessTokenExpiresAt) return;
        // 만료 30초 전의 서버 갱신 경계에 맞춘다. 오래된/잘못된 응답으로 busy loop를 만들지 않는다.
        const delay = Math.max(1_000, session.accessTokenExpiresAt - now() - 30_000);
        timer = schedule(() => { void refresh(); }, delay);
      })
      // 네트워크 실패를 로그인 실패로 고정하지 않는다. 다음 focus/탐색에서 다시 확인한다.
      .catch(() => {})
      .finally(() => { pending = undefined; });
    return pending;
  }

  return {
    refresh,
    stop() {
      stopped = true;
      if (timer !== undefined) cancel(timer);
    },
  };
}
