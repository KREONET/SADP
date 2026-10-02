# SADP와 파생 프로젝트 공통 기능 비교

제공된 파생 프로젝트 소스와 SADP를 비교한 **개발자용 검토 기록**입니다.
처음 설치하는 사람은 [설치 가이드](installation.md), 운영 업데이트는
[기동·종료·업데이트 안내](operations-lifecycle.md)를 사용하세요.
공통화는 같은 기능의 생성 로직과 시험 기준을 여러 프로젝트에서 함께 쓰도록 정리하는 작업입니다.
아래 버전·시험 결과는 비교 당시의 기록이며 최신 운영 상태를 뜻하지 않습니다.

비교 대상은 작업 디렉터리 `Other-Source`에 제공된 IAPP, NAPP, XGW 소스다.
원격 저장소의 최신 상태나 운영 클러스터 상태를 의미하지 않는다. 파생본은 비교 자료로
유지하고, 이번 구현 변경은 SADP에 반영했다.

## 인증

| 대상 | 확인한 구현 | 공통화 방향 |
| --- | --- | --- |
| SADP | 외부 OIDC, PKCE/state/nonce, 서버 세션, 프로세스 공유 갱신 coordinator | IdP 관리 기능 없이 검증·갱신·로그아웃 계약 유지 |
| IAPP | Keycloak provider, 갱신 coordinator, 완료 결과 캐시 | 진행 중 맵이 가득 차면 추적하지 않는 새 호출도 실행하므로 용량 대기 보완 필요 |
| NAPP | Keycloak provider, 진행 중 갱신을 보존하는 coalescer | 용량 대기 원칙을 SADP로 반영 |
| XGW | `ui/auth.ts`에서 직접 refresh 함수 호출 | 동일 구 토큰의 동시 갱신을 병합하는 coordinator 이식 필요 |

SADP도 기존에는 진행 중 갱신이 512개를 초과하면 오래된 항목을 지웠다. 이때 같은
일회용 refresh token의 후속 요청이 두 번째 IdP 호출을 시작할 수 있었다.
`ui/lib/oidc-refresh-coordinator.ts`에서 진행 중 항목을 보존하고, 완료 후 대기 요청이
키와 용량을 다시 검사하도록 수정했다. 기존 프로세스 공유, 결과 TTL, 호출자 필드 분리,
실패 비캐시 규칙을 유지한다. 프로세스 또는 replica 사이의 분산 병합은 제공하지 않는다.

근거 파일: 각 파생본의 `apps/portal-lite/ui/auth.ts`, IAPP의
`lib/keycloak-refresh-coordinator.ts`, NAPP의 `lib/keycloak-refresh-coalescer.ts`.
공통 회귀 기준은 같은 토큰 동시 요청, 용량 초과, 회전 직후 구 쿠키, 실패 후 재시도,
세션 JSON의 토큰 비노출이다. SADP의 `auth-refresh.test.ts`와 coordinator 시험을 기준으로 한다.

Keycloak 설치·realm/client 변경과 SAML broker 설정은 SADP의 외부 IdP 소유권 경계와
충돌한다. 공통화 대상은 인증 소비자의 동작이며, 제공자 프로비저닝은 파생 프로젝트의
선택 기능으로 유지해야 한다. 인증된 사용자 신원을 전달하는 BFF의 loopback 경계와
OpenBao → ESO 자격증명 공급 경계도 함께 유지한다.

## 패키지 업데이트

IAPP의 `versions.lock.yaml`에는 Next.js 16.3.0이 남아 있지만 UI `package.json`은
16.3.1이다. SADP의 현재 값은 서로 맞지만 이 차이를 자동 검출하는 검사가 없었다.

`scripts/site/check-portal-package-lock.py`를 공통 CI에 연결했다. Next.js/Auth.js/
React/ESLint에 대해 제품 잠금값, package manifest, npm lock의 루트 선언과 실제 resolved
버전을 비교한다. React DOM·Next ESLint 설정도 함께 확인하고 Docker frontend/runtime
Node 버전도 검사한다. `portal-package-lock-test.py`는 부분 업데이트를 거부하는 회귀다.

NAPP/XGW는 Node·Go·Alpine 및 이미지 digest를 잠금 파일과 Dockerfile에 함께 둔다.
SADP는 Node 잠금값과 Go Dockerfile 태그를 사용하며 base image digest 고정은 남아 있다.
파생본의 digest는 그 파생본 버전용이므로 SADP의 다른 버전에 복사하면 안 된다.
후속 런타임 업그레이드에서는 대상 아키텍처의 실제 registry digest를 확인하고 Node·Go·
Alpine·이미지 잠금값을 함께 갱신한 뒤 실제 컨테이너 빌드를 검증해야 한다.

NAPP의 `apply-locked-versions.sh` (파생본의 scripts/ops 디렉터리)는 잠금값 검사, 백업, Application 적용,
Synced/Healthy 대기를 묶는다. SADP의 `scripts/ops/update-sadp.sh`는 검증된 checkout의
fast-forward 갱신까지 담당한다. 둘은 적용 범위가 다르다. 플랫폼 패키지 수렴용 공통
명령을 도입할 때는 GitOps 원격 revision 일치와 현재 revision의 수렴까지 확인해야 한다.
상태 문자열만 보고 오래된 Healthy를 새 버전 성공으로 판정하지 않아야 한다.
RKE2 노드 업데이트와 재시작은 기존의 별도 유지보수 경계를 유지한다.

## 빌드와 배포

SADP의 워커 빌드 전송은 UI 바로 아래 `.env`만 제외했다. backend, 중첩 UI,
test-app의 로컬 `.env`와 `.git`은 빌더로 전송될 수 있었다. 실제 tar 명령을 모든
하위 디렉터리의 `.env`/`.env.*`/`.git` 제외로 보완하고 직접 Docker 빌드용 ignore에도
동일한 제외를 적용했다. `build-context-test.py`는 중첩 fixture를 실제 tar로 생성해
비공개 파일 제외와 필요한 소스 보존을 검증한다. 임의 이름의 Secret 파일 전체를
탐지하는 기능은 아니므로 자격증명은 계속 빌드 소스 바깥에 보관해야 한다.

IAPP는 같은 태그의 containerd 참조를 import 전에 제거한다. SADP는 archive 검사와
각 노드의 import 후 manifest digest 비교를 이미 수행한다. 참조 제거를 일괄 도입하기보다
새 immutable tag/digest로 승격하고 전체 노드에 준비한 뒤 rollout하는 흐름을 공통 기준으로
삼아야 한다. NAPP의 `prepare-portal-image.py`/`release-portal-image.sh`가 이 방향의
참고 구현이지만 backend 디렉터리 구조와 계약 생성 입력이 SADP와 다르다.

NAPP release는 새 배포 성공 뒤 직전 이미지를 삭제한다. 공통 배포 흐름에는 rollback용
이미지 보존 기간과 GitOps desired revision 확인을 먼저 정의해야 한다. 이번에는 운영
이미지를 삭제하는 동작이나 자동 클러스터 적용을 추가하지 않았다. SADP의 Portal 단일
활성 프로세스 및 Recreate, ESO 준비 후 workload 적용 순서는 계속 유지한다.

## 적용 순서

1. SADP의 인증 용량 대기·패키지 일치 검사·빌드 context 제외 회귀를 공통 기준으로 채택한다.
2. IAPP는 잠금값 불일치와 coordinator 과부하 처리를 보완한다.
3. XGW는 갱신 병합과 SADP의 세션 쿠키 전달 시험을 함께 이식한다.
4. NAPP의 버전 적용·immutable release 흐름은 원격 revision 확인과 rollback 보존을 보완해
   공통 운영 명령으로 설계한다. 제공자 설정·사이트 계약·UI 디자인은 각 프로젝트에 남긴다.

생성된 YAML을 복사하는 방식으로 동기화하지 않는다. 생성 로직과 계약 변경을 이식하고
각 사이트 입력으로 다시 렌더링한 뒤 `bash ./sadp --test`를 실행한다. UI 변경은
`npm test`, `npm run typecheck`, `npm run lint`, `npm run build`를 함께 검증한다.

## 이번 변경의 검증

- `bash ./sadp --test`: 전체 통과. 로컬 Helm 3.17.3을 PATH에 제공해 실행했다.
  잠금 파일의 Helm 3.21.3으로 컨테이너를 빌드한 결과는 아니다.
- UI 시험: 15개 파일, 82개 시험 통과. 용량 초과 시 중복 토큰 소비 방지와 실패 후
  다른 사용자의 대기 해제를 포함한다.
- 타입 검사 통과, 전체 lint 오류 0개와 기존 미사용 변수 경고 2개.
- 프로덕션 Next.js 빌드 통과. 실제 자격증명이 아닌 빌드용 OIDC fixture를 사용했다.
- 문서 계약 검사, build context/패키지 잠금 회귀, `git diff --check` 통과.

실제 IdP 로그인, Docker 이미지 빌드·push·노드 import, 클러스터 rollout은 실행하지 않았다.
이번 결과는 소스와 로컬 회귀의 검증이며 운영 배포 완료를 뜻하지 않는다.
