#!/usr/bin/env python3
"""install-idp-relay.sh 계획·거부 경로 회귀(IR-01~).

실제 설치(--apply/--check)는 root와 haproxy가 필요해 클러스터 호스트에서만 확인한다. 여기서는
계획 모드가 호스트를 전혀 바꾸지 않는지, 켜지 않은 계약·오래된 생성물·비root 적용을 거부하는지
본다. 시스템 명령은 PATH mock으로 가로채 호출 여부만 기록한다.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sadp_test_fixture  # noqa: E402


PASSED = 0
FAILED = 0
SYSTEM_COMMANDS = ("apt-get", "systemctl", "haproxy", "install", "ss", "ip", "curl", "cp")


def check(label: str, condition: bool, detail: str = "") -> None:
    global PASSED, FAILED
    if condition:
        PASSED += 1
        print(f"[OK]   {label}")
    else:
        FAILED += 1
        print(f"[FAIL] {label}")
        if detail:
            print("       " + detail.strip().replace("\n", "\n       "))


def set_relay(root: pathlib.Path, enabled: bool) -> None:
    path = root / "contracts/platform-production.yaml"
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    network = document["spec"]["network"]
    network["identityProviderRelay"] = {
        "enabled": enabled,
        "address": network["squid"]["internalIP"],
        "port": 443,
    }
    path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False), encoding="utf-8")
    subprocess.run([sys.executable, "scripts/site/render-network.py"], cwd=root, check=True,
                   capture_output=True)


def run(root: pathlib.Path, *arguments: str) -> tuple[subprocess.CompletedProcess, list[str]]:
    bin_dir = root.parent / "mock-bin"
    bin_dir.mkdir(exist_ok=True)
    log = root.parent / "system-calls.log"
    log.unlink(missing_ok=True)
    for name in SYSTEM_COMMANDS:
        path = bin_dir / name
        path.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "{name} $*" >>"{log}"\nexit 0\n')
        path.chmod(0o755)
    environment = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
    result = subprocess.run(["bash", "scripts/node/install-idp-relay.sh", *arguments], cwd=root,
                            env=environment, capture_output=True, text=True, check=False)
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls


root = sadp_test_fixture.build()
try:
    result, calls = run(root)
    check("IR-01 relay를 끈 계약에서는 계획도 거부하고 시스템 명령을 부르지 않음",
          result.returncode != 0 and "IDP_RELAY_ENABLED=true" in result.stderr and not calls,
          result.stdout + result.stderr)

    set_relay(root, True)
    result, calls = run(root)
    output = result.stdout + result.stderr
    check("IR-02 기본 실행은 계획만 출력하고 패키지·서비스·파일을 바꾸지 않음",
          result.returncode == 0 and "[PLAN]" in output and "--apply" in output and not calls,
          output + f"\ncalls={calls}")

    if os.geteuid() == 0:
        print("[SKIP] IR-03 비root --apply 거부: root로 실행 중이라 검사할 수 없음(일반 계정으로 재실행)")
    else:
        result, calls = run(root, "--apply")
        check("IR-03 비root --apply는 호스트 변경 전에 거부",
              result.returncode != 0 and "root 권한" in result.stderr
              and not any(call.split()[0] in {"apt-get", "systemctl", "install", "cp"} for call in calls),
              result.stdout + result.stderr + f"\ncalls={calls}")

    path = root / "contracts/platform-production.yaml"
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    document["spec"]["network"]["identityProviderRelay"] = {"enabled": True}
    path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False), encoding="utf-8")
    result, calls = run(root)
    squid_ip = document["spec"]["network"]["squid"]["internalIP"]
    check("IR-05 이전 계약({enabled: true}만)도 Squid 호스트·443으로 계획",
          result.returncode == 0 and f"{squid_ip}:443" in result.stdout and not calls,
          result.stdout + result.stderr)

    (root / "platform/network/idp-relay/haproxy.cfg").write_text("# stale\n", encoding="utf-8")
    result, calls = run(root)
    check("IR-04 생성물이 계약과 다르면 계획 전에 거부",
          result.returncode != 0 and "render 후 다시 실행" in result.stderr and not calls,
          result.stdout + result.stderr)
finally:
    sadp_test_fixture.remove(root)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
