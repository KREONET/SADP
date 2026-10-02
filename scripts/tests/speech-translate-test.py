#!/usr/bin/env python3
"""모델 다운로드 없이 오디오 경계와 스트리밍 API 회귀를 검사한다."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/speech-translate"
env = dict(os.environ, PYTHONPATH=str(APP))
result = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", str(APP / "tests"), "-v"], env=env)
failed = result.returncode != 0
if shutil.which("node"):
    result = subprocess.run(["node", "--test", str(APP / "tests/pcm.test.mjs")])
    failed = failed or result.returncode != 0
else:
    print("[SKIP] Node.js가 없어 브라우저 PCM 리샘플링 시험을 건너뜀")
if failed:
    print("[FAIL] 음성 번역 회귀 시험 실패")
    print("[NEXT] python3 scripts/tests/speech-translate-test.py")
    raise SystemExit(1)
print("[OK] 음성 번역 회귀 시험 완료 (API 의존성 누락은 위 SKIP 참조)")
