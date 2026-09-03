#!/usr/bin/env python3
"""외부 image sync의 pull/export/검증/전송 경계를 고정한다."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import re
import socket
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SYNC = ROOT / "scripts/cluster/sync-external-images.sh"
SOURCE = SYNC.read_text(encoding="utf-8")
passed = 0
failed = 0


def check(condition: bool, message: str) -> None:
    global passed, failed
    if condition:
        passed += 1
        print(f"[OK]   {message}")
    else:
        failed += 1
        print(f"[FAIL] {message}")


help_result = subprocess.run(
    ["bash", "./sadp", "--sync-images", "--help"],
    cwd=ROOT,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
check(
    help_result.returncode == 0
    and "sudo bash ./sadp --sync-images" in help_result.stdout
    and "ctr images check --quiet" in help_result.stdout,
    "단일 진입점 도움말이 새 archive 경로와 complete 판정을 설명",
)

check(
    re.search(r"^\s*docker\s+(pull|save)\b", SOURCE, re.MULTILINE) is None
    and "source platform/network/proxy.env" not in SOURCE
    and "proxy_values" in SOURCE
    and '--namespace "${TRANSFER_NAMESPACE}" images pull --platform "${platform}"' in SOURCE
    and '--namespace "${TRANSFER_NAMESPACE}" images export "${platform_args[@]}"' in SOURCE,
    "기존 Docker metadata 대신 전용 containerd Namespace에서 node platform별 pull/export",
)

platform_position = SOURCE.find("nodeInfo")
pull_position = SOURCE.find("pull_image_platform()")
export_position = SOURCE.find('--namespace "${TRANSFER_NAMESPACE}" images export "${platform_args[@]}"')
verify_position = SOURCE.find("verify-image-archive.py")
loader_position = SOURCE.find("loader_created=true")
transfer_position = SOURCE.find("cat > /staging/external-images.tar")
check(
    -1 not in (
        platform_position,
        pull_position,
        export_position,
        verify_position,
        loader_position,
        transfer_position,
    )
    and platform_position < pull_position < export_position < verify_position < loader_position < transfer_position,
    "node platform 확인 → pull → export → archive 검증이 loader/전송보다 먼저 실행",
)

check(
    all(
        marker in SOURCE
        for marker in (
            "PULL_ATTEMPTS",
            "retryable_pull_error",
            "status code: 5",
            "deadline exceeded",
            "attempt < PULL_ATTEMPTS",
            "sleep $((attempt * 2))",
        )
    ),
    "Registry 5xx/timeout만 짧은 backoff로 제한 재시도",
)

check(
    all(
        marker in SOURCE
        for marker in (
            "digest_alias()",
            ":sadp-sha256-%s",
            'actual_digest} == "${requested_digest}',
            'alias_digest} == "${requested_digest}',
        )
    ),
    "digest 입력은 결정적 alias를 만들고 원본/alias target digest를 모두 검증",
)

check(
    all(
        marker in SOURCE
        for marker in (
            "nodeSelector: {kubernetes.io/os: linux}",
            "tolerations: [{operator: Exists}]",
            "automountServiceAccountToken: false",
            "imagePullPolicy: IfNotPresent",
            "securityContext: {privileged: true, runAsUser: 0}",
        )
    ),
    "loader는 Linux/all-taint/토큰 차단/기존 image 재사용과 짧은 privileged 경계를 유지",
)

check(
    'images import --platform "${node_platform}"' in SOURCE
    and 'images check --quiet "name==${image}"' in SOURCE
    and "linux_node_count" in SOURCE
    and 'node_platform_by_name["${node}"]' in SOURCE,
    "각 Linux node platform으로 import하고 모든 예상 ref content complete를 확인",
)

check(
    all(
        marker in SOURCE
        for marker in (
            "trap cleanup EXIT",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM HUP",
            "cleanup_loader",
            "cleanup_namespace",
            "for attempt in 1 2 3",
            "namespaces remove",
            "수동 확인:",
        )
    ),
    "성공/실패/signal cleanup과 Namespace 삭제 제한 재시도·수동 확인 명령 유지",
)

check(
    'install -d -m 0700 "${IMAGE_DIR}/quarantine"' in SOURCE
    and 'chmod 0600 "${partial_archive}"' in SOURCE
    and 'chmod 0600 "${quarantined_archive}"' in SOURCE
    and 'chmod 0600 "${checksum}"' in SOURCE,
    "archive/quarantine/checksum의 root-only mode를 강제",
)

for bad_ref, expected_text in (
    ("example.invalid/acme/app", "태그나 digest"),
    ("example.invalid/acme/app:latest", "latest"),
    ("example.invalid/acme/app@sha256:abcd", "digest image 참조 형식"),
):
    result = subprocess.run(
        ["bash", str(SYNC), "--image", bad_ref],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    check(
        result.returncode != 0 and expected_text in result.stderr,
        f"비결정적/비정상 참조 거부: {bad_ref}",
    )


def write_executable(path: pathlib.Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


# archive fixture 생성기는 검증기 unit test와 같은 계약을 써 orchestration fake가 형식 차이로
# 통과하지 않게 한다.
fixture_spec = importlib.util.spec_from_file_location(
    "sadp_image_archive_fixture", ROOT / "scripts/tests/image-archive-test.py"
)
assert fixture_spec is not None and fixture_spec.loader is not None
fixture_module = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(fixture_module)

with tempfile.TemporaryDirectory(prefix="sadp-image-sync-test-") as raw_temporary:
    temporary = pathlib.Path(raw_temporary)
    bin_dir = temporary / "bin"
    bin_dir.mkdir()
    state_dir = temporary / "state"
    log = temporary / "operations.log"
    pull_count = temporary / "pull-count"
    manifest_capture = temporary / "loader.yaml"
    archive_fixture = temporary / "valid.tar"
    corrupt_fixture = temporary / "corrupt.tar"
    fixture_module.make_archive(archive_fixture)
    fixture_module.make_archive(corrupt_fixture, corrupt_blob=True)

    nodes = {
        "items": [
            {
                "metadata": {"name": "control-1"},
                "status": {"nodeInfo": {"operatingSystem": "linux", "architecture": "amd64"}},
            },
            {
                "metadata": {"name": "worker-1"},
                "status": {"nodeInfo": {"operatingSystem": "linux", "architecture": "arm64"}},
            },
        ]
    }
    canal = {
        "spec": {"template": {"spec": {"containers": [{"image": "example.invalid/canal:v1"}]}}},
        "status": {"desiredNumberScheduled": 2, "numberReady": 2},
    }
    nodes_path = temporary / "nodes.json"
    canal_path = temporary / "canal.json"
    nodes_path.write_text(json.dumps(nodes), encoding="utf-8")
    canal_path.write_text(json.dumps(canal), encoding="utf-8")

    write_executable(
        bin_dir / "bash",
        """#!/bin/bash
if [[ ${1:-} == scripts/node/install-rke2-containerd-proxy.sh ]]; then exit 0; fi
exec /bin/bash "$@"
""",
    )
    write_executable(
        bin_dir / "id",
        """#!/bin/bash
[[ ${1:-} == -u ]] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
""",
    )
    write_executable(bin_dir / "sleep", "#!/bin/bash\nexit 0\n")
    fake_ctr = bin_dir / "ctr"
    write_executable(
        fake_ctr,
        r'''#!/bin/bash
set -euo pipefail
printf 'ctr:%s\n' "$*" >>"${FAKE_LOG}"
args=" $* "
if [[ ${args} == *" images pull "* ]]; then
  count=0
  [[ ! -f ${FAKE_PULL_COUNT} ]] || count=$(<"${FAKE_PULL_COUNT}")
  count=$((count + 1))
  printf '%s\n' "${count}" >"${FAKE_PULL_COUNT}"
  case ${FAKE_MODE:-success} in
    pull-fail) printf 'HTTP status code: 503\n' >&2; exit 1 ;;
    pull-retry) [[ ${count} -ne 1 ]] || { printf 'HTTP status code: 503\n' >&2; exit 1; } ;;
  esac
  exit 0
fi
if [[ ${args} == *" images export "* ]]; then
  take_next=false
  output=
  after_export=false
  for value in "$@"; do
    if [[ ${after_export} != true ]]; then
      [[ ${value} != export ]] || after_export=true
      continue
    fi
    if [[ ${take_next} == true ]]; then take_next=false; continue; fi
    if [[ ${value} == --platform ]]; then take_next=true; continue; fi
    output=${value}
    break
  done
  /bin/cp "${FAKE_ARCHIVE}" "${output}"
  exit 0
fi
if [[ ${args} == *" images inspect "* ]]; then
  printf '{"target":{"digest":"sha256:%064d"}}\n' 0
  exit 0
fi
exit 0
''',
    )
    fake_kubectl = bin_dir / "kubectl"
    write_executable(
        fake_kubectl,
        r'''#!/bin/bash
set -euo pipefail
[[ ${1:-} != --kubeconfig ]] || shift 2
printf 'kube:%s\n' "$*" >>"${FAKE_LOG}"
args=" $* "
if [[ ${args} == " get nodes -o json " ]]; then exec /bin/cat "${FAKE_NODES}"; fi
if [[ ${args} == " get daemonset -n kube-system rke2-canal -o json " ]]; then
  exec /bin/cat "${FAKE_CANAL}"
fi
if [[ ${args} == " apply -f - " ]]; then exec /bin/cat >"${FAKE_MANIFEST}"; fi
if [[ ${args} == *" rollout status -n kube-system daemonset/sadp-image-loader-"* ]]; then
  if [[ ${FAKE_MODE:-success} == signal ]]; then kill -TERM "$PPID"; exit 143; fi
  exit 0
fi
if [[ ${args} == *" get pods -n kube-system -l app=sadp-image-loader-"*" -o name " ]]; then
  printf 'pod/loader-control\npod/loader-worker\n'
  exit 0
fi
if [[ ${args} == *" get -n kube-system pod/loader-control "* ]]; then printf 'control-1'; exit 0; fi
if [[ ${args} == *" get -n kube-system pod/loader-worker "* ]]; then printf 'worker-1'; exit 0; fi
if [[ ${args} == *" exec -i -n kube-system "*" cat > /staging/external-images.tar"* ]]; then
  /bin/cat >/dev/null
  exit 0
fi
if [[ ${args} == *" images import "* ]]; then
  [[ ${FAKE_MODE:-success} != import-fail ]] || exit 1
  exit 0
fi
if [[ ${args} == *" images check --quiet name=="* ]]; then
  ref=${args##* images check --quiet name==}
  ref=${ref% }
  printf '%s\n' "${ref}"
  exit 0
fi
exit 0
''',
    )

    socket_path = temporary / "containerd.sock"
    socket_handle = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    socket_handle.bind(str(socket_path))
    base_env = os.environ | {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "KUBECTL_BIN": str(fake_kubectl),
        "KUBECONFIG_PATH": str(temporary / "kubeconfig"),
        "RKE2_CTR_BIN": str(fake_ctr),
        "RKE2_CONTAINERD_ADDRESS": str(socket_path),
        "SADP_STATE_DIR": str(state_dir),
        "SADP_IMAGE_PULL_ATTEMPTS": "2",
        "SADP_IMAGE_PULL_TIMEOUT": "2",
        "SADP_IMAGE_EXPORT_TIMEOUT": "2",
        "FAKE_LOG": str(log),
        "FAKE_PULL_COUNT": str(pull_count),
        "FAKE_NODES": str(nodes_path),
        "FAKE_CANAL": str(canal_path),
        "FAKE_MANIFEST": str(manifest_capture),
        "FAKE_ARCHIVE": str(archive_fixture),
    }
    command = [
        "/bin/bash",
        str(SYNC),
        "--image",
        "registry.example.invalid/acme/service:1.2.3",
    ]

    result = subprocess.run(
        command,
        cwd=ROOT,
        env=base_env | {"FAKE_MODE": "pull-retry"},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    success_log = log.read_text(encoding="utf-8")
    check(
        result.returncode == 0
        and success_log.count("images pull --platform") == 3
        and "--platform linux/amd64" in success_log
        and "--platform linux/arm64" in success_log
        and success_log.count("images check --quiet") == 2
        and "delete daemonset" in success_log
        and "namespaces remove" in success_log,
        "platform별 pull, 503 제한 재시도, 전 node complete와 성공 cleanup을 실행",
    )

    log.write_text("", encoding="utf-8")
    pull_count.unlink(missing_ok=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=base_env | {"FAKE_MODE": "import-fail"},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    failure_log = log.read_text(encoding="utf-8")
    check(
        result.returncode != 0
        and "images import" in failure_log
        and "delete daemonset" in failure_log
        and "namespaces remove" in failure_log,
        "import 실패도 loader와 containerd Namespace를 cleanup",
    )

    log.write_text("", encoding="utf-8")
    pull_count.unlink(missing_ok=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=base_env | {"FAKE_MODE": "success", "FAKE_ARCHIVE": str(corrupt_fixture)},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    verify_failure_log = log.read_text(encoding="utf-8")
    quarantined = list((state_dir / "images/quarantine").glob("*.invalid"))
    check(
        result.returncode != 0
        and "archive 검증 실패" in result.stderr
        and "kube:apply -f -" not in verify_failure_log
        and "namespaces remove" in verify_failure_log
        and len(quarantined) == 1
        and quarantined[0].stat().st_mode & 0o777 == 0o600,
        "손상 archive는 loader 생성 전 root-only 격리하고 Namespace를 cleanup",
    )

    log.write_text("", encoding="utf-8")
    pull_count.unlink(missing_ok=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=base_env | {"FAKE_MODE": "pull-fail"},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    pull_failure_log = log.read_text(encoding="utf-8")
    check(
        result.returncode != 0
        and pull_failure_log.count("images pull --platform") == 2
        and "images export" not in pull_failure_log
        and "kube:apply -f -" not in pull_failure_log
        and "namespaces remove" in pull_failure_log,
        "Registry 5xx는 제한 횟수 뒤 pull 단계로 실패하고 export/loader 없이 cleanup",
    )

    log.write_text("", encoding="utf-8")
    pull_count.unlink(missing_ok=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=base_env | {"FAKE_MODE": "signal"},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    signal_log = log.read_text(encoding="utf-8")
    check(
        result.returncode != 0
        and "rollout status" in signal_log
        and "delete daemonset" in signal_log
        and "namespaces remove" in signal_log,
        "signal 중단도 loader와 containerd Namespace를 cleanup",
    )
    socket_handle.close()

print(f"통과 {passed} / 실패 {failed}")
raise SystemExit(1 if failed else 0)
