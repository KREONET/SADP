#!/usr/bin/env python3
"""Registry credential 분리와 secret argv 회귀를 정적/계획 모드로 검증한다."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "scripts/cluster/deploy-testbed-apps.sh"
BOOTSTRAP = ROOT / "scripts/cluster/bootstrap-testbed-services.sh"
CONFIGURE = ROOT / "scripts/ops/configure-openbao-app-access.sh"
CONFIGURE_OIDC = ROOT / "scripts/ops/configure-openbao-oidc.sh"
VERIFY = ROOT / "scripts/verify/verify-testbed.sh"
INSTALL_PORTAL = ROOT / "scripts/cluster/install-portal-backend.sh"
BACKUP = ROOT / "scripts/ops/backup-testbed.sh"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"[OK]   {message}")


def typed_name(prefix: str, slug: str, canonical: str) -> str:
    digest = hashlib.sha256(f"{prefix}|{canonical}".encode()).hexdigest()[:10]
    room = 63 - len(prefix.encode()) - 11
    human = slug.encode()[:room].decode("ascii").rstrip("-")
    return f"{prefix}{human}-{digest}"


for script in (DEPLOY, BOOTSTRAP, CONFIGURE, CONFIGURE_OIDC, VERIFY, INSTALL_PORTAL, BACKUP):
    subprocess.run(["bash", "-n", str(script)], check=True, cwd=ROOT)
check(True, "registry/OpenBao 운영 스크립트 bash syntax")

deploy = DEPLOY.read_text(encoding="utf-8")
bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
configure = CONFIGURE.read_text(encoding="utf-8")
verify = VERIFY.read_text(encoding="utf-8")

check(
    "--registry-pull-dockerconfig" in deploy
    and "--registry-push-dockerconfig" in deploy,
    "pull/push Docker config 독립 입력",
)
check(
    "validate_root_dockerconfig" in deploy
    and "pull/push Docker config가 동일함" in deploy
    and "Kubernetes Secret 이름이 같음" in deploy,
    "root-only 파일 및 동일 credential/Secret fail-close",
)
check(
    "pull_config | jq -Rs" in deploy
    and "push_config | jq -Rs" not in deploy,
    "OpenBao registry seed는 pull 전용 입력만 사용",
)
check(
    "push 자격증명 없음" in deploy and "pull 자격증명 없음" in deploy,
    "자격증명 누락 시 AppGroup/build 준비를 건너뛰지 않음",
)
check(
    "registry pull/push Docker config가 동일함" in verify,
    "cluster acceptance가 pull/push 분리를 검증",
)

secret_argv_scripts = (
    (BOOTSTRAP, bootstrap),
    (DEPLOY, deploy),
    (CONFIGURE, configure),
    (CONFIGURE_OIDC, CONFIGURE_OIDC.read_text(encoding="utf-8")),
    (INSTALL_PORTAL, INSTALL_PORTAL.read_text(encoding="utf-8")),
    (BACKUP, BACKUP.read_text(encoding="utf-8")),
)
for path, body in secret_argv_scripts:
    forbidden = (
        r"BAO_TOKEN\s*=\s*[\"']?\$\{",
        r"BAO_TOKEN\s*=\s*[\"']?\$\(",
        r"--password\s+[\"']?\$\{",
        r"operator\s+unseal\s+[\"']?\$\{",
        r"oidc_client_secret=[\"']?\$\{",
    )
    for pattern in forbidden:
        check(not re.search(pattern, body), f"{path.name}: secret kubectl exec argv 금지 ({pattern})")

check("--app-group" in configure, "OpenBao 운영 명령의 AppGroup 전용 인자")
check(
    'policy write "${ESO_ROLE}"' not in configure
    and 'policy write "${REGISTRY_ROLE}"' not in configure
    and not re.search(
        r'bao\s+write\s+"auth/kubernetes/role/\$\{(?:ESO|REGISTRY)_ROLE\}"',
        configure,
    ),
    "운영 명령이 동적 ESO policy/auth role을 생성하지 않음",
)

writer_policy = bootstrap.split("policy write portal-app-secret-writer", 1)[1].split("\nHCL", 1)[0]
writer_control_lines = [
    line
    for line in writer_policy.splitlines()
    if "sys/policies/acl/" in line or "auth/kubernetes/role/" in line
]
check(
    len(writer_control_lines) == 11,
    "Portal writer가 고정 자원과 기존 앱별 policy/role만 read/deny로 조회",
)
for line in writer_control_lines:
    check(
        ('capabilities = ["read"]' in line or 'capabilities = ["deny"]' in line)
        and not any(word in line for word in ('"create"', '"update"', '"delete"')),
        f"Portal writer는 policy/auth endpoint read-only: {line.strip()}",
    )
check(
    'path "sys/policies/acl/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-*" { capabilities = ["read"] }'
    in writer_policy
    and 'path "auth/kubernetes/role/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-*" { capabilities = ["read"] }'
    in writer_policy,
    "기존 신청 resume는 앱별 ESO policy/role을 조회만 함",
)
check(
    'path "kv/subkeys/${REGISTRY_PULL_REMOTE_PATH}" { capabilities = ["read"] }'
    in writer_policy,
    "Portal writer는 registry key 이름만 exact subkeys endpoint에서 확인",
)
check(
    'path "kv/subkeys/${kv_prefix}/workloads/*" { capabilities = ["read"] }'
    in writer_policy,
    "Portal writer는 workload key 이름만 canonical subkeys 경계에서 확인",
)
check(
    'path "kv/data/${kv_prefix}/+" { capabilities = ["create", "update", "patch"] }'
    in writer_policy
    and 'path "kv/metadata/${kv_prefix}/+" { capabilities = ["read", "delete"] }'
    in writer_policy
    and 'path "kv/data/${kv_prefix}/*"' not in writer_policy,
    "기존 신청 KV 호환 권한은 project/env 바로 아래 한 segment로 제한",
)
for protected in ("eso-portal-lite", "eso-secure-demo"):
    check(
        f'kv/subkeys/${{kv_prefix}}/workloads/${{app_namespace}}/{protected}' in writer_policy
        and 'capabilities = ["deny"]' in writer_policy.split(
            f'kv/subkeys/${{kv_prefix}}/workloads/${{app_namespace}}/{protected}', 1
        )[1].split("\n", 1)[0],
        f"Portal writer workload subkeys에서 플랫폼 앱 보호: {protected}",
    )
for fixed_resource in (
    "portal-zone-app-eso",
    "portal-group-app-eso",
    "portal-group-registry-eso",
    "portal-workload-secret-reader",
    "portal-registry-pull-reader",
):
    check(fixed_resource in bootstrap, f"bootstrap 고정 OpenBao 자원: {fixed_resource}")
for legacy_app in ("portal-lite", "secure-demo"):
    check(
        f'grant_legacy_static_secret_access {legacy_app}' in bootstrap
        and f'seed_kv_file_key "${{kv_prefix}}/{legacy_app}"' in bootstrap,
        f"기존 정적 앱 exact OpenBao role/path bootstrap 유지: {legacy_app}",
    )
    check(
        f'kv/data/${{kv_prefix}}/{legacy_app}' in writer_policy
        and 'capabilities = ["deny"]' in writer_policy.split(
            f'kv/data/${{kv_prefix}}/{legacy_app}', 1
        )[1].split("\n", 1)[0],
        f"Portal writer에서 기존 정적 앱 exact 경로 보호: {legacy_app}",
    )

legacy_app_policy = bootstrap.split("policy write app-secrets", 1)[1].split("\nHCL", 1)[0]
check(
    "kv/data/" not in legacy_app_policy and "kv/metadata/" not in legacy_app_policy,
    "legacy app-secrets policy에 프로젝트 wildcard Secret 권한 없음",
)
check(
    "oidc_role app-admin app-user" in bootstrap
    and "oidc_role developer app-user" in bootstrap,
    "app-admin/developer 기본 role은 Secret 없는 app-user로 하향",
)
check(
    'bao_input kv patch -mount=kv "${remote_path}" "${key}=-"' in bootstrap
    and 'bao_input kv put -mount=kv "${remote_path}" "${key}=-"' in bootstrap,
    "bootstrap은 기존 KV 문서를 key patch하고 최초 문서만 put",
)
portal_seed = bootstrap.split(
    'seed_kv_file_key "${kv_prefix}/portal-lite" AUTH_OIDC_SECRET', 1
)[1].split('if ! bao auth list', 1)[0]
check(
    "FORGEJO_BOT_TOKEN" not in portal_seed,
    "bootstrap Portal 시드는 공용 Forgejo 봇 token key를 덮어쓰거나 삭제하지 않음",
)

# 실제 클러스터를 건드리지 않는 계획 모드에서 Go/Chart와 같은 canonical/hash 이름을 확인한다.
portal = yaml.safe_load((ROOT / "apps/portal-lite/values-beta.yaml").read_text(encoding="utf-8"))
project = str(portal["app"]["project"])
environment = str(portal["app"]["environment"])
contract_values = yaml.safe_load(
    (ROOT / "contracts/values-platform-production.yaml").read_text(encoding="utf-8")
)["platform"]
fixed_roles = contract_values["openbao"]["roles"]
group = "mobility-platform"
app = "api"
canonical_app = f"v1/app/{project}/{environment}/{group}/{app}"
group_sa = typed_name("eso-sa-a-", app, canonical_app)

with tempfile.TemporaryDirectory(prefix="sadp-registry-test-") as temp_dir:
    fake_id = Path(temp_dir) / "id"
    fake_id.write_text("#!/usr/bin/env sh\nprintf '0\\n'\n", encoding="utf-8")
    fake_id.chmod(0o700)
    environment_vars = os.environ.copy()
    environment_vars["PATH"] = f"{temp_dir}:{environment_vars['PATH']}"
    group_result = subprocess.run(
        ["bash", str(CONFIGURE), "--app", app, "--app-group", group],
        cwd=ROOT,
        env=environment_vars,
        check=True,
        text=True,
        capture_output=True,
    )
    zone_result = subprocess.run(
        ["bash", str(CONFIGURE), "--app", app],
        cwd=ROOT,
        env=environment_vars,
        check=True,
        text=True,
        capture_output=True,
    )
for name in (fixed_roles["groupApp"], fixed_roles["groupRegistry"], group_sa, "eso-registry"):
    check(name in group_result.stdout, f"AppGroup fixed role/identity 일치: {name}")
check(
    f"kv/apps/{project}/{environment}/workloads/"
    f"{contract_values['appGroups']['namespacePrefix']}{group}/{group_sa}"
    in group_result.stdout,
    "AppGroup workload Secret 경로가 Namespace/ESO SA exact",
)
check(fixed_roles["zoneApp"] in zone_result.stdout, "단일 앱 fixed ESO role 일치")
check(
    f"kv/apps/{project}/{environment}/workloads/"
    f"{contract_values['portal']['namespace']}/eso-{app}"
    in zone_result.stdout,
    "단일 앱 workload Secret 경로가 Namespace/ESO SA exact",
)

print("registry credential/OpenBao ops regression test passed")
