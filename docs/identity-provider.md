# 외부 OpenID Connect · SAML 연결

> 문서 경로: [문서 홈](README.md) → [관리자 가이드](administrator-guide.md) → 외부 인증
> 대상: 조직 IdP와 SADP를 연결하는 플랫폼·인증 관리자

Portal과 앱을 **조직 계정 로그인**에 연결하는 절차입니다. IdP는 로그인을 제공하는 외부 서버이고,
SADP는 그 서버가 확인한 신원을 사용합니다. 플랫폼 관리자와 조직 인증 관리자가 함께 진행하세요.

준비 순서는 **IdP에 앱 등록 → 로그인 후 돌아올 주소 등록 → 공개 주소를 site.env에 기록 →
client secret을 관리자 전용 파일로 전달 → 설치 적용과 로그인 시험**입니다.
SADP는 IdP의 realm·tenant(계정 관리 영역), client(등록 앱), 사용자·그룹을 자동 생성하지 않습니다.
IdP 설정과 계정의 생성·변경·삭제는 조직 인증 담당자가 관리합니다.

SADP 런타임의 인증 소비자는 OIDC를 사용합니다. 상위 인증원이 SAML만 제공한다면 조직이 운영하는
broker에서 SAML을 받아 OIDC로 내보내고, SADP에는 그 broker의 OIDC endpoint를 연결합니다.

```mermaid
flowchart LR
    subgraph External["조직 인증팀 운영"]
        OIDC["OIDC IdP"]
        SAML["SAML IdP"] --> Broker["외부 SAML → OIDC broker"]
    end
    OIDC --> Endpoints["공개 OIDC endpoint·claim"]
    Broker --> Endpoints
    subgraph SADP["SADP 인증 소비자"]
        Portal["Portal"]
        Envoy["Envoy Gateway"]
        Bao["OpenBao"]
    end
    Endpoints --> Portal
    Endpoints --> Envoy
    Endpoints --> Bao
```

## 1. 외부 IdP에서 준비할 항목

인증 담당자에게 다음 항목을 요청하세요. 주소는 IdP 관리 화면의 주소가 아니라
OIDC discovery 문서가 제공하는 값이어야 합니다.

| 항목 | 사용하는 이유 |
| --- | --- |
| `issuer` | 인증 정보를 발급한 주체가 맞는지 확인. 끝 `/`까지 정확히 유지 |
| authorization endpoint | 브라우저를 조직 로그인 화면으로 보냄 |
| token endpoint | 로그인 결과를 토큰으로 교환 |
| JWKS URI | 토큰 서명을 확인하는 공개 키 조회 |
| client ID와 client secret | IdP에 등록한 앱의 식별자와 비밀값. 사용자 비밀번호와 다름 |
| 그룹 claim | 사용자가 어떤 그룹에 속하는지 확인하는 인증 결과 필드 |

OIDC discovery가 제공하는 `issuer`, authorization endpoint, token endpoint, JWKS URI를 확인합니다.
모든 endpoint는 credential이 없는 HTTPS URL이어야 합니다. SADP가 사용하는 최소 scope는
`openid email profile`이며, 권한 판정에 사용할 배열형 그룹 claim도 하나 정합니다.

IdP 관리자가 client secret으로 인증하는 앱(confidential client)을 직접 만들고,
로그인 뒤 돌아올 주소(redirect URI)를 다음과 같이 정확히 등록합니다.

| 소비자 | client ID | redirect URI |
| --- | --- | --- |
| Portal | 계약의 `PORTAL_OIDC_CLIENT_ID` | `https://<PORTAL_HOST>/api/auth/callback/oidc` |
| secure-demo | `secure-demo-<APP_ENVIRONMENT>` | `https://<SECURE_DEMO_HOST>/oauth2/callback` |
| OpenBao | `openbao` | `https://<OPENBAO_HOST>/ui/vault/auth/oidc/oidc/callback` |
| OpenBao CLI | 위와 같음 | `http://localhost:8250/oidc/callback` |

로그아웃 endpoint를 제공하지 않는 IdP라면 `OIDC_END_SESSION_ENDPOINT`를 비워 둡니다. 이 경우
Portal은 로컬 세션만 종료합니다.

## 2. `site.env`에 공개 계약 기록

OpenID IdP를 직접 쓰는 경우:

```bash
IDENTITY_SOURCE_PROTOCOL=openid
OIDC_ISSUER=https://<IDP_HOST>/<ISSUER_PATH>
OIDC_AUTHORIZATION_ENDPOINT=https://<IDP_HOST>/<AUTHORIZATION_PATH>
OIDC_TOKEN_ENDPOINT=https://<IDP_HOST>/<TOKEN_PATH>
OIDC_JWKS_URI=https://<IDP_HOST>/<JWKS_PATH>
OIDC_END_SESSION_ENDPOINT=https://<IDP_HOST>/<LOGOUT_PATH>
OIDC_GROUPS_CLAIM=groups
OIDC_CLIENT_ID_CLAIM=azp
PORTAL_OIDC_CLIENT_ID=<PORTAL_CLIENT_ID>
```

SAML→OIDC broker를 쓰는 경우에는 같은 OIDC 값을 적되 출처를 기록합니다.

```bash
IDENTITY_SOURCE_PROTOCOL=saml
```

SAML metadata, Entity ID, 인증서, signing key, IdP 관리자 token은 SADP 계약에 넣지 않습니다.
broker의 upstream SAML 설정은 broker 관리자가 해당 제품의 절차로 구성합니다.

## 3. client secret 전달

**실행 위치: control-plane.** IdP에서 발급한 secret은 Git이나 `site.env`에 쓰지 않고 관리자(root)
전용 파일로 전달합니다. 아래 `<..._SECRET_FILE>`은 담당자로부터 안전하게 받은 원본 파일 경로입니다.
각 파일에는 secret 문자열 하나만 저장하며, 파일 내용을 화면에 출력하지 않습니다.
Provider 하나를 공유하는 사이트는 [공통 Client ID 설정](installation.md#한-명령으로-설치)의 별도 파일을 사용합니다.

```bash
sudo install -d -m 0700 /var/lib/sadp/credentials
sudo install -o root -g root -m 0600 <PORTAL_SECRET_FILE> \
  /var/lib/sadp/credentials/oidc-portal-client-secret
sudo install -o root -g root -m 0600 <SECURE_DEMO_SECRET_FILE> \
  /var/lib/sadp/credentials/oidc-secure-demo-client-secret
sudo install -o root -g root -m 0600 <OPENBAO_SECRET_FILE> \
  /var/lib/sadp/credentials/oidc-openbao-client-secret
```

cluster bootstrap은 이 값을 OpenBao→ESO 경로에 넣고 SADP 소비자 설정만 수렴합니다. 외부 IdP API는
호출하지 않습니다.

## 4. 검증

입력 파일을 읽을 수 있는 권한으로 형식을 검사하고, control-plane에서 Portal 인증 흐름을 검사합니다.

```bash
python3 scripts/site/configure-site.py --env-file /etc/sadp/site.env --check
sudo bash ./sadp --verify-portal-auth
```

검증기는 discovery와 계약 endpoint가 같은지, Portal이 `oidc` provider와
Authorization Code + PKCE/state/nonce 요청을 만드는지만 읽기 전용으로 확인합니다. 실제 사용자 로그인,
MFA, 그룹 claim, SAML assertion은 외부 IdP의 승인된 테스트 계정으로 브라우저에서 확인합니다.

## 5. 기존 내장 인증 제거 시 주의

이 변경은 저장소에서 관리 매니페스트와 구성 스크립트를 제거하지만 이미 실행 중인 인증 서버나 DB를
자동 삭제하지 않습니다. 먼저 외부 OIDC 로그인과 권한을 확인한 뒤, 기존 워크로드·데이터·DNS를 별도
변경 절차와 백업 정책에 따라 폐기합니다. SADP 설치기를 삭제 도구로 사용하지 않습니다.
