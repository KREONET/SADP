#!/usr/bin/env python3
"""verify-idp-discovery.sh와 공용 discovery 대조 함수 회귀(VI-01~).

curl을 PATH mock으로 바꿔 네트워크 없이 돈다. mock은 받은 URL·--proxy·proxy 환경변수를 기록하고
준비한 discovery 문서를 돌려준다. 값과 응답 본문이 출력에 새지 않는지도 함께 본다.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
EXAMPLE = (ROOT / "environments/site.env.example").read_text(encoding="utf-8")
PASSED = 0
FAILED = 0

MOCK_CURL = r"""#!/usr/bin/env bash
out= proxy= url=
while (($#)); do
  case "$1" in
    --output) out=$2; shift ;;
    --proxy) proxy=$2; shift ;;
    --write-out|--connect-timeout|--max-time|--proto) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
{
  printf 'url=%s\n' "${url}"
  printf 'proxy=%s\n' "${proxy}"
  printf 'env_proxy=%s\n' "${HTTPS_PROXY:-}${https_proxy:-}${ALL_PROXY:-}${all_proxy:-}"
} >>"${MOCK_CURL_LOG}"
if [[ ${MOCK_CURL_EXIT:-0} != 0 ]]; then
  printf 'curl: (%s) Failed to connect to leaked-host.example.invalid port 443\n' "${MOCK_CURL_EXIT}" >&2
  exit "${MOCK_CURL_EXIT}"
fi
cat "${MOCK_CURL_BODY}" >"${out}"
printf '%s' "${MOCK_CURL_STATUS:-200}"
"""


def env_values(text: str) -> dict[str, str]:
    values = {}
    for line in text.splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key] = value
    return values


def replace(text: str, **changes: str) -> str:
    lines = []
    seen = set()
    for line in text.splitlines():
        key = line.partition("=")[0]
        if key in changes and not line.startswith("#"):
            lines.append(f"{key}={changes[key]}")
            seen.add(key)
        else:
            lines.append(line)
    lines += [f"{key}={value}" for key, value in changes.items() if key not in seen]
    return "\n".join(lines) + "\n"


def discovery(env_text: str, **overrides) -> dict:
    values = env_values(env_text)
    document = {
        "issuer": values["OIDC_ISSUER"],
        "authorization_endpoint": values["OIDC_AUTHORIZATION_ENDPOINT"],
        "token_endpoint": values["OIDC_TOKEN_ENDPOINT"],
        "jwks_uri": values["OIDC_JWKS_URI"],
        "userinfo_endpoint": "https://idp.example.invalid/application/o/userinfo/",
    }
    if values.get("OIDC_END_SESSION_ENDPOINT"):
        document["end_session_endpoint"] = values["OIDC_END_SESSION_ENDPOINT"]
    document.update(overrides)
    return {key: value for key, value in document.items() if value is not None}


def run(
    work: pathlib.Path,
    env_text: str | None,
    body: object,
    *,
    status: str = "200",
    curl_exit: str = "0",
    extra_env: dict[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess, list[dict[str, str]]]:
    bin_dir = work / "bin"
    bin_dir.mkdir(exist_ok=True)
    curl = bin_dir / "curl"
    curl.write_text(MOCK_CURL, encoding="utf-8")
    curl.chmod(0o755)
    log = work / "curl.log"
    log.unlink(missing_ok=True)
    body_file = work / "body.json"
    body_file.write_text(body if isinstance(body, str) else json.dumps(body), encoding="utf-8")
    command = ["bash", str(ROOT / "scripts/verify/verify-idp-discovery.sh")]
    if env_text is not None:
        env_file = work / "site.env"
        env_file.write_text(env_text, encoding="utf-8")
        command += ["--env-file", str(env_file)]
    environment = dict(os.environ)
    for key in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"):
        environment.pop(key, None)
    environment.update(
        {
            "PATH": f"{bin_dir}:{environment['PATH']}",
            "MOCK_CURL_LOG": str(log),
            "MOCK_CURL_BODY": str(body_file),
            "MOCK_CURL_STATUS": status,
            "MOCK_CURL_EXIT": curl_exit,
            **(extra_env or {}),
        }
    )
    result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True, check=False)
    calls = []
    if log.exists():
        current: dict[str, str] = {}
        for line in log.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            current[key] = value
            if key == "env_proxy":
                calls.append(current)
                current = {}
    return result, calls


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


def leaks(output: str) -> bool:
    # site.env 값, 응답 본문, curl 오류 원문 어느 것도 출력되면 안 된다.
    return any(
        marker in output
        for marker in ("idp.example.invalid", "wrong.example.invalid", "leaked-host", "userinfo")
    )


EXPECTED_URL = "https://idp.example.invalid/application/o/sadp/.well-known/openid-configuration"

with tempfile.TemporaryDirectory(prefix="verify-idp-test-") as raw:
    work = pathlib.Path(raw)

    result, calls = run(work, EXAMPLE, discovery(EXAMPLE))
    output = result.stdout + result.stderr
    check(
        "VI-01 discovery와 site.env가 정확히 같으면 통과(끝 '/' issuer 보존, 이중 '/' 없음)",
        result.returncode == 0
        and "[OK]" in output
        and calls == [{"url": EXPECTED_URL, "proxy": "", "env_proxy": ""}]
        and "직접 연결" in output
        and not leaks(output),
        output + f"\ncalls={calls}",
    )

    result, _ = run(
        work,
        EXAMPLE,
        discovery(EXAMPLE, token_endpoint="https://wrong.example.invalid/application/o/token/"),
    )
    output = result.stdout + result.stderr
    check(
        "VI-02 token_endpoint 불일치는 필드 이름만 알리고 값·본문은 출력하지 않음",
        result.returncode != 0
        and "불일치 필드: token_endpoint" in output
        and "issuer" not in output.split("불일치 필드:", 1)[1].splitlines()[0]
        and not leaks(output),
        output,
    )

    result, _ = run(
        work, EXAMPLE, discovery(EXAMPLE, issuer="https://idp.example.invalid/application/o/sadp")
    )
    output = result.stdout + result.stderr
    check(
        "VI-03 discovery issuer가 끝 '/'만 달라도 issuer 불일치",
        result.returncode != 0 and "불일치 필드: issuer" in output and not leaks(output),
        output,
    )

    no_slash = replace(EXAMPLE, OIDC_ISSUER="https://idp.example.invalid/application/o/sadp")
    result, calls = run(work, no_slash, discovery(EXAMPLE))
    output = result.stdout + result.stderr
    check(
        "VI-04 site.env issuer가 끝 '/'를 빠뜨려도 정규화하지 않고 불일치로 거부",
        result.returncode != 0
        and "불일치 필드: issuer" in output
        and calls
        and calls[0]["url"] == EXPECTED_URL,
        output + f"\ncalls={calls}",
    )

    proxied = replace(EXAMPLE, HTTPS_PROXY="http://10.20.30.11:3128")
    result, calls = run(
        work,
        proxied,
        discovery(EXAMPLE),
        extra_env={"HTTPS_PROXY": "http://caller.example.invalid:9999", "ALL_PROXY": "socks5://x:1"},
    )
    output = result.stdout + result.stderr
    check(
        "VI-05 site.env HTTPS_PROXY만 쓰고 호출 셸의 proxy 환경변수는 무시",
        result.returncode == 0
        and calls == [{"url": EXPECTED_URL, "proxy": "http://10.20.30.11:3128", "env_proxy": ""}]
        and "HTTPS_PROXY 경유" in output
        and "10.20.30.11" not in output,
        output + f"\ncalls={calls}",
    )

    result, _ = run(work, proxied, discovery(EXAMPLE), curl_exit="56")
    output = result.stdout + result.stderr
    check(
        "VI-06 proxy CONNECT 거부는 Squid allowlist 안내로 분류하고 curl 원문은 숨김",
        result.returncode != 0 and "CONNECT를 거부" in output and not leaks(output),
        output,
    )

    result, _ = run(work, EXAMPLE, discovery(EXAMPLE), curl_exit="7")
    output = result.stdout + result.stderr
    check(
        "VI-07 직접 연결 실패는 폐쇄망 HTTPS_PROXY 안내로 분류",
        result.returncode != 0 and "HTTPS_PROXY" in output and not leaks(output),
        output,
    )

    result, _ = run(work, EXAMPLE, {"error": "not found"}, status="404")
    output = result.stdout + result.stderr
    check(
        "VI-08 HTTP 오류는 status만 출력",
        result.returncode != 0 and "status=404" in output and "not found" not in output,
        output,
    )

    result, _ = run(work, EXAMPLE, "<html>login</html>")
    output = result.stdout + result.stderr
    check(
        "VI-09 JSON이 아닌 응답은 본문 없이 거부",
        result.returncode != 0 and "JSON 객체가 아님" in output and "login" not in output,
        output,
    )

    with_logout = replace(
        EXAMPLE, OIDC_END_SESSION_ENDPOINT="https://idp.example.invalid/application/o/sadp/end-session/"
    )
    result, _ = run(
        work,
        with_logout,
        discovery(
            with_logout,
            end_session_endpoint="https://idp.example.invalid/application/o/other/end-session/",
        ),
    )
    output = result.stdout + result.stderr
    check(
        "VI-10 end_session_endpoint를 지정했으면 함께 대조",
        result.returncode != 0 and "불일치 필드: end_session_endpoint" in output and not leaks(output),
        output,
    )

    result, _ = run(
        work,
        EXAMPLE,
        discovery(EXAMPLE, end_session_endpoint="https://idp.example.invalid/end-session/"),
    )
    output = result.stdout + result.stderr
    check(
        "VI-11 site.env가 end_session을 비우고 discovery만 공개하면 [WARN] 후 통과",
        result.returncode == 0 and "[WARN]" in output and "end_session_endpoint" in output,
        output,
    )

    result, calls = run(work, None, discovery(EXAMPLE))
    output = result.stdout + result.stderr
    check(
        "VI-12 --env-file 없으면 자동 탐색 없이 두 후보 경로를 안내",
        result.returncode != 0
        and "environments/site.env" in output
        and "/etc/sadp/site.env" in output
        and not calls,
        output,
    )

    bad = replace(EXAMPLE, OIDC_TOKEN_ENDPOINT="https://idp.sadp-portalnet/application/o/token/")
    result, calls = run(work, bad, discovery(EXAMPLE))
    output = result.stdout + result.stderr
    check(
        "VI-13 오프라인 검증 실패면 외부 요청 전에 중단",
        result.returncode != 0 and "PORTAL_OIDC_CLIENT_ID" in output and not calls,
        output + f"\ncalls={calls}",
    )

portal = (ROOT / "scripts/verify/verify-portal-auth.sh").read_text(encoding="utf-8")
check(
    "VI-14 verify-portal-auth는 같은 공용 대조 함수를 쓰고 issuer를 정규화하지 않음",
    "lib/oidc-discovery.sh" in portal
    and "sadp_oidc_discovery_verify" in portal
    and "openid-configuration" not in portal
    and "[4]%/}" not in portal,
)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
