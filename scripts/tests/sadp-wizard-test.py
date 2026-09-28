#!/usr/bin/env python3
"""대화형 설치기가 env 계약과 기존 통합 설치기 경계를 유지하는지 검사한다."""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
from unittest.mock import patch
import io
from contextlib import redirect_stdout


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

def answers(overrides: dict[str, str], *, quick: bool = False) -> str:
    current = dict(values)
    lines = []
    for _, questions in wizard.SECTIONS:
        network_defaults = wizard.network_default_questions(questions, current) if quick else []
        if network_defaults:
            lines.append("")
        defaults = wizard.default_questions(questions, current) if quick else []
        skipped = {q.key for q in defaults} if len(defaults) > 1 else set()
        if skipped:
            lines.append("")
        skipped.update(q.key for q in network_defaults)
        for question in questions:
            if question.key not in skipped and wizard.should_ask(question, current):
                value = overrides.get(question.key, current.get(question.key, ""))
                lines.append(value or "-")
                current[question.key] = value
    return "\n".join(lines) + "\n"


with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    command = ["bash", "./sadp", "--install", "--interactive", "--advanced", "--env-file", str(output)]
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

with patch("builtins.input", return_value=""), redirect_stdout(io.StringIO()):
    quick = dict(values)
    quick["SADP_PORTAL_FORGEJO_TOKEN_FILE"] = "/etc/sadp/secrets/portal-token"
    with patch.object(wizard, "answer", side_effect=lambda q, current: current) as quick_answer:
        wizard.collect_answers(quick, advanced=False, detect=False)
    detailed = dict(quick)
    with patch.object(wizard, "answer", side_effect=lambda q, current: current) as full_answer:
        wizard.collect_answers(detailed, advanced=True, detect=False)
check("SW-16 간편 모드는 값을 유지하면서 개별 질문을 10개 이상 줄임",
      quick == detailed and full_answer.call_count - quick_answer.call_count >= 10)
asked = {call.args[0].key for call in quick_answer.call_args_list}
check("SW-17 간편 모드도 주소·인증·이미지·보호 NIC·Secret 경로는 확인",
      {"BASE_DOMAIN", "OCI_REGISTRY", "OIDC_ISSUER", "PUBLIC_EXPOSURE_MODE",
       "GUARDED_INTERFACES", "CLUSTER_MODE", "INTERNAL_INTERFACE", "PUBLIC_IP", "TEST_APP_IMAGE_TAG",
       "SADP_PORTAL_FORGEJO_TOKEN_FILE"} <= asked)

with patch("builtins.input", return_value="n"), redirect_stdout(io.StringIO()):
    with patch.object(wizard, "answer", side_effect=lambda q, current: current) as edit_answer:
        wizard.collect_answers(dict(quick), advanced=False, detect=False)
check("SW-18 기본 설정 묶음 거절 시 상세 질문으로 복귀", edit_answer.call_count == full_answer.call_count)

interfaces = [
    {"ifname": "lan0", "addr_info": [{"family": "inet", "scope": "global",
                                      "local": "10.20.30.11", "prefixlen": 24}]},
    {"ifname": "wan0", "addr_info": []},
]
with patch.object(wizard, "local_interfaces", return_value=interfaces), \
     patch.object(wizard.socket, "gethostname", return_value="control.test.invalid"), \
     patch("builtins.input", side_effect=["1", "1", "y"]), redirect_stdout(io.StringIO()):
    detected = dict(values)
    skipped = wizard.suggest_network(detected)
check("SW-19 명시적으로 선택·수락한 로컬 주소와 NIC만 반영",
      detected["CONTROL_PLANE_HOSTNAME"] == "control"
      and detected["INTERNAL_INTERFACE"] == "lan0" and detected["EXTERNAL_INTERFACE"] == "wan0"
      and detected["NODE_INTERNAL_CIDRS"] == "10.20.30.0/24"
      and skipped == {"CONTROL_PLANE_HOSTNAME", "CONTROL_PLANE_IP", "INTERNAL_INTERFACE",
                      "EXTERNAL_INTERFACE", "NODE_INTERNAL_CIDRS"}
      and detected["WORKER_NODES"] == values["WORKER_NODES"]
      and detected["PUBLIC_EXPOSURE_MODE"] == values["PUBLIC_EXPOSURE_MODE"])
with patch.object(wizard, "local_interfaces", return_value=interfaces), \
     patch("builtins.input", side_effect=["1", "1", "n"]), redirect_stdout(io.StringIO()):
    rejected = dict(values)
    skipped = wizard.suggest_network(rejected)
check("SW-20 탐지값 거절 시 기존 env 값과 질문 보존", rejected == values and not skipped)
with patch.object(wizard.subprocess, "run", side_effect=FileNotFoundError):
    check("SW-21 ip 도구가 없으면 탐지 없이 수동 입력 가능", wizard.local_interfaces() == [])
with patch.object(wizard.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "not-json")):
    check("SW-22 잘못된 탐지 출력은 수동 입력으로 복귀", wizard.local_interfaces() == [])
with patch.object(wizard, "local_interfaces") as probe, \
     patch.object(wizard, "answer", side_effect=lambda q, current: current), \
     patch("builtins.input", return_value=""), redirect_stdout(io.StringIO()):
    wizard.collect_answers(dict(quick), advanced=False, detect=False)
check("SW-23 no-detect에서는 시스템 조회를 하지 않음", not probe.called)
result = subprocess.run(["bash", "./sadp", "--install", "--no-detect"], cwd=ROOT,
                        capture_output=True, text=True)
check("SW-24 일반 설치에서 마법사 전용 옵션 오용 거부", result.returncode == 2)

with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    result = subprocess.run(
        ["bash", "./sadp", "--install", "--interactive", "--no-detect", "--env-file", str(output)],
        cwd=ROOT, input=answers({"SADP_PORTAL_FORGEJO_TOKEN_FILE": "/etc/sadp/secrets/portal-token"},
                               quick=True) + "y\n", capture_output=True, text=True)
    check("SW-25 간편 입력·no-detect도 env 검증·저장 후 기존 all 계획 실행",
          result.returncode == 0 and output.exists() and "[PLAN]" in result.stdout
          and output.stat().st_mode & 0o777 == 0o600)

multiple = [{"ifname": "lan0", "addr_info": interfaces[0]["addr_info"] + [
    {"family": "inet", "scope": "global", "local": "10.20.40.11", "prefixlen": 24}]}]
with patch.object(wizard, "local_interfaces", return_value=multiple), \
     patch("builtins.input", side_effect=["1", "2", "y"]), redirect_stdout(io.StringIO()):
    detected = dict(values)
    skipped = wizard.suggest_network(detected)
check("SW-26 다중 주소는 사용자가 선택하며 없는 외부 NIC는 수동 질문 유지",
      detected["CONTROL_PLANE_IP"] == "10.20.40.11"
      and detected["NODE_INTERNAL_CIDRS"] == "10.20.40.0/24"
      and "EXTERNAL_INTERFACE" not in skipped)


network_values = dict(values, CONTROL_PLANE_HOSTNAME="control", CONTROL_PLANE_IP="10.20.30.11",
                      NODE_INTERNAL_CIDRS="10.20.30.0/24", INTERNAL_INTERFACE="lan0", EXTERNAL_INTERFACE="wan0")
def component(name, args):
    return {"metadata": {"name": name}, "spec": {"nodeName": "control", "containers": [
        {"name": name, "command": [name], "args": args}]}, "status": {"phase": "Running"}}

cluster_pods = [
    component("kube-controller-manager", ["--cluster-cidr=10.42.0.0/16"]),
    component("kube-apiserver", ["--service-cluster-ip-range", "10.43.0.0/16"]),
    {"metadata": {"labels": {"k8s-app": "kube-dns"}}, "status": {"phase": "Running"},
     "spec": {"volumes": [{"configMap": {"name": "actual-coredns"}}]}},
]
cluster_responses = {
    ("nodes",): {"items": [{"metadata": {"name": "control", "labels": {
        "node-role.kubernetes.io/control-plane": "true"}},
        "spec": {"podCIDR": "10.42.0.0/24"},
        "status": {"addresses": [{"type": "InternalIP", "address": "10.20.30.11"}]}}]},
    ("pods", "-n", "kube-system"): {"items": cluster_pods},
    ("services", "-n", "kube-system", "-l", "k8s-app=kube-dns"):
        {"items": [{"spec": {"clusterIP": "10.43.0.10"}}]},
    ("service", "kubernetes", "-n", "default"): {"spec": {"clusterIP": "10.43.0.1"}},
    ("endpointslices", "-n", "default", "-l", "kubernetes.io/service-name=kubernetes"):
        {"items": [{"endpoints": [{"addresses": ["10.20.30.11"]}]}]},
    ("configmap", "actual-coredns", "-n", "kube-system"):
        {"data": {"Corefile": ".:53 {\n  errors\n  forward . 10.20.30.12 {\n    max_concurrent 1000\n  }\n}\n"}},
}
with patch.object(wizard, "read_cluster", side_effect=lambda *args: cluster_responses.get(args, {})):
    discovered = wizard.cluster_network_candidates(network_values)
check("SW-27 실행 인자·Service·EndpointSlice·Corefile에서 6개 실제 값 조회",
      {key: value for key, (value, _) in discovered.items()} == {
          "POD_CIDRS": "10.42.0.0/16", "SERVICE_CIDRS": "10.43.0.0/16",
          "CLUSTER_DNS_IP": "10.43.0.10", "CLUSTER_UPSTREAM_DNS": "10.20.30.12:53",
          "KUBERNETES_API_ADDRESSES": "10.43.0.1,10.20.30.11", "RKE2_SERVER_ENDPOINT": "10.20.30.11"})
with patch.object(wizard, "read_cluster", side_effect=lambda *args: cluster_responses.get(args, {})):
    mismatch = wizard.cluster_network_candidates(dict(network_values, CONTROL_PLANE_IP="10.20.30.99"))
check("SW-28 선택한 control-plane 신원이 다르면 다른 클러스터의 값 사용 금지", not mismatch)
with patch.object(wizard, "read_cluster", return_value={}):
    unavailable = wizard.cluster_network_candidates(network_values)
check("SW-29 API 조회 실패 시 예제 CIDR·기본값을 탐지값으로 승격하지 않음", not unavailable)
no_flags = dict(cluster_responses)
no_flags[("pods", "-n", "kube-system")] = {"items": []}
with patch.object(wizard, "read_cluster", side_effect=lambda *args: no_flags.get(args, {})):
    missing_flags = wizard.cluster_network_candidates(network_values)
check("SW-30 Node별 /24·Service IP로 클러스터 CIDR을 추측하지 않음",
      "POD_CIDRS" not in missing_flags and "SERVICE_CIDRS" not in missing_flags)
check("SW-31 서로 다른 실행 인자와 IPv6 CIDR을 자동 축약하지 않음",
      wizard.pod_flag(cluster_pods + [component("kube-controller-manager", ["--cluster-cidr=10.44.0.0/16"])],
                      "control", "kube-controller-manager", "--cluster-cidr") is None
      and wizard.ipv4_list(["10.42.0.0/16", "fd00::/48"], networks=True) is None)
check("SW-32 resolver 파일·외부망·복수 upstream·다중 zone·import는 수동 확인",
      all(wizard.coredns_upstream(corefile, "10.20.30.0/24") is None for corefile in [
          ".:53 {\n forward . /etc/resolv.conf\n}",
          ".:53 {\n forward . 192.0.2.53\n}",
          ".:53 {\n forward . 10.20.30.12 10.20.30.13\n}",
          ".:53 {\n forward . 10.20.30.12\n}\ninternal:53 {\nforward . 10.20.30.13\n}",
          ".:53 {\n import custom/*\n forward . 10.20.30.12\n}",
      ]))
public_nic = {"ifname": "spare0", "addr_info": [{"family": "inet6", "local": "2000::1"}]}
check("SW-33 공인 IPv6 후보를 추가하되 기존 보호 목록 유지·역할 NIC 제외",
      wizard.guarded_candidates(dict(network_values, GUARDED_INTERFACES="old0"),
                                [public_nic, dict(public_nic, ifname="lan0"),
                                 dict(public_nic, ifname="wan0"), dict(public_nic, ifname="cali123")]) == "old0,spare0")
check("SW-34 후보가 없다고 기존 보호 목록을 빈 값으로 바꾸지 않음",
      wizard.guarded_candidates(dict(network_values, GUARDED_INTERFACES="old0"), interfaces) is None)
with patch.object(wizard, "cluster_network_candidates", return_value=discovered), \
     patch.object(wizard, "local_interfaces", return_value=interfaces + [public_nic]), \
     patch.object(wizard, "confirm", return_value=True), redirect_stdout(io.StringIO()):
    accepted = dict(network_values)
    accepted_keys = wizard.suggest_cluster_network(accepted)
check("SW-35 한 번 수락하면 확인한 7개 질문을 생략하고 저장할 값 반영",
      accepted_keys == set(discovered) | {"GUARDED_INTERFACES"}
      and accepted["POD_CIDRS"] == "10.42.0.0/16" and accepted["GUARDED_INTERFACES"] == "spare0")
with patch.object(wizard, "cluster_network_candidates", return_value=discovered), \
     patch.object(wizard, "local_interfaces", return_value=interfaces), \
     patch.object(wizard, "confirm", return_value=False), redirect_stdout(io.StringIO()):
    rejected = dict(network_values)
    rejected_keys = wizard.suggest_cluster_network(rejected)
check("SW-36 조회값 거절 시 기존 값과 개별 질문 유지", not rejected_keys and rejected == network_values)
with patch.object(wizard, "automatic_network_defaults", return_value={}), \
     patch.object(wizard, "suggest_network", return_value=set()), \
     patch.object(wizard, "cluster_network_candidates", return_value=discovered), \
     patch.object(wizard, "local_interfaces", return_value=interfaces), \
     patch.object(wizard, "confirm", side_effect=lambda prompt, **kw: not prompt.startswith("IP·CIDR")), \
     patch.object(wizard, "answer", side_effect=lambda q, current: current) as remaining, \
     redirect_stdout(io.StringIO()):
    wizard.collect_answers(dict(network_values), advanced=False, detect=True)
check("SW-37 실제 질문 루프에서도 수락한 클러스터 값을 다시 묻지 않음",
      not set(discovered).intersection(call.args[0].key for call in remaining.call_args_list))
with patch.object(wizard.pathlib.Path, "is_file", return_value=True), \
     patch.object(wizard.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{}')) as run:
    wizard.read_cluster("nodes")
check("SW-38 고정 RKE2 kubeconfig·읽기 전용 get·시간 제한 사용",
      run.call_args.args[0] == ["/var/lib/rancher/rke2/bin/kubectl", "--kubeconfig",
          "/etc/rancher/rke2/rke2.yaml", "--request-timeout=3s", "get", "nodes", "-o", "json"]
      and run.call_args.kwargs["timeout"] == 5)
with patch.object(wizard.pathlib.Path, "is_file", return_value=True), \
     patch.object(wizard.subprocess, "run", side_effect=subprocess.TimeoutExpired("kubectl", 5)), \
     redirect_stdout(io.StringIO()) as output:
    timed_out = wizard.read_cluster("nodes")
check("SW-39 조회 timeout은 원문 출력 없이 수동 입력으로 복귀", not timed_out and not output.getvalue())

with patch.object(wizard, "automatic_network_defaults", return_value={}), \
     patch.object(wizard, "suggest_network") as local_probe, \
     patch.object(wizard, "suggest_cluster_network") as cluster_probe, \
     patch("builtins.input", return_value=""), \
     patch.object(wizard, "answer", side_effect=lambda q, current: current) as questions, \
     redirect_stdout(io.StringIO()):
    kept = dict(network_values)
    wizard.collect_answers(kept, advanced=False, detect=True)
asked_keys = {call.args[0].key for call in questions.call_args_list}
check("SW-40 기본 IP 유지 선택은 개별 IP 질문·재탐지 없이 기존 값 보존",
      all(kept[key] == value for key, value in network_values.items())
      and not asked_keys.intersection(wizard.NETWORK_DEFAULTS)
      and not local_probe.called and not cluster_probe.called)
check("SW-41 IP 기본값을 유지해도 실제 노드·NIC·보호·공개·인증 선택은 확인",
      {"CLUSTER_MODE", "CONTROL_PLANE_HOSTNAME", "WORKER_NODES", "INTERNAL_INTERFACE",
       "EXTERNAL_INTERFACE", "GUARDED_INTERFACES", "PUBLIC_IP", "PUBLIC_EXPOSURE_MODE",
       "OIDC_ISSUER", "TLS_SOURCE"} <= asked_keys)
with patch("builtins.input", return_value=""), \
     patch.object(wizard, "answer", side_effect=lambda q, current: current) as questions, \
     redirect_stdout(io.StringIO()):
    wizard.collect_answers(dict(network_values, CONTROL_PLANE_IP=""), advanced=False, detect=False)
check("SW-42 필수 IP 기본값이 없으면 묶음 유지로 누락시키지 않고 질문",
      "CONTROL_PLANE_IP" in {call.args[0].key for call in questions.call_args_list})
with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    output.write_text(wizard.replace_values(template, {"CLUSTER_UPSTREAM_DNS": "10.20.30.11:1053"}))
    result = subprocess.run(
        ["bash", "./sadp", "--install", "--interactive", "--no-detect", "--env-file", str(output)],
        cwd=ROOT, input=answers({"SADP_PORTAL_FORGEJO_TOKEN_FILE": "/etc/sadp/secrets/portal-token"},
                               quick=True) + "y\n", capture_output=True, text=True)
    check("SW-43 재실행의 기본값은 template이 아닌 저장된 DNS 주소이며 검증 후 계획만 실행",
          result.returncode == 0 and "[PLAN]" in result.stdout
          and "CLUSTER_UPSTREAM_DNS=10.20.30.11:1053\n" in output.read_text())


with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    bad_content = wizard.replace_values(template, {
        "NODE_INTERNAL_CIDRS": "10.20.30.0/28",
        "SADP_PORTAL_FORGEJO_TOKEN_FILE": "/etc/sadp/secrets/portal-token",
    })
    output.write_text(bad_content)
    command = ["bash", "./sadp", "--install", "--interactive", "--repair", "--env-file", str(output)]
    result = subprocess.run(command, cwd=ROOT, input="y\n\n10.20.30.0/24\n",
                            capture_output=True, text=True)
    repaired = wizard.parse_values(output.read_text())
    original = wizard.parse_values(bad_content)
    check("SW-44 worker 범위 오류는 CIDR만 수정하고 전체 재질문 없이 검증·계획 실행",
          result.returncode == 0 and "outside NODE_INTERNAL_CIDRS" in result.stderr
          and "[PLAN]" in result.stdout and "== 사이트 이름" not in result.stdout
          and repaired["NODE_INTERNAL_CIDRS"] == "10.20.30.0/24"
          and all(repaired[key] == value for key, value in original.items() if key != "NODE_INTERNAL_CIDRS")
          and output.stat().st_mode & 0o777 == 0o600)
    output.write_text(bad_content)
    result = subprocess.run(command, cwd=ROOT, input="y\nq\n", capture_output=True, text=True)
    check("SW-45 오류 수정 취소는 기존 파일·설치 상태 보존",
          result.returncode == 1 and output.read_text() == bad_content and "[PLAN]" not in result.stdout
          and not list(output.parent.glob(".site.env.*")))
    result = subprocess.run(command, cwd=ROOT, input="y\n", capture_output=True, text=True)
    check("SW-46 오류 수정 중 EOF도 기존 파일을 보존하고 traceback 없이 종료",
          result.returncode == 1 and output.read_text() == bad_content and "Traceback" not in result.stderr)
    multiple_errors = wizard.replace_values(bad_content, {"CLUSTER_DNS_IP": "invalid"})
    output.write_text(multiple_errors)
    result = subprocess.run(command, cwd=ROOT, input="y\n\n10.20.30.0/24\n\n10.53.0.10\n",
                            capture_output=True, text=True)
    check("SW-47 연속 오류는 앞서 고친 값을 유지하고 다음 오류만 다시 질문",
          result.returncode == 0 and result.stdout.count("다른 답변은 유지합니다") == 2
          and wizard.parse_values(output.read_text())["NODE_INTERNAL_CIDRS"] == "10.20.30.0/24"
          and wizard.parse_values(output.read_text())["CLUSTER_DNS_IP"] == "10.53.0.10")
    output.unlink()
    result = subprocess.run(command, cwd=ROOT, input="", capture_output=True, text=True)
    check("SW-48 저장 파일이 없으면 repair가 template으로 대체하거나 답변을 복원했다고 하지 않음",
          result.returncode == 1 and "기존 --output 파일이 필요" in result.stderr and not output.exists())
    result = subprocess.run(
        ["bash", "./sadp", "--install", "--interactive", "--advanced", "--env-file", str(output)],
        cwd=ROOT, input=answers({"NODE_INTERNAL_CIDRS": "10.20.30.0/28",
                                "SADP_PORTAL_FORGEJO_TOKEN_FILE": "/etc/sadp/secrets/portal-token"})
                                + "y\n\n10.20.30.0/24\n", capture_output=True, text=True)
    check("SW-49 새로 답한 내용도 검증 실패 후 그 자리에서 수정·저장 가능",
          result.returncode == 0 and output.exists() and "[PLAN]" in result.stdout
          and result.stdout.count("== 사이트 이름") == 1)

with patch("builtins.input", side_effect=["WORKER_NODES", "node-a=10.20.30.21"]), \
     redirect_stdout(io.StringIO()):
    repaired = dict(values)
    completed = wizard.repair_answers("worker 10.90.0.21 is outside NODE_INTERNAL_CIDRS", repaired)
check("SW-50 IP 오타는 worker만 수정하고 내부망 CIDR을 자동 확대하지 않음",
      completed and repaired["WORKER_NODES"] == "node-a=10.20.30.21"
      and repaired["NODE_INTERNAL_CIDRS"] == values["NODE_INTERNAL_CIDRS"])
with patch("builtins.input", side_effect=["?", "UNKNOWN_KEY", "POD_CIDRS,SERVICE_CIDRS",
                                         "10.42.0.0/16", "10.43.0.0/16"]), redirect_stdout(io.StringIO()):
    repaired = dict(values)
    completed = wizard.repair_answers("node CIDR overlaps pod CIDR", repaired)
check("SW-51 key 목록·잘못된 선택 재입력·복수 항목 수정 지원",
      completed and repaired["POD_CIDRS"] == "10.42.0.0/16" and repaired["SERVICE_CIDRS"] == "10.43.0.0/16")
with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    content = wizard.replace_values(template, {"CERT_MANAGER_NODE_PLACEMENT": "invalid"})
    current = wizard.parse_values(content)
    with patch("builtins.input", side_effect=["", "control-plane"]), redirect_stdout(io.StringIO()):
        saved = wizard.save_with_repair(output, content, current)
    check("SW-52 기본 질문에 없는 유효한 설정 key도 오류 수정 결과 저장",
          saved and wizard.parse_values(output.read_text())["CERT_MANAGER_NODE_PLACEMENT"] == "control-plane")

with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    output.write_text("\n".join(line for line in template.splitlines()
                                if not line.startswith(("SITE_NAME=", "WORKLOAD_NAMESPACE="))) + "\n")
    result = subprocess.run(
        ["bash", "./sadp", "--install-wizard", "--repair", "--output", str(output)],
        cwd=ROOT, input="y\n\nrepair-site\n\nsadp-apps\n", capture_output=True, text=True)
    repaired = wizard.parse_values(output.read_text())
    check("SW-53 필수 key가 빠진 파일도 요약에서 중단하지 않고 누락 항목만 복원",
          result.returncode == 0 and repaired.get("SITE_NAME") == "repair-site"
          and repaired.get("WORKLOAD_NAMESPACE") == "sadp-apps" and "Traceback" not in result.stderr)


stale = dict(network_values, CONTROL_PLANE_HOSTNAME="old-node", CONTROL_PLANE_IP="10.99.0.11",
             NODE_INTERNAL_CIDRS="10.99.0.0/24", INTERNAL_INTERFACE="old0")
with patch.object(wizard, "read_cluster", side_effect=lambda *args: cluster_responses.get(args, {})), \
     patch.object(wizard, "local_interfaces", return_value=interfaces):
    actual = wizard.automatic_network_defaults(stale)
check("SW-54 예제 hostname·IP와 달라도 실제 Node와 로컬 NIC를 대조해 기본값 조회",
      actual["CONTROL_PLANE_HOSTNAME"][0] == "control" and actual["CONTROL_PLANE_IP"][0] == "10.20.30.11"
      and actual["NODE_INTERNAL_CIDRS"][0] == "10.20.30.0/24" and actual["INTERNAL_INTERFACE"][0] == "lan0"
      and actual["POD_CIDRS"][0] == "10.42.0.0/16" and actual["SERVICE_CIDRS"][0] == "10.43.0.0/16"
      and actual["RKE2_SERVER_ENDPOINT"][0] == "10.20.30.11" and stale["CONTROL_PLANE_IP"] == "10.99.0.11")
with patch.object(wizard, "automatic_network_defaults", return_value=actual) as lookup, \
     patch.object(wizard, "suggest_network") as manual, \
     patch.object(wizard, "suggest_cluster_network") as repeat, \
     patch.object(wizard, "confirm", return_value=True), \
     patch.object(wizard, "answer", side_effect=lambda q, current: current) as remaining, \
     redirect_stdout(io.StringIO()) as screen:
    accepted = dict(stale)
    wizard.collect_answers(accepted, advanced=False, detect=True)
check("SW-55 실제 조회값을 먼저 표시하고 Enter 유지 시 한 번 반영·중복 질문 생략",
      lookup.call_count == 1 and not manual.called and not repeat.called
      and all(accepted[key] == value for key, (value, _) in actual.items())
      and not set(actual).intersection(call.args[0].key for call in remaining.call_args_list)
      and "로컬 내부 NIC의 prefix" in screen.getvalue() and "예제와 동일·미확인" in screen.getvalue())
with patch.object(wizard, "automatic_network_defaults", return_value=actual), \
     patch.object(wizard, "suggest_cluster_network", return_value=set()), \
     patch.object(wizard, "confirm", side_effect=lambda prompt, **kw: not prompt.startswith("IP·CIDR")), \
     patch.object(wizard, "answer", side_effect=lambda q, current: current), redirect_stdout(io.StringIO()):
    rejected = dict(stale)
    wizard.collect_answers(rejected, advanced=False, detect=True)
check("SW-56 조회값을 거절하면 기존 값을 자동 덮어쓰지 않음",
      all(rejected[key] == value for key, value in stale.items()))
with patch.object(wizard, "read_cluster", side_effect=lambda *args: cluster_responses.get(args, {})), \
     patch.object(wizard, "local_interfaces", return_value=[]):
    remote = wizard.automatic_network_defaults(stale)
check("SW-57 현재 호스트 NIC와 일치하지 않는 control-plane은 자동 선택하지 않음", not remote)
with patch.object(wizard, "read_cluster", side_effect=lambda *args: cluster_responses.get(args, {})), \
     patch.object(wizard, "local_interfaces", return_value=interfaces + [dict(interfaces[0], ifname="bond0")]):
    ambiguous = wizard.automatic_network_defaults(stale)
check("SW-58 같은 IP가 여러 NIC에 있으면 역할을 임의로 선택하지 않음", not ambiguous)
with patch.object(wizard, "automatic_network_defaults") as lookup, \
     patch.object(wizard, "confirm", return_value=True), \
     patch.object(wizard, "answer", side_effect=lambda q, current: current), redirect_stdout(io.StringIO()):
    wizard.collect_answers(dict(stale), advanced=False, detect=False)
check("SW-59 no-detect는 기존값을 유지하고 새 자동 기본값 조회도 생략", not lookup.called)


with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    content = wizard.replace_values(template, {
        "TLS_SOURCE": "provided", "PROVIDED_CERTIFICATE_PATH": "outside/fullchain.pem",
        "PROVIDED_PRIVATE_KEY_PATH": "outside/privkey.pem",
    })
    output.write_text(content)
    result = subprocess.run(
        ["bash", "./sadp", "--install-wizard", "--repair", "--output", str(output)],
        cwd=ROOT, input="y\nPROVIDED_CERTIFICATE_PATH,PROVIDED_PRIVATE_KEY_PATH\nwildcard/fullchain.pem\nwildcard/privkey.pem\n",
        capture_output=True, text=True)
    saved = wizard.parse_values(output.read_text())
    check("SW-60 제공 PEM의 잘못된 상대경로는 렌더 전 거부하고 두 경로만 수정하여 저장",
          result.returncode == 0 and "PROVIDED_CERTIFICATE_PATH must be an absolute path or a relative path under wildcard/" in result.stderr
          and saved["PROVIDED_CERTIFICATE_PATH"] == "wildcard/fullchain.pem"
          and saved["PROVIDED_PRIVATE_KEY_PATH"] == "wildcard/privkey.pem"
          and "== 사이트 이름" not in result.stdout)

with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    paths = {
        "TLS_SOURCE": "provided",
        "PROVIDED_CERTIFICATE_PATH": "/etc/letsencrypt/live/example.invalid/fullchain.pem",
        "PROVIDED_PRIVATE_KEY_PATH": "/etc/letsencrypt/live/example.invalid/privkey.pem",
    }
    output.write_text(wizard.replace_values(template, paths))
    result = subprocess.run(
        ["bash", "./sadp", "--install-wizard", "--repair", "--output", str(output)],
        cwd=ROOT, input="y\n", capture_output=True, text=True)
    saved = wizard.parse_values(output.read_text())
    check("SW-61 Certbot 절대경로를 PEM 본문 없이 그대로 검증하고 저장",
          result.returncode == 0 and all(saved[key] == value for key, value in paths.items()))

with tempfile.TemporaryDirectory() as raw_directory:
    output = pathlib.Path(raw_directory) / "site.env"
    result = subprocess.run(
        ["bash", "./sadp", "--install-wizard", "--advanced", "--phase", "all", "--output", str(output)],
        cwd=ROOT, input=answers({"OIDC_SHARED_CLIENT_ID": "Authentik.Shared_123",
                                "SADP_PORTAL_FORGEJO_TOKEN_FILE": "/etc/sadp/secrets/portal-token"}) + "y\n",
        capture_output=True, text=True)
    check("SW-62 공유 Provider는 Client ID 한 번 입력·Portal 질문 생략·callback 목록 안내",
          result.returncode == 0 and "Portal OIDC client ID [" not in result.stdout
          and "공통 Secret 1개" in result.stdout and "/api/auth/callback/oidc" in result.stdout
          and wizard.parse_values(output.read_text())["OIDC_SHARED_CLIENT_ID"] == "Authentik.Shared_123")

print(f"통과 {passed} / 실패 {failed}")
raise SystemExit(1 if failed else 0)
