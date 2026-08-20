#!/usr/bin/env python3
"""루트 .env에서 Portal UI 빌드에 공개해도 되는 값만 추출한다."""

from __future__ import annotations

import argparse
import base64
import json
import pathlib
import re
import sys


ENV_KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")
ROOT = pathlib.Path(__file__).resolve().parents[2]
KEYS_FILE = ROOT / "apps/portal-lite/ui/scripts/portal-ui-public-env-keys.json"
ALLOWED_KEYS = tuple(json.loads(KEYS_FILE.read_text(encoding="utf-8")))
ALLOWED_KEY_SET = frozenset(ALLOWED_KEYS)


class BuildEnvError(ValueError):
    """빌드 환경파일이 안전한 제한 형식이 아닐 때 발생한다."""


def parse_env(path: pathlib.Path) -> dict[str, str]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise BuildEnvError(f"빌드 환경파일을 읽을 수 없음: {error}") from error
    if len(raw) > 64 * 1024:
        raise BuildEnvError("빌드 환경파일은 64 KiB를 넘을 수 없음")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise BuildEnvError("빌드 환경파일은 UTF-8이어야 함") from error

    parsed: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not ENV_KEY.fullmatch(key):
            raise BuildEnvError(f"line {line_number}: UPPER_CASE_KEY=value 형식이 필요함")
        if key in parsed:
            raise BuildEnvError(f"line {line_number}: 중복 key {key}")

        value = value.strip()
        if value[:1] in {"'", '"'}:
            if len(value) < 2 or value[-1] != value[0]:
                raise BuildEnvError(f"line {line_number}: {key} 따옴표가 닫히지 않음")
            value = value[1:-1]
        if "\x00" in value or "\r" in value or "\n" in value:
            raise BuildEnvError(f"line {line_number}: {key}에 제어 문자가 있음")
        if len(value) > 2048:
            raise BuildEnvError(f"line {line_number}: {key} 값이 너무 김")
        parsed[key] = value

    unknown_public = sorted(
        key for key in parsed if key.startswith("NEXT_PUBLIC_") and key not in ALLOWED_KEY_SET
    )
    if unknown_public:
        raise BuildEnvError("허용되지 않은 Portal UI 공개 변수: " + ", ".join(unknown_public))

    selected = {key: parsed[key] for key in ALLOWED_KEYS if key in parsed}
    for key, value in selected.items():
        # dotenv 확장과 셸 해석 차이로 빌드마다 값이 달라지는 것을 막는다.
        if "$" in value or "`" in value:
            raise BuildEnvError(f"{key}에는 변수/명령 치환 문자를 쓸 수 없음")
    return selected


def dotenv_bytes(values: dict[str, str]) -> bytes:
    # JSON 문자열 표기는 dotenv의 double-quoted value와 호환되고 공백·#·따옴표를 보존한다.
    lines = [f"{key}={json.dumps(values[key], ensure_ascii=False)}" for key in ALLOWED_KEYS if key in values]
    return (("\n".join(lines) + "\n") if lines else "").encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", required=True, type=pathlib.Path)
    parser.add_argument("--format", choices=("check", "nul", "base64"), default="check")
    args = parser.parse_args()

    try:
        values = parse_env(args.env_file)
    except BuildEnvError as error:
        print(f"[FAIL] Portal UI 빌드 환경: {error}", file=sys.stderr)
        return 2

    if args.format == "nul":
        for key in ALLOWED_KEYS:
            if key in values:
                sys.stdout.buffer.write(f"{key}={values[key]}".encode("utf-8") + b"\0")
    elif args.format == "base64":
        sys.stdout.write(base64.b64encode(dotenv_bytes(values)).decode("ascii"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
