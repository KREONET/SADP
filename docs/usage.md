# SADP 사용자 가이드

> 대상: Portal에서 서비스를 확인하고 단일 앱 또는 여러 앱을 배포하는 사용자
> 화면 기준: `apps/portal-lite/ui/app`과 `apps/portal-lite/ui/components/paas`
> API 기준: `apps/portal-lite/openapi.yaml`

이 문서는 현재 Portal 화면에 실제로 있는 메뉴와 버튼만 설명합니다. 화면과 문서가 다르면
새로고침한 뒤에도 같은지 확인하고, 계속 다르면 배포된 Portal 버전과 이 문서의 Git revision을
관리자에게 전달합니다.

## 1. 준비물과 권한

관리자에게 다음을 받습니다.

- Portal 주소 `https://<PORTAL_HOST>`
- SSO 계정
- 앱 조회 권한 `deployments:read`
- 앱을 신청·중지·재개·삭제하려면 `deployments:write`

일반 사용자는 kubeconfig, RKE2 token, OpenBao root token, Keycloak 관리자 계정, Forgejo bot
token이 필요하지 않습니다.

브라우저에 인증서 경고가 나타나면 경고를 무시하고 로그인하지 말고 주소와 발생 시각을
관리자에게 전달합니다.

## 2. 로그인과 로그아웃

1. `https://<PORTAL_HOST>`를 엽니다.
2. 로그인 화면에서 Keycloak 로그인을 선택합니다.
3. 조직 SSO가 연결된 사이트면 조직 로그인까지 마칩니다.
4. 인증 후 원래 열었던 Portal 경로로 돌아오는지 확인합니다.

로그인이 반복되거나 가입·프로필 입력 화면이 다시 나타나면 임의로 새 계정을 만들지 않습니다.
사용자 ID, 발생 시각, 화면 오류 문구, 처음 연 경로만 관리자에게 전달합니다. password, token,
cookie는 전달하지 않습니다.

로그아웃은 계정 화면 또는 상단 사용자 메뉴에서 실행합니다. Keycloak 로그아웃까지 완료된 뒤
공용 장비에서는 브라우저 창을 닫습니다.

## 3. 현재 화면 지도

상단 메뉴는 소스의 `NAV_ITEMS`와 다음과 같이 대응합니다.

| 메뉴 | 경로 | 실제 기능 |
| --- | --- | --- |
| 홈 | `/` | 내 워크로드, 최근 신청, 쿼터, 접근 가능한 서비스 요약 |
| 서비스 | `/services` | 공개·SSO·관리 서비스 목록과 현재 상태 |
| 내 앱 | `/my-apps` | 내 신청의 최신 앱 상태, 검색·필터·상세 보기 |
| 배포 | `/deployments/env-classifier` | `.env` 값을 ConfigMap/OpenBao로 분류해 단일 앱 초안에 저장 |
| 새 앱 | `/new-app/1` | 5단계 단일 앱 신청 |

여러 앱 함께 배포 화면은 상단의 별도 메뉴가 아닙니다. **새 앱** 1단계 상단의
**docker-compose로 여러 앱 배포하기** 링크로 `/new-app/compose`에 들어갑니다.

백엔드 상태를 읽지 못하면 Portal은 정상인 것처럼 꾸민 목 데이터를 보여주지 않습니다.
`일시적으로 볼 수 없음` 또는 빈 상태가 계속되면 관리자에게 알립니다.

## 4. 단일 앱 신청

단일 앱 위저드는 정확히 다섯 단계입니다.

### 1단계 — 기본 정보

- 앱 이름: 소문자로 시작하는 40자 이하의 DNS 이름
- 프로젝트: Portal 카탈로그가 허용한 값 중 선택
- 환경: 서버가 정한 읽기 전용 값이며 사용자가 바꾸지 않음

`hello`, `portal-lite`, `secure-demo`와 플랫폼 예약 접두사는 사용할 수 없습니다. 이름이 이미
다른 사용자나 AppGroup에 속하면 신청이 거부됩니다.

### 2단계 — 소스 정보

- 자격증명이 포함되지 않은 HTTPS Git 저장소 URL
- branch 또는 tag
- 저장소 루트 기준 Dockerfile 상대경로

Dockerfile 파일명은 `Dockerfile`로 시작해야 합니다. URL에 사용자명, password, token, query,
fragment를 넣지 않습니다.

### 3단계 — 실행 조건

- 컨테이너가 실제로 듣는 TCP port
- Pod 수 `replicas`
- 플랫폼이 제공한 자원 preset

화면이 preset 제한값과 `preset × replicas` 쿼터 사용량을 보여 줍니다. 현재 단일 앱 화면에는
health path나 probe 방식을 고르는 입력이 없습니다. 서비스 probe는 플랫폼 기본값을 사용합니다.

### 4단계 — 접근과 통신

| 입력 | 선택 | 의미 |
| --- | --- | --- |
| 외부 접속 | 외부 URL 생성 | `<앱이름>.<BASE_DOMAIN>` HTTPS Route 생성 |
| 외부 접속 | 내부 앱 전용 | 외부 Route 없음 |
| 접속 인증 | 인증 없음 | 외부 URL을 아는 누구나 접근 |
| 접속 인증 | SSO 로그인 필요 | 외부 Route에서 Keycloak 인증 적용 |
| 외부 통신 | 차단 | DNS와 명시적으로 허용한 내부 연결만 |
| 외부 통신 | 웹 통신만 허용 | 인터넷 TCP 80/443, 내부망은 제외 |
| 외부 통신 | 사용자 지정 | 입력한 CIDR·port·TCP/UDP만 추가 |

내부 앱에는 SSO를 선택할 수 없습니다. `웹 통신만 허용`은 도메인 허용 목록이 아니라 포트
정책입니다. 사용자 지정 CIDR은 `/0` 전체 대역을 허용하지 않습니다.

### 5단계 — 검토와 신청

입력, 예상 URL, 자원, 환경변수 분류를 검토하고 **신청 제출**을 누릅니다. 단일 앱 화면에는
검증만 하고 끝내는 별도 버튼이 없습니다. 제출 요청을 받은 서버가 먼저 전체 입력을 검증하고,
통과한 경우에만 신청을 저장해 백그라운드 배포를 시작합니다.

성공 모달에 신청 ID가 표시됩니다. 이 ID를 기록하고 **내 앱** 상세 화면에서 진행 상태와
Pull Request 링크를 확인합니다.

## 5. 환경변수 분류

**배포** 화면은 `.env` 입력을 다음 두 종류로 나눕니다.

| 분류 | 제출 후 처리 |
| --- | --- |
| ConfigMap | 값이 GitOps values의 일반 설정으로 들어감 |
| OpenBao | 값은 제출 요청 중 OpenBao 앱 전용 경로에 직접 저장되고 Git과 신청 저장소에는 key만 남음 |

분류 화면의 **저장**은 서버에 즉시 배포하는 동작이 아니라 단일 앱 브라우저 초안에 결과를
넘기는 동작입니다. 그 뒤 **새 앱** 위저드에서 최종 신청해야 실제 저장과 배포가 시작됩니다.

OpenBao 값은 다음 안전 경계를 가집니다.

- 페이지 이동 동안 메모리에만 유지됩니다.
- `sessionStorage`에는 key와 분류만 남고 실제 값은 빈 문자열로 저장됩니다.
- 새로고침했다면 5단계 제출 전에 OpenBao 값을 다시 입력해야 합니다.
- 제출 성공 시 Portal API가 값을 OpenBao에 쓰고 Git에는 key 이름만 기록합니다.

민감 여부가 애매하면 OpenBao로 분류합니다. 공용 PC에서 운영 `.env`를 열거나 화면 캡처에 값을
남기지 않습니다.

## 6. 여러 앱 함께 배포(AppGroup)

AppGroup 화면은 Git 저장소를 가져오거나 Compose를 직접 붙여 넣습니다.

1. **새 앱** 1단계의 여러 앱 배포 링크를 엽니다.
2. 플랫폼 전체에서 유일한 AppGroup 이름과 프로젝트를 선택합니다.
3. 입력 방식을 고릅니다.
   - Git 주소: 기본 branch에서 Compose 또는 Helm Chart 자동 탐색
   - Compose 직접 입력
4. 모든 서비스가 사용할 자원 preset을 선택합니다.
5. **앱 구성 확인**을 누릅니다.
6. 발견된 서비스마다 외부 노출, SSO, 외부 통신, Secret key, 앱 간 연결을 정합니다.
7. 설정을 바꿨다면 **앱 구성 확인**을 다시 누릅니다.
8. 현재 검증 결과와 입력이 일치할 때만 **배포 신청**을 누릅니다.

단일 앱과 달리 AppGroup은 확인과 신청이 분리돼 있습니다. 검증 후 입력을 바꾸면 기존 계획은
무효가 되고 다시 확인해야 합니다.

AppGroup의 주요 제한:

- 전용 Namespace는 계약의 접두사와 이름을 합쳐 만듭니다. 기본 예시는 `app-<group>`입니다.
- 같은 Namespace여도 앱 간 통신은 자동 허용되지 않습니다.
- 호출 앱의 `이 앱이 접속할 앱`과 수신 앱의 `이 앱에 접속을 허용할 앱` 양쪽을 설정합니다.
- port가 없는 서비스는 worker이며 Service·HTTPRoute가 없고 수신 대상으로 선택할 수 없습니다.
- `build:`와 Compose `environment`는 지원하지 않습니다. 고정 tag/digest의 prebuilt image를 씁니다.
- Secret은 실제 값이 아니라 관리자가 미리 만든 OpenBao key 이름만 입력합니다.
- named volume은 RWO, replica 1, 플랫폼 고정 크기로 변환되며 앱 삭제 시 PVC도 삭제됩니다.

## 7. 내 앱과 상태

목록 카드의 상태는 네 가지입니다.

| 카드 상태 | 의미 |
| --- | --- |
| `PENDING` | 접수, PR, 빌드, 배포 또는 실행 상태 전환 중 |
| `RUNNING` | 파이프라인 상태가 `deployed`이고 목표 replica가 Ready |
| `STOPPED` | GitOps로 replica 0과 외부 Route 제거가 완료됨 |
| `FAILED` | 배포 또는 실행 상태 전환이 실패함 |

상세 화면은 더 정확한 원시 파이프라인 상태를 표시합니다.

```text
received → pr-creating → pr-open → merged → building → deploying → deployed
deployed → stopping → stopped → starting → deployed
deployed/stopped/failed → deleting → deleted
```

`PENDING`만 보고 같은 앱을 반복 신청하지 않습니다. 상세 화면의 신청 ID, 메시지, PR 링크를
먼저 확인합니다.

## 8. 중지·재개·삭제

쓰기 권한이 있고 해당 앱의 최신 신청을 소유한 사용자만 실행할 수 있습니다.

- 중지: GitOps values의 replica를 0으로 만들고 외부 Route를 제거합니다. Service, 내부 DNS,
  ConfigMap, ExternalSecret, PVC는 유지합니다.
- 재개: 원래 replica와 외부 Route를 복원하고 rollout을 기다립니다.
- 삭제: 앱 values와 Argo Application을 제거합니다. 원본 Git 저장소와 Registry image 이력은
  보존합니다.

중지한 앱도 재개 가능한 자원을 보장하기 위해 원래 쿼터를 계속 예약합니다. named volume 앱을
삭제하면 PVC 데이터도 삭제됩니다. 데이터가 필요하면 삭제 전에 관리자에게 백업을 요청합니다.

## 9. 서비스 화면

서비스 카탈로그는 사용자 역할과 실제 Endpoint 상태를 함께 봅니다.

- 공개 서비스: 로그인 없이 외부 서비스 자체에 접근 가능
- SSO 서비스: Keycloak 인증 후 접근
- 관리자 서비스: 필요한 역할이 없으면 Portal에 로그인했어도 접근 불가
- `unknown`: 상태 조회 권한이나 백엔드 조회 문제일 수 있으므로 정상으로 간주하지 않음

권한 거부는 서비스 장애와 다릅니다. 서비스 이름과 필요한 작업을 관리자에게 전달해 권한을
요청합니다.

## 10. 문제를 전달할 때

| 증상 | 확인할 것 | 전달할 것 |
| --- | --- | --- |
| Portal 접속 실패 | 정확한 HTTPS 주소 | 주소, 시각, 브라우저 오류 |
| 로그인 반복 | 새 계정 생성 금지 | 사용자 ID, 시각, 오류 문구 |
| 신청 거부 | 빨간 필드와 서버 메시지 | 신청 ID 또는 오류 type/title, 값을 지운 입력 구조 |
| `FAILED` | 상세 pipeline state와 message | 앱 이름, 신청 ID, commit, 실패 단계 |
| 앱은 `RUNNING`인데 접속 실패 | route와 앱 port | 앱 이름, URL, 발생 시각 |
| Secret 저장 실패 | 같은 초안의 값을 다시 입력 | 앱 이름과 key 이름만 |

password, API token, private key, session cookie, Keycloak token, `.dockerconfigjson`, 전체 `.env`,
kubeconfig, OpenBao root token은 보내지 않습니다.

저장소와 Dockerfile 준비는 [개발자 가이드](developer-guide.md), 플랫폼 장애는
[관리자 가이드](administrator-guide.md)를 사용합니다.
