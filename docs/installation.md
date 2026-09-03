# SADP 설치 가이드

대상은 기존 3노드 RKE2 위에 SADP를 설치하는 플랫폼 관리자입니다. SADP는 운영체제와 RKE2 자체를
설치하지 않습니다.

## 전체 흐름

```text
1. 선행 조건 확인
2. site.env와 root 전용 Secret 파일 준비
   ├─ 허용 주소 접속 테스트
   └─ Squid 및 네트워크 패키지 설치 준비
3. render 계획 → 생성 → 테스트 → commit/push
4. Squid 담당 노드에 node phase를 먼저 적용하고 egress 검증
5. 나머지 노드에 node phase 적용
   └─ 사람이 노드별 RKE2 재시작/Ready 확인
6. control-plane cluster phase
   ├─ Squid 재검증
   ├─ Prometheus/Loki/Alloy 이미지 선배포
   └─ Devtron/번들 Argo CD 보장 후 GitOps bootstrap
7. staging → production TLS 진행값 반영
8. 서비스 초기화·앱 배포
9. acceptance와 인수인계
```

`--apply`가 없으면 계획만 확인합니다. `--phase all --apply`는 node와 cluster 사이의 수동 재시작
경계를 건너뛰므로 거부됩니다.

## 설치 입력 방식 선택

### 방법 A — site.env 기반 원툴 설치

이미 사이트 값을 알고 있거나 반복 설치·자동화를 할 때 사용합니다.

```bash
sudo install -d -m 0700 /etc/sadp /etc/sadp/secrets
sudo install -m 0600 environments/site.env.example /etc/sadp/site.env
sudoedit /etc/sadp/site.env
```

### 방법 B — 질문·답변형 설치

처음 설치할 때 사용합니다. Enter는 현재값 유지, `-`는 선택값 비우기입니다. 마법사는 password,
token, private key 본문을 묻지 않고 파일 경로만 받습니다.

```bash
sudo bash ./sadp --install-wizard
```

답변으로 만든 파일도 동일한 검증기를 통과해야 `/etc/sadp/site.env`에 mode `0600`으로 저장됩니다.
마법사에서 바로 계획을 보려면 다음처럼 실행할 수 있습니다.

```bash
sudo bash ./sadp --install-wizard --phase all
```

기존 파일이 있으면 그 값을 기본 답변으로 사용합니다. 고급 `SYSTEMS`, 외부 서비스, machine-auth,
상위 SAML IdP 설정은 마법사 실행 후 [사이트 설정](site-configuration.md)에 따라 편집합니다.

## 1. 선행 조건 확인

### 관리 워크스테이션

- 저장소의 사이트 branch에 commit/push할 수 있음
- `bash`, Python 3, Git, Helm 사용 가능
- dirty worktree의 기존 변경을 구분할 수 있음

```bash
git status --short
bash ./sadp --list
helm version --short
```

### RKE2 클러스터

- server 1대 + worker 2대가 모두 `Ready`
- 세 노드의 내부 NIC 이름이 같음
- Pod CIDR, Service CIDR, Cluster DNS IP가 확정됨
- control-plane에서 RKE2 kubeconfig와 kubectl 사용 가능
- 기본 StorageClass가 정확히 하나 있음

```bash
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes -o wide

sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get storageclass
```

StorageClass가 전혀 없는 테스트베드는 다음 계획을 확인한 뒤 적용합니다.

```bash
sudo bash ./sadp --install-local-path-storage
sudo bash ./sadp --install-local-path-storage --apply
```

## 2. site.env와 root 전용 Secret 파일 준비

`site.env`에는 비밀이 아닌 사이트 사실과 Secret 파일의 절대경로만 적습니다. 전체 key는
[site.env 예제](../environments/site.env.example)와 [사이트 설정](site-configuration.md)을
참조합니다.

Prometheus/Loki/Alloy를 설치하지 않는 사이트는 `SADP_INSTALL_MONITORING=false`로 둡니다. 이 상태로
`MACHINE_AUTH_SERVICES`에 `monitoring/...` backend를 요청하면 configure/render가 fail-close하므로,
monitoring을 켜거나 backend 입력을 제거한 뒤 다시 렌더합니다.

### root 전용 파일

| 파일 | 용도 | 권한 |
| --- | --- | --- |
| `/etc/sadp/secrets/forgejo-read-token` | Argo Git read | root, `0400` 또는 `0600` |
| `/etc/sadp/secrets/rfc2136-tsig` | DNS-01 UPDATE | root, `0400` 또는 `0600` |
| `/etc/sadp/secrets/registry-pull-dockerconfig.json` | 이미지 pull | root, `0400` 또는 `0600` |
| `/etc/sadp/secrets/registry-push-dockerconfig.json` | 이미지 push | root, `0400` 또는 `0600` |

파일을 만든 뒤 내용은 출력하지 않고 메타데이터만 확인합니다.

```bash
sudo stat -c '%U %a %n' /etc/sadp/site.env /etc/sadp/secrets/*
```

### 허용 주소 접속 테스트

Squid 자체를 처음 설치하기 전에 Squid 담당 노드가 승인된 apt mirror 또는 기존 upstream proxy에
접속할 수 있어야 합니다. 조직 방화벽에는 저장소의 Squid allowlist와 사이트에서 추가한 정확한
hostname만 요청합니다. `*` wildcard나 전체 인터넷을 열지 않습니다.

승인된 대표 주소를 실제 설치 경로와 같은 방식으로 시험합니다.

```bash
curl --fail --location --max-time 20 https://<APPROVED_APT_MIRROR>/
curl --fail --location --max-time 20 https://<APPROVED_GIT_OR_REGISTRY>/
```

기존 upstream proxy로 bootstrap한다면 그 proxy를 명시합니다.

```bash
curl --fail --location --max-time 20 \
  --proxy http://<UPSTREAM_PROXY>:<PORT> \
  https://<APPROVED_APT_MIRROR>/
```

허용되지 않은 주소가 차단되는지도 조직의 승인된 테스트 대상과 방법으로 확인합니다. 실제 내부
주소나 credential이 포함된 URL을 로그에 남기지 않습니다.

### Squid 및 네트워크 패키지 설치 준비

각 노드에서 다음 도구를 확인합니다.

```bash
command -v bash python3 curl ip ss systemctl
```

Squid 담당 노드는 `apt-get update`와 `squid` package 설치가 가능한 bootstrap 경로가 필요합니다.
실제 Squid 설정, RKE2 containerd proxy, Docker proxy, interface guard는 render 결과가 나온 뒤
5~6단계의 node phase가 적용합니다. 이 시점에 임의 설정 파일을 먼저 만들지 않습니다.

### 외부 IdP 준비

SADP는 인증 서버, realm/tenant, client, 사용자 또는 그룹을 만들지 않습니다. `site.env`에는
외부 OIDC discovery에서 확인한 공개 endpoint와 claim 이름만 기록합니다.

```dotenv
IDENTITY_SOURCE_PROTOCOL=openid
OIDC_ISSUER=https://<IDP_HOST>/<ISSUER_PATH>
OIDC_AUTHORIZATION_ENDPOINT=https://<IDP_HOST>/<AUTHORIZATION_PATH>
OIDC_TOKEN_ENDPOINT=https://<IDP_HOST>/<TOKEN_PATH>
OIDC_JWKS_URI=https://<IDP_HOST>/<JWKS_PATH>
OIDC_END_SESSION_ENDPOINT=
OIDC_GROUPS_CLAIM=groups
OIDC_CLIENT_ID_CLAIM=azp
PORTAL_OIDC_CLIENT_ID=<PORTAL_CLIENT_ID>
```

상위 IdP가 SAML만 제공하면 외부 broker를 먼저 구성하고
`IDENTITY_SOURCE_PROTOCOL=saml`로 바꿉니다. SADP에는 그 broker의 OIDC endpoint를 넣습니다.

IdP 관리자가 Portal, secure-demo, OpenBao client와 callback을 직접 등록한 뒤 client secret을
root-only 파일로 전달해야 cluster phase를 적용할 수 있습니다. 정확한 callback과 파일명은
[외부 인증 연결](identity-provider.md)을 따릅니다. 설치기는 외부 IdP 관리 API를 호출하지 않습니다.


### Portal UI 공개 빌드값

필요한 사이트만 저장소 루트의 Git 밖 `.env`에 다음 공개값을 둡니다.

```dotenv
NEXT_PUBLIC_PAAS_VERSION=<VERSION>
NEXT_PUBLIC_PAAS_COPYRIGHT_YEAR=<YEAR>
NEXT_PUBLIC_GIT_BASE_URL=https://<GIT_HOST>
NEXT_PUBLIC_GIT_DEFAULT_ORG=<GIT_ORG>
NEXT_PUBLIC_PAAS_APP_DOMAIN=<BASE_DOMAIN>
NEXT_PUBLIC_PAAS_CLUSTER_NAME=<CLUSTER_NAME>
NEXT_PUBLIC_BAO_BASE_URL=https://<OPENBAO_HOST>
NEXT_PUBLIC_RANCHER_BASE_URL=https://<RANCHER_HOST>
```

`AUTH_SECRET`, OIDC client Secret, Forgejo/Registry token은 넣지 않습니다. 값 변경 후에는 Portal
이미지를 다시 빌드해야 합니다.

## 3. render 계획 → 생성 → 테스트 → commit/push

먼저 읽기 전용 계획을 확인합니다.

```bash
bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render
```

사이트 branch의 깨끗한 checkout에서 생성합니다.

```bash
bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render \
  --apply

git diff --check
git diff -- contracts apps argocd platform rke
bash ./sadp --test
```

생성물에 실제 Secret 값이나 다른 사이트 값이 없는지 검토한 뒤에만 commit/push합니다. node와
cluster는 현재 checkout이 `site.env`와 정확히 일치하지 않으면 중단됩니다.

## 4. Secret 없는 node bundle을 모든 노드에 배포

render → 전체 test/guard → diff 검토가 끝난 같은 control-plane checkout에서 bundle을 한 번만
만듭니다. 저장소 전체를 SCP하지 않습니다. bundle은 고정 allowlist의 node proxy installer,
생성 `proxy.env`, join token이 빈 server/agent template만 포함하며 `site.env`, 루트 `.env`, PEM,
private key, token, credential/state/backup은 포함하지 않습니다.

control-plane에서 생성하고 두 worker에 archive와 checksum 두 파일만 전송합니다.

```bash
install -d -m 0700 /var/tmp/sadp-node-transfer
bash ./sadp --node-bundle --output-dir /var/tmp/sadp-node-transfer
scp /var/tmp/sadp-node-transfer/sadp-node-bundle.tar.gz \
  /var/tmp/sadp-node-transfer/sadp-node-bundle.tar.gz.sha256 \
  <WORKER_NODE_1>:/var/tmp/
scp /var/tmp/sadp-node-transfer/sadp-node-bundle.tar.gz \
  /var/tmp/sadp-node-transfer/sadp-node-bundle.tar.gz.sha256 \
  <WORKER_NODE_2>:/var/tmp/
```

control-plane의 local archive는 root-only staging으로 복사합니다.

```bash
sudo install -d -m 0700 /var/lib/sadp/node-transfer /opt/sadp-node
sudo install -m 0600 /var/tmp/sadp-node-transfer/sadp-node-bundle.tar.gz \
  /var/tmp/sadp-node-transfer/sadp-node-bundle.tar.gz.sha256 \
  /var/lib/sadp/node-transfer/
```

SCP를 받은 각 worker에서도 일반 사용자 영역에서 checksum만 확인한 뒤 root가 같은 파일을 다시
읽는 경쟁을 피하도록 먼저 root-only staging으로 복사합니다.

```bash
sudo install -d -m 0700 /var/lib/sadp/node-transfer /opt/sadp-node
sudo install -m 0600 /var/tmp/sadp-node-bundle.tar.gz \
  /var/tmp/sadp-node-bundle.tar.gz.sha256 /var/lib/sadp/node-transfer/
```

이후 control-plane과 모든 worker에서 공통으로 outer checksum → extract → inner manifest → local
plan/apply 순서로 실행합니다. mode 0700 디렉터리의 `cd`도 root shell 안에서 수행합니다.

```bash
sudo bash -c 'cd /var/lib/sadp/node-transfer && sha256sum -c sadp-node-bundle.tar.gz.sha256'
sudo bash -c 'umask 077; tar --no-same-owner -xzf /var/lib/sadp/node-transfer/sadp-node-bundle.tar.gz -C /opt/sadp-node'
sudo bash -c 'cd /opt/sadp-node/sadp-node-bundle && sha256sum -c MANIFEST.sha256'
sudo bash /opt/sadp-node/sadp-node-bundle/sadp --install-containerd-proxy
sudo bash /opt/sadp-node/sadp-node-bundle/sadp --install-containerd-proxy --apply
```

모든 노드가 같은 outer digest를 사용해야 합니다. join token과 `site.env`는 bundle로 옮기지 않고
각 노드의 기존 root-only 경로에 유지합니다. 다음 표를 채워 한 노드라도 빠지면 설치 완료로
보고하지 않습니다.

| expected node | 전송 완료 | outer checksum | inner manifest | local plan/apply/check | restart 후 Ready |
| --- | --- | --- | --- | --- | --- |
| `<CONTROL_PLANE_NODE>` |  |  |  |  |  |
| `<WORKER_NODE_1>` |  |  |  |  |  |
| `<WORKER_NODE_2>` |  |  |  |  |  |

신규 노드/초기 설치에는 이 bundle SCP 절차가 필수입니다. 이미 실행 중인 cluster의 proxy drift만
고치면 [네트워크 Runbook](network-egress.md)의 중앙 DaemonSet plan/apply를 우선 사용할 수 있습니다.

## 5. Squid 담당 노드부터 node phase 적용

세 노드는 같은 Git revision과 같은 `/etc/sadp/site.env`를 사용합니다. `SQUID_INTERNAL_IP`를 가진
노드에서 먼저 계획과 적용을 실행합니다.

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase node

sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase node \
  --apply
```

node phase는 Squid package와 계약 설정을 먼저 적용한 뒤 RKE2 설정, NIC identity, interface guard,
containerd proxy를 적용합니다. 설치 직후 허용·차단 경로를 검증합니다.

```bash
sudo bash ./sadp --install-squid --check
bash ./sadp --verify-squid
```

검증이 실패하면 다른 노드로 진행하지 않습니다.

## 6. 나머지 노드 적용과 수동 재시작

control-plane과 각 worker에서 같은 node 계획·적용 명령을 실행합니다. 설치기는 RKE2와 Docker를
자동 재시작하지 않습니다.

권장 순서는 다음과 같습니다.

1. worker 한 대를 drain합니다.
2. 그 노드에서 `rke2-agent`를 재시작합니다.
3. Node와 Canal Ready를 확인한 뒤 uncordon합니다.
4. 다른 worker를 반복합니다.
5. 유지보수 창에서 control-plane의 `rke2-server`를 재시작합니다.
6. control-plane의 Docker를 재시작하고 proxy를 확인합니다.

```bash
sudo systemctl restart docker
sudo bash ./sadp --install-docker-proxy --check
```

모든 노드가 Ready가 되기 전에는 cluster phase로 넘어가지 않습니다.

각 노드에서 재시작 뒤 bundle의 local check까지 수행합니다.

```bash
sudo bash /opt/sadp-node/sadp-node-bundle/sadp --install-containerd-proxy --check
```

## 7. control-plane cluster phase

먼저 계획을 확인하고 적용합니다.

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase cluster

sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase cluster \
  --apply
```

cluster phase는 다음 순서를 강제합니다.

1. Squid의 허용·차단 egress 재검증
2. StorageClass 준비, 3노드 topology와 모든 Linux node의 digest 고정 CRI pull preflight
3. Docker daemon proxy 계약 확인
4. Prometheus/Loki/Alloy 이미지를 모든 노드에 선배포
5. Devtron과 번들 Argo CD 확인, 완전 부재 시 고정 버전 설치
6. RFC2136 TSIG Secret 적용
7. Argo repository, AppProject, app-of-apps bootstrap
8. child Application 생성 대기
9. 노출 YAML의 Namespace/HTTPRoute backendRef를 parser로 읽어 누락 Namespace 선행 생성
10. SADP 기반 플랫폼 설치: cert-manager Ready → controller node의 authoritative DNS TCP/UDP 53
    preflight → wildcard Certificate/Secret Ready → Gateway/OpenBao 기반 리소스
11. TLS 완료 상태와 실제 Certificate/Gateway가 모두 일치할 때만 외부 OIDC/OpenBao 소비 설정
12. Gateway HTTPS Accepted/Programmed와 Service 443 → OpenBao Pod 내부 discovery
    HTTPS 200/JSON/issuer 일치 → `auth/oidc/config` 적용과 안전한 설정 검증

다른 Devtron 버전이나 불완전한 기존 설치는 자동 덮어쓰지 않고 중단합니다.

### 외부 image archive를 다시 동기화할 때

cluster phase가 사용하는 운영 목록과 단일 진입점은 다음과 같습니다. `docker pull`, `docker save`,
기존 archive 반복 import로 우회하지 않습니다.

```bash
sudo bash ./sadp --sync-images \
  --image-list platform/monitoring/images.txt
```

정상 순서는 모든 Kubernetes Linux node의 `operatingSystem/architecture` 확인 → RKE2 containerd의
전용 임시 Namespace에서 각 image/platform 새 pull → OCI export → `manifest.json`의 Config/Layers와
모든 `blobs/sha256/*` 재계산 → 모든 Linux node에 동일 archive 전송 → 해당 node platform import →
각 예상 ref의 `ctr images check --quiet` complete 확인 → loader/Namespace 정리입니다. archive 검증이
끝나기 전에는 DaemonSet을 만들거나 node로 한 바이트도 보내지 않습니다.

임시 loader는 이미 모든 node에서 Ready인 RKE2 Canal image를 `IfNotPresent`로 재사용하고 Linux
selector, 모든 taint toleration, service account token 차단을 적용합니다. privileged와 RKE2 bin 및
containerd socket hostPath는 검증 archive를 import하는 동안만 필요하며 성공·실패·signal에서
DaemonSet을 삭제합니다. digest 입력은 원 digest와 같은 target임을 확인한
`:sadp-sha256-<digest>` alias로 export하므로 workload는 출력된 alias를 참조합니다.

검증 archive와 checksum을 사고 분석용으로 남길 때만 `--keep-archive`를 추가합니다. 둘은 mode
`0600`, 상위 상태 디렉터리는 `0700`입니다. 검증에 실패한 archive는 root-only quarantine으로
옮기며 node 전송에 재사용하지 않습니다.

## 8. staging → production TLS 진행값 반영

TLS 진행값은 설정이 아니라 완료한 단계의 기록입니다. cluster가 앞서 있는데 `site.env`가 뒤처지면
다음 render가 HTTPS 경로를 과거 상태로 되돌릴 수 있습니다.

### staging 발급 확인 후

```dotenv
ACME_STAGING_VERIFIED=true
TLS_ISSUER_MODE=production
```

3단계의 render → test → commit/push를 반복하고 cluster phase를 다시 실행합니다.

### production wildcard Secret Ready 후

```dotenv
EXISTING_GATEWAY_TLS_READY=true
```

다시 render → test → commit/push → cluster를 실행합니다. HTTPS listener와 HTTP → HTTPS redirect가
활성화됩니다. 상세 절차는 [DNS-01 Runbook](letsencrypt-dns01.md)을 따릅니다.

## 9. 서비스 초기화·앱 배포

`EXISTING_GATEWAY_TLS_READY=true`인 cluster phase는 다음 작업을 이어서 실행합니다.

- SADP 이미지 build와 세 노드 import
- 외부 OIDC client secret을 OpenBao→ESO 경로에 연결
- OpenBao 초기화, auth, KV 정책 수렴
- ESO와 Reloader 확인
- hello, secure-demo, Portal 배포
- Portal 인증과 핵심 acceptance

`SADP_INSTALL_MONITORING`, `SADP_BUILD_IMAGES`, `SADP_DEPLOY_APPS`, `SADP_RUN_VERIFY`로 선택할 수
있습니다. 정상 설치에서는 개별 스크립트를 임의 순서로 다시 조합하지 않습니다.

### OpenBao OIDC 순서와 단계 재실행

통합 설치는 아래 순서를 건너뛰지 않습니다. 앞 단계가 실패하면 뒤 단계는 실행하지 않으며,
`EXISTING_GATEWAY_TLS_READY=true`라는 입력만으로 성공 처리하지 않습니다.

```text
cert-manager controller Ready
  → controller가 실제 배치된 node의 authoritative DNS TCP/UDP 경로
  → wildcard Certificate Ready와 대상 TLS Secret 존재
  → Gateway HTTPS listener Accepted=True, Programmed=True
  → Envoy Gateway Service 443 존재
  → OpenBao Pod 내부 discovery HTTPS 200와 JSON parse
  → discovery issuer == 계약 외부 OIDC issuer
  → OpenBao auth/oidc/config 멱등 적용
  → Secret을 제외한 공개 설정과 user role 재검증
```

DNS-01이 특정 node에서만 가능하면 생성 Deployment를 patch하지 않습니다.
`site.env`의 `CERT_MANAGER_NODE_PLACEMENT=control-plane`을 선택하고 render → test → commit/push로
`nodeSelector`와 control-plane taint `toleration`을 생성한 뒤 아래 plan/apply를 실행합니다.

```bash
sudo bash ./sadp --preflight-dns01
sudo bash ./sadp --preflight-dns01 --apply
```

일반 인터넷 DNS 질의 성공은 이 검사를 대신하지 않습니다. probe는 실제 Ready controller Pod의
node마다 host network에서 RFC2136 authoritative endpoint의 TCP 연결과 UDP SOA authoritative
응답을 확인하고 삭제됩니다. 실패 출력은 node, `authoritative-dns`, `no-route|timeout|refused`만
남기며 목적지 주소나 DNS 응답 본문을 출력하지 않습니다.

OIDC 단계만 다시 실행할 때는 전체 설치를 반복하지 않습니다. 첫 명령은 실제 preflight만 수행하고,
두 번째 명령도 같은 preflight를 다시 통과한 뒤에만 설정을 적용합니다.

```bash
sudo bash ./sadp --configure-openbao-oidc
sudo bash ./sadp --configure-openbao-oidc --apply
```

기존 설정이 정상이면 공개 필드 일치만 보고하며 client Secret은 읽거나 출력하지 않습니다. 적용은
root-only client Secret 파일을 stdin JSON으로 다시 보내 동일 상태로 수렴합니다. 최종 `[OK]`는
공개 OIDC 설정과 최소 권한 `user` role을 다시 읽은 안전 검증 결과입니다. 실제 브라우저 로그인이
가능한 유지보수 창에서는 OpenBao UI의 외부 OIDC 로그인을 추가 확인합니다.

대표 `error checking oidc discovery URL`은 원인 자체가 아니라 OpenBao API의 요약입니다. 새
preflight의 원인별 조치는 다음과 같습니다.

| 증상 | 원인 판별 | 복구 |
| --- | --- | --- |
| DNS 해석 실패 | OpenBao Pod의 issuer host 조회 실패 | CoreDNS split-horizon과 Gateway VIP 레코드를 복구 |
| TLS 인증서/CA 오류 | HTTPS client의 certificate/TLS 검증 실패 | wildcard SAN·신뢰 체인·만료와 Pod CA trust를 복구 |
| Gateway listener 미준비 | `Accepted`/`Programmed`가 `True`가 아님 | listener condition과 renderer/Argo drift를 복구 |
| 인증서 Secret 없음 | Certificate `spec.secretName` 대상이 없음 | DNS-01/Certificate Ready를 먼저 복구; Secret 본문은 출력하지 않음 |
| cert-manager DNS-01 route 실패 | controller node probe가 `no-route`, `timeout`, `refused` | node 방화벽/route와 placement 계약을 고친 뒤 DNS preflight부터 재실행 |
| OIDC issuer 불일치 | HTTP 200 JSON의 `issuer`가 계약과 정확히 다름 | 외부 IdP discovery와 계약 issuer를 byte-for-byte 수렴 |

상세 복구 순서는 [복구 Runbook](recovery.md#9-openbao-oidc-discovery-오류-복구)을 따릅니다.

OpenBao가 최초 initialized된 직후 또는 재기동 뒤 sealed이면 cluster phase는 ExternalSecret을
기다리지 않고 의도적으로 중단합니다. control-plane에서 복구 재료를 사용하지 않는 plan을 먼저
확인하고, sealed일 때만 명시적으로 적용합니다.

```bash
sudo bash ./sadp --unseal-openbao
sudo bash ./sadp --unseal-openbao --apply
```

이미 unsealed이면 두 번째 명령은 생략합니다. unseal 성공 뒤 같은 Git revision에서 원래 cluster
phase를 다시 실행합니다. bootstrap 순서는 다음과 같이 고정됩니다.

```text
OpenBao Pod Running
  → initialized/sealed 검사
  → 명시적 unseal
  → active endpoint와 Pod Ready
  → SecretStore/ClusterSecretStore Ready
  → ExternalSecret force-sync
  → ExternalSecret Ready
  → 대상 Secret 객체 존재
  → 소비 workload rollout
```

`error: timed out waiting for the condition on externalsecrets/<EXTERNAL_SECRET_NAME>`은 설치 성공이
아니라 `Ready=True`에 도달하지 못한 실패입니다. 원인이 OpenBao seal이면 ESO provider가 HTTP 503
`Vault is sealed`를 받고 Store가 일시적으로 Ready가 아닐 수 있습니다. 설치 스크립트는 timeout
한 줄 대신 ExternalSecret/Store의 Ready status·reason·message, 자동 판별한 Store kind/name과 대상
Secret 객체 존재 여부만 출력합니다. Secret data는 읽거나 출력하지 않습니다. 상세 복구는
[복구 Runbook](recovery.md#7-openbao-sealexternalsecret-timeout-복구)을 따릅니다.

### control-plane 운영 코드 배포

Git을 사용할 수 있으면 변경을 검토해 commit/push한 뒤 control-plane에서 동일 revision을
checkout합니다. worker에는 Kubernetes API/OpenBao/ESO manager와 unseal 명령을 배포하지 않습니다.

```bash
git rev-parse HEAD
git push <REMOTE> <BRANCH>

# control-plane
git fetch <REMOTE>
git checkout <REVISION>
test "$(git rev-parse HEAD)" = '<REVISION>'
```

Git 전송을 사용할 수 없을 때만 저장소 전체 대신 코드 allowlist의 운영 overlay를 만듭니다. 이
archive에는 `site.env`, 루트 `.env`, OpenBao 초기화 파일, root token, unseal key, credential,
state, backup, 인증서와 private key가 들어가지 않습니다.

생성 서버:

```bash
bash ./sadp --ops-bundle --output-dir /var/tmp/sadp-transfer
scp /var/tmp/sadp-transfer/sadp-ops-bundle.tar.gz \
  /var/tmp/sadp-transfer/sadp-ops-bundle.tar.gz.sha256 \
  <CONTROL_PLANE>:/var/tmp/
```

대상 control-plane의 기존 `/opt/sadp` checkout 위에 같은 경로로 적용합니다.

```bash
sudo install -d -m 0700 /var/lib/sadp/transfer /opt/sadp
sudo install -m 0600 /var/tmp/sadp-ops-bundle.tar.gz \
  /var/tmp/sadp-ops-bundle.tar.gz.sha256 /var/lib/sadp/transfer/
sudo bash -c \
  'cd /var/lib/sadp/transfer && sha256sum -c sadp-ops-bundle.tar.gz.sha256'
sudo bash -c \
  'umask 077; tar --no-same-owner -xzf /var/lib/sadp/transfer/sadp-ops-bundle.tar.gz \
   -C /opt/sadp'
sudo bash -c 'cd /opt/sadp && sha256sum -c MANIFEST.sha256'
```

이 OpenBao/ESO 변경은 control-plane 전용이므로 worker SCP는 불필요합니다. node 공통 스크립트도
함께 바뀐 별도 변경에서는 `--node-bundle`로 만든 하나의 archive digest를 control-plane과 모든
server/worker에 동일하게 배포하고 각 노드에서 검증합니다.

## 10. acceptance와 인수인계

control-plane에서 확인합니다.

```bash
sudo bash ./sadp --verify-portal-auth
sudo bash ./sadp --verify-testbed
```

브라우저에서는 공개 앱이 미로그인 상태로 열리는지, SSO 앱과 Portal이 외부 OIDC 로그인 뒤 열리는지,
internal 앱에 외부 Route가 없는지 확인합니다.

인수인계에는 다음만 기록합니다.

- site/cluster 이름과 배포 Git revision
- Portal과 관리 서비스 주소
- 운영 담당자와 장애 연락 경로
- `site.env`와 root 전용 파일의 보관 위치·소유자
- token·인증서 회전 일정
- 마지막 백업·복원 시험과 acceptance 결과

Secret 본문은 인수인계 문서에 복사하지 않습니다. 설치 뒤 운영은
[관리자 가이드](administrator-guide.md)를 따릅니다.

## 설치가 멈췄을 때

| 증상 | 의미 | 다음 확인 |
| --- | --- | --- |
| 예제 domain/IP 적용 거부 | 문서용 값이 남음 | [사이트 설정](site-configuration.md) |
| 생성물이 env와 다름 | render 결과 미반영 | 3단계 diff와 commit/push |
| hostname을 찾지 못함 | 노드 이름 불일치 | `hostname -s`, `WORKER_NODES` |
| Squid 허용 주소 실패 | bootstrap/allowlist/daemon 문제 | [네트워크](network-egress.md) |
| `ctr: content digest sha256:<DIGEST>: not found` | archive manifest가 참조한 config/layer blob 누락 | 손상 archive 반복 import를 중단하고 위 `--sync-images --image-list platform/monitoring/images.txt`로 새 pull/export부터 재실행 |
| `timed out waiting for ... externalsecrets` | ExternalSecret `Ready=True` 실패; OpenBao sealed/Store 503 가능 | 9단계의 `--unseal-openbao` plan과 [복구 Runbook](recovery.md#7-openbao-sealexternalsecret-timeout-복구) |
| TLS 준비 단계에서 종료 | 정상 staged install | 8단계 |
| Challenge 실패 | DNS-01/RFC2136 문제 | [DNS-01](letsencrypt-dns01.md) |
| `error checking oidc discovery URL` | API 호출 전 preflight가 잡아야 할 DNS/TLS/Gateway/issuer 문제 | `--configure-openbao-oidc` plan과 [OIDC 복구](recovery.md#9-openbao-oidc-discovery-오류-복구) |
| 공개 URL 연결 실패 | NAT/direct/Gateway/NIC 문제 | [네트워크](network-egress.md) |
