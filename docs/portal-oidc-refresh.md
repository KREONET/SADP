# Portal OIDC 갱신 경합 점검과 수정

로그인 유지용 refresh token을 여러 요청이 동시에 사용해 갱신이 실패하는 문제를 점검한
**개발자용 기술 기록**입니다. 한 번 쓴 토큰이 교체되는 IdP에서는 같은 옛 토큰으로 갱신을
두 번 시도하면 두 번째 요청이 거부될 수 있습니다. coordinator는 이런 요청을 묶어 처리하는 코드입니다.

수정 범위는 [런타임과 Proxy](#4-런타임-경계와-proxy-수정), 검증 범위는
[시험 결과](#7-시험-결과)와 [남은 한계](#8-남은-한계)를 읽으세요.
로그인 장애 대응은 [외부 인증 안내](identity-provider.md)를 먼저 따릅니다.
아래 파일·줄 번호와 시험 결과는 점검 시점의 기록입니다.

2026-09-11 점검. 경로는 저장소 루트 기준이며 줄 번호는 수정 후 기준이다.
시작 시 워크트리에 있던 coordinator 초안을 검토·보완했다. 실제 IdP 설정이나 배포는 변경하지 않았다.

## 1. 회전 설정 확인 결과

**확인 필요.** SADP는 외부 IdP를 설치·구성하지 않는다(`AGENTS.md:14`).
저장소에서 `revokeRefreshToken`, `refreshTokenMaxReuse`와 회전 설정을 검색했지만
실제 Realm/Provider의 값을 확인할 자료나 관리자 세션은 없었다.
Keycloak이라면 Realm Settings → Tokens → Revoke Refresh Token과 재사용 허용값을 확인해야 한다.
이번 수정과 시험은 refresh token이 single-use인 것으로 가정한다.
실제 IdP가 Keycloak인지, 회전이 켜져 있는지는 확인했다고 주장하지 않는다.

## 2. 실패가 고정되는가

`apps/portal-lite/ui/auth.ts:69–85`에는 `token.error`를 보고 바로 반환하는 sticky 분기가 없다.
만료 검사를 통과하면 다시 갱신하고 성공 시 error를 지운다(83). 실패하면 RefreshTokenError를
기록(85)하고 session에 전달(97)한다. `lib/require-session.ts:40–44`는 이 세션을 거부한다.
따라서 이번 프로젝트의 증폭기는 **오류 토큰으로 무한히 재시도를 막는 jwt 분기**가 아니라,
갱신 실패를 현재 페이지/API의 인증 실패로 판정하는 게이트다. 여기에 새 sticky 분기를 넣지 않았다.
실제 Auth.js 핸들러 시험 `auth-refresh.test.ts`는 error가 있는 만료 JWT의 재시도 성공도 검증한다.

## 3. 갱신 진입점 전수 목록

아래 접두사는 모두 `apps/portal-lite/ui/`다. `auth()` 호출 경로를 기준으로 센다.
직접 auth 또는 공용 게이트를 호출하는 위치는 수정 전 21곳(Proxy 1, RSC 12, BFF 1,
서버 액션 7)이며, Auth.js GET/POST export 1곳을 별도로 센다. 함수 호출 횟수와 파일 수는 다르다.

| 종류 | 파일:줄 | 갱신으로 이어지는 경로 |
| --- | --- | --- |
| Proxy (제거) | 수정 전 `proxy.ts:51`, 수정 후 `proxy.ts:4` | `auth(securedProxy)`였으나 request.auth/req.auth 사용 없음 |
| PaaS layout | `app/(paas)/layout.tsx:29` | requirePaasRole → requirePaasSession → paasSession → auth |
| PaaS 홈 | `app/(paas)/page.tsx:38` | requirePaasRole |
| 앱 목록/상세 | `app/(paas)/my-apps/page.tsx:35`, `app/(paas)/my-apps/[id]/page.tsx:42` | requirePaasRole |
| 신규 앱/Compose | `app/(paas)/new-app/[step]/page.tsx:33`, `app/(paas)/new-app/compose/page.tsx:25` | requirePaasRole |
| 서비스/환경 분류 | `app/(paas)/services/page.tsx:23`, `app/(paas)/deployments/env-classifier/page.tsx:15` | requirePaasRole |
| 관리자 화면 | `app/(paas)/admin/page.tsx:18` | requirePortalAdmin → requirePaasSession |
| 레거시 화면 | `app/(legacy)/account/page.tsx:17`, `app/(legacy)/portal/page.tsx:5`, `app/(legacy)/login/page.tsx:31` | 직접 auth |
| BFF | `app/api/v1/[...path]/route.ts:46` | paasSession; GET/POST/PUT/PATCH/DELETE의 공통 forward |
| 앱 액션 | `app/(paas)/my-apps/[id]/actions.ts:19`, `:37` | requirePaasSession |
| 앱 생성 액션 | `app/(paas)/new-app/actions.ts:33` | requirePaasSession |
| Compose 액션 | `app/(paas)/new-app/compose/actions.ts:64`, `:83` | requirePaasSession |
| 관리자 액션 | `app/(paas)/admin/actions.ts:20`, `:52` | requirePortalAdmin |
| Auth.js endpoint | `app/api/auth/[...nextauth]/route.ts:3` | GET/POST handlers. GET session도 jwt callback을 실행 |

공용 경계는 `lib/require-session.ts:23`, `:39`, `:52`, `:59`다.
로그아웃의 `app/auth-actions.ts:20–31`은 getToken으로 cookie를 decode할 뿐 갱신하지 않는다.
로그인/signOut 액션을 모두 refresh 진입점으로 잘못 세지 않았다.

기존 코드에는 SessionProvider, useSession, getSession, refetchInterval,
refetchOnWindowFocus 및 명시적인 `/api/auth/session` 폴링 호출이 없었다.
`components/paas/deployment-request-rows.tsx:103`의 5초 router.refresh는 pending 신청의
RSC 재요청이며 세션 갱신도 간접 유발할 수 있다. 이 주기는 변경하지 않았다.

## 4. 런타임 경계와 Proxy 수정

사용자 예시의 “Middleware는 기본 Edge”를 이 프로젝트에 그대로 적용하면 틀린다.
설치된 Next는 16.3.1이며 로컬 문서
`node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/proxy.md:223`은
Proxy의 기본 런타임이 Node이고 runtime 옵션을 넣으면 오류라고 명시한다.
같은 문서 19행은 Proxy와 렌더 코드의 모듈/전역 공유에 의존하지 말라고 한다.
따라서 Node라는 이름만으로 같은 메모리라고 가정하지 않았다.

수정 전 순서: 요청 A의 Proxy auth가 RT1을 갱신 → Proxy 응답에 RT2 cookie 준비 →
렌더 코드의 auth가 요청 cookie 사본 RT1로 다시 갱신 → single-use IdP에서는 invalid_grant.
실제 Auth.js wrapper의 동작은 설치 코드 `node_modules/next-auth/lib/index.js:142–145`,
`:183–184`에서 확인했다. 해당 환경의 실제 isolate 배치로 E2E 재현한 것은 아니며,
서로 다른 런타임에서 캐시가 공유된다는 전제를 제거하는 것이 수정 목적이다.

`proxy.ts`에서 request.auth/req.auth를 사용하지 않음을 확인하고 auth import와 wrapper를 제거했다.
CSP/nonce/pathname/공통 보안 헤더는 그대로 생성한다(`proxy.ts:4–46`).
인증은 layout·페이지·BFF·액션의 위 게이트가 계속 담당한다.
`proxy.test.ts:8`은 auth 모듈을 import하면 실패하도록 만들고 헤더 유지도 검증한다.
런타임 이전이 아니므로 Node 전환 승인이나 Edge 지원 가정을 추가하지 않았다.

## 5. 같은 런타임의 병합과 회전 결과 보존

`lib/oidc-refresh-coordinator.ts`가 가변 상태를 담당한다.

- 원문 refresh token을 정확 일치 key로 사용(55). 축약 hash나 node:crypto를 사용하지 않는다.
- 진행 중 Promise 조회(61–62), await 전 등록(89). 같은 token의 IdP 호출은 하나다.
- 성공 결과만 구 token key로 저장(71–81). TTL은 완료 시점부터 최대 60초이며
  새 access token의 다음 갱신 경계보다 오래 캐시하지 않는다(78–79).
- 실패는 결과 캐시에 들어가지 않고 대기자 모두에게 전파된다. finally에서 정리(84–85).
- 결과/진행 중 맵 각각 512개 상한, 요청 때 만료 결과를 청소한다.
  진행 중 항목은 퇴출하지 않고 한 건의 성공 또는 실패까지 새 키의 호출을 기다린다.
  깨어난 요청은 키와 용량을 다시 검사한다. 시험 reset 전 작업이 새 작업을 지우거나
  덮지 않도록 Promise identity 확인도 유지한다.
- 같은 Node 실행 컨텍스트의 별도 번들 평가에도 globalThis 저장소를 공유(15–23).
  Proxy·다른 isolate·다른 replica에는 적용되지 않는다.
- 첫 호출자의 JWT 부가 필드를 캐시하지 않고, 호출자별 필드와 배열을 분리(39–47, 68).
- 시험 reset은 95행. `oidc-token.ts`의 기존 순수 로직에는 가변 상태를 추가하지 않았다.

coordinator 자체에는 node:* import가 없다. 수정 후 Proxy import 그래프에서 auth/coordinator를
제거했으므로 Edge와 Node 사이 공유를 해결책으로 삼지 않는다. 토큰 해석 함수는 기존처럼
Buffer를 쓰며, 전체 그래프가 임의의 Edge 호스트에서 동작한다고 인증하지 않는다.

## 6. 회전된 cookie 전달과 폴링

Proxy 제거만으로 끝내면 또 다른 문제가 생긴다. 설치된 Auth.js의 RSC용 `auth()`는
세션 본문만 반환한다(`node_modules/next-auth/lib/index.js:104–106`). 브라우저 cookie를
갱신하지 못하므로 장시간 RSC 조회만 하면 TTL 이후에도 소모된 구 token을 계속 보낸다.

`app/layout.tsx`의 보이지 않는 `SessionCookieSync`가 브라우저에서 기존 Auth.js session
endpoint를 호출해 Set-Cookie를 받는다(`components/session-cookie-sync.tsx:8–20`,
`lib/session-cookie-sync.ts:18`). mount/경로 변경/focus 및 session의 accessTokenExpiresAt
30초 전 기준으로 요청한다(24–25). 고정 간격의 부하 최적화나 jitter 변경은 하지 않았다.
인증 실패/무인증 응답은 주기 재시도를 중단하고, 네트워크 오류는 다음 focus/경로 변경에서
재시도할 수 있다. 컴포넌트는 화면 요소를 추가하지 않는다.

session 응답에는 access/refresh token을 보내지 않는다(`auth.ts:88–98`).
`auth-refresh.test.ts`는 두 GET와 늦은 구 cookie 요청의 IdP 호출 수뿐 아니라,
암호화된 Set-Cookie를 시험용 secret으로 복호화하여 새 access/refresh token인지 검증하고,
JSON session 본문에는 토큰이 없음을 확인한다.

## 7. 시험 결과

| 시나리오 | 기대하는 IdP 호출 수 | 시험 근거 (`lib/oidc-refresh-coordinator.test.ts`) |
| --- | --- | --- |
| 같은 token 동시 2건 | 총 1, 동일 access token | 36행 `merges two concurrent refreshes` |
| 회전 직후 구 token | 추가 0, 새 refresh token | 67행 `serves a late request` |
| TTL 경과 | 추가 1 | 89행 `refreshes again once ... expired` |
| 다른 token 동시 2건 | 총 2, 결과 분리 | 109행 `does not merge different refresh tokens` |
| 실패 후 다음 호출 | 실패 1 + 재시도 1 | 134행 `does not cache failures` |
| 동시 실패 | 총 1, 양쪽 reject | 160행 `propagates one failure` |
| refresh token 없음 | 0, 기존 오류 유지 | 181행 `keeps the existing error` |
| 늦은 완료·청소·용량 상한 | 상한에서 대기, 진행 중 토큰 중복 소비 없음 | completion clock/clean/waits at capacity 시험 |
| 모듈 재평가 | 총 1 | 266행 `shares pending refreshes ... again` |

실제 Auth.js session handler 시험과 browser cookie sync scheduler 시험도 추가했다.
Mock fetcher와 deferred/clock으로 타이밍을 제어하며 실제 IdP에 요청하지 않는다.

## 8. 남은 한계

- **프로세스/실행 컨텍스트 로컬 병합이다. replica 간에는 병합되지 않는다.** 단일 프로세스,
  단일 활성 Portal 배포 제약을 유지한다. Next를 별도 worker/isolate/serverless로 나누면 재감사 필요.
- TTL 이후 구 cookie, 완료 결과 캐시 퇴출, 프로세스 재시작 시에는 이전 회전 결과를 복구하지 못한다.
  퇴출은 다른 사용자 토큰 반환을 일으키지는 않지만 병합 기회를 잃어 invalid_grant가 다시 날 수 있다.
- IdP가 회전을 수행한 뒤 성공 응답이 네트워크에서 유실되면 새 token을 알 수 없다.
  서버 single-flight만으로 이 실패까지 복구할 수 없다.
- JavaScript가 꺼진 브라우저, cookie 쓰기가 차단된 클라이언트, session endpoint를 전혀 호출하지
  않는 순수 API 소비자는 회전 cookie 전달을 보장받지 못한다.
- 실제 IdP 설정, 실제 사용자 cookie로 두 탭 로그인 E2E, 배포 반영은 확인하지 않았다.

## 실행한 검증

- `npm test`: 15개 파일, 81개 시험 통과. 갱신 관련 5개 파일의 시험은 26건이다.
- `npm run typecheck`: 통과. `npm run lint`: 오류 0개, 기존 미사용 변수 경고 2개.
- `npm run build`: 통과. 처음에는 OIDC 런타임 환경변수 부재로 실패했으며, 실제 자격증명이 아닌
  빌드 전용 fixture 환경으로 재실행했다. 실제 IdP에 연결하지 않았다.
- `bash ./sadp --test`: Helm을 PATH에 준비하고 전체 통과. 문서 계약 검사 및 `git diff --check` 통과.
- 로컬 개발 서버에서 로그인 화면 스크린샷 확인, 무인증 보호 페이지의 로그인 리다이렉트,
  BFF의 401 Problem Details 및 session endpoint의 200 확인.
- 로컬 standalone 기동은 추적된 `@swc/helpers` 파일 누락으로 실패했다. 현재 설치 의존성의
  패키징 문제와 이번 수정 사이의 인과는 확인 못 했으며, standalone 런타임 통과로 보고하지 않는다.
