# SADP 명령과 스크립트 안내

> 대상: 통합 설치기를 실행하는 관리자와 개별 단계를 진단하는 개발자
> 명령 매핑 기준: 저장소 루트의 `sadp`

정상 설치는 개별 스크립트를 조합하지 말고 통합 설치기를 사용합니다.

```bash
bash ./sadp --list
bash ./sadp --install --env-file /etc/sadp/site.env --phase all
```

`sadp`는 권한을 올리지 않습니다. node/cluster 적용은 호출자가 `sudo bash`로 실행합니다.

## 통합 설치

```bash
# 1. 입력과 전체 계획 검사. 호스트나 클러스터를 바꾸지 않음
bash ./sadp --install --env-file /etc/sadp/site.env --phase all

# 2. 계약과 생성물을 쓰기. 생성 diff를 검토해 commit/push
bash ./sadp --install --env-file /etc/sadp/site.env --phase render --apply

# 3. 각 노드에서 실행. RKE2는 자동 재시작하지 않음
sudo bash ./sadp --install --env-file /etc/sadp/site.env --phase node --apply

# 4. 노드별 수동 재시작과 Ready 확인 뒤 control-plane에서 실행
sudo bash ./sadp --install --env-file /etc/sadp/site.env --phase cluster --apply
```

`--phase all --apply`는 안전상 거부됩니다. `node`와 `cluster` 사이에 관리자가 노드를 한 대씩
drain/restart/Ready 확인해야 하기 때문입니다. `render` 외 phase는 checkout이 `site.env`에서
생성될 결과와 같은지 먼저 확인합니다. 설치기는 생성물을 자동 commit/push하지 않습니다.

## site — 워크스테이션에서 실행

| 명령 | 실제 역할 |
| --- | --- |
| `--configure-site` | `site.env` 검증·계약 생성. `--env-file` 필수, 쓰기는 `--write` |
| `--render-network` | 계약에서 Squid, firewall, CoreDNS, NMS, cert-manager egress 생성 |
| `--render-exposure` | Gateway, HTTPRoute, TLS 리소스 생성 |
| `--render-rancher` | Rancher Project와 RBAC 생성 |
| `--render-quota` | ResourceQuota와 LimitRange 생성 |
| `--render-all` | 네 renderer를 순서대로 실행 |
| `--promote-image` | GitOps values의 image field만 교체 |
| `--portal-ui-env` | 루트 `.env`의 허용된 `NEXT_PUBLIC_*`만 추출 |

```bash
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --check
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --write
bash ./sadp --render-all
```

`configure-site.py`의 기본은 read-only입니다. dirty worktree에서 `--write`는 거부되며 검토한
변경이 있을 때만 `--allow-dirty`를 명시합니다.

## node — 해당 노드에서 root

| 명령 | 실제 역할 | 기본 동작 |
| --- | --- | --- |
| `--install-node-config` | 계약이 소유한 RKE2 config field 병합 | 계획, `--apply` 시 쓰기 |
| `--install-network-identity` | 내부 NIC/IP에 RKE2 identity 고정 | 계획, `--apply` 시 쓰기 |
| `--install-interface-guard` | external/NMS/guarded NIC 관리 port 차단 | 계획, `--apply` 시 쓰기 |
| `--install-containerd-proxy` | RKE2 embedded containerd proxy unit 생성 | 계획, `--apply` 시 쓰기 |
| `--install-docker-proxy` | control-plane Docker daemon pull을 Squid로 고정 | 계획, `--apply` 시 쓰기, `--check` 검증 |
| `--install-squid` | 렌더된 allowlist Squid 설치 | 실행 시 설치, `--check`는 검사 |
| `--install-nms-egress` | `gateway`/`worker` NMS systemd unit 설치 | 실행 시 설치 |
| `--configure-nms-egress` | 렌더된 route/rp_filter 적용 | 실행 시 적용 |

앞의 다섯 스크립트는 `--apply` 2단계입니다. Squid/DNS/NMS 설치기는 통합 설치기의 node apply에서만
자동 호출되며, 직접 호출할 때는 기본 동작이 실제 변경일 수 있으므로 각 `--help`를 먼저 봅니다.
어떤 스크립트도 RKE2를 자동 재시작하지 않습니다.

원툴 설치는 `site.env`와 생성물 동기화를 먼저 확인합니다. `SQUID_INTERNAL_IP` 담당 노드에서는
Squid를 containerd proxy보다 먼저 설치하며, cluster phase는 Devtron/Helm chart/image 작업 전에
실제 Squid 허용·차단 경로를 다시 검증합니다. 이어서 Prometheus/Loki/Alloy 이미지를 모든 노드에
선배포한 뒤 Devtron과 Argo Application을 설치합니다. 이미지 선배포 전에는 실행 중 Docker
daemon의 proxy 환경도 계약과 같은지 확인하며, 셸 환경변수만 맞는 상태는 거부합니다.

## cluster — control-plane에서 실행

| 명령 | 역할 |
| --- | --- |
| `--preflight` | 기존 3노드 RKE2와 도구·네트워크 선행 조건 검사 |
| `--install-devtron` | Devtron/번들 Argo CD 상태 계획, `--apply` 시 부재 설치 또는 동일 버전 failed release 복구 |
| `--configure-keycloak` | 이미 실행 중인 in-cluster/external Keycloak을 계약으로 수렴(`--apply` 전은 계획만) |
| `--configure-argocd-repo` | Argo repository Secret과 per-repository proxy 설정 |
| `--install-platform` | Argo 소유 플랫폼을 설치·대기하고 외부 이미지를 동기화 |
| `--configure-openbao-app-access` | 앱별 OpenBao OIDC 접근 정책 구성 |
| `--build-images` | Docker dind worker Pod로 로컬 이미지 빌드 후 세 노드 import |
| `--bootstrap-services` | Keycloak realm/client와 OpenBao auth/KV 초기화 |
| `--deploy-apps` | hello, secure-demo, portal-lite 배포와 rollout |
| `--install-portal-backend` | Portal backend 개별 설치 |
| `--configure-external-keycloak` | 외부 Keycloak VM NTP를 먼저 정상화한 뒤 정책 원격 수렴 |
| `--sync-images` | 외부 이미지를 모든 노드 containerd에 동기화 |
| `--bootstrap` | 예전 직접 bootstrap 진입점. 신규 설치에는 사용하지 않음 |

`--bootstrap`은 통합 설치기의 `site.env` 검증·phase 안전 경계를 거치지 않는 레거시 진단
진입점입니다. 신규 설치는 반드시 `--install --phase cluster`를 사용합니다.

통합 cluster apply는 `--preflight`를 통과한 뒤 `--install-devtron --apply`와 같은 검사를 자동으로
수행합니다. Devtron/Argo CD가 완전히 없을 때만 설치하며 정확한 기존 설치는 유지합니다. 다른
버전이나 Helm 소유권이 없는 부분 설치는 운영자 확인 없이 덮어쓰지 않습니다. 수동으로 먼저
준비할 때도 raw Helm 명령 대신 아래의 계획→적용 경로를 사용합니다.

```bash
sudo bash ./sadp --install-devtron
sudo bash ./sadp --install-devtron --apply
```

cluster apply는 TLS 진행 상태를 읽습니다. 운영 인증서가 아직 Ready가 아니면 플랫폼 기반까지만
설치하고 서비스 초기화·앱 배포·검수를 보류한 뒤 정상 종료합니다. `site.env`의 TLS 진행값을
갱신하고 render→commit/push→cluster를 반복합니다.

`KEYCLOAK_DEPLOYMENT=in-cluster`와 `KEYCLOAK_NODE_PLACEMENT=control-plane`을 함께 쓰면 cluster
apply가 Keycloak/PostgreSQL을 control-plane에 고정하고 runtime Secret과 realm/client 초기화까지
한 번에 수행합니다. `--phase all --apply`의 노드 재시작 안전 경계는 그대로 유지됩니다.

## 검수와 운영

| 그룹 | 명령 |
| --- | --- |
| 핵심 검수 | `--verify-testbed` |
| TLS/Gateway | `--verify-d5` |
| Rancher | `--verify-d6` |
| Portal 인증 | `--verify-portal-auth` |
| 외부 SAML federation | `--verify-saml-federation` |
| Squid | `--verify-squid` |
| 백업 | `--verify-backups` |
| 운영 백업 | `--backup` |
| Portal on/off | `--toggle-portal` |
| Authentik Assertion 유효시간 | `--configure-authentik-saml` |
| Forgejo token 회전 | `--rotate-forgejo-token` |
| root-only 자격증명 내보내기 | `--export-credentials` |

`--verify-testbed`는 control-plane 노드 한 대의 호스트 상태와 클러스터 상태를 검사합니다. 다른
worker 호스트의 interface/systemd 상태까지 대신 검증하지 않습니다.

## 커밋 전 검사

```bash
bash ./sadp --test
```

`--test`는 모든 `scripts/tests/*-test.py`, Helm render 회귀, `ci-guard.sh`,
`git diff --check`를 실행합니다. `render-test.sh`의 정상 profile 검증에는 Helm이 필요합니다.
Helm이 없으면 금지 profile의 실행 실패만으로 `[OK]`가 보일 수 있으므로 유효한 통과가 아닙니다.

개별 진단:

```bash
bash ./sadp --guard
bash ./sadp --render-test
sudo bash ./sadp --verify-testbed
```
