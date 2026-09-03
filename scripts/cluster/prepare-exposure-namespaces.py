#!/usr/bin/env python3
"""노출 리소스가 참조하는 Namespace를 manifest 적용 전에 멱등 준비한다."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
NAME = re.compile(r"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$")


def fail(message: str) -> None:
    print(f"[FAIL] {message}", file=sys.stderr)
    raise SystemExit(1)


def manifest_namespaces(path: pathlib.Path) -> set[str]:
    required: set[str] = set()
    try:
        documents = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
    except (OSError, yaml.YAMLError) as error:
        fail(f"exposure manifest를 읽지 못함: {error}")
    for document in documents:
        if not isinstance(document, dict):
            continue
        metadata = document.get("metadata") or {}
        if document.get("kind") == "Namespace":
            required.add(str(metadata.get("name") or ""))
        namespace = str(metadata.get("namespace") or "")
        if namespace:
            required.add(namespace)
        if document.get("kind") != "HTTPRoute":
            continue
        route_namespace = namespace
        for rule in (document.get("spec") or {}).get("rules") or []:
            if not isinstance(rule, dict):
                continue
            for backend in rule.get("backendRefs") or []:
                if isinstance(backend, dict):
                    required.add(str(backend.get("namespace") or route_namespace))
    required.discard("")
    invalid = sorted(
        item for item in required if len(item) > 63 or not NAME.fullmatch(item)
    )
    if invalid:
        fail(f"manifest의 Namespace 이름이 올바르지 않음: {', '.join(invalid)}")
    return required


def kubectl_base(binary: str, kubeconfig: str) -> list[str]:
    command = [binary]
    if kubeconfig:
        command.extend(("--kubeconfig", kubeconfig))
    return command


def main() -> int:
    parser = argparse.ArgumentParser(
        description="exposure YAML의 Namespace/backendRef를 parser로 읽어 선행 준비"
    )
    parser.add_argument(
        "--manifest",
        default=str(ROOT / "platform/exposure/resources.yaml"),
    )
    parser.add_argument(
        "--kubectl", default=os.environ.get("KUBECTL_BIN", "/var/lib/rancher/rke2/bin/kubectl")
    )
    parser.add_argument(
        "--kubeconfig", default=os.environ.get("KUBECONFIG_PATH", "/etc/rancher/rke2/rke2.yaml")
    )
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    manifest = pathlib.Path(args.manifest)
    if not manifest.is_file() or manifest.is_symlink():
        fail("exposure manifest가 일반 파일이 아님")
    required = manifest_namespaces(manifest)
    command = kubectl_base(args.kubectl, args.kubeconfig)
    try:
        result = subprocess.run(
            [*command, "get", "namespaces", "-o", "json"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        existing_document = json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        fail("현재 Namespace 목록을 읽지 못함")
    existing = {
        str((item.get("metadata") or {}).get("name") or "")
        for item in existing_document.get("items", [])
        if isinstance(item, dict)
    }
    missing = sorted(required - existing)

    if not missing:
        print("[OK]   exposure manifest가 요구하는 Namespace가 모두 존재함")
        return 0
    print(f"[INFO] 누락 Namespace: {', '.join(missing)}")
    if not args.apply:
        print("[NEXT] sudo bash ./sadp --prepare-exposure --apply")
        return 0
    if os.geteuid() != 0:
        fail("--apply는 root 권한이 필요함")

    for namespace in missing:
        rendered = subprocess.run(
            [*command, "create", "namespace", namespace, "--dry-run=client", "-o", "yaml"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            [*command, "apply", "-f", "-"],
            check=True,
            text=True,
            input=rendered.stdout,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    print(
        "[OK]   exposure Namespace 선행 준비 완료"
        "(Namespace만 생성; workload와 Secret은 만들지 않음)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
