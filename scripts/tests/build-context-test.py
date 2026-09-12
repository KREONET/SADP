#!/usr/bin/env python3
"""워커에 보내는 실제 tar 명령에서 중첩된 로컬 인증 입력이 제외되는지 확인한다."""

import io
import pathlib
import shlex
import subprocess
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
source = (ROOT / "scripts/cluster/build-local-images.sh").read_text()
start = source.index('  tar -C "${TESTBED_ROOT}" -cf -')
end = source.index("| kctl exec", start)
command = shlex.split(source[start:end].replace("\\\n", ""))
with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    private = []
    public = ["apps/test-app/main.go", "apps/portal-lite/ui/package-lock.json", "apps/portal-lite/backend/main.go"]
    for directory in ("apps/test-app", "apps/portal-lite", "apps/portal-lite/ui", "apps/portal-lite/backend", "apps/portal-lite/ui/nested"):
        private.extend(f"{directory}/{name}" for name in (".env", ".env.local", ".git/config"))
    for name in private + public:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture")
    command[command.index("${TESTBED_ROOT}")] = temporary
    result = subprocess.run(command, check=True, capture_output=True)
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
        names = set(archive.getnames())
    assert names.isdisjoint(private), names.intersection(private)
    assert set(public) <= names
print("[OK] 워커 build context의 중첩 .env/Git 제외 및 소스 보존")
