# 외부 기계 클라이언트 인증 Runbook

> 대상: 클러스터 밖 Grafana/Wazuh 등에서 SADP 내부 Prometheus·Loki 등의 API를 호출하는 관리자
> 전제: SADP 통합 설치와 production TLS 검증이 완료됨

기계 인증은 사람용 Keycloak SSO와 별도입니다. `MACHINE_AUTH_MODE`를 `keycloak` 또는
`api-key`로 반드시 고르며, 어느 모드를 골라도 Portal·Rancher·OpenBao와 OIDC 앱의 사람 로그인은
기존 Keycloak 설정을 그대로 사용합니다.

## 1. 모드 선택

| 모드 | 기계 클라이언트가 보내는 값 | Gateway 검증 | Secret 원본 |
| --- | --- | --- | --- |
| `keycloak` | `Authorization: Bearer <SHORT_LIVED_JWT>` | issuer/JWKS, `azp`, 출발지 CIDR | Keycloak client secret |
| `api-key` | `X-SADP-API-Key: <CLIENT_API_KEY>` | API key, 출발지 CIDR | OpenBao |

모드를 생략하거나 다른 문자열을 쓰면 렌더링을 중단합니다. `api-key` 모드에서는 client와 CIDR이
비어 있어도 중단하며, 모든 모드에서 `0.0.0.0/0`을 거부합니다.

최초 설치에서 기계 endpoint를 아직 열지 않을 때도 모드는 명시합니다.

```dotenv
MACHINE_AUTH_MODE=keycloak
MACHINE_AUTH_SERVICES=
MACHINE_AUTH_CLIENTS=
MACHINE_AUTH_ALLOWED_CIDRS=
```

## 2. 사이트 설정

`MACHINE_AUTH_SERVICES`는 외부 VM을 클러스터 안으로 가져오는 `EXTERNAL_SERVICES`와 다릅니다.
이미 클러스터에 있는 Service를 기계 클라이언트용 hostname으로 노출합니다.

### Keycloak client_credentials

```dotenv
MACHINE_AUTH_MODE=keycloak
MACHINE_AUTH_SERVICES=metrics=monitoring/prometheus-server:80,logs=monitoring/loki:3100
MACHINE_AUTH_CLIENTS=<GRAFANA_CLIENT_ID>,<WAZUH_CLIENT_ID>
MACHINE_AUTH_ALLOWED_CIDRS=<GRAFANA_CIDR>,<WAZUH_CIDR>
```

### 자동 API 키

```dotenv
MACHINE_AUTH_MODE=api-key
MACHINE_AUTH_SERVICES=metrics=monitoring/prometheus:9090,logs=monitoring/loki:3100
MACHINE_AUTH_CLIENTS=grafana-central,wazuh-connector
MACHINE_AUTH_ALLOWED_CIDRS=<GRAFANA_CIDR>,<WAZUH_CIDR>
```

| 입력 | 제약 |
| --- | --- |
| service | `<name>=<namespace>/<service>:<port>`, 이름 중복 금지 |
| client | Kubernetes 이름 형식, client마다 전용 자격증명 사용 |
| CIDR | Envoy가 실제로 관측하는 IPv4 CIDR, `/0` 금지 |

한 client는 현재 등록한 모든 machine-auth service에 접근합니다. 서비스별 client 목록이 필요하면
현재의 전역 계약을 확장해야 하므로 같은 이름을 재사용해 우회하지 않습니다.

`site.env`에는 client 이름만 쓰고 Keycloak client secret이나 API 키 실제 값은 넣지 않습니다.

## 3. 렌더와 cluster 적용

생성된 계약이나 `platform/exposure/resources.yaml`을 직접 고치지 않습니다.

```bash
sudoedit /etc/sadp/site.env

bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render

bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render \
  --apply

git diff --check
git diff -- contracts platform
bash ./sadp --test
```

diff에는 client 이름, OpenBao 경로, ExternalSecret, Secret 참조만 보여야 합니다. 실제 키, `data`,
`stringData`가 보이면 적용하지 않습니다. 검토 후 사이트 branch에 commit/push하고 control-plane에서
적용합니다.

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase cluster \
  --apply
```

각 service에는 HTTPRoute, ReferenceGrant, `<name>-machine-auth` SecurityPolicy가 생성됩니다.
`api-key` 모드에는 client별 ExternalSecret도 생성됩니다. Chart나 renderer는 Kubernetes `Secret`을
직접 만들지 않습니다.

## 4. Keycloak 모드

각 client를 Keycloak confidential client로 만듭니다.

| 설정 | 값 |
| --- | --- |
| Client authentication | On |
| Standard flow | Off |
| Service accounts roles | On |
| Grant | `client_credentials` |

client ID는 `MACHINE_AUTH_CLIENTS`와 같아야 하고 client secret은 외부 시스템의 Secret 저장소에만
둡니다. SADP는 이 모드에서 API 키를 생성하거나 변경하지 않습니다.

```bash
read -rs -p 'Machine client secret: ' MACHINE_CLIENT_SECRET; echo
TOKEN=$(curl --fail --silent --show-error \
  --request POST 'https://<SSO_HOST>/realms/<REALM>/protocol/openid-connect/token' \
  --data grant_type=client_credentials \
  --data client_id='<CLIENT_ID>' \
  --data-urlencode client_secret="${MACHINE_CLIENT_SECRET}" | jq -r .access_token)
unset MACHINE_CLIENT_SECRET
```

token을 출력하지 말고 시험 후 `unset TOKEN`합니다.

## 5. API-key 모드의 자동 생성과 전달

cluster phase의 `bootstrap-services`가 다음 순서로 client별 256비트 난수 키를 준비합니다.

```text
OpenBao kv/platform/machine-auth/<client>
  → machine-auth-<client> ExternalSecret
    → machine-auth-<client>-api-keys Kubernetes Secret
      → Envoy Gateway SecurityPolicy.apiKeyAuth
```

OpenBao에 `<client>` key가 이미 있으면 그 값을 그대로 사용합니다. 일반 bootstrap 재실행은 키를
회전하지 않습니다. 서로 다른 client에는 서로 다른 키를 생성합니다.

외부 시스템으로 옮길 복사본만 control-plane의 root 전용 파일로 내보냅니다.

```text
/var/lib/sadp/credentials/machine-auth-grafana-central-api-key
/var/lib/sadp/credentials/machine-auth-wazuh-connector-api-key
```

파일은 root 소유 mode `0600`입니다. 스크립트는 값 대신 다음처럼 위치만 출력합니다.

```text
[OK]   grafana-central API 키 준비 완료
[INFO] 전달 파일: /var/lib/sadp/credentials/machine-auth-grafana-central-api-key
```

OpenBao가 영속 원본이고 Kubernetes Secret은 ESO가 만든 공급 사본입니다. Git, contract, Helm
values, ConfigMap에는 키 실제 값이 들어가지 않습니다.

## 6. Grafana 설정

Prometheus와 Loki datasource 각각에 Secure Custom HTTP Header를 설정합니다.

| 항목 | 값 |
| --- | --- |
| Prometheus URL | `https://metrics.<BASE_DOMAIN>` |
| Loki URL | `https://logs.<BASE_DOMAIN>` |
| Header | `X-SADP-API-Key` |
| Value | `grafana-central` 전용 전달 파일의 값 |

Value를 provisioning Git이나 일반 datasource YAML에 평문으로 넣지 않습니다. Grafana의 secure
JSON data 또는 배포 환경의 승인된 Secret 공급 경로를 사용합니다.

Keycloak 모드에서는 같은 URL에 OAuth2 client credentials를 설정하고, API-key header를 함께
보내지 않습니다.

## 7. Wazuh 설정

API-key 모드에서 두 인증 계층은 서로 다른 헤더를 사용하므로 동시에 보낼 수 있습니다.

```http
X-SADP-API-Key: <WAZUH_EDGE_API_KEY>
Authorization: Bearer <SHORT_LIVED_WAZUH_JWT>
```

- `X-SADP-API-Key`는 SADP Envoy Gateway가 검증하고 backend 전달 전에 제거합니다.
- `Authorization`은 건드리지 않으므로 Wazuh 자체 API가 짧은 수명의 JWT를 계속 검증합니다.

Wazuh JWT를 SADP API 키로 대체하거나 장기 저장하지 않습니다.

## 8. 접근 검증

허용된 출발지에서 올바른 키, 잘못된 키, 누락된 키를 각각 시험합니다. API 키를 명령 인자나 shell
history에 넣지 말고 외부 시스템의 secure 설정 또는 mode `0600`인 임시 curl config를 사용합니다.

검증 결과:

- 올바른 키 + 허용 CIDR: backend의 정상 응답
- 누락되거나 잘못된 키: `401`
- 올바른 키 + 허용되지 않은 CIDR: `403`
- backend에서 `X-SADP-API-Key`가 보이면 실패
- Wazuh는 API 키와 `Authorization`을 함께 보냈을 때 자체 API 인증까지 성공해야 함

CIDR은 Envoy가 관측하는 주소를 써야 합니다. NAT나 kube-proxy SNAT 때문에 외부 시스템의 NIC
주소와 다를 수 있으므로 실제 경로에서 반드시 확인합니다.

```bash
kubectl -n <PLATFORM_ROUTE_NAMESPACE> get securitypolicy
kubectl -n <PLATFORM_ROUTE_NAMESPACE> get secretstore,externalsecret
sudo bash ./sadp --verify-testbed
```

검수 스크립트는 Secret의 key 이름과 Ready 상태만 보고 값을 출력하지 않습니다.

## 9. API 키 회전

일반 bootstrap은 회전하지 않습니다. client 하나를 명시한 운영 명령만 회전을 시작합니다.

### 9.1 신규 키 병행 반영

```bash
sudo bash ./sadp --rotate-machine-api-key grafana-central
```

이 명령은 신규 키를 `<client>-next`로 OpenBao에 추가하고 ESO/Gateway가 active와 next를 모두
받았는지 확인한 뒤, root-only 전달 파일을 신규 값으로 갱신합니다. 같은 명령을 다시 실행해도
이미 준비한 next를 다시 만들지 않습니다. 기존 키는 아직 유효합니다.

### 9.2 외부 시스템 적용과 연결 성공 확인

전달 파일의 신규 값을 Grafana/Wazuh secure 설정에 반영하고 8절의 실제 연결 시험을 통과시킵니다.
이 단계가 실패하면 승격하지 않습니다.

준비를 취소하려면 다음을 실행합니다.

```bash
sudo bash ./sadp --rotate-machine-api-key grafana-central --abort
```

### 9.3 신규 키 승격과 기존 키 폐기

연결 성공을 직접 확인한 뒤 그 사실을 명시적으로 승인합니다.

```bash
sudo bash ./sadp --rotate-machine-api-key grafana-central \
  --promote \
  --confirm-connected
```

스크립트는 신규 키만 active로 남기고 ESO/Gateway 수렴을 확인한 다음, 이전 키가 들어 있던 OpenBao
KV 버전을 destroy합니다. `--confirm-connected` 없이 이전 키를 폐기할 수 없습니다.

## 10. 운영 제약

- `MACHINE_AUTH_SERVICES`는 backend Namespace나 Service를 만들지 않습니다.
- Prometheus/Loki에는 클러스터 메타데이터와 로그가 있으므로 `defaultAction: Deny`를 유지합니다.
- API-key에서 Keycloak으로 바꿔도 사람 SSO 설정은 바뀌지 않습니다. 남은 API 키를 일반 bootstrap이
  자동 회전하거나 임의 삭제하지도 않습니다.
- Keycloak에서 API-key로 바꾸면 cluster phase가 client별 키를 최초 한 번만 생성합니다.
- Loki의 단일 replica/local-path 구성은 테스트베드 설정입니다.
