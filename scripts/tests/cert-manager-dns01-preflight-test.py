#!/usr/bin/env python3
"""cert-manager controller node의 authoritative DNS TCP/UDP preflight 회귀."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
passed = 0
failed = 0


def check(condition: bool, message: str, detail: str = "") -> None:
    global passed, failed
    if condition:
        passed += 1
        print(f"[OK]   {message}")
    else:
        failed += 1
        print(f"[FAIL] {message}{': ' + detail if detail else ''}")


def run_case(fake_bin: pathlib.Path, scenario: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{fake_bin}:{environment['PATH']}",
            "KUBECTL_BIN": str(fake_bin / "kubectl"),
            "KUBECONFIG_PATH": "/tmp/<PLACEHOLDER>-kubeconfig",
            "DNS01_TEST_SCENARIO": scenario,
            "SADP_DNS01_CONTRACT_PATH": "/tmp/<PLACEHOLDER>-contract.yaml",
        }
    )
    return subprocess.run(
        ["bash", "scripts/cluster/preflight-cert-manager-dns01.sh", "--apply"],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


with tempfile.TemporaryDirectory(prefix="sadp-dns01-preflight-test-") as temporary:
    fake_bin = pathlib.Path(temporary) / "bin"
    fake_bin.mkdir()
    (fake_bin / "python3").write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' acme cert-manager any '<PLACEHOLDER_DNS>' 53 '<PLACEHOLDER_ZONE>'\n",
        encoding="utf-8",
    )
    (fake_bin / "python3").chmod(0o700)
    (fake_bin / "id").write_text(
        "#!/usr/bin/env bash\n"
        "[[ ${1:-} == -u ]] && { echo 0; exit 0; }\n"
        "exec /usr/bin/id \"$@\"\n",
        encoding="utf-8",
    )
    (fake_bin / "id").chmod(0o700)
    (fake_bin / "kubectl").write_text(
        r'''#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --kubeconfig ]]; then shift 2; fi
case "$*" in
  "get pod -n cert-manager -l app.kubernetes.io/instance=cert-manager,app.kubernetes.io/component=controller -o json")
    printf '%s\n' '{"items":[{"spec":{"nodeName":"<PLACEHOLDER_NODE>"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    ;;
  "get daemonset -n kube-system rke2-canal -o jsonpath={.spec.template.spec.containers[0].image}")
    printf '%s' '<PLACEHOLDER_IMAGE>'
    ;;
  delete\ pod\ -n\ cert-manager\ *) exit 0 ;;
  "apply -f -") cat >/dev/null ;;
  wait\ pod\ -n\ cert-manager\ *) exit 0 ;;
  exec\ -i\ -n\ cert-manager\ *)
    cat >/dev/null
    case "${DNS01_TEST_SCENARIO}" in
      success) printf '%s\n' 'tcp:ok' 'udp:ok' ;;
      no-route) printf '%s\n' 'tcp:no-route'; exit 1 ;;
      timeout) printf '%s\n' 'udp:timeout'; exit 1 ;;
      refused) printf '%s\n' 'tcp:refused'; exit 1 ;;
      *) exit 98 ;;
    esac
    ;;
  *) printf 'unexpected kubectl call: %s\n' "$*" >&2; exit 97 ;;
esac
''',
        encoding="utf-8",
    )
    (fake_bin / "kubectl").chmod(0o700)

    result = run_case(fake_bin, "success")
    check(
        result.returncode == 0
        and "destination=authoritative-dns TCP/UDP authoritative response" in result.stdout,
        "일반 인터넷 질의 대신 controller node의 authoritative TCP/UDP 응답을 요구한다",
        result.stdout + result.stderr,
    )

    for scenario, expected in (
        ("no-route", "tcp:no-route"),
        ("timeout", "udp:timeout"),
        ("refused", "tcp:refused"),
    ):
        result = run_case(fake_bin, scenario)
        output = result.stdout + result.stderr
        check(
            result.returncode != 0
            and f"node=<PLACEHOLDER_NODE> destination=authoritative-dns reason={expected}" in output
            and "<PLACEHOLDER_DNS>" not in output
            and "<PLACEHOLDER_ZONE>" not in output,
            f"DNS-01 node path {scenario}를 목적지 값 비노출 상태로 구분한다",
            output,
        )

print(f"\ncert-manager DNS-01 preflight tests: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
