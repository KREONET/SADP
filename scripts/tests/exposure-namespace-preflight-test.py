#!/usr/bin/env python3
"""노출 YAML Namespace parser와 플랫폼 적용 순서 회귀."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/cluster/prepare-exposure-namespaces.py"
PLATFORM_INSTALLER = ROOT / "scripts/cluster/install-testbed-platform.sh"
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


spec = importlib.util.spec_from_file_location("prepare_exposure", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)


manifest_text = """\
apiVersion: v1
kind: Namespace
metadata: {name: sadp-platform}
---
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata:
  name: allow-gateway
  namespace: monitoring
spec: {}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: metrics
  namespace: sadp-platform
spec:
  rules:
    - backendRefs:
        - name: prometheus
          namespace: monitoring
          port: 80
        - name: local
          port: 8080
"""

with tempfile.TemporaryDirectory(prefix="sadp-exposure-namespace-test-") as temporary:
    manifest = pathlib.Path(temporary) / "exposure.yaml"
    manifest.write_text(manifest_text, encoding="utf-8")
    check(
        module.manifest_namespaces(manifest) == {"sadp-platform", "monitoring"},
        "YAML parser가 metadata.namespace, Namespace 문서, backendRefs.namespace를 수집",
    )

    existing = {"default"}
    created: list[str] = []

    def fake_run(command, **kwargs):
        if "get" in command and "namespaces" in command:
            stdout = json.dumps(
                {"items": [{"metadata": {"name": item}} for item in sorted(existing)]}
            )
            return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")
        if "create" in command and "namespace" in command:
            namespace = command[command.index("namespace") + 1]
            created.append(namespace)
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=f"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: {namespace}\n",
                stderr="",
            )
        if "apply" in command:
            namespace = str(kwargs.get("input", "")).split("name:", 1)[1].strip()
            existing.add(namespace)
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
        raise AssertionError(command)

    original_argv = sys.argv
    original_run = module.subprocess.run
    original_geteuid = module.os.geteuid
    try:
        module.subprocess.run = fake_run
        sys.argv = [str(SCRIPT), "--manifest", str(manifest), "--kubectl", "kubectl"]
        plan_output = io.StringIO()
        with contextlib.redirect_stdout(plan_output):
            plan_status = module.main()
        check(
            plan_status == 0
            and not created
            and "monitoring" in plan_output.getvalue()
            and "--prepare-exposure --apply" in plan_output.getvalue(),
            "기본 plan은 누락 Namespace와 다음 명령만 출력하고 리소스를 만들지 않음",
        )

        module.os.geteuid = lambda: 0
        sys.argv.append("--apply")
        with contextlib.redirect_stdout(io.StringIO()):
            first_status = module.main()
        first_created = list(created)
        with contextlib.redirect_stdout(io.StringIO()):
            second_status = module.main()
        check(
            first_status == second_status == 0
            and first_created == ["monitoring", "sadp-platform"]
            and created == first_created,
            "--apply는 Namespace만 생성하며 두 번째 실행은 멱등",
        )
    finally:
        sys.argv = original_argv
        module.subprocess.run = original_run
        module.os.geteuid = original_geteuid

installer = PLATFORM_INSTALLER.read_text(encoding="utf-8")
prepare_at = installer.find("prepare-exposure-namespaces.py --apply")
exposure_at = installer.find("kctl apply -f platform/exposure/resources.yaml")
check(
    0 <= prepare_at < exposure_at,
    "통합 플랫폼 설치기는 HTTPRoute/ReferenceGrant manifest 직전에 Namespace preflight 실행",
)
check(
    "Namespace만 생성; workload와 Secret은 만들지 않음" in SCRIPT.read_text(encoding="utf-8"),
    "Namespace preflight 경계는 workload/Secret을 만들지 않음",
)

print(f"통과 {passed} / 실패 {failed}")
raise SystemExit(1 if failed else 0)
