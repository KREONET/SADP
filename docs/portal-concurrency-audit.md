# Portal 생성·삭제 동시성 감사

여러 사용자가 동시에 생성·삭제를 요청할 때 상태가 서로 충돌하는지 점검한 **개발자용 기술 기록**입니다.
일상 운영자는 [배포 제약](#5단계--배포-제약과-이번-수정)과 [최종 판정](#7단계--최종-판정)을 먼저 읽으세요.
Portal은 전체 배포에서 활성 프로세스 하나만 허용하며, 저장공간 변경만으로 여러 프로세스로 늘릴 수 없습니다.

이 문서에서 불변식은 항상 지켜야 하는 조건, 잠금(lock)은 겹치는 작업을 순서대로 처리하는 장치,
경쟁(race)은 요청 순서에 따라 결과가 달라질 수 있는 상황을 뜻합니다.
아래 파일·줄 번호와 시험 결과는 감사 시점의 근거이며 현재 파일의 줄 번호와 다를 수 있습니다.

후속 OIDC 수정과 시험은 [OIDC 갱신 경합 수정](portal-oidc-refresh.md)에 기록했다.
아래 O1은 수정 전 감사 결과이며 나머지 backend 결함은 이 후속 작업에서 변경하지 않았다.

감사일: 2026-09-11. 대상은 이 체크아웃의 Portal HTTP 생성·삭제, 저장소,
Forgejo 작업 큐·승인·소스 watcher, OIDC 세션이다. 처리량과 응답시간은 범위 밖이다.
아래 경로는 저장소 루트 기준이며 줄 번호는 이번 변경 후 기준이다.
실서비스·클러스터·외부 IdP에는 요청하지 않았다.

## 1단계 — 구현을 읽기 전에 수집한 불변식

문서와 오류 정의부터 확인했다. README는 전체 구조를 설명하지만 동시성 계약은 없고,
안내된 `ADR/` 및 `docs/adr/`는 현재 체크아웃에 없다. 없는 ADR의 결론은 확인 못 했다.

| 불변식 후보 | 최초 근거 | 범위/주의 |
| --- | --- | --- |
| AppGroup 이름은 플랫폼 전역 유일 | `AGENTS.md:231`, `docs/developer-guide.md:75` | 사용자·project·environment가 달라도 같은 Namespace를 공유하면 안 됨 |
| 배포 대상은 다른 앱이 선점할 수 없음 | `apps/portal-lite/backend/store.go:46` | 논리 앱 이름만으로 충분한지는 2단계에서 확인 |
| 사용자 예약 자원 상한, 중지해도 예약 유지 | `docs/developer-guide.md:50`, `docs/portal-api.md:207` | CPU/메모리 합산, 실제 Pod 수와 예약량 구별 |
| 최신 요청만 삭제, 진행 중 배포는 삭제 거부 | `apps/portal-lite/backend/store.go:43` | 오류 정의 43–45행 |
| 삭제 중 AppGroup에는 신규 앱 유입 금지 | `apps/portal-lite/backend/deployment_requests.go:366`, `apps/portal-lite/backend/appgroup_api.go:556` | 삭제 실패 후 미완료 정리도 확인 필요 |
| 같은 키·같은 사용자·본문은 기존 결과, 다른 본문은 409 | `docs/portal-api.md:59` | 59–68행. 단일 앱은 키 선택, AppGroup은 필수 |
| 승인·보안 검사 통과 전 배포 금지 | `docs/portal-api.md:155`, `docs/portal-api.md:180` | 승인 저장과 실제 병합의 경계 확인 |

독립된 계정 생성 API는 위 API 목록(`docs/portal-api.md:29`)에 없다. 계정명 전역
유일성은 외부 IdP 영역이며 이 감사에서는 확인 못 했다.

## 2단계 — 잠금 보유 범위와 커밋

아래에서 D=`apps/portal-lite/backend/deployment_requests.go`,
G=`apps/portal-lite/backend/appgroup_api.go`, S=`apps/portal-lite/backend/store.go`,
R=`apps/portal-lite/backend/runtime_state.go`, U=`apps/portal-lite/backend/source_updates.go`,
A=`apps/portal-lite/backend/approval.go`다. 각 범위는 함수 시작–끝이다.
`appMu`가 있는 행은 전부 `defer Unlock`으로 함수 반환까지 유지된다.

| 핸들러/진입점 | 잠금 획득 줄 | 함수 경계 | 잠금 안 검사 및 모든 store 호출 | 커밋 호출 |
| --- | --- | --- | --- | --- |
| 단일 앱 생성 | D:250 `appMu` | D:205–507 | `findByIdempotency` 256; replay `update` 292; `appClaim` 313; `hostClaim` 327; `groupClaim` 337; `groupDeletionInProgress` 364; `projectedQuotaErrors→liveProfiles` 371; `create` 451; Secret 결과 `update` 468/481/486 | D:451 → S:446 → `createBatch`; Secret 쓰기 464도 같은 appMu |
| AppGroup 생성 | G:525 `appMu` | G:487–702 | `groupClaim` 527; `groupDeletionInProgress` 554; `appClaim` 561; `liveProfile→liveProfiles` 572; `hostClaim` 587; `projectedQuotaErrors→liveProfiles` 597; `findByIdempotency` 626; `createBatch` 668 | G:668 → S:454 |
| 삭제 | D:646 `appMu` | D:634–693 | `beginDelete` 648; 큐 실패 시 `updateIfCurrent` 676 | S:854–900, `mu` 855부터 `append` 890까지 |
| 중지/재개 | R:230 `appMu` | R:215–278 | `beginRuntimeState` 232; 큐 실패 `updateIfCurrent` 260 | R:126–206, `mu` 127부터 `append` 199까지 |
| 소스 watcher 생성 | U:138 `appMu` | U:137–179 | `latestAppRequest` 141; ID·UpdatedAt·상태·commit 검사; `findByIdempotency` 152; `create` 174 | U:174 → S:454; 기존 profile 복사로 자원 변화 없음 |
| 관리자 승인/반려 | A:428 `decisionMu` | A:425–517 | `get` 429; PR/state/결정 검사; `updateIfCurrent` 460/487/504 | 각 CAS 뒤 461/488/505에서 즉시 Unlock. enqueue와 응답은 밖 |
| GET reconciliation | 핸들러 appMu 없음 | D:538–630 | 외부 조회 후 `updateIfCurrent` 사용 | S:828–849의 `mu` 829와 CAS 835–838, append 842 |

입력 형식·한 요청의 정적 자원 검증은 appMu 전에 하지만, 다른 요청과 공유하는 상태를
검사하는 구간은 위와 같다. validate endpoint의 결과는 예약이 아니다(G:434–485).

`createBatch` 자체 임계구역은 S:454–542이며 `mu`는 455–456행에서 잡는다.
재검증하는 것은 요청 ID(469), 물리 배포 대상과 배치 내부 중복(476–483),
예약 hostname/기존 host/배치 내부 host(484–497), 멱등 키(498–505)다.
쓰기·fsync·메모리 반영(522–537)까지 잠금을 유지한다.
**재검증하지 않는 것**은 전역 groupClaim, 사용자 누적 quota, groupDeletionInProgress,
PVC 변경 규칙이다. 이것들은 호출자의 appMu가 권위 있는 원자 구간이다.
따라서 store 메서드만 직접 호출하는 새 경로를 추가하면 안 된다.

## 3단계 — 권위 있는 검사

| 불변식 | 최종 보장 위치 | 판정 |
| --- | --- | --- |
| 물리 namespace/app 소유권 | S:481 `artifactConflictLocked`, 구현 S:652–673 | 같은 사용자·논리 identity 재배포를 허용. 다른 소유자 및 삭제/중지 전환과 충돌하면 커밋 안에서 거부 |
| Gateway hostname 유일성 | S:489 `hostClaimLocked`, 구현 S:688–719 | 핸들러 host 검사는 친절한 오류용. 커밋이 재검증하므로 보통 생성 A/B 사이 틈 없음 |
| 그룹 이름 전역 소유권 | D:337 또는 G:527 + 공통 appMu | S:723 groupClaim은 조회 잠금만 가진다. 최종 보장은 호출자 임계구역이며 store.createBatch 자체 보장은 아님 |
| 누적 CPU/메모리·그룹 Pod 상한 | D:371 또는 G:597 + appMu, 계산 D:783–833 | 신규 identity 두 개의 동시 접수는 직렬화. **재배포 축소 실패의 예약 복원은 보장 안 됨**(아래 Q1) |
| 삭제 상태 전환 | S:854–900 | 소유자·최신 물리 요청·상태를 append와 같은 mu에서 검사. 단, 과거 별도 요청 ID의 열린 PR은 검사하지 않음(B1) |
| 삭제 중 그룹 신규 유입 | D:364/G:554 + 삭제 D:646, S:888 | 커밋 함수의 재검증 대신 appMu와 durable deletion flag가 함께 보장 |
| 멱등 실행 | D:256/G:626 + appMu, S:498 | 같은 저장 키의 중복 commit 차단. 큐도 요청 ID로 병합. 문서상의 모든 본문/키 조합에 대한 보장은 아래 제한 참조 |
| 오래된 GET 상태의 덮어쓰기 방지 | S:828–849 | state·runtime generation·deletion flag·desired state·UpdatedAt CAS를 append와 같은 mu에서 검사 |
| 승인 결정 경쟁 | A:428–505 및 S:828 | decisionMu/CAS로 같은 요청의 결정을 보호. 반환 객체의 포인터는 격리되지 않음(B2) |

`hostClaim/hostClaimLocked`는 설계된 잠금 규약의 실제 예다(S:678, S:688).
파일 저장소는 append 후 fsync(S:220–235), compact 때 임시 파일 sync→rename→directory sync
(S:287–299)를 이미 수행한다. 파일이라는 이유만으로 재설계가 필요하다고 결론내리지 않는다.
동시성 보장과 전원 장애 시 여러 JSONL 레코드의 원자성은 별개이며 후자는 이번 검증 대상이 아니다.

멱등 계약의 제한도 남는다. 단일 앱 키는 사용자별로 namespace되지 않고 raw key다(D:91–106).
다른 사용자의 같은 키는 409(D:256–260)로 닫혀 정보가 섞이지 않는다.
Secret 값은 body hash에서 제외(D:195–198)되므로 문서의 “다른 본문은 409”를 바이트 단위로
보장하지 않는다. AppGroup은 서비스 이름·그룹까지 포함한 파생 키(G:28–35)를 쓰므로,
같은 상위 키를 서로 겹치지 않는 서비스 목록에 재사용하는 경우를 단일 요청 키로 묶지 않는다.
이는 동시 실행 중복 방어와 별도로 계약을 명확히 해야 하는 차이이며 이번에 변경하지 않았다.

## 4단계 — 워커와 핸들러

`main.go:100–112`는 큐 소비자 하나, 소스 watcher 하나, 승인 watcher 하나를 시작한다.
`forgejo.go:566–581`의 run은 process를 동기 호출한다. queueMu는 enqueue/marker만 보호하고
외부 작업 전체를 감싸지 않는다(519–563). 소스 watcher의 생성은 appMu를 잡지만,
삭제 워커는 appMu를 잡지 않는다.

삭제 순서는 `beginDelete`의 durable DeletionRequested 설정(S:888–890) → enqueue(D:671)
→ 마지막 앱 판정(`pipeline.go:1241`) → group cleanup 결정 저장(1248–1255)
→ Git 삭제(1262/1271) → 앱 삭제(1289) → Namespace 삭제(1296)
→ ESO 및 그룹 registry 권한 회수(1313/1320) → deleted 기록(1326–1328)이다.
그동안 새 HTTP 생성은 flag로 거절한다. 실패해도 flag를 유지하므로 유입은 계속 막힌다(S:750–766).
새 앱이 먼저 commit했으면 마지막 앱 판정에 포함되고, 삭제가 먼저 시작됐으면 생성이 거절된다.
이 **새 HTTP 유입** 경로는 안전하다. 다만 이미 접수된 과거 요청의 재개는 B1처럼 별도다.

서로 다른 앱을 동시에 처리하는 두 소비자를 가정하면 양쪽이 상대의 deleting을 non-deleted로
보고 group cleanup을 모두 건너뛸 수 있다(S:801). 결과는 Namespace/권한의 **누수**이며
살아 있는 다른 앱의 삭제는 아니다. 현재는 소비자 하나라 이 interleaving은 실행되지 않는다.
실패 재시도에서는 false→true cleanup 승격을 지원한다(`pipeline.go:1243–1255`).
소비자 수를 늘려도 안전하다는 뜻은 아니다. 순차 소비 역시 정합성 제약이다.

## 5단계 — 배포 제약과 이번 수정

최우선 문서·가드 결핍: appMu(D:37), store.mu(S:117), queueMu/decisionMu
(`forgejo.go:90–92`)는 모두 프로세스 로컬이다. DB transaction/advisory lock/etcd lock으로
이 경계를 대체하는 코드는 해당 경로에서 찾지 못했다.
감사 전 Chart는 persistence.enabled && ReadWriteOnce일 때만 replica>1을 막고,
Recreate도 persistence.enabled에만 의존했다. 근거 설명도 RWO/append-only와 묶여 있었다.
`charts/app-profile/values.yaml:148–149`도 RWX·파일 쓰기 맥락이었다.
따라서 “스토리지만 바꾸면 확장 가능”이라고 오독할 수 있었다. 감사 전 Chart를 별도 복사해
persistence=false, replicaCount=2로 렌더하자 실제로 replicas=2이고 strategy는 생략되었다.

다중 프로세스 시나리오: A와 B가 각각 로드한 빈 메모리 색인에서 같은 그룹 또는 남은 quota를
통과 → 각자 로컬 mutex 안에서 commit → 양쪽이 성공. 파일 rename/fsync는 다른 프로세스의
메모리 색인을 갱신하지 않는다(S:138–155, S:214–216). 공유 DB에 레코드만 옮겨도
핸들러의 검사와 commit을 함께 직렬화하지 않으면 같은 문제가 남는다.

이번에는 동작 알고리즘을 바꾸지 않고 다음 제약만 구체화했다.

- `AGENTS.md:223`와 `docs/portal-api.md`의 “Portal 배포의 정합성 제약”에 독립된 이유를 명시.
- Chart 생성 로직 `charts/app-profile/templates/deployment.yaml:65–68`에서 Portal replica>1 거부.
  0(중지)/1은 유지하며, 볼륨을 끄더라도 Recreate 적용(91–94).
- `scripts/tests/render-test.sh:996–1014`에 persistence=false 및 ReadWriteOncePod 각각의
  다중 replica 거부/단일 replica+Recreate 성공을 검증. 거부 원문까지 확인해 엉뚱한 오류를
  성공으로 세지 않는다. helm 부재도 시작 시 명시 실패(8–9).

`environments/site.env`는 없었다. 생성된 values와 계약은 수정하지 않았다.
이 가드는 app.name=portal-lite인 이 Chart 배포에 적용된다. 별도 Deployment, 수동 실행,
직접 kubectl scale, 강제 Pod 삭제에 대한 admission/fencing 보장은 없다.

## 6단계 — OIDC/세션

O1: `auth.ts:71–85`는 만료 30초 전부터 각 jwt callback이 refresh 함수를 호출한다.
`lib/oidc-token.ts:111–157`는 매번 POST하며 in-flight map/promise 병합이 없다.
회전된 refresh token은 성공 응답에서 교체한다(147–148).

시간 순서: 탭 A와 B가 동일한 만료 직전 cookie를 전송 → 각각 같은 refresh token으로 POST
→ single-use IdP가 A만 허용하고 B를 invalid_grant로 거부 → B callback은 RefreshTokenError
(`auth.ts:85`) → 세션을 사용할 수 없다고 판정(`lib/paas-session-policy.ts:10`),
화면 요청은 로그인 경로로 이동(`lib/require-session.ts:23–29`). 서버 IdP 세션 자체가
반드시 종료된다는 뜻은 아니다. 실제 cookie 응답 도착 순서와 IdP 정책은 별도 확인이 필요하다.

가짜 single-use fetcher와 두 호출의 barrier를 사용한 시험에서 POST 두 번, 성공 하나/실패
하나를 재현했다. 실제 IdP가 rotation을 켰는지는 확인 못 했다.
수정은 동일 토큰의 겹친 갱신을 병합하고 늦게 도착한 구 cookie까지 다룰 정책이 필요하다.
단순히 jitter만 추가해서는 single-use 경쟁을 해결하지 못한다.

SessionProvider/refetchInterval을 사용하는 명시적인 세션 폴링은 검색에서 찾지 못했다.
대신 pending 신청이 있을 때 `components/paas/deployment-request-rows.tsx:97–105`는
5초 고정 router.refresh를 실행하며 jitter가 없다. 이는 서버 인증 재평가의 동시 트리거가
될 수 있으나, 서로 다른 사용자들의 만료가 실제로 동기화됐다고 확인하지는 못했다.
처리량 최적화 목적의 jitter 수정은 하지 않았다.

## 7단계 — 최종 판정

### 안전한 것 (근거: 파일:줄)

- 단일 프로세스에서 다른 소유자의 물리 대상·hostname 동시 선점:
  `store.go:481`, `store.go:489`의 commit 내부 재검증.
- 새로운 HTTP 생성 두 건의 그룹 소유권 및 quota 검사–commit:
  `deployment_requests.go:250–451`, `appgroup_api.go:525–668`의 appMu.
  재배포 실패 복원까지 안전하다는 주장은 하지 않는다.
- 삭제 상태 전환과 신규 HTTP 자식 유입 차단:
  `store.go:854–900`, `store.go:750–766` 및 공통 appMu.
- GET의 오래된 snapshot 쓰기: `store.go:828–849` CAS.
- 저장된 동일 키의 중복 commit 및 같은 ID의 큐 중복 실행:
  `store.go:498`, `forgejo.go:519–581`. 키/본문 계약의 제한은 3단계 참조.

### 안전하지 않은 것 (요청 A/B 시간 순서)

**B1 — 이전 승인 대기 요청이 최신 삭제 뒤에 살아남는다.**

1. A의 앱 생성이 pr-open에서 승인 대기.
2. B가 같은 사용자·identity로 다시 생성. `store.go:665–668`은 기존 pr-open을 거부하지 않음.
3. B의 배포가 실패하여 failed. B를 삭제하면 최신 요청이므로 `beginDelete` 통과(868, 879).
4. B가 deleted된 뒤 A 승인. `approval.go:429–438`은 A 자신의 상태만 확인하고 최신 identity나
   다른 요청의 삭제를 확인하지 않음. `reviewForAdvance`도 ID만 다시 읽음(264–265).
5. A가 실제 fake Forgejo PR을 merge(`pipeline.go:1117`). 그러나 소유권 조회는 최신 B의
   deleted에서 false(`store.go:641–642`). 배포가 뒤늦게 진행되는 동안 선점/조회 상태가 어긋난다.

HTTP로 A/B를 생성한 재현에서 B의 failed/deleted는 store fixture로 주입했고,
A의 승인 및 merge는 실제 구현+fake Forgejo로 확인했다. 클러스터 리소스 부활 E2E는 미확인.
이전 작업 무효화/최신 세대 검증 정책이 필요한 코드 결함이다. mutex 추가만으로 닫히지 않는다.

**B2 — 잠금을 빠져나온 shallow-copy 포인터의 데이터 경쟁.**

1. A 승인 요청이 store CAS 결과를 받아 enqueue 후 응답 JSON을 인코딩(`approval.go:504–554`).
2. 워커 B가 같은 요청을 읽어 merge 후 `request.PullRequest.State`를 수정(`pipeline.go:1121`).
3. store의 apply/get은 struct를 값 복사하지만 내부 포인터는 공유(`store.go:214`, `store.go:905`).
   A의 JSON 읽기와 B의 포인터 쓰기가 같은 객체에서 경쟁한다.

기존 `TestManualApprovalPersistsEvidenceBeforeMerge`의 race detector로 재현했다.
응답과 저장소 snapshot 격리 실패이며, durable 저장 전에 메모리 내용이 변할 수 있다.
이 결과만으로 실제 Namespace 오삭제까지 입증했다고 주장하지 않는다.

**Q1 — 자원 축소 요청 실패가 뒤에 접수된 앱과 quota를 초과한다.**

1. 기존 앱 X가 사용자 CPU 상한을 전부 예약한다.
2. A가 X의 자원을 줄이는 재배포를 접수. projectedQuotaErrors는 이전 X를 작은 profile로
   대체하고(`deployment_requests.go:791–792`), received도 예약에 사용(`store.go:611–613`).
3. A가 아직 완료되기 전에 B가 다른 작은 앱을 생성. 줄어든 합계를 기준으로 통과.
4. A가 merge 전 실패. `store.go:601–605`는 이전 큰 X로 돌아간다. B와의 합계가 상한 초과.

실제 store/create/projectedQuotaErrors와 실패 상태 fixture로 이 합계 초과를 재현했다.
appMu는 A/B의 접수를 직렬화하지만 비동기 rollback까지 묶지 않는다.
기존 profile과 예정 profile 사이의 예약 보존 정책이 필요하다. 이 문제는 동시 HTTP 실행만의
문제가 아니라 완료 전 작업 수명이 겹치는 문제다.

**O1 — 회전 refresh token의 중복 사용.**

탭 A/B의 동시 갱신 순서와 근거는 6단계. 가짜 single-use IdP에서 재현했으며 실제 IdP 설정은
미확인이다. 이 경우 세션 계층 수정이 필요하다.

### 코드 변경 없이 문서·가드만 필요한 것

정상 임계구역에 추가 mutex를 넣을 필요는 **없다**. 독립된 단일 프로세스 제약의 문서·Chart
가드·회귀 시험을 이번에 추가했다(5단계). 다만 전체 서비스에 필요한 동작 코드 변경이
“없다”는 결론은 B1/B2/Q1/O1 증거와 맞지 않는다. 이 감사에서는 해당 동작 코드를 고치지 않았다.

### 확인 못 한 것

실제 IdP rotation, 두 탭의 실제 브라우저 cookie 경합, 실제 클러스터 생성·삭제 E2E,
외부 운영자의 Namespace/Git 동시 변경, 다중 프로세스 직접 배포 차단, 전원 장애·디스크
부분 기록은 확인 못 했다. hostname/물리 claim도 B1 같은 이미 접수된 과거 작업의 재개까지
포함하여 전역적으로 안전하다고 인증하지 않는다.

## 검증 기록

- 일반 `go test ./...`는 Helm을 준비한 뒤 통과.
- 기존 Go 전체 `-race` 실행에서 B2 검출. 최초 실행의 Helm import 시험은 helm 부재로도 실패.
- Helm v3.17.3을 임시 디렉터리에 준비한 뒤 기존 승인 시험을 `-race -count=10`으로 재실행하여 B2 재현.
- 임시 Go 감사 시험 두 개: B1의 이전 PR merge/claim false, Q1의 실패 후 quota 초과 모두 재현.
- 임시 Vitest 감사 시험 하나: O1의 두 POST 중 하나 실패 재현.
- 임시 시험은 버그를 정상 동작으로 고정하는 회귀 시험이 아니므로 기본 suite에 추가하지 않았다.
  이번에 추가한 영구 회귀 시험은 배포 정합성 가드만 검증한다.

- 최종 `bash ./sadp --test` 통과(Helm v3.17.3 PATH 지정). Chart 회귀 80건 통과,
  새 replica/rollout 가드 4건과 기존 Portal OFF 검증 포함. ci-guard 및 diff 검사 통과.
- 첫 전체 실행의 문서 링크 검사는 감사 문서 작성 중 링크 대상이 아직 없어 실패했으나,
  문서 완성 후 문서 검사와 전체 suite 재실행 모두 통과했다.
- `go test -race -run TestManualApprovalPersistsEvidenceBeforeMerge -count=10 ./...`는
  B2 때문에 실패한다. 일반 테스트 통과를 동시성 안전의 증거로 대체하지 않는다.
