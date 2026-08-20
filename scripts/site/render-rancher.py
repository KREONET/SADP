#!/usr/bin/env python3
"""Render Rancher Project and RBAC binding resources from the platform contract.

Two independent pending gates, matching scripts/site/render-exposure.py:

  Projects  always render. They only need the contract, not Keycloak.
  Bindings  render per role, and only once that role's Keycloak group name lands (D7).

Subjects are Keycloak groups, so a binding written before D7 would reference a principal that
cannot resolve. Rather than guess a group name, each role is skipped until its group is filled in.
Roles reuse Rancher's built-in GlobalRole and RoleTemplate names; no custom RoleTemplate is
created, because the plan's clause 7.2 role model maps onto the built-ins one to one.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_PATH = ROOT / "contracts" / "platform-production.yaml"
TEMPLATE_DIR = ROOT / "scripts" / "site" / "templates"
PROJECT_TEMPLATE = TEMPLATE_DIR / "rancher-project.yaml.template"
GLOBAL_BINDING_TEMPLATE = TEMPLATE_DIR / "rancher-global-binding.yaml.template"
PROJECT_BINDING_TEMPLATE = TEMPLATE_DIR / "rancher-project-binding.yaml.template"
OUTPUT = ROOT / "platform" / "rancher" / "resources.yaml"

PENDING_VALUES = {"", "pending", "replace-me", "tbd", "none"}
NAME_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
# 계획서 7.2 의 역할 이름. 계약이 임의 역할을 만들지 못하게 고정한다.
KNOWN_ROLES = ("platform-admin", "app-admin", "developer", "viewer")
HEADER = (
    "# 자동 생성 파일. contracts/platform-production.yaml을 수정한 뒤 scripts/site/render-rancher.py를 실행한다.\n"
    "# Rancher 내장 GlobalRole/RoleTemplate 만 참조한다. 사용자 계정은 여기에 기록하지 않는다.\n"
)


def load_contract() -> dict:
    contract = yaml.safe_load(CONTRACT_PATH.read_text(encoding="utf-8"))
    if contract.get("kind") != "PlatformContract":
        raise ValueError("contracts/platform-production.yaml kind must be PlatformContract")
    return contract["spec"]


def is_pending(raw_value: object) -> bool:
    return str(raw_value or "").strip().lower() in PENDING_VALUES


def substitute(template: str, replacements: dict[str, str]) -> str:
    rendered = template
    for placeholder, value in replacements.items():
        rendered = rendered.replace(placeholder, value)
    unresolved = sorted({part for part in rendered.split() if part.startswith("__")})
    if unresolved:
        raise ValueError(f"unresolved template placeholders: {', '.join(unresolved)}")
    return rendered


def project_names(rancher: dict, workload_namespaces: set[str]) -> list[str]:
    names = []
    for project in rancher.get("projects") or []:
        name = str((project or {}).get("name") or "").strip()
        if not NAME_PATTERN.match(name):
            raise ValueError(f"invalid rancher project name: {name!r}")
        # Rancher 는 Project 이름과 같은 backing Namespace 를 만들어 PRTB 를 보관한다.
        # 워크로드 Namespace 와 이름이 겹치면 두 용도가 한 객체에 섞인다.
        if name in workload_namespaces:
            raise ValueError(
                f"rancher project {name!r} collides with a workload namespace; Rancher creates a "
                "backing namespace of the same name. Use a distinct name and set displayName"
            )
        names.append(name)
    if not names:
        raise ValueError("spec.rancher.projects must not be empty")
    if len(set(names)) != len(names):
        raise ValueError("spec.rancher.projects contains duplicate names")
    return names


def project_documents(rancher: dict, cluster_id: str) -> list[str]:
    template = PROJECT_TEMPLATE.read_text(encoding="utf-8")
    documents = []
    for project in rancher.get("projects") or []:
        name = str(project["name"]).strip()
        documents.append(
            substitute(
                template,
                {
                    "__CLUSTER_ID__": cluster_id,
                    "__PROJECT_NAME__": name,
                    "__PROJECT_DISPLAY_NAME__": str(project.get("displayName") or name),
                    "__PROJECT_DESCRIPTION__": str(project.get("description") or name),
                },
            ).rstrip("\n")
        )
    return documents


def binding_documents(
    rancher: dict, cluster_id: str, known: list[str]
) -> tuple[list[str], list[str]]:
    """(렌더된 binding 문서, group 미확정으로 건너뛴 역할)"""
    global_template = GLOBAL_BINDING_TEMPLATE.read_text(encoding="utf-8")
    project_template = PROJECT_BINDING_TEMPLATE.read_text(encoding="utf-8")
    documents: list[str] = []
    skipped: list[str] = []
    seen_roles: set[str] = set()

    for binding in rancher.get("roleBindings") or []:
        binding = binding or {}
        role = str(binding.get("role") or "").strip()
        if role not in KNOWN_ROLES:
            raise ValueError(
                f"spec.rancher.roleBindings role must be one of {', '.join(KNOWN_ROLES)}: {role!r}"
            )
        if role in seen_roles:
            raise ValueError(f"duplicate spec.rancher.roleBindings entry for role {role}")
        seen_roles.add(role)
        # 개별 사용자 계정이나 자격증명이 계약에 들어오는 것을 막는다(ADR 19: group 만 허용).
        for forbidden in ("user", "users", "password", "token"):
            if forbidden in binding:
                raise ValueError(
                    f"spec.rancher.roleBindings[{role}].{forbidden} is forbidden; groups only"
                )

        group = str(binding.get("group") or "").strip()
        if is_pending(group):
            skipped.append(role)
            continue

        scope = str(binding.get("scope") or "").strip()
        principal = f"keycloakoidc_group://{group}"
        if scope == "global":
            global_role = str(binding.get("globalRole") or "").strip()
            if not global_role:
                raise ValueError(f"spec.rancher.roleBindings[{role}].globalRole is required")
            documents.append(
                substitute(
                    global_template,
                    {
                        "__BINDING_NAME__": f"{role}-{global_role}",
                        "__GLOBAL_ROLE__": global_role,
                        "__GROUP_PRINCIPAL__": principal,
                    },
                ).rstrip("\n")
            )
        elif scope == "project":
            role_template = str(binding.get("roleTemplate") or "").strip()
            if not role_template:
                raise ValueError(f"spec.rancher.roleBindings[{role}].roleTemplate is required")
            targets = [str(p).strip() for p in binding.get("projects") or []]
            if not targets:
                raise ValueError(f"spec.rancher.roleBindings[{role}].projects must not be empty")
            for target in targets:
                if target not in known:
                    raise ValueError(
                        f"spec.rancher.roleBindings[{role}] references unknown project {target!r}"
                    )
                documents.append(
                    substitute(
                        project_template,
                        {
                            "__BINDING_NAME__": f"{target}-{role}",
                            "__CLUSTER_ID__": cluster_id,
                            "__GROUP_PRINCIPAL__": principal,
                            "__PROJECT_NAME__": target,
                            "__ROLE_TEMPLATE__": role_template,
                        },
                    ).rstrip("\n")
                )
        else:
            raise ValueError(
                f"spec.rancher.roleBindings[{role}].scope must be global or project: {scope!r}"
            )
    return documents, skipped


def render(specification: dict) -> tuple[str, list[str]]:
    rancher = specification.get("rancher") or {}
    if not rancher:
        raise ValueError("spec.rancher is missing")
    cluster_id = str(rancher.get("clusterId") or "").strip()
    if not NAME_PATTERN.match(cluster_id):
        raise ValueError(f"invalid spec.rancher.clusterId: {cluster_id!r}")

    workload_namespaces = {
        str(namespace)
        for project in rancher.get("projects") or []
        for namespace in (project or {}).get("namespaces") or []
    }
    workload_namespaces |= {
        str(namespace)
        for namespace in (specification.get("gateway") or {}).get("allowedRouteNamespaces") or []
    }
    known = project_names(rancher, workload_namespaces)
    documents = project_documents(rancher, cluster_id)
    bindings, skipped = binding_documents(rancher, cluster_id, known)
    documents += bindings
    return HEADER + "---\n".join(document + "\n" for document in documents), skipped


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    try:
        rendered, skipped = render(load_contract())
    except (KeyError, ValueError) as error:
        print(f"[FAIL] Rancher manifest generation failed: {error}", file=sys.stderr)
        return 1

    if skipped:
        print(
            "[WARN] Keycloak group 미확정으로 RBAC binding 생략(D7 에 활성화): "
            + ", ".join(sorted(skipped))
        )

    if arguments.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != rendered:
            print(
                f"[FAIL] {OUTPUT.relative_to(ROOT)} is not synchronized with the contract",
                file=sys.stderr,
            )
            return 1
        print("[OK]   Rancher contract and manifest synchronization confirmed")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"[OK]   {OUTPUT.relative_to(ROOT)} generated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
