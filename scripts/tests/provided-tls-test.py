#!/usr/bin/env python3
"""Certbot 링크를 직접 읽되 대상 개인키의 보호 조건은 유지한다."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/cluster/install-testbed-platform.sh').read_text()


def function(name):
    body = SOURCE.split(name + '() {', 1)[1].split('\n}', 1)[0]
    return name + '() {' + body + '\n}'


class ProvidedTLS(unittest.TestCase):
    def test_certbot_paths_and_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive = root / 'archive'
            live = root / 'live'
            archive.mkdir()
            live.mkdir()
            cert, key = archive / 'fullchain1.pem', archive / 'privkey1.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-days', '30', '-subj', '/CN=example.invalid', '-addext',
                            'subjectAltName=DNS:example.invalid,DNS:*.example.invalid',
                            '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
            key.chmod(0o600)
            (live / 'fullchain.pem').symlink_to('../archive/fullchain1.pem')
            (live / 'privkey.pem').symlink_to('../archive/privkey1.pem')
            env = dict(os.environ, TESTBED_ROOT=str(root), BASE_DOMAIN='example.invalid',
                       CERT_FILE=str(live / 'fullchain.pem'), KEY_FILE=str(live / 'privkey.pem'))
            script = ('set -euo pipefail\ndie() { echo "$*" >&2; exit 1; }\nok() { :; }\n'
                      + function('resolve_tls_path') + '\n' + function('validate_wildcard_files')
                      + '\nvalidate_wildcard_files\n')
            def run(extra=''):
                return subprocess.run(['bash', '-c', script + extra], env=env, capture_output=True, text=True)
            result = run('resolve_tls_path "$CERT_FILE"\nresolve_tls_path wildcard/fullchain.pem\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [env['CERT_FILE'], str(root / 'wildcard/fullchain.pem')])
            key.chmod(0o644)
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('권한이 너무 넓음', result.stderr)
            key.chmod(0o600)
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-out', str(key),
                            '-pkeyopt', 'rsa_keygen_bits:2048'], check=True, capture_output=True)
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('일치하지 않음', result.stderr)
            key.unlink()
            self.assertNotEqual(run().returncode, 0)


if __name__ == '__main__':
    unittest.main()
