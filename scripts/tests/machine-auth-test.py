#!/usr/bin/env python3
"""기계 인증 모드, API 키 멱등성, 명시적 회전 경계를 검증한다."""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "scripts/lib/machine-auth.sh"
BOOTSTRAP = ROOT / "scripts/cluster/bootstrap-testbed-services.sh"
ROTATE = ROOT / "scripts/ops/rotate-machine-api-key.sh"
VERIFY = ROOT / "scripts/verify/verify-testbed.sh"
DISPATCHER = ROOT / "sadp"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"[OK]   {message}")


for script in (LIBRARY, BOOTSTRAP, ROTATE, VERIFY, DISPATCHER):
    subprocess.run(["bash", "-n", str(script)], check=True, cwd=ROOT)
check(True, "machine-auth 운영 스크립트 bash syntax")

library = LIBRARY.read_text(encoding="utf-8")
bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
rotate = ROTATE.read_text(encoding="utf-8")
verify = VERIFY.read_text(encoding="utf-8")
dispatcher = DISPATCHER.read_text(encoding="utf-8")

check(
    "machine_auth_bootstrap" in bootstrap
    and "mode=keycloak: API 키를 생성하거나 변경하지 않음" in library,
    "keycloak 모드에서 API 키 생성 경로를 실행하지 않음",
)
check(
    "openssl rand -hex 32" in library
    and 'bao kv get -field="${client}"' in library
    and "일반 bootstrap은 절대 회전하지 않는다" in library,
    "api-key 생성은 256비트이며 기존 OpenBao 값을 우선 사용",
)
check(
    'policy write machine-auth-reader' in library
    and 'auth/kubernetes/role/${MACHINE_AUTH_ESO_ROLE}' in library
    and "machine_auth_wait_external_secret" in library,
    "OpenBao -> ESO 공급 경로와 수렴 대기",
)
check(
    "ACTION=prepare" in rotate
    and "--promote" in rotate
    and "--confirm-connected" in rotate
    and "--abort" in rotate
    and "old_versions=" in rotate
    and "kv destroy" in rotate,
    "회전은 prepare/외부 연결 확인/promote/old-version 폐기 순서",
)
check(
    "rotate-machine-api-key|bash|scripts/ops/rotate-machine-api-key.sh" in dispatcher,
    "sadp 명시적 machine API key 회전 명령",
)
check(
    "apiKeyAuth.sanitize == true" in verify
    and "Gateway credential key 이름 존재" in verify
    and "-o jsonpath='{.data" not in verify,
    "검수는 API 키 값을 출력하지 않고 이름/sanitize/ESO 상태만 확인",
)

# fake OpenBao는 실제 값 대신 임시 파일 하나를 KV 문서처럼 쓴다. 같은 client를 두 번
# bootstrap해도 첫 키가 바뀌지 않고, 서로 다른 client 키가 다른지 실행으로 확인한다.
with tempfile.TemporaryDirectory(prefix="sadp-machine-auth-") as temp_dir:
    temp = Path(temp_dir)
    credentials = temp / "credentials"
    store = temp / "openbao"
    credentials.mkdir(mode=0o700)
    store.mkdir(mode=0o700)
    shell = r'''
set -euo pipefail
source "$MACHINE_AUTH_LIBRARY"
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
ok() { printf '[OK] %s\n' "$*"; }
note() { printf '[INFO] %s\n' "$*"; }
bao() {
  [[ $1 == kv && $2 == get ]] || return 2
  local field="" arg path file
  for arg in "$@"; do
    [[ $arg != -field=* ]] || field=${arg#-field=}
  done
  path=${!#}
  file="$FAKE_BAO_DIR/${path//\//_}"
  [[ -f $file ]] || return 1
  if [[ -n $field ]]; then
    [[ $(head -n1 "$file") == "$field" ]] || return 1
    tail -n +2 "$file"
  fi
}
bao_input() {
  local last client path_index path value=""
  last=${!#}
  client=${last%=-}
  path_index=$(( $# - 1 ))
  path=${!path_index}
  IFS= read -r value || [[ -n $value ]]
  printf '%s\n%s' "$client" "$value" >"$FAKE_BAO_DIR/${path//\//_}"
}
MACHINE_AUTH_REMOTE_PATH_PREFIX=platform/machine-auth
MACHINE_AUTH_CLIENTS=(grafana-central wazuh-connector)
machine_auth_ensure_client_key grafana-central
first_hash=$(sha256sum "$CREDENTIAL_DIR/machine-auth-grafana-central-api-key")
machine_auth_ensure_client_key grafana-central
second_hash=$(sha256sum "$CREDENTIAL_DIR/machine-auth-grafana-central-api-key")
[[ $first_hash == "$second_hash" ]]
machine_auth_ensure_client_key wazuh-connector
machine_auth_assert_distinct_keys
[[ $(wc -c <"$CREDENTIAL_DIR/machine-auth-grafana-central-api-key") -ge 64 ]]
[[ $(stat -c '%a' "$CREDENTIAL_DIR/machine-auth-grafana-central-api-key") == 600 ]]
'''
    env = os.environ.copy()
    env.update(
        {
            "MACHINE_AUTH_LIBRARY": str(LIBRARY),
            "CREDENTIAL_DIR": str(credentials),
            "FAKE_BAO_DIR": str(store),
        }
    )
    result = subprocess.run(
        ["bash", "-c", shell],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    check(result.returncode == 0, f"API 키 bootstrap 멱등성 실행: {result.stderr.strip()}")
    check(
        not re.search(r"\b[0-9a-f]{64}\b", result.stdout),
        "API 키 값이 stdout에 나타나지 않음",
    )

print("machine auth regression test passed")
