#!/usr/bin/env python3
"""설치된 Keycloak 수렴 명령의 plan/apply/credential 경계를 fake kcadm으로 검증한다."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/cluster/configure-keycloak.sh"
WRAPPER = ROOT / "scripts/cluster/keycloak-kcadm-in-pod.sh"
PASSED = 0
FAILED = 0


def write_executable(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def check(condition: bool, label: str, detail: str = "") -> None:
    global PASSED, FAILED
    if condition:
        PASSED += 1
        print(f"[OK]   {label}")
        return
    FAILED += 1
    print(f"[FAIL] {label}{': ' + detail if detail else ''}")


def run(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


FAKE_KCADM = r'''#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import pathlib
import sys

state_path = pathlib.Path(os.environ["MOCK_KCADM_STATE"])
if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8"))
else:
    state = {
        "realm": None, "groups": [], "default_groups": [], "clients": {},
        "roles": [], "client_roles": {}, "role_mappings": [], "users": [],
        "creates": {"realm": 0, "group": 0, "client": 0, "user": 0},
    }

args = sys.argv[1:]
stdin = sys.stdin.buffer.read()

def save():
    state_path.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")

def arg_after(flag, default=""):
    try:
        return args[args.index(flag) + 1]
    except (ValueError, IndexError):
        return default

def set_value(prefix):
    for index, value in enumerate(args):
        if value == "-s" and index + 1 < len(args) and args[index + 1].startswith(prefix + "="):
            return args[index + 1].split("=", 1)[1]
    return ""

if args[:2] == ["config", "credentials"]:
    rows = stdin.splitlines()
    if len(rows) != 2:
        raise SystemExit(12)
    user = base64.b64decode(rows[0])
    password = base64.b64decode(rows[1])
    expected = os.environ["MOCK_ADMIN_PASSWORD"].encode()
    if password != expected or not user:
        raise SystemExit(13)
    state["auth_password_sha256"] = hashlib.sha256(password).hexdigest()
    save()
    if os.environ.get("MOCK_KCADM_FAIL_AUTH") == "1":
        raise SystemExit(14)
    raise SystemExit(0)

if len(args) < 2:
    raise SystemExit(2)
operation, endpoint = args[:2]

if operation == "get" and endpoint.startswith("realms/"):
    if state["realm"] is None:
        raise SystemExit(1)
    print(json.dumps(state["realm"]))
elif operation == "create" and endpoint == "realms":
    state["realm"] = json.loads(stdin)
    state["creates"]["realm"] += 1
elif operation == "update" and endpoint.startswith("realms/"):
    state["realm"] = json.loads(stdin)
elif operation == "get" and endpoint == "groups":
    wanted = arg_after("-q").removeprefix("search=")
    print(json.dumps([row for row in state["groups"] if not wanted or row["name"] == wanted]))
elif operation == "create" and endpoint == "groups":
    name = set_value("name")
    row = {"id": f"group-{len(state['groups']) + 1}", "name": name}
    state["groups"].append(row)
    state["creates"]["group"] += 1
elif operation == "update" and endpoint.startswith("default-groups/"):
    group_id = endpoint.split("/", 1)[1]
    if group_id not in state["default_groups"]:
        state["default_groups"].append(group_id)
elif operation == "get" and endpoint == "clients":
    wanted = arg_after("-q").removeprefix("clientId=")
    rows = []
    for client_id, client in state["clients"].items():
        if not wanted or client_id == wanted:
            rows.append({"id": client["id"], "clientId": client_id})
    print(json.dumps(rows))
elif operation == "create" and endpoint == "clients":
    document = json.loads(stdin)
    client_id = document["clientId"]
    client_uuid = f"client-{len(state['clients']) + 1}"
    state["clients"][client_id] = {
        "id": client_uuid, "secret": f"kept-{client_id}-secret",
        "document": document, "mappers": [],
    }
    state["creates"]["client"] += 1
    if "-i" in args:
        print(client_uuid)
elif operation == "update" and endpoint.startswith("clients/") and "/protocol-mappers/" not in endpoint:
    client_uuid = endpoint.split("/")[1]
    document = json.loads(stdin)
    client = next(row for row in state["clients"].values() if row["id"] == client_uuid)
    client["document"] = document
elif operation == "get" and endpoint.endswith("/protocol-mappers/models"):
    client_uuid = endpoint.split("/")[1]
    client = next(row for row in state["clients"].values() if row["id"] == client_uuid)
    print(json.dumps(client["mappers"]))
elif operation == "create" and endpoint.endswith("/protocol-mappers/models"):
    client_uuid = endpoint.split("/")[1]
    client = next(row for row in state["clients"].values() if row["id"] == client_uuid)
    document = json.loads(stdin)
    document["id"] = f"mapper-{client_uuid}"
    client["mappers"].append(document)
elif operation == "update" and "/protocol-mappers/models/" in endpoint:
    client_uuid = endpoint.split("/")[1]
    client = next(row for row in state["clients"].values() if row["id"] == client_uuid)
    document = json.loads(stdin)
    client["mappers"] = [document]
elif operation == "get" and endpoint.endswith("/client-secret"):
    client_uuid = endpoint.split("/")[1]
    client = next(row for row in state["clients"].values() if row["id"] == client_uuid)
    print(json.dumps({"value": client["secret"]}))
elif endpoint.startswith("roles/") and operation == "get":
    role = endpoint.split("/", 1)[1]
    if role not in state["roles"]:
        raise SystemExit(1)
    print(json.dumps({"name": role}))
elif endpoint == "roles" and operation == "create":
    role = set_value("name")
    if role not in state["roles"]:
        state["roles"].append(role)
elif "/roles/" in endpoint and endpoint.startswith("clients/") and operation == "get":
    _, client_uuid, _, role = endpoint.split("/", 3)
    if role not in state["client_roles"].get(client_uuid, []):
        raise SystemExit(1)
    print(json.dumps({"name": role}))
elif endpoint.endswith("/roles") and endpoint.startswith("clients/") and operation == "create":
    client_uuid = endpoint.split("/")[1]
    role = set_value("name")
    state["client_roles"].setdefault(client_uuid, [])
    if role not in state["client_roles"][client_uuid]:
        state["client_roles"][client_uuid].append(role)
elif operation == "add-roles":
    mapping = " ".join(args[1:])
    if mapping not in state["role_mappings"]:
        state["role_mappings"].append(mapping)
elif operation == "get" and endpoint == "users":
    print(json.dumps(state["users"]))
elif operation == "create" and endpoint == "users":
    document = json.loads(stdin)
    user_id = f"user-{len(state['users']) + 1}"
    document["id"] = user_id
    state["users"].append(document)
    state["creates"]["user"] += 1
    if "-i" in args:
        print(user_id)
elif operation == "update" and endpoint.startswith("users/"):
    parts = endpoint.split("/")
    user = next(row for row in state["users"] if row["id"] == parts[1])
    if len(parts) == 2:
        document = json.loads(stdin)
        document["id"] = parts[1]
        user.clear()
        user.update(document)
    elif parts[2] == "reset-password":
        credential = json.loads(stdin)
        state["acceptance_password_sha256"] = hashlib.sha256(
            credential["value"].encode()
        ).hexdigest()
    elif parts[2] == "groups":
        user.setdefault("groups", [])
        if parts[3] not in user["groups"]:
            user["groups"].append(parts[3])
else:
    print("unsupported fake kcadm call", operation, endpoint, file=sys.stderr)
    raise SystemExit(3)

save()
'''


with tempfile.TemporaryDirectory(prefix="sadp-keycloak-test-") as raw_tmp:
    tmp = pathlib.Path(raw_tmp)
    fake_bin = tmp / "bin"
    fake_bin.mkdir()
    admin_user = tmp / "admin-user"
    admin_password = tmp / "admin-password"
    password_marker = "do-not-print-admin-password"
    admin_user.write_text("admin-fixture", encoding="utf-8")
    admin_password.write_text(password_marker, encoding="utf-8")
    admin_user.chmod(0o600)
    admin_password.chmod(0o600)

    real_stat = shutil.which("stat") or "/usr/bin/stat"
    write_executable(
        fake_bin / "id",
        """#!/usr/bin/env bash
[[ ${1:-} == -u ]] && { printf '0\\n'; exit 0; }
exec /usr/bin/id "$@"
""",
    )
    write_executable(
        fake_bin / "stat",
        f"""#!/usr/bin/env bash
if [[ $1 == -c && $2 == %u ]]; then printf '0\\n'; exit 0; fi
exec {real_stat!s} "$@"
""",
    )
    write_executable(fake_bin / "chown", "#!/usr/bin/env bash\nexit 0\n")

    kubectl_log = tmp / "kubectl.log"
    kubectl_stdin = tmp / "kubectl-stdin.log"
    write_executable(
        fake_bin / "kubectl",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${MOCK_KUBECTL_LOG}"
if [[ ! -t 0 ]]; then cat >>"${MOCK_KUBECTL_STDIN}"; fi
exit 0
""",
    )
    fake_kcadm_py = tmp / "fake-kcadm.py"
    write_executable(fake_kcadm_py, FAKE_KCADM)
    fake_runner = tmp / "fake-kcadm-runner.sh"
    write_executable(
        fake_runner,
        """#!/usr/bin/env bash
set -euo pipefail
exec python3 "${MOCK_KCADM_PY}" "$@"
""",
    )

    state = tmp / "kcadm-state.json"
    state_dir = tmp / "state"
    base_env = os.environ | {
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "KUBECTL_BIN": str(fake_bin / "kubectl"),
        "KUBECONFIG_PATH": str(tmp / "kubeconfig"),
        "MOCK_KUBECTL_LOG": str(kubectl_log),
        "MOCK_KUBECTL_STDIN": str(kubectl_stdin),
        "MOCK_KCADM_PY": str(fake_kcadm_py),
        "MOCK_KCADM_STATE": str(state),
        "MOCK_ADMIN_PASSWORD": password_marker,
        "SADP_KCADM_RUNNER": str(fake_runner),
        "SADP_STATE_DIR": str(state_dir),
    }
    command = [
        "bash",
        str(SCRIPT),
        "--admin-user-file",
        str(admin_user),
        "--admin-password-file",
        str(admin_password),
    ]

    kubectl_log.write_text("", encoding="utf-8")
    plan = run(command, base_env)
    plan_output = plan.stdout + plan.stderr
    check(plan.returncode == 0 and "적용하려면" in plan_output, "KC-plan is read-only")
    check(kubectl_log.read_text(encoding="utf-8") == "", "KC-plan does not call kubectl")
    check(password_marker not in plan_output, "KC-plan does not print administrator password")

    rejected = run(command + ["--server-url", "https://attacker.example.invalid"], base_env)
    check(
        rejected.returncode != 0 and "server-url host" in rejected.stderr,
        "KC-arbitrary server host rejected",
    )
    check(password_marker not in rejected.stdout + rejected.stderr, "KC-rejection does not leak password")

    contract = yaml.safe_load((ROOT / "contracts/platform-production.yaml").read_text(encoding="utf-8"))
    empty_idp_contract = tmp / "contract-empty-idp.yaml"
    full_idp_contract = tmp / "contract-full-idp.yaml"
    partial_idp_contract = tmp / "contract-partial-idp.yaml"
    contract["spec"]["keycloak"]["identityProvider"] = {}
    empty_idp_contract.write_text(yaml.safe_dump(contract), encoding="utf-8")
    contract["spec"]["keycloak"]["identityProvider"] = {
        "alias": "fixture-idp",
        "displayName": "Fixture IdP",
        "providerId": "saml",
        "metadataDescriptorUrl": "https://idp.example.invalid/metadata",
        "singleSignOnServiceUrl": "https://idp.example.invalid/sso",
    }
    full_idp_contract.write_text(yaml.safe_dump(contract), encoding="utf-8")
    contract["spec"]["keycloak"]["identityProvider"]["singleSignOnServiceUrl"] = ""
    partial_idp_contract.write_text(yaml.safe_dump(contract), encoding="utf-8")
    empty_result = run(command, base_env | {"SADP_CONTRACT_FILE": str(empty_idp_contract)})
    full_result = run(command, base_env | {"SADP_CONTRACT_FILE": str(full_idp_contract)})
    partial_result = run(command, base_env | {"SADP_CONTRACT_FILE": str(partial_idp_contract)})
    check(empty_result.returncode == 0, "KC-empty SAML IdP contract allowed")
    check(full_result.returncode == 0 and "SAML IdP" in full_result.stdout, "KC-full SAML IdP contract allowed")
    check(
        partial_result.returncode != 0 and "모두 비우거나 모두 설정" in partial_result.stderr,
        "KC-partial SAML IdP contract rejected",
    )

    apply_first = run(command + ["--apply"], base_env)
    first_output = apply_first.stdout + apply_first.stderr
    first_state = json.loads(state.read_text(encoding="utf-8")) if state.exists() else {}
    expected_clients = {"secure-demo-prod", "openbao", contract["spec"]["keycloak"]["portalClientID"]}
    check(apply_first.returncode == 0, "KC-empty fake state converges", first_output[-1000:])
    check(
        first_state.get("creates") == {"realm": 1, "group": 4, "client": 3, "user": 1}
        and set(first_state.get("clients", {})) == expected_clients,
        "KC-first apply creates realm/groups/clients/user exactly once",
    )
    secret_dir = state_dir / "credentials"
    first_secrets = {
        path.name: path.read_text(encoding="utf-8")
        for path in secret_dir.glob("keycloak-*-client-secret")
    }
    check(
        len(first_secrets) == 3
        and all(value.startswith("kept-") for value in first_secrets.values()),
        "KC-Keycloak-generated client secrets recovered to state files",
    )
    check(password_marker not in first_output, "KC-apply does not print administrator password")

    apply_second = run(command + ["--apply"], base_env)
    second_state = json.loads(state.read_text(encoding="utf-8"))
    second_secrets = {
        path.name: path.read_text(encoding="utf-8")
        for path in secret_dir.glob("keycloak-*-client-secret")
    }
    check(apply_second.returncode == 0, "KC-repeat apply succeeds")
    check(
        second_state["creates"] == first_state["creates"]
        and len(second_state["groups"]) == 4
        and len(second_state["clients"]) == 3
        and len(second_state["users"]) == 1,
        "KC-repeat apply updates without duplicate resources",
    )
    check(first_secrets == second_secrets, "KC-existing client secrets preserved and re-retrieved")
    expected_hash = hashlib.sha256(password_marker.encode()).hexdigest()
    check(
        second_state.get("auth_password_sha256") == expected_hash,
        "KC-administrator password reaches fake kcadm through stdin",
    )

    wrapper_log = tmp / "wrapper-kubectl.log"
    wrapper_stdin = tmp / "wrapper-kubectl.stdin"
    wrapper_kubectl = tmp / "wrapper-kubectl"
    write_executable(
        wrapper_kubectl,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >"${WRAPPER_LOG}"
cat >"${WRAPPER_STDIN}"
""",
    )
    encoded_user = base64.b64encode(b"fixture-admin").decode()
    encoded_password = base64.b64encode(password_marker.encode()).decode()
    wrapper_result = subprocess.run(
        ["bash", str(WRAPPER), "config", "credentials", "--server", "https://sso.example.invalid", "--realm", "master"],
        cwd=ROOT,
        env=os.environ
        | {
            "KUBECTL_BIN": str(wrapper_kubectl),
            "KUBECONFIG_PATH": str(tmp / "kubeconfig"),
            "SADP_KCADM_POD": "pod/keycloak-cli",
            "SADP_KCADM_NAMESPACE": "keycloak",
            "SADP_KCADM_CONFIG": "/tmp/test-kcadm.config",
            "WRAPPER_LOG": str(wrapper_log),
            "WRAPPER_STDIN": str(wrapper_stdin),
        },
        input=f"{encoded_user}\n{encoded_password}\n",
        capture_output=True,
        text=True,
        check=False,
    )
    wrapper_argv = wrapper_log.read_text(encoding="utf-8")
    wrapper_payload = wrapper_stdin.read_text(encoding="utf-8")
    check(
        wrapper_result.returncode == 0
        and password_marker not in wrapper_argv
        and encoded_password not in wrapper_argv
        and wrapper_payload.splitlines() == [encoded_user, encoded_password],
        "KC-wrapper keeps password out of kubectl argv and uses stdin",
    )

    external_contract = yaml.safe_load(empty_idp_contract.read_text(encoding="utf-8"))
    external_contract["spec"]["keycloak"]["deployment"] = "external"
    external_contract["spec"]["keycloak"]["external"] = {"address": "192.0.2.99", "port": 8080}
    external_contract_path = tmp / "contract-external.yaml"
    external_contract_path.write_text(yaml.safe_dump(external_contract), encoding="utf-8")
    kubectl_log.write_text("", encoding="utf-8")
    kubectl_stdin.write_text("", encoding="utf-8")
    external_env = base_env | {"SADP_CONTRACT_FILE": str(external_contract_path)}
    external_result = run(command + ["--apply"], external_env)
    kube_calls = kubectl_log.read_text(encoding="utf-8")
    pod_manifest = kubectl_stdin.read_text(encoding="utf-8")
    pinned_version = str(yaml.safe_load((ROOT / "versions.lock.yaml").read_text())["platform"]["keycloak"])
    check(external_result.returncode == 0, "KC-external apply uses in-cluster CLI Pod")
    check(
        f"image: quay.io/keycloak/keycloak:{pinned_version}" in pod_manifest
        and "automountServiceAccountToken: false" in pod_manifest
        and "runAsNonRoot: true" in pod_manifest
        and "allowPrivilegeEscalation: false" in pod_manifest
        and "drop: [ALL]" in pod_manifest
        and "type: RuntimeDefault" in pod_manifest
        and "volumes:" not in pod_manifest,
        "KC-ephemeral Pod has pinned image and minimum privileges",
    )
    check(" delete -n keycloak pod/sadp-keycloak-kcadm-" in f" {kube_calls}", "KC-success cleanup deletes ephemeral Pod")

    kubectl_log.write_text("", encoding="utf-8")
    failed_external = run(
        command + ["--apply"],
        external_env | {"MOCK_KCADM_FAIL_AUTH": "1"},
    )
    failed_calls = kubectl_log.read_text(encoding="utf-8")
    check(
        failed_external.returncode != 0
        and " delete -n keycloak pod/sadp-keycloak-kcadm-" in f" {failed_calls}",
        "KC-failure cleanup deletes ephemeral Pod and session",
    )
    check(password_marker not in failed_external.stdout + failed_external.stderr, "KC-failure does not leak password")

shell_files = sorted(ROOT.rglob("*.sh")) + [ROOT / "sadp"]
syntax_failures = []
for shell_file in shell_files:
    result = subprocess.run(["bash", "-n", str(shell_file)], capture_output=True, text=True, check=False)
    if result.returncode:
        syntax_failures.append(str(shell_file.relative_to(ROOT)))
check(not syntax_failures, "KC-all shell files pass bash -n", ", ".join(syntax_failures))

docs_text = (ROOT / "docs/installation.md").read_text(encoding="utf-8")
sadp_list = subprocess.run(
    ["bash", str(ROOT / "sadp"), "--list"], capture_output=True, text=True, check=False
)
check(
    sadp_list.returncode == 0 and "--configure-keycloak" in sadp_list.stdout,
    "KC-entrypoint lists --configure-keycloak",
)
for flag in ("--configure-keycloak", "--server-url", "--admin-user-file", "--admin-password-file", "--apply"):
    check(flag in docs_text, f"KC-documentation includes {flag}")

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
