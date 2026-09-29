#!/usr/bin/env python3
"""호스트를 바꾸지 않고 무인 설치의 중단·재시작·TLS 기록 경계를 검증한다."""
import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("install_all", ROOT / "scripts/install/sadp-install-all.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
EXAMPLE = (ROOT / "environments/site.env.example").read_text()


class Simulation(mod.Installer):
    def __init__(self, path):
        super().__init__(path)
        self.events = []
        self.fail_phase = False
        self.fail_drain = False
        self.cordoned = False
        self.bad_certificate = False

    def kctl(self, *args, **kwargs):
        self.events.append(args)
        if args[0] == "drain" and self.fail_drain:
            raise mod.InstallError("PDB rejected drain")
        if args[:2] == ("get", "node"):
            body = {"spec": {"unschedulable": self.cordoned}}
        elif args[:2] == ("get", "certificate"):
            tls = self.cfg["tls"]
            suffix = "-staging" if tls["issuerMode"] == "staging" else ""
            body = {"metadata": {"generation": 2},
                    "spec": {"issuerRef": {"name": tls["clusterIssuerName"] + suffix}},
                    "status": {"conditions": [{"type": "Ready", "status": "True",
                                                "observedGeneration": 1 if self.bad_certificate else 2}]}}
        else:
            body = {}
        return subprocess.CompletedProcess(args, 0, json.dumps(body).encode())

    def phase(self, phase, **kwargs):
        self.events.append((phase, self.cfg["tls"]["issuerMode"], self.cfg["tls"]["existingReady"]))
        if self.fail_phase:
            raise mod.InstallError("platform unavailable")

    def publish(self):
        self.events.append(("publish", self.cfg["tls"]["issuerMode"], self.cfg["tls"]["existingReady"]))

    def wait_node(self, name):
        self.events.append(("ready", name))


class InstallAllTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = Path(self.temp.name) / "site.env"
        self.env.write_text(EXAMPLE)
        self.installer = Simulation(self.env)

    def test_service_failure_names_only_known_unit_and_action(self):
        for unit in ("rke2-server", "docker"):
            for arguments, action in ((["is-active", "--quiet", unit], "실행 상태 확인"),
                                      (["restart", unit], "재시작")):
                with self.subTest(unit=unit, action=action), patch.object(mod.subprocess, "Popen") as process:
                    process.return_value.communicate.return_value = (b"", b"private-response-fixture")
                    process.return_value.returncode = 4
                    with self.assertRaises(mod.InstallError) as caught:
                        self.installer.run(["systemctl", *arguments], capture=True)
                    message = str(caught.exception)
                    self.assertIn(unit + ".service " + action, message)
                    self.assertIn("systemctl show " + unit, message)
                    self.assertNotIn("private-response-fixture", message)

    def test_other_failure_keeps_arguments_and_response_private(self):
        with patch.object(mod.subprocess, "Popen") as process:
            process.return_value.communicate.return_value = (b"", b"private-response-fixture")
            process.return_value.returncode = 1
            with self.assertRaises(mod.InstallError) as caught:
                self.installer.run(["git", "private-argument-fixture"], capture=True)
            self.assertNotIn("private-", str(caught.exception))

    def test_git_failure_classifies_without_echoing_credentials(self):
        fixtures = (
            ("could not read Username: terminal prompts disabled", "인증정보를 읽을 수 없음"),
            ("Authentication failed", "Git 인증 거부"),
            ("The requested URL returned error: 403", "쓰기 또는 branch 권한 거부"),
            ("repository not found", "저장소 주소 또는 접근 권한"),
            ("Could not resolve host", "DNS 조회 실패"),
            ("SSL certificate problem", "TLS 인증서 검증 실패"),
            ("Failed to connect", "Git 서버 연결 실패"),
            ("non-fast-forward", "원격 branch가 앞서 있음"),
            ("unrecognized failure", "Git 저장소·인증·네트워크 확인 필요"),
        )
        for detail, expected in fixtures:
            result = subprocess.CompletedProcess([], 128, b"private-output-fixture", (detail + " private-token-fixture").encode())
            with self.subTest(detail=detail), patch.object(self.installer, "run", return_value=result):
                with self.assertRaises(mod.InstallError) as caught:
                    self.installer.git("push", "--dry-run", "https://private-user:private-token-fixture@example.invalid/repo", "HEAD:refs/heads/site")
                message = str(caught.exception)
                self.assertIn(expected, message)
                self.assertIn("push 사전 검사(dry-run)", message)
                self.assertNotIn("private-", message)
                self.assertIs(self.installer.git("diff", check=False), result)

    def test_default_plan_never_changes_host_or_env(self):
        result = subprocess.run(["bash", "./sadp", "--install", "--env-file", str(self.env)],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[PLAN]", result.stdout)
        self.assertEqual(self.env.read_text(), EXAMPLE)

    def test_staging_to_production_to_https_in_one_run(self):
        self.installer.finish_tls()
        steps = [e for e in self.installer.events if e[0] in ("cluster", "publish")]
        self.assertEqual(steps, [("cluster", "staging", False), ("publish", "production", False),
                                 ("cluster", "production", False), ("publish", "production", True),
                                 ("cluster", "production", True)])
        values = mod.site.parse_env(self.env)
        self.assertEqual(values["ACME_STAGING_VERIFIED"], "true")
        self.assertEqual(values["EXISTING_GATEWAY_TLS_READY"], "true")
        self.assertEqual(self.env.stat().st_mode & 0o777, 0o600)

    def test_failed_platform_does_not_advance_env(self):
        self.installer.fail_phase = True
        with self.assertRaises(mod.InstallError):
            self.installer.finish_tls()
        self.assertEqual(self.env.read_text(), EXAMPLE)

    def test_stale_ready_condition_does_not_advance_env(self):
        self.installer.bad_certificate = True
        with self.assertRaises(mod.InstallError):
            self.installer.finish_tls()
        self.assertEqual(self.env.read_text(), EXAMPLE)

    def test_resume_production_does_not_reissue_staging(self):
        mod.atomic_env_update(self.env, {"ACME_STAGING_VERIFIED": "true", "TLS_ISSUER_MODE": "production"})
        self.installer.reload()
        self.installer.finish_tls()
        self.assertNotIn(("cluster", "staging", False), self.installer.events)

    def test_provided_tls_skips_acme_promotion(self):
        mod.atomic_env_update(self.env, {"TLS_SOURCE": "provided", "EXISTING_GATEWAY_TLS_READY": "true"})
        self.installer.reload()
        self.installer.finish_tls()
        self.assertEqual(len(self.installer.events), 1)

    def test_invalid_tls_transition_is_atomic(self):
        with self.assertRaises(mod.site.ConfigError):
            mod.atomic_env_update(self.env, {"TLS_ISSUER_MODE": "production"})
        self.assertEqual(self.env.read_text(), EXAMPLE)

    def test_drain_failure_prevents_configuration_and_restart(self):
        i = self.installer
        i.fail_drain = True
        with self.assertRaises(mod.InstallError):
            i.restart_node("worker", lambda: i.events.append(("configure",)), lambda: i.events.append(("restart",)))
        self.assertFalse(any(e[0] in ("configure", "restart", "uncordon") for e in i.events))

    def test_restart_failure_keeps_node_cordoned(self):
        def fail():
            raise mod.InstallError("restart failed")
        with self.assertRaises(mod.InstallError):
            self.installer.restart_node("worker", lambda: None, fail)
        self.assertFalse(any(e[0] == "uncordon" for e in self.installer.events))

    def test_success_uncordons_only_after_ready(self):
        i = self.installer
        i.restart_node("worker", lambda: i.events.append(("configure",)), lambda: i.events.append(("restart",)))
        self.assertEqual([e[0] for e in i.events], ["get", "drain", "configure", "restart", "ready", "uncordon"])

    def test_existing_cordon_is_preserved(self):
        i = self.installer
        i.cordoned = True
        i.restart_node("worker", lambda: None, lambda: None)
        self.assertFalse(any(e[0] == "uncordon" for e in i.events))

    def test_ssh_uses_noninteractive_strict_host_verification(self):
        i = self.installer
        i.cfg["installer"]["sshUser"] = "operator"
        with patch.object(i, "run") as run:
            i.ssh("192.0.2.1", "systemctl restart rke2-agent")
        args = run.call_args.args[0]
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn("BatchMode=yes", args)
        self.assertIn("sudo -n env -u BASH_ENV -u ENV bash --noprofile --norc -ceu", args[-1])

    def test_remote_shell_skips_interactive_startup_and_preserves_stdin(self):
        startup = Path(self.temp.name) / "startup.bash"
        startup.write_text('printf "%s" "$PS1"\nexit 99\n')
        environment = dict(os.environ, BASH_ENV=str(startup), ENV=str(startup))
        for key in ("PS1", "SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY"):
            environment.pop(key, None)
        broken = subprocess.run(["bash", "-ceu", "true"], env=environment, stdin=subprocess.DEVNULL, capture_output=True)
        self.assertIn(b"PS1: unbound variable", broken.stderr)
        self.installer.cfg["installer"]["sshUser"] = "root"
        payload = b"archive-fixture\x00bytes"
        with patch.object(self.installer, "run") as run:
            self.installer.ssh("192.0.2.1", "cat", input=payload, capture=True)
        command = shlex.split(run.call_args.args[0][-1])
        result = subprocess.run(command, env=environment, input=payload, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)
        self.assertEqual(result.stderr, b"")
        failed = subprocess.run(command[:-1] + ["false; echo should-not-run"], env=environment, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertNotIn(b"should-not-run", failed.stdout)

    def test_internal_only_never_disables_control_plane_external_check(self):
        self.installer.cfg["interfaces"]["workersInternalOnly"] = True
        self.assertIn("--internal-only", self.installer.interface_check_args("192.0.2.1", worker=True))
        self.assertNotIn("--internal-only", self.installer.interface_check_args("192.0.2.1", worker=False))
        with patch.object(self.installer, "ssh") as ssh:
            self.installer.preflight_worker("worker-fixture", "192.0.2.1")
        command = shlex.split(ssh.call_args.args[1])
        self.assertIn("--internal-only", command)
        self.assertEqual(command[:2], ["python3", "-c"])

    def test_worker_preflight_identifies_failed_check_and_stops(self):
        expected = "worker-fixture"
        with patch.object(self.installer, "ssh") as ssh:
            self.installer.preflight_worker(expected, "192.0.2.1")
        script = ssh.call_args_list[0].args[1]
        setup = r"""
hostname() { if [[ $SCENARIO == hostname ]]; then echo other-worker; else echo worker-fixture; fi; }
systemctl() { [[ $SCENARIO != agent ]]; }
python3() { echo private-response-fixture >&2; [[ $SCENARIO != yaml ]]; }
command() {
  if [[ $SCENARIO == python && $2 == python3 || $SCENARIO == tar && $2 == tar ]]; then return 1; fi
  builtin command "$@"
}
"""
        for scenario, label in (("hostname", "hostname 일치"), ("agent", "rke2-agent 실행"),
                                ("python", "Python3"), ("yaml", "PyYAML"), ("tar", "tar"), ("ok", "")):
            with self.subTest(scenario=scenario):
                result = subprocess.run(["bash", "--noprofile", "--norc", "-ceu", setup + script],
                                        env=dict(os.environ, SCENARIO=scenario, BASH_ENV=""),
                                        capture_output=True, text=True)
                self.assertNotIn("private-response-fixture", result.stdout + result.stderr)
                if label:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("worker " + expected + ": " + label + " 검사 실패", result.stderr)
                    self.assertNotIn("[OK] worker " + expected + ": " + label, result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(result.stdout.splitlines()), 5)

    def test_ssh_failure_identifies_target_without_remote_script(self):
        self.installer.cfg["installer"]["sshUser"] = "root"
        with patch.object(self.installer, "run", side_effect=mod.InstallError("ssh 단계 실패(exit=1)")):
            with self.assertRaises(mod.InstallError) as caught:
                self.installer.ssh("192.0.2.1", "private-script-fixture")
        self.assertIn("root@192.0.2.1", str(caught.exception))
        self.assertNotIn("private-script-fixture", str(caught.exception))

    def test_parser_rejects_ssh_option_injection(self):
        values = mod.site.parse_env(self.env)
        values["SADP_SSH_USER"] = "-oProxyCommand=bad"
        with self.assertRaises(mod.site.ConfigError):
            mod.site.validate(values)

    def test_parser_accepts_only_push_token_path(self):
        values = mod.site.parse_env(self.env)
        values["SADP_GIT_PUSH_TOKEN_FILE"] = "/etc/sadp/secrets/git-write"
        self.assertEqual(mod.site.validate(values)["installer"]["pushTokenFile"], values["SADP_GIT_PUSH_TOKEN_FILE"])
        values["SADP_GIT_PUSH_TOKEN_FILE"] = "relative/file"
        with self.assertRaises(mod.site.ConfigError):
            mod.site.validate(values)

    def test_all_snapshots_before_publish_and_nodes_before_cluster(self):
        i = self.installer
        i.state = Path(self.temp.name) / "state"
        events = []

        def run(args, **kwargs):
            events.append(tuple(str(a) for a in args))
            return subprocess.CompletedProcess(args, 0, b"")

        with patch.object(i, "preflight", side_effect=lambda: events.append(("preflight",))), \
             patch.object(i, "run", side_effect=run), \
             patch.object(i, "ssh", side_effect=lambda *a, **kw: events.append(("ssh-check",))), \
             patch.object(i, "publish", side_effect=lambda: events.append(("publish",))), \
             patch.object(i, "nodes", side_effect=lambda: events.append(("nodes",))), \
             patch.object(i, "finish_tls", side_effect=lambda: events.append(("cluster",))):
            i.install()
        labels = [e[0] for e in events]
        self.assertLess(labels.index("preflight"), labels.index("publish"))
        self.assertLess(labels.index("/usr/local/bin/rke2"), labels.index("publish"))
        self.assertLess(labels.index("publish"), labels.index("nodes"))
        self.assertLess(labels.index("/usr/local/bin/rke2"), labels.index("nodes"))
        self.assertLess(labels.index("nodes"), labels.index("cluster"))
        self.assertEqual(i.process_env["SADP_INSTALL_ALL"], "true")

    def test_push_failure_prevents_host_changes(self):
        i = self.installer
        i.state = Path(self.temp.name) / "state"
        with patch.object(i, "preflight"), patch.object(i, "ssh"), \
             patch.object(i, "git", side_effect=mod.InstallError("push denied")), \
             patch.object(i, "nodes") as nodes, patch.object(i, "finish_tls") as cluster:
            with self.assertRaises(mod.InstallError):
                i.install()
        nodes.assert_not_called()
        cluster.assert_not_called()

    def test_workers_finish_before_control_plane_restart(self):
        i = self.installer
        i.node_name = i.cfg["nodes"]["controlHostname"]
        completed = []
        with patch.object(i, "prepare_workers"), patch.object(i, "run"), patch.object(i, "ssh"), \
             patch.object(i, "restart_node", side_effect=lambda name, *_: completed.append(name)):
            i.nodes()
        self.assertEqual(completed, [name for name, _ in i.cfg["nodes"]["workers"]] + [i.node_name])

    def test_single_server_needs_no_ssh(self):
        i = self.installer
        i.cfg["nodes"]["workers"] = []
        with patch.object(i, "prepare_workers"), patch.object(i, "run"), \
             patch.object(i, "ssh") as ssh, patch.object(i, "restart_node") as restart:
            i.nodes()
        ssh.assert_not_called()
        self.assertEqual(restart.call_count, 1)

    def git_fixture(self):
        repo = Path(self.temp.name) / "repo"
        repo.mkdir()
        def git(*args):
            return subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", *args],
                                  cwd=repo, check=True, capture_output=True).stdout
        git("init", "-b", "main")
        (repo / "contract.yaml").write_text("old: value\n")
        git("add", "contract.yaml")
        git("commit", "-m", "base")
        return repo, git

    def test_worker_archive_excludes_untracked_credentials(self):
        repo, _ = self.git_fixture()
        (repo / "private.env").write_text("sensitive fixture")
        captured = []
        i = self.installer
        with patch.object(mod, "ROOT", repo), patch.object(i, "ssh", side_effect=lambda *a, **kw: captured.append(kw["input"])):
            i.prepare_workers()
        with tarfile.open(fileobj=io.BytesIO(captured[0])) as archive:
            self.assertEqual(archive.getnames(), ["contract.yaml"])
        self.assertEqual(captured[1], self.env.read_bytes())

    def test_publish_commits_only_generated_paths_to_real_git_remote(self):
        repo, git = self.git_fixture()
        remote = Path(self.temp.name) / "remote.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
        i = mod.Installer(self.env)
        i.cfg["forgejo"]["repoURL"] = str(remote)
        original_run = i.run
        def render_or_run(args, **kwargs):
            if args[0] == "python3":
                (repo / "contract.yaml").write_text("generated: value\n")
                (repo / "unrelated.txt").write_text("keep private")
                return subprocess.CompletedProcess(args, 0)
            return original_run(args, **kwargs)
        with patch.object(mod, "ROOT", repo), patch.object(mod.site, "CONTRACT_PATH", repo / "contract.yaml"), \
             patch.object(mod.site, "prepare_updates", return_value={repo / "contract.yaml": "generated: value\n"}), \
             patch.object(mod.site, "GENERATED_PATHS", ()), patch.object(i, "run", side_effect=render_or_run):
            i.publish()
        self.assertEqual(git("show", "--format=", "--name-only", "HEAD").decode().strip(), "contract.yaml")
        self.assertEqual(git("status", "--porcelain").decode().strip(), "?? unrelated.txt")
        self.assertEqual(git("ls-remote", str(remote), "refs/heads/main").decode().split()[0],
                         i.process_env["SADP_INSTALL_REVISION"])

    def test_cluster_apply_initializes_unseals_and_seeds_before_deploy(self):
        for fail_init in (False, True):
            with self.subTest(fail_init=fail_init), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                script = root / "scripts/install/sadp-install.sh"
                script.parent.mkdir(parents=True)
                script.write_text((ROOT / "scripts/install/sadp-install.sh").read_text())
                token = root / "token"
                token.write_text("fixture only")
                env_file = root / "site.env"
                env_file.write_text(EXAMPLE)
                cfg = mod.site.validate(mod.site.parse_env(env_file))
                cfg["baseDomain"] = "fixture.invalid"
                cfg["forgejo"]["repoURL"] = "https://fixture.invalid/repo/site.git"
                cfg["registry"]["host"] = "registry.fixture.invalid"
                cfg["network"]["publicIP"] = "198.18.0.1"
                cfg["tls"].update(source="provided", existingReady=True)
                cfg["installer"].update(gitops=False, installMonitoring=False, buildImages=False,
                                        portalTokenFile=str(token), registryPullDockerconfig=str(token),
                                        registryPushDockerconfig=str(token))
                values = root / "validated.env"
                values.write_text(mod.site.install_env(cfg))
                bin_dir = root / "bin"
                bin_dir.mkdir()
                executables = {
                    "id": "echo 0\n",
                    "stat": 'if [[ "$2" == "%u" ]]; then echo 0; else echo 600; fi\n',
                    "python3": 'if [[ "$*" == *--print-install-env* ]]; then cat "$VALIDATED_ENV"; fi\n',
                    "kubectl": 'if [[ "$*" == *status.sync.revision* ]]; then printf "%s" "$SADP_INSTALL_REVISION"; '
                               'elif [[ "$*" == *status.sync.status* ]]; then echo Synced; fi\n',
                }
                for name, body in executables.items():
                    path = bin_dir / name
                    path.write_text("#!/usr/bin/env bash\n" + body)
                    path.chmod(0o700)
                paths = ("scripts/verify/verify-squid-egress.sh", "scripts/cluster/install-local-path-storage.sh",
                         "scripts/cluster/preflight.sh", "scripts/node/install-docker-proxy.sh",
                         "scripts/cluster/install-devtron.sh", "scripts/cluster/install-testbed-platform.sh",
                         "scripts/cluster/bootstrap-testbed-services.sh", "scripts/ops/unseal-openbao.sh",
                         "scripts/ops/configure-openbao-oidc.sh", "scripts/cluster/install-portal-backend.sh",
                         "scripts/cluster/deploy-testbed-apps.sh", "scripts/verify/verify-portal-auth.sh",
                         "scripts/verify/verify-testbed.sh")
                for name in paths:
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('printf "%s\\n" "$0 $*" >> "$CALL_LOG"\n'
                                    'if [[ "$*" == *--init-only* && "$FAIL_INIT" == true ]]; then exit 1; fi\n')
                log = root / "calls"
                environment = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"],
                                   VALIDATED_ENV=str(values), CALL_LOG=str(log), FAIL_INIT=str(fail_init).lower(),
                                   SADP_INSTALL_ALL="true", SADP_INSTALL_REVISION="a" * 40,
                                   KUBECTL_BIN=str(bin_dir / "kubectl"), SADP_STATE_DIR=str(root / "state"))
                result = subprocess.run(["bash", str(script), "--phase", "cluster", "--apply",
                                         "--env-file", str(env_file), "--node-name", cfg["nodes"]["controlHostname"]],
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1 if fail_init else 0, result.stdout + result.stderr)
                calls = log.read_text()
                if fail_init:
                    self.assertNotIn("unseal-openbao.sh", calls)
                    self.assertNotIn("deploy-testbed-apps.sh", calls)
                else:
                    sequence = ("--init-only", "unseal-openbao.sh --apply", "--skip-openbao-oidc",
                                "configure-openbao-oidc.sh --apply", "--token-only", "deploy-testbed-apps.sh",
                                "verify-testbed.sh")
                    positions = [calls.index(item) for item in sequence]
                    self.assertEqual(positions, sorted(positions))


class OIDCCredentialsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.directory = self.state / "credentials"
        self.directory.mkdir(mode=0o700)
        self.output = io.StringIO()
        # root 전용 설치 동작은 소유권만 모사하고 실제 파일·권한·링크 처리는 임시 디스크에서 검증한다.
        original = Path.lstat
        def root_stat(path, *args, **kwargs):
            result = list(original(path, *args, **kwargs))
            result[4:6] = [0, 0]
            return os.stat_result(result)
        for context in (patch.object(Path, "lstat", root_stat),
                        patch.object(mod.os, "geteuid", return_value=0),
                        patch.object(mod.os, "fchown"), redirect_stdout(self.output)):
            context.__enter__()
            self.addCleanup(context.__exit__, None, None, None)

    def path(self, name):
        return self.directory / f"oidc-{name}-client-secret"

    def test_shared_asks_once_and_ignores_legacy_files(self):
        self.path("portal").write_text("legacy")
        self.path("portal").chmod(0o600)
        with patch.object(mod.getpass, "getpass", side_effect=["shared-fixture"] * 2) as prompt:
            mod.prepare_oidc_credentials(self.state, interactive=True, shared=True)
            self.assertEqual(prompt.call_count, 2)
        self.assertEqual(self.path("shared").read_text(), "shared-fixture")
        self.assertEqual(self.path("portal").read_text(), "legacy")
        self.assertFalse(self.path("secure-demo").exists())
        self.assertFalse(self.path("openbao").exists())
        self.assertNotIn("shared-fixture", self.output.getvalue())
        with patch.object(mod.getpass, "getpass") as prompt:
            mod.prepare_oidc_credentials(self.state, interactive=False, shared=True)
            prompt.assert_not_called()

    def test_missing_noninteractive_lists_all_without_writing(self):
        with patch.object(mod.getpass, "getpass") as prompt:
            with self.assertRaises(mod.InstallError) as caught:
                mod.prepare_oidc_credentials(self.state, interactive=False)
            for name in mod.OIDC_CLIENTS:
                self.assertIn(str(self.path(name)), str(caught.exception))
            prompt.assert_not_called()
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_prompt_only_missing_preserve_existing_and_no_secret_output(self):
        existing = self.path("portal")
        existing.write_text("existing-fixture")
        existing.chmod(0o600)
        with patch.object(mod.getpass, "getpass", side_effect=["demo-fixture"] * 2 + ["bao-fixture"] * 2) as prompt:
            mod.prepare_oidc_credentials(self.state, interactive=True)
            self.assertEqual(prompt.call_count, 4)
        self.assertEqual(existing.read_text(), "existing-fixture")
        for name, expected in (("secure-demo", "demo-fixture"), ("openbao", "bao-fixture")):
            self.assertEqual(self.path(name).read_text(), expected)
            self.assertEqual(self.path(name).stat().st_mode & 0o777, 0o600)
            self.assertNotIn(expected, self.output.getvalue())
        with patch.object(mod.getpass, "getpass") as prompt:
            mod.prepare_oidc_credentials(self.state, interactive=False)
            prompt.assert_not_called()

    def test_mismatch_retries_only_current_and_cancel_keeps_completed(self):
        with patch.object(mod.getpass, "getpass", side_effect=["one", "two", "demo", "demo", ""]):
            with self.assertRaises(mod.InstallError):
                mod.prepare_oidc_credentials(self.state, interactive=True)
        self.assertEqual(self.path("secure-demo").read_text(), "demo")
        self.assertFalse(self.path("portal").exists())
        self.assertFalse(list(self.directory.glob(".oidc-*")))

    def test_symlink_and_broad_permissions_are_not_replaced(self):
        path = self.path("secure-demo")
        path.symlink_to(self.state / "absent")
        with self.assertRaises(mod.InstallError):
            mod.prepare_oidc_credentials(self.state, interactive=True)
        self.assertTrue(path.is_symlink())
        path.unlink()
        path.write_text("existing")
        path.chmod(0o644)
        with self.assertRaises(mod.InstallError):
            mod.prepare_oidc_credentials(self.state, interactive=True)
        self.assertEqual(path.read_text(), "existing")

    def test_echo_fallback_and_eof_never_write(self):
        for error in (mod.getpass.GetPassWarning, EOFError):
            with patch.object(mod.getpass, "getpass", side_effect=error):
                with self.assertRaises(mod.InstallError):
                    mod.prepare_oidc_credentials(self.state, interactive=True)
            self.assertEqual(list(self.directory.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
