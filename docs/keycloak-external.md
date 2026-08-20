# 외부 Keycloak 분리 Runbook

> 문서 경로: [문서 홈](README.md) → [관리자 가이드](administrator-guide.md) → 외부 Keycloak
> 대상: Keycloak을 별도 VM에서 운영하거나 상위 SAML IdP를 연결하는 관리자
> 일반 로그인 문제 제보자는 [사용자 가이드](usage.md#10-문제를-전달할-때)를 먼저 사용

Keycloak과 PostgreSQL을 클러스터 밖의 별도 VM에서 운영하는 절차입니다.
운영 환경은 전용 VM, 테스트는 같은 VM의 Docker Compose를 씁니다.
**두 경우 모두 클러스터 쪽 구성은 동일합니다.**

> [!IMPORTANT]
> 이 문서의 `Private`는 실제 환경에서만 관리하는 값입니다.
> IP, FQDN, 비밀번호를 Git에 실제 값으로 기록하지 않습니다.

## 1. 무엇이 바뀌고 무엇이 그대로인가

바뀌지 않는 것이 더 많습니다. **애플리케이션과 인증 설정은 손대지 않습니다.**

| 항목 | in-cluster | external |
| --- | --- | --- |
| issuer | `https://sso.<도메인>/realms/<realm>` | 같음 |
| sso host와 TLS | Envoy Gateway, wildcard 인증서 | 같음 |
| 외부 진입점 | Envoy Gateway 하나 | 같음 |
| Portal Auth.js, SecurityPolicy | 계약 issuer 참조 | 같음 |
| `Service/keycloak:8080` | Deployment를 selector로 선택 | **selector 없음 + EndpointSlice** |
| Keycloak/PostgreSQL 워크로드 | 클러스터 | **외부 VM** |
| DB 백업·복원 훈련 | 이 저장소 스크립트 | **외부 VM 책임** |

> [!NOTE]
> 핵심은 **`Service/keycloak`의 이름과 port를 그대로 두는 것**입니다.
> HTTPRoute, ReferenceGrant, issuer, SecurityPolicy, Portal 설정이 전부 이 Service만 보므로
> backend만 외부로 옮기면 됩니다.

---

## 2. 계약 입력

`/etc/sadp/site.env`에서 세 값을 설정합니다.

```dotenv
KEYCLOAK_DEPLOYMENT=external
KEYCLOAK_EXTERNAL_ADDRESS=<Private-Keycloak-VM-IPv4>
KEYCLOAK_EXTERNAL_PORT=8080
```

> [!WARNING]
> `external`이면 주소가 **반드시 필요**하고, `in-cluster`에서 주소를 채우면 **생성이 거부됩니다.**

```bash
python3 scripts/site/configure-site.py --env-file /etc/sadp/site.env --check
python3 scripts/site/configure-site.py --env-file /etc/sadp/site.env --write
```

`platform/keycloak/resources.yaml`이 세 문서로 바뀝니다.

- Namespace
- selector 없는 `Service/keycloak`
- `EndpointSlice/keycloak-external`

Deployment와 StatefulSet은 사라집니다.
`in-cluster`로 되돌리면 `scripts/site/templates/keycloak-in-cluster.yaml.template`에서
워크로드가 복구됩니다.

---

## 3. 외부 VM 준비

> [!IMPORTANT]
> VM은 클러스터 노드 **내부망**에 있어야 하고, Envoy가 `KEYCLOAK_EXTERNAL_PORT`로 접근할 수
> 있어야 합니다. **공인 NIC에는 이 port를 열지 않습니다.**

설치 방식은 두 가지입니다. 어느 쪽이든 클러스터 쪽 계약과 검증은 동일하며, 다른 것은
**설정을 어디에 적고 무엇을 재시작하는가**뿐입니다.

| 방식 | 설정 위치 | 재시작 |
| --- | --- | --- |
| Docker Compose (§3.1) | `/opt/keycloak-external/.env` | `docker compose up -d` |
| 네이티브 + systemd (§3.2) | `/etc/keycloak/keycloak.env` | `systemctl restart keycloak` |

### 3.1 Docker Compose

```bash
sudo install -d -m 0700 /opt/keycloak-external
sudo cp platform/keycloak/external/docker-compose.yml /opt/keycloak-external/
sudo cp platform/keycloak/external/configure-default-developer.sh /opt/keycloak-external/
sudo cp platform/keycloak/external/env.example /opt/keycloak-external/.env
sudo chmod 0600 /opt/keycloak-external/.env
sudoedit /opt/keycloak-external/.env
```

`.env`에서 맞출 값입니다. 비밀번호는 `openssl rand -hex 32`로 만듭니다.

| 변수 | 값과 주의점 |
| --- | --- |
| `KC_HOSTNAME` | 계약의 `keycloak.issuer`와 같은 `https://sso.<도메인>`. **다르면 discovery issuer가 어긋나 Portal 로그인과 SecurityPolicy가 모두 실패합니다.** |
| `KEYCLOAK_BIND_ADDRESS` | 계약의 `KEYCLOAK_EXTERNAL_ADDRESS`와 같은 내부 NIC 주소 |
| `KC_PROXY_TRUSTED_ADDRESSES` | Envoy가 클러스터를 나올 때의 source 대역(보통 노드 내부망 CIDR). **틀리면 Keycloak이 `X-Forwarded-*`를 무시해 redirect URI가 내부 주소로 생성됩니다.** |
| `SADP_NTP_SERVERS` | Keycloak VM에서 이름을 해석하고 UDP 123 응답을 받을 수 있는 내부 NTP 서버. 공백으로 여러 개를 적습니다. |
| `EGRESS_PROXY_URL` | VM의 egress 프록시(보통 `http://<SQUID_INTERNAL_IP>:<SQUID_PORT>`). identity provider 연동을 쓰면 **반드시** 채웁니다 → §3.3 |
| `KEYCLOAK_REALM` | 계약 `spec.keycloak.realm`과 같은 realm |
| `KEYCLOAK_IDP_ALIAS` | 계약 `spec.keycloak.identityProvider.alias`와 같은 연합 IdP alias |
| `KEYCLOAK_SAML_SP_ENTITY_ID` | 계약 `spec.keycloak.samlSpEntityId`와 **문자 그대로** 같은 값. Audience의 끝 `/`도 보존합니다. |
| `KEYCLOAK_IDP_METADATA_URL` | 계약 `spec.keycloak.identityProvider.metadataDescriptorUrl`과 같은 URL |
| `KEYCLOAK_IDP_SSO_URL` | 계약 `spec.keycloak.identityProvider.singleSignOnServiceUrl`과 같은 URL |
| `PORTAL_CLIENT_ID` | 계약 `spec.keycloak.portalClientID`와 같은 client ID |
| `PORTAL_POST_LOGOUT_REDIRECT_URI` | `https://<Private-portal-host>/portal`. Keycloak 브라우저 로그아웃 뒤 돌아올 정확한 URI |

```bash
cd /opt/keycloak-external
sudo docker compose up -d
sudo docker compose ps
```

`configure-external-keycloak.sh --apply`는 realm을 바꾸기 전에 VM에
`configure-time-sync.sh`를 설치·실행합니다. Compose 방식에서는 `docker.service`를
`systemd-time-wait-sync.service` 뒤에 두므로 재부팅 때 Keycloak 컨테이너가 동기화 전 시각으로
시작하지 않습니다. 실행 중인 Docker/Keycloak은 자동 재시작하지 않습니다.

`keycloak-config`는 Keycloak이 Ready가 된 뒤 다음 항목을 멱등 구성하는 일회성 job입니다.

- realm의 공개 가입·중복 이메일·사용자명 변경을 차단
- SAML SP EntityID와 IdP metadata/SSO URL, assertion 서명 검증을 계약으로 수렴
- `sadp-trusted-saml-first-login` flow를 만들고 `Create User If Unique`와
  `Automatically Set Existing User`만 `ALTERNATIVE`로 구성
- 연합 IdP에 위 flow와 `Trust Email`을 바인딩
- SAML Username 매퍼를 `${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}`/`IMPORT`로 고정
- `developer`를 Realm Default Group에 추가하되 다른 default group은 유지
- 연합 IdP에 Hardcoded Group(`/developer`, Sync Mode `FORCE`) mapper 추가
- Portal client의 callback URI, web origin, post logout redirect URI를 현재 Portal host로 수렴

성공하면 종료 코드 0인 `Exited` 상태가 정상입니다.

```bash
sudo docker compose ps --all keycloak-config
sudo docker compose logs keycloak-config       # Secret 값은 출력하지 않음
```

이미 설치된 외부 Keycloak에는 갱신한 `docker-compose.yml`,
`configure-default-developer.sh`와 `.env`의 위 네 입력을 반영한 뒤 job을 한 번 실행합니다.
Keycloak 본체나 로그인 세션을 재시작하지 않습니다.

```bash
cd /opt/keycloak-external
sudo docker compose run --rm keycloak-config
```

> [!IMPORTANT]
> 이 설정은 로컬 공개 회원가입을 켜지 않습니다. First Broker Login은 client가 아니라
> **realm의 신뢰한 IdP에 한 번만** 적용됩니다. 따라서 Portal 뒤에 다른 OIDC 앱을 추가해도
> 같은 LIFE 사용자는 profile 입력이나 새 계정 생성을 반복하지 않습니다. 이메일 자동 연결은
> 서명 검증된 이 IdP에만 쓰며, 다른 임의 IdP에는 이 flow를 바인딩하지 않습니다.
> Realm Default Group은 신규 import를, IdP mapper는 이미 import된 연합 사용자를 담당합니다.
> 기존 사용자는 다음 로그인 때 `developer` membership이 추가되고 다른 group은 유지됩니다.

> [!NOTE]
> PostgreSQL은 `ports`를 열지 않아 컨테이너 네트워크 밖으로 나가지 않습니다.

### 3.2 네이티브 설치 (systemd)

배포판 패키지나 tarball로 `/opt/keycloak`에 직접 설치하고 systemd로 띄우는 구성입니다.
PostgreSQL도 같은 VM의 서비스이므로 `Requires=postgresql.service`로 묶습니다.

```ini
# /etc/systemd/system/keycloak.service
[Unit]
Description=Keycloak Identity and Access Management
After=network-online.target systemd-time-wait-sync.service time-sync.target postgresql.service
Wants=network-online.target systemd-time-wait-sync.service
Requires=postgresql.service

[Service]
Type=simple
User=keycloak
Group=keycloak
EnvironmentFile=/etc/keycloak/keycloak.env
WorkingDirectory=/opt/keycloak
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Compose의 `environment:`에 해당하는 값이 `/etc/keycloak/keycloak.env`로 갑니다.
**변수 이름은 같고 형식만 `KEY=value`입니다.** 이 파일은 비밀번호를 담으므로
`chmod 0600`, 소유자 `root:keycloak`로 두고 Git에 넣지 않습니다.

```dotenv
# /etc/keycloak/keycloak.env  (값은 사이트별 Private)
KC_DB=postgres
KC_DB_URL=jdbc:postgresql://localhost:5432/keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=<Private>
KC_HTTP_ENABLED=true
KC_HTTP_HOST=<KEYCLOAK_EXTERNAL_ADDRESS>
KC_HTTP_PORT=8080
KC_HOSTNAME=https://sso.<도메인>
KC_PROXY_HEADERS=xforwarded
KC_HEALTH_ENABLED=true
```

> [!IMPORTANT]
> 네이티브에서는 `KC_HTTP_HOST`가 Compose의 `KEYCLOAK_BIND_ADDRESS` 역할을 합니다.
> **비워 두면 `0.0.0.0`으로 열려 공인 NIC에도 8080이 뜹니다.** 계약의
> `keycloak.external.address`와 같은 내부 NIC 주소를 반드시 적습니다.

> [!NOTE]
> `--optimized`는 `kc.sh build`가 끝난 상태를 전제합니다. `KC_DB` 같은 빌드 시점 옵션을
> 바꿨으면 재시작만으로는 반영되지 않고 `sudo -u keycloak /opt/keycloak/bin/kc.sh build`를
> 다시 돌려야 합니다. 아래 egress 프록시 값은 환경변수라 build가 필요 없습니다.

#### `invalid_grant`인데 EnvironmentFile 값은 같은 경우

`KC_BOOTSTRAP_ADMIN_USERNAME`과 `KC_BOOTSTRAP_ADMIN_PASSWORD`는 **최초 DB 생성 입력**입니다.
Keycloak이 한 번 초기화된 뒤 EnvironmentFile 값을 바꿔도 기존 `master` realm 사용자의
비밀번호 credential은 갱신되지 않습니다. 파일과 실행 프로세스의 값이 같아도 `kcadm`이
다음처럼 실패할 수 있습니다.

```text
Invalid user credentials [invalid_grant]
```

다음 세 상태가 함께 나오면 EnvironmentFile 로딩 문제가 아니라 **DB credential drift**입니다.

- `master` realm에 해당 관리자 사용자가 정확히 1개 있음
- 사용자가 enabled이고 password credential도 존재함
- 실행 프로세스의 bootstrap 값으로 실제 token 발급이 실패함

DB의 credential hash를 직접 고치지 않습니다. PostgreSQL 백업과 유지보수 창을 확보한 뒤
Keycloak을 정지하고 `kc.sh bootstrap-admin user`로 일회용 관리자를 만듭니다. 비밀번호는
argv가 아니라 `--password:env <ENV_NAME>`으로 전달합니다. Keycloak을 다시 시작한 다음
일회용 관리자로 기존 관리자의 비밀번호를 EnvironmentFile 값에 맞추고, 원래 관리자로
로그인되는지 확인한 뒤 일회용 사용자를 삭제합니다. `kcadm`에는 `--config <TEMP_FILE>` 또는
임시 `HOME`을 사용하고 끝나면 session 파일도 삭제합니다.

> [!CAUTION]
> `bootstrap-admin`은 실행 중인 Keycloak과 동시에 DB를 쓰지 않습니다. 모든 Keycloak
> 인스턴스를 정지한 유지보수 창에서만 실행합니다. 복구 중간에 실패하면 서비스를 먼저
> 다시 올리고 일회용 관리자 잔존 여부부터 확인합니다.

#### 네트워크 EnvironmentFile 교차검증

아래 값은 서로 다른 역할입니다. 한 줄을 다른 값으로 대신하면 Keycloak은 떠 있어도
OIDC discovery, 감사 source IP, IdP metadata 갱신 중 하나가 뒤늦게 깨집니다.

```dotenv
KC_HTTP_HOST=<KEYCLOAK_PRIVATE_IP>
KC_HTTP_PORT=8080
KC_HOSTNAME=https://sso.<BASE_DOMAIN>
KC_PROXY_HEADERS=xforwarded
KC_PROXY_TRUSTED_ADDRESSES=<ENVOY_EGRESS_SOURCE_CIDR>
HTTP_PROXY=http://<SQUID_PRIVATE_IP>:3128
HTTPS_PROXY=http://<SQUID_PRIVATE_IP>:3128
NO_PROXY=localhost,127.0.0.1,<KEYCLOAK_PRIVATE_IP>
```

특히 `KC_PROXY_TRUSTED_ADDRESSES:http://<주소>:<port>`는 두 번 틀린 값입니다. systemd
EnvironmentFile의 대입 연산자는 `=`이고, 이 옵션의 값은 프록시 URL이 아니라 Envoy가
Keycloak VM에 연결할 때 보이는 source IP/CIDR입니다. `KC_HTTP_HOST=0.0.0.0`도 쓰지 않습니다.
내부 NIC 하나에만 bind해야 공인 NIC에서 8080이 열리지 않습니다.

비밀번호를 출력하지 않고 실제 런타임의 공개 네트워크 항목만 볼 수 있습니다.

```bash
pid=$(systemctl show keycloak.service -p MainPID --value)
sudo tr '\0' '\n' <"/proc/${pid}/environ" |
  grep -E '^(KC_HTTP_HOST|KC_HTTP_PORT|KC_HOSTNAME|KC_PROXY_HEADERS|KC_PROXY_TRUSTED_ADDRESSES|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)='
```

`KC_HTTP_HOST`를 private IP로 제한한 뒤에는 VM 안의 자동화도 `localhost:8080`을 가정하면
안 됩니다. `configure-external-keycloak.sh`는 계약의 `external.address`와 `external.port`를
사용합니다. 오래된 checkout이 loopback을 쓰면 connection refused로 실패합니다.

### 3.3 egress 프록시 — `Error reloading keys.`의 원인

> [!CAUTION]
> **`-Dhttps.proxyHost` 같은 JVM 시스템 속성은 여기서 통하지 않습니다.** 그것은
> `HttpURLConnection` 전용입니다. identity provider의 metadata·서명 인증서를 가져오는 것은
> Keycloak의 **Apache HttpClient**이고, 이 client는 `proxy-mappings`가 없으면
> **`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` 환경변수**로 넘어갑니다.
> (`DefaultHttpClientFactory`의 로그: `Trying to use proxy mapping from env vars`)
>
> `-D`만 넣으면 조용히 무시되고, 프록시를 설정했는데도 **직접 DNS를 조회하다** 실패합니다.
> 로그에 이 조합이 보이면 바로 이 경우입니다.
>
> ```text
> Error when loading public keys: java.net.UnknownHostException:
>   <IDP_HOST>: Temporary failure in name resolution
> ```

증상은 관리 콘솔의 **`Error reloading keys.`** 하나뿐입니다. 요청이 프록시까지 가지도
않으므로 **Squid 로그에는 아무것도 남지 않습니다.** 그래서 "Squid ACL이 막았나" 쪽을
오래 파기 쉽지만 ACL은 대개 문제가 아닙니다 — 계약의 `identityProviderDomains`가 이미
그 도메인을 통째로(`.example.net` = 모든 하위 도메인) 허용합니다.

원인을 두 줄로 가릅니다. **1번이 200인데 2번이 비어 있으면 프록시 미설정입니다.**

```bash
# 1) 프록시 경로 자체는 열려 있는가 (VM 에서, 200 이어야 한다)
curl -sS -o /dev/null -w '%{http_code}\n' -x http://<SQUID_IP>:3128 <IDP_METADATA_URL>
# 2) Keycloak 이 그 경로를 쓰는가
sudo docker exec keycloak-external-keycloak-1 printenv HTTPS_PROXY          # Compose
sudo tr '\0' '\n' < /proc/$(pgrep -f "kc.sh\|quarkus")/environ | grep PROXY   # 네이티브
```

VM 자체의 직접 egress가 막혀 있는지도 같이 봅니다. 내부망 VM이면 **DNS 조회부터**
실패하는 것이 정상입니다(`Resolving timed out`). 그 상태에서 1번이 200이면 경로는 Squid뿐이라는
뜻입니다.

**Compose:** `.env`의 `EGRESS_PROXY_URL`을 채우고 다시 만듭니다.
`docker restart`는 environment를 다시 읽지 않으므로 반드시 `up -d`입니다.

```bash
cd /opt/keycloak-external && sudo docker compose up -d
```

**네이티브:** `/etc/keycloak/keycloak.env`에 세 줄을 더하고 재시작합니다.
`NO_PROXY`는 CIDR이 아니라 쉼표로 구분한 hostname/주소 목록입니다.

```dotenv
HTTP_PROXY=http://<SQUID_IP>:3128
HTTPS_PROXY=http://<SQUID_IP>:3128
NO_PROXY=localhost,127.0.0.1
```

```bash
sudo systemctl restart keycloak
# EnvironmentFile 의 값은 systemctl show -p Environment 에 나오지 않는다. 프로세스에서 본다.
sudo tr '\0' '\n' < /proc/$(pgrep -f quarkus | head -1)/environ | grep PROXY
```

> [!NOTE]
> 도메인별로 프록시를 나눠야 하면 환경변수 대신 SPI 옵션
> `--spi-connections-http-client-default-proxy-mappings`(`hostnamePattern;proxyUri` 목록)를
> 씁니다. 이 값이 있으면 환경변수 fallback은 동작하지 않습니다.

### 3.4 `invalid_saml_response` — Audience 오류와 실제 만료를 로그로 분리

`Assertion expired.`는 Keycloak의 Conditions 검증이 실패했다는 결과입니다. Audience와 시간
조건을 같은 검증 경로에서 처리하므로 이 한 줄만으로 어느 쪽인지 정하지 않습니다.

다음처럼 바로 앞에 `is not addressed to this SP.`가 있으면 Audience 불일치입니다.

```text
INFO  [org.keycloak.saml.validators.ConditionsValidator] Assertion <ID> is not addressed to this SP.
ERROR [org.keycloak.broker.saml.SAMLEndpoint] Assertion expired.
WARN  [org.keycloak.events] type="IDENTITY_PROVIDER_RESPONSE_ERROR", error="invalid_saml_response"
```

반대로 해당 Audience 로그가 없고 다음 사실이 함께 확인되면 실제 시간 만료로 분류합니다.

- Portal/Auth.js에 `expired_code`가 없고 로컬 Keycloak 로그인은 정상
- Keycloak 재시작이 없음
- `timedatectl show -p NTPSynchronized --value`가 `no`
- SAML Assertion의 `NotOnOrAfter`가 Keycloak 도착 시각보다 과거

이 경우 Portal timeout이나 Keycloak `allowedClockSkew`를 바꾸지 않습니다. Keycloak VM과
외부 SSO의 NTP부터 정상화하고 Assertion 발급 시각·유효시간·재사용 여부를 검사합니다.

#### Audience 불일치인 경우

우리 쪽 값은 추측하지 말고 descriptor에서 그대로 읽습니다.

```bash
curl -s https://sso.<도메인>/realms/<REALM>/broker/<IDP_ALIAS>/endpoint/descriptor \
  | grep -o 'entityID="[^"]*"\|AssertionConsumerService[^>]*Location="[^"]*"'
```

- `entityID` = IdP가 `<Audience>`에 넣어야 하는 값 (보통 `https://sso.<도메인>/realms/<REALM>`)
- `AssertionConsumerService Location` = IdP에 등록할 ACS URL (`.../broker/<IDP_ALIAS>/endpoint`)

**둘 중 하나로 맞춥니다.** IdP를 남이 운영하면 (가)를 요청하는 편이 표준에 가깝습니다.

| | 고칠 곳 | 내용 |
| --- | --- | --- |
| (가) | IdP(SP 등록 정보) | Audience를 위 `entityID`와 **문자 그대로** 같게. 끝의 `/` 하나도 다르면 안 됨 |
| (나) | Keycloak IdP 설정 | `Entity ID`를 IdP가 실제로 보내는 값으로 덮어씀 |

가장 흔한 실수는 두 값이 눈으로는 같아 보여도 한쪽만 끝에 `/`가 있는 경우입니다. ACS와
`Recipient`가 정확하고 `Audience`만 다르면 서명 검증을 끄지 말고 이 한 글자를 맞춥니다.
IdP를 바로 고칠 수 없어 (나)를 택할 때는 관리 UI만 고치지 말고 사이트 입력과 계약을 함께
수렴시킵니다. `KEYCLOAK_SAML_SP_ENTITY_ID`를 비우면 OIDC issuer와 같은 값이고, 끝 `/`가
필요한 IdP에만 명시합니다.

```dotenv
KEYCLOAK_SAML_SP_ENTITY_ID=https://sso.<도메인>/realms/<REALM>/
```

```bash
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --write
sudo bash scripts/cluster/configure-external-keycloak.sh --apply
```

이 적용은 Keycloak 재시작 없이 IdP instance를 갱신합니다. descriptor의 `entityID`와 새
AuthnRequest의 `Issuer`를 다시 확인한 뒤 로그인합니다. 실패 화면에서 새 로그인 흐름을
시작하지 않고 POST를 다시 보내면 `RelayState parameter was null`이 뒤따를 수 있는데, 이는
Audience 실패 뒤의 재전송 증상이지 별도 원인이 아닙니다.

#### 실제 Assertion 만료인 경우: NTP를 먼저 복구

Keycloak VM의 Private EnvironmentFile에 접근 가능한 NTP 서버를 적습니다. 이름을 쓰려면 VM의
DNS가 그 이름을 해석해야 하고, 주소를 쓰더라도 UDP 123 송수신이 열려 있어야 합니다.

```dotenv
SADP_NTP_SERVERS="<INTERNAL_NTP_1> <INTERNAL_NTP_2>"
```

원격 수렴은 각 주소에 실제 NTP 패킷을 보내 응답 mode/stratum/timestamp를 확인한 뒤
`systemd-timesyncd`를 설정합니다. `NTPSynchronized=yes`가 제한 시간 안에 되지 않으면 Keycloak
realm/IdP 설정 전에 중단합니다.

```bash
# 변경 전: 두 서버의 sync yes/no와 UTC 차이(초)만 출력. 기준 미충족이면 non-zero가 정상
sudo bash ./sadp --verify-saml-federation \
  --env-file /etc/sadp/saml-federation.env --measure

# control-plane: 계획에는 변경이 없음
sudo bash ./sadp --configure-external-keycloak

# 적용: NTP → NTPSynchronized=yes → Keycloak realm/IdP 정책 순서
sudo bash ./sadp --configure-external-keycloak --apply

# 변경 후: 양쪽 sync=yes와 허용 범위 이내 시각 차이를 강제
sudo bash ./sadp --verify-saml-federation \
  --env-file /etc/sadp/saml-federation.env --measure
```

외부 SSO VM도 같은 스크립트를 복사해 실행할 수 있습니다. 해당 VM의 root-only EnvironmentFile에
같은 `SADP_NTP_SERVERS`를 두고 실제 런타임에 맞는 모드를 선택합니다.

```bash
sudo bash platform/keycloak/external/configure-time-sync.sh \
  --env-file /etc/<PRIVATE_PATH>/identity-time.env --runtime compose
sudo bash platform/keycloak/external/configure-time-sync.sh \
  --env-file /etc/<PRIVATE_PATH>/identity-time.env --runtime compose --apply
```

`native`는 `keycloak.service`, `compose`는 `docker.service`를
`systemd-time-wait-sync.service` 뒤에 둡니다. 설정 적용은 실행 중인 서비스를 재시작하지 않습니다.
재부팅 시험에서는 Keycloak/Docker가 time sync 뒤에 시작되는지 다시 확인합니다.

#### Authentik Assertion 유효시간과 재사용 방지

상위 IdP가 Authentik이면 현재 공식 SAML Provider 기본값은
`assertion_valid_not_before=minutes=-5`,
`assertion_valid_not_on_or_after=minutes=5`입니다. SADP는 이 두 필드만 PATCH하며 Keycloak
clock skew, 로그인 timeout, 서명 검증은 건드리지 않습니다. API URL·Provider ID·token 파일은
`platform/keycloak/external/authentik-saml.env.example`을 복사한 Git 외부 Private 파일에 둡니다.

```bash
sudo bash ./sadp --configure-authentik-saml \
  --env-file /etc/sadp/authentik-saml.env
sudo bash ./sadp --configure-authentik-saml \
  --env-file /etc/sadp/authentik-saml.env --apply
```

이 값은 사용자가 로그인 페이지를 오래 보는 시간을 늘리는 설정이 아닙니다. 외부 인증이 끝나
Assertion을 발급한 시점 전후의 작은 전달 구간입니다. 5분보다 짧은 기존 값만 숨기기 위해
Keycloak 허용 오차를 크게 늘리지 않습니다.

Authentik과 그 앞 프록시/로드밸런서에서는 `/application/saml/<APPLICATION>/`의 인증된 응답을
캐시하지 않습니다. 제품별 설정 문법은 다르지만 다음 세 조건을 모두 만족해야 합니다.

- SAML POST 응답에 `Cache-Control: no-store, private` 적용
- proxy cache bypass/no-cache 적용
- 브라우저 뒤로 가기·새로고침 때 이전 POST body를 재전송하지 않고 새 인증 흐름 시작

Authentik SAML endpoint와 유효시간 필드명은 공식 문서/API를 기준으로 합니다.

- [Authentik SAML endpoint](https://docs.goauthentik.io/add-secure-apps/providers/saml)
- [Authentik SAML Provider API](https://docs.goauthentik.io/docs/developer-docs/api/reference/providers-saml-update)

#### 수정 전후 검증

두 로그인에서 얻은 SAMLResponse는 원문을 화면·로그에 붙이지 않습니다. root 전용 `0600` 파일로
짧게 보관하고, 검증 뒤 안전하게 삭제합니다. 검증기는 `IssueInstant`, Conditions의
`NotBefore`/`NotOnOrAfter`, `SubjectConfirmationData.NotOnOrAfter`와 두 Response/Assertion ID가
서로 다른지만 출력 없는 해시 비교로 판정합니다.

```bash
sudo bash ./sadp --verify-saml-federation \
  --env-file /etc/sadp/saml-federation.env --mark

# 아래 시나리오를 수행한 뒤 서로 다른 두 로그인 응답의 root-only 파일을 전달합니다.
sudo bash ./sadp --verify-saml-federation \
  --env-file /etc/sadp/saml-federation.env --check \
  --assertion-sample /run/<PRIVATE_FIRST_SAMPLE> \
  --assertion-sample /run/<PRIVATE_SECOND_SAMPLE>
```

`--measure`의 수정 전·후 출력을 장애 기록에 남기되 서버 주소와 UTC 절대시각은 기록하지 않습니다.
`--mark` 뒤 다음을 모두 수행합니다.

1. 외부 SSO 정상 로그인
2. 로그인 페이지를 잠시 열어둔 뒤 로그인
3. 여러 탭에서 동시 로그인
4. 뒤로 가기 후 새 로그인
5. 로그아웃 후 재로그인
6. 유지보수 창에서 Keycloak 재시작 후 로그인

`--check`는 두 서버의 `NTPSynchronized=yes`, UTC 시각 차이, Keycloak의 time-sync 시작 순서,
새 Assertion 시간 필드/ID, 기준점 이후 신규 `Assertion expired`와 `invalid_saml_response` 건수를
검사합니다. journal/Docker 로그 원문과 SAML 원문은 출력하지 않습니다.

> [!TIP]
> Keycloak이 허용하는 audience 목록을 직접 보려면 `org.keycloak.saml.validators`를 DEBUG로
> 올립니다(`Allowed audiences are: ...`가 찍힙니다). 재시작이 필요하므로 유지보수 창에서
> 하고, 확인이 끝나면 되돌립니다. **SAML 응답 전문을 TRACE로 덤프하지 마세요.** 사용자
> 속성이 그대로 로그에 남습니다.

> [!CAUTION]
> 재시작은 진행 중인 SSO 세션을 끊습니다. **유지보수 창에서** 수행합니다.
> 적용 뒤 관리 콘솔에서 identity provider의 **Reload keys**를 다시 눌러 확인합니다.

---

## 4. realm과 client 구성

외부 Keycloak의 realm/client/운영 사용자는 **VM에서** 만듭니다.
`scripts/cluster/bootstrap-testbed-services.sh`는 `deployment=external`이면 in-cluster Keycloak
구간을 건너뛰고 원격 정책 수렴과 OpenBao 초기화를 수행합니다. 단, 실제 로그인 검증에 쓰는
acceptance 테스트 사용자 하나는 in-cluster 경로와 같은 결과가 되도록 원격 수렴 스크립트가
생성합니다.

```bash
sudo docker exec -it keycloak-external-keycloak-1 \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user <Private-admin>
```

클러스터 배포와 맞춰야 하는 값입니다.

| 항목 | 값 |
| --- | --- |
| realm 이름 | 계약 `keycloak.realm` |
| Portal client | 계약 `keycloak.portalClientID`, confidential, redirect URI `https://<PORTAL_HOST>/api/auth/callback/keycloak`, web origin `https://<PORTAL_HOST>`, valid post logout URI `https://<PORTAL_HOST>/portal` |
| secure-demo client, OpenBao client | 기존 in-cluster 구성과 동일한 이름·redirect URI |
| role 매핑 | group과 같은 이름의 realm/client role을 매핑해 토큰의 `realm_access`와 `resource_access.<portalClientID>`를 모두 검증 가능하게 |
| developer group | Realm Default Groups에 추가하고, 연합 IdP Hardcoded Group mapper를 `/developer`/`FORCE`로 설정 |
| First Login Flow | `sadp-trusted-saml-first-login`: `Create User If Unique` + `Automatically Set Existing User`, 둘 다 `ALTERNATIVE`; `Review Profile` 없음 |
| SAML Username mapper | `Username Template Importer`, template `${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}`, sync mode `IMPORT`, target `LOCAL` |

> [!IMPORTANT]
> client secret은 클러스터의 OpenBao/ESO가 앱에 공급하는 값과 **같아야 합니다.**
> VM에서 생성한 값을 승인된 절차로 OpenBao에 넣고, **화면이나 로그에 출력하지 않습니다.**

Docker Compose 구성은 `keycloak-config` job이 위 설정을 멱등 적용하고 결과까지 검증합니다.
네이티브 설치도 같은 스크립트를 사용해야 두 배포 방식이 갈라지지 않습니다. Keycloak이
Ready인 상태에서 실행하며 재시작은 필요 없습니다. 관리자 값은 EnvironmentFile에서 정확한
두 key만 읽고 출력하지 않습니다.

control-plane에서 외부 VM의 root 공개키 인증과 host key 검증이 준비되어 있으면 설치
과정이 이 작업을 원격으로 수행할 수 있습니다. 기본 실행은 계획만 출력하고 `--apply`가
스크립트 설치와 Keycloak 설정 변경을 수행합니다. `StrictHostKeyChecking=yes`라서 host key를
자동 승인하지 않으며, 관리자 비밀번호나 client secret을 외부로 복사하지 않습니다.
acceptance 사용자명과 비밀번호는 control-plane의 root-only 파일에서 암호화된 SSH stdin으로만
전달하며 remote command argv, 환경변수, 원격 파일에 저장하지 않습니다.

```bash
# fingerprint를 별도 채널로 확인해 control-plane root의 known_hosts에 먼저 등록
sudo ssh -o BatchMode=yes root@<KEYCLOAK_EXTERNAL_ADDRESS> true
sudo bash scripts/cluster/configure-external-keycloak.sh
sudo bash scripts/cluster/configure-external-keycloak.sh --apply
```

다른 SSH 포트나 identity 파일은 실행 환경으로만 넘깁니다. Secret 값이나 개인키를
`site.env`/계약에 넣지 않습니다.

```bash
sudo env \
  KEYCLOAK_SSH_PORT=<SSH_PORT> \
  KEYCLOAK_SSH_IDENTITY_FILE=<ROOT_ONLY_IDENTITY_FILE> \
  bash scripts/cluster/configure-external-keycloak.sh --apply
```

`bootstrap-testbed-services.sh`는 `keycloak.deployment=external`이면 위 `--apply`를 자동으로
호출합니다. 따라서 통합 설치기의 `cluster --apply`를 다시 실행해도 First Login flow, Authentik username URI,
developer mapper, Portal callback/origin/logout, acceptance 사용자 realm/client role이 현재 계약으로
수렴합니다. 외부 VM에는
`/etc/keycloak/keycloak.env`와 `/opt/keycloak/bin/kcadm.sh`가 먼저 준비되어 있어야 합니다.

```bash
sudo install -m 0700 \
  platform/keycloak/external/configure-default-developer.sh \
  /root/sadp-configure-keycloak-trusted-saml.sh
sudo env \
  KEYCLOAK_ENV_FILE=/etc/keycloak/keycloak.env \
  KEYCLOAK_SERVER=http://localhost:8080 \
  KCADM=/opt/keycloak/bin/kcadm.sh \
  KEYCLOAK_REALM=<REALM> \
  KEYCLOAK_IDP_ALIAS=<IDP_ALIAS> \
  KEYCLOAK_SAML_SP_ENTITY_ID=https://sso.<DOMAIN>/realms/<REALM> \
  KEYCLOAK_IDP_METADATA_URL=https://<IDP_FQDN>/<METADATA_PATH> \
  KEYCLOAK_IDP_SSO_URL=https://<IDP_FQDN>/<SSO_PATH> \
  PORTAL_CLIENT_ID=<PORTAL_CLIENT_ID> \
  PORTAL_POST_LOGOUT_REDIRECT_URI=https://<PORTAL_FQDN>/portal \
  /root/sadp-configure-keycloak-trusted-saml.sh
```

관리 UI에서 직접 구성하는 경우에도 위 First Login Flow, Realm Default Groups, IdP의
Authentik Username URI/Hardcoded Group mapper와 Portal client의 callback/origin/post logout URI를
함께 설정합니다.
`User registration` 자체는 켜지 않습니다.

### 4.1 IdP alias와 metadata가 계약에서 벗어난 경우

관리 UI에서 metadata를 import하면 provider가 제안한 임의 alias로 저장될 수 있습니다.
그러면 화면에는 IdP가 보여도 자동 수렴은 다음 오류로 멈춥니다.

```text
[FAIL] Keycloak IdP '<IDP_ALIAS>'를 찾지 못함
```

IdP alias는 로그인 URL과 federated identity의 일부이며 Keycloak API에서 제자리 변경할 수
없습니다(`Identity Provider alias cannot be changed`). 운영 realm에서 기존 객체를 바로
삭제하면 사용자 연결이 끊깁니다. 다음 순서로 처리합니다.

1. 계약의 alias, metadata URL, metadata 안의 EntityID/SSO Location을 교차검증합니다.
2. realm 사용자와 federated identity, 기존 IdP mapper 수를 확인합니다.
3. 사용자가 있으면 alias 변경을 인증 마이그레이션으로 취급하고 중단합니다.
4. 아직 사용자가 없는 fresh realm만 원하는 alias의 IdP를 먼저 생성·검증합니다.
5. trusted first-login flow와 mapper를 새 IdP에 적용한 뒤, mapper가 없는 이전 객체만 제거합니다.

metadata endpoint 번호나 SSO slug를 추측하지 않습니다. 둘 이상의 endpoint가 HTTP 200을
줄 수 있으므로 XML의 EntityID와 `SingleSignOnService Location`이 이 사이트용 provider인지
확인하고 그 값을 계약에 기록합니다.

### 4.2 로그인 때 다시 profile/가입 화면이 나오는 경우

주소가 `/login-actions/first-broker-login`이면 새 앱의 회원가입 기능이 아니라 Keycloak이
현재 SAML 신원을 기존 federated identity와 연결하지 못한 것입니다. 화면을 제출해 중복
계정을 만들지 말고 다음 순서로 복구합니다.

1. 외부 PostgreSQL을 `pg_dump --format=custom`으로 백업하고 `pg_restore --list`로 검사합니다.
2. IdP의 현재 alias와 사용자 `Federated identity`의 alias가 같은지 확인합니다.
3. alias를 바꾼 경우 위 trusted flow를 **먼저** 적용합니다. 같은 서명된 이메일의 기존
   계정으로 자동 연결되므로 앱별 사용자 계정은 새로 만들지 않습니다.
4. 이미 중복 계정이 생겼다면 Portal 요청 소유 기록, 자격증명, 세션, role/group, consent,
   다른 federated link가 모두 없는 계정만 백업 후 제거합니다.
5. 로그아웃 후 같은 LIFE 계정으로 두 번 로그인해 두 번째부터 First Broker Login이 나오지
   않고 Portal의 기존 앱 목록이 유지되는지 확인합니다.

로그에 `Username template ... contains unresolved attributes`, `Username is null`,
`IDENTITY_PROVIDER_FIRST_LOGIN_ERROR ... invalid_user_credentials`가 함께 나오면 비밀번호
오류가 아닙니다. Authentik 기본 SAML 응답의
`http://schemas.goauthentik.io/2021/02/saml/username` 특성이 누락되었거나 비어 있는
상태입니다. IdP가 이 특성을 내보내는지 확인한 뒤 `configure-default-developer.sh`를 다시
실행해 URI 전체를 쓰는 Username Template Importer로 수렴시키고,
사용자 수와 federated link를 확인합니다. Review Profile을 되살려 사용자가 임의 username을
제출하게 만들지 않습니다.

IdP alias는 Keycloak에서 신원 namespace입니다. 문자열을 바꾸면 같은 SAML NameID도 다른
공급자로 인식됩니다. trusted flow가 기존 계정에 새 alias를 연결해 주지만, alias 변경 자체는
DB 백업과 위 검증을 포함한 인증 마이그레이션으로 취급합니다.

### 4.3 Portal 로그인 검증이 role claim에서 멈추는 경우

Portal과 Keycloak authorization endpoint까지 정상인데 실제 로그인 검증이 다음처럼
실패하면 TLS나 callback 문제가 아니라 acceptance 테스트 사용자의 수렴 상태를 봅니다.

```text
[FAIL] 실제 Keycloak 로그인/세션 role 검증 실패(누락: <CLAIM-LIST>)
```

외부 배포에서 테스트 사용자가 없거나 `platform-admin`/`viewer` 그룹의 realm/client role이
빠졌을 수 있습니다. 비밀번호를 command line이나 원격 EnvironmentFile에 추가하지 말고
control-plane에서 다음 원격 수렴을 다시 실행합니다.

```bash
sudo bash scripts/cluster/configure-external-keycloak.sh --apply
sudo bash scripts/verify/verify-portal-auth.sh
```

첫 명령은 root-only `keycloak-test-user`/`keycloak-test-password` 파일을 SSH stdin으로만
전달하고 사용자, 그룹, effective realm/client role을 적용 후 재조회합니다. 관리자 Secret은
계속 외부 VM의 EnvironmentFile에서만 읽습니다.

로그인과 role 검증은 통과했는데 `포털 로그아웃 후에도 Keycloak SSO 세션이 남음`만 실패하면
검증기가 Auth.js 기본 `/api/auth/signout`을 직접 호출하는 구버전인지 확인합니다. 이 endpoint는
Portal 로컬 세션만 지우며 `signOutFromKeycloak`을 실행하지 않습니다. 현재 검증기는 인증된
`/account` HTML에서 `$ACTION_ID_...` form을 찾아 실제 로그아웃 버튼과 같은 Server Action을
제출하고, Keycloak RP-initiated logout 뒤 `/portal`로 돌아오는지 확인합니다.

---

## 5. 적용과 검증

```bash
sudo bash scripts/cluster/install-testbed-platform.sh
sudo bash scripts/verify/verify-testbed.sh
```

`install-testbed-platform.sh`는 external이면 `keycloak-db`/`keycloak-bootstrap` Secret을 만들지
않고 Service/EndpointSlice만 적용합니다.

검증에서 확인할 항목:

- `외부 Keycloak EndpointSlice 주소 존재`
- `Keycloak discovery issuer 일치`
- `Portal 실제 Keycloak 로그인·세션·역할·로그아웃`

`verify-testbed.sh`의 first-login flow 검사는 control-plane에 관리자 비밀번호를 복사하지
않습니다. `BatchMode`/strict host-key SSH로 VM에 들어가 그 VM의 EnvironmentFile을 읽고,
realm/IdP/flow/mapper 일치 여부만 boolean으로 돌려받습니다. 따라서 control-plane에
`keycloak-external-admin-password` 같은 복제본을 만들지 않습니다.

수동으로 볼 때는 다음이 계약 issuer와 같아야 합니다.

```bash
curl -s https://sso.<Private-도메인>/realms/<realm>/.well-known/openid-configuration | jq -r .issuer
```

---

## 6. 알아둘 제약

> [!WARNING]
> **Envoy와 Keycloak 사이 구간은 HTTP입니다.**
> TLS는 Envoy가 종단하고 VM까지는 내부망 평문입니다.
> 내부망을 신뢰할 수 없으면 Keycloak에 자체 인증서를 붙이고 계약 port를 8443으로 바꾼 뒤
> Envoy backend를 HTTPS로 올려야 합니다. **현재 렌더러는 HTTP backend를 생성합니다.**

- **DB 백업은 외부 VM 책임입니다.** `scripts/ops/backup-testbed.sh`와
  `scripts/verify/verify-backups.sh`는 external이면 Keycloak PostgreSQL 구간을 건너뜁니다.
  VM에서 `pg_dump`와 복원 훈련을 별도로 운영하고
  [백업·복원 Runbook](recovery.md)과 **같은 주기로** 검증합니다.
- **VM이 죽으면 SSO 앱 로그인이 멈춥니다.** public 앱은 계속 서비스되지만 OIDC 앱과 Portal
  로그인은 실패합니다. **단일 장애점**이므로 운영 전환 시 이중화나 복구 목표를 먼저 정합니다.
- **EndpointSlice는 IPv4 주소 하나만** 렌더합니다. 여러 Keycloak 인스턴스를 두려면 계약과
  렌더러를 먼저 확장해야 합니다.
