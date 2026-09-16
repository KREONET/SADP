#!/usr/bin/env python3
"""controller와 별개인 webhook 준비 지연을 실제 설치 함수로 검증합니다."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/cluster/install-testbed-platform.sh').read_text()
FUNCTION = 'wait_cert_manager_api() {' + SOURCE.split('wait_cert_manager_api() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'


class CertManagerReadyTest(unittest.TestCase):
    def test_admission_readiness(self):
        for scenario, expected_calls, success in [('startup', 3, True), ('unavailable', 30, False),
                                                  ('invalid', 1, False), ('pod-failed', 0, False)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                path = Path(temp)
                (path / 'count').write_text('0')
                mock = r'''
note() { echo "$*"; }
ok() { echo "$*"; }
die() { echo "$*" >&2; exit 1; }
sleep() { :; }
kctl() {
  printf '%s\n' "$*" >>"$CASE_ROOT/calls"
  if [[ $1 == rollout ]]; then [[ $SCENARIO != pod-failed ]]; return; fi
  [[ "$*" == 'apply --dry-run=server --request-timeout=10s -f platform/exposure/internal-ca.yaml' ]] || exit 99
  count=$(<"$CASE_ROOT/count")
  printf '%s\n' "$((count+1))" >"$CASE_ROOT/count"
  case "$SCENARIO" in
    invalid) echo 'invalid manifest'; return 1 ;;
    startup) ((count < 2)) || return 0 ;;
  esac
  echo 'failed calling webhook: no endpoints available for service cert-manager-webhook'
  return 1
}
'''
                result = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + mock + FUNCTION + 'wait_cert_manager_api'],
                                        env=dict(os.environ, CASE_ROOT=temp, SCENARIO=scenario), capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                self.assertEqual(int((path / 'count').read_text()), expected_calls)
                calls = (path / 'calls').read_text().splitlines()
                self.assertIn('deployment/cert-manager-webhook', calls[0])
                if scenario != 'pod-failed':
                    self.assertIn('deployment/cert-manager-cainjector', calls[1])
                if scenario == 'unavailable':
                    self.assertIn('준비 timeout', result.stderr)

    def test_gate_precedes_certificate_operations(self):
        gate = SOURCE.index('\nwait_cert_manager_api\n')
        self.assertLess(gate, SOURCE.index('bash scripts/cluster/preflight-cert-manager-dns01.sh'))
        self.assertLess(gate, SOURCE.index('kctl apply -f platform/exposure/internal-ca.yaml'))


if __name__ == '__main__':
    unittest.main()
