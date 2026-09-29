#!/usr/bin/env python3
"""검증된 env로 설치 경계를 순서대로 실행하고 완료한 TLS 단계만 기록한다."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import getpass
import warnings
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("configure_site", ROOT / "scripts/site/configure-site.py")
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


class InstallError(Exception):
    pass


def private_file(path: Path) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) not in (0o400, 0o600) or not info.st_size:
        raise InstallError(f"root 소유 0400/0600 일반 파일이 필요함: {path}")


OIDC_CLIENTS = ("secure-demo", "portal", "openbao")


def prepare_oidc_credentials(state: Path, *, interactive: bool, shared: bool = False) -> None:
    directory = state / "credentials"
    missing = []
    for name in (("shared",) if shared else OIDC_CLIENTS):
        path = directory / f"oidc-{name}-client-secret"
        try:
            info = path.lstat()
        except FileNotFoundError:
            missing.append((name, path))
            continue
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0
                or stat.S_IMODE(info.st_mode) != 0o600 or not info.st_size):
            raise InstallError(f"OIDC client Secret은 비어 있지 않은 root:root 0600 일반 파일이어야 함: {path}")
    if not missing:
        return
    guidance = ("외부 IdP에서 발급한 client Secret이 필요합니다(사용자 비밀번호/토큰 아님).\n"
                + "\n".join(f"  {name}: {path}" for name, path in missing)
                + "\n파일에는 해당 Secret 문자열 하나만 넣고 root:root 0600으로 준비하십시오."
                + "\n터미널에서 같은 --phase all --apply 명령을 실행하면 없는 항목만 숨김 입력받습니다.")
    if not interactive:
        raise InstallError(guidance)
    if os.geteuid() != 0:
        raise InstallError("OIDC Secret 준비는 root로 실행해야 함")
    print("[INFO] " + guidance, flush=True)
    print("[INFO] 기존 파일은 유지하며 Secret은 site.env·Git·로그에 기록하지 않습니다.", flush=True)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    # 링크나 다른 사용자가 바꿀 수 있는 디렉터리로 Secret이 새지 않게 한다.
    for parent in (state, directory):
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise InstallError(f"Secret 저장 디렉터리는 root 소유이며 다른 사용자 쓰기가 금지되어야 함: {parent}")
    for name, path in missing:
        while True:
            # echo 차단 실패 시 getpass가 평문 입력으로 대체하지 않도록 중단한다.
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                try:
                    value = getpass.getpass(f"{name} OIDC client Secret (숨김 입력): ")
                    confirm = getpass.getpass(f"{name} OIDC client Secret 확인: ") if value else ""
                except (EOFError, getpass.GetPassWarning) as error:
                    raise InstallError("OIDC Secret 숨김 입력을 사용할 수 없습니다. 파일로 준비 후 재실행하십시오.") from error
            if not value:
                raise InstallError("OIDC Secret 입력 취소. 준비된 파일과 기존 설정을 유지합니다.")
            if value != confirm or any(char in value for char in "\r\n\x00"):
                print("[INFO] 입력이 다르거나 여러 줄입니다. 해당 항목만 다시 입력하십시오.", flush=True)
                continue
            break
        # 완성된 0600 파일만 게시하며 재실행이나 경쟁으로 생긴 기존 파일은 덮어쓰지 않는다.
        fd, temporary = tempfile.mkstemp(prefix=".oidc-", dir=directory)
        try:
            with os.fdopen(fd, "w") as stream:
                os.fchmod(stream.fileno(), 0o600)
                os.fchown(stream.fileno(), 0, 0)
                stream.write(value)
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, path)
        finally:
            os.unlink(temporary)
        print(f"[OK] {name} OIDC client Secret 파일 준비", flush=True)


def atomic_env_update(path: Path, changes: dict[str, str]) -> None:
    # 실제 발급 성공 뒤 원본 env까지 갱신해야 다음 설치가 TLS를 과거로 되돌리지 않는다.
    original = path.read_text()
    values = site.parse_env(path)
    values.update(changes)
    site.validate(values)
    lines = []
    remaining = dict(changes)
    for line in original.splitlines():
        key = line.strip().removeprefix("export ").split("=", 1)[0].strip()
        if key in changes:
            lines.append(f"{key}={changes[key]}")
            remaining.pop(key, None)
        else:
            lines.append(line)
    lines.extend(f"{key}={value}" for key, value in remaining.items())
    fd, name = tempfile.mkstemp(prefix=".sadp-env-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write("\n".join(lines) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Installer:
    def __init__(self, env_file: Path, node_name: str = ""):
        self.env_file = env_file.absolute()
        self.node_name = node_name or socket.gethostname().split(".")[0]
        self.reload()
        self.process_env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        self.kubectl = [os.environ.get("KUBECTL_BIN", "/var/lib/rancher/rke2/bin/kubectl"),
                        "--kubeconfig", os.environ.get("KUBECONFIG_PATH", "/etc/rancher/rke2/rke2.yaml")]
        self.state = Path(os.environ.get("SADP_STATE_DIR", "/var/lib/sadp"))

    def reload(self):
        self.cfg = site.validate(site.parse_env(self.env_file))

    def run(self, args, *, capture=False, input=None, check=True, timeout=1800):
        # 자격증명은 stdin 또는 파일로만 전달한다. 실패 메시지에 argv/서버 응답을 복사하지 않는다.
        command = [str(arg) for arg in args]
        process = subprocess.Popen(command, cwd=ROOT, env=self.process_env, start_new_session=True,
                                   stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE if capture else None,
                                   stderr=subprocess.PIPE if capture else None)
        try:
            stdout, stderr = process.communicate(input, timeout=timeout)
        except BaseException:
            # timeout 뒤 손자 설치기가 남으면 재실행과 겹칠 수 있어 로컬 프로세스 그룹을 함께 끝낸다.
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
            except ProcessLookupError:
                pass
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        if check and result.returncode:
            # 전체 argv에는 자격증명이 있을 수 있다. 설치기가 고정한 서비스 명령만 식별한다.
            service_actions = {
                ("systemctl", "is-active", "--quiet", "rke2-server"): ("rke2-server", "실행 상태 확인"),
                ("systemctl", "is-active", "--quiet", "docker"): ("docker", "실행 상태 확인"),
                ("systemctl", "restart", "rke2-server"): ("rke2-server", "재시작"),
                ("systemctl", "restart", "docker"): ("docker", "재시작"),
            }
            if tuple(command) in service_actions:
                unit, action = service_actions[tuple(command)]
                raise InstallError(
                    f"{unit}.service {action} 실패(exit={result.returncode}); 후속 단계 중단. "
                    f"확인: sudo systemctl show {unit} -p LoadState -p ActiveState -p SubState. "
                    + ("RKE2가 설치되고 실행 중인 control-plane에서 실행해야 합니다."
                       if unit == "rke2-server" else
                       "Docker 서비스 설치·실행 여부를 확인하십시오. RKE2의 containerd와 별개입니다.")
                )
            raise InstallError(f"{Path(str(args[0])).name} 단계 실패(exit={result.returncode}); 후속 단계 중단")
        return result

    def git(self, *args, check=True):
        result = self.run(["git", *args], capture=True, check=False)
        if not check or not result.returncode:
            return result
        # Git 오류에는 URL에 담긴 자격증명이나 서버 응답이 섞일 수 있어 분류 결과만 표시한다.
        output = ((result.stderr or b"") + (result.stdout or b"")).decode("utf-8", errors="replace").lower()
        categories = (
            (("could not read username", "could not read password", "terminal prompts disabled"),
             "Git 인증정보를 읽을 수 없음. SADP_GIT_PUSH_TOKEN_FILE 또는 root 계정의 credential helper를 확인하십시오"),
            (("authentication failed", "invalid username or password", "http basic: access denied", "error: 401"),
             "Git 인증 거부. 토큰 유효기간과 SADP_ARGO_REPO_USERNAME을 확인하십시오"),
            (("protected branch", "protected-branch", "error: 403", "not allowed to push", "write access to repository not granted"),
             "저장소 쓰기 또는 branch 권한 거부. 토큰의 저장소 쓰기 권한과 branch 보호 설정을 확인하십시오"),
            (("repository not found", "does not appear to be a git repository"),
             "저장소 주소 또는 접근 권한 확인 필요. FORGEJO_REPO_URL과 토큰의 대상 저장소를 확인하십시오"),
            (("could not resolve host", "could not resolve proxy"),
             "Git 서버 또는 프록시 DNS 조회 실패. control-plane의 DNS와 프록시 설정을 확인하십시오"),
            (("ssl certificate problem", "certificate verify failed", "server certificate verification failed"),
             "Git 서버 TLS 인증서 검증 실패. 서버 인증서와 신뢰 CA를 확인하십시오"),
            (("failed to connect", "connection timed out", "connection refused", "no route to host"),
             "Git 서버 연결 실패. control-plane의 네트워크와 Git 서버 상태를 확인하십시오"),
            (("non-fast-forward", "fetch first"),
             "원격 branch가 앞서 있음. 원격 변경을 확인하고 통합한 뒤 재실행하십시오(force push하지 않음)"),
        )
        reason = "Git 저장소·인증·네트워크 확인 필요. 서버 오류 원문은 자격증명 보호를 위해 출력하지 않습니다"
        for patterns, message in categories:
            if any(pattern in output for pattern in patterns):
                reason = message
                break
        operation = args[0] if args and args[0] in {
            "push", "status", "branch", "check-ref-format", "rev-parse", "archive", "add", "diff", "commit"
        } else "작업"
        if operation == "push" and "--dry-run" in args:
            operation = "push 사전 검사(dry-run)"
        raise InstallError(f"Git {operation} 실패(exit={result.returncode}): {reason}; 후속 단계 중단")

    def kctl(self, *args, **kwargs):
        return self.run([*self.kubectl, *args], **kwargs)

    def plan(self):
        print("[PLAN] env 검증 → etcd snapshot → 생성물 렌더·검사·Git commit/push", flush=True)
        print("[PLAN] Squid 준비 → 노드별 drain·설정·RKE2 재시작·Ready·uncordon → Docker 재시작", flush=True)
        print("[PLAN] 플랫폼 → staging/production Certificate 확인·env 갱신·재렌더/push → HTTPS", flush=True)
        print("[PLAN] OpenBao 초기화·unseal → 서비스·이미지·앱 → 선택한 acceptance", flush=True)
        shared = self.cfg["identityProvider"].get("sharedClientID")
        print("[PLAN] OIDC " + ("공통 Secret 1개" if shared else "앱별 Secret 3개")
              + ": 기존 파일 재사용, 적용 시 없는 항목만 숨김 입력", flush=True)
        if shared:
            hosts = self.cfg["hosts"]
            print("[INFO] 공유 Provider에 등록할 redirect URI:", flush=True)
            for uri in (f"https://{hosts['secure-demo']}/oauth2/callback",
                        f"https://{hosts['portal']}/api/auth/callback/oidc",
                        f"https://{hosts['openbao']}/ui/vault/auth/oidc/oidc/callback",
                        "http://localhost:8250/oidc/callback"):
                print("  " + uri, flush=True)
        print("[INFO] --apply는 서비스 중단, 생성물 Git 반영, TLS 진행값 기록을 포함한다", flush=True)

    def preflight(self):
        c = self.cfg
        if os.geteuid() != 0:
            raise InstallError("all 적용은 control-plane에서 root로 실행해야 함")
        if self.node_name != c["nodes"]["controlHostname"]:
            raise InstallError("all 적용은 계약의 control-plane에서만 실행 가능")
        private_file(self.env_file)
        if self.env_file.resolve().is_relative_to(ROOT.resolve()):
            raise InstallError("all은 Git 밖의 site.env를 사용해야 함")
        if c["baseDomain"].endswith("example.invalid") or "example.invalid" in c["forgejo"]["repoURL"]:
            raise InstallError("예제 BASE_DOMAIN을 실제 설치에 사용할 수 없음")
        if c["network"]["publicIP"].startswith(("192.0.2.", "198.51.100.", "203.0.113.")):
            raise InstallError("문서 전용 PUBLIC_IP를 실제 설치에 사용할 수 없음")
        if "example.invalid" in c["registry"]["host"]:
            raise InstallError("예제 Registry를 실제 설치에 사용할 수 없음")
        branch = c["forgejo"]["revision"]
        self.git("check-ref-format", "--branch", branch)
        if self.git("branch", "--show-current").stdout.decode().strip() != branch:
            raise InstallError("현재 Git branch는 FORGEJO_REVISION과 같아야 함(자동 branch 전환 없음)")
        if self.git("status", "--porcelain").stdout:
            raise InstallError("all은 깨끗한 worktree가 필요함; 기존 변경을 먼저 검토·commit해야 함")
        for binary in ("bash", "git", "helm", "openssl", "jq", "systemctl", "tar"):
            self.run(["bash", "-c", 'command -v "$1" >/dev/null', "bash", binary], capture=True)
        for key in ("argoRepoTokenFile", "registryPullDockerconfig", "registryPushDockerconfig"):
            needed = c["installer"]["gitops"] if key == "argoRepoTokenFile" else c["installer"]["deployApps"]
            if needed:
                private_file(Path(c["installer"][key]))
        if c["tls"]["source"] == "acme":
            private_file(Path(c["installer"]["dnsTsigSecretFile"]))
        else:
            certificate = ROOT / c["tls"]["providedCertificatePath"]
            key = ROOT / c["tls"]["providedPrivateKeyPath"]
            if not certificate.is_file() or not key.is_file():
                self.kctl("get", "secret", c["tls"]["wildcardSecret"], "-n", c["layout"]["gatewayNamespace"], capture=True)
        if c["installer"]["deployApps"]:
            if not c["installer"]["portalTokenFile"]:
                raise InstallError("all 앱 설치에는 SADP_PORTAL_FORGEJO_TOKEN_FILE이 필요함")
            private_file(Path(c["installer"]["portalTokenFile"]))
        prepare_oidc_credentials(self.state, interactive=sys.stdin.isatty(),
                                 shared=bool(c["identityProvider"].get("sharedClientID")))
        if c["installer"]["pushTokenFile"]:
            private_file(Path(c["installer"]["pushTokenFile"]))
        self.run(["systemctl", "is-active", "--quiet", "rke2-server"])
        self.run(["systemctl", "is-active", "--quiet", "docker"])
        self.run(["python3", "scripts/lib/node-interface-preflight.py",
                  *self.interface_check_args(c["nodes"]["controlIP"], worker=False)])
        nodes = json.loads(self.kctl("get", "nodes", "-o", "json", capture=True).stdout)["items"]
        expected = {c["nodes"]["controlHostname"]: c["nodes"]["controlIP"], **dict(c["nodes"]["workers"])}
        if {n["metadata"]["name"] for n in nodes} != set(expected):
            raise InstallError("실제 Node 이름과 env의 server/worker 목록이 다름")
        for node in nodes:
            labels = node["metadata"].get("labels", {})
            is_server = any(key in labels for key in ("node-role.kubernetes.io/control-plane", "node-role.kubernetes.io/master"))
            if is_server != (node["metadata"]["name"] == c["nodes"]["controlHostname"]):
                raise InstallError("Node 역할과 env의 server/worker 목록이 다름")
            if not any(a.get("type") == "InternalIP" and a.get("address") == expected[node["metadata"]["name"]]
                       for a in node.get("status", {}).get("addresses", [])):
                raise InstallError("Node InternalIP와 env가 다름")
            if c["nodes"]["mode"] == "single" and (node.get("spec", {}).get("unschedulable") or any(
                    t.get("effect") in ("NoSchedule", "NoExecute") for t in node.get("spec", {}).get("taints", []))):
                raise InstallError("single 서버가 cordon 또는 차단 taint 상태임; 자동으로 배치 정책을 바꾸지 않음")
        self.kctl("wait", "node", "--all", "--for=condition=Ready", "--timeout=3m")

    def publish(self):
        print("[INFO] env 렌더·회귀 검사 후 사이트 branch 반영", flush=True)
        self.run(["python3", "scripts/site/configure-site.py", "--env-file", self.env_file, "--write"])
        # 설치 시작 때 clean을 확인했으며 생성기만 실행했다. 임의 untracked 파일을 add하지 않는다.
        contract = site.yaml.safe_load(site.CONTRACT_PATH.read_text())
        allowed = set(site.prepare_updates(self.cfg, contract)) | set(site.GENERATED_PATHS)
        paths = [str(p.relative_to(ROOT)) for p in sorted(allowed) if p.exists() or self.git("ls-files", "--", str(p.relative_to(ROOT))).stdout]
        self.git("add", "--", *paths)
        if self.git("diff", "--cached", "--quiet", check=False).returncode:
            self.git("-c", "user.name=SADP Installer", "-c", "user.email=sadp-installer@example.invalid",
                     "commit", "-m", "Configure SADP site installation")
        self.git("push", self.cfg["forgejo"]["repoURL"], f"HEAD:refs/heads/{self.cfg['forgejo']['revision']}")
        revision = self.git("rev-parse", "HEAD").stdout.decode().strip()
        self.process_env["SADP_INSTALL_REVISION"] = revision

    def phase(self, phase, *, name=None):
        self.run(["bash", "scripts/install/sadp-install.sh", "--env-file", self.env_file,
                  "--phase", phase, "--node-name", name or self.node_name, "--apply"], timeout=14400)

    def ssh(self, address, script, *, input=None, capture=False):
        user = self.cfg["installer"]["sshUser"]
        # SSH 하위 Bash가 .bashrc/BASH_ENV를 읽으면 PS1 같은 대화형 설정이 nounset에서 실패한다.
        # 설치용 셸만 격리하고 원격 사용자의 시작 파일은 수정하지 않는다.
        remote = (["sudo", "-n"] if user != "root" else []) + [
            "env", "-u", "BASH_ENV", "-u", "ENV", "bash", "--noprofile", "--norc", "-ceu", script,
        ]
        try:
            return self.run(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                             "-o", "ConnectTimeout=10", f"{user}@{address}", shlex.join(remote)],
                            input=input, capture=capture)
        except InstallError as error:
            raise InstallError(f"SSH 대상={user}@{address}: {error}") from error

    def interface_check_args(self, address, *, worker):
        interfaces = self.cfg["interfaces"]
        args = ["--internal-interface", interfaces["internal"], "--external-interface", interfaces["external"],
                "--internal-ip", address, "--guarded-interfaces", ",".join(interfaces.get("guarded") or [])]
        if worker and interfaces.get("workersInternalOnly"):
            args.append("--internal-only")
        return args

    def preflight_worker(self, name, address):
        # -e로 조용히 끝나는 원격 복합 명령 대신 실패한 선행 조건만 값 비노출로 식별한다.
        checks = [
            ("hostname 일치", f'test "$(hostname -s)" = {shlex.quote(name)}',
             "hostname -s 결과와 WORKER_NODES의 이름을 확인하십시오"),
            ("rke2-agent 실행", "systemctl is-active --quiet rke2-agent",
             "systemctl show rke2-agent -p LoadState -p ActiveState -p SubState로 확인하십시오"),
            ("Python3", "command -v python3", "worker에 Python3가 필요합니다"),
            ("PyYAML", 'python3 -c "import yaml"', "worker의 Python3에 PyYAML이 필요합니다"),
            ("tar", "command -v tar", "worker에 tar가 필요합니다"),
        ]
        lines = []
        for label, command, guidance in checks:
            failure = shlex.quote(f"[FAIL] worker {name}: {label} 검사 실패. {guidance}")
            success = shlex.quote(f"[OK] worker {name}: {label}")
            lines.append(f"if ! {command} >/dev/null 2>&1; then printf '%s\\n' {failure} >&2; exit 1; fi")
            lines.append(f"printf '%s\\n' {success}")
        print(f"[INFO] worker 사전 검사: {name} ({address})", flush=True)
        self.ssh(address, "\n".join(lines))
        source = (ROOT / "scripts/lib/node-interface-preflight.py").read_text()
        self.ssh(address, shlex.join(["python3", "-c", source, *self.interface_check_args(address, worker=True)]))

    def prepare_workers(self):
        revision = self.git("rev-parse", "HEAD").stdout.decode().strip()
        self.remote_root = f"/var/lib/sadp/install-node/{revision}"
        # git archive는 ignored env·개인키·빌드 cache를 싣지 않는다. env는 별도 root-only 파일이다.
        archive = self.git("archive", "HEAD").stdout if self.cfg["nodes"]["workers"] else b""
        for name, address in self.cfg["nodes"]["workers"]:
            target = shlex.quote(self.remote_root)
            self.ssh(address, f"umask 077; mkdir -p {target}; tar -xf - -C {target}", input=archive)
            self.ssh(address, f"umask 077; cat > {target}/install.env", input=self.env_file.read_bytes())

    def configure_worker(self, name, address):
        root = shlex.quote(self.remote_root)
        self.ssh(address, f"cd {root}; bash scripts/install/sadp-install.sh --env-file {root}/install.env "
                          f"--phase node --node-name {shlex.quote(name)} --apply")

    def nodes(self):
        workers = self.cfg["nodes"]["workers"]
        self.prepare_workers()
        squid = self.cfg["network"]["squidIP"]
        if squid == self.cfg["nodes"]["controlIP"]:
            self.run(["bash", "scripts/node/install-squid-egress.sh"])
        else:
            for _, address in workers:
                if address == squid:
                    self.ssh(address, f"cd {shlex.quote(self.remote_root)}; bash scripts/node/install-squid-egress.sh")
        for name, address in workers:
            print(f"[INFO] worker 순차 설정·재시작: {name}", flush=True)
            self.restart_node(name, lambda: self.configure_worker(name, address),
                              lambda: self.ssh(address, "systemctl restart rke2-agent; systemctl is-active --quiet rke2-agent"))
        print("[INFO] control-plane 설정·재시작", flush=True)
        self.restart_node(self.node_name, lambda: self.phase("node"),
                          lambda: self.run(["systemctl", "restart", "rke2-server"]))
        self.run(["systemctl", "restart", "docker"])
        self.run(["bash", "scripts/node/install-docker-proxy.sh", "--check"])

    def install(self):
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(self.state / "install.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as lock, tempfile.TemporaryDirectory(prefix="sadp-install-auth-") as temp:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise InstallError("다른 통합 설치가 실행 중임") from error
            token_file = self.cfg["installer"]["pushTokenFile"]
            if token_file:
                helper = Path(temp) / "askpass"
                helper.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
if "username" in sys.argv[1].lower():
    print(os.environ["SADP_GIT_USERNAME"])
else:
    print(pathlib.Path(os.environ["SADP_GIT_TOKEN_PATH"]).read_text().strip())
''')
                helper.chmod(0o700)
                self.process_env.update(GIT_ASKPASS=str(helper), SADP_GIT_TOKEN_PATH=token_file,
                                        SADP_GIT_USERNAME=self.cfg["installer"]["argoRepoUsername"] or "oauth2",
                                        GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="")
            self.preflight()
            for name, address in self.cfg["nodes"]["workers"]:
                self.preflight_worker(name, address)
            # push 실패를 노드 변경보다 먼저 발견한다. force push와 원격 branch 강제 전환은 없다.
            print("[INFO] Git push 권한·연결 사전 검사(dry-run)", flush=True)
            self.git("push", "--dry-run", self.cfg["forgejo"]["repoURL"],
                     f"HEAD:refs/heads/{self.cfg['forgejo']['revision']}")
            self.run([os.environ.get("SADP_RKE2_BIN", "/usr/local/bin/rke2"),
                      "etcd-snapshot", "save", "--name", "sadp-before-install"])
            self.publish()
            self.nodes()
            self.process_env["SADP_INSTALL_ALL"] = "true"
            self.finish_tls()

    def wait_node(self, name):
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            result = self.kctl("wait", "node", name, "--for=condition=Ready", "--timeout=10s",
                               "--request-timeout=15s", capture=True, check=False, timeout=25)
            if result.returncode == 0:
                lease = self.kctl("get", "lease", name, "-n", "kube-node-lease", "-o", "json",
                                  "--request-timeout=15s", capture=True, check=False, timeout=25)
                if lease.returncode == 0:
                    renewed = json.loads(lease.stdout).get("spec", {}).get("renewTime", "")
                    if renewed and datetime.fromisoformat(renewed.replace("Z", "+00:00")) > self.restarted_at:
                        return
            time.sleep(5)
        raise InstallError("RKE2 재시작 후 Node Ready timeout; 노드는 cordon 상태로 유지됨")

    def restart_node(self, name, configure, restart):
        node = json.loads(self.kctl("get", "node", name, "-o", "json", capture=True).stdout)
        originally_cordoned = node.get("spec", {}).get("unschedulable", False)
        self.kctl("drain", name, "--ignore-daemonsets", "--delete-emptydir-data", "--timeout=10m")
        # 실패한 노드는 자동 uncordon하지 않는다. PDB와 unmanaged Pod도 강제로 우회하지 않는다.
        configure()
        restart()
        self.restarted_at = datetime.now(timezone.utc)
        self.wait_node(name)
        if not originally_cordoned:
            self.kctl("uncordon", name)

    def finish_tls(self):
        for _ in range(3):
            self.phase("cluster")
            tls = self.cfg["tls"]
            if tls["existingReady"]:
                return
            suffix = "-staging" if tls["issuerMode"] == "staging" else ""
            names = [tls["wildcardSecret"], *[s["wildcardTlsSecret"] for s in self.cfg["systems"]]]
            for base_name in names:
                name = base_name + suffix
                self.kctl("wait", "certificate", name, "-n", self.cfg["layout"]["gatewayNamespace"],
                           "--for=condition=Ready", "--timeout=15m")
                cert = json.loads(self.kctl("get", "certificate", name, "-n", self.cfg["layout"]["gatewayNamespace"],
                                           "-o", "json", capture=True).stdout)
                if cert["spec"]["issuerRef"]["name"] != tls["clusterIssuerName"] + suffix:
                    raise InstallError("Certificate issuer가 현재 TLS 단계와 다름")
                if not any(c.get("type") == "Ready" and c.get("status") == "True"
                           and c.get("observedGeneration") == cert["metadata"]["generation"]
                           for c in cert.get("status", {}).get("conditions", [])):
                    raise InstallError("Certificate의 현재 generation Ready가 확인되지 않음")
            changes = ({"ACME_STAGING_VERIFIED": "true", "TLS_ISSUER_MODE": "production"}
                       if suffix else {"EXISTING_GATEWAY_TLS_READY": "true"})
            atomic_env_update(self.env_file, changes)
            self.reload()
            self.publish()
        raise InstallError("TLS 단계 전환이 완료되지 않음")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--node-name", default="")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        installer = Installer(args.env_file, args.node_name)
        installer.plan()
        if not args.apply:
            return 0
        if args.allow_dirty:
            raise InstallError("all에서는 --allow-dirty를 허용하지 않음; 자동 commit에 기존 변경을 섞을 수 없음")
        if os.geteuid() != 0:
            raise InstallError("all 적용은 control-plane에서 root로 실행해야 함")
        installer.install()
        print("[OK] SADP 단일 명령 설치 완료", flush=True)
        return 0
    except (InstallError, site.ConfigError, OSError, subprocess.TimeoutExpired) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("[FAIL] 설치가 중단됨. SSH 작업과 cordon 상태를 확인한 뒤 재실행하세요.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
