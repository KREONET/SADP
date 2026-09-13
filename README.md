# SADP — RKE2 자동 앱 배포 플랫폼

RKE2 클러스터 위에서 **공개 웹 서비스와 SSO 보호 서비스를 함께 운영**하기 위한 GitOps 플랫폼입니다.
Envoy Gateway가 단일 외부 진입점을 맡고, 외부 OIDC IdP · OpenBao · Argo CD가 인증 · Secret · 배포를 담당합니다.

> [!WARNING]
> 이 저장소는 **운영체제와 RKE2 자체를 설치하지 않습니다.**
> 이미 구성된 RKE2 클러스터 위에 플랫폼 서비스만 올립니다.
> 기존 RKE2의 승인 버전 업데이트는 설치가 아니라 별도 유지보수 Runbook으로 지원합니다.
> 처음 구축한다면 [설치 가이드](docs/installation.md)의 선행 조건부터 확인하세요.

> [!IMPORTANT]
> IP, FQDN, 저장소 URL, 사용자명, 토큰, 비밀번호, 인증서, 개인키는
> **Git 문서에 실제 값으로 기록하지 않습니다.** 문서에서 `Private`로 표기한 값은
> 실제 운영 환경에서만 관리합니다.

## 역할별 시작

| 나는 누구인가 | 먼저 읽을 문서 | 할 수 있는 일 |
| --- | --- | --- |
| SADP 사용자 | [사용자 가이드](docs/usage.md) | 로그인, 서비스 이용, 앱 신청과 상태 확인 |
| 앱 개발자 | [개발자 가이드](docs/developer-guide.md) | 저장소·Dockerfile·배포 정책·AppGroup·API 연동 |
| 플랫폼 관리자 | [관리자 가이드](docs/administrator-guide.md) | 설치, 사이트 설정, 인증·Secret·GitOps·운영 |

전체 문서와 장애별 이동 경로는 [SADP 문서 홈](docs/README.md)에 있습니다.

## 관리자 빠른 시작

```bash
bash ./sadp --list     # 전체 명령 확인
bash ./sadp --test     # 로컬 회귀 시험 (클러스터 불필요)
```

다른 사이트에 배포할 때는 예제 env를 Git 밖으로 복사하고 실제 값으로 바꿉니다.

처음 설치해 변수 의미가 익숙하지 않으면 질문·답변형 설치 준비를 사용할 수 있습니다.

```bash
sudo bash ./sadp --install-wizard
```

이 마법사도 검증된 `/etc/sadp/site.env`를 만든 뒤 아래와 같은 통합 설치 phase를 사용합니다.

```bash
sudo install -d -m 0700 /etc/sadp /etc/sadp/secrets
sudo install -m 0600 environments/site.env.example /etc/sadp/site.env
sudoedit /etc/sadp/site.env

# 1. 설정 검증 → 생성 → diff 검토 → 사이트 branch에 commit/push
bash ./sadp --install --env-file /etc/sadp/site.env --phase render
bash ./sadp --install --env-file /etc/sadp/site.env --phase render --apply

# 2. control-plane과 각 worker에서 자동 역할 판별 후 노드 설정
sudo bash ./sadp --install --env-file /etc/sadp/site.env --phase node --apply

# 3. 노드별 유지보수 재시작/Ready 확인 뒤 control-plane에서 플랫폼 설치
sudo bash ./sadp --install --env-file /etc/sadp/site.env --phase cluster --apply
```

cluster phase는 Devtron과 번들 Argo CD가 완전히 없으면 승인된 고정 버전으로 먼저 설치합니다.
정확한 기존 설치는 유지하며, 다른 버전이나 부분 설치를 자동 덮어쓰지는 않습니다.

> [!CAUTION]
> `--apply`가 없으면 검증과 계획 출력만 합니다. 노드 단계는 RKE2를 자동 재시작하지
> 않습니다. 생성 결과도 자동 commit/push하지 않으므로 GitOps branch를 먼저 검토·배포해야 합니다.

## 아키텍처

```text
사용자
  └─ HTTPS
      └─ Envoy Gateway (MetalLB VIP)
          ├─ public 앱      hello
          ├─ Portal Lite    사용자 화면 로그인 필수 ── Auth.js → 외부 OIDC
          ├─ OIDC 앱        secure-demo ──────── 외부 OIDC
          └─ 관리 UI        Rancher, OpenBao

SAML 전용 IdP ── 외부 SAML→OIDC broker ── 위 OIDC 경로

애플리케이션 Secret
  └─ OpenBao ── External Secrets Operator ── Kubernetes Secret
                                              └─ Reloader rollout

사설 Worker
  └─ 승인 외부 HTTPS ── Squid allowlist
```

외부 경로는 **Envoy Gateway 하나로 통일**합니다. 앱이 별도 NodePort나 Ingress를 만들지 않으며,
SSO 앱은 Gateway의 `SecurityPolicy`에서 인증을 강제합니다.

## 기능

| 영역 | 내용 |
| --- | --- |
| 클러스터 | RKE2 single(server 1대) 또는 multi(server 1대 + worker N대, N >= 1) Ready 기준 |
| 외부 진입점 | MetalLB VIP + Envoy Gateway, HTTP → HTTPS 전환 |
| 인증 | 외부 OIDC 연결, Portal Auth.js 세션, public/OIDC 앱 구분 |
| Secret | OpenBao KV v2 → ESO → Kubernetes Secret, 변경 시 Reloader rollout |
| 이미지 배포 | Portal 신청 → kaniko build/push → GitOps tag 반영 → Argo 배포 |
| GitOps | Forgejo 보안 검사 + 관리자 승인 뒤 PR merge, OCI Registry push/pull, Argo CD 동기화 |
| 제한 egress | cert-manager·패키지는 Squid, 앱의 새 연결은 선언한 NetworkPolicy로 제한 |
| 앱 보안 경계 | 외부 앱 응답 보안 헤더, 앱별 Secret/권한, 침해 의심 앱 즉시 격리 |
| 외부 공개 | 경계 NAT 또는 노드 공인 NIC 직접 연결, 외부 TCP 80/443만 허용 |
| 백업 | RKE2 etcd, OpenBao Raft |
| 운영 수명주기 | 백업·drain 기반 안전 기동/종료, VERSION 기반 SADP/RKE2 업데이트 |

## 문서

| 분류 | 문서 |
| --- | --- |
| 문서 포털 | [SADP 문서 홈](docs/README.md) |
| 역할별 가이드 | [사용자](docs/usage.md) · [개발자](docs/developer-guide.md) · [관리자](docs/administrator-guide.md) |
| 설치와 이식 | [설치](docs/installation.md) · [사이트 설정](docs/site-configuration.md) |
| 개발 참조 | [Portal API](docs/portal-api.md) · [OpenAPI](apps/portal-lite/backend/openapi.yaml) |
| 운영 Runbook | [보안 경계·앱 격리](docs/security-boundaries.md) · [기동·종료·업데이트](docs/operations-lifecycle.md) · [네트워크](docs/network-egress.md) · [DNS-01](docs/letsencrypt-dns01.md) · [외부 인증](docs/identity-provider.md) · [기계 인증](docs/external-observability.md) · [복구](docs/recovery.md) |
| AI 에이전트 | [AGENTS.md](AGENTS.md) |

## 저장소 구조

| 경로 | 역할 |
| --- | --- |
| `contracts/` | `site.env`에서 생성되는 저장소 내부 환경 계약과 공통 values |
| `charts/app-profile/` | public/OIDC 앱 공통 Helm chart |
| `apps/` | 테스트 앱, Portal Lite, 신규 앱 values 템플릿 |
| `platform/` | Gateway, DNS, OpenBao 등 플랫폼 리소스 |
| `argocd/` | 플랫폼과 앱 Argo CD Application |
| `scripts/` | 역할별 스크립트 (`site/ node/ cluster/ verify/ ops/ tests/ lib/`) |
| `docs/` | 설치 · 사용 · API · 복구 문서 |
| `sadp` | SADP 단일 진입점 (`kisti-RKE`는 기존 자동화 호환 wrapper) |
| `VERSION` | GitHub main 배포본의 SADP 제품 버전(`x.y.z`) |
| `versions.lock.yaml` | 승인된 플랫폼 · delivery 버전 |

실제 사이트에서는 Git 밖의 `site.env`가 상류이고 `contracts/platform-production.yaml`은 검증된
저장소 내부 계약입니다. **계약과 생성물을 손으로 고치지 말고 `site.env`에서 다시 생성해 같은
변경으로 검토합니다.** 운영 env가 없는 생성기 개발 checkout만 계약을 직접 고칠 수 있습니다.

## 개발 검증

클러스터 없이 도는 기본 검증:

```bash
bash ./sadp --test
```

> [!NOTE]
> `--test`에 포함된 `render-test.sh`는 `helm`이 필요합니다. helm이 없으면 정상 profile 시험이
> 실패하고, 금지 profile 시험은 helm 실행 실패를 "정상 거부"로 세어 통과한 것처럼 보입니다.

Portal Lite 화면을 수정했다면:

```bash
cd apps/portal-lite/ui
npm ci && npm run lint && npm run typecheck && npm run test && npm run build

cd ../backend
gofmt -l *.go && go vet ./... && go test ./...
```

테스트베드에 적용한 뒤 실제 인증 흐름과 네트워크 수용 시험 (control-plane 노드):

```bash
sudo bash ./sadp --verify-portal-auth
sudo bash ./sadp --verify-testbed
```

두 스크립트는 Secret, token, 세션 cookie 값을 출력하지 않습니다.
