#!/usr/bin/env python3
"""외부망 보호를 유지하면서 내부망 전용 worker만 외부 NIC 요구를 생략한다."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('nic_preflight', ROOT / 'scripts/lib/node-interface-preflight.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def device(name, address):
    return {'ifname': name, 'addr_info': [{'local': address}]}


class NICPreflightTest(unittest.TestCase):
    def setUp(self):
        self.devices = [device('lo', '127.0.0.1'), device('eth0', '198.18.0.4'),
                        device('flannel.1', '10.44.1.0'), device('cali-fixture', 'fe80::1')]
        self.routes = [{'dev': 'eth0'}]

    def validate(self, internal_only=True, guarded=()):
        mod.validate(self.devices, self.routes, 'eth0', 'eth1', '198.18.0.4', guarded, internal_only)

    def test_internal_only_accepts_private_overlay_and_internal_default_route(self):
        self.validate()
        self.routes = []
        self.validate()

    def test_contract_internal_ipv4_is_not_assumed_to_be_rfc1918(self):
        devices = [device('eth0', '11.0.0.4')]
        mod.validate(devices, [], 'eth0', 'eth1', '11.0.0.4', [], True)

    def test_external_role_still_requires_nic_and_default_route(self):
        with self.assertRaises(ValueError):
            self.validate(False)
        self.devices.append(device('eth1', '198.18.0.1'))
        with self.assertRaises(ValueError):
            self.validate(False)
        self.routes = [{'dev': 'eth1'}]
        self.validate(False)

    def test_internal_only_never_skips_existing_external_or_guarded(self):
        self.devices.append(device('eth1', '10.0.0.1'))
        with self.assertRaises(ValueError):
            self.validate()
        self.devices[-1]['ifname'] = 'eth2'
        with self.assertRaises(ValueError):
            self.validate(guarded=['eth2'])

    def test_wrong_internal_ip_and_default_interface_rejected(self):
        self.routes = [{'dev': 'eth2'}]
        with self.assertRaises(ValueError):
            self.validate()
        self.routes = []
        self.devices[1] = device('eth0', '198.18.0.5')
        with self.assertRaises(ValueError):
            self.validate()

    def test_unprotected_global_ipv4_or_ipv6_rejected(self):
        for name, address in [('eth2', '9.9.9.9'), ('eth2', '2001:4860::1'), ('eth0', '2001:4860::1')]:
            with self.subTest(name=name, address=address):
                extra = device(name, address)
                if name == 'eth0':
                    extra['addr_info'].append({'local': '198.18.0.4'})
                with self.assertRaises(ValueError):
                    mod.validate(self.devices + [extra], self.routes, 'eth0', 'eth1', '198.18.0.4', [], True)

    def test_node_flow_checks_before_changes_and_skips_worker_guard_only(self):
        source = (ROOT / 'scripts/install/sadp-install.sh').read_text()
        block = source.split('if [[ ${PHASE} == node || ${PHASE} == all ]]; then', 1)[1]
        block = 'if true; then' + block.split('if [[ ${PHASE} == node ]]; then', 1)[0]
        environment = dict(os.environ, NODE_NAME='worker', NODE_IP='198.18.0.4', SQUID_INTERNAL_IP='198.18.0.2',
                           INTERNAL_INTERFACE='eth0', EXTERNAL_INTERFACE='eth1', GUARDED_INTERFACES='',
                           SERVICE_CIDR='10.43.0.0/16', RKE2_SERVER_ENDPOINT='198.18.0.2',
                           INTERNAL_ALLOWED_TCP_PORTS='9345,6443', CLUSTER_UPSTREAM_DNS='', APPLY='true',
                           WORKER_INTERNAL_ONLY='true', BASH_ENV='')
        prefix = "set -euo pipefail\nnote() { :; }\ndie() { exit 1; }\nstep() { printf '%s\\n' \"$*\"; }\n"
        for role in ('agent', 'server'):
            result = subprocess.run(['bash', '--noprofile', '--norc', '-c', prefix + block],
                                    env=dict(environment, NODE_ROLE=role), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertIn('node-interface-preflight.py', lines[0])
            identity = next(line for line in lines if 'install-rke2-network-identity.sh' in line)
            self.assertEqual('--external-interface eth1' in identity, role == 'server')
            self.assertEqual('install-rke2-interface-guard.sh' in result.stdout, role == 'server')
        fail_prefix = prefix + 'step() { echo "$*"; return 1; }\n'
        failed = subprocess.run(['bash', '--noprofile', '--norc', '-c', fail_prefix + block],
                                env=dict(environment, NODE_ROLE='agent'), capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertNotIn('install-rke2-node-config.sh', failed.stdout)


if __name__ == '__main__':
    unittest.main()
