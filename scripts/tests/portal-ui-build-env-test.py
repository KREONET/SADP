#!/usr/bin/env python3
"""Portal UI 공개 빌드 환경 파서 회귀 시험."""

from __future__ import annotations

import base64
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "site" / "portal-ui-build-env.py"
WRAPPER = ROOT / "apps" / "portal-lite" / "ui" / "scripts" / "with-root-build-env.mjs"


def run(env_file: pathlib.Path, output_format: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--env-file", str(env_file), "--format", output_format],
        capture_output=True,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="portal-ui-build-env-test-") as directory:
        env_file = pathlib.Path(directory) / ".env"
        env_file.write_text(
            """# 공개값만 빌드로 나가야 한다.
NEXT_PUBLIC_PAAS_VERSION="v9 test"
NEXT_PUBLIC_PAAS_APP_DOMAIN=apps.example.invalid
AUTH_SECRET=never-print-this-value
FORGEJO_BOT_TOKEN=also-never-print-this-value
""",
            encoding="utf-8",
        )

        nul_result = run(env_file, "nul")
        if nul_result.returncode != 0:
            print(nul_result.stderr.decode("utf-8", errors="replace"), file=sys.stderr)
            return 1
        assignments = nul_result.stdout.rstrip(b"\0").split(b"\0")
        if assignments != [
            b"NEXT_PUBLIC_PAAS_VERSION=v9 test",
            b"NEXT_PUBLIC_PAAS_APP_DOMAIN=apps.example.invalid",
        ]:
            print("[FAIL] UI 공개 변수 선택 결과 불일치", file=sys.stderr)
            return 1
        if b"never-print" in nul_result.stdout or b"never-print" in nul_result.stderr:
            print("[FAIL] 비공개 값이 파서 출력에 노출됨", file=sys.stderr)
            return 1

        base64_result = run(env_file, "base64")
        decoded = base64.b64decode(base64_result.stdout)
        if decoded != (
            b'NEXT_PUBLIC_PAAS_VERSION="v9 test"\n'
            b'NEXT_PUBLIC_PAAS_APP_DOMAIN="apps.example.invalid"\n'
        ):
            print("[FAIL] Docker용 dotenv 결과 불일치", file=sys.stderr)
            return 1
        if b"AUTH_SECRET" in decoded or b"FORGEJO_BOT_TOKEN" in decoded:
            print("[FAIL] Docker용 dotenv에 비공개 key가 포함됨", file=sys.stderr)
            return 1

        wrapper_env = os.environ.copy()
        wrapper_env["PORTAL_UI_ROOT_ENV_FILE"] = str(env_file)
        wrapper_env.pop("AUTH_SECRET", None)
        # node 는 nvm 아래 설치되는 일이 많아 sudo 의 secure_path 에서 사라진다.
        # build-local-images.sh 가 root 로 이 시험을 부르므로, 없으면 traceback 으로
        # 죽는 대신 이 항목만 건너뛴다. 파서 자체 검증은 위에서 이미 끝났다.
        # 건너뛴 검사를 [OK]로 세면 node 없는 환경에서 래퍼 회귀가 통과로 보인다. 그래서
        # 별도 항목으로 [SKIP]과 사유를 남긴다.
        node_bin = shutil.which("node")
        wrapper_result = "[SKIP] PE-02 로컬 npm 래퍼 공개값 상속: node 없음(PATH에 node를 두고 재실행)"
        if node_bin is not None:
            wrapper_result = "[OK]   PE-02 로컬 npm 래퍼는 공개값만 상속"
            wrapped = subprocess.run(
                [
                    node_bin,
                    str(WRAPPER),
                    "bash",
                    "-c",
                    'printf "%s|%s" "$NEXT_PUBLIC_PAAS_VERSION" "${AUTH_SECRET:-}"',
                ],
                capture_output=True,
                env=wrapper_env,
            )
            if wrapped.returncode != 0 or wrapped.stdout != b"v9 test|":
                print(
                    "[FAIL] 로컬 npm 래퍼의 공개값 상속/비공개값 차단 실패 "
                    f"(exit={wrapped.returncode}, stderr={wrapped.stderr.decode('utf-8', errors='replace').strip()})",
                    file=sys.stderr,
                )
                return 1

        env_file.write_text("NEXT_PUBLIC_UNKNOWN=value\n", encoding="utf-8")
        unknown = run(env_file, "check")
        if unknown.returncode == 0:
            print("[FAIL] 알 수 없는 NEXT_PUBLIC 변수를 허용함", file=sys.stderr)
            return 1

        env_file.write_text("NEXT_PUBLIC_PAAS_VERSION=${UNSAFE}\n", encoding="utf-8")
        interpolation = run(env_file, "check")
        if interpolation.returncode == 0:
            print("[FAIL] 공개 변수의 치환 문자를 허용함", file=sys.stderr)
            return 1

    print("[OK]   PE-01 루트 .env에서 허용된 Portal UI 공개값만 추출")
    print(wrapper_result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
