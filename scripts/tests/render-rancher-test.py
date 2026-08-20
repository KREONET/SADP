#!/usr/bin/env python3
"""scripts/site/render-rancher.py 회귀 시험(RA-01~RA-10).

D6 은 Project 까지, D7 은 Keycloak group binding 까지다. 그 경계가 지켜지는지 확인한다.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
COPY_PATHS = ("contracts", "scripts/site/templates", "scripts/site/render-rancher.py")
OUTPUT = "platform/rancher/resources.yaml"

PASSED: list[str] = []
FAILED: list[str] = []


def workspace() -> pathlib.Path:
    root = pathlib.Path(tempfile.mkdtemp(prefix="render-rancher-test-"))
    for relative in COPY_PATHS:
        source, target = ROOT / relative, root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
    return root


def apply(root: pathlib.Path, mutate) -> None:
    path = root / "contracts" / "platform-production.yaml"
    contract = yaml.safe_load(path.read_text(encoding="utf-8"))
    mutate(contract["spec"], contract.setdefault("status", {}))
    path.write_text(yaml.safe_dump(contract, allow_unicode=True, sort_keys=False), encoding="utf-8")


def contract_spec(root: pathlib.Path) -> dict:
    """Project 이름은 계약이 정한다. 사이트를 옮겨도 시험이 따라오게 한다."""
    return yaml.safe_load(
        (root / "contracts" / "platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]


def project_names(root: pathlib.Path) -> list[str]:
    return [
        str(project["name"])
        for project in contract_spec(root).get("rancher", {}).get("projects") or []
    ]


def run(root: pathlib.Path, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(root / "scripts" / "site" / "render-rancher.py"), *arguments],
        capture_output=True,
        text=True,
        cwd=root,
    )


def documents(root: pathlib.Path) -> list[dict]:
    path = root / OUTPUT
    if not path.exists():
        return []
    return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]


def case(label: str, mutate, expect_success: bool, verify=None, arguments=()) -> None:
    root = workspace()
    apply(root, mutate)
    result = run(root, *arguments)
    detail = ""
    if (result.returncode == 0) != expect_success:
        detail = f"exit={result.returncode} expected_success={expect_success}"
    elif verify:
        detail = verify(root, result) or ""
    if detail:
        FAILED.append(label)
        print(f"[FAIL] {label}: {detail}")
        if result.stderr.strip():
            print("       " + result.stderr.strip().replace("\n", "\n       "))
    else:
        PASSED.append(label)
        print(f"[OK]   {label}")
    shutil.rmtree(root, ignore_errors=True)


def fill_groups(spec: dict, _status: dict) -> None:
    groups = {
        "platform-admin": "platform-admins",
        "app-admin": "app-admins",
        "developer": "developers",
        "viewer": "viewers",
    }
    for binding in spec["rancher"]["roleBindings"]:
        binding["group"] = groups[binding["role"]]


def projects_only(root: pathlib.Path, result) -> str:
    kinds = [d["kind"] for d in documents(root)]
    if kinds != ["Project", "Project"]:
        return f"group 미확정 상태에서 Project 외 문서가 생성됐다: {kinds}"
    if "미확정" not in result.stdout:
        return "생략된 역할을 알리는 경고가 없다"
    return ""


def all_bindings(root: pathlib.Path, _result) -> str:
    docs = documents(root)
    kinds = [d["kind"] for d in docs]
    if kinds.count("Project") != 2:
        return f"Project 수가 다르다: {kinds}"
    if kinds.count("GlobalRoleBinding") != 1:
        return "platform-admin GlobalRoleBinding 이 없다"
    # app-admin/developer 는 워크로드 Project 1개씩, viewer 는 2개 -> 총 4개
    if kinds.count("ProjectRoleTemplateBinding") != 4:
        return f"ProjectRoleTemplateBinding 수가 4 가 아니다: {kinds}"

    global_binding = next(d for d in docs if d["kind"] == "GlobalRoleBinding")
    if global_binding["globalRoleName"] != "admin":
        return "platform-admin 이 내장 admin GlobalRole 을 쓰지 않는다"
    if not global_binding["groupPrincipalName"].startswith("keycloakoidc_group://"):
        return f"group principal 형식이 다르다: {global_binding['groupPrincipalName']}"

    owner = next(
        d for d in docs
        if d["kind"] == "ProjectRoleTemplateBinding" and d["roleTemplateName"] == "project-owner"
    )
    workload_project = project_names(root)[0]
    if owner["metadata"]["namespace"] != workload_project:
        return "PRTB 가 Project backing Namespace 에 없다"
    if owner["projectName"] != f"local:{workload_project}":
        return f"projectName 형식이 다르다: {owner['projectName']}"

    # 사용자 계정이나 자격증명이 절대 들어가지 않아야 한다.
    body = (root / OUTPUT).read_text(encoding="utf-8")
    for forbidden in ("userPrincipalName", "password", "token"):
        if forbidden in body:
            return f"산출물에 '{forbidden}' 이 들어 있다"
    return ""


def viewer_two_projects(root: pathlib.Path, _result) -> str:
    namespaces = sorted(
        d["metadata"]["namespace"] for d in documents(root)
        if d["kind"] == "ProjectRoleTemplateBinding" and d["roleTemplateName"] == "read-only"
    )
    if namespaces != sorted(project_names(root)):
        return f"viewer binding 이 두 Project 에 없다: {namespaces}"
    return ""


case("RA-01 group 미확정이면 Project 만 생성한다", lambda spec, status: None, True, projects_only)
case("RA-02 group 확정 시 전체 binding 생성", fill_groups, True, all_bindings)
case("RA-03 viewer 는 두 Project 에 바인딩된다", fill_groups, True, viewer_two_projects)
case(
    "RA-04 계획서 7.2 밖의 역할 거부",
    lambda spec, status: spec["rancher"]["roleBindings"].append(
        {"role": "super-admin", "scope": "global", "globalRole": "admin", "group": "x"}
    ),
    False,
)
case(
    "RA-05 없는 Project 참조 거부",
    lambda spec, status: (
        fill_groups(spec, status),
        spec["rancher"]["roleBindings"][1]["projects"].append("nope-missing-project"),
    ),
    False,
)
case(
    "RA-06 알 수 없는 scope 거부",
    lambda spec, status: (
        fill_groups(spec, status),
        spec["rancher"]["roleBindings"][0].update({"scope": "cluster"}),
    ),
    False,
)
case(
    "RA-07 중복 역할 선언 거부",
    lambda spec, status: spec["rancher"]["roleBindings"].append(
        {"role": "viewer", "scope": "project", "roleTemplate": "read-only",
         "projects": [spec["rancher"]["projects"][0]["name"]], "group": "dup"}
    ),
    False,
)
case("RA-08 --check 는 미동기화 산출물을 잡는다", fill_groups, False, arguments=("--check",))
case(
    # Rancher 는 Project 이름과 같은 backing Namespace 를 만든다. 워크로드 Namespace 와
    # 이름이 겹치면 한 Namespace 가 워크로드와 RBAC 보관 두 용도로 섞인다.
    "RA-09 Project 이름이 워크로드 Namespace 와 겹치면 거부",
    lambda spec, status: spec["rancher"]["projects"][0].update(
        {"name": spec["rancher"]["projects"][0]["namespaces"][0]}
    ),
    False,
)
case(
    "RA-10 binding 에 개별 사용자/비밀번호 필드 거부",
    lambda spec, status: (
        fill_groups(spec, status),
        spec["rancher"]["roleBindings"][0].update({"user": "someone"}),
    ),
    False,
)

print(f"통과 {len(PASSED)} / 실패 {len(FAILED)}")
raise SystemExit(1 if FAILED else 0)
