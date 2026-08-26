# 설치 완료 후 외부 Grafana 연동 Runbook

> 대상: 클러스터 밖 Grafana에서 SADP의 Prometheus/Loki를 읽는 관리자
> 전제: SADP 통합 설치, production TLS, Keycloak 운영과 acceptance가 모두 완료됨

이 절차는 **신규 설치 때 Grafana 연동값을 미리 넣는 절차가 아닙니다.** 기본 SADP 설치를 먼저
완료한 뒤 `site.env`를 갱신하고 생성물과 cluster phase를 다시 적용해 연동 경로를 추가합니다.
Grafana 자체는 SADP 클러스터에 설치하지 않으며 별도 VM의 Grafana가 준비돼 있어야 합니다.

> [!IMPORTANT]
> 여기서 "재패치"는 생성된 YAML이나 클러스터 리소스를 직접 `kubectl patch`한다는 뜻이 아닙니다.
> `/etc/sadp/site.env` 갱신 → render → diff 검토와 commit/push → cluster phase 재적용 순서를
> 사용합니다. 생성된 `contracts/platform-production.yaml`과 `platform/exposure/resources.yaml`을
> 손으로 고치면 다음 render에서 되돌아갑니다.

## 1. 추가 시점과 전체 순서

최초 설치에서는 다음 세 값을 비워 둡니다.

```dotenv
MACHINE_AUTH_SERVICES=
MACHINE_AUTH_CLIENTS=
MACHINE_AUTH_ALLOWED_CIDRS=
```

설치 가이드의 9단계와 인수인계까지 마친 뒤 다음 순서로 연동합니다.

```text
기본 SADP 설치 완료
  → Prometheus/Loki/Alloy Ready 확인
  → 외부 Grafana용 Keycloak client 생성
  → 기존 site.env의 machine-auth 3개 값 갱신
  → render/test/commit/push
  → control-plane에서 cluster phase 재적용
  → Grafana datasource 등록과 접근 검증
```

먼저 기존 설치가 정상인지 확인합니다.

```bash
kubectl get applications -n devtroncd prometheus loki alloy
kubectl rollout status -n monitoring deployment/prometheus-server
kubectl rollout status -n monitoring statefulset/loki
kubectl rollout status -n monitoring daemonset/alloy
sudo bash ./sadp --verify-testbed
```

세 workload 중 하나라도 준비되지 않았으면 Grafana 패치를 진행하지 않고 기본 설치를 먼저
복구합니다.

### 모니터링 스택 소유권

| 구성 | Argo Application | 역할 |
| --- | --- | --- |
| Prometheus | `prometheus` | 메트릭 수집·15일 보관 |
| Loki | `loki` | SingleBinary, filesystem, 168시간 보관 |
| Alloy | `alloy` | Pod 로그와 RKE2 감사 로그를 Loki로 전송 |

버전은 [versions.lock.yaml](../versions.lock.yaml), 실제 Argo 입력은
`argocd/applications/{prometheus,loki,alloy}.yaml`이 기준입니다. 세 구성 요소는 Argo CD 소유이므로
로컬 `helm upgrade --install`로 설치하지 않습니다.

워커 노드는 외부 Registry egress가 없으므로 최초 통합 설치기의 cluster 단계가 Squid를 먼저
검증하고 `platform/monitoring/images.txt`를 모든 노드 containerd에 선배포한 뒤 Devtron·Argo
Application을 만듭니다. platform 단계는 Prometheus/Loki/Alloy rollout을 확인합니다. Grafana
사후 연동을 위해 이 chart들을 다시 설치하지 않습니다.

이미지 목록을 바꿀 때는 같은 chart 버전의 `helm template` 결과에서 모든 image를 다시 추출하고
태그가 붙은 참조를 기록합니다. `docker save/import` 경로에서 digest 참조가 유지되지 않을 수 있어
Application values는 `IfNotPresent`와 tag 참조를 사용합니다.

## 2. 실제 구조

```text
외부 Grafana
  ├─ Keycloak client_credentials로 짧은 수명의 JWT 발급
  └─ Authorization: Bearer <JWT>
       → Envoy Gateway SecurityPolicy
          ├─ issuer/JWKS 서명 검증
          ├─ azp가 허용 client인지 검증
          └─ Envoy가 본 출발지 CIDR 검증
             → Prometheus 또는 Loki Service
```

`EXTERNAL_SERVICES`는 외부 VM 서비스를 SADP 안으로 노출하는 입력이고,
`MACHINE_AUTH_SERVICES`는 외부 기계 클라이언트가 SADP 내부 backend를 읽는 입력입니다. Grafana는
후자를 사용합니다. 외부 Grafana 자체를 Envoy 뒤에 공개하려는 경우에만 `EXTERNAL_SERVICES`를
별도로 사용하며, datasource가 Prometheus/Loki를 읽는 데에는 필요하지 않습니다.

## 3. Keycloak 기계 client

외부 Grafana 전용 confidential client를 만듭니다.

| 설정 | 값 |
| --- | --- |
| Client authentication | On |
| Standard flow | Off |
| Service accounts roles | On |
| Grant | `client_credentials` |

client ID는 site.env의 허용 목록에 넣지만 client secret은 외부 Grafana의 Secret 저장소에만
보관합니다. Git, site.env, Kubernetes manifest에 넣지 않습니다. 발급 token의 `iss`는 계약의
Keycloak issuer와 같고 `azp`는 client ID와 같아야 합니다.

```bash
read -rs -p 'Grafana client secret: ' GRAFANA_CLIENT_SECRET; echo
TOKEN=$(curl --fail --silent --show-error \
  --request POST 'https://<SSO_HOST>/realms/<REALM>/protocol/openid-connect/token' \
  --data grant_type=client_credentials \
  --data client_id='<GRAFANA_CLIENT_ID>' \
  --data-urlencode client_secret="${GRAFANA_CLIENT_SECRET}" | jq -r .access_token)
unset GRAFANA_CLIENT_SECRET
```

`TOKEN`을 terminal log나 issue에 출력하지 않고 검증이 끝나면 `unset TOKEN`합니다.

## 4. 설치 완료 후 사이트 재패치

### 4.1 기존 site.env 갱신

세 값을 모두 비우면 기능이 생성되지 않습니다. 켤 때는 모두 함께 설정합니다.

```dotenv
MACHINE_AUTH_SERVICES=metrics=monitoring/prometheus-server:80,logs=monitoring/loki:3100
MACHINE_AUTH_CLIENTS=<GRAFANA_CLIENT_ID>
MACHINE_AUTH_ALLOWED_CIDRS=<ENVOY가_보는_GRAFANA_출발지_IPV4>/32
```

| 입력 | 제약 |
| --- | --- |
| 서비스 | `<name>=<namespace>/<service>:<port>`, 이름 중복 금지 |
| client | Kubernetes 이름 형식, token `azp`와 비교 |
| CIDR | IPv4 CIDR, `0.0.0.0/0` 금지 |

기존 `/etc/sadp/site.env`를 `sudoedit`로 열어 빈 세 값을 위 값으로 바꿉니다. client secret은
넣지 않습니다. 실제 출발지 주소는 Grafana VM의 설정값이 아니라 Envoy가 관측하는 주소를
사용해야 합니다.

```bash
sudoedit /etc/sadp/site.env
```

### 4.2 읽기 전용 계획과 생성물 검토

사이트 branch의 깨끗한 checkout에서 먼저 읽기 전용 계획을 확인합니다.

```bash
git status --short
bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render
```

문제가 없으면 생성물을 다시 렌더링합니다. 이 단계는 클러스터를 변경하지 않습니다.

```bash
bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render \
  --apply

git diff --check
git diff -- contracts apps argocd platform rke
bash ./sadp --test
```

생성되는 각 서비스에는 HTTPRoute, backend Namespace의 ReferenceGrant,
`<name>-machine-auth` SecurityPolicy가 포함됩니다. JWT client와 출발지 CIDR은 같은 authorization
principal 안에 있어 둘 다 일치해야 합니다.

생성 diff에 Secret 값이나 의도하지 않은 사이트 설정 변경이 없는지 검토한 뒤 기존 사이트 branch에
commit/push합니다. live 리소스를 먼저 수동 패치하지 않습니다.

### 4.3 control-plane에서 cluster phase 재적용

commit/push가 끝난 checkout에서 먼저 적용 계획을 확인하고 같은 cluster phase를 재실행합니다.

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase cluster

sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase cluster \
  --apply
```

cluster phase는 기존 리소스를 멱등적으로 다시 확인하고 새 HTTPRoute·ReferenceGrant·SecurityPolicy를
적용합니다. NIC/RKE2 설정은 바뀌지 않으므로 `--phase node`, 노드 drain, RKE2 재시작은 하지
않습니다.

```bash
kubectl get httproute,referencegrant -A
kubectl get securitypolicy -A
```

## 5. Grafana 데이터소스

Prometheus 예:

| 항목 | 값 |
| --- | --- |
| URL | `https://metrics.<BASE_DOMAIN>` |
| Token URL | `https://<SSO_HOST>/realms/<REALM>/protocol/openid-connect/token` |
| Grant | OAuth2 client credentials |
| Client ID | 허용 목록의 전용 ID |
| Client Secret | 외부 Grafana Secret 저장소의 값 |

Loki는 URL을 `https://logs.<BASE_DOMAIN>`으로 바꾸고 같은 인증을 사용합니다. Grafana가 datasource
OAuth2 client credentials를 지원하지 않으면 token 수명보다 짧은 주기로 갱신하는 서버 측
Authorization header 구성이 필요합니다. 정적 장기 token을 Git에 넣는 방식은 사용하지 않습니다.

## 6. 검증

허용 출발지에서 다음 순서로 확인합니다.

```bash
# token 없음: 401 또는 403
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  'https://metrics.<BASE_DOMAIN>/-/ready'

# 앞 절에서 받은 token: 200
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  --header "Authorization: Bearer ${TOKEN}" \
  'https://metrics.<BASE_DOMAIN>/-/ready'

unset TOKEN
```

같은 token을 허용하지 않은 출발지에서도 시험해 `403`인지 확인합니다. `200`이면 경계 NAT나
kube-proxy SNAT 때문에 Envoy가 보는 주소가 달라졌는지 조사합니다.

중요한 네트워크 제약:

- `nat` 모드는 Envoy가 Grafana 대신 경계 장비 주소를 볼 수 있습니다.
- `direct` 모드는 Envoy Service가 `externalTrafficPolicy: Cluster`라 원본 IP가 노드 주소로 SNAT될
  수 있습니다.
- 따라서 CIDR은 독립 인증 수단이 아니라 JWT에 더하는 보조 조건입니다. 실제 경로에서 반드시
  시험하고 원본 IP 보존이 필수면 mTLS 등 별도 설계를 사용합니다.

## 7. Alloy와 감사 로그

Alloy는 모든 노드에서 DaemonSet으로 실행해 Pod 로그를 Loki에 보내고, control-plane의
`/var/lib/rancher/rke2/server/logs/audit.log`도 읽습니다. 감사 파일이 root 전용이므로 Alloy는
root로 실행하되 hostPath는 read-only, root filesystem은 read-only입니다.

감사 로그에는 Secret/ConfigMap을 제외한 다른 리소스의 요청 본문이 포함될 수 있습니다. Loki의
감사 로그 조회 권한을 일반 앱 로그와 같은 수준으로 열지 않습니다.

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy -o wide
kubectl -n monitoring logs daemonset/alloy --tail=100
```

## 8. 운영 제약

- machine client 하나를 허용 목록에 넣으면 현재 등록한 모든 machine-auth 서비스에 접근합니다.
- `MACHINE_AUTH_SERVICES`는 backend Namespace/Service를 만들지 않습니다.
- Prometheus/Loki endpoint에는 cluster 메타데이터와 로그 본문이 있으므로 `defaultAction: Deny`를
  유지합니다.
- Loki의 `useTestSchema: true`, 단일 replica, local-path storage는 테스트베드 설정입니다.
- chart/version/image를 올릴 때 Argo Application, `versions.lock.yaml`, image 목록을 함께 바꿉니다.
