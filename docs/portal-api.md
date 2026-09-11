# SADP Portal API 안내

> 대상: Portal BFF/API 연동 개발자
> 규격 원본: [apps/portal-lite/backend/openapi.yaml](../apps/portal-lite/backend/openapi.yaml)
> 라우팅 원본: [apps/portal-lite/backend/routes.go](../apps/portal-lite/backend/routes.go)

이 문서는 사람이 빠르게 확인하기 위한 요약입니다. 필드, required 여부, 응답 schema는 OpenAPI가
기준이며 실행 중인 Portal에서도 `GET /api/v1/openapi.yaml`로 제공합니다.

## 1. 인증 경계

브라우저는 `https://<PORTAL_HOST>`의 same-origin BFF를 호출합니다. BFF가 Auth.js 세션을 확인한
뒤 loopback Go API에 신원을 전달합니다.

- 무인증 probe는 `GET /healthz` 하나뿐입니다.
- 조회에는 `deployments:read`, 검증·생성·상태 변경·삭제에는 `deployments:write`가 필요합니다.
- `/api/v1/admin/**`는 호환 역할 없이 정확한 `platform-admin`만 허용합니다.
- BFF는 브라우저가 보낸 `X-Portal-User`, `X-Portal-Roles`, `Authorization`, `requester`를 제거합니다.
- Go API의 `X-Portal-User`는 BFF가 세션의 사용자명 또는 subject로 넣는 내부 header입니다.
- Go API의 `X-Portal-Roles`도 BFF가 검증한 세션 role만 새로 넣으며, Go API는 loopback에만
  bind합니다.
- access/refresh token과 OIDC client secret은 Client Component로 전달하지 않습니다.

따라서 문서의 `curl` 예시는 정상 로그인으로 얻은 Auth.js session cookie가 있어야 합니다.
`X-Portal-User`를 직접 넣어 사용자를 가장하는 호출은 지원하지 않습니다.

## 2. 실제 엔드포인트

| Method | Path | 상태 변경 | 용도 |
| --- | --- | --- | --- |
| `GET` | `/healthz` | 없음 | 무인증 프로세스 probe |
| `GET` | `/api/v1/health` | 없음 | 로그인 사용자용 API 상태 |
| `GET` | `/api/v1/catalog` | 없음 | environment, project, preset, 기능 조회 |
| `POST` | `/api/v1/app-profiles/validate` | 없음 | 단일 앱 입력과 계획 검증 |
| `POST` | `/api/v1/app-groups/validate` | 없음 | Compose/Git AppGroup 계획 검증 |
| `POST` | `/api/v1/app-groups` | 요청 저장·GitOps PR | AppGroup 생성 |
| `GET` | `/api/v1/openapi.yaml` | 없음 | OpenAPI 다운로드 |
| `POST` | `/api/v1/deployment-requests` | 요청 저장·GitOps PR | 단일 앱 생성 |
| `GET` | `/api/v1/deployment-requests` | 없음 | 내 신청 목록 |
| `GET` | `/api/v1/deployment-requests/{requestID}` | 없음 | 내 신청 상세 |
| `PUT` | `/api/v1/deployment-requests/{requestID}/runtime-state` | GitOps PR | 앱 중지·재개 |
| `DELETE` | `/api/v1/deployment-requests/{requestID}` | GitOps 삭제 PR | 앱 삭제 |
| `GET` | `/api/v1/quota-usage` | 없음 | 내 예약 쿼터 |
| `GET` | `/api/v1/admin/approval-dashboard` | 없음 | 전체 신청·승인 정책·private PR 조회 |
| `POST` | `/api/v1/admin/deployment-requests/{requestID}/decision` | 승인/반려 저장·PR merge/close | 관리자 결정 |
| `PUT` | `/api/v1/admin/approval-policies/{requester}` | 정책 감사 이력 저장 | 사용자별 자동 승인 예외 |

`FORGEJO_BASE_URL`, owner/repository/target branch, bot token 연동이 없으면 생성·상태 변경·삭제는
`503 forgejo-not-configured`로 중단됩니다. 검증과 저장된 목록 조회는 별도 경계입니다.

## 3. 공통 요청 규칙

- JSON body 최대 크기는 64 KiB입니다.
- `Content-Type`은 `application/json`이어야 합니다.
- 알 수 없는 필드와 JSON 객체 뒤의 추가 데이터는 거부합니다.
- 검증 API는 입력을 저장하거나 Forgejo/Kubernetes를 바꾸지 않습니다.
- 오류는 `application/problem+json` Problem Details입니다.

멱등 키 규칙은 생성 종류마다 다릅니다.

| 요청 | `Idempotency-Key` |
| --- | --- |
| AppGroup 생성 | 필수 |
| 일반 단일 앱 생성 | 선택, Portal UI는 항상 전송 |
| OpenBao 실제 값을 포함한 단일 앱 생성 | 필수 |

키는 1~128자의 영문자, 숫자, `.`, `_`, `:`, `-`만 사용합니다. 같은 사용자·키·본문을 다시
보내면 기존 결과를 `200`으로 돌려주고, 같은 키에 다른 본문을 보내면 `409`입니다.

## 4. 단일 앱 검증과 생성

먼저 catalog의 현재 `environment`, project, resource preset을 사용합니다. 사이트 값을 추측해
문서 예제를 그대로 보내지 않습니다.

```bash
curl --request POST \
  --header 'Content-Type: application/json' \
  --data '{
    "appName": "research-viewer",
    "project": "<CATALOG_PROJECT>",
    "environment": "<CATALOG_ENVIRONMENT>",
    "gitRepository": "https://<FORGEJO>/<OWNER>/<REPOSITORY>.git",
    "branch": "main",
    "dockerfile": "Dockerfile",
    "containerPort": 8080,
    "replicas": 1,
    "exposure": {"mode": "external"},
    "authentication": {"mode": "oidc"},
    "networkPolicy": {"egressMode": "web"},
    "resourceSize": "small"
  }' \
  'https://<PORTAL_HOST>/api/v1/app-profiles/validate'
```

검증 응답에는 정규화한 source/service/access/resource, 예상 host와 내부 Service 주소,
OpenBao path, GitOps 다음 단계가 포함됩니다. `classification=openbao`의 실제 값은 응답에 절대
포함되지 않습니다.

실제 생성은 같은 입력을 `POST /api/v1/deployment-requests`로 보냅니다. 서버가 다시 검증하고
통과한 경우 `202 Accepted`와 `Location`을 반환한 뒤 백그라운드 파이프라인을 시작합니다.
일반 사용자 응답은 승인·보안 상태와 source 좌표를 제공하지만 private GitOps PR URL·branch는
제공하지 않습니다.

접근 정책 제약:

- `external + none`: 공개 HTTPS Route
- `external + oidc`: 외부 OIDC 로그인 Route
- `internal + none`: 외부 Route 없이 Service만 생성
- `internal + oidc`: 지원하지 않음
- `web` egress: 인터넷 TCP 80/443 포트 정책이며 도메인 allowlist가 아님

## 5. AppGroup 검증과 생성

입력은 `compose` 원문과 `repository` 중 정확히 하나입니다. Git 주소는 Portal에 구성된 같은
Forgejo HTTPS host만 허용합니다.

```bash
curl --request POST \
  --header 'Content-Type: application/json' \
  --data '{
    "group": "mobility-platform",
    "project": "<CATALOG_PROJECT>",
    "environment": "<CATALOG_ENVIRONMENT>",
    "resourceSize": "small",
    "repository": "https://<FORGEJO>/<OWNER>/<REPOSITORY>.git"
  }' \
  'https://<PORTAL_HOST>/api/v1/app-groups/validate'
```

Git 입력은 기본 branch의 한 commit을 고정하고 루트 Compose/Chart를 우선 탐색합니다. 검증
응답의 `source.revision`을 생성 본문의 `repositoryRevision`으로 다시 보내야 합니다.

주요 제한:

- Compose `build:`와 `environment`는 거부하고 immutable prebuilt image만 받습니다.
- 서비스별 `secretKeys`에는 OpenBao key 이름만 보내며 값은 보내지 않습니다.
- port 없는 서비스는 worker이고 Service/HTTPRoute/수신 대상이 없습니다.
- 앱 간 통신은 송신 `allowedApps`와 수신 `ingress.allowedApps`가 모두 필요합니다.
- named volume은 플랫폼 고정 RWO PVC, replica 1이며 앱 삭제 시 PVC도 삭제됩니다.
- Helm은 제한된 `helm template` 결과를 변환하며 원본 Secret/RBAC/ConfigMap을 적용하지 않습니다.

검증 후 같은 입력에 서비스별 정책과 `repositoryRevision`을 포함하고 필수 `Idempotency-Key`와
함께 `POST /api/v1/app-groups`로 보냅니다. 첫 PR에는 AppGroup Namespace bootstrap도 포함됩니다.

## 6. Secret 입력 차이

단일 앱 `envVars`에서 `classification=openbao`인 항목은 생성 요청 중 Portal이 OpenBao에 직접
쓰며 Git과 신청 저장소에는 key만 남습니다. 이 경우 값과 `Idempotency-Key`가 모두 필요합니다.

AppGroup `services[].secretKeys`는 선언만 합니다. 관리자가 검증 계획의 exact path에 값을 미리
준비해야 하며, 실제 Secret 값을 AppGroup API나 Compose 원문에 보내면 안 됩니다.

## 7. 승인과 보안 검토

모든 새 신청은 `approval.status=pending`, `securityReview.status=pending`으로 durable 저장됩니다.
전역 자동 승인 환경변수는 없으며 기본은 수동 승인입니다.

```text
received → pr-creating → pr-open
                         ├─ 보안 pending: 대기
                         ├─ 보안 rejected: PR close + 자동 반려
                         └─ 보안 passed + 관리자 승인 또는 사용자별 예외
                              → merged → building → deploying → deployed
```

관리자 승인은 보안 상태를 Forgejo에서 다시 확인하고 승인 증거를 fsync한 뒤 worker를 깨웁니다.
반려에는 사유가 필수이며 결정자·시각·자동/수동 여부·사유를 먼저 영속화한 뒤 PR을 닫습니다. 사용자별
자동 승인 예외도 append-only 정책 이력을 남기고 기존 대기 요청에 적용하지만 보안 검사를
우회하지 않습니다.

관리자 보안 반려 응답은 가능한 경우 취약 package, CVE, 수정 버전을 포함합니다. 일반 사용자에게는 보안 감사 상세를 반환하지 않습니다. 사용자는 자신의 source
저장소에서 수정 PR 또는 이슈로 패치한 뒤 다시 신청하며 private 감사 저장소에 접근할 필요가 없습니다.

수동 승인과 사용자별 자동 승인 모두 OpenBao Secret, `OIDC_CLIENT_SECRET`, ESO policy/role의
준비 여부를 승인 조건으로 검사하지 않습니다. Secret 미준비로 승인 API가 409를 반환하거나
`approval.status=pending`을 유지하지 않습니다. 보안 검사 미통과 또는 닫힌/병합된 PR은 계속
승인할 수 없습니다. BFF는 브라우저 역할 헤더를 버리고 Keycloak 세션의 group, realm role,
해당 Portal client role에서 정확한 `platform-admin`을 확인합니다.

승인 기록 저장 뒤 PR 병합 직전에 OpenBao/ESO policy·role·필수 Secret key를 fail-closed로
검사합니다. 실패하면 `approval.status=approved`와 감사정보를 유지하면서 `state=failed`,
`failedFromState=pr-open`과 사용자용 오류 메시지를 저장하고 병합·배포를 중단합니다.
Secret 값이나 내부 오류 상세는 일반 사용자 응답에 포함하지 않습니다.

## 8. 상태와 실행 상태 변경

원시 상태:

```text
received → pr-creating → pr-open → (승인) → merged → building → deploying → deployed
deployed → stopping → stopped → starting → deployed
deployed/stopped/failed → deleting → deleted
```

중지와 재개:

```bash
curl --request PUT --header 'Content-Type: application/json' \
  --data '{"state":"stopped"}' \
  'https://<PORTAL_HOST>/api/v1/deployment-requests/<REQUEST_ID>/runtime-state'

curl --request PUT --header 'Content-Type: application/json' \
  --data '{"state":"running"}' \
  'https://<PORTAL_HOST>/api/v1/deployment-requests/<REQUEST_ID>/runtime-state'
```

중지는 Kubernetes를 직접 scale하지 않습니다. Git values에 replica 0과 외부 노출 비활성을
반영해 Argo가 수렴하게 합니다. Service, 내부 DNS, ConfigMap, ExternalSecret, PVC는 유지하고
쿼터도 계속 예약합니다.

## 9. 소스 자동 갱신

단일 앱이 같은 Forgejo의 branch를 추적하면 Portal은 기본 60초 간격으로 head를 확인합니다.
새 commit마다 `sourceUpdate=true`인 별도 신청과 PR을 만들고 관리자 승인 뒤 commit 고정 build를
실행합니다. build가 만든 immutable image를 PR에 반영하면 새 head의 보안 check를 다시 통과한
뒤에만 merge합니다. 실패 commit은 무한 재시도하지 않으며 진행 중 배포가 끝난 뒤 최신 head로
수렴합니다. 다른 Git host는 최초 one-shot build만 지원합니다.

## 10. 오류 형식

```json
{
  "type": "urn:sadp:portal:problem:validation-error",
  "title": "AppProfile 검증 실패",
  "status": 422,
  "detail": "입력 필드를 수정한 뒤 다시 요청하세요.",
  "errors": [
    {"field": "appName", "message": "허용된 이름을 사용하세요."}
  ]
}
```

| Status | 의미 |
| ---: | --- |
| `400` | JSON/헤더/형식 오류 |
| `401` | 로그인 세션 없음 |
| `403` | role 부족 |
| `409` | 소유권·멱등 키·기존 PVC 계약 충돌 |
| `413` | 64 KiB 초과 |
| `415` | Content-Type 오류 |
| `422` | 필드 또는 정책 검증 실패 |
| `503` | Forgejo/OpenBao 등 필수 연동 미구성 또는 장애 |

API 로그와 장애 보고에는 password, token, cookie, `.env` 원문, private key를 남기지 않습니다.

## 11. 구현 위치와 검증

| 파일 | 책임 |
| --- | --- |
| `backend/routes.go` | 실제 method/path 등록 |
| `backend/openapi.yaml` | 외부 API schema |
| `backend/app_profile.go` | 단일 앱 검증과 계획 |
| `backend/appgroup_api.go` | AppGroup 검증·생성 |
| `backend/deployment_requests.go` | 단일 앱 생성 handler |
| `backend/approval.go` | 보안 검토, 승인·반려, 사용자별 정책과 감사 저장 |
| `backend/runtime_state.go` | 중지·재개 |
| `backend/pipeline.go` | build/PR/Argo 상태 수렴 |
| `ui/` | Auth.js BFF와 화면 |

변경 후 실행합니다.

```bash
cd apps/portal-lite/backend
gofmt -l *.go
go vet ./...
go test ./...

cd ../ui
npm run typecheck
npm run lint
npm run test
npm run build
```

## Portal 배포의 정합성 제약

Portal은 전체 배포에서 활성 프로세스 하나만 허용합니다. 생성·삭제의 그룹 소유권,
누적 쿼터, 삭제 중 신규 유입 차단은 프로세스 로컬 `appMu`에 의존하며, 저장소 색인과
멱등 키는 `store.mu`, 요청 실행은 단일 Forgejo 큐 소비자에 의존합니다.
`replicaCount`는 0(중지) 또는 1, 롤아웃 전략은 `Recreate`여야 합니다.
이는 PVC accessMode와 독립된 정합성 제약입니다. 볼륨 교체나 DB 도입만으로 확장할 수 없으며,
검사와 커밋의 원자성 및 워커 실행 소유권을 프로세스 사이에서 보장한 뒤 다시 감사해야 합니다.
별도 Deployment, 수동 프로세스 실행, 기존 프로세스 종료를 확인하지 않은 강제 Pod 삭제는
Chart 가드가 막지 못합니다. 상세 검사 범위와 알려진 결함은
[동시성 감사](portal-concurrency-audit.md)를 확인합니다.

### OIDC refresh token 회전

Proxy는 보안 헤더만 생성하며 세션 갱신을 수행하지 않습니다. 인증은 서버의 화면·API·액션
게이트가 확인합니다. 동일 refresh token의 동시 갱신과 회전 직후 구 cookie 요청은
프로세스 로컬 coordinator가 병합합니다. 성공 결과는 최대 60초, 맵은 각각 512개로 제한되며
실패는 캐시하지 않습니다. replica 간에는 병합되지 않습니다.
브라우저는 기존 Auth.js session endpoint를 통해 회전된 cookie를 받습니다. 이 호출은
토큰 만료 시각에 맞춰 예약하며 access/refresh token 자체를 session JSON으로 전달하지 않습니다.
실제 IdP 회전 설정은 별도 확인이 필요합니다. 진입점 목록과 시험 근거는
[OIDC 갱신 경합 수정](portal-oidc-refresh.md)을 따릅니다.
