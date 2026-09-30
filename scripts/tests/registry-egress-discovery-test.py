#!/usr/bin/env python3
"""탐지 증거·상류 보존·reload 실패 복원을 외부 연결 없이 검사한다."""
import ast
import contextlib
import io
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import signal
import time
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("discovery", ROOT / "scripts/ops/discover-registry-egress.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
HOST = "asia-southeast1-docker.pkg.dev"
URL = "https://" + HOST + "/v2/k8s-artifacts-prod/images/pause/manifests/sha256:fixture"


class DiscoveryTests(unittest.TestCase):
    def test_preflight_digest_matches(self):
        self.assertIn("pause:3.10@" + m.DIGEST, (ROOT / "scripts/cluster/preflight.sh").read_text())

    def test_redirect_boundary(self):
        for host in (HOST, "registry.k8s.io", "cdn.registry.k8s.io", "storage.googleapis.com",
                     "prod-registry-k8s-io-eu-west-1.s3.dualstack.eu-west-1.amazonaws.com"):
            self.assertEqual(m.checked_host("https://" + host + "/path?redacted=value"), host)
        for url in ("http://" + HOST, "https://127.0.0.1/", "https://user:pass@" + HOST,
                    "https://" + HOST + ":444/", "https://" + HOST + ".evil.invalid/",
                    "https://arbitrary.pkg.dev/", "https://example.invalid/", "https://" + HOST + "/#fragment"):
            with self.subTest(url=url), self.assertRaises(m.DiscoveryError):
                m.checked_host(url)

    def test_no_network_request_before_redirect_validation(self):
        response = types.SimpleNamespace(status=302, headers={"Location": "http://127.0.0.1/"})
        class Response:
            status = response.status
            headers = response.headers
            def __enter__(self): return self
            def __exit__(self, *args): pass
        fetcher = m.Fetcher()
        with patch.object(fetcher.opener, "open", return_value=Response()) as request:
            with self.assertRaises(m.DiscoveryError):
                fetcher.get(m.BASE)
            self.assertEqual(request.call_count, 1)

    def test_index_digest_must_match(self):
        fetcher = types.SimpleNamespace(get=lambda url: b'{"manifests": []}')
        with self.assertRaisesRegex(m.DiscoveryError, "digest"):
            m.discover(fetcher, {"amd64"})

    def test_linux_manifest_and_layer_paths(self):
        body = json.dumps({"config": {"digest": "sha256:" + "a" * 64},
                           "layers": [{"digest": "sha256:" + "b" * 64}]}).encode()
        child_digest = "sha256:" + hashlib.sha256(body).hexdigest()
        index = json.dumps({"manifests": [
            {"platform": {"os": "linux", "architecture": "amd64"}, "digest": child_digest},
            {"platform": {"os": "windows", "architecture": "amd64"}, "digest": "sha256:" + "c" * 64},
            {"platform": {"os": "linux", "architecture": "arm64"}, "digest": "sha256:" + "d" * 64}]}).encode()
        index_digest = "sha256:" + hashlib.sha256(index).hexdigest()
        calls = []
        def get(url, blob=False):
            calls.append((url, blob))
            return b"x" if blob else (index if url.endswith(index_digest) else body)
        with patch.object(m, "DIGEST", index_digest):
            m.discover(types.SimpleNamespace(get=get, observed={}), {"amd64"})
        self.assertEqual(len(calls), 4)
        self.assertEqual(sum(blob for _, blob in calls), 2)
        self.assertFalse(any(url.endswith("c" * 64) or url.endswith("d" * 64) for url, _ in calls))


    def test_deadline_interrupts_blocking_wait_and_restores_handler(self):
        previous = signal.getsignal(signal.SIGALRM)
        started = time.monotonic()
        with self.assertRaisesRegex(m.DiscoveryError, "탐지 제한"):
            with m.discovery_deadline(0.05):
                time.sleep(2)
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(signal.getsignal(signal.SIGALRM), previous)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL)[0], 0)

    def test_cluster_architecture_selection_and_failure(self):
        nodes = {"items": [{"status": {"nodeInfo": {"operatingSystem": os_name, "architecture": arch}}}
                           for os_name, arch in (("linux", "amd64"), ("linux", "amd64"),
                                                 ("linux", "arm64"), ("windows", "386"))]}
        with patch.object(Path, "is_file", return_value=True), patch.object(m.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, stdout=json.dumps(nodes))
            self.assertEqual(m.select_architectures(None), {"amd64", "arm64"})
            self.assertIn("--request-timeout=8s", run.call_args.args[0])
            self.assertEqual(run.call_args.kwargs["timeout"], 10)
            run.return_value = subprocess.CompletedProcess([], 1, stdout="secret diagnostic")
            with self.assertRaises(m.DiscoveryError) as caught:
                m.select_architectures(None)
            self.assertNotIn("secret", str(caught.exception))
            run.side_effect = subprocess.TimeoutExpired("kubectl", 10)
            with self.assertRaisesRegex(m.DiscoveryError, "시간 초과"):
                m.select_architectures(None)

    def test_explicit_architectures_and_separate_squid_local_fallback(self):
        with patch.object(m.subprocess, "run") as run:
            self.assertEqual(m.select_architectures({"amd64", "arm64"}), {"amd64", "arm64"})
            run.assert_not_called()
        with patch.object(Path, "is_file", return_value=False), patch.object(m.platform, "machine", return_value="x86_64"):
            self.assertEqual(m.select_architectures(None), {"amd64"})
        for value in ("", "amd64,", "invalid"):
            with self.assertRaises(m.argparse.ArgumentTypeError):
                m.architecture_list(value)

    def test_missing_requested_architecture_is_not_silently_skipped(self):
        body = json.dumps({"manifests": [{"platform": {"os": "linux", "architecture": "amd64"},
                                         "digest": "sha256:" + "a" * 64}]}).encode()
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        with patch.object(m, "DIGEST", digest), self.assertRaisesRegex(m.DiscoveryError, "아키텍처"):
            m.discover(types.SimpleNamespace(get=lambda url: body), {"amd64", "arm64"})

    def test_domain_suffix_semantics(self):
        self.assertTrue(m.covered(HOST, [".pkg.dev"]))
        self.assertFalse(m.covered(HOST + ".invalid", [".pkg.dev"]))
        self.assertFalse(m.covered(HOST, ["pkg.dev"]))

    def probe_candidates(self, connect="403", fresh=True):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "access.log"
            entry = f"0 0 127.0.0.1 TCP_DENIED/403 0 CONNECT {HOST}:443 - HIER_NONE/- text/html\n"
            log.write_text(entry)
            def probe(*args):
                if fresh:
                    with log.open("a") as stream: stream.write(entry)
                return subprocess.CompletedProcess([], 56, stdout=f"{connect} 000")
            with patch.object(m, "proxy_probe", side_effect=probe), patch.object(m.time, "sleep"):
                return m.candidates({HOST: URL}, [], "http://proxy.invalid:3128", log)

    def test_requires_fresh_denial_and_connect_403(self):
        self.assertEqual(self.probe_candidates(), [HOST])
        for args in ({"fresh": False}, {"connect": "200"}, {"connect": "000"}):
            with self.subTest(args=args), self.assertRaises(m.DiscoveryError):
                self.probe_candidates(**args)

    def test_no_candidate_when_already_allowed(self):
        with patch.object(m, "proxy_probe") as probe:
            self.assertEqual(m.candidates({HOST: URL}, [HOST], "unused", Path("missing")), [])
            probe.assert_not_called()

    def test_log_rotation_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "access.log"
            log.write_text("old\n")
            def rotate(*args):
                log.rename(Path(temp) / "old.log")
                log.write_text("new\n")
                return subprocess.CompletedProcess([], 56, stdout="403 000")
            with patch.object(m, "proxy_probe", side_effect=rotate), self.assertRaisesRegex(m.DiscoveryError, "회전"):
                m.candidates({HOST: URL}, [], "unused", log)


    def test_post_reload_acl_retry_is_bounded(self):
        denied = subprocess.CompletedProcess([], 56, stdout="403 000")
        accepted = subprocess.CompletedProcess([], 0, stdout="200 200")
        with patch.object(m, "proxy_probe", side_effect=[denied, accepted]) as probe, patch.object(m.time, "sleep"):
            m.verify_proxy_paths({HOST: URL}, "unused", reloaded=True)
            self.assertEqual(probe.call_count, 2)
        with patch.object(m, "proxy_probe", return_value=denied) as probe, patch.object(m.time, "sleep"):
            with self.assertRaisesRegex(m.DiscoveryError, "CONNECT=403"):
                m.verify_proxy_paths({HOST: URL}, "unused", reloaded=True)
            self.assertEqual(probe.call_count, 3)
        with patch.object(m, "proxy_probe", return_value=denied) as probe:
            with self.assertRaises(m.DiscoveryError):
                m.verify_proxy_paths({HOST: URL}, "unused")
            self.assertEqual(probe.call_count, 1)

    def test_proxy_failure_reports_safe_fields_and_does_not_retry_tls_or_timeout(self):
        for code, reason in ((28, "시간 초과"), (60, "인증서")):
            result = subprocess.CompletedProcess([], code, stdout="200 000", stderr="signed-query-secret")
            with patch.object(m, "proxy_probe", return_value=result) as probe:
                with self.assertRaises(m.DiscoveryError) as caught:
                    m.verify_proxy_paths({HOST: URL + "?secret=value"}, "unused", reloaded=True)
                message = str(caught.exception)
                self.assertIn(HOST, message)
                self.assertIn(reason, message)
                self.assertIn(f"curl_exit={code}", message)
                self.assertIn("--preflight --image-pull-only", message)
                self.assertNotIn("secret", message)
                self.assertEqual(probe.call_count, 1)

    def test_origin_http_403_is_not_proxy_acl_denial(self):
        result = subprocess.CompletedProcess([], 0, stdout="200 403")
        with patch.object(m, "proxy_probe", return_value=result), contextlib.redirect_stdout(io.StringIO()) as output:
            m.verify_proxy_paths({HOST: URL}, "unused")
        self.assertIn("HTTP=403", output.getvalue())
        self.assertIn("CRI 성공과 별도", output.getvalue())

    def test_proxy_probe_ignores_curlrc_and_handles_process_timeout(self):
        with patch.object(m.subprocess, "run", side_effect=subprocess.TimeoutExpired("curl", 15)) as run:
            result = m.proxy_probe("http://proxy.invalid:3128", URL)
            self.assertEqual(run.call_args.args[0][:2], ["curl", "--disable"])
            self.assertEqual(result.returncode, 28)
            self.assertEqual(m.proxy_codes(result), ("000", "000"))
        self.assertEqual(m.proxy_codes(subprocess.CompletedProcess([], 0, stdout="unsafe-output")), ("000", "000"))

    def test_contract_preserves_existing_text(self):
        text = (ROOT / "contracts/platform-production.yaml").read_text()
        updated = m.append_domains(text, [HOST])
        self.assertEqual(updated.replace("      - " + HOST + "\n", ""), text)
        domains = yaml.safe_load(updated)["spec"]["network"]["squid"]["packageDomains"]
        self.assertEqual(domains[-1], HOST)

    def test_env_roundtrip_and_drift_rejection(self):
        # 기존 site 입력 fixture를 실행하지 않고 재사용해 상류 생성 로직을 실제로 검사한다.
        tree = ast.parse((ROOT / "scripts/tests/configure-site-test.py").read_text())
        fixture = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == "VALID" for target in node.targets))
        configure = m.module("discovery_test_configure", "scripts/site/configure-site.py")
        with tempfile.TemporaryDirectory() as temp:
            env = Path(temp) / "site.env"
            env.write_text(fixture)
            values = configure.parse_env(env)
            base = yaml.safe_load((ROOT / "contracts/platform-production.yaml").read_text())
            doc = configure.build_contract(base, configure.validate(values))
            contract = Path(temp) / "contract.yaml"
            contract.write_text(yaml.safe_dump(doc, sort_keys=False))
            updates = m.upstream_updates(contract, env, [HOST])
            self.assertEqual(env.read_text(), fixture)
            self.assertIn("EXTRA_PACKAGE_DOMAINS=packages.company.kr," + HOST, updates[env])
            env.write_text(updates[env])
            reproduced = configure.build_contract(doc, configure.validate(configure.parse_env(env)))
            self.assertEqual(reproduced, yaml.safe_load(updates[contract]))
            env.write_text(fixture.replace("CLUSTER_NAME=production", "CLUSTER_NAME=changed"))
            with self.assertRaisesRegex(m.DiscoveryError, "site.env와 계약"):
                m.upstream_updates(contract, env, [HOST])

    def test_reload_failure_restores_all_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            generated = root / "platform/network/squid/squid.conf"
            generated.parent.mkdir(parents=True)
            installed = root / "installed.conf"
            env = root / "site.env"
            for path in (generated, installed, env): path.write_text("before")
            calls = []
            def command(args):
                calls.append(args)
                if args == ["systemctl", "reload", "squid"] and calls.count(args) == 1:
                    raise m.DiscoveryError("reload failed")
            with patch.object(m, "ROOT", root), patch.object(m, "command", side_effect=command):
                with self.assertRaises(m.DiscoveryError):
                    m.apply_updates({generated: "after", env: "after"}, installed)
            for path in (generated, installed, env): self.assertEqual(path.read_text(), "before")
            self.assertEqual(calls.count(["systemctl", "reload", "squid"]), 2)
            self.assertFalse(any("restart" in call for call in calls))

    def test_parse_failure_changes_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            generated = root / "platform/network/squid/squid.conf"
            generated.parent.mkdir(parents=True)
            installed = root / "installed.conf"
            generated.write_text("before")
            installed.write_text("before")
            with patch.object(m, "ROOT", root), patch.object(m, "command", side_effect=m.DiscoveryError("parse")):
                with self.assertRaises(m.DiscoveryError):
                    m.apply_updates({generated: "after"}, installed)
            self.assertEqual(installed.read_text(), "before")
            self.assertEqual(generated.read_text(), "before")



    def test_stale_outputs_report_every_path_without_changing_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stale = root / "stale.yaml"
            missing = root / "missing.yaml"
            current = root / "current.yaml"
            stale.write_text("old-private-value")
            current.write_text("current")
            with patch.object(m, "ROOT", root):
                with self.assertRaises(m.DiscoveryError) as caught:
                    m.check_network_outputs({stale: "new-private-value", missing: "missing", current: "current"})
                message = str(caught.exception)
                self.assertIn("stale.yaml", message)
                self.assertIn("missing.yaml", message)
                self.assertNotIn("current.yaml", message)
                self.assertNotIn("private-value", message)
                self.assertIn("--render-network --check", message)
                self.assertEqual(stale.read_text(), "old-private-value")
                self.assertFalse(missing.exists())
                m.check_network_outputs({current: "current"})

    def test_plan_apply_and_idempotent_cri_check(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            contract = root / "contracts/platform-production.yaml"
            contract.parent.mkdir()
            contract.write_text((ROOT / "contracts/platform-production.yaml").read_text())
            generated = root / "platform/network/squid/squid.conf"
            generated.parent.mkdir(parents=True)
            def rendered(spec):
                return {generated: json.dumps(spec["network"]["squid"]["packageDomains"])}
            generated.write_text(rendered(yaml.safe_load(contract.read_text())["spec"])[generated])
            installed = root / "installed.conf"
            installed.write_text(generated.read_text())
            kubectl = root / "kubectl"
            kubeconfig = root / "kubeconfig"
            kubectl.touch()
            kubeconfig.touch()
            renderer = types.SimpleNamespace(rendered=rendered)
            initial = {p: p.read_bytes() for p in (contract, generated, installed)}
            def candidates(observed, domains, *args):
                return [] if HOST in domains else [HOST]
            with contextlib.ExitStack() as stack:
                for key, value in {"ROOT": root, "INSTALLED_SQUID": installed,
                                   "APPLY_LOCK": root / "apply.lock", "KUBECTL": kubectl,
                                   "KUBECONFIG": kubeconfig}.items():
                    stack.enter_context(patch.object(m, key, value))
                stack.enter_context(patch.object(m.os, "geteuid", return_value=0))
                stack.enter_context(patch.object(m, "module", return_value=renderer))
                stack.enter_context(patch.object(m, "select_architectures", return_value={"amd64"}))
                discovery = stack.enter_context(patch.object(m, "discover", return_value={HOST: URL}))
                stack.enter_context(patch.object(m, "candidates", side_effect=candidates))
                proxy = stack.enter_context(patch.object(m, "proxy_probe", return_value=subprocess.CompletedProcess([], 0, stdout="200 200")))
                cmd = stack.enter_context(patch.object(m, "command", return_value=subprocess.CompletedProcess([], 0, stdout="")))
                cri = stack.enter_context(patch.object(m.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)))
                output = io.StringIO()
                stack.enter_context(contextlib.redirect_stdout(output))
                stack.enter_context(contextlib.redirect_stderr(output))
                self.assertEqual(m.main([]), 0)
                self.assertFalse((root / "apply.lock").exists())
                discovery.side_effect = m.DiscoveryError("탐지 제한 1초 초과")
                self.assertEqual(m.main(["--apply", "--timeout", "1"]), 1)
                discovery.side_effect = None
                self.assertTrue(all(path.read_bytes() == value for path, value in initial.items()))
                cri.assert_not_called()
                cmd.return_value = subprocess.CompletedProcess([], 0, stdout=" M existing-change")
                self.assertEqual(m.main(["--apply"]), 1)
                self.assertTrue(all(path.read_bytes() == value for path, value in initial.items()))
                cri.assert_not_called()
                self.assertEqual(m.main(["--apply", "--allow-dirty"]), 0)
                cmd.return_value = subprocess.CompletedProcess([], 0, stdout="")
                self.assertIn(HOST, yaml.safe_load(contract.read_text())["spec"]["network"]["squid"]["packageDomains"])
                self.assertEqual(installed.read_text(), generated.read_text())
                self.assertIn("--image-pull-only", cri.call_args.args[0])
                count = cmd.call_count
                self.assertEqual(m.main(["--apply"]), 0)
                self.assertEqual(cmd.call_count, count + 1)  # active 확인만 하며 재작성/reload 없음
                self.assertEqual(cri.call_count, 2)
                proxy.return_value = subprocess.CompletedProcess([], 28, stdout="200 000")
                self.assertEqual(m.main(["--apply"]), 0)
                self.assertEqual(cri.call_count, 3)
                self.assertIn("보조 proxy 진단 경고", output.getvalue())
                with patch.object(m, "KUBECONFIG", root / "missing-kubeconfig"):
                    self.assertEqual(m.main(["--apply"]), 1)
                self.assertEqual(cri.call_count, 3)
                cri.return_value = subprocess.CompletedProcess([], 1)
                self.assertEqual(m.main(["--apply"]), 1)
                self.assertIn(HOST, contract.read_text())
                self.assertIn("CRI pull 실패", output.getvalue())


if __name__ == "__main__":
    unittest.main()
