# 외부 Grafana 연동 안내

> 대상: 클러스터 밖 Grafana에서 SADP의 Prometheus/Loki를 읽는 관리자
> 전제: 통합 설치와 Keycloak 운영이 완료됨

이 기능은 Grafana를 클러스터에 설치하지 않습니다. SADP에는 Prometheus, Loki, Alloy를 설치하고
외부 Grafana가 Envoy Gateway를 통해 읽게 합니다.

## 1. 실제 구조

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
후자를 사용합니다.

## 2. 모니터링 스택 소유권

| 구성 | Argo Application | 역할 |
| --- | --- | --- |
| Prometheus | `prometheus` | 메트릭 수집·15일 보관 |
| Loki | `loki` | SingleBinary, filesystem, 168시간 보관 |
| Alloy | `alloy` | Pod 로그와 RKE2 감사 로그를 Loki로 전송 |

버전은 [versions.lock.yaml](../versions.lock.yaml), 실제 Argo 입력은
`argocd/applications/{prometheus,loki,alloy}.yaml`이 기준입니다. 세 구성 요소는 Argo CD 소유이므로
로컬 `helm upgrade --install`로 설치하지 않습니다.

워커 노드는 외부 Registry egress가 없으므로 통합 설치기의 platform 단계가
`platform/monitoring/images.txt`를 모든 노드 containerd에 동기화한 뒤 Argo rollout을 기다립니다.

```bash
kubectl get applications -n devtroncd prometheus loki alloy
kubectl rollout status -n monitoring deployment/prometheus-server
kubectl rollout status -n monitoring statefulset/loki
kubectl rollout status -n monitoring daemonset/alloy
```

이미지 목록을 바꿀 때는 같은 chart 버전의 `helm template` 결과에서 모든 image를 다시 추출하고
태그가 붙은 참조를 기록합니다. `docker save/import` 경로에서 digest 참조가 유지되지 않을 수 있어
Application values는 `IfNotPresent`와 tag 참조를 사용합니다.

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

## 4. 사이트 입력과 렌더링

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

```bash
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --check
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --write
bash ./sadp --test
```

생성되는 각 서비스에는 HTTPRoute, backend Namespace의 ReferenceGrant,
`<name>-machine-auth` SecurityPolicy가 포함됩니다. JWT client와 출발지 CIDR은 같은 authorization
principal 안에 있어 둘 다 일치해야 합니다.

생성 diff를 검토해 commit/push한 뒤 control-plane에서 cluster phase를 다시 실행합니다.

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env --phase cluster --apply
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
