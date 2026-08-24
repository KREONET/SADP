# SADP 사이트 설정 참조

> 대상: `/etc/sadp/site.env`와 계약·생성물을 관리하는 플랫폼 관리자
> 전체 key template: [environments/site.env.example](../environments/site.env.example)

다른 사이트에 배포할 때 생성된 YAML의 IP·도메인·이름을 검색 치환하지 않습니다. Git 밖의
`site.env`를 검증한 뒤 생성기 한 번으로 계약과 하위 파일을 만듭니다.

## 1. 값의 소유 위치

| 종류 | 소유 위치 |
| --- | --- |
| 사이트별 비밀 아닌 입력 | `/etc/sadp/site.env` |
| 플랫폼 계약과 생성 리소스 | Git, `configure-site.py --write` 결과 |
| Secret 이름/path/property | Git 계약과 values |
| Secret 실제 값 | OpenBao 또는 root-only bootstrap 파일 |
| Pod Secret | ESO가 만든 Kubernetes Secret |

`configure-site.py`는 env를 shell로 source하지 않고 직접 파싱합니다. 알 수 없는 key, 중복 key,
shell expansion, credential처럼 보이는 key/value, placeholder가 남은 적용을 거부합니다.

운영 `site.env`가 존재하면 그것이 상류입니다. 계약과 생성물을 손으로 고쳐도 다음 `--write`에서
되돌아갑니다. 실제 env가 없는 생성기 개발 checkout에서는 계약을 직접 수정할 수 있지만,
renderer와 테스트를 함께 갱신해야 합니다.

## 2. 파일 준비

```bash
sudo install -d -m 0700 /etc/sadp /etc/sadp/secrets
sudo install -m 0600 environments/site.env.example /etc/sadp/site.env
sudoedit /etc/sadp/site.env
```

`site.env.example`의 key를 삭제하거나 복제하지 말고 값을 사이트 사실에 맞게 바꿉니다. 특히
다음 문서 전용 값은 적용 전에 모두 없어야 합니다.

- `*.example.invalid`
- `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`
- 예제 노드 이름, NIC, Gateway VIP/pool, Forgejo/Registry endpoint

Secret 본문은 env에 넣지 않습니다. 통합 설치기의 다음 변수에는 root 소유 `0400`/`0600` 일반
파일의 절대경로만 기록합니다.

```dotenv
SADP_ARGO_REPO_TOKEN_FILE=/etc/sadp/secrets/<FORGEJO_READ_TOKEN_FILE>
SADP_DNS_TSIG_SECRET_FILE=/etc/sadp/secrets/<RFC2136_TSIG_FILE>
SADP_REGISTRY_PULL_DOCKERCONFIG=/etc/sadp/secrets/<PULL_DOCKERCONFIG_FILE>
SADP_REGISTRY_PUSH_DOCKERCONFIG=/etc/sadp/secrets/<PUSH_DOCKERCONFIG_FILE>
```

pull/push Docker config 경로와 권한은 분리합니다.

## 3. 필수 입력 묶음

정확한 key와 주석은 template이 기준입니다.

| 영역 | 확인할 사실 |
| --- | --- |
| 이름 | site/environment/cluster, Namespace, Gateway, TLS resource 이름 |
| 도메인 | base domain과 Portal/SSO/Rancher/OpenBao host |
| Git/Registry | Forgejo GitOps URL/revision, OCI host/project, immutable 초기 tag |
| 노드 | control-plane 1대, worker 2대의 hostname과 내부 IPv4 |
| 클러스터 | 기존 RKE2 Pod/Service CIDR, cluster DNS, API 주소 |
| NIC | 모든 노드에서 통일된 internal/external interface 이름 |
| 공개 경로 | public IP 소유, `nat`/`direct`, Gateway VIP/pool |
| egress | Squid host/port/client CIDR, upstream DNS |
| TLS | ACME mode, RFC2136 endpoint/key metadata, 진행 상태 |
| 인증 | Keycloak deployment/node placement/realm/client와 선택적 SAML IdP |
| 스토리지 | StorageClass와 AppGroup 고정 volume 크기 |

### NIC와 CIDR

```bash
ip -br link
ip -br -4 address
ip -4 route
```

interface 이름은 Canal `flannel.iface`, node identity, host firewall에 사용되므로 MAC 주소로
대체하지 않습니다. 현재 계약은 모든 노드에 같은 interface 이름을 요구합니다. 이름이 다르면
`systemd.link`로 통일합니다. MAC은 노드별 installer 인자의 선택적 이름 검증에만 사용합니다.

`GUARDED_INTERFACES`에는 현재 역할이 없지만 public 주소를 받을 수 있어 관리 port를 막아야 하는
NIC 이름을 넣습니다. internal NIC은 넣을 수 없고, NMS를 활성화하면 해당 NIC을 이 목록에서 빼고
`NMS_INTERFACE`로 옮깁니다.

Pod/Service CIDR과 cluster DNS는 이미 설치된 RKE2와 일치해야 합니다. 기존 클러스터의 주소를
바꾸는 migration 입력이 아닙니다.

### public mode

```bash
ip -brief address | grep '<PUBLIC_IP>'
```

| 결과 | `PUBLIC_EXPOSURE_MODE` | 경로 |
| --- | --- | --- |
| 노드에 없음 | `nat` | 경계 장비 80/443 → Gateway VIP 80/443 |
| 노드 external NIC에 있음 | `direct` | Envoy Service `externalIPs` |

`direct`는 Envoy Pod가 다른 노드에 있어도 전달하도록 `externalTrafficPolicy: Cluster`를 사용하므로
원본 client IP가 SNAT될 수 있습니다. `nat`는 hairpin NAT가 필요합니다. 외부 허용 port는 TCP
80/443뿐입니다.

### DNS-01

Let's Encrypt는 DNS를 변경하지 않습니다. SADP는 RFC2136/TSIG을 사용하며 direct 또는
`_acme-challenge` 위임 mode를 지원합니다. nameserver는 URL이 아니라 `<IPv4>:<port>`, TSIG
secret 값은 root-only 파일에 둡니다. 자세한 입력 조합은 [DNS-01 안내](letsencrypt-dns01.md)를
따릅니다.

TLS 진행값은 설정 선호가 아니라 완료 사실입니다.

```text
staging Certificate Ready
  → ACME_STAGING_VERIFIED=true
  → TLS_ISSUER_MODE=production
production Certificate Ready
  → EXISTING_GATEWAY_TLS_READY=true
```

클러스터가 HTTPS인데 env가 뒤처지면 다음 render가 listener를 HTTP로 되돌릴 수 있습니다.

### Keycloak 배치

외부 VM을 사용할 때는 기존 주소를 EndpointSlice로 연결합니다.

```dotenv
KEYCLOAK_DEPLOYMENT=external
KEYCLOAK_NODE_PLACEMENT=any
KEYCLOAK_EXTERNAL_ADDRESS=<PRIVATE_KEYCLOAK_IPV4>
KEYCLOAK_EXTERNAL_PORT=8080
```

RKE2 안에 설치할 때는 외부 주소를 비우고 node placement를 선택합니다.

```dotenv
KEYCLOAK_DEPLOYMENT=in-cluster
KEYCLOAK_NODE_PLACEMENT=control-plane
KEYCLOAK_EXTERNAL_ADDRESS=
KEYCLOAK_EXTERNAL_PORT=8080
```

`any`는 스케줄러가 일반 노드를 선택하는 기존 동작입니다. `control-plane`은 Keycloak과
PostgreSQL을 함께 RKE2 server에 고정하며 필요한 두 taint toleration도 생성합니다. external과
`control-plane`을 함께 쓰거나 알 수 없는 placement를 쓰면 `configure-site.py`가 거부합니다.
통합 설치 동작과 기존 로컬 PVC 이전 주의사항은
[설치 가이드](installation.md#control-plane-내부-keycloak-올인원-설치)를 따릅니다.

## 4. 검증·생성·드리프트 확인

읽기 전용 검증:

```bash
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --check
```

저장소 생성 결과까지 일치하는지 확인:

```bash
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --check-rendered
```

깨끗한 사이트 branch에서 생성:

```bash
git status --short
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --write
git diff --check
git diff -- contracts apps argocd platform rke
bash ./sadp --test
```

`--write`는 dirty worktree를 기본 거부합니다. 이미 존재하는 변경을 검토하고 보존한 경우에만
`--allow-dirty`를 씁니다. 이 명령은 cluster apply, Git commit/push, RKE2 restart를 하지 않습니다.

현재 checkout이 env에서 다시 만들어져도 같은지 안전하게 확인하려면 임시 복사본을 씁니다.

```bash
SADP_CHECK_DIR=$(mktemp -d)
cp -a . "${SADP_CHECK_DIR}/repo"
cd "${SADP_CHECK_DIR}/repo"
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --write --allow-dirty
diff -u '<ORIGINAL_REPOSITORY>/contracts/platform-production.yaml' \
  contracts/platform-production.yaml
```

검사가 끝나면 임시 경로를 확인한 뒤 제거합니다. diff가 있으면 원본 계약을 고치는 대신 env 또는
생성 로직을 먼저 바로잡습니다.

## 5. 선택 기능

### 용도별 system

`SYSTEMS`는 한 Envoy Gateway 아래 별도 domain, Namespace, Rancher Project, wildcard Certificate,
Keycloak을 가진 system을 추가합니다.

```dotenv
SYSTEMS=<SYSTEM>=<SYSTEM_DOMAIN>
SYSTEM_<SYSTEM>_KEYCLOAK_DEPLOYMENT=external
SYSTEM_<SYSTEM>_KEYCLOAK_REALM=<REALM>
SYSTEM_<SYSTEM>_PORTAL_CLIENT_ID=<CLIENT_ID>
SYSTEM_<SYSTEM>_KEYCLOAK_EXTERNAL_ADDRESS=<KEYCLOAK_IPV4>
SYSTEM_<SYSTEM>_KEYCLOAK_EXTERNAL_PORT=<PORT>
```

선언한 system마다 다섯 Keycloak key가 필요합니다. domain은 base domain의 하위여야 하며 이 기능은
ACME를 요구합니다. `in-cluster`이면 external address/port를 비웁니다.

### 외부 VM backend

```dotenv
EXTERNAL_SERVICES=<NAME>=<BACKEND_IPV4>:<PORT>
```

클러스터에는 Namespace, selector 없는 Service, EndpointSlice, Route, ReferenceGrant가 생성되고
public host는 `<NAME>.<BASE_DOMAIN>`입니다. Envoy와 backend 사이 기본 구간은 HTTP이며 endpoint는
IPv4 한 개입니다. backend 장애 시 Envoy가 대신 복구하지 않습니다.

외부 Git/Helm repository proxy는 Deployment에 `kubectl set env`로 넣지 않습니다. 통합 설치기가
`configure-argocd-repo.sh`를 호출해 Argo repository Secret의 `proxy`/`noProxy`를 계약과 맞추고
repo-server cache를 재시작합니다.

### machine-auth backend

```dotenv
MACHINE_AUTH_SERVICES=<NAME>=<NAMESPACE>/<SERVICE>:<PORT>
MACHINE_AUTH_CLIENTS=<KEYCLOAK_CLIENT_ID>
MACHINE_AUTH_ALLOWED_CIDRS=<SOURCE_IPV4_CIDR>
```

외부 Grafana 같은 기계 client의 JWT `azp`와 source CIDR을 함께 검사합니다. CIDR `/0`은
거부합니다. 자세한 절차는 [외부 관측](external-observability.md)을 사용합니다.

### NMS mode

| mode | 필요한 경로 |
| --- | --- |
| `disabled` | NMS 상세값과 allowed app을 비움 |
| `network` | 전용 NIC, gateway 내부 IP, SNAT IP, next-hop, destination CIDR/port |
| `api` | API base URL, destination CIDR/port, 선택적 role/token key 이름 |

세 mode는 상호 배타적입니다. actual NMS token은 OpenBao에 넣고 env에는 key 이름만 둡니다.
설치와 검증은 [네트워크 안내](network-egress.md)를 따릅니다.

### 외부 SAML IdP

alias, display name, provider ID, metadata URL, SSO URL 다섯 값을 모두 채우거나 모두 비웁니다.
provider는 현재 `saml`만 받습니다. 인증서와 password는 env에 넣지 않습니다. 외부 Keycloak과
remote 수렴은 [Keycloak 안내](keycloak-external.md)를 사용합니다.

## 6. 통합 설치 제어

| key | 동작 |
| --- | --- |
| `SADP_INSTALL_GITOPS` | Argo repository와 app-of-apps 구성 |
| `SADP_BUILD_IMAGES` | 기본 로컬 이미지 빌드·세 노드 import |
| `SADP_BUILD_NODE` | 빌드 worker 지정, 비우면 자동 선택 |
| `SADP_DEPLOY_APPS` | 기본 앱과 Portal 배포 |
| `SADP_RUN_VERIFY` | Portal 인증과 핵심 검수 실행 |

계획과 적용:

```bash
bash ./sadp --install --env-file /etc/sadp/site.env --phase all
bash ./sadp --install --env-file /etc/sadp/site.env --phase render --apply
sudo bash ./sadp --install --env-file /etc/sadp/site.env --phase node --apply
# 노드별 수동 restart/Ready 확인
sudo bash ./sadp --install --env-file /etc/sadp/site.env --phase cluster --apply
```

`all`은 계획 전용이라 `--apply`와 함께 쓸 수 없습니다. node/cluster의 no-apply mode는 실제 preflight
나 변경을 실행하지 않고 검증된 입력으로 실행할 명령을 출력합니다.

cluster apply는 Devtron/번들 Argo CD가 완전히 없으면 `versions.lock.yaml`의 고정 버전으로 먼저
설치합니다. 정확한 기존 설치는 유지하고 다른 버전·부분 설치는 자동 수리하지 않습니다. delivery
controller만 수동 준비할 때는 `sudo bash ./sadp --install-devtron`으로 계획을 확인한 뒤
`--apply`를 붙입니다.

## 7. 적용 전 체크

- env의 모든 문서용 domain/IP를 교체했습니다.
- 노드 이름, NIC, IP, Pod/Service CIDR이 실제 RKE2와 일치합니다.
- Gateway pool은 노드/DHCP/다른 장비와 겹치지 않습니다.
- root-only 파일은 root 소유 `0400`/`0600`이고 pull/push config가 분리됐습니다.
- 생성 diff에 Secret 값이나 개인 FQDN/IP를 공용 template에 넣지 않았습니다.
- Helm이 설치된 상태로 `bash ./sadp --test`가 통과했습니다.
- 결과를 사이트 전용 branch에 commit/push한 뒤 node/cluster를 실행합니다.
