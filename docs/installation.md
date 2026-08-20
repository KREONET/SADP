# SADP 설치 가이드

> 문서 경로: [문서 홈](README.md) → [관리자 가이드](administrator-guide.md) → 설치
> 대상: 새 SADP 사이트를 구축하는 플랫폼 관리자
> 결과: 기존 3노드 RKE2 위에 SADP 플랫폼과 기본 앱을 GitOps로 설치

이 문서는 `site.env` 기반 통합 설치기만 주 경로로 설명합니다. 개별 스크립트는 장애 복구와
원인 분리를 위한 참조이며 정상 설치에서 순서대로 직접 조합하지 않습니다.

> [!WARNING]
> SADP는 운영체제와 RKE2 자체를 설치하지 않습니다. RKE2 server 1대와 worker 2대가 이미
> `Ready`여야 합니다.

## 설치 흐름

```text
1. 선행 조건 확인
2. site.env와 root 전용 Secret 파일 준비
3. render 계획 → 생성 → 테스트 → commit/push
4. 필요한 서드파티 이미지 준비
5. 각 노드에 node phase 적용
   → 사람이 노드별 RKE2 재시작/Ready 확인
6. control-plane에서 Devtron/번들 Argo CD 보장 후 GitOps bootstrap
7. staging → production TLS 진행값 반영
8. 서비스 초기화·앱 배포
9. acceptance와 인수인계
```

`--phase all --apply`는 지원하지 않습니다. 노드 재시작 확인 전에 클러스터 단계를 실행하지
못하도록 의도적으로 분리했습니다.

## 1. 선행 조건

### 클러스터

- RKE2 server 1대와 worker 2대가 모두 `Ready`
- 기본 StorageClass 1개와 동작하는 dynamic provisioning
- 각 노드의 내부 NIC 이름이 동일하거나 `systemd.link`로 통일됨
- control-plane에서 worker로 관리자 작업이 가능한 네트워크 경로

```bash
kubectl get nodes -o wide
kubectl get storageclass
```

클러스터 전체 선행 검사는 control-plane에서 실행합니다.

```bash
sudo bash ./sadp --preflight
```

이 검사는 RKE2 전용 kubeconfig와 kubectl을 사용해 server 1대와 worker 2대, 정확히 3대가 모두
Ready인지와 기본 StorageClass가 정확히 1개인지 강제합니다. 자신이 만든 고유
`sadp-preflight-*` Namespace/PVC로
실제 provisioning을 확인하고 성공·실패 모두 해당 임시 Namespace만 정리합니다.

Devtron과 번들 Argo CD는 원툴 cluster apply의 사전 설치 조건이 아닙니다. 둘이 완전히 없으면
`versions.lock.yaml`의 Devtron app/chart 고정 버전으로 자동 설치합니다. 정확한 기존 설치는
건드리지 않으며, 다른 버전이나 부분 설치는 자동 upgrade·downgrade·채택하지 않고 중단합니다.

사람이 delivery controller를 먼저 준비하려는 경우에만 같은 control-plane에서 계획과 적용을
분리합니다. raw `helm install`은 승인된 수동 경로가 아닙니다.

```bash
sudo bash ./sadp --install-devtron
sudo bash ./sadp --install-devtron --apply

kubectl -n devtroncd get deployment/devtron deployment/argocd-repo-server
kubectl -n devtroncd get statefulset/argocd-application-controller
kubectl -n devtroncd get installer/installer-devtron -o jsonpath='{.status.sync.status}'
kubectl get crd applications.argoproj.io
```

현재 계약은 Devtron app `1.5.0`, 공식 chart `0.22.92`, Namespace `devtroncd`, Helm release
`devtron`, `installer.modules={cicd}`, `argo-cd.enabled=true`입니다. 숫자의 SSOT는
`versions.lock.yaml`이며 버전 변경은 설치기와 회귀 시험을 함께 갱신합니다. Devtron UI Service는
별도 외부 진입점을 만들지 않도록 `ClusterIP`로 고정하고, installer/microservice는 렌더된
Squid/NO_PROXY 계약을 사용합니다.

첫 설치는 Devtron Installer가 `Applied`가 될 때까지 최대 30분 기다린 뒤 핵심 Devtron/Argo CD
rollout을 확인합니다. 승인 버전이라도 설정이 다르거나 Installer/워크로드가 Ready가 아니면 자동으로
재적용하지 않고 `devtroncd` 상태 확인을 요구합니다.

### 설치 호스트 도구

- Bash 4+
- Python 3와 PyYAML
- `kubectl`, Helm `versions.lock.yaml`의 버전
- `curl`, `jq`, `openssl`, `ssh`
- 이미지 빌드/동기화를 사용할 경우 Docker

```bash
python3 --version
kubectl version --client
helm version --short
bash ./sadp --list
```

`render-test.sh`는 Helm이 없으면 정상 profile을 검증하지 못합니다. Helm 없이 일부 금지 profile이
`[OK]`로 보인 결과를 전체 통과로 기록하지 않습니다.

### 네트워크와 외부 시스템

설치 전에 다음 담당자와 값을 확정합니다.

| 담당 | 필요한 결정 |
| --- | --- |
| 네트워크 | 내부/외부 NIC, 노드 IP, Gateway VIP/pool, NAT 또는 direct, 방화벽 |
| DNS | base domain, wildcard/apex record, RFC2136 또는 `_acme-challenge` 위임 |
| GitOps | Forgejo repository/revision, bot 계정 |
| Registry | OCI host/project, push 계정과 pull 계정 분리 |
| 인증 | Keycloak 배치, realm/client, 선택적 외부 SAML IdP |
| 스토리지 | 기본 StorageClass, AppGroup volume 크기 |

## 2. 입력과 Secret 준비

### `site.env`

실제 사이트 파일은 Git 밖에 둡니다.

```bash
sudo install -d -m 0700 /etc/sadp /etc/sadp/secrets
sudo install -m 0600 environments/site.env.example /etc/sadp/site.env
sudoedit /etc/sadp/site.env
```

반드시 교체할 대표 값:

- `*.example.invalid` 주소
- `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` 문서용 IP
- control-plane/worker 이름과 내부 IP
- NIC 이름, Pod/Service CIDR, Gateway VIP/pool
- Forgejo/Registry endpoint와 project
- DNS-01, Keycloak, StorageClass 설정

통합 설치기는 문서용 endpoint/IP가 남은 상태에서 `--apply`를 거부합니다. 전체 필드 설명은
[사이트 설정 참조](site-configuration.md)를 사용합니다.

### root 전용 파일

`site.env`에는 Secret 본문 대신 파일 경로만 적습니다.

| 변수 | 파일 내용 | 최소 권한 |
| --- | --- | --- |
| `SADP_ARGO_REPO_TOKEN_FILE` | Forgejo read token | root, `0400`/`0600` |
| `SADP_DNS_TSIG_SECRET_FILE` | RFC2136 TSIG secret | root, `0400`/`0600` |
| `SADP_REGISTRY_PULL_DOCKERCONFIG` | pull 전용 Docker config | root, `0400`/`0600` |
| `SADP_REGISTRY_PUSH_DOCKERCONFIG` | push 전용 Docker config | root, `0400`/`0600` |

```bash
sudo chown root:root /etc/sadp/secrets/*
sudo chmod 0600 /etc/sadp/secrets/*
```

pull과 push credential은 서로 달라야 합니다. token과 Docker config를 문서나 명령행 인자로
직접 붙이지 않습니다.

### Portal UI 빌드 환경

브라우저 번들에 들어가도 되는 공개값만 저장소 루트 `.env`에 선택적으로 둡니다.

```dotenv
NEXT_PUBLIC_PAAS_VERSION=<VERSION>
NEXT_PUBLIC_PAAS_COPYRIGHT_YEAR=<YEAR>
NEXT_PUBLIC_GIT_BASE_URL=https://<FORGEJO_HOST>
NEXT_PUBLIC_GIT_DEFAULT_ORG=<FORGEJO_ORG>
NEXT_PUBLIC_SSO_BASE_URL=https://<SSO_HOST>
NEXT_PUBLIC_SSO_REALM=<REALM>
NEXT_PUBLIC_PAAS_APP_DOMAIN=<BASE_DOMAIN>
NEXT_PUBLIC_PAAS_CLUSTER_NAME=<CLUSTER_NAME>
NEXT_PUBLIC_BAO_BASE_URL=https://<OPENBAO_HOST>
NEXT_PUBLIC_RANCHER_BASE_URL=https://<RANCHER_HOST>
NEXT_PUBLIC_LEGACY_SSO_BASE_URL=https://<LEGACY_SSO_HOST>
```

허용 key의 SSOT는 `apps/portal-lite/ui/scripts/portal-ui-public-env-keys.json`입니다.

```bash
python3 scripts/site/portal-ui-build-env.py --env-file .env --format check
```

`AUTH_SECRET`, Keycloak client secret, Forgejo/Registry/NMS token은 이 파일에 넣지 않습니다.
`NEXT_PUBLIC_*` 변경은 이미지를 다시 빌드해야 반영됩니다.

## 3. 설정 렌더와 Git 반영

### 읽기 전용 계획

```bash
bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render
```

이 단계는 입력, CIDR/port 충돌, URL, Secret 파일 경로 메타데이터를 검사하지만 저장소와
클러스터를 바꾸지 않습니다.

### 생성

사이트 전용 branch의 깨끗한 checkout에서 실행합니다.

```bash
git status --short

bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase render \
  --apply

git diff --check
git diff -- contracts apps argocd platform rke
```

생성물에 실제 Secret 값이 없는지 확인하고 전체 회귀를 실행합니다.

```bash
bash ./sadp --test
```

검토가 끝난 결과만 사이트 branch에 commit/push합니다. `node`와 `cluster` phase는 현재 checkout이
`site.env`와 정확히 동기화되지 않으면 중단됩니다.

> [!CAUTION]
> `--allow-dirty`는 기존 변경을 확인하고 보존한 경우에만 사용합니다. 생성물 충돌을 무시하는
> 일반 옵션이 아닙니다.

## 4. 서드파티 이미지 배포

worker가 직접 인터넷 registry에 접근하지 못하는 환경에서는 control-plane이 승인된 이미지를
받아 모든 노드의 containerd로 전달합니다.

```bash
sudo bash scripts/cluster/sync-external-images.sh \
  --image <REGISTRY>/<IMAGE>:<IMMUTABLE_TAG>
```

여러 이미지는 root 전용 목록 파일로 전달할 수 있습니다.

```bash
sudo bash scripts/cluster/sync-external-images.sh \
  --image-list /etc/sadp/external-images.txt
```

tag나 digest가 반드시 있어야 하며 `latest`는 거부됩니다. 승인된 이미지 목록과 버전은
`versions.lock.yaml` 및 Argo Application을 기준으로 검토합니다.

## 5. 노드 설정 적용

control-plane과 각 worker에서 같은 Git revision과 같은 `site.env`를 사용합니다. hostname이
`CONTROL_PLANE_HOSTNAME` 또는 `WORKER_NODES`와 일치하면 역할과 내부 IP를 자동 판별합니다.

### 계획

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase node
```

### 적용

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase node \
  --apply
```

적용되는 항목:

- RKE2 server/agent 계약 설정
- 내부 NIC 기반 node identity와 Canal interface
- 외부/NMS/guarded NIC 관리 포트 차단
- RKE2 embedded containerd proxy
- env에서 선택한 NMS route/SNAT
- 지정 노드의 Squid와 CoreDNS upstream listener

### 수동 재시작 경계

설치기는 RKE2를 자동 재시작하지 않습니다.

1. worker 한 대를 drain합니다.
2. 해당 노드의 `rke2-agent`를 재시작합니다.
3. Node와 Canal이 Ready인지 확인하고 uncordon합니다.
4. 나머지 worker를 한 대씩 반복합니다.
5. 마지막에 control-plane 유지보수 창에서 `rke2-server`를 재시작합니다.

실제 drain 정책과 PodDisruptionBudget은 사이트 운영 기준을 따릅니다. 모든 노드가 Ready가 되기
전에는 cluster phase를 실행하지 않습니다.

## 6. GitOps bootstrap

control-plane에서 먼저 계획을 확인합니다.

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase cluster
```

적용:

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env \
  --phase cluster \
  --apply
```

cluster phase는 env에 따라 다음을 순서대로 수행합니다.

1. 클러스터 선행 조건 검사
2. Devtron/번들 Argo CD 기존 계약 확인 또는 완전 부재 시 자동 설치
3. RFC2136 TSIG Kubernetes Secret 적용(값 비출력)
4. Argo repository 연결
5. AppProject와 app-of-apps bootstrap 적용
6. child Application 생성 대기
7. SADP 기반 플랫폼 설치
8. TLS 진행 상태 판단
9. 이미지 빌드, Keycloak/OpenBao 초기화, 앱 배포, acceptance

| env | 동작 |
| --- | --- |
| `SADP_INSTALL_GITOPS=true` | Argo repository와 bootstrap 구성 |
| `SADP_BUILD_IMAGES=true` | Portal/test image 빌드와 노드 import |
| `SADP_BUILD_NODE=<WORKER>` | 지정 worker에서 빌드, 비우면 자동 선택 |
| `SADP_DEPLOY_APPS=true` | 기본 앱과 Portal 배포 |
| `SADP_RUN_VERIFY=true` | Portal 인증과 핵심 acceptance 실행 |

## 7. wildcard TLS 전환

`TLS_SOURCE=acme`이고 운영 인증서가 아직 준비되지 않았다면 cluster phase는 기반 플랫폼까지만
설치하고 안전하게 멈춥니다.

### staging

```bash
kubectl get certificate,certificaterequest,order,challenge -A
```

staging 인증서가 Ready이고 DNS-01 경로를 검증한 뒤:

```dotenv
ACME_STAGING_VERIFIED=true
TLS_ISSUER_MODE=production
```

다시 render → test → commit/push → cluster를 수행합니다.

### production

운영 wildcard Secret이 Ready이면:

```dotenv
EXISTING_GATEWAY_TLS_READY=true
```

다시 render → test → commit/push → cluster를 수행합니다. 이때 HTTPS listener와 HTTP→HTTPS
redirect가 활성화됩니다.

상세 DNS 위임, RFC2136, Challenge 정리는 [Let's Encrypt DNS-01 Runbook](letsencrypt-dns01.md)을
따릅니다.

## 8. 서비스 초기화와 앱 배포

TLS가 준비된 cluster phase는 다음을 자동으로 이어서 실행합니다.

- Keycloak realm/client/group 정책 수렴
- OpenBao 초기화와 Kubernetes auth/KV 정책 수렴
- ESO/Reloader 상태 확인
- Portal/test image 빌드 또는 import
- Registry pull/push credential 분리 적용
- hello, secure-demo, Portal 배포
- Portal 인증과 핵심 acceptance

특정 단계의 원인을 분리해야 할 때만 [scripts 명령 참조](../scripts/README.md)의 개별 명령을
사용합니다. 정상 설치 절차를 개별 명령 목록으로 다시 조합하지 않습니다.

## 9. 설치 검증과 인수인계

### 클러스터

```bash
kubectl get nodes -o wide
kubectl get applications -n devtroncd
kubectl get gateway,httproute -A
kubectl get certificate -A
kubectl get externalsecret,secretstore,clustersecretstore -A
```

### acceptance

```bash
sudo bash ./sadp --verify-portal-auth
sudo bash ./sadp --verify-testbed
```

### 브라우저

| 대상 | 예상 결과 |
| --- | --- |
| 공개 앱 | 미로그인 `200` |
| SSO 앱 | Keycloak redirect 후 접근 |
| Portal | 로그인 후 대시보드 |
| 내부 앱 | 외부 Route 없음 |

### 인수인계 항목

- site/cluster 이름과 Git revision
- Portal과 관리 서비스 주소
- 운영 담당자와 장애 연락 경로
- `site.env`와 root 전용 Secret 파일의 보관 위치·소유자
- token/certificate 회전 일정
- 마지막 백업과 복원 시험 시각
- acceptance 결과

Secret 본문은 인수인계 문서에 복사하지 않습니다.

## 설치 중 자주 멈추는 지점

| 메시지/증상 | 의미 | 다음 문서 |
| --- | --- | --- |
| 예제 domain/IP 적용 거부 | `site.env`에 문서값이 남음 | [사이트 설정](site-configuration.md) |
| 생성물이 env와 다름 | render 결과를 commit/push하지 않음 | [3절](#3-설정-렌더와-git-반영) |
| 현재 hostname이 노드 목록에 없음 | `site.env`의 이름 불일치 | `hostname -s`, `WORKER_NODES` 확인 |
| Devtron release 계약 불일치 | 다른 버전 또는 부분 설치 감지 | 기존 소유권/버전을 확인하고 자동 덮어쓰지 않음 |
| Argo Application 없음 | 단계 6 GitOps bootstrap 미완료 | [6절](#6-gitops-bootstrap) |
| TLS 준비 단계에서 종료 | 정상적인 staged install | [7절](#7-wildcard-tls-전환) |
| 인증서/Challenge 실패 | DNS-01/RFC2136 문제 | [DNS-01 Runbook](letsencrypt-dns01.md) |
| 공인 URL 연결 거부 | NAT/direct/Gateway/NIC 문제 | [네트워크 Runbook](network-egress.md) |
| `Assertion expired`/SAML 오류 | Audience 로그와 외부 SSO·Keycloak NTP/Assertion 시간 계약 분리 | [외부 Keycloak](keycloak-external.md#34-invalidsamlresponse--audience-오류와-실제-만료를-로그로-분리) |
| Registry Secret 거부 | pull/push 파일 또는 권한 문제 | [관리자 가이드](administrator-guide.md#5-계정과-권한-운영) |

설치 완료 후 일상 운영은 [관리자 가이드](administrator-guide.md), 사용자 onboarding은
[사용자 가이드](usage.md), 앱 배포 준비는 [개발자 가이드](developer-guide.md)를 사용합니다.
