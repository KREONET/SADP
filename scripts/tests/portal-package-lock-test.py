#!/usr/bin/env python3
"""실제 배포 입력의 일부만 업데이트하면 버전 검사가 거부하는지 확인한다."""

import importlib.util
import pathlib
import shutil
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_check", ROOT / "scripts/site/check-portal-package-lock.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert not module.check(ROOT)
paths = ["versions.lock.yaml", "apps/portal-lite/Dockerfile", "apps/portal-lite/ui/package.json", "apps/portal-lite/ui/package-lock.json"]
for changed in paths:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for path in paths:
            destination = root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, destination)
        path = root / changed
        text = path.read_text()
        # 모든 파일에서 공유하는 값이 아니라 각 입력의 실제 잠금 버전을 깨뜨린다.
        if changed.endswith("Dockerfile"):
            text = text.replace("FROM node:", "FROM node:0.0.0-", 1)
        else:
            version = str(module.yaml.safe_load((ROOT / "versions.lock.yaml").read_text())["applications"]["portalLite"]["next"])
            text = text.replace(version, "0.0.0")
        path.write_text(text)
        assert module.check(root), changed
print("[OK] Portal 부분 버전 업데이트 거부")
