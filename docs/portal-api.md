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
- BFF는 브라우저가 보낸 `X-Portal-User`, `Authorization`, `requester`를 제거합니다.
- Go API의 `X-Portal-User`는 BFF가 세션의 사용자명 또는 subject로 넣는 내부 header입니다.
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

## 7. 상태와 실행 상태 변경

원시 상태:

```text
received → pr-creating → pr-open → merged → building → deploying → deployed
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

## 8. 소스 자동 갱신

단일 앱이 같은 Forgejo의 branch를 추적하면 Portal은 기본 60초 간격으로 head를 확인합니다.
새 commit마다 `sourceUpdate=true`인 별도 신청을 만들고, commit 고정 build 성공 후 immutable
image를 담은 PR을 엽니다. 실패 commit은 무한 재시도하지 않으며 진행 중 배포가 끝난 뒤 최신
head로 수렴합니다. 다른 Git host는 최초 one-shot build만 지원합니다.

## 9. 오류 형식

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

## 10. 구현 위치와 검증

| 파일 | 책임 |
| --- | --- |
| `backend/routes.go` | 실제 method/path 등록 |
| `backend/openapi.yaml` | 외부 API schema |
| `backend/app_profile.go` | 단일 앱 검증과 계획 |
| `backend/appgroup_api.go` | AppGroup 검증·생성 |
| `backend/deployment_requests.go` | 단일 앱 생성 handler |
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
