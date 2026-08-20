#!/usr/bin/env python3
"""GitOps values의 image 필드만 바꾸고 나머지 서식과 주석은 보존한다."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

import yaml


SHA_TAG = re.compile(r"[0-9a-f]{40}")
IMAGE_HEADER = re.compile(r"^image:\s*(?:#.*)?$")
IMAGE_FIELD = re.compile(r"^  (repository|tag|digest|pullPolicy):")


def quoted(value: str) -> str:
    """JSON 문자열은 YAML double-quoted scalar와 호환된다."""
    return json.dumps(value, ensure_ascii=False)


def promote(text: str, repository: str, tag: str) -> str:
    if not repository or any(character.isspace() for character in repository):
        raise ValueError("image repository는 공백 없는 값이어야 한다")
    if not SHA_TAG.fullmatch(tag):
        raise ValueError("image tag는 40자리 소문자 commit SHA여야 한다")

    document = yaml.safe_load(text)
    if not isinstance(document, dict) or not isinstance(document.get("image"), dict):
        raise ValueError("최상위 image mapping이 없다")

    newline = "\r\n" if "\r\n" in text else "\n"
    trailing_newline = text.endswith(("\n", "\r"))
    lines = text.splitlines()
    headers = [index for index, line in enumerate(lines) if IMAGE_HEADER.fullmatch(line)]
    if len(headers) != 1:
        raise ValueError(f"최상위 image block은 정확히 하나여야 한다(현재 {len(headers)}개)")

    start = headers[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line and not line[0].isspace() and not line.startswith("#"):
            end = index
            break

    block = lines[start + 1 : end]
    positions: dict[str, list[int]] = {}
    for index, line in enumerate(block):
        match = IMAGE_FIELD.match(line)
        if match:
            positions.setdefault(match.group(1), []).append(index)

    for required in ("repository", "tag", "pullPolicy"):
        if len(positions.get(required, [])) != 1:
            raise ValueError(f"image.{required}는 정확히 하나여야 한다")
    if len(positions.get("digest", [])) > 1:
        raise ValueError("image.digest는 하나만 허용한다")

    replacements = {
        "repository": f"  repository: {quoted(repository)}",
        "tag": f"  tag: {quoted(tag)}",
        "digest": '  digest: ""',
        "pullPolicy": "  pullPolicy: IfNotPresent",
    }
    for field in ("repository", "tag", "pullPolicy"):
        block[positions[field][0]] = replacements[field]
    if positions.get("digest"):
        block[positions["digest"][0]] = replacements["digest"]
    else:
        block.insert(positions["tag"][0] + 1, replacements["digest"])

    result = newline.join(lines[: start + 1] + block + lines[end:])
    if trailing_newline:
        result += newline

    rendered = yaml.safe_load(result)
    image = rendered["image"]
    expected = {
        "repository": repository,
        "tag": tag,
        "digest": "",
        "pullPolicy": "IfNotPresent",
    }
    for field, value in expected.items():
        if image.get(field) != value:
            raise ValueError(f"렌더 후 image.{field} 검증 실패")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--values", required=True, type=pathlib.Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()

    try:
        original = args.values.read_text(encoding="utf-8")
        updated = promote(original, args.repository, args.tag)
        args.values.write_text(updated, encoding="utf-8")
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"[FAIL] image 승격 실패: {error}", file=sys.stderr)
        return 1

    print(f"[OK] {args.values}: {args.repository}:{args.tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
