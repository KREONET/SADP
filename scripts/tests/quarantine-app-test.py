#!/usr/bin/env python3
"""앱 격리는 destination과 Helm release를 함께 찾아 계획만 출력해야 한다."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    fake = temp / "kubectl"
    fixture = {
        "items": [
            {
                "metadata": {"name": "aa-demo-0123456789"},
                "spec": {
                    "destination": {"namespace": "app-team"},
                    "sources": [{"helm": {"releaseName": "demo"}}],
                },
            },
            {
                "metadata": {"name": "same-name-other-namespace"},
                "spec": {
                    "destination": {"namespace": "other"},
                    "sources": [{"helm": {"releaseName": "demo"}}],
                },
            },
        ]
    }
    fake.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ $* == *'get applications'* ]]; then printf '%s\\n' \"$FAKE_APPLICATIONS\"; exit 0; fi\n"
        "if [[ $* == *'jsonpath={.spec.replicas}'* ]]; then printf '1'; exit 0; fi\n"
        "if [[ $* == *'jsonpath={.status.readyReplicas}'* ]]; then printf '1'; exit 0; fi\n"
        "if [[ $* == *'get httproute'* ]]; then exit 0; fi\n"
        "if [[ $* == *'get application'* ]]; then printf 'false'; exit 0; fi\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake.chmod(0o755)
    result = subprocess.run(
        ["bash", "./sadp", "--quarantine-app", "--app", "demo", "--namespace", "app-team"],
        cwd=ROOT,
        env={**os.environ, "KUBECTL_BIN": str(fake), "KUBECONFIG_PATH": str(temp / "config"),
             "FAKE_APPLICATIONS": json.dumps(fixture)},
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "application=aa-demo-0123456789" in output
    assert "계획:" in output and "적용하려면" in output

invalid = subprocess.run(
    ["bash", "./sadp", "--quarantine-app", "--app", "../demo", "--namespace", "app-team"],
    cwd=ROOT,
    capture_output=True,
    text=True,
    check=False,
)
assert invalid.returncode != 0 and "DNS label" in invalid.stderr
source = (ROOT / "scripts/ops/quarantine-app.sh").read_text(encoding="utf-8")
pause = source.index("argocd.argoproj.io/skip-reconcile=true")
remove_route = source.index('kctl delete httproute', pause)
scale_zero = source.index('kctl scale deployment', remove_route)
wait_zero = source.index('kctl get pods', scale_zero)
if not pause < remove_route < scale_zero < wait_zero:
    raise AssertionError("reconcile 중지 → Route 제거 → Pod 중지/확인 순서가 깨짐")
print("[OK] 앱 격리 대상 식별·plan/apply 경계")
