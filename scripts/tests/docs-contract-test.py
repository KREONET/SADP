#!/usr/bin/env python3
"""문서의 명령·링크·Portal endpoint가 현재 소스와 어긋나지 않는지 검사한다."""

from __future__ import annotations

import json
import pathlib
import re
import sys
import urllib.parse

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
MARKDOWN_FILES = sorted(
    {
        ROOT / "README.md",
        *ROOT.glob("docs/**/*.md"),
        ROOT / "scripts/README.md",
        ROOT / "platform/README.md",
        ROOT / "platform/rancher/README.md",
    }
)
FAILURES: list[str] = []


def fail(message: str) -> None:
    FAILURES.append(message)


def text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def relative(path: pathlib.Path) -> str:
    return str(path.relative_to(ROOT))


def check_local_links() -> None:
    link_pattern = re.compile(r"(?<!!)\[[^]]+\]\(([^)]+)\)")
    heading_pattern = re.compile(r"^#{1,6}\s+(.+?)\s*#*$", re.MULTILINE)

    def slug(raw_heading: str) -> str:
        value = re.sub(r"<[^>]+>", "", raw_heading)
        value = re.sub(r"[`*_~]", "", value).strip().lower()
        value = "".join(
            character
            for character in value
            if character.isalnum() or character in " -_"
        )
        return re.sub(r"\s", "-", value)

    anchors: dict[pathlib.Path, set[str]] = {}
    for document in MARKDOWN_FILES:
        counts: dict[str, int] = {}
        document_anchors: set[str] = set()
        for heading in heading_pattern.findall(text(document)):
            base = slug(heading)
            count = counts.get(base, 0)
            counts[base] = count + 1
            document_anchors.add(base if count == 0 else f"{base}-{count}")
        anchors[document.resolve()] = document_anchors

    for document in MARKDOWN_FILES:
        for raw_target in link_pattern.findall(text(document)):
            target = raw_target.strip().strip("<>").split(maxsplit=1)[0]
            if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                continue
            local_path = target.split("#", 1)[0]
            if not local_path:
                continue
            resolved = (document.parent / local_path).resolve()
            if not resolved.exists():
                fail(f"{relative(document)}: 존재하지 않는 링크 {target}")
                continue
            if "#" in target and resolved in anchors:
                fragment = urllib.parse.unquote(target.split("#", 1)[1])
                if fragment and fragment not in anchors[resolved]:
                    fail(f"{relative(document)}: 존재하지 않는 문서 절 {target}")


def sadp_commands() -> set[str]:
    dispatcher = text(ROOT / "sadp")
    return set(re.findall(r"^([a-z0-9-]+)\|(?:bash|python3|special)\|", dispatcher, re.MULTILINE))


def sadp_script_map() -> dict[str, pathlib.Path]:
    dispatcher = text(ROOT / "sadp")
    return {
        command: ROOT / path
        for command, runner, path in re.findall(
            r"^([a-z0-9-]+)\|(bash|python3)\|([^|]+)\|", dispatcher, re.MULTILINE
        )
        if runner in {"bash", "python3"}
    }


def check_sadp_commands() -> None:
    known = sadp_commands()
    invocation = re.compile(r"\bbash\s+\./sadp\s+--([a-z0-9-]+)")
    ignored = {"help", "list"}
    for document in MARKDOWN_FILES:
        for command in invocation.findall(text(document)):
            if command not in known | ignored:
                fail(f"{relative(document)}: sadp에 없는 명령 --{command}")


def check_documented_script_options() -> None:
    script_map = sadp_script_map()
    invocation = re.compile(
        r"^\s*(?:sudo\s+)?bash\s+(\./sadp|scripts/[A-Za-z0-9_./-]+\.sh)\b(.*)$"
    )
    option = re.compile(r"(?<![A-Za-z0-9_-])--([a-z][a-z0-9-]*)")

    for document in MARKDOWN_FILES:
        # 여러 줄 복사 명령도 하나의 명령으로 검사한다. 줄 끝 역슬래시가 없는 다음 줄은
        # 별도 명령이므로 합치지 않는다.
        commands = re.sub(r"\\\n[ \t]*", " ", text(document)).splitlines()
        for line in commands:
            match = invocation.match(line)
            if not match:
                continue
            target, raw_arguments = match.groups()
            options = option.findall(raw_arguments)
            if target == "./sadp":
                if not options:
                    continue
                command, *forwarded = options
                script = script_map.get(command)
                if script is None:
                    continue
                options = forwarded
            else:
                script = ROOT / target

            supported = set(option.findall(text(script)))
            for documented in options:
                if documented not in supported:
                    fail(
                        f"{relative(document)}: {relative(script)}가 받지 않는 "
                        f"--{documented} 옵션"
                    )


def check_script_references() -> None:
    reference = re.compile(r"(?<![A-Za-z0-9_./-])(scripts/[A-Za-z0-9_./-]+\.(?:sh|py))")
    for document in MARKDOWN_FILES:
        for script in reference.findall(text(document)):
            if not (ROOT / script).is_file():
                fail(f"{relative(document)}: 존재하지 않는 스크립트 {script}")


def source_routes() -> set[tuple[str, str]]:
    routes = text(ROOT / "apps/portal-lite/backend/routes.go")
    return set(re.findall(r'mux\.HandleFunc\("(GET|POST|PUT|DELETE) ([^" ]+)"', routes))


def openapi_routes() -> set[tuple[str, str]]:
    document = yaml.safe_load(text(ROOT / "apps/portal-lite/backend/openapi.yaml"))
    result: set[tuple[str, str]] = set()
    for path, operations in document.get("paths", {}).items():
        for method in operations:
            if method.lower() in {"get", "post", "put", "delete"}:
                result.add((method.upper(), path))
    return result


def check_portal_routes() -> None:
    code_routes = source_routes()
    documented_api = openapi_routes()
    expected_api = {route for route in code_routes if route[1] != "/healthz"}
    if expected_api != documented_api:
        for route in sorted(expected_api - documented_api):
            fail(f"OpenAPI 누락 route: {route[0]} {route[1]}")
        for route in sorted(documented_api - expected_api):
            fail(f"OpenAPI에만 있는 route: {route[0]} {route[1]}")

    human_guide = text(ROOT / "docs/portal-api.md")
    for method, path in sorted(code_routes):
        row = re.compile(
            rf"\|\s*`{re.escape(method)}`\s*\|\s*`{re.escape(path)}`\s*\|"
        )
        if not row.search(human_guide):
            fail(f"docs/portal-api.md endpoint 표 누락: {method} {path}")


def check_portal_public_keys() -> None:
    allowed = json.loads(
        text(ROOT / "apps/portal-lite/ui/scripts/portal-ui-public-env-keys.json")
    )
    installation = text(ROOT / "docs/installation.md")
    for key in allowed:
        if key not in installation:
            fail(f"docs/installation.md Portal UI 공개 key 누락: {key}")


def check_known_stale_instructions() -> None:
    combined = "\n".join(text(path) for path in MARKDOWN_FILES)
    forbidden = {
        r"install-rke2-containerd-proxy[^\n]*--restart": "문서에서 금지한 containerd proxy 자동 재시작",
        r"--install-containerd-proxy[^\n]*--restart": "문서에서 금지한 containerd proxy 자동 재시작",
        r"kubectl\s+[^\n]*set env[^\n]*argocd-repo-server": "Argo repo-server 수동 set env",
        r"--env-file\s+environments/site\.env(?:\s|$)": "Git 밖 실제 env 대신 없는 environments/site.env 사용",
        r"helm[^\n]*upgrade\s+--install\s+(?:prometheus|loki|alloy)": "Argo 소유 monitoring 직접 Helm 설치",
    }
    for pattern, description in forbidden.items():
        if re.search(pattern, combined, re.IGNORECASE):
            fail(f"오래된 문서 지시 발견: {description}")

    platform_docs = text(ROOT / "platform/README.md") + text(
        ROOT / "platform/rancher/README.md"
    )
    for stale in ("beta-gateway", "research-beta", "beta.example.com", "Rancher 2.15.0"):
        if stale in platform_docs:
            fail(f"platform 문서에 과거 사이트 값이 남음: {stale}")


def main() -> int:
    check_local_links()
    check_sadp_commands()
    check_documented_script_options()
    check_script_references()
    check_portal_routes()
    check_portal_public_keys()
    check_known_stale_instructions()

    if FAILURES:
        for issue in FAILURES:
            print(f"[FAIL] {issue}", file=sys.stderr)
        print(f"문서 계약 실패 {len(FAILURES)}건", file=sys.stderr)
        return 1
    print(
        "[OK]   문서 링크, SADP 명령/스크립트 옵션, Portal route/OpenAPI, UI 공개 key 동기화"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
