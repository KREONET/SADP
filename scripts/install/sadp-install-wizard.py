#!/usr/bin/env python3
"""질문과 답변으로 non-secret site.env를 만들고 기존 통합 설치기를 호출한다."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_TEMPLATE = ROOT / "environments" / "site.env.example"
DEFAULT_OUTPUT = pathlib.Path("/etc/sadp/site.env")
ASSIGNMENT = re.compile(r"^(?P<key>[A-Z][A-Z0-9_]*)=(?P<value>.*)$")


@dataclass(frozen=True)
class Question:
    key: str
    label: str
    choices: tuple[str, ...] = ()
    optional: bool = False


SECTIONS: tuple[tuple[str, tuple[Question, ...]], ...] = (
    (
        "사이트 이름과 기본 서비스",
        (
            Question("SITE_NAME", "사이트 이름"),
            Question("APP_ENVIRONMENT", "앱 환경 이름"),
            Question("CLUSTER_NAME", "클러스터 이름"),
            Question("BASE_DOMAIN", "기본 도메인"),
            Question("APP_PROJECT", "기본 앱 프로젝트"),
            Question("STORAGE_CLASS", "기본 StorageClass"),
        ),
    ),
    (
        "GitOps와 이미지 저장소",
        (
            Question("FORGEJO_REPO_URL", "Forgejo SADP 저장소 HTTPS URL"),
            Question("FORGEJO_REVISION", "배포할 Git branch 또는 revision"),
            Question("OCI_REGISTRY", "OCI Registry host"),
            Question("OCI_PROJECT", "OCI Registry project"),
            Question("TEST_APP_IMAGE_TAG", "테스트 앱 immutable image tag"),
            Question("PORTAL_IMAGE_TAG", "Portal immutable image tag"),
        ),
    ),
    (
        "RKE2 노드와 내부망",
        (
            Question("CLUSTER_MODE", "노드 구성", ("single", "multi")),
            Question("CONTROL_PLANE_HOSTNAME", "control-plane hostname"),
            Question("CONTROL_PLANE_IP", "control-plane 내부 IPv4"),
            Question("WORKER_NODES", "worker 목록(host=IPv4,host=IPv4)"),
            Question("INTERNAL_INTERFACE", "모든 노드의 내부 NIC 이름"),
            Question("EXTERNAL_INTERFACE", "모든 노드의 외부 NIC 이름"),
            Question("GUARDED_INTERFACES", "추가 보호 NIC 목록(CSV, 없으면 -)", optional=True),
            Question("NODE_INTERNAL_CIDRS", "노드 내부 CIDR 목록"),
            Question("POD_CIDRS", "Pod CIDR 목록"),
            Question("SERVICE_CIDRS", "Service CIDR 목록"),
            Question("CLUSTER_DNS_IP", "Cluster DNS Service IP"),
            Question("CLUSTER_UPSTREAM_DNS", "CoreDNS upstream IPv4:port", optional=True),
            Question("KUBERNETES_API_ADDRESSES", "Kubernetes API 허용 주소 목록"),
            Question("RKE2_SERVER_ENDPOINT", "RKE2 server endpoint IPv4"),
        ),
    ),
    (
        "공개 경로와 Squid",
        (
            Question("PUBLIC_IP", "서비스 공인 IPv4"),
            Question("PUBLIC_EXPOSURE_MODE", "공개 방식", ("nat", "direct")),
            Question("PUBLIC_IP_NODE", "공인 IP 보유 Kubernetes Node 이름"),
            Question("GATEWAY_VIP", "MetalLB Gateway VIP"),
            Question("GATEWAY_ADDRESS_POOL", "MetalLB 주소 pool"),
            Question("SQUID_INTERNAL_IP", "Squid 담당 노드 내부 IPv4"),
            Question("SQUID_CLIENT_CIDRS", "Squid client CIDR 목록"),
            Question("EXTRA_PACKAGE_DOMAINS", "추가 허용 package domain(CSV, 없으면 -)", optional=True),
        ),
    ),
    (
        "인증과 TLS",
        (
            Question("IDENTITY_SOURCE_PROTOCOL", "외부 인증 원본 방식", ("openid", "saml")),
            Question("OIDC_ISSUER", "SADP가 사용할 OIDC issuer"),
            Question("OIDC_AUTHORIZATION_ENDPOINT", "OIDC authorization endpoint"),
            Question("OIDC_TOKEN_ENDPOINT", "OIDC token endpoint"),
            Question("OIDC_JWKS_URI", "OIDC JWKS URI"),
            Question("OIDC_END_SESSION_ENDPOINT", "OIDC logout endpoint(없으면 -)", optional=True),
            Question("OIDC_GROUPS_CLAIM", "OIDC 그룹 claim"),
            Question("OIDC_CLIENT_ID_CLAIM", "OIDC client ID claim"),
            Question("PORTAL_OIDC_CLIENT_ID", "Portal OIDC client ID"),
            Question("TLS_SOURCE", "TLS 인증서 방식", ("acme", "provided")),
            Question("ACME_EMAIL", "ACME 알림 email"),
            Question("DNS01_MODE", "DNS-01 방식", ("direct-rfc2136", "delegated-rfc2136")),
            Question("ACME_DELEGATION_TYPE", "DNS 위임 형식", ("cname", "ns")),
            Question("ACME_DELEGATED_ZONE", "위임받은 DNS zone"),
            Question("RFC2136_NAMESERVER", "RFC2136 nameserver IPv4:port"),
            Question("RFC2136_TSIG_KEY_NAME", "RFC2136 TSIG key 이름"),
            Question("DNS_RECURSIVE_NAMESERVERS", "DNS-01 self-check resolver 목록"),
            Question("PROVIDED_CERTIFICATE_PATH", "제공 인증서 파일 경로"),
            Question("PROVIDED_PRIVATE_KEY_PATH", "제공 개인키 파일 경로"),
        ),
    ),
    (
        "통합 설치 선택",
        (
            Question("SADP_INSTALL_GITOPS", "Argo GitOps를 구성할지", ("true", "false")),
            Question("SADP_ARGO_REPO_USERNAME", "Argo 저장소 사용자명"),
            Question("SADP_ARGO_REPO_TOKEN_FILE", "Argo read token 파일 경로"),
            Question("SADP_DNS_TSIG_SECRET_FILE", "RFC2136 TSIG 파일 경로"),
            Question("SADP_INSTALL_MONITORING", "Prometheus/Loki/Alloy를 설치할지", ("true", "false")),
            Question("SADP_BUILD_IMAGES", "SADP 이미지를 빌드할지", ("true", "false")),
            Question("SADP_BUILD_NODE", "빌드 worker 이름(자동 선택은 -)", optional=True),
            Question("SADP_DEPLOY_APPS", "기본 앱을 배포할지", ("true", "false")),
            Question("SADP_REGISTRY_PULL_DOCKERCONFIG", "Registry pull dockerconfig 경로"),
            Question("SADP_REGISTRY_PUSH_DOCKERCONFIG", "Registry push dockerconfig 경로"),
            Question("SADP_RUN_VERIFY", "설치 뒤 acceptance를 실행할지", ("true", "false")),
        ),
    ),
)


def parse_values(content: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in content.splitlines():
        match = ASSIGNMENT.match(line)
        if match:
            values[match.group("key")] = match.group("value")
    return values


def replace_values(content: str, updates: dict[str, str]) -> str:
    found: set[str] = set()
    rendered: list[str] = []
    for line in content.splitlines():
        match = ASSIGNMENT.match(line)
        if match and match.group("key") in updates:
            key = match.group("key")
            rendered.append(f"{key}={updates[key]}")
            found.add(key)
        else:
            rendered.append(line)
    missing = sorted(set(updates) - found)
    if missing:
        raise ValueError("template에 없는 key: " + ", ".join(missing))
    return "\n".join(rendered) + "\n"


def answer(question: Question, current: str) -> str:
    while True:
        choices = f" ({'/'.join(question.choices)})" if question.choices else ""
        default = current if current else "비움"
        try:
            raw = input(f"{question.label}{choices} [{default}]: ").strip()
        except EOFError as error:
            raise RuntimeError("입력이 중단됨") from error
        value = current if not raw else ("" if raw == "-" else raw)
        if not value and not question.optional:
            print("  값이 필요합니다.", file=sys.stderr)
            continue
        if question.choices and value not in question.choices:
            print("  허용 값: " + ", ".join(question.choices), file=sys.stderr)
            continue
        return value


def should_ask(question: Question, values: dict[str, str]) -> bool:
    if question.key == "WORKER_NODES":
        return values.get("CLUSTER_MODE", "multi") != "single"
    if question.key == "PUBLIC_IP_NODE":
        return values.get("PUBLIC_EXPOSURE_MODE") == "direct"
    if question.key.startswith("RFC2136_") or question.key in {
        "ACME_EMAIL",
        "DNS01_MODE",
        "DNS_RECURSIVE_NAMESERVERS",
        "SADP_DNS_TSIG_SECRET_FILE",
    }:
        return values.get("TLS_SOURCE") == "acme"
    if question.key in {"ACME_DELEGATION_TYPE", "ACME_DELEGATED_ZONE"}:
        return values.get("TLS_SOURCE") == "acme" and values.get("DNS01_MODE") == "delegated-rfc2136"
    if question.key in {"PROVIDED_CERTIFICATE_PATH", "PROVIDED_PRIVATE_KEY_PATH"}:
        return values.get("TLS_SOURCE") == "provided"
    if question.key in {"SADP_ARGO_REPO_USERNAME", "SADP_ARGO_REPO_TOKEN_FILE"}:
        return values.get("SADP_INSTALL_GITOPS") == "true"
    if question.key == "SADP_BUILD_NODE":
        return values.get("SADP_BUILD_IMAGES") == "true"
    if question.key in {
        "SADP_REGISTRY_PULL_DOCKERCONFIG",
        "SADP_REGISTRY_PUSH_DOCKERCONFIG",
    }:
        return values.get("SADP_DEPLOY_APPS") == "true"
    return True


def clear_inactive(values: dict[str, str]) -> None:
    if values.get("CLUSTER_MODE") == "single":
        values["WORKER_NODES"] = ""
    if values.get("PUBLIC_EXPOSURE_MODE") != "direct":
        values["PUBLIC_IP_NODE"] = ""
    if values.get("TLS_SOURCE") == "acme":
        values["PROVIDED_CERTIFICATE_PATH"] = ""
        values["PROVIDED_PRIVATE_KEY_PATH"] = ""
        if values.get("DNS01_MODE") != "delegated-rfc2136":
            values["ACME_DELEGATION_TYPE"] = ""
            values["ACME_DELEGATED_ZONE"] = ""
    else:
        values["SADP_DNS_TSIG_SECRET_FILE"] = ""
        # provided 모드는 운영 PEM을 이미 확보한 설치 방식이므로 HTTPS 준비 상태와 함께 기록한다.
        values["EXISTING_GATEWAY_TLS_READY"] = "true"
    if values.get("SADP_INSTALL_GITOPS") != "true":
        values["SADP_ARGO_REPO_USERNAME"] = ""
        values["SADP_ARGO_REPO_TOKEN_FILE"] = ""
    if values.get("SADP_BUILD_IMAGES") != "true":
        values["SADP_BUILD_NODE"] = ""
    if values.get("SADP_DEPLOY_APPS") != "true":
        values["SADP_REGISTRY_PULL_DOCKERCONFIG"] = ""
        values["SADP_REGISTRY_PUSH_DOCKERCONFIG"] = ""


def validate(candidate: pathlib.Path) -> None:
    command = [
        sys.executable,
        str(ROOT / "scripts/site/configure-site.py"),
        "--env-file",
        str(candidate),
        "--check",
    ]
    result = subprocess.run(command, cwd=ROOT, check=False)
    if result.returncode:
        raise RuntimeError("site.env 검증 실패: 위 항목을 고친 뒤 다시 실행하십시오")


def write_candidate(output: pathlib.Path, content: str) -> None:
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if output.is_symlink():
        raise RuntimeError(f"symlink 출력은 허용하지 않음: {output}")
    fd, raw_path = tempfile.mkstemp(prefix=".site.env.", dir=output.parent, text=True)
    candidate = pathlib.Path(raw_path)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        validate(candidate)
        os.replace(candidate, output)
        output.chmod(0o600)
    finally:
        candidate.unlink(missing_ok=True)


def installer_command(args: argparse.Namespace, output: pathlib.Path) -> list[str]:
    command = [
        "bash",
        str(ROOT / "scripts/install/sadp-install.sh"),
        "--env-file",
        str(output),
        "--phase",
        args.phase,
    ]
    if args.node_name:
        command.extend(("--node-name", args.node_name))
    if args.allow_dirty:
        command.append("--allow-dirty")
    if args.apply:
        command.append("--apply")
    return command


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="질문과 답변으로 site.env를 만들고 SADP 통합 설치 phase를 실행합니다."
    )
    parser.add_argument("--template", type=pathlib.Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--phase", choices=("none", "all", "render", "node", "cluster"), default="none"
    )
    parser.add_argument("--node-name")
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--yes", action="store_true", help="최종 저장 확인만 생략")
    parser.add_argument("--show-questions", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.apply and args.phase == "none":
        print("[FAIL] --apply에는 --phase가 필요함", file=sys.stderr)
        return 2
    if args.show_questions:
        for title, questions in SECTIONS:
            print(f"[{title}]")
            for question in questions:
                print(f"  {question.key}: {question.label}")
        return 0

    source = args.output if args.output.exists() else args.template
    if not source.is_file() or source.is_symlink():
        print(f"[FAIL] 입력 template/site.env를 읽을 수 없음: {source}", file=sys.stderr)
        return 1
    content = source.read_text(encoding="utf-8")
    values = parse_values(content)
    values.setdefault("CLUSTER_MODE", "multi")

    print("SADP 대화형 설치 준비")
    print("- Enter: 현재값 유지, - 입력: 선택값 비우기")
    print("- password/token/private key 본문은 묻지 않고 root 전용 파일 경로만 받습니다.")
    for title, questions in SECTIONS:
        print(f"\n== {title} ==")
        for question in questions:
            if should_ask(question, values):
                values[question.key] = answer(question, values.get(question.key, ""))
    clear_inactive(values)

    updates = {
        question.key: values[question.key]
        for _, questions in SECTIONS
        for question in questions
        if question.key in values
    }
    # 질문의 선택에 따라 자동으로 바뀌는 진행값도 실제 env에 함께 기록한다.
    updates["EXISTING_GATEWAY_TLS_READY"] = values["EXISTING_GATEWAY_TLS_READY"]
    rendered = replace_values(content, updates)
    print("\n저장 전 요약")
    print(f"  site={values['SITE_NAME']} cluster={values['CLUSTER_NAME']}")
    print(f"  domain={values['BASE_DOMAIN']} public={values['PUBLIC_EXPOSURE_MODE']}")
    print(f"  control-plane={values['CONTROL_PLANE_HOSTNAME']} workers={values['WORKER_NODES']}")
    print(f"  output={args.output}")
    if not args.yes:
        confirmation = input("검증 후 저장할까요? [y/N]: ").strip().lower()
        if confirmation not in {"y", "yes"}:
            print("[INFO] 저장하지 않고 종료")
            return 0

    try:
        write_candidate(args.output, rendered)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        return 1
    print(f"[OK]   검증된 site.env 저장(mode 0600): {args.output}")

    if args.phase == "none":
        print("다음 단계:")
        print(f"  bash ./sadp --install --env-file {args.output} --phase all")
        print(f"  bash ./sadp --install --env-file {args.output} --phase render --apply")
        return 0

    command = installer_command(args, args.output)
    print("[INFO] 기존 통합 설치기로 전달: " + " ".join(command))
    return subprocess.run(command, cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
