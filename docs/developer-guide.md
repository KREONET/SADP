# SADP 개발자 가이드

> 대상: SADP에 단일 앱 또는 AppGroup을 배포하는 개발자와 Portal API 연동 개발자
> 구현 기준: `apps/portal-lite`, `charts/app-profile`, `charts/app-group`

화면 사용법은 [사용자 가이드](usage.md), 플랫폼 설치와 장애 처리는
[관리자 가이드](administrator-guide.md)를 사용합니다. 이 문서는 현재 코드가 받는 입력과
제약만 설명합니다.

## 1. 배포 방식 선택

| 대상 | 입력 | 이미지 | 제출 흐름 |
| --- | --- | --- | --- |
| 단일 앱 | HTTPS Git URL, branch/tag, Dockerfile | Portal 파이프라인이 소스 빌드 | 5단계 화면에서 바로 제출 |
| AppGroup | 같은 Forgejo의 Git URL 또는 Compose 원문 | 고정 tag/digest의 기존 이미지 | 구성 확인 후 별도 제출 |

단일 앱은 저장소 루트를 build context로 사용합니다. AppGroup의 Compose `build:`는 받지
않습니다. Helm 가져오기도 원본 리소스를 그대로 적용하지 않고, 안전하게 변환 가능한 단일
컨테이너 Deployment/Service만 AppProfile로 다시 만듭니다.

## 2. 단일 앱 저장소 준비

- URL은 credential, query, fragment가 없는 HTTPS 주소여야 합니다.
- branch 또는 tag와 Dockerfile 상대경로가 실제로 존재해야 합니다.
- Dockerfile 파일명은 `Dockerfile`로 시작해야 합니다.
- 앱 프로세스는 foreground로 실행하고 컨테이너의 `0.0.0.0:<port>`에서 listen합니다.
- 로그는 stdout/stderr로 보냅니다.
- Secret, 개인키, kubeconfig, Registry 인증 파일을 소스나 build arg에 넣지 않습니다.

현재 단일 앱 화면에서 health path나 probe 종류를 입력하지 않습니다. 소스 앱은 플랫폼 기본
`/healthz` 계약을 사용하므로 앱이 해당 경로에서 성공을 반환하도록 준비하는 것이 안전합니다.
Compose의 prebuilt image는 HTTP health 계약이 없으므로 TCP 준비 검사를 사용합니다.

## 3. 정책 입력

세 정책은 독립적으로 정합니다.

| 필드 | 값 | 의미 |
| --- | --- | --- |
| `exposure.mode` | `external` | Service와 외부 HTTPRoute 생성 |
|  | `internal` | Service만 생성하고 외부 URL은 만들지 않음 |
| `authentication.mode` | `none` | Gateway에서 로그인 강제 안 함 |
|  | `oidc` | 외부 Route에 Keycloak 인증 적용 |
| `networkPolicy.egressMode` | `blocked` | DNS와 명시된 앱 연결만 허용 |
|  | `web` | 위 항목과 인터넷 TCP 80/443 허용, 내부 대역 제외 |
|  | `custom` | 위 항목과 검증된 CIDR/port/protocol 규칙 허용 |

`internal + oidc`는 Route가 없어 거부됩니다. `web`은 FQDN 필터가 아니라 포트 정책입니다.
특정 도메인만 허용해야 한다면 현재 Canal/기본 NetworkPolicy만으로는 구현할 수 없습니다.

## 4. 자원과 이미지 규칙

단일 앱은 화면에서 replica 수와 서버가 제공하는 `small` 또는 `medium` preset을 고릅니다.
Portal은 현재 사용자 쿼터를 계산해 초과 요청을 거부합니다.

AppGroup은 모든 서비스에 공통 preset을 적용합니다. Compose/Helm에서 가져온 기존 이미지는
tag 또는 digest가 반드시 있어야 하며 `latest`, `main`, `master`, `stable` 같은 가변 tag는
거부됩니다.

단일 앱 소스 빌드는 commit을 고정하고 kaniko로 이미지를 만든 뒤 immutable image tag를 담은
GitOps Pull Request를 엽니다. 같은 Forgejo 저장소의 추적 branch는 기본 60초마다 확인하며,
새 commit이 있으면 기존 신청을 덮지 않고 `sourceUpdate=true`인 새 신청을 만듭니다. 다른 Git
host의 소스는 최초 one-shot build만 지원합니다.

## 5. 일반 설정과 Secret

단일 앱의 환경변수 분류 화면은 입력을 실제 배포 초안으로 넘깁니다.

| 분류 | 저장 위치 | Git/신청 저장소에 남는 내용 |
| --- | --- | --- |
| `configmap` | GitOps values의 일반 설정 | key와 값 |
| `openbao` | 제출 중 앱 전용 OpenBao 경로 | key만 |

OpenBao 값은 검증 응답과 배포 신청 저장소에 남지 않습니다. 제출이 실패해 다시 시도할 때는
값을 다시 입력해야 할 수 있습니다. 민감한 값을 ConfigMap으로 분류하지 않습니다.

AppGroup은 반대로 `services[].secretKeys`에 key 이름만 받습니다. 실제 값은 검증 결과가 알려
주는 exact OpenBao 경로에 관리자가 미리 준비합니다. Compose `environment`는 평범한 key에
숨은 Secret을 판별할 수 없어 전체를 fail-closed로 거부합니다.

Secret 전달 경로는 항상 다음과 같습니다.

```text
OpenBao → ESO ExternalSecret → Kubernetes Secret → Pod
```

Chart가 `kind: Secret`을 직접 만들거나 Secret 값을 Git values에 쓰는 방식은 허용하지 않습니다.

## 6. 단일 앱 제출

화면 입력은 다음 다섯 단계입니다.

1. 앱 이름, project, 서버가 정한 읽기 전용 environment
2. Git URL, branch/tag, Dockerfile 경로
3. container port, replicas, resource preset
4. exposure, authentication, egress 정책
5. 환경변수 분류와 전체 내용 검토 후 **신청 제출**

화면에는 별도의 단일 앱 검증 버튼이 없습니다. `POST /api/v1/deployment-requests`가 먼저 같은
검증을 수행하고 성공한 경우에만 신청을 저장합니다. API 연동 개발자는 상태 변경이 없는
`POST /api/v1/app-profiles/validate`로 계획을 미리 볼 수 있습니다.

## 7. AppGroup 입력과 제한

Git URL 하나를 입력하면 같은 Forgejo의 기본 branch에서 루트 Compose 또는 `Chart.yaml`을
우선 탐색합니다. 같은 우선순위 후보가 여러 개면 임의로 고르지 않고 `422`로 거부합니다.
검증 응답의 `source.revision`을 생성 요청의 `repositoryRevision`으로 다시 보내 검증과 제출
사이의 branch 변경을 막습니다. Portal UI는 이를 자동 처리합니다.

AppGroup 규칙:

- 이름은 플랫폼 전체에서 유일하며 Namespace는 계약의 접두사와 이름으로 만듭니다.
- `build:`, Compose `environment`, host bind, anonymous volume, external/driver volume은 거부합니다.
- port 없는 서비스는 worker이며 Service, HTTPRoute, 수신 대상이 없습니다.
- 앱 간 연결은 호출 측 `allowedApps`와 수신 측 `ingress.allowedApps` 양쪽에 선언합니다.
- named volume은 플랫폼 고정 StorageClass/크기의 RWO PVC이며 replica는 1입니다.
- named volume 앱을 삭제하면 PVC 데이터도 삭제됩니다.
- privileged, host network, NodePort/LoadBalancer/Ingress, 임의 RBAC는 허용하지 않습니다.

AppGroup 화면은 먼저 **앱 구성 확인**으로 `POST /api/v1/app-groups/validate`를 호출하고, 현재
입력과 검증 결과가 일치할 때만 **배포 신청**으로 `POST /api/v1/app-groups`를 호출합니다.
검증 뒤 입력을 바꾸면 다시 확인해야 합니다.

## 8. API 연동 경계

기계 판독 원본은 [OpenAPI 3.1.1](../apps/portal-lite/openapi.yaml), 사람용 요약은
[Portal API 안내](portal-api.md)입니다.

- 브라우저는 Auth.js 세션을 확인하는 same-origin BFF만 호출합니다.
- BFF는 브라우저가 보낸 `X-Portal-User`, `Authorization`, `requester`를 버리고 세션 신원을 넣습니다.
- 조회는 `deployments:read`, 변경은 `deployments:write` 권한이 필요합니다.
- JSON은 최대 64 KiB이고 알 수 없는 필드를 거부합니다.
- 오류는 `application/problem+json`입니다.
- AppGroup 생성에는 `Idempotency-Key`가 필수입니다.
- 단일 앱 키는 일반 요청에는 선택이며 OpenBao 실제 값이 있으면 필수입니다. Portal UI는 항상 보냅니다.

## 9. 상태, 중지, 삭제

파이프라인 원시 상태는 다음과 같습니다.

```text
received → pr-creating → pr-open → merged → building → deploying → deployed
deployed → stopping → stopped → starting → deployed
deployed/stopped/failed → deleting → deleted
```

중지는 GitOps values의 replica를 0으로 만들고 외부 노출을 끕니다. Service, 내부 DNS,
ConfigMap, ExternalSecret, PVC는 보존하지만 재개 용량을 위해 원래 쿼터를 계속 예약합니다.
삭제는 앱 values와 Argo Application을 제거합니다. 원본 소스와 Registry image 이력은 보존하며,
named volume PVC는 삭제합니다.

## 10. 저장소 개발 검증

Chart/렌더러/문서를 바꾸면 저장소 루트에서 실행합니다.

```bash
bash ./sadp --test
```

Portal API 변경:

```bash
cd apps/portal-lite
gofmt -l *.go
go vet ./...
go test ./...
```

Portal UI 변경:

```bash
cd apps/portal-lite/ui
npm ci
npm run typecheck
npm run lint
npm run test
npm run build
```

파일 머리에 `# Generated by`가 있으면 직접 수정하지 말고 생성 로직과 입력을 고친 뒤 다시
렌더링합니다.

## 11. 장애 전달 정보

| 증상 | 먼저 확인 | 관리자에게 전달 |
| --- | --- | --- |
| `422` | 오류의 field/message와 정책 조합 | Secret을 제거한 입력 구조, Problem type/title |
| build 실패 | branch, commit, Dockerfile 경로 | 신청 ID, commit, 실패 단계 |
| `ImagePullBackOff` | image tag/digest 존재 여부 | Namespace, 앱 이름, Pod event |
| Ready지만 접속 실패 | bind 주소와 container port | URL, 신청 ID, 발생 시각 |
| 내부 통신 실패 | 양방향 allowedApps | 호출/수신 앱과 port |
| Secret 미반영 | key 이름과 ExternalSecret 상태 | 앱/Namespace, key 이름만 |

password, token, private key, `.dockerconfigjson`, 전체 `.env` 값은 전달하지 않습니다.
