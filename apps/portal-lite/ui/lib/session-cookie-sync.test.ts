import { afterEach, expect, it, vi } from "vitest";
import { startSessionCookieSync } from "./session-cookie-sync";

afterEach(() => { vi.useRealTimers(); });

it("writes session cookies through Auth.js and schedules by token expiry", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(1_000);
  const fetcher = vi.fn(async () => Response.json({ user: { name: "fixture" }, accessTokenExpiresAt: Date.now() + 120_000 }));
  const sync = startSessionCookieSync({ fetcher });
  await Promise.all([sync.refresh(), sync.refresh()]);
  expect(fetcher).toHaveBeenCalledTimes(1);
  expect(fetcher).toHaveBeenCalledWith("/api/auth/session", { credentials: "same-origin", cache: "no-store" });
  await vi.advanceTimersByTimeAsync(89_999);
  expect(fetcher).toHaveBeenCalledTimes(1);
  await vi.advanceTimersByTimeAsync(1);
  expect(fetcher).toHaveBeenCalledTimes(2);
  sync.stop();
  await vi.advanceTimersByTimeAsync(120_000);
  expect(fetcher).toHaveBeenCalledTimes(2);
});

it.each([null, { user: {}, error: "RefreshTokenError" }])("does not poll an unusable session: %j", async (session) => {
  vi.useFakeTimers();
  const fetcher = vi.fn(async () => Response.json(session));
  const sync = startSessionCookieSync({ fetcher });
  await sync.refresh();
  await vi.advanceTimersByTimeAsync(120_000);
  expect(fetcher).toHaveBeenCalledTimes(1);
  sync.stop();
});

it("retries a network failure on the next trigger", async () => {
  const fetcher = vi.fn().mockRejectedValueOnce(new Error("offline")).mockResolvedValueOnce(Response.json(null));
  const sync = startSessionCookieSync({ fetcher });
  await sync.refresh();
  await sync.refresh();
  expect(fetcher).toHaveBeenCalledTimes(2);
  sync.stop();
});
