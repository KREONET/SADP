# 외부 기계 클라이언트 인증 Runbook

> 대상: 클러스터 밖 Grafana/Wazuh 등에서 SADP 내부 Prometheus·Loki 등의 API를 호출하는 관리자
> 전제: SADP 통합 설치와 production TLS 검증이 완료됨

클러스터 밖의 Grafana·Wazuh 같은 프로그램이 SADP 내부 API를 호출하도록 연결하는 절차입니다.
프로그램은 브라우저 로그인 화면을 조작할 수 없으므로 전용 인증 수단을 사용합니다.
이를 이 문서에서는 **기계 인증(machine auth)**이라고 부릅니다.

진행 순서는 **인증 방식 선택 → 허용할 서비스·프로그램·출발지 주소 설정 → 생성·적용 →
외부 프로그램에 자격증명 전달 → 실제 연결 시험**입니다. SADP 쪽 설정과 검수는 control-plane에서,
Grafana·Wazuh 설정과 요청 시험은 해당 외부 시스템에서 수행합니다.

`MACHINE_AUTH_MODE`는 `oidc` 또는 `api-key`를 선택합니다. 이 선택은 사람의 조직 로그인과 별개이며,
Portal·Rancher·OpenBao와 OIDC 앱은 기존 외부 IdP 로그인을 계속 사용합니다.
용어는 [기본 개념](concepts.md), `kubectl` 준비는 [설치 가이드](installation.md#실행-위치-확인)를 참고하세요.

## 1. 모드 선택

외부 프로그램이 IdP에서 짧은 수명의 JWT를 발급받아 갱신할 수 있으면 `oidc`를 검토합니다.
전용 HTTP 헤더에 키를 넣는 방식이면 `api-key`를 사용합니다. 두 방식 모두 인증값뿐 아니라
Gateway가 실제로 보는 출발지 IP 범위(CIDR)도 확인합니다.

| 모드 | 기계 클라이언트가 보내는 값 | Gateway 검증 | Secret 원본 |
| --- | --- | --- | --- |
| `oidc` | `Authorization: Bearer <SHORT_LIVED_JWT>` | issuer/JWKS, `azp`, 출발지 CIDR | 외부 OIDC IdP client secret |
| `api-key` | `X-SADP-API-Key: <CLIENT_API_KEY>` | API key, 출발지 CIDR | OpenBao |

모드를 생략하거나 다른 문자열을 쓰면 렌더링을 중단합니다. `api-key` 모드에서는 client와 CIDR이
비어 있어도 중단하며, 모든 모드에서 `0.0.0.0/0`을 거부합니다.

최초 설치에서 기계 endpoint를 아직 열지 않을 때도 모드는 명시합니다.

```dotenv
MACHINE_AUTH_MODE=oidc
MACHINE_AUTH_SERVICES=
MACHINE_AUTH_CLIENTS=
MACHINE_AUTH_ALLOWED_CIDRS=
```

## 2. 사이트 설정

`MACHINE_AUTH_SERVICES`는 외부 VM을 클러스터 안으로 가져오는 `EXTERNAL_SERVICES`와 다릅니다.
이미 클러스터에 있는 Service를 기계 클라이언트용 hostname으로 노출합니다.

### 외부 OIDC IdP client_credentials

```dotenv
MACHINE_AUTH_MODE=oidc
MACHINE_AUTH_SERVICES=metrics=monitoring/prometheus-server:80,logs=monitoring/loki:3100
MACHINE_AUTH_CLIENTS=<GRAFANA_CLIENT_ID>,<WAZUH_CLIENT_ID>
MACHINE_AUTH_ALLOWED_CIDRS=<GRAFANA_CIDR>,<WAZUH_CIDR>
```

### 자동 API 키

```dotenv
MACHINE_AUTH_MODE=api-key
MACHINE_AUTH_SERVICES=metrics=monitoring/prometheus-server:80,logs=monitoring/loki:3100
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

`site.env`에는 client 이름만 쓰고 외부 OIDC IdP client secret이나 API 키 실제 값은 넣지 않습니다.

### CIDR과 source IP 사전 판정

주소를 입력하기 전에 허용 범위를 명시적으로 결정합니다. 한 호스트만 허용하면 `<IPv4>/32`, 같은
네트워크 전체를 허용할 때만 `<NETWORK>/<PREFIX>`를 사용합니다. 편의를 위해 호스트 주소를 `/24`로
넓히지 않으며 `0.0.0.0/0`은 renderer가 거부합니다.

Envoy access log에서 `downstream_remote_address`와 `x-forwarded-for`를 함께 확인합니다.
`X-Forwarded-For`는 신뢰 가능한 프록시 경계를 따로 구성한 경우에만 인증 근거로 사용하고, 외부
클라이언트가 임의로 넣을 수 있는 기본 환경에서는 `downstream_remote_address`를 기준으로 합니다.

- `externalTrafficPolicy: Cluster` 때문에 Pod CIDR이나 Node IP로 SNAT되면 실제 외부 CIDR 인증을
  진행하지 않습니다.
- `direct`는 `PUBLIC_IP_NODE`에 공인 IP 보유 Node 이름을 넣습니다. renderer가 Envoy Pod를 그
  Node에 고정하고 Service를 `externalTrafficPolicy: Local`로 만듭니다.
- `Local` 적용 뒤에는 Envoy Pod의 Node, Ready 조건, Service EndpointSlice의 `nodeName`과
  `conditions.ready`를 확인합니다. 다른 Node에 있거나 endpoint가 없으면 외부 트래픽은 DROP됩니다.
- `nat`는 클라이언트 NIC 주소가 아니라 경계 NAT 이후 Envoy가 관측한 출발지 주소로 CIDR을 정합니다.

공인 IP 보유 여부는 해당 Node 자체에서 확인합니다. `verify-testbed`의 host 검사는 control-plane 한
대만 보므로 worker의 NIC를 대신 검증했다고 기록하지 않습니다.

```bash
ip -brief address show <EXTERNAL_INTERFACE> | grep -F '<PUBLIC_IP>'
kubectl get pod,svc,endpointslice -n envoy-gateway-system -o wide
```

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

## 4. 외부 OIDC IdP 모드

각 client를 외부 OIDC IdP confidential client로 만듭니다.

| 설정 | 값 |
| --- | --- |
| Client authentication | On |
| Standard flow | Off |
| Service accounts roles | On |
| Grant | `client_credentials` |

client ID는 `MACHINE_AUTH_CLIENTS`와 같아야 하고 client secret은 외부 시스템의 Secret 저장소에만
둡니다. SADP는 이 모드에서 API 키를 생성하거나 변경하지 않습니다.

client secret은 시험을 실행하는 시스템의 본인 전용 파일(`0600`)에 준비합니다.
아래 `<CLIENT_SECRET_FILE>`은 해당 파일 경로입니다. curl이 파일을 읽도록 해 실제 값을 명령 인자에
넣지 않습니다. `TOKEN`은 응답을 메모리에 담는 Bash 변수이며 출력하지 않습니다.

```bash
TOKEN=$(curl --fail --silent --show-error \
  --request POST 'https://<SSO_HOST>/realms/<REALM>/protocol/openid-connect/token' \
  --data grant_type=client_credentials \
  --data client_id='<CLIENT_ID>' \
  --data-urlencode 'client_secret@<CLIENT_SECRET_FILE>' | jq -r .access_token)
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

Header 이름은 정확히 `X-SADP-API-Key`여야 합니다. 앞뒤 공백, 따옴표, 대소문자 오타를 검사하고
`" X-SADP-API-Key"`처럼 앞에 공백이 있는 기존 행은 수정하지 말고 삭제 후 다시 만듭니다. Go HTTP
client의 `invalid header field name`은 API 키나 Gateway 오류가 아니라 잘못된 Header 이름입니다.

저장 후 datasource의 URL과 실제 경로를 각각 확인합니다.

| datasource | URL | 반드시 성공할 경로 |
| --- | --- | --- |
| Prometheus | `https://metrics.<BASE_DOMAIN>` | `/api/v1/query`, `/api/v1/status/buildinfo` |
| Loki | `https://logs.<BASE_DOMAIN>` | `/ready`, `/loki/api/v1/query` |

Loki 요청이 `metrics` host로 전달되어 `via_upstream / 404`가 나오면 인증 성공으로 판정하지 않습니다.
Prometheus/Loki URL이 뒤바뀐 설정입니다.

외부 OIDC IdP 모드에서는 같은 URL에 OAuth2 client credentials를 설정하고, API-key header를 함께
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

## 8. 실연결 수락시험

허용된 출발지에서 올바른 키, 잘못된 키, 누락된 키를 각각 시험합니다. API 키를 명령 인자나 shell
history에 넣지 말고 외부 시스템의 secure 설정 또는 mode `0600`인 임시 curl config를 사용합니다.

다음 항목은 HTTP status만 기록하지 않고 같은 요청의 Envoy access log와 함께 판독합니다.

1. Header 없음 → `401`
2. 임시로 만든 잘못된 키 → `401`
3. 올바른 키를 허용 CIDR 밖에서 전송 → `403`
4. 올바른 키를 실제 Grafana/Wazuh 출발지에서 전송 → `200`
5. Prometheus `/api/v1/query` → `200`
6. Prometheus `/api/v1/status/buildinfo` → `200`
7. Loki `/ready` → `200`
8. Loki `/loki/api/v1/query`가 `logs` authority로 전달됨
9. 실제 외부 출발지 IP가 `downstream_remote_address`에 보임
10. 모든 machine-auth SecurityPolicy `Accepted=True`
11. machine-auth SecretStore와 모든 ExternalSecret `Ready=True`
12. backend에서 `X-SADP-API-Key`가 제거됨
13. 준비 명령을 다시 실행해도 credential 파일 hash가 유지됨
14. `sudo bash ./sadp --verify-portal-auth`로 사람용 외부 OIDC IdP 로그인이 유지됨

Wazuh는 `X-SADP-API-Key`와 짧은 수명의 `Authorization: Bearer ...`를 동시에 보낸 실제 API
요청까지 성공해야 합니다. API 키만 통과하고 Wazuh 자체 JWT 검증이 실패하면 완료가 아닙니다.

Envoy 로그에서는 다음 필드를 한 요청 단위로 같이 봅니다.

```text
response_code, response_code_details, downstream_remote_address,
x-forwarded-for, :authority, x-envoy-origin-path, user-agent
```

각 요청에 키 값이 없는 고유 User-Agent marker를 넣고 control-plane에서 allowlist된 로그 필드만
추출할 수 있습니다.

```bash
sudo bash ./sadp --inspect-machine-auth-log sadp-ma-grafana-prom-query-01 --since 15m
```

| 판독 | 의미 |
| --- | --- |
| `missing_api_key / 401` | 클라이언트가 Header를 보내지 않음 |
| `unknown_api_key / 401` | Header는 있으나 API 키가 다름 |
| `rbac_access_denied / 403` | 키는 통과했지만 관측된 CIDR이 거부됨 |
| `via_upstream / 404` | 인증은 통과했지만 host/path/backend가 잘못됨 |
| `via_upstream / 200` | 인증·CIDR·routing이 모두 성공 |

API 키 값은 명령 인자에 두지 않습니다. curl을 직접 쓸 때도 root-only 파일을 읽어 stdin으로 만든
임시 config를 사용하고, config와 결과 본문은 시험 직후 제거합니다. access log나 shell trace에
Header 값을 추가하는 디버그 옵션을 사용하지 않습니다.

일반 bootstrap의 멱등성은 hash 자체를 출력하지 않고 비교합니다.

```bash
before_grafana=$(sudo sha256sum /var/lib/sadp/credentials/machine-auth-grafana-central-api-key | cut -d' ' -f1)
before_wazuh=$(sudo sha256sum /var/lib/sadp/credentials/machine-auth-wazuh-connector-api-key | cut -d' ' -f1)
sudo bash ./sadp --bootstrap-services
after_grafana=$(sudo sha256sum /var/lib/sadp/credentials/machine-auth-grafana-central-api-key | cut -d' ' -f1)
after_wazuh=$(sudo sha256sum /var/lib/sadp/credentials/machine-auth-wazuh-connector-api-key | cut -d' ' -f1)
test "${before_grafana}" = "${after_grafana}"
test "${before_wazuh}" = "${after_wazuh}"
unset before_grafana before_wazuh after_grafana after_wazuh
```

```bash
kubectl -n <PLATFORM_ROUTE_NAMESPACE> get securitypolicy
kubectl -n <PLATFORM_ROUTE_NAMESPACE> get secretstore,externalsecret
sudo bash ./sadp --verify-testbed
```

검수 스크립트는 SecretStore/ExternalSecret/SecurityPolicy와 direct 모드의 Pod·Service endpoint를
검사하지만 외부 host에서 나간 요청을 대신 만들 수는 없습니다. 1–9와 backend Header 제거는 실제
Grafana/Wazuh 경로에서 검증하고 해당 access log를 evidence로 남깁니다. Secret의 key 이름만 보고
값은 출력하지 않습니다.

최종 수락 전에 저장소의 실제 진입점과 호환 진입점을 모두 실행할 수 있습니다.

```bash
bash ./kisti-RKE --test
sudo bash ./kisti-RKE --verify-testbed
```

최종 보고에는 mode, client 이름, 허용 CIDR, credential 파일 위치/권한, SecurityPolicy/ESO 상태,
실제 client IP, 각 요청의 HTTP status, hash 유지 여부, 남은 운영 제약만 기록합니다. API 키·JWT·
Secret 본문과 hash 값은 보고서에 넣지 않습니다.

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
  노출할 내부 서비스는 먼저 설치돼 있어야 합니다.
- Prometheus/Loki에는 클러스터 메타데이터와 로그가 있으므로 `defaultAction: Deny`를 유지합니다.
- API-key에서 외부 OIDC IdP으로 바꿔도 사람 SSO 설정은 바뀌지 않습니다. 남은 API 키를 일반 bootstrap이
  자동 회전하거나 임의 삭제하지도 않습니다.
- 외부 OIDC IdP에서 API-key로 바꾸면 cluster phase가 client별 키를 최초 한 번만 생성합니다.
- Loki의 단일 replica/local-path 구성은 테스트베드 설정입니다.
