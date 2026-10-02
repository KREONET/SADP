# Forgejo token 회전 안내

> 대상: Portal write token과 Argo repository read token을 회전하는 관리자
> 구현: `scripts/ops/rotate-forgejo-token.sh`

토큰 회전은 서비스가 사용하는 접속 토큰을 새 값으로 교체하고 옛 값을 폐기하는 작업입니다.
**새 토큰 발급 → 시험(dry-run) → 서비스 전환 → 정상 동작 확인 → 옛 토큰 폐기** 순서로 진행합니다.
전환에 실패했을 때 되돌릴 수 있도록 확인이 끝나기 전에는 옛 토큰을 폐기하지 마세요.

새 토큰 발급과 옛 토큰 폐기는 Forgejo 웹 화면에서 사람이 수행합니다.
스크립트는 새 토큰의 신원·권한을 확인하고 OpenBao·Argo·Portal을 전환합니다.
실행 위치는 control-plane의 저장소 루트입니다. 토큰 값은 문서·셸 기록·명령 인자·화면 캡처에 남기지 않습니다.

## 1. 두 token의 경계

| 용도 | 최소 scope | 사용처 |
| --- | --- | --- |
| Portal write | `write:repository` | 배포 branch와 Pull Request 생성 |
| Argo read | `read:repository` | GitOps repository clone |

두 token 모두 admin scope를 주지 않고 서로 다른 값으로 발급합니다. 같은 bot 계정이더라도 push와
read credential을 한 파일로 재사용하지 않습니다.

## 2. 발급과 root-only 파일

site.env의 `SADP_ARGO_REPO_USERNAME` 계정으로 Forgejo UI의
`Settings → Applications → Generate New Token`에서 두 token을 만듭니다.

터미널에 값을 직접 명령 인자로 붙이지 말고 숨김 입력으로 관리자(root) 전용 파일을 만듭니다.
다음 예제는 Bash 문법입니다. 대화형 셸이 zsh라면 먼저 `bash`를 실행한 뒤 복사하세요.
입력 중에는 화면에 문자가 표시되지 않습니다.

```bash
sudo install -d -m 0700 /etc/sadp/secrets

read -rs -p 'New Portal write token: ' NEW_WRITE_TOKEN; echo
printf '%s' "${NEW_WRITE_TOKEN}" | \
  sudo sh -c 'umask 077; exec tee /etc/sadp/secrets/forgejo-write-next >/dev/null'
unset NEW_WRITE_TOKEN

read -rs -p 'New Argo read token: ' NEW_READ_TOKEN; echo
printf '%s' "${NEW_READ_TOKEN}" | \
  sudo sh -c 'umask 077; exec tee /etc/sadp/secrets/forgejo-read-next >/dev/null'
unset NEW_READ_TOKEN

sudo chown root:root \
  /etc/sadp/secrets/forgejo-write-next \
  /etc/sadp/secrets/forgejo-read-next
sudo chmod 0600 \
  /etc/sadp/secrets/forgejo-write-next \
  /etc/sadp/secrets/forgejo-read-next
```

공용 운영 환경에서는 approved password manager에서 안전한 파일 전달 기능을 사용하는 것이 더
좋습니다. 위 변수 이름을 export하지 말고 입력 직후 unset합니다.

## 3. dry-run

새 토큰을 서비스에 반영하기 전에 신원과 권한부터 확인합니다.
**이 스크립트는 `--apply`가 아니라 `--dry-run`으로 시험 모드를 지정합니다.**
이를 빼면 아래 4절처럼 실제 전환하므로 옵션을 확인하세요.

```bash
sudo bash ./sadp --rotate-forgejo-token \
  --write-token-file /etc/sadp/secrets/forgejo-write-next \
  --read-token-file /etc/sadp/secrets/forgejo-read-next \
  --dry-run
```

검사 내용:

- write token이 기존 token과 다른지
- token 소유자가 예상 bot 계정인지
- admin API가 403/404로 막히는지
- GitOps repository push/read 권한이 있는지

dry-run은 cluster Secret과 credential file을 바꾸지 않습니다.

## 4. 실제 전환

```bash
sudo bash ./sadp --rotate-forgejo-token \
  --write-token-file /etc/sadp/secrets/forgejo-write-next \
  --read-token-file /etc/sadp/secrets/forgejo-read-next
```

스크립트가 수행하는 일:

1. `/var/lib/sadp/credentials`의 active file 교체와 옛 write token의 `.revoked-*` backup
2. Portal write token을 OpenBao 경유로 갱신
3. Argo repository Secret의 read token 교체와 repo-server rollout
4. `portal-lite-auth` ExternalSecret 강제 동기화와 Portal rollout
5. cluster Secret에 옛 token이 남지 않았는지 값 자체를 출력하지 않고 비교

모든 단계가 성공하기 전 옛 token을 폐기하지 않습니다.

## 5. 수동 폐기

스크립트 성공 후 Forgejo UI의 `Settings → Applications`에서 옛 write/read token을 삭제합니다.
token 목록은 UI의 이름과 발급 시각으로 확인하고 API Basic Auth 명령에 새 token을 넣지 않습니다.

폐기 뒤 확인:

```bash
kubectl get application -n devtroncd
kubectl rollout status -n devtroncd deployment/argocd-repo-server
kubectl rollout status -n <PORTAL_NAMESPACE> deployment/portal-lite
sudo bash ./sadp --verify-portal-auth
```

Portal에서 테스트 요청을 하나 만들어 PR 생성이 되는지 확인하되 production 앱 이름을 재사용하지
않습니다.

## 6. 롤백

옛 token을 아직 Forgejo에서 폐기하지 않았을 때만 `.revoked-*` 파일로 write credential을 되돌릴
수 있습니다. read token도 해당 시점의 안전한 파일이 있어야 합니다.

```bash
sudo bash ./sadp --rotate-forgejo-token \
  --write-token-file /var/lib/sadp/credentials/forgejo-bot-token.revoked-<TIMESTAMP> \
  --read-token-file <PREVIOUS_ROOT_ONLY_READ_TOKEN_FILE>
```

옛 token을 이미 폐기했다면 롤백하지 말고 새 token 쌍을 발급해 다시 회전합니다. 작업이 끝나면
`/etc/sadp/secrets/*-next` 임시 파일은 보존 정책에 따라 승인된 password manager로 옮기거나
안전하게 제거하고, 폐기 token backup의 보관 기한을 기록합니다.
