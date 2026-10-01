#!/usr/bin/env python3
"""원인 분류(scripts/lib/diagnose.py)와 --doctor 회귀(DG-01~, DR-01~).

fixture 문자열은 실제 사이트 장애에서 본 증상이다. 분류가 맞는지, 정상 상태에서 거짓 경보를
내지 않는지, URL·IP·hostname·Secret·로그 원문을 출력하지 않는지 함께 본다. doctor는 kubectl과
ip를 PATH mock으로 바꿔 클러스터 없이 돈다.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sadp_test_fixture  # noqa: E402

# doctor는 계약·생성물과 예제 site.env 일치를 본다. 사이트 checkout에서도 예제 fixture에서 돈다.
sadp_test_fixture.reexec_in_fixture(__file__)

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIAGNOSE = ROOT / "scripts/lib/diagnose.py"
PASSED = 0
FAILED = 0
LEAKS = ("https://", "203.0.113.5", "idp.example.invalid", "registry.example.invalid",
         "kv/apps/", "s3cr3t-token-value")


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


def classify(command: str, payload, *extra: str, env: dict | None = None) -> subprocess.CompletedProcess:
    text = payload if isinstance(payload, str) else json.dumps(payload)
    return subprocess.run([sys.executable, str(DIAGNOSE), command, *extra], input=text,
                          capture_output=True, text=True, check=False, env=env)


def leaked(output: str) -> list[str]:
    return [item for item in LEAKS if item in output]


def policy(message: str | None) -> dict:
    conditions = [{"type": "Accepted", "status": "True" if message is None else "False",
                   "reason": "Accepted" if message is None else "Invalid", "message": message or "ok"}]
    return {"metadata": {"name": "secure-demo-oidc"}, "status": {"ancestors": [{"conditions": conditions}]}}


NO_ROUTE = ('OIDC: Get "https://idp.example.invalid/application/o/sadp/.well-known/openid-configuration": '
            "dial tcp 203.0.113.5:443: connect: no route to host")

result = classify("security-policy", policy(NO_ROUTE), "--relay-enabled", "false")
out = result.stderr
check("DG-01 SecurityPolicy no route to host(relay 꺼짐)은 relay 켜기 절차를 안내하고 URL/IP를 가림",
      result.returncode == 1 and "[idp-unreachable]" in out and "IDP_RELAY_ENABLED=true" in out
      and "--install-idp-relay --apply" in out and not leaked(out), out)
result = classify("security-policy", policy(NO_ROUTE), "--relay-enabled", "true")
check("DG-02 relay가 켜져 있으면 relay --check와 CoreDNS·envoy-gateway 재시작을 안내",
      result.returncode == 1 and "--install-idp-relay --check" in result.stderr
      and "IDP_RELAY_ENABLED=true" not in result.stderr, result.stderr)
result = classify("security-policy", policy(
    'oidc: issuer did not match the issuer returned by provider, expected "https://idp.example.invalid/x" '
    'got "https://idp.example.invalid/x/"'))
check("DG-03 issuer 불일치는 --verify-idp로 안내",
      result.returncode == 1 and "[issuer-mismatch]" in result.stderr and "--verify-idp" in result.stderr
      and not leaked(result.stderr), result.stderr)
result = classify("security-policy", policy(None))
check("DG-04 Accepted SecurityPolicy는 아무것도 출력하지 않음(거짓 경보 없음)",
      result.returncode == 0 and not result.stdout and not result.stderr, result.stderr)


def external_secret(ready: bool, events: list[str], store_ready: bool = True) -> dict:
    return {
        "externalSecret": {
            "metadata": {"name": "portal-lite-auth"},
            "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False",
                                       "reason": "SecretSyncedError",
                                       "message": "could not get secret data from provider"}]},
        },
        "events": {"items": [{"message": item} for item in events]},
        "store": {"status": {"conditions": [{"type": "Ready", "status": "True" if store_ready else "False"}]}},
    }


TOKEN_EVENT = ('error processing spec.data[2] (key: kv/apps/research/prod/portal-lite), err: '
               'cannot find secret data for key: "FORGEJO_BOT_TOKEN"')
result = classify("external-secret", external_secret(False, [TOKEN_EVENT]))
check("DG-05 ExternalSecret 빠진 FORGEJO_BOT_TOKEN은 key 이름과 --token-only 주입 명령만 출력",
      result.returncode == 1 and "key FORGEJO_BOT_TOKEN 없음" in result.stderr
      and "install-portal-backend.sh --token-only" in result.stderr
      and "SADP_PORTAL_FORGEJO_TOKEN_FILE" in result.stderr and not leaked(result.stderr), result.stderr)
result = classify("external-secret", external_secret(False, [], store_ready=False))
check("DG-06 SecretStore 미준비는 OpenBao seal 확인으로 안내",
      result.returncode == 1 and "--unseal-openbao" in result.stderr, result.stderr)
result = classify("external-secret", external_secret(True, [TOKEN_EVENT]))
check("DG-07 Ready ExternalSecret은 옛 이벤트가 남아도 출력하지 않음",
      result.returncode == 0 and not result.stderr, result.stderr)


def deployment(pods: list[dict], *, available: int = 0, updated: int = 1, replicas: int = 1) -> dict:
    return {
        "deployment": {"metadata": {"name": "portal-lite"}, "spec": {"replicas": replicas},
                       "status": {"availableReplicas": available, "updatedReplicas": updated}},
        "pods": {"items": pods},
    }


def waiting_pod(reason: str, message: str, image: str = "registry.example.invalid/sadp/portal:1") -> dict:
    return {
        "metadata": {"name": "portal-lite-abc"},
        "spec": {"containers": [{"name": "portal", "image": image}]},
        "status": {"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "True"}],
                   "containerStatuses": [{"name": "portal", "ready": False,
                                          "state": {"waiting": {"reason": reason, "message": message}}}]},
    }


result = classify("deployment", deployment([waiting_pod("CreateContainerConfigError",
                                                        'secret "portal-lite-auth" not found')]))
check("DG-08 CreateContainerConfigError는 빠진 Secret 이름과 ExternalSecret 확인을 안내",
      result.returncode == 1 and "Secret portal-lite-auth 없음" in result.stderr and not leaked(result.stderr),
      result.stderr)
pending = {
    "metadata": {"name": "envoy-sadp-new"},
    "spec": {"containers": [{"name": "envoy", "image": "docker.io/envoyproxy/envoy:v1"}]},
    "status": {"phase": "Pending", "conditions": [{
        "type": "PodScheduled", "status": "False", "reason": "Unschedulable",
        "message": "0/3 nodes are available: 1 node(s) had untolerated taint "
                   "{node-role.kubernetes.io/control-plane: true}, 2 node(s) didn't match Pod's node "
                   "affinity/selector. preemption: 0/3 nodes are available"}]},
}
result = classify("deployment", deployment([pending], available=1, updated=0))
check("DG-09 옛 Pod가 가용해도 새 Pod의 control-plane taint Pending을 rollout 정지로 보고",
      result.returncode == 1 and "rollout이 멈춤" in result.stderr
      and "taint node-role.kubernetes.io/control-plane" in result.stderr
      and "toleration" in result.stderr and "nodeSelector/affinity 불일치" in result.stderr, result.stderr)
result = classify("deployment", deployment([waiting_pod("ImagePullBackOff", "Back-off pulling image "
                                                        '"registry.example.invalid/sadp/portal:1"',
                                                        image="docker.io/curlimages/curl:8.21.0")]))
check("DG-10 ImagePullBackOff는 --sync-images --image 명령을 안내하고 원문 메시지는 숨김",
      result.returncode == 1 and "--sync-images --image docker.io/curlimages/curl:8.21.0" in result.stderr
      and "registry.example.invalid" not in result.stderr, result.stderr)
healthy_pod = {"metadata": {"name": "portal-lite-ok"}, "spec": {"containers": [{"name": "portal"}]},
               "status": {"phase": "Running", "containerStatuses": [{"name": "portal", "ready": True}]}}
result = classify("deployment", deployment([healthy_pod], available=1, updated=1))
check("DG-11 정상 Deployment는 출력하지 않음", result.returncode == 0 and not result.stderr, result.stderr)

LOGS = ("[auth][error] TypeError: fetch failed\n  cause: ConnectTimeoutError: Connect Timeout Error "
        "(attempted address: idp.example.invalid:443, timeout: 10000ms) code: 'UND_ERR_CONNECT_TIMEOUT'\n"
        "AUTH_SECRET=s3cr3t-token-value\n")
result = classify("portal-logs", LOGS, "--relay-enabled", "true")
check("DG-12 Portal fetch failed/UND_ERR_CONNECT_TIMEOUT은 relay:443 NetworkPolicy로 안내하고 로그 원문은 숨김",
      result.returncode == 1 and "fetch-failed" in result.stderr and "connect-timeout" in result.stderr
      and "/32:443" in result.stderr and not leaked(result.stderr), result.stderr)
result = classify("portal-logs", "GET /api/v1/health 200\n")
check("DG-13 IdP 연결 오류가 없는 로그는 출력하지 않음", result.returncode == 0 and not result.stderr, result.stderr)

with tempfile.TemporaryDirectory(prefix="diagnose-route-") as raw:
    work = pathlib.Path(raw)
    contract = work / "contract.yaml"
    contract.write_text(json.dumps({"spec": {
        "identityProvider": {"issuer": "https://localhost/application/o/sadp/"},
        "network": {"nodeInternalCIDRs": ["10.20.30.0/24"], "identityProviderRelay": {"enabled": False}},
    }}), encoding="utf-8")
    bin_dir = work / "bin"
    bin_dir.mkdir()
    (bin_dir / "ip").write_text("#!/usr/bin/env bash\necho 'RTNETLINK answers: Network is unreachable' >&2\nexit 2\n")
    (bin_dir / "ip").chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
    result = classify("node-idp-route", "", "--contract", str(contract), env=env)
    check("DG-14 IdP route 없음 + relay 꺼짐은 [FAIL]과 relay 켜기 절차를 안내",
          result.returncode == 1 and "route가 없는데 IDP_RELAY_ENABLED=false" in result.stderr
          and "IDP_RELAY_ENABLED=true" in result.stderr, result.stderr)
    data = json.loads(contract.read_text())
    data["spec"]["network"]["identityProviderRelay"]["enabled"] = True
    contract.write_text(json.dumps(data))
    result = classify("node-idp-route", "", "--contract", str(contract), env=env)
    check("DG-15 relay가 켜져 있으면 route를 묻지 않음", result.returncode == 0 and not result.stderr,
          result.stderr)


# --- inotify / CrashLoop 연쇄 ------------------------------------------------------

crash = {
    "pods": {"items": [{"metadata": {"name": "devtron-nats-0"}, "spec": {"nodeName": "sadp-worker-1"}},
                       {"metadata": {"name": "kubelink-7d9"}, "spec": {"nodeName": "sadp-worker-1"}}]},
    "logs": {
        "devtron-nats-0/reloader": "Error: too many open files",
        "kubelink-7d9/kubelink": "panic: dial tcp: lookup devtron-nats.devtroncd on 10.53.0.10:53: no such host",
    },
}
result = classify("crashloop-logs", crash)
check("DG-16 NATS reloader too many open files를 첫 원인(노드 inotify)으로, DNS 실패는 결과로 분류",
      result.returncode == 1 and "노드 sadp-worker-1 inotify 한도 부족" in result.stderr
      and "devtron-nats-0/reloader" in result.stderr and "결과" in result.stderr
      and "--install-node-sysctl" in result.stderr and "10.53.0.10" not in result.stderr, result.stderr)
only_lookup = {"pods": crash["pods"], "logs": {"kubelink-7d9/kubelink": crash["logs"]["kubelink-7d9/kubelink"]}}
result = classify("crashloop-logs", only_lookup)
check("DG-17 DNS 조회 실패만 있으면 대상 Service의 Pod 상태 확인을 안내",
      result.returncode == 1 and "devtron-nats" in result.stderr and "endpoints" in result.stderr
      and "inotify" not in result.stderr, result.stderr)
result = classify("crashloop-logs", {"pods": crash["pods"], "logs": {"kubelink-7d9/kubelink": "started"}})
check("DG-18 원인 패턴이 없는 CrashLoop 로그는 출력하지 않음", result.returncode == 0 and not result.stderr,
      result.stderr)
result = classify("node-inotify", {"nodes": {
    "sadp-control-plane-1": {"fs.inotify.max_user_instances": "8192", "fs.inotify.max_user_watches": "524288"},
    "sadp-worker-1": {"fs.inotify.max_user_instances": "128", "fs.inotify.max_user_watches": "133056"},
}})
check("DG-19 하한 미만 노드만 이름·값과 node phase 명령으로 보고",
      result.returncode == 1 and "sadp-worker-1: fs.inotify.max_user_instances=128 < 8192" in result.stderr
      and "sadp-control-plane-1" not in result.stderr and "--install-node-sysctl" in result.stderr, result.stderr)

with tempfile.TemporaryDirectory(prefix="node-sysctl-") as raw:
    work = pathlib.Path(raw)
    proc = work / "proc"
    (proc / "fs/inotify").mkdir(parents=True)
    target = work / "sysctl.d/90-sadp-inotify.conf"

    def sysctl_run(instances: str, watches: str, *arguments: str) -> subprocess.CompletedProcess:
        (proc / "fs/inotify/max_user_instances").write_text(instances + "\n")
        (proc / "fs/inotify/max_user_watches").write_text(watches + "\n")
        env = dict(os.environ, SADP_PROC_SYS=str(proc), SADP_SYSCTL_FILE=str(target))
        return subprocess.run(["bash", "./sadp", "--install-node-sysctl", *arguments], cwd=ROOT, env=env,
                              capture_output=True, text=True, check=False)

    result = sysctl_run("128", "133056")
    output = result.stdout + result.stderr
    check("NS-01 기본 실행은 계획만 출력하고 파일을 쓰지 않음",
          result.returncode == 0 and "[PLAN]" in output and "fs.inotify.max_user_instances = 8192" in output
          and not target.exists(), output)
    result = sysctl_run("128", "133056", "--check")
    check("NS-02 하한 미만이면 --check가 [FAIL]과 [NEXT]",
          result.returncode == 1 and "[NEXT]" in result.stderr and "--apply" in result.stderr, result.stderr)
    result = sysctl_run("8192", "1048576")
    output = result.stdout + result.stderr
    check("NS-03 기존 값이 더 크면 낮추지 않음(목표=현재값)",
          "fs.inotify.max_user_watches = 1048576" in output and "fs.inotify.max_user_instances = 8192" in output,
          output)
    result = sysctl_run("8192", "524288", "--check")
    check("NS-04 하한 이상이면 --check 통과", result.returncode == 0 and "[OK]" in result.stdout,
          result.stdout + result.stderr)


# --- doctor ------------------------------------------------------------------------

FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, os, sys
args = [a for a in sys.argv[1:]]
if "--kubeconfig" in args:
    i = args.index("--kubeconfig"); del args[i:i + 2]
scenario = os.environ["DOCTOR_SCENARIO"]
open(os.environ["DOCTOR_LOG"], "a").write(" ".join(args) + "\n")
line = " ".join(args)
def out(value):
    print(json.dumps(value)); sys.exit(0)
def node(name, address, server=False):
    labels = {"node-role.kubernetes.io/control-plane": "true"} if server else {}
    return {"metadata": {"name": name, "labels": labels},
            "status": {"conditions": [{"type": "Ready", "status": "True"}],
                       "addresses": [{"type": "InternalIP", "address": address}]}}
if line.startswith("get daemonset -n kube-system rke2-canal"):
    out({"spec": {"selector": {"matchLabels": {"k8s-app": "canal"}}}})
if line.startswith("get pods -n kube-system -l k8s-app=canal"):
    out({"items": [{"metadata": {"name": f"canal-{i}"}, "spec": {"nodeName": node}, "status": {"phase": "Running"}}
                   for i, node in enumerate(["sadp-control-plane-1", "sadp-worker-1", "sadp-worker-2"])]})
if line.startswith("exec -n kube-system canal-"):
    low = scenario == "inotify-low" and line.startswith("exec -n kube-system canal-1 ")
    print(("128" if low else "8192") if line.endswith("max_user_instances") else "524288"); sys.exit(0)
if line.startswith("get nodes -o name"):
    print("node/sadp-control-plane-1"); sys.exit(0)
if line.startswith("get nodes -o json"):
    out({"items": [node("sadp-control-plane-1", "10.20.30.11", True), node("sadp-worker-1", "10.20.30.21"),
                   node("sadp-worker-2", "10.20.30.22")]})
if line.startswith("exec -n openbao openbao-0"):
    out({"initialized": True, "sealed": scenario == "sealed", "storage_type": "raft"})
if line.startswith("get statefulset -n openbao"):
    out({"items": [{"metadata": {"name": "openbao"}, "spec": {"updateStrategy": {"type": "OnDelete"}},
                    "status": {"updateRevision": "rev-new"}}]})
if line.startswith("get pod -n openbao -o json"):
    out({"items": [{"metadata": {"name": "openbao-0", "labels": {"controller-revision-hash": "rev-new"},
                                 "ownerReferences": [{"kind": "StatefulSet", "name": "openbao"}]}}]})
if line.startswith("get externalsecret -n sadp-apps -o json"):
    out({"items": [{"metadata": {"name": "portal-lite-auth"}}]})
if line.startswith("get externalsecret -n sadp-apps portal-lite-auth"):
    ready = scenario != "token-missing"
    out({"metadata": {"name": "portal-lite-auth"}, "spec": {"secretStoreRef": {"name": "openbao"}},
         "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}})
if line.startswith("get events"):
    items = [{"message": 'cannot find secret data for key: "FORGEJO_BOT_TOKEN"'}] if scenario == "token-missing" else []
    out({"items": items})
if line.startswith("get secretstore"):
    out({"status": {"conditions": [{"type": "Ready", "status": "True"}]}})
if line.startswith("get gateway"):
    out({"status": {"conditions": [{"type": "Programmed", "status": "True"}]}})
if line.startswith("get deployment -n envoy-gateway-system -l"):
    print("deployment.apps/envoy-sadp"); sys.exit(0)
if line.startswith("get deployment -n envoy-gateway-system envoy-sadp"):
    out({"metadata": {"name": "envoy-sadp"}, "spec": {"replicas": 1, "selector": {"matchLabels": {"app": "envoy"}}},
         "status": {"availableReplicas": 1, "updatedReplicas": 0 if scenario == "envoy-pending" else 1}})
if line.startswith("get pods -n envoy-gateway-system"):
    if scenario == "envoy-pending":
        out({"items": [{"metadata": {"name": "envoy-new"}, "status": {"phase": "Pending", "conditions": [{
            "type": "PodScheduled", "status": "False",
            "message": "0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: true}"}]}}]})
    out({"items": []})
if line.startswith("get securitypolicy -n sadp-apps secure-demo-oidc"):
    accepted = scenario != "no-route"
    out({"metadata": {"name": "secure-demo-oidc"}, "status": {"ancestors": [{"conditions": [{
        "type": "Accepted", "status": "True" if accepted else "False",
        "message": "ok" if accepted else 'OIDC: Get "https://idp.example.invalid/x": dial tcp 203.0.113.5:443: connect: no route to host'}]}]}})
if line.startswith("get deployment -n sadp-apps portal-lite"):
    out({"metadata": {"name": "portal-lite"}, "spec": {"replicas": 1, "selector": {"matchLabels": {"app": "portal"}}},
         "status": {"availableReplicas": 1, "updatedReplicas": 1}})
if line.startswith("get pods -n sadp-apps"):
    out({"items": []})
if line.startswith("logs -n sadp-apps deploy/portal-lite"):
    if scenario == "portal-fetch":
        print("[auth][error] TypeError: fetch failed UND_ERR_CONNECT_TIMEOUT idp.example.invalid:443")
    sys.exit(0)
print("unexpected kubectl: " + line, file=sys.stderr)
sys.exit(97)
'''

with tempfile.TemporaryDirectory(prefix="doctor-test-") as raw:
    work = pathlib.Path(raw)
    bin_dir = work / "bin"
    bin_dir.mkdir()
    (bin_dir / "kubectl").write_text(FAKE_KUBECTL)
    (bin_dir / "kubectl").chmod(0o755)
    # 이 호스트를 Squid egress 호스트가 아닌 것으로 보이게 하고 route 조회는 성공시킨다.
    (bin_dir / "ip").write_text("#!/usr/bin/env bash\nif [[ $1 == -4 && $2 == route ]]; then echo ok; exit 0; fi\n"
                                "echo '2: eth0    inet 192.0.2.99/24'\n")
    (bin_dir / "ip").chmod(0o755)
    kubeconfig = work / "kubeconfig"
    kubeconfig.write_text("fixture\n")

    def doctor(scenario: str, *arguments: str) -> tuple[subprocess.CompletedProcess, str]:
        log = work / f"{scenario}.log"
        log.unlink(missing_ok=True)
        environment = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                           KUBECTL_BIN=str(bin_dir / "kubectl"), KUBECONFIG_PATH=str(kubeconfig),
                           DOCTOR_SCENARIO=scenario, DOCTOR_LOG=str(log))
        result = subprocess.run(["bash", "./sadp", "--doctor", *arguments], cwd=ROOT, env=environment,
                                capture_output=True, text=True, check=False)
        return result, log.read_text() if log.exists() else ""

    env_args = ("--env-file", "environments/site.env.example")
    result, calls = doctor("healthy", *env_args)
    output = result.stdout + result.stderr
    check("DR-01 정상 클러스터에서 거짓 경보 없이 8단계 통과",
          result.returncode == 0 and "모든 단계 정상" in output and "[FAIL]" not in output
          and "[NEXT]" not in output and "[STAGE 8/8]" in output, output)
    check("DR-02 doctor는 읽기 전용 kubectl 호출만 사용",
          not any(line.split()[0] in {"apply", "delete", "annotate", "patch", "rollout", "create", "scale"}
                  for line in calls.splitlines() if line), calls)
    result, calls = doctor("sealed", *env_args)
    output = result.stdout + result.stderr
    check("DR-03 OpenBao sealed면 5단계에서 멈추고 unseal을 안내, 뒤 단계(ESO)는 보지 않음",
          result.returncode == 1 and "처음 막힌 단계: 5/8" in output and "--unseal-openbao" in output
          and "externalsecret" not in calls, output)
    result, _ = doctor("token-missing", *env_args)
    output = result.stdout + result.stderr
    check("DR-04 Forgejo token 미주입은 6단계에서 key 이름과 --token-only 명령",
          result.returncode == 1 and "처음 막힌 단계: 6/8" in output and "FORGEJO_BOT_TOKEN" in output
          and "--token-only" in output, output)
    result, _ = doctor("envoy-pending", *env_args)
    output = result.stdout + result.stderr
    check("DR-05 새 Envoy Pod가 taint로 Pending이면 7단계에서 rollout 정지와 toleration 안내",
          result.returncode == 1 and "처음 막힌 단계: 7/8" in output and "rollout이 멈춤" in output, output)
    result, _ = doctor("no-route", *env_args)
    output = result.stdout + result.stderr
    check("DR-06 SecurityPolicy no route to host는 7단계에서 relay 안내(URL/IP 비노출)",
          result.returncode == 1 and "처음 막힌 단계: 7/8" in output and "IDP_RELAY_ENABLED=true" in output
          and not leaked(output), output)
    result, _ = doctor("portal-fetch", *env_args)
    output = result.stdout + result.stderr
    check("DR-07 Portal fetch 실패는 8단계에서 relay 안내, 로그 원문 비노출",
          result.returncode == 1 and "처음 막힌 단계: 8/8" in output and "fetch-failed" in output
          and not leaked(output), output)
    result, _ = doctor("inotify-low", *env_args)
    output = result.stdout + result.stderr
    check("DR-09 worker inotify 한도 부족은 4단계에서 노드 이름과 node phase 명령",
          result.returncode == 1 and "처음 막힌 단계: 4/8" in output
          and "sadp-worker-1: fs.inotify.max_user_instances=128" in output
          and "--install-node-sysctl" in output, output)
    healthy_err = doctor("healthy", *env_args)[0].stderr
    check("DR-10 정상 클러스터에서 노드 inotify 값을 모두 읽어 inotify [WARN]이 없음",
          not any("[WARN]" in line and "inotify" in line for line in healthy_err.splitlines()), healthy_err)
    check("DR-11 IdP 이름을 해석하지 못하면 route를 확인했다고 말하지 않음",
          "route 판정을 생략함" in healthy_err + doctor("healthy", *env_args)[0].stdout
          and "외부 IdP route 확인" not in doctor("healthy", *env_args)[0].stdout)
    result, calls = doctor("healthy")
    output = result.stdout + result.stderr
    check("DR-08 --env-file이 없으면 1단계에서 두 후보 경로를 안내하고 클러스터를 묻지 않음",
          result.returncode == 1 and "처음 막힌 단계: 1/8" in output and "/etc/sadp/site.env" in output
          and "environments/site.env" in output and not calls, output)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
