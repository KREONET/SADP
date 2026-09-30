#!/usr/bin/env python3
"""고정 이미지의 검증된 redirect와 새 Squid 거부 기록을 대조해 허용 후보를 만든다."""
from __future__ import annotations

import argparse
import copy
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
import platform
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

ROOT = Path(__file__).resolve().parents[2]
DIGEST = "sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a"
BASE = "https://registry.k8s.io/v2/pause/"
INSTALLED_SQUID = Path("/etc/squid/squid.conf")
ACCESS_LOG = Path("/var/log/squid/access.log")
APPLY_LOCK = Path("/run/lock/sadp-registry-egress.lock")
KUBECTL = Path("/var/lib/rancher/rke2/bin/kubectl")
KUBECONFIG = Path("/etc/rancher/rke2/rke2.yaml")
REQUEST_TIMEOUT = 10
MAX_BODY = 4 * 1024 * 1024
ACCEPT = ", ".join(("application/vnd.oci.image.index.v1+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.v2+json"))


class DiscoveryError(Exception):
    pass



@contextmanager
def discovery_deadline(seconds):
    # socket timeout만으로는 DNS나 느린 연속 응답의 전체 대기 시간을 제한할 수 없다.
    def expired(signum, frame):
        raise DiscoveryError(f"탐지 제한 {seconds}초 초과: 마지막 진행 단계의 연결을 확인하세요. 설정은 변경하지 않았습니다.")
    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def architecture_list(raw):
    values = {item.strip() for item in raw.split(",")}
    known = {"amd64", "arm64", "arm", "386", "ppc64le", "s390x", "riscv64", "loong64"}
    if not values or not values <= known:
        raise argparse.ArgumentTypeError("아키텍처는 amd64,arm64 등의 쉼표 구분 목록이어야 합니다")
    return values


def positive_seconds(raw):
    value = int(raw)
    if not 1 <= value <= 3600:
        raise argparse.ArgumentTypeError("탐지 시간 제한은 1~3600초여야 합니다")
    return value


def select_architectures(explicit):
    if explicit:
        return explicit
    if KUBECTL.is_file() and KUBECONFIG.is_file():
        print("[PROGRESS] 클러스터 Linux 노드 아키텍처 조회 (최대 10초)", flush=True)
        try:
            result = subprocess.run([str(KUBECTL), "--kubeconfig", str(KUBECONFIG),
                                     "--request-timeout=8s", "get", "nodes", "-o", "json"],
                                    capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            raise DiscoveryError("노드 아키텍처 조회 시간 초과: API 연결을 확인하거나 --architectures를 지정하세요") from None
        if result.returncode:
            raise DiscoveryError("노드 아키텍처 조회 실패: API 연결을 확인하거나 --architectures를 지정하세요")
        values = set()
        for node in json.loads(result.stdout)["items"]:
            info = node.get("status", {}).get("nodeInfo", {})
            if info.get("operatingSystem") == "linux":
                value = info.get("architecture")
                if not value:
                    raise DiscoveryError("Linux 노드의 architecture 상태가 비어 있습니다")
                values.add(value)
        if not values:
            raise DiscoveryError("클러스터에 검사 가능한 Linux 노드가 없습니다")
        return architecture_list(",".join(sorted(values)))
    machine = platform.machine().lower()
    aliases = {"x86_64": "amd64", "aarch64": "arm64", "armv7l": "arm", "armv6l": "arm",
               "i386": "386", "i686": "386", "ppc64le": "ppc64le", "s390x": "s390x"}
    value = aliases.get(machine, machine)
    print("[INFO] 별도 Squid 호스트: 로컬 아키텍처만 탐지합니다. 다른 노드 아키텍처는 --architectures로 지정하세요.", flush=True)
    return architecture_list(value)


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


def checked_host(url):
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    # 임의 Location을 따라 내부 주소나 다른 서비스의 도메인을 허용하지 않는다.
    allowed = host in {"registry.k8s.io", "cdn.registry.k8s.io", "storage.googleapis.com"} or any(
        re.fullmatch(pattern, host) for pattern in (
            r"[a-z]+(?:-[a-z]+)+[0-9]+-docker\.pkg\.dev",
            r"prod-registry-k8s-io-[a-z0-9-]+\.s3(?:\.dualstack)?\.[a-z0-9-]+\.amazonaws\.com",
        )
    )
    if (parsed.scheme != "https" or parsed.username or parsed.password
            or parsed.port not in (None, 443) or parsed.fragment or not allowed):
        raise DiscoveryError("허용된 Kubernetes 배포 호스트 범위 밖 redirect: 자동 추적 중단")
    return host


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Fetcher:
    def __init__(self):
        # Squid 자체의 외부 연결 경로를 조사해야 차단된 CONNECT 뒤 Location도 볼 수 있다.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.observed = {}
        self.started = time.monotonic()

    def get(self, url, blob=False):
        visited = set()
        for hop in range(8):
            host = checked_host(url)
            if url in visited:
                raise DiscoveryError("redirect 순환 감지")
            visited.add(url)
            self.observed.setdefault(host, url)
            elapsed = int(time.monotonic() - self.started)
            kind = "blob 경로" if blob else "manifest"
            print(f"[PROGRESS +{elapsed}s] {kind}: {host} (redirect {hop}/7)", flush=True)
            headers = {"Accept": ACCEPT, "User-Agent": "sadp-registry-discovery"}
            if blob:
                headers["Range"] = "bytes=0-0"
            try:
                response = self.opener.open(urllib.request.Request(url, headers=headers), timeout=REQUEST_TIMEOUT)
            except urllib.error.HTTPError as error:
                response = error
            except (OSError, urllib.error.URLError):
                raise DiscoveryError("직접 HTTPS 탐지 실패: Squid 호스트의 외부 연결을 확인하세요") from None
            with response:
                if response.status in (301, 302, 303, 307, 308):
                    location = response.headers.get("Location")
                    if not location:
                        raise DiscoveryError("Location 없는 redirect")
                    url = urllib.parse.urljoin(url, location)
                    continue
                if response.status not in ((200, 206) if blob else (200,)):
                    raise DiscoveryError(f"직접 탐지 HTTP {response.status}: 자동 허용하지 않음")
                # 레이어는 경로만 확인한다. 최종 전량 다운로드 검증은 실제 CRI pull이 맡는다.
                body = response.read(1 if blob else MAX_BODY + 1)
                if len(body) > MAX_BODY:
                    raise DiscoveryError("manifest 크기 제한 초과")
                return body
        raise DiscoveryError("redirect 횟수 제한 초과")


def digest(value):
    if not isinstance(value, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise DiscoveryError("manifest descriptor digest 형식 오류")
    return value


def discover(fetcher, architectures):
    def manifest(value):
        value = digest(value)
        body = fetcher.get(BASE + "manifests/" + value)
        if "sha256:" + hashlib.sha256(body).hexdigest() != value:
            raise DiscoveryError("manifest digest 불일치: 탐지 결과 폐기")
        return json.loads(body)

    index = manifest(DIGEST)
    entries = [entry for entry in index.get("manifests", [])
               if entry.get("platform", {}).get("os") == "linux"
               and entry.get("platform", {}).get("architecture") in architectures]
    present = {entry["platform"]["architecture"] for entry in entries}
    if present != architectures or len(entries) > 32:
        raise DiscoveryError("고정 이미지에 요청한 Linux 아키텍처의 manifest가 없습니다")
    blobs = set()
    for number, entry in enumerate(entries, 1):
        print(f"[PROGRESS] Linux manifest {number}/{len(entries)}: {entry['platform']['architecture']}", flush=True)
        child = manifest(entry["digest"])
        descriptors = [child["config"], *child["layers"]]
        if len(descriptors) > 64:
            raise DiscoveryError("레이어 개수 제한 초과")
        blobs.update(digest(item["digest"]) for item in descriptors)
    for number, value in enumerate(sorted(blobs), 1):
        print(f"[PROGRESS] config/layer 경로 {number}/{len(blobs)}", flush=True)
        fetcher.get(BASE + "blobs/" + value, blob=True)
    return fetcher.observed


def command(args):
    # 외부 명령 stderr에는 URL query나 사이트 값이 포함될 수 있어 그대로 출력하지 않는다.
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise DiscoveryError(f"{Path(args[0]).name} 실행 실패: 적용/설정 상태를 확인하세요")
    return result


def denied_hosts(text):
    result = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 7 and fields[3] == "TCP_DENIED/403" and fields[5] == "CONNECT":
            match = re.fullmatch(r"([a-z0-9.-]+):443", fields[6])
            if match:
                result.add(match[1])
    return result


def covered(host, domains):
    return any(host == item or (item.startswith(".") and
               (host == item[1:] or host.endswith(item))) for item in domains)


def proxy_probe(proxy, url):
    # 사용자 curlrc의 retry/proxy/output 설정이 검사 의미와 대기 시간을 바꾸지 않게 한다.
    args = ["curl", "--disable", "--silent", "--show-error", "--head",
            "--max-time", str(REQUEST_TIMEOUT), "--proxy", proxy, "--noproxy", "",
            "--output", os.devnull, "--write-out", "%{http_connect} %{http_code}", url]
    try:
        return subprocess.run(args, capture_output=True, text=True,
                              timeout=REQUEST_TIMEOUT + 5, check=False)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 28, stdout="000 000", stderr="")


def proxy_codes(result):
    match = re.fullmatch(r"\s*([0-9]{3}) ([0-9]{3})\s*", result.stdout or "")
    return match.groups() if match else ("000", "000")


def verify_proxy_paths(observed, proxy, reloaded=False):
    for host, url in observed.items():
        # reload 직후 기존 worker가 잠시 이전 ACL을 사용할 수 있지만 다른 오류는 숨기지 않는다.
        attempts = 3 if reloaded else 1
        for attempt in range(1, attempts + 1):
            print(f"[PROGRESS] 적용 후 proxy 재검사: {host} ({attempt}/{attempts})", flush=True)
            result = proxy_probe(proxy, url)
            connect, http = proxy_codes(result)
            if result.returncode == 0 and connect == "200":
                print(f"[OK] {host}: CONNECT={connect}, HTTP={http} (CRI 성공과 별도)", flush=True)
                break
            if connect == "403" and attempt < attempts:
                print(f"[INFO] {host}: CONNECT=403, reload ACL 반영 재확인 (1초 뒤)", flush=True)
                time.sleep(1)
                continue
            reason = {
                5: "proxy 이름 해석 실패", 6: "목적지 이름 해석 실패", 7: "TCP 연결 실패",
                28: "연결/응답 시간 초과", 35: "TLS 연결 실패", 56: "응답 수신 실패",
                60: "TLS 인증서 검증 실패",
            }.get(result.returncode, "proxy/HTTPS 응답 확인 필요")
            if connect == "403":
                reason = "proxy CONNECT 거부: 새 TCP_DENIED와 실행 중 ACL 확인 필요"
            raise DiscoveryError(
                f"proxy 검증 실패: {host}, CONNECT={connect}, HTTP={http}, curl_exit={result.returncode} ({reason})"
                "\n[INFO] 적용된 설정은 유지됩니다. 긴 탐지를 반복하기 전에 실제 CRI pull 결과를 확인하세요."
                "\n[NEXT] control-plane에서 bash ./sadp --preflight --image-pull-only"
            )


def candidates(observed, domains, proxy, access_log):
    missing = {host: url for host, url in observed.items() if not covered(host, domains)}
    if not missing:
        return []
    before = access_log.stat()
    with access_log.open() as stream:
        stream.seek(0, 2)
        refused = set()
        for host, url in missing.items():
            print(f"[PROGRESS] Squid CONNECT/새 차단 로그 확인: {host}", flush=True)
            # 이번 요청의 새 CONNECT 로그만 대조해 오래된 거부를 근거로 삼지 않는다.
            result = proxy_probe(proxy, url)
            if proxy_codes(result)[0] == "403":
                refused.add(host)
        found = set()
        for _ in range(20):
            now = access_log.stat()
            if (before.st_ino, before.st_dev) != (now.st_ino, now.st_dev) or now.st_size < before.st_size:
                raise DiscoveryError("검사 중 Squid 로그 회전: 다시 탐지하세요")
            found.update(denied_hosts(stream.read()))
            if set(missing) <= found & refused:
                return sorted(missing)
            time.sleep(0.1)
    raise DiscoveryError("탐지 호스트 일부의 새 TCP_DENIED 증거 없음: upstream 403/프록시 경로를 확인하세요")


def append_domains(text, hosts):
    document = yaml.safe_load(text)
    expected = copy.deepcopy(document)
    expected["spec"]["network"]["squid"]["packageDomains"].extend(hosts)
    # 전체 YAML 직렬화로 주석과 다른 설정을 재작성하지 않는다.
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if re.fullmatch(r"\s+packageDomains:\s*\n?", line)]
    if len(starts) != 1:
        raise DiscoveryError("packageDomains 블록 형식 오류")
    start = starts[0] + 1
    end = start
    while end < len(lines) and re.match(r"\s+- ", lines[end]):
        end += 1
    if end == start:
        raise DiscoveryError("packageDomains 목록 형식 오류")
    indent = re.match(r"\s*", lines[start]).group()
    lines[end:end] = [f"{indent}- {host}\n" for host in hosts]
    updated = "".join(lines)
    if yaml.safe_load(updated) != expected:
        raise DiscoveryError("허용 목록 외 계약 변경 감지")
    return updated


def upstream_updates(contract_path, env_file, hosts):
    original = contract_path.read_text()
    document = yaml.safe_load(original)
    updates = {contract_path: append_domains(original, hosts)}
    if env_file is not None:
        configure = module("registry_configure", "scripts/site/configure-site.py")
        values = configure.parse_env(env_file)
        current = configure.build_contract(document, configure.validate(values))
        if current != document:
            raise DiscoveryError("site.env와 계약이 다릅니다. 먼저 기존 설정을 동기화하세요")
        extras = [item.strip() for item in values.get("EXTRA_PACKAGE_DOMAINS", "").split(",") if item.strip()]
        extras = list(dict.fromkeys([*extras, *hosts]))
        values["EXTRA_PACKAGE_DOMAINS"] = ",".join(extras)
        if len(values["EXTRA_PACKAGE_DOMAINS"]) > 2048:
            raise DiscoveryError("EXTRA_PACKAGE_DOMAINS 길이 제한 초과")
        text = env_file.read_text()
        line = "EXTRA_PACKAGE_DOMAINS=" + values["EXTRA_PACKAGE_DOMAINS"]
        pattern = r"(?m)^\s*(?:export\s+)?EXTRA_PACKAGE_DOMAINS\s*=.*$"
        text = re.sub(pattern, lambda _: line, text) if re.search(pattern, text) else text.rstrip() + "\n" + line + "\n"
        # 기존 확장 목록을 지우거나 다음 configure-site에서 되돌아갈 변경은 거부한다.
        rendered = configure.build_contract(document, configure.validate(values))
        if rendered != yaml.safe_load(updates[contract_path]):
            raise DiscoveryError("site.env 재생성 결과가 허용 목록 변경과 다릅니다")
        updates[env_file] = text
    return updates


def apply_updates(updates, installed):
    snapshots = {path: path.read_bytes() for path in [*updates, installed]}
    with tempfile.TemporaryDirectory(prefix="sadp-registry-stage-") as stage:
        staged = Path(stage) / "squid.conf"
        staged.write_text(updates[ROOT / "platform/network/squid/squid.conf"])
        command(["squid", "-k", "parse", "-f", str(staged)])
        try:
            for path, content in updates.items():
                path.write_text(content)
            installed.write_text(staged.read_text())
            command(["squid", "-k", "parse", "-f", str(installed)])
            command(["systemctl", "reload", "squid"])
            command(["systemctl", "is-active", "--quiet", "squid"])
        except BaseException:
            for path, content in snapshots.items():
                path.write_bytes(content)
            try:
                command(["systemctl", "reload", "squid"])
            except DiscoveryError:
                print("[FAIL] 파일 복원 후 Squid reload 실패: 수동 복구 필요", file=sys.stderr)
            raise



def check_network_outputs(outputs):
    stale = [str(path.relative_to(ROOT)) for path, content in outputs.items()
             if not path.is_file() or path.read_text() != content]
    if stale:
        raise DiscoveryError(
            "네트워크 생성물 불일치:\n  " + "\n  ".join(stale)
            + "\n[NEXT] bash ./sadp --render-network --check"
            + "\n[NEXT] site.env/계약의 현재 설정을 확인한 뒤 bash ./sadp --render-network"
            + "\n[INFO] Git clean 여부와 계약↔생성물 동기화 여부는 별개입니다. 설정은 변경하지 않았습니다."
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="상류/생성물 반영, Squid reload, 가능한 경우 CRI 재검사")
    parser.add_argument("--env-file", type=Path, help="외부 site.env 경로 (기본 environments/site.env 자동 확인)")
    parser.add_argument("--timeout", type=positive_seconds, default=90, help="탐지 단계 전체 제한 초 (기본 90, 적용/CRI 검사 제외)")
    parser.add_argument("--architectures", type=architecture_list, help="Linux 아키텍처 CSV (기본 클러스터 노드 조회, 별도 Squid는 로컬)")
    parser.add_argument("--allow-dirty", action="store_true", help="기존 worktree 변경 검토 후 적용 허용")
    args = parser.parse_args(argv)
    lock = None
    try:
        if os.geteuid() != 0:
            raise DiscoveryError("Squid 호스트에서 sudo로 실행하세요 (access.log 대조 필요)")
        env_file = args.env_file or ROOT / "environments/site.env"
        if args.env_file and not env_file.is_file():
            raise DiscoveryError("지정한 site.env 없음")
        env_file = env_file.resolve() if env_file.exists() else None
        if args.apply:
            lock = APPLY_LOCK.open("a")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise DiscoveryError("다른 registry egress 적용이 진행 중입니다") from None
        renderer = module("registry_network", "scripts/site/render-network.py")
        contract_path = ROOT / "contracts/platform-production.yaml"
        document = yaml.safe_load(contract_path.read_text())
        outputs = renderer.rendered(document["spec"])
        check_network_outputs(outputs)
        installed = INSTALLED_SQUID
        if installed.read_text() != outputs[ROOT / "platform/network/squid/squid.conf"]:
            raise DiscoveryError("설치된 Squid 설정 불일치: 먼저 --install-squid로 동기화하세요")
        baseline = {path: path.read_bytes() for path in [contract_path, installed, *outputs]}
        if env_file is not None:
            baseline[env_file] = env_file.read_bytes()
        command(["systemctl", "is-active", "--quiet", "squid"])
        squid = document["spec"]["network"]["squid"]
        proxy = f"http://{squid['internalIP']}:{squid['port']}"
        print(f"[INFO] 고정 pause 이미지 redirect 탐지 시작 (전체 제한 {args.timeout}초)", flush=True)
        with discovery_deadline(args.timeout):
            architectures = select_architectures(args.architectures)
            print("[INFO] 탐지 아키텍처: " + ", ".join(sorted(architectures)), flush=True)
            observed = discover(Fetcher(), architectures)
            hosts = candidates(observed, squid["packageDomains"], proxy, ACCESS_LOG)
        if any(path.read_bytes() != content for path, content in baseline.items()):
            raise DiscoveryError("탐지 중 설정 변경 감지: 다시 실행하세요")
        updates = upstream_updates(contract_path, env_file, hosts) if hosts else {}
        for host in hosts:
            print(f"[CANDIDATE] {host} (고정 이미지 경로 + 새 TCP_DENIED)")
        print(f"[INFO] 탐지 호스트 {len(observed)}개, 추가 후보 {len(hosts)}개")
        if not args.apply:
            print("[PLAN] 설정 변경 없음. 후보 검토 후 같은 인자에 --apply를 추가하세요")
            return 0
        if hosts:
            if not args.allow_dirty:
                status = command(["git", "status", "--porcelain"])
                if status.stdout.strip():
                    raise DiscoveryError("worktree가 dirty입니다. 기존 변경 검토 후 --allow-dirty를 명시하세요")
            updates.update(renderer.rendered(yaml.safe_load(updates[contract_path])["spec"]))
            apply_updates(updates, installed)
            print("[OK] 상류와 생성물 반영·Squid reload 완료 (RKE2 재시작 없음)")
        proxy_error = None
        try:
            verify_proxy_paths(observed, proxy, reloaded=bool(hosts))
            print("[OK] 탐지한 호스트의 proxy CONNECT 통과 (실제 CRI 성공과 별도)")
        except DiscoveryError as error:
            # 보조 HEAD 검사가 실패해도 최종 판단 근거인 실제 CRI pull은 실행한다.
            proxy_error = error
            print("[WARN] " + str(error), flush=True)
        if KUBECTL.is_file() and KUBECONFIG.is_file():
            print("[PROGRESS] 모든 Linux 노드 CRI pull 확인 (rollout 대기 최대 180초)", flush=True)
            result = subprocess.run(["bash", str(ROOT / "sadp"), "--preflight", "--image-pull-only"], cwd=ROOT)
            if result.returncode:
                raise DiscoveryError("CRI pull 실패: 유효한 허용 목록은 유지됩니다. 노드별 경로를 확인하세요")
            if proxy_error:
                print("[OK] 실제 CRI pull 성공으로 최종 검증 통과. 보조 proxy 진단 경고는 별도로 확인하세요.")
        else:
            if proxy_error:
                raise proxy_error
            print("[NEXT] CRI 미검증: control-plane에서 sudo bash ./sadp --preflight --image-pull-only")
        return 0
    except (DiscoveryError, OSError, ValueError, KeyError, TypeError, argparse.ArgumentTypeError, yaml.YAMLError,
            subprocess.SubprocessError):
        # 원래 예외의 URL/환경값을 출력하지 않되 안전한 자체 진단은 유지한다.
        error = sys.exc_info()[1]
        print("[FAIL] " + (str(error) if isinstance(error, DiscoveryError) else
                          "탐지/설정 처리 실패: 입력 형식, 파일 접근 권한과 도구 설치를 확인하세요"), file=sys.stderr)
        return 1
    finally:
        if lock is not None:
            lock.close()


if __name__ == "__main__":
    raise SystemExit(main())
