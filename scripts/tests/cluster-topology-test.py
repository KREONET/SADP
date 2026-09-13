#!/usr/bin/env python3
"""single·1+N 설치와 빌드 선택에서 노드 누락이나 역할 우회가 통과하지 않게 한다."""
from __future__ import annotations

import copy
import importlib.util
import pathlib
import os
import json
import shutil
import subprocess
import tempfile

import yaml
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("cluster_topology", ROOT / "scripts/lib/cluster-topology.py")
topology = importlib.util.module_from_spec(spec)
spec.loader.exec_module(topology)


def node(name: str, *, server: bool = False, memory: str = "8Gi") -> dict:
    return {"metadata": {"name": name, "labels": {
        "kubernetes.io/os": "linux", **({topology.SERVER_LABELS[0]: ""} if server else {})}},
        "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "True"}],
                                 "allocatable": {"memory": memory}}}


class TopologyTest(unittest.TestCase):
    def test_supported_sizes_and_contract_counts(self):
        for count in (1, 2, 3, 8):
            with self.subTest(count=count):
                contract = {"spec": {"network": {"nodeAddresses": [f"10.20.30.{i+1}" for i in range(count)]}}}
                expected = topology.expected_nodes(contract)
                nodes = [node("server", server=True)] + [node(f"worker-{i}") for i in range(count-1)]
                topology.validate_nodes(nodes, expected)
                with self.assertRaises(ValueError):
                    topology.validate_nodes(nodes[:-1], expected)
                with self.assertRaises(ValueError):
                    topology.validate_nodes(nodes + [node("unexpected")], expected)

    def test_invalid_contracts(self):
        for addresses in (None, [], ["10.0.0.1", "10.0.0.1"], ["bad"], ["::1"]):
            with self.subTest(addresses=addresses), self.assertRaises(ValueError):
                topology.expected_nodes({"spec": {"network": {"nodeAddresses": addresses}}})

    def test_server_labels_include_empty_values_and_legacy_master(self):
        cp = node("cp", server=True)
        cp["metadata"]["labels"] = {topology.SERVER_LABELS[1]: ""}
        topology.validate_nodes([cp], 1)
        for nodes in ([node("worker")], [cp, node("another-cp", server=True)]):
            with self.assertRaises(ValueError):
                topology.validate_nodes(nodes, len(nodes))

    def test_readiness_and_single_scheduling(self):
        cp = node("cp", server=True)
        cp["status"]["conditions"][0]["status"] = "False"
        with self.assertRaises(ValueError):
            topology.validate_nodes([cp], 1)
        topology.validate_nodes([cp], 1, allow_not_ready=True)
        cp = node("cp", server=True)
        for spec in ({"unschedulable": True}, {"taints": [{"effect": "NoSchedule"}]},
                     {"taints": [{"effect": "NoExecute"}]}):
            cp["spec"] = spec
            with self.assertRaises(ValueError):
                topology.validate_nodes([cp], 1)
            topology.validate_nodes([cp], 1, allow_unschedulable=True)

    def test_builder_single_and_multi(self):
        cp = node("cp", server=True, memory="64Gi")
        self.assertEqual(topology.select_builder([cp], 1), "cp")
        nodes = [cp, node("small", memory="8192Mi"), node("large", memory="16Gi")]
        self.assertEqual(topology.select_builder(nodes, 3), "large")
        self.assertEqual(topology.select_builder(nodes, 3, "small"), "small")
        for name in ("cp", "unknown"):
            with self.assertRaises(ValueError):
                topology.select_builder(nodes, 3, name)
        nodes[2]["spec"]["unschedulable"] = True
        self.assertEqual(topology.select_builder(nodes, 3), "small")
        nodes[1]["status"]["conditions"][0]["status"] = "False"
        with self.assertRaises(ValueError):
            topology.select_builder(nodes, 3)
        cp["metadata"]["labels"] = {topology.SERVER_LABELS[1]: ""}
        with self.assertRaises(ValueError):
            topology.select_builder([cp, node("worker")], 2, "cp")

    def test_shutdown_relaxes_health_but_keeps_membership_and_roles(self):
        nodes = [node("cp", server=True), node("worker")]
        nodes[1]["spec"]["unschedulable"] = True
        nodes[1]["status"]["conditions"][0]["status"] = "False"
        topology.validate_nodes(nodes, 2, allow_not_ready=True, allow_unschedulable=True)
        with self.assertRaises(ValueError):
            topology.validate_nodes(nodes[:1], 2, allow_not_ready=True, allow_unschedulable=True)
        invalid = copy.deepcopy(nodes)
        invalid[1]["metadata"]["labels"][topology.SERVER_LABELS[0]] = ""
        with self.assertRaises(ValueError):
            topology.validate_nodes(invalid, 2, allow_not_ready=True, allow_unschedulable=True)


class PowerTopologyTest(unittest.TestCase):
    def test_prepare_off_and_resume_for_single_and_variable_workers(self):
        # 실제 host/클러스터에 닿지 않는 복사본에서 worker 0·1·4대의 루프와 중지 경계를 확인한다.
        for count in (1, 2, 5):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as temporary:
                work = pathlib.Path(temporary)
                for relative in ("scripts/ops/manage-power.sh", "scripts/lib/testbed-common.sh",
                                 "scripts/lib/cluster-topology.py", "VERSION"):
                    destination = work / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / relative, destination)
                (work / "contracts").mkdir()
                (work / "contracts/platform-production.yaml").write_text(yaml.safe_dump({
                    "spec": {"network": {"nodeAddresses": [f"10.20.30.{i+1}" for i in range(count)]}}}))
                bindir = work / "bin"
                bindir.mkdir()
                fake = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['POWER_TEST_ROOT'])
with (root / 'commands').open('a') as stream:
    stream.write(name + ' ' + ' '.join(args) + '\n')
if name == 'id':
    print('0')
elif name == 'systemctl':
    if args[0] == 'stop':
        (root / 'stopped').touch()
    elif args[0] == 'is-active' and (root / 'stopped').exists():
        sys.exit(3)
elif name == 'rke2':
    directory = pathlib.Path(args[args.index('--dir')+1])
    (directory / 'sadp-poweroff-test').write_text('snapshot')
elif name == 'kubectl' and 'get' in args and 'nodes' in args:
    nodes = json.loads((root / 'nodes.json').read_text())
    if '-l' in args:
        nodes = [node for node in nodes if 'node-role.kubernetes.io/control-plane' not in node['metadata']['labels']]
    if 'json' in args:
        print(json.dumps({'items': nodes}))
    else:
        for node in nodes:
            print(node['metadata']['name'])
"""
                for name in ("kubectl", "id", "systemctl", "rke2"):
                    target = bindir / name
                    target.write_text(fake)
                    target.chmod(0o755)
                (work / "scripts/ops/backup-testbed.sh").write_text("#!/usr/bin/env bash\nset -euo pipefail\n")
                backup = work / "state/backups/seed"
                backup.mkdir(parents=True)
                (backup.parent / "latest").symlink_to(backup)
                nodes = [node("cp", server=True)] + [node(f"worker-{i}") for i in range(count-1)]
                nodefile = work / "nodes.json"
                nodefile.write_text(json.dumps(nodes))
                env = {**os.environ, "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
                       "POWER_TEST_ROOT": str(work), "SADP_STATE_DIR": str(work / "state"),
                       "KUBECTL_BIN": str(bindir / "kubectl"), "SADP_RKE2_BIN": str(bindir / "rke2")}

                def run(action):
                    return subprocess.run(["bash", "scripts/ops/manage-power.sh", action,
                                           "--role", "server", "--apply"], cwd=work, env=env,
                                          capture_output=True, text=True)

                prepared = run("prepare-off")
                self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
                commands = (work / "commands").read_text()
                self.assertEqual(commands.count(" drain worker-"), count - 1)
                self.assertNotIn(" drain cp", commands)
                marker = work / "state/power/prepared-off"
                self.assertTrue(marker.exists())
                if count > 1:
                    refused = run("off")
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertFalse((work / "stopped").exists())
                for item in nodes[1:]:
                    item["spec"]["unschedulable"] = True
                    item["status"]["conditions"][0]["status"] = "False"
                nodefile.write_text(json.dumps(nodes))
                stopped = run("off")
                self.assertEqual(stopped.returncode, 0, stopped.stdout + stopped.stderr)
                commands = (work / "commands").read_text()
                self.assertLess(commands.index("rke2 etcd-snapshot save"), commands.index("systemctl stop"))
                (work / "stopped").unlink()
                for item in nodes:
                    item["status"]["conditions"][0]["status"] = "True"
                nodefile.write_text(json.dumps(nodes))
                resumed = run("resume")
                self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
                self.assertFalse(marker.exists())
                self.assertEqual((work / "commands").read_text().count(" uncordon worker-"), count - 1)


if __name__ == "__main__":
    unittest.main()
