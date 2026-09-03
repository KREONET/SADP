#!/usr/bin/env python3
"""중앙 proxy 수렴과 실제 CRI pull preflight 회귀."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
MANAGER = ROOT / "scripts/cluster/manage-rke2-containerd-proxy.sh"
PREFLIGHT = ROOT / "scripts/cluster/preflight.sh"
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


nodes = {
    "items": [
        {
            "metadata": {
                "name": "control-1",
                "labels": {"node-role.kubernetes.io/control-plane": "true"},
            },
            "status": {"nodeInfo": {"operatingSystem": "linux"}},
        },
        {
            "metadata": {"name": "worker-2", "labels": {}},
            "status": {"nodeInfo": {"operatingSystem": "linux"}},
        },
        {
            "metadata": {"name": "worker-1", "labels": {}},
            "status": {"nodeInfo": {"operatingSystem": "linux"}},
        },
    ]
}
pods = {
    "items": [
        {
            "metadata": {"name": f"rke2-canal-{index}"},
            "spec": {
                "nodeName": node,
                "containers": [
                    {"name": "calico-node", "image": "example.invalid/calico-node:v1"}
                ],
            },
            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
        }
        for index, node in enumerate(("control-1", "worker-1", "worker-2"), 1)
    ]
}
failed_pull_pods = {
    "items": [
        {
            "metadata": {"name": "cri-image-pull-fixture"},
            "spec": {"nodeName": "worker-2"},
            "status": {
                "phase": "Pending",
                "containerStatuses": [
                    {
                        "state": {
                            "waiting": {
                                "reason": "ImagePullBackOff",
                                "message": "lookup registry fixture",
                            }
                        }
                    }
                ],
            },
        }
    ]
}


with tempfile.TemporaryDirectory(prefix="sadp-cluster-proxy-test-") as temporary:
    work = pathlib.Path(temporary)
    bin_dir = work / "bin"
    bin_dir.mkdir()
    nodes_path = work / "nodes.json"
    pods_path = work / "pods.json"
    failed_pods_path = work / "failed-pods.json"
    nodes_path.write_text(json.dumps(nodes), encoding="utf-8")
    pods_path.write_text(json.dumps(pods), encoding="utf-8")
    failed_pods_path.write_text(json.dumps(failed_pull_pods), encoding="utf-8")
    fake_id = bin_dir / "id"
    fake_id.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ ${1:-} == -u ]]; then echo 0; else /usr/bin/id \"$@\"; fi\n",
        encoding="utf-8",
    )
    fake_id.chmod(0o755)
    fake_kubectl = bin_dir / "kubectl"
    fake_kubectl.write_text(
        r'''#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --kubeconfig ]]; then shift 2; fi
if [[ ${1:-} == -n ]]; then shift 2; fi
printf '%s\n' "$*" >>"${FAKE_LOG}"
case "$*" in
  "get nodes -o json") exec /bin/cat "${FAKE_NODES}" ;;
  "get pods -n kube-system -o json") exec /bin/cat "${FAKE_PODS}" ;;
  exec*) exit 0 ;;
  "create namespace "*) exit 0 ;;
  "create configmap "*)
    [[ ${FAKE_MODE:-success} != create-fail ]] || exit 1
    printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: fixture}'
    ;;
  "apply -f -")
    /bin/cat >>"${FAKE_STDIN_CAPTURE}"
    ;;
  "apply -f "*)
    /bin/cp "${3}" "${FAKE_MANIFEST_CAPTURE}"
    ;;
  "rollout status "*)
    case ${FAKE_MODE:-success} in
      rollout-fail|pull-fail) exit 1 ;;
      signal) kill -TERM "$PPID"; exit 130 ;;
      *) exit 0 ;;
    esac
    ;;
  "get pods -n sadp-preflight-"*) exec /bin/cat "${FAKE_FAILED_PODS}" ;;
  "get pod -n kube-system "*) printf '%s\n' 'fixture diagnostics' ;;
  delete*) exit 0 ;;
  *) exit 0 ;;
esac
''',
        encoding="utf-8",
    )
    fake_kubectl.chmod(0o755)
    log = work / "kubectl.log"
    stdin_capture = work / "stdin.yaml"
    manifest_capture = work / "manager.yaml"
    base_env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "KUBECTL_BIN": str(fake_kubectl),
        "KUBECONFIG_PATH": str(work / "kubeconfig"),
        "FAKE_NODES": str(nodes_path),
        "FAKE_PODS": str(pods_path),
        "FAKE_FAILED_PODS": str(failed_pods_path),
        "FAKE_LOG": str(log),
        "FAKE_STDIN_CAPTURE": str(stdin_capture),
        "FAKE_MANIFEST_CAPTURE": str(manifest_capture),
    }

    result = subprocess.run(
        ["bash", str(MANAGER)], cwd=ROOT, env=base_env, text=True, capture_output=True
    )
    plan_log = log.read_text(encoding="utf-8")
    check(
        result.returncode == 0
        and "create configmap" not in plan_log
        and "apply -f" not in plan_log,
        "중앙 plan은 image/tool/node를 검사하지만 리소스를 만들지 않음",
    )
    output = result.stdout + result.stderr
    positions = [
        output.find("drain worker-1"),
        output.find("drain worker-2"),
        output.find("drain control-1"),
    ]
    check(
        positions == sorted(positions) and min(positions) >= 0,
        "수동 재시작 명령은 worker 한 대씩 처리하고 server를 마지막에 둠",
    )

    for mode, expect_success in (("success", True), ("rollout-fail", False), ("create-fail", False), ("signal", False)):
        log.write_text("", encoding="utf-8")
        stdin_capture.write_text("", encoding="utf-8")
        env = {**base_env, "FAKE_MODE": mode}
        result = subprocess.run(
            ["bash", str(MANAGER), "--apply"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
        )
        cleanup_log = log.read_text(encoding="utf-8")
        check(
            (result.returncode == 0) == expect_success
            and "delete daemonset" in cleanup_log
            and "delete configmap" in cleanup_log,
            f"중앙 {mode} 경로에서 임시 DaemonSet/ConfigMap cleanup",
        )

    log.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(MANAGER), "--check"],
        cwd=ROOT,
        env={**base_env, "FAKE_MODE": "success"},
        text=True,
        capture_output=True,
    )
    check(
        result.returncode == 0
        and "--check" in manifest_capture.read_text(encoding="utf-8")
        and "delete daemonset" in log.read_text(encoding="utf-8")
        and "delete configmap" in log.read_text(encoding="utf-8"),
        "중앙 check도 모든 노드 실행 환경을 검사하고 임시 리소스를 cleanup",
    )

    manager_manifest = manifest_capture.read_text(encoding="utf-8")
    check(
        all(
            marker in manager_manifest
            for marker in (
                "hostNetwork: true",
                "hostPID: true",
                "automountServiceAccountToken: false",
                "privileged: true",
                "imagePullPolicy: IfNotPresent",
                "${NODE_NAME}",
            )
        ),
        "중앙 manifest는 짧은 privileged host 접근과 Pod 시점 변수 escape를 유지",
    )

    log.write_text("", encoding="utf-8")
    stdin_capture.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(PREFLIGHT), "--image-pull-only"],
        cwd=ROOT,
        env={**base_env, "FAKE_MODE": "success"},
        text=True,
        capture_output=True,
    )
    preflight_manifest = stdin_capture.read_text(encoding="utf-8")
    check(
        result.returncode == 0
        and "StorageClass" not in result.stdout
        and all(
            marker in preflight_manifest
            for marker in (
                "@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a",
                "imagePullPolicy: Always",
                "hostNetwork: true",
                "kubernetes.io/os: linux",
                "tolerations: [{operator: Exists}]",
            )
        ),
        "image-pull-only는 topology/StorageClass 없이 모든 Linux node 실제 CRI pull만 검사",
    )

    log.write_text("", encoding="utf-8")
    stdin_capture.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(PREFLIGHT), "--image-pull-only"],
        cwd=ROOT,
        env={**base_env, "FAKE_MODE": "pull-fail"},
        text=True,
        capture_output=True,
    )
    failure_output = result.stdout + result.stderr
    check(
        result.returncode != 0
        and all(
            marker in failure_output
            for marker in (
                "worker-2",
                "cri-image-pull-fixture",
                "Pending",
                "ImagePullBackOff",
                "lookup registry fixture",
                "--manage-containerd-proxy --apply",
                "--manage-containerd-proxy --check",
                "--preflight --image-pull-only",
            )
        )
        and "Pod log" in failure_output,
        "CRI pull 실패는 node/pod/phase/reason/message와 정확한 복구 명령만 출력",
    )

integrated = (ROOT / "scripts/install/sadp-install.sh").read_text(encoding="utf-8")
legacy = (ROOT / "scripts/cluster/bootstrap-testbed.sh").read_text(encoding="utf-8")
check(
    0 <= integrated.find("scripts/cluster/preflight.sh") < integrated.find("scripts/cluster/install-devtron.sh")
    and 0 <= legacy.find("preflight.sh --image-pull-only") < legacy.find("install-testbed-platform.sh"),
    "통합 installer와 레거시 bootstrap 모두 플랫폼 설치 전에 CRI pull preflight 실행",
)

print(f"통과 {passed} / 실패 {failed}")
raise SystemExit(1 if failed else 0)
