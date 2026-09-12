#!/usr/bin/env python3
"""잠금 버전만 바꾸고 실제 UI 또는 이미지가 구버전으로 남는 업데이트를 막는다."""

from __future__ import annotations

import json
import pathlib
import re

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]


def check(root: pathlib.Path) -> list[str]:
    locked = yaml.safe_load((root / "versions.lock.yaml").read_text())["applications"]["portalLite"]
    ui = root / "apps/portal-lite/ui"
    package = json.loads((ui / "package.json").read_text())
    packages = json.loads((ui / "package-lock.json").read_text())["packages"]
    errors = []
    expected = {
        "next": locked["next"],
        "eslint-config-next": locked["next"],
        "next-auth": locked["nextAuth"],
        "react": locked["react"],
        "react-dom": locked["react"],
        "eslint": locked["eslint"],
    }
    for name, version in expected.items():
        for label, document in (("package.json", package), ("package-lock.json root", packages[""])):
            actual = {**document.get("dependencies", {}), **document.get("devDependencies", {})}.get(name)
            if actual != str(version):
                errors.append(f"{label}: {name} != applications.portalLite")
        if packages.get(f"node_modules/{name}", {}).get("version") != str(version):
            errors.append(f"package-lock.json resolved: {name} != applications.portalLite")
    dockerfile = (root / "apps/portal-lite/Dockerfile").read_text()
    node_images = re.findall(r"^FROM node:([^\s]+)", dockerfile, re.MULTILINE)
    if len(node_images) != 2 or any(image.split("-", 1)[0] != str(locked["node"]) for image in node_images):
        errors.append("Dockerfile: frontend/runtime Node != applications.portalLite.node")
    return errors


if __name__ == "__main__":
    errors = check(ROOT)
    for error in errors:
        print(f"[FAIL] {error}")
    if errors:
        raise SystemExit(1)
    print("[OK] Portal package manifest/resolved lock/Node image 버전 일치")
