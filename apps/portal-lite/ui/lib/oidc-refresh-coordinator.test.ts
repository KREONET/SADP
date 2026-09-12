import { afterEach, describe, expect, it, vi } from "vitest";

import {
  OIDC_REFRESH_RESULT_CACHE_MAX,
  OIDC_REFRESH_IN_FLIGHT_MAX,
  oidcRefreshInFlightSize,
  OIDC_REFRESH_RESULT_TTL_MS,
  oidcRefreshCoordinatorSize,
  refreshOIDCAccessTokenOnce,
  resetOIDCRefreshCoordinator,
} from "./oidc-refresh-coordinator";

const BASE_OPTIONS = {
  tokenEndpoint: "https://idp.example.test/oauth/token",
  clientId: "portal-beta",
  clientSecret: "server-only-secret",
};

function tokenResponse(accessToken: string, refreshToken: string) {
  return new Response(
    JSON.stringify({
      access_token: accessToken,
      refresh_token: refreshToken,
      id_token: "id-token",
      expires_in: 120,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

afterEach(() => {
  resetOIDCRefreshCoordinator();
});

describe("refreshOIDCAccessTokenOnce", () => {
  it("merges two concurrent refreshes of the same token into one IdP call", async () => {
    let calls = 0;
    const gate: { release?: () => void } = {};
    const fetcher = vi.fn(() => {
      calls += 1;
      return new Promise<Response>((resolve) => {
        // 두 번째 요청이 진행 중 map에 합류한 뒤에야 IdP가 답하는 창을 만든다.
        gate.release = () => resolve(tokenResponse("access-1", "rotated-1"));
      });
    });

    const first = refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 },
    );
    const second = refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 },
    );
    expect(calls).toBe(1);

    gate.release?.();
    const [a, b] = await Promise.all([first, second]);

    expect(calls).toBe(1);
    expect(a.accessToken).toBe("access-1");
    expect(b.accessToken).toBe("access-1");
    expect(a.refreshToken).toBe("rotated-1");
    expect(b.refreshToken).toBe("rotated-1");
  });

  it("serves a late request carrying the consumed token from the TTL cache", async () => {
    let calls = 0;
    const fetcher = vi.fn(async () => {
      calls += 1;
      return tokenResponse("access-1", "rotated-1");
    });

    await refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 },
    );
    const late = await refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 + OIDC_REFRESH_RESULT_TTL_MS - 1 },
    );

    // 이미 소모된 옛 토큰으로 IdP를 다시 부르지 않는다. 새 토큰을 그대로 준다.
    expect(calls).toBe(1);
    expect(late.accessToken).toBe("access-1");
    expect(late.refreshToken).toBe("rotated-1");
  });

  it("refreshes again once the rotation result TTL has expired", async () => {
    let calls = 0;
    const fetcher = vi.fn(async () => {
      calls += 1;
      return tokenResponse(`access-${calls}`, "rotated");
    });

    await refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 },
    );
    const again = await refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 + OIDC_REFRESH_RESULT_TTL_MS },
    );

    expect(calls).toBe(2);
    expect(again.accessToken).toBe("access-2");
  });

  it("does not merge different refresh tokens (no session mixing)", async () => {
    let calls = 0;
    const fetcher = vi.fn(async (_url: RequestInfo | URL, init?: RequestInit) => {
      calls += 1;
      const sentRefresh = (init?.body as URLSearchParams).get("refresh_token") ?? "";
      return tokenResponse(`access-${sentRefresh}`, `rotated-${sentRefresh}`);
    });

    const [alice, bob] = await Promise.all([
      refreshOIDCAccessTokenOnce(
        { refreshToken: "token-alice" },
        { ...BASE_OPTIONS, fetcher, now: 1_000 },
      ),
      refreshOIDCAccessTokenOnce(
        { refreshToken: "token-bob" },
        { ...BASE_OPTIONS, fetcher, now: 1_000 },
      ),
    ]);

    expect(calls).toBe(2);
    expect(alice.refreshToken).toBe("rotated-token-alice");
    expect(bob.refreshToken).toBe("rotated-token-bob");
    expect(alice.accessToken).not.toBe(bob.accessToken);
  });

  it("does not cache failures, so the next request retries the IdP", async () => {
    let calls = 0;
    const flaky = { failing: true };
    const fetcher = vi.fn(async () => {
      calls += 1;
      if (flaky.failing) return new Response("denied", { status: 401 });
      return tokenResponse("access-ok", "rotated-ok");
    });

    await expect(
      refreshOIDCAccessTokenOnce(
        { refreshToken: "old-token" },
        { ...BASE_OPTIONS, fetcher, now: 1_000 },
      ),
    ).rejects.toThrow("OIDC token refresh failed (401)");
    flaky.failing = false;

    const retry = await refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 + 1 },
    );

    expect(calls).toBe(2);
    expect(retry.accessToken).toBe("access-ok");
  });

  it("propagates one failure to every concurrent waiter without extra IdP calls", async () => {
    let calls = 0;
    const fetcher = vi.fn(async () => {
      calls += 1;
      return new Response("denied", { status: 401 });
    });

    const first = refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 },
    );
    const second = refreshOIDCAccessTokenOnce(
      { refreshToken: "old-token" },
      { ...BASE_OPTIONS, fetcher, now: 1_000 },
    );

    await expect(first).rejects.toThrow("OIDC token refresh failed (401)");
    await expect(second).rejects.toThrow("OIDC token refresh failed (401)");
    expect(calls).toBe(1);
  });

  it("keeps the existing error when there is no refresh token", async () => {
    const fetcher = vi.fn();
    await expect(
      refreshOIDCAccessTokenOnce(
        { accessToken: "access-1" },
        { ...BASE_OPTIONS, fetcher, now: 1_000 },
      ),
    ).rejects.toThrow("OIDC refresh token is unavailable");
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("bounds the rotation-result cache to the configured size", async () => {
    const fetcher = vi.fn(async () => tokenResponse("access", "rotated"));
    const total = OIDC_REFRESH_RESULT_CACHE_MAX + 10;
    for (let i = 0; i < total; i++) {
      await refreshOIDCAccessTokenOnce(
        { refreshToken: `token-${i}` },
        { ...BASE_OPTIONS, fetcher, now: 1_000 },
      );
    }

    expect(fetcher).toHaveBeenCalledTimes(total);
    expect(oidcRefreshCoordinatorSize()).toBeLessThanOrEqual(
      OIDC_REFRESH_RESULT_CACHE_MAX,
    );
  });
});

it("starts the result TTL at completion using the injected clock", async () => {
  let now = 1_000;
  let release!: (response: Response) => void;
  const fetcher = vi.fn(() => new Promise<Response>((resolve) => { release = resolve; }));
  const options = { ...BASE_OPTIONS, fetcher, clock: () => now };
  const first = refreshOIDCAccessTokenOnce({ refreshToken: "old" }, options);
  now += 10_000;
  release(tokenResponse("access", "rotated"));
  await first;
  now += OIDC_REFRESH_RESULT_TTL_MS - 1;
  expect((await refreshOIDCAccessTokenOnce({ refreshToken: "old" }, options)).refreshToken).toBe("rotated");
  expect(fetcher).toHaveBeenCalledTimes(1);
});

it("cleans expired results when a different token arrives", async () => {
  const fetcher = vi.fn(async () => tokenResponse("access", "rotated"));
  await refreshOIDCAccessTokenOnce({ refreshToken: "old" }, { ...BASE_OPTIONS, fetcher, now: 1_000 });
  await refreshOIDCAccessTokenOnce({ refreshToken: "other" }, { ...BASE_OPTIONS, fetcher, now: 1_000 + OIDC_REFRESH_RESULT_TTL_MS });
  expect(oidcRefreshCoordinatorSize()).toBe(1);
  expect(fetcher).toHaveBeenCalledTimes(2);
});

it("waits at capacity without evicting an active one-time refresh token", async () => {
  const releases: Array<(response: Response) => void> = [];
  const fetcher = vi.fn(() => new Promise<Response>((resolve) => { releases.push(resolve); }));
  const options = { ...BASE_OPTIONS, fetcher, now: 1_000 };
  const first = refreshOIDCAccessTokenOnce({ refreshToken: "old" }, options);
  const others = Array.from({ length: OIDC_REFRESH_IN_FLIGHT_MAX - 1 }, (_, i) =>
    refreshOIDCAccessTokenOnce({ refreshToken: `other-${i}` }, options));
  const waiting = refreshOIDCAccessTokenOnce({ refreshToken: "new" }, options);
  const waitingAgain = refreshOIDCAccessTokenOnce({ refreshToken: "new" }, options);
  const joined = refreshOIDCAccessTokenOnce({ refreshToken: "old" }, options);
  expect(oidcRefreshInFlightSize()).toBe(OIDC_REFRESH_IN_FLIGHT_MAX);
  expect(fetcher).toHaveBeenCalledTimes(OIDC_REFRESH_IN_FLIGHT_MAX);
  releases[0](tokenResponse("first", "first-rotated"));
  expect((await first).accessToken).toBe("first");
  expect((await joined).accessToken).toBe("first");
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(OIDC_REFRESH_IN_FLIGHT_MAX + 1));
  expect(oidcRefreshInFlightSize()).toBe(OIDC_REFRESH_IN_FLIGHT_MAX);
  releases.slice(1).forEach((release) => release(tokenResponse("next", "rotated")));
  await Promise.all([...others, waiting, waitingAgain]);
  expect(oidcRefreshInFlightSize()).toBe(0);
});

it("releases capacity after a failed refresh without failing an unrelated waiter", async () => {
  const releases: Array<(response: Response) => void> = [];
  const fetcher = vi.fn(() => new Promise<Response>((resolve) => { releases.push(resolve); }));
  const options = { ...BASE_OPTIONS, fetcher, now: 1_000 };
  const active = Array.from({ length: OIDC_REFRESH_IN_FLIGHT_MAX }, (_, i) =>
    refreshOIDCAccessTokenOnce({ refreshToken: `active-${i}` }, options));
  const failure = expect(active[0]).rejects.toThrow("OIDC token refresh failed (401)");
  const waiting = refreshOIDCAccessTokenOnce({ refreshToken: "waiting" }, options);
  releases[0](new Response("denied", { status: 401 }));
  await failure;
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(OIDC_REFRESH_IN_FLIGHT_MAX + 1));
  releases.slice(1).forEach((release) => release(tokenResponse("access", "rotated")));
  expect((await waiting).accessToken).toBe("access");
  await Promise.all(active.slice(1));
  expect(oidcRefreshInFlightSize()).toBe(0);
});

it("preserves each caller's own JWT fields and isolates result arrays", async () => {
  const fetcher = vi.fn(async () => tokenResponse("access", "rotated"));
  const options = { ...BASE_OPTIONS, fetcher, now: 1_000 };
  const [a, b] = await Promise.all([
    refreshOIDCAccessTokenOnce({ refreshToken: "same", marker: "a" }, options),
    refreshOIDCAccessTokenOnce({ refreshToken: "same", marker: "b" }, options),
  ]);
  expect(a.marker).toBe("a");
  expect(b.marker).toBe("b");
  a.groups?.push("mutated");
  expect(b.groups).not.toContain("mutated");
  expect(fetcher).toHaveBeenCalledTimes(1);
});

it("shares pending refreshes when a server bundle evaluates the module again", async () => {
  let release!: (response: Response) => void;
  const fetcher = vi.fn(() => new Promise<Response>((resolve) => { release = resolve; }));
  const options = { ...BASE_OPTIONS, fetcher, now: 1_000 };
  const first = refreshOIDCAccessTokenOnce({ refreshToken: "same" }, options);
  vi.resetModules();
  const otherBundle = await import("./oidc-refresh-coordinator");
  const second = otherBundle.refreshOIDCAccessTokenOnce({ refreshToken: "same" }, options);
  expect(fetcher).toHaveBeenCalledTimes(1);
  release(tokenResponse("shared", "rotated"));
  const [a, b] = await Promise.all([first, second]);
  expect(a.accessToken).toBe(b.accessToken);
});
