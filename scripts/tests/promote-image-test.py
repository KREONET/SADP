#!/usr/bin/env python3
"""promote-image.py가 image 필드만 변경하는지 회귀 시험한다."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "site" / "promote-image.py"
SHA = "0123456789abcdef0123456789abcdef01234567"
SOURCE = """# 보존해야 하는 설명
app:
  name: demo

image:
  repository: local/demo
  tag: testbed-v1
  pullPolicy: Never # 로컬 테스트

configuration:
  config:
    MESSAGE: 그대로
"""


def run(path: pathlib.Path, tag: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--values",
            str(path),
            "--repository",
            "registry.example.internal/group/project/demo",
            "--tag",
            tag,
        ],
        capture_output=True,
        text=True,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="promote-image-test-") as directory:
        values = pathlib.Path(directory) / "values.yaml"
        values.write_text(SOURCE, encoding="utf-8")
        result = run(values, SHA)
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            return 1
        output = values.read_text(encoding="utf-8")
        document = yaml.safe_load(output)
        expected = {
            "repository": "registry.example.internal/group/project/demo",
            "tag": SHA,
            "digest": "",
            "pullPolicy": "IfNotPresent",
        }
        if document["image"] != expected:
            print(f"[FAIL] image 결과 불일치: {document['image']}", file=sys.stderr)
            return 1
        if "# 보존해야 하는 설명" not in output or "MESSAGE: 그대로" not in output:
            print("[FAIL] image 밖의 주석 또는 설정이 바뀌었다", file=sys.stderr)
            return 1

        before_invalid = output
        invalid = run(values, "latest")
        if invalid.returncode == 0 or values.read_text(encoding="utf-8") != before_invalid:
            print("[FAIL] mutable/잘못된 tag를 거부하지 못했다", file=sys.stderr)
            return 1

    print("[OK]   GP-01 image 필드만 SHA tag로 승격하고 잘못된 tag는 거부")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
