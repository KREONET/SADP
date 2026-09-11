import type { OIDCTokenState, RefreshOptions } from "./oidc-token";
import { refreshOIDCAccessToken } from "./oidc-token";

export const OIDC_REFRESH_RESULT_TTL_MS = 60_000;
export const OIDC_REFRESH_RESULT_CACHE_MAX = 512;
export const OIDC_REFRESH_IN_FLIGHT_MAX = 512;

type CoordinatedOptions = RefreshOptions & { clock?: () => number };
type RefreshResult = { value: OIDCTokenState; expiresAt: number };
type CoordinatorState = {
  inFlight: Map<string, Promise<OIDCTokenState>>;
  results: Map<string, RefreshResult>;
};

// 서버 번들이 모듈을 각각 평가해도 같은 Node 실행 컨텍스트에서는 한 저장소를 사용한다.
// Proxy/별도 isolate/replica와의 메모리 공유는 보장하지 않는다. Proxy는 이 모듈을 읽지 않는다.
const processState = globalThis as typeof globalThis & {
  __sadpOIDCRefreshCoordinator?: CoordinatorState;
};
const state: CoordinatorState = (processState.__sadpOIDCRefreshCoordinator ??= {
  inFlight: new Map(),
  results: new Map(),
});

function bound<T>(entries: Map<string, T>, limit: number): void {
  while (entries.size > limit) {
    const oldest = entries.keys().next().value;
    if (oldest === undefined) break;
    entries.delete(oldest);
  }
}

function cleanResults(now: number): void {
  for (const [key, result] of state.results) {
    if (result.expiresAt <= now) state.results.delete(key);
  }
}

function withResult<T extends OIDCTokenState>(token: T, value: OIDCTokenState): T & OIDCTokenState {
  // 첫 호출자의 JWT 부가 필드나 가변 배열을 다른 요청에 넘기지 않는다.
  return {
    ...token,
    ...value,
    groups: value.groups?.slice(),
    realmRoles: value.realmRoles?.slice(),
    clientRoles: value.clientRoles?.slice(),
  };
}

/** 구 토큰의 정확 일치로 진행 중 갱신과 짧은 회전 결과를 공유한다. 실패는 저장하지 않는다. */
export function refreshOIDCAccessTokenOnce<T extends OIDCTokenState>(
  token: T,
  options: CoordinatedOptions,
): Promise<T & OIDCTokenState> {
  const key = token.refreshToken;
  if (!key) return refreshOIDCAccessToken(token, options);
  const clock = options.clock ?? (() => options.now ?? Date.now());
  const now = clock();
  cleanResults(now);

  const pending = state.inFlight.get(key);
  if (pending) return pending.then((value) => withResult(token, value));
  const cached = state.results.get(key);
  if (cached) return Promise.resolve(withResult(token, cached.value));

  // 원문 키의 정확 일치로 비교해 축약한 해시의 충돌로 세션이 섞이지 않게 한다.
  // 호출자 JWT 전체를 저장하지 않고 갱신에 필요한 토큰 필드만 순수 함수에 전달한다.
  const promise = refreshOIDCAccessToken({ refreshToken: key, idToken: token.idToken }, {
    ...options,
    now,
  }).then((value) => {
    // 쫓겨난 이전 호출이 나중에 완료돼 새 갱신의 결과를 덮지 않게 한다.
    if (state.inFlight.get(key) === promise) {
      const finishedAt = clock();
      cleanResults(finishedAt);
      state.results.set(key, {
        value,
        expiresAt: Math.min(finishedAt + OIDC_REFRESH_RESULT_TTL_MS,
          (value.accessTokenExpiresAt ?? Infinity) - 30_000),
      });
      bound(state.results, OIDC_REFRESH_RESULT_CACHE_MAX);
    }
    return value;
  }).finally(() => {
    if (state.inFlight.get(key) === promise) state.inFlight.delete(key);
  });

  // await 전에 등록해야 같은 tick의 다음 호출도 이 Promise를 기다린다.
  state.inFlight.set(key, promise);
  bound(state.inFlight, OIDC_REFRESH_IN_FLIGHT_MAX);
  return promise.then((value) => withResult(token, value));
}

/** 시험 사이에 토큰이나 진행 중 작업이 남지 않도록 비운다. */
export function resetOIDCRefreshCoordinator(): void {
  state.inFlight.clear();
  state.results.clear();
}

export function oidcRefreshCoordinatorSize(): number {
  return state.results.size;
}

export function oidcRefreshInFlightSize(): number {
  return state.inFlight.size;
}
