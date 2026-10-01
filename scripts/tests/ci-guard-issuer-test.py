#!/usr/bin/env python3
"""ci-guard의 OIDC issuer 정규화 차단 회귀(CG-01~).

실제 장애: configure-site.py와 openbao-oidc.sh가 issuer 끝 '/'를 rstrip해 Authentik issuer에서
OpenBao discovery issuer 비교, Envoy JWT iss, Auth.js가 모두 불일치했다. 같은 코드가 다시
들어오면 ci-guard가 막는지, discovery URL을 만드는 정상 코드는 막지 않는지 본다.

suite가 공유하는 fixture를 더럽히지 않도록 이 시험만의 fixture를 따로 만든다.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sadp_test_fixture  # noqa: E402


PASSED = 0
FAILED = 0

# 금지 사례: 파일마다 한 줄씩 넣고 ci-guard가 정확히 이 파일들만 지목하는지 본다.
FORBIDDEN = {
    "scripts/lib/cg-python-rstrip.py": 'issuer = str(identity.get("issuer") or "").rstrip("/")\n',
    "scripts/lib/cg-python-removesuffix.py": "issuer = raw_issuer.removesuffix('/')\n",
    "apps/portal-lite/backend/cg_trimsuffix.go": 'var issuer = strings.TrimSuffix(cfg.Issuer, "/")\n',
    "apps/portal-lite/backend/cg_trimright.go": 'issuerURL := strings.TrimRight(raw, "/") // issuer\n',
    "apps/portal-lite/ui/cg-replace.ts": 'const issuer = env.AUTH_OIDC_ISSUER.replace(/\\/+$/, "");\n',
    "scripts/verify/cg-bash.sh": "issuer=${contract_values[4]%/}\n",
}
# 허용 사례: discovery URL만 끝 '/'를 떼고 만드는 코드, issuer와 무관한 URL 정리.
ALLOWED = {
    "scripts/lib/cg-discovery-url.sh": (
        'OIDC_DISCOVERY_URL="${OIDC_EXPECTED_ISSUER%/}/.well-known/openid-configuration"\n'
        "printf '%s/.well-known/openid-configuration' \"${issuer%/}\"\n"
    ),
    "apps/portal-lite/backend/cg_registry.go": 'base := strings.TrimRight(registryBase, "/")\n',
    "scripts/lib/cg-hostname.py": 'host = raw.strip().lower().rstrip(".")\n',
}


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


def run_guard(root: pathlib.Path) -> tuple[int, str, set[str]]:
    result = subprocess.run(
        ["bash", "scripts/ci-guard.sh"], cwd=root, capture_output=True, text=True, check=False
    )
    output = result.stdout + result.stderr
    flagged = set()
    capture = False
    for line in output.splitlines():
        if line.startswith("[FAIL] OIDC issuer를"):
            capture = True
            continue
        if capture:
            if not line.startswith("         "):
                break
            flagged.add(line.strip().rsplit(":", 1)[0])
    return result.returncode, output, flagged


root = sadp_test_fixture.build()
try:
    for relative, content in {**FORBIDDEN, **ALLOWED}.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    code, output, flagged = run_guard(root)
    check(
        "CG-01 issuer 끝 '/' 제거(rstrip/removesuffix/TrimSuffix/TrimRight/replace/bash %/)를 모두 차단",
        code != 0 and flagged == set(FORBIDDEN),
        f"flagged={sorted(flagged)}",
    )
    check(
        "CG-02 discovery URL 생성·issuer 무관 URL 정리는 차단하지 않음",
        not (flagged & set(ALLOWED)),
        f"flagged={sorted(flagged)}",
    )
    check(
        "CG-03 차단 출력은 file:line만 보이고 코드 원문을 옮기지 않음",
        "TrimSuffix(cfg.Issuer" not in output and "contract_values[4]" not in output,
        output,
    )
    for relative in FORBIDDEN:
        (root / relative).unlink()
    code, output, flagged = run_guard(root)
    check(
        "CG-04 금지 코드를 지우면 issuer 검사는 통과",
        "[OK]   OIDC issuer 정규화 코드 없음" in output and not flagged,
        output[-2000:],
    )
finally:
    sadp_test_fixture.remove(root)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
