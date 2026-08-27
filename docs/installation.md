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
4~5단계의 node phase가 적용합니다. 이 시점에 임의 설정 파일을 먼저 만들지 않습니다.

### control-plane 내부 Keycloak 올인원 설치

외부 Keycloak 없이 control-plane에 Keycloak과 PostgreSQL을 고정하려면 다음 값을 사용합니다.

```dotenv
KEYCLOAK_DEPLOYMENT=in-cluster
KEYCLOAK_NODE_PLACEMENT=control-plane
```

일반 worker 스케줄링은 `KEYCLOAK_NODE_PLACEMENT=any`, 외부 Keycloak은
`KEYCLOAK_DEPLOYMENT=external`을 사용합니다.

이미 실행 중인 Keycloak만 별도로 진단할 때는 root 전용 파일을 사용해 계획을 먼저 확인합니다.
정상 신규 설치에서는 cluster phase가 이 작업을 수행하므로 별도로 실행하지 않습니다.

```bash
sudo bash ./sadp --configure-keycloak \
  --server-url https://<KEYCLOAK_HOST> \
  --admin-user-file /etc/sadp/secrets/keycloak-admin-user \
  --admin-password-file /etc/sadp/secrets/keycloak-admin-password

sudo bash ./sadp --configure-keycloak \
  --server-url https://<KEYCLOAK_HOST> \
  --admin-user-file /etc/sadp/secrets/keycloak-admin-user \
  --admin-password-file /etc/sadp/secrets/keycloak-admin-password \
  --apply
```

### Portal UI 공개 빌드값

필요한 사이트만 저장소 루트의 Git 밖 `.env`에 다음 공개값을 둡니다.

```dotenv
NEXT_PUBLIC_PAAS_VERSION=<VERSION>
NEXT_PUBLIC_PAAS_COPYRIGHT_YEAR=<YEAR>
NEXT_PUBLIC_GIT_BASE_URL=https://<GIT_HOST>
NEXT_PUBLIC_GIT_DEFAULT_ORG=<GIT_ORG>
NEXT_PUBLIC_SSO_BASE_URL=https://<SSO_HOST>
NEXT_PUBLIC_SSO_REALM=<REALM>
NEXT_PUBLIC_PAAS_APP_DOMAIN=<BASE_DOMAIN>
NEXT_PUBLIC_PAAS_CLUSTER_NAME=<CLUSTER_NAME>
NEXT_PUBLIC_BAO_BASE_URL=https://<OPENBAO_HOST>
NEXT_PUBLIC_RANCHER_BASE_URL=https://<RANCHER_HOST>
NEXT_PUBLIC_LEGACY_SSO_BASE_URL=https://<LEGACY_SSO_HOST>
```

`AUTH_SECRET`, Keycloak client Secret, Forgejo/Registry token은 넣지 않습니다. 값 변경 후에는 Portal
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

## 4. Squid 담당 노드부터 node phase 적용

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

## 5. 나머지 노드 적용과 수동 재시작

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

## 6. control-plane cluster phase

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
2. StorageClass 준비와 3노드 RKE2 preflight
3. Docker daemon proxy 계약 확인
4. Prometheus/Loki/Alloy 이미지를 모든 노드에 선배포
5. Devtron과 번들 Argo CD 확인, 완전 부재 시 고정 버전 설치
6. RFC2136 TSIG Secret 적용
7. Argo repository, AppProject, app-of-apps bootstrap
8. child Application 생성 대기
9. SADP 기반 플랫폼 설치

다른 Devtron 버전이나 불완전한 기존 설치는 자동 덮어쓰지 않고 중단합니다.

## 7. staging → production TLS 진행값 반영

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

## 8. 서비스 초기화·앱 배포

`EXISTING_GATEWAY_TLS_READY=true`인 cluster phase는 다음 작업을 이어서 실행합니다.

- SADP 이미지 build와 세 노드 import
- Keycloak realm/client/group 수렴
- OpenBao 초기화, auth, KV 정책 수렴
- ESO와 Reloader 확인
- hello, secure-demo, Portal 배포
- Portal 인증과 핵심 acceptance

`SADP_BUILD_IMAGES`, `SADP_DEPLOY_APPS`, `SADP_RUN_VERIFY`로 선택할 수 있습니다. 정상 설치에서는
개별 스크립트를 임의 순서로 다시 조합하지 않습니다.

## 9. acceptance와 인수인계

control-plane에서 확인합니다.

```bash
sudo bash ./sadp --verify-portal-auth
sudo bash ./sadp --verify-testbed
```

브라우저에서는 공개 앱이 미로그인 상태로 열리는지, SSO 앱과 Portal이 Keycloak 로그인 뒤 열리는지,
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
| TLS 준비 단계에서 종료 | 정상 staged install | 7단계 |
| Challenge 실패 | DNS-01/RFC2136 문제 | [DNS-01](letsencrypt-dns01.md) |
| 공개 URL 연결 실패 | NAT/direct/Gateway/NIC 문제 | [네트워크](network-egress.md) |
