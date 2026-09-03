# Rancher 구현·검수 안내

> 대상: Rancher Application, Gateway Route, Project/RBAC을 진단하는 관리자
> 정상 설치: [통합 설치](../../docs/installation.md)

Rancher는 현재 RKE2 클러스터 안에 설치되어 같은 클러스터의 `local` 항목을 관리합니다. 별도
import token이나 cluster registration 명령은 필요하지 않습니다.

## 1. 현재 배포 계약

- 버전은 [versions.lock.yaml](../../versions.lock.yaml)의 `platform.rancher`가 기준입니다.
- Argo Application은 `argocd/applications/rancher.yaml`입니다.
- chart는 `ingress.enabled=false`, `tls=external`입니다.
- 외부 진입점은 Envoy Gateway 하나뿐입니다.
- 기본 replica 수와 hostname은 사이트 계약에서 생성됩니다.

Rancher/Kubernetes 지원 조합은 배포 전 공식 support matrix에서 확인합니다. 버전 문제를
해결하려고 Application `targetRevision`을 임의로 최신으로 바꾸지 않습니다.

## 2. 외부 경로

Envoy Gateway가 wildcard TLS를 종료하고 Rancher Service로 HTTP를 전달합니다. Rancher는
`X-Forwarded-Proto: https`를 받아 public URL과 websocket redirect를 구성합니다.

HTTPRoute는 계약의 `gateway.redirectRouteNamespace`, backend Service는 `cattle-system`에 있어
ReferenceGrant가 함께 필요합니다. Gateway의 실제 Namespace, 이름, listener, hostname을 문서
예제에서 추측하지 말고 계약과 생성된 `platform/exposure/resources.yaml`에서 확인합니다.

```bash
kubectl get application -n devtroncd rancher
kubectl rollout status -n cattle-system deployment/rancher
kubectl get httproute -A | grep rancher
kubectl get referencegrant -n cattle-system
```

Rancher Ingress나 `rke2-ingress-nginx`가 존재하면 단일 진입점 계약 위반입니다.

## 3. Project와 RBAC 생성

`scripts/site/render-rancher.py`가 계약 `spec.rancher`에서
`platform/rancher/resources.yaml`을 생성합니다.

- Project는 항상 렌더링합니다.
- role binding은 해당 Rancher `principal`이 `pending`이 아닐 때만 렌더링합니다.
- subject는 개인 계정이 아니라 Rancher UI/API에서 확인한 외부 IdP group principal입니다.
- Rancher 내장 GlobalRole/RoleTemplate만 사용합니다.
- Project 이름이 workload Namespace와 같으면 Rancher backing Namespace와 충돌하므로 거부합니다.

현재 계약의 Project 이름·대상 Namespace·group이 기준입니다. 과거 예시 이름을 문서나 수동
명령에 고정하지 않습니다.

기본 역할 매핑:

| SADP 역할 | Rancher 범위 | 내장 역할 |
| --- | --- | --- |
| `platform-admin` | global | `admin` |
| `app-admin` | project | `project-owner` |
| `developer` | project | `project-member` |
| `viewer` | project | `read-only` |

사용자를 Rancher UI에서 별도로 binding하면 Git 계약과 드리프트가 생깁니다. 외부 IdP group
membership과 계약을 수정한 뒤 renderer를 실행합니다.

## 4. 생성과 동기화 확인

사이트 입력이 있는 운영 checkout:

```bash
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --write
python3 scripts/site/render-rancher.py --check
bash scripts/ci-guard.sh
```

계약 생성 로직 개발 checkout:

```bash
python3 scripts/site/render-rancher.py
python3 scripts/site/render-rancher.py --check
bash ./sadp --test
```

생성된 `resources.yaml`을 직접 편집하지 않습니다.

## 5. bootstrap 관리자 계정

초기 bootstrap Secret은 Git에 넣지 않습니다. 첫 로그인 후 approved password manager의 값으로
관리자 password를 바꾸고 break-glass 계정으로 제한합니다.

```bash
kubectl -n cattle-system get secret bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}'
```

명령 출력은 자격증명이므로 화면 공유·shell log·issue에 남기지 않습니다. SSO 장애 시 복구할 수
있도록 break-glass 절차와 접근자를 별도로 관리합니다.

## 6. 검수

```bash
sudo bash ./sadp --verify-d6
```

검수 스크립트는 다음을 확인합니다.

- Rancher Deployment와 `local` cluster Ready
- Rancher Ingress 및 bundled ingress-nginx 부재
- Envoy 밖의 LoadBalancer Service 부재
- `server-url=https://<RANCHER_HOST>`
- HTTPRoute Accepted/ResolvedRefs와 VIP 응답
- Project 존재와 Namespace project annotation
- group이 확정된 경우 RBAC binding

group이 아직 `pending`이면 RBAC는 실패가 아니라 `[SKIP]`으로 표시됩니다. `verify-d6.sh`의 호스트
도구는 현재 control-plane 노드만 검사합니다.

## 7. 대표 장애

| 증상 | 확인 |
| --- | --- |
| `local`이 Provisioning | RKE2/Rancher support matrix, Rancher logs |
| `http://` redirect | Gateway의 `X-Forwarded-Proto`, `server-url` |
| Route `ResolvedRefs=False` | `cattle-system` ReferenceGrant와 Service port |
| Project 없음 | `platform-resources` Application sync, generated resources |
| SSO 사용자는 로그인되나 권한 없음 | 계약 principal, 외부 IdP membership, rendered binding |
| UI 수동 권한이 다시 달라짐 | UI grant 제거 후 계약 기반 group binding 사용 |
