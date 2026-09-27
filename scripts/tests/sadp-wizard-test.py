#!/usr/bin/env python3
"""대화형 설치기가 env 계약과 기존 통합 설치기 경계를 유지하는지 검사한다."""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/install/sadp-install-wizard.py"
spec = importlib.util.spec_from_file_location("sadp_install_wizard", SCRIPT)
assert spec and spec.loader
wizard = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = wizard
spec.loader.exec_module(wizard)

passed = 0
failed = 0


def check(label: str, condition: bool) -> None:
    global passed, failed
    if condition:
        passed += 1
        print(f"[OK]   {label}")
    else:
        failed += 1
        print(f"[FAIL] {label}")


template = (ROOT / "environments/site.env.example").read_text(encoding="utf-8")
values = wizard.parse_values(template)
rendered = wizard.replace_values(
    template,
    {"SITE_NAME": "guided-site", "GUARDED_INTERFACES": "ens4,ens5"},
)
check(
    "SW-01 선택 답변만 기존 template assignment에 안전하게 반영",
    "SITE_NAME=guided-site" in rendered and "GUARDED_INTERFACES=ens4,ens5" in rendered,
)

inactive = dict(values)
inactive.update(
    {
        "TLS_SOURCE": "provided",
        "PUBLIC_EXPOSURE_MODE": "nat",
        "PUBLIC_IP_NODE": "worker-1",
        "SADP_DNS_TSIG_SECRET_FILE": "/etc/sadp/secrets/unused",
        "SADP_INSTALL_GITOPS": "false",
        "SADP_ARGO_REPO_TOKEN_FILE": "/etc/sadp/secrets/unused",
        "SADP_BUILD_IMAGES": "false",
        "SADP_BUILD_NODE": "worker-1",
        "SADP_DEPLOY_APPS": "false",
        "SADP_REGISTRY_PULL_DOCKERCONFIG": "/etc/sadp/secrets/unused",
        "SADP_REGISTRY_PUSH_DOCKERCONFIG": "/etc/sadp/secrets/unused",
    }
)
wizard.clear_inactive(inactive)
check(
    "SW-02 사용하지 않는 Secret 경로와 선택 입력을 비움",
    all(
        not inactive[key]
        for key in (
            "SADP_DNS_TSIG_SECRET_FILE",
            "SADP_ARGO_REPO_TOKEN_FILE",
            "SADP_BUILD_NODE",
            "SADP_REGISTRY_PULL_DOCKERCONFIG",
            "SADP_REGISTRY_PUSH_DOCKERCONFIG",
            "PUBLIC_IP_NODE",
        )
    )
    and inactive["EXISTING_GATEWAY_TLS_READY"] == "true",
)

args = argparse.Namespace(
    phase="node",
    node_name="worker-1",
    allow_dirty=False,
    apply=True,
)
command = wizard.installer_command(args, pathlib.Path("/etc/sadp/site.env"))
check(
    "SW-03 답변형 설치도 기존 phase installer로 전달",
    command[-5:] == ["--phase", "node", "--node-name", "worker-1", "--apply"]
    and "scripts/install/sadp-install.sh" in command[1],
)

with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    output.write_text("old\n", encoding="utf-8")
    output.chmod(0o600)
    output.unlink()
    output.symlink_to(ROOT / "environments/site.env.example")
    try:
        wizard.write_candidate(output, template)
    except RuntimeError:
        refused_symlink = True
    else:
        refused_symlink = False
    check("SW-04 site.env symlink 덮어쓰기 거부", refused_symlink)

result = subprocess.run(
    ["bash", "./sadp", "--install-wizard", "--show-questions"],
    cwd=ROOT,
    capture_output=True,
    text=True,
    check=False,
)
check(
    "SW-05 공개 dispatcher에서 질문 목록 확인 가능",
    result.returncode == 0
    and "BASE_DOMAIN" in result.stdout
    and "PUBLIC_IP_NODE" in result.stdout
    and "SADP_RUN_VERIFY" in result.stdout,
)

single = dict(values, CLUSTER_MODE="single")
worker_question = next(q for _, questions in wizard.SECTIONS for q in questions if q.key == "WORKER_NODES")
check("SW-06 single은 worker 질문 생략", not wizard.should_ask(worker_question, single))
wizard.clear_inactive(single)
check("SW-07 single 선택 시 예제 worker 목록 제거", single["WORKER_NODES"] == "")
check("SW-08 multi는 worker 질문 유지", wizard.should_ask(worker_question, dict(values, CLUSTER_MODE="multi")))

def answers(overrides: dict[str, str]) -> str:
    current = dict(values)
    lines = []
    for _, questions in wizard.SECTIONS:
        for question in questions:
            if wizard.should_ask(question, current):
                value = overrides.get(question.key, current.get(question.key, ""))
                lines.append(value or "-")
                current[question.key] = value
    return "\n".join(lines) + "\n"


with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    command = ["bash", "./sadp", "--install", "--interactive", "--env-file", str(output)]
    replies = answers({"SADP_PORTAL_FORGEJO_TOKEN_FILE": "/etc/sadp/secrets/portal-token"})
    result = subprocess.run(command, cwd=ROOT, input=replies + "y\n", capture_output=True, text=True)
    check("SW-09 질문형 진입점에서 env 저장 후 all 계획 실행",
          result.returncode == 0 and output.exists() and "[PLAN]" in result.stdout)
    saved = output.read_text() if output.exists() else ""
    check("SW-10 이전 template에 없던 Portal token 경로도 0600으로 저장",
          "SADP_PORTAL_FORGEJO_TOKEN_FILE=/etc/sadp/secrets/portal-token\n" in saved
          and output.stat().st_mode & 0o777 == 0o600)
    result = subprocess.run(command, cwd=ROOT, input=replies + "n\n", capture_output=True, text=True)
    check("SW-11 저장 취소는 기존 env를 보존하고 설치하지 않음",
          result.returncode == 0 and output.read_text() == saved and "[PLAN]" not in result.stdout)
    result = subprocess.run(command, cwd=ROOT, input="", capture_output=True, text=True)
    check("SW-12 입력 중단은 traceback 없이 기존 env 보존",
          result.returncode == 1 and output.read_text() == saved
          and "Traceback" not in result.stderr and "[PLAN]" not in result.stdout)
    invalid = answers({"SADP_PORTAL_FORGEJO_TOKEN_FILE": "/etc/sadp/secrets/portal-token",
                       "CONTROL_PLANE_IP": "invalid"})
    result = subprocess.run(command, cwd=ROOT, input=invalid + "y\n", capture_output=True, text=True)
    check("SW-13 검증 실패는 기존 env를 보존하고 설치하지 않음",
          result.returncode == 1 and output.read_text() == saved and "[PLAN]" not in result.stdout)
    result = subprocess.run(command + ["--phase", "render", "--apply"], cwd=ROOT,
                            input=replies + "y\n", capture_output=True, text=True)
    check("SW-13b apply와 phase를 전달하되 예제값 실제 적용은 기존 설치기가 차단",
          result.returncode == 1 and "예제 BASE_DOMAIN을 실제 설치에 사용할 수 없음" in result.stderr
          and "저장 후 render phase를 실제 적용" in result.stdout)

bundle_question = next(q for _, questions in wizard.SECTIONS for q in questions if q.key == "SADP_PREBUILT_BUNDLE")
check("SW-14 로컬 빌드를 끈 경우에만 bundle 질문",
      wizard.should_ask(bundle_question, dict(values, SADP_BUILD_IMAGES="false"))
      and not wizard.should_ask(bundle_question, values))
preserved = dict(values, SADP_INSTALL_GITOPS="false", SADP_GIT_PUSH_TOKEN_FILE="/etc/sadp/secrets/push")
wizard.clear_inactive(preserved)
check("SW-15 GitOps 구성을 꺼도 Git push 인증 사용자 유지",
      preserved["SADP_ARGO_REPO_USERNAME"] == values["SADP_ARGO_REPO_USERNAME"])

print(f"통과 {passed} / 실패 {failed}")
raise SystemExit(1 if failed else 0)
