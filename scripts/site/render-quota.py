#!/usr/bin/env python3
"""Render workload Namespace ResourceQuota and LimitRange from the platform contract.

사용자당 상한(3 CPU / 5Gi)은 세 곳에서 따로 판단된다.

  UI      신규 앱 위저드가 preset x replicas 를 더해 미리 막는다.
  서버    배포 신청 POST 를 apps/portal-lite/quota.go 가 다시 계산해 거부한다.
  클러스터 이 스크립트가 만드는 ResourceQuota/LimitRange 가 마지막으로 막는다.

앞의 둘은 포털을 거친 요청에만 걸린다. 포털을 우회해 kubectl/ArgoCD 로 직접 넣은 Pod 는
클러스터 단계에서만 막을 수 있어서 세 번째가 필요하다. 반대로 세 값이 어긋나면 "UI 는
통과했는데 배포가 거부되는" 상태가 되므로, 계약과 quota.go 기본값이 다르면 실패한다.

베타는 워크로드 Namespace 를 사용자별로 나누지 않는다. 그래서 Namespace 총량은
1인 상한 x policy.userQuota.maxUsers 로 잡고, 개별 Pod/Container 는 LimitRange 로
1인 상한을 넘지 못하게 한다. 사용자별 Namespace 분리는 후속 과제다.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "contracts" / "platform-production.yaml"
QUOTA_SOURCE = ROOT / "apps" / "portal-lite" / "quota.go"
UI_QUOTA_SOURCE = ROOT / "apps" / "portal-lite" / "ui" / "lib" / "quota.ts"
OUTPUT = ROOT / "platform" / "quota" / "resources.yaml"

KUBE_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
MEMORY_SUFFIXES = (
    ("Ki", 1 << 10),
    ("Mi", 1 << 20),
    ("Gi", 1 << 30),
    ("Ti", 1 << 40),
    ("K", 1000),
    ("M", 1000**2),
    ("G", 1000**3),
    ("T", 1000**4),
)
# Pod 하나가 최소한 요청해야 하는 값. 0 으로 두면 request 없는 Pod 가 Namespace 총량을
# 소모하지 않으면서 노드를 채운다.
MIN_CONTAINER_CPU = "10m"
MIN_CONTAINER_MEMORY = "16Mi"
# charts/app-profile/values.yaml 의 기본 resources 와 같아야 한다. LimitRange default 가
# 더 작으면 values 를 지운 앱이 조용히 축소되고, 더 크면 총량이 예상보다 빨리 찬다.
DEFAULT_CONTAINER_CPU_REQUEST = "100m"
DEFAULT_CONTAINER_MEMORY_REQUEST = "128Mi"
DEFAULT_CONTAINER_CPU_LIMIT = "500m"
DEFAULT_CONTAINER_MEMORY_LIMIT = "512Mi"

HEADER = (
    "# 자동 생성 파일. contracts/platform-production.yaml을 수정한 뒤 scripts/site/render-quota.py를 실행한다.\n"
    "# 사용자당 상한은 policy.userQuota 하나로 정한다. UI(위저드)와 서버 검증\n"
    "# (apps/portal-lite/quota.go)이 같은 값을 쓰는지는 render-quota.py가 대조한다.\n"
)


def load_contract() -> dict:
    document = yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))
    if document.get("kind") != "PlatformContract":
        raise ValueError("contracts/platform-production.yaml kind must be PlatformContract")
    return document["spec"]


def parse_cpu_milli(value: object) -> int:
    """apps/portal-lite/quota.go 의 parseCPUMilli 와 같은 규칙으로 읽는다."""
    text = str(value or "").strip()
    if not text:
        raise ValueError("empty cpu quantity")
    if text.endswith("m"):
        milli = int(text[:-1].strip())
        if milli < 0:
            raise ValueError(f"negative cpu quantity: {text}")
        return milli
    cores = float(text)
    if cores < 0:
        raise ValueError(f"negative cpu quantity: {text}")
    return int(cores * 1000 + 0.5)


def parse_memory_bytes(value: object) -> int:
    """apps/portal-lite/quota.go 의 parseMemoryBytes 와 같은 규칙으로 읽는다."""
    text = str(value or "").strip()
    if not text:
        raise ValueError("empty memory quantity")
    for suffix, factor in MEMORY_SUFFIXES:
        if text.endswith(suffix):
            amount = float(text[: -len(suffix)].strip())
            if amount < 0:
                raise ValueError(f"negative memory quantity: {text}")
            return int(amount * factor + 0.5)
    amount = int(text)
    if amount < 0:
        raise ValueError(f"negative memory quantity: {text}")
    return amount


def format_cpu_milli(milli: int) -> str:
    return str(milli // 1000) if milli % 1000 == 0 else f"{milli}m"


def format_memory_bytes(size: int) -> str:
    if size >= 1 << 30 and size % (1 << 30) == 0:
        return f"{size // (1 << 30)}Gi"
    if size >= 1 << 20 and size % (1 << 20) == 0:
        return f"{size // (1 << 20)}Mi"
    return str(size)


def go_defaults() -> dict[str, str]:
    """quota.go 의 기본 상한을 읽는다. Go 를 실행하지 않고 상수 선언만 본다."""
    source = QUOTA_SOURCE.read_text(encoding="utf-8")
    wanted = {
        "cpu": r'defaultUserQuotaCPU\s*=\s*"([^"]+)"',
        "memory": r'defaultUserQuotaMemory\s*=\s*"([^"]+)"',
        "maxReplicas": r"maxAppReplicas\s*=\s*(\d+)",
    }
    found: dict[str, str] = {}
    for key, pattern in wanted.items():
        match = re.search(pattern, source)
        if not match:
            raise ValueError(f"{QUOTA_SOURCE.name} 에서 {key} 기본값을 찾지 못했다")
        found[key] = match.group(1)
    return found


def ui_defaults() -> dict[str, str]:
    """위저드가 쓰는 상한을 읽는다. UI 가 서버보다 느슨하면 통과시킨 뒤 배포가 거부된다."""
    source = UI_QUOTA_SOURCE.read_text(encoding="utf-8")
    wanted = {
        "cpu": r'USER_QUOTA\s*=\s*\{[^}]*?\bcpu:\s*"([^"]+)"',
        "memory": r'USER_QUOTA\s*=\s*\{[^}]*?\bmemory:\s*"([^"]+)"',
        "maxReplicas": r"MAX_APP_REPLICAS\s*=\s*(\d+)",
    }
    found: dict[str, str] = {}
    for key, pattern in wanted.items():
        match = re.search(pattern, source, re.DOTALL)
        if not match:
            raise ValueError(f"{UI_QUOTA_SOURCE.name} 에서 {key} 기본값을 찾지 못했다")
        found[key] = match.group(1)
    return found


def user_quota(specification: dict) -> dict:
    quota = ((specification.get("policy") or {}).get("userQuota")) or {}
    if not quota:
        raise ValueError("spec.policy.userQuota is missing")

    cpu_milli = parse_cpu_milli(quota.get("cpu"))
    memory_bytes = parse_memory_bytes(quota.get("memory"))
    if cpu_milli <= 0 or memory_bytes <= 0:
        raise ValueError("spec.policy.userQuota.cpu/memory must be greater than zero")

    max_replicas = int(quota.get("maxReplicas") or 0)
    max_users = int(quota.get("maxUsers") or 0)
    if max_replicas < 1:
        raise ValueError("spec.policy.userQuota.maxReplicas must be at least 1")
    if max_users < 1:
        raise ValueError("spec.policy.userQuota.maxUsers must be at least 1")

    namespaces = [str(name) for name in quota.get("namespaces") or []]
    if not namespaces:
        raise ValueError("spec.policy.userQuota.namespaces must not be empty")
    for name in namespaces:
        if not KUBE_NAME.match(name):
            raise ValueError(f"invalid spec.policy.userQuota.namespaces entry: {name!r}")

    allowed = {
        str(namespace)
        for project in (specification.get("rancher") or {}).get("projects") or []
        for namespace in (project or {}).get("namespaces") or []
    }
    allowed |= {
        str(namespace)
        for namespace in (specification.get("gateway") or {}).get("allowedRouteNamespaces") or []
    }
    unknown = sorted(set(namespaces) - allowed)
    if unknown:
        # 계약에 없는 Namespace 에 쿼터를 걸면 ArgoCD 가 Namespace 를 새로 만들고
        # 아무도 쓰지 않는 제한만 남는다.
        raise ValueError(f"unknown workload namespace in userQuota: {', '.join(unknown)}")

    mismatched = []
    for origin, defaults in (("quota.go", go_defaults()), ("ui/lib/quota.ts", ui_defaults())):
        if parse_cpu_milli(defaults["cpu"]) != cpu_milli:
            mismatched.append(f"cpu(contract={quota.get('cpu')}, {origin}={defaults['cpu']})")
        if parse_memory_bytes(defaults["memory"]) != memory_bytes:
            mismatched.append(
                f"memory(contract={quota.get('memory')}, {origin}={defaults['memory']})"
            )
        if int(defaults["maxReplicas"]) != max_replicas:
            mismatched.append(
                f"maxReplicas(contract={max_replicas}, {origin}={defaults['maxReplicas']})"
            )
    if mismatched:
        raise ValueError(
            "포털 검증 코드와 계약의 사용자 상한이 다르다: " + ", ".join(mismatched)
        )

    return {
        "cpu_milli": cpu_milli,
        "memory_bytes": memory_bytes,
        "max_replicas": max_replicas,
        "max_users": max_users,
        "namespaces": namespaces,
    }


def documents(quota: dict) -> list[str]:
    per_user_cpu = format_cpu_milli(quota["cpu_milli"])
    per_user_memory = format_memory_bytes(quota["memory_bytes"])
    total_cpu = format_cpu_milli(quota["cpu_milli"] * quota["max_users"])
    total_memory = format_memory_bytes(quota["memory_bytes"] * quota["max_users"])
    # Pod 수 상한도 같이 건다. 아주 작은 Pod 를 무한히 만들어 kubelet 을 채우는 경로가 남는다.
    total_pods = quota["max_replicas"] * quota["max_users"]

    rendered: list[str] = []
    for namespace in quota["namespaces"]:
        rendered.append(
            f"""apiVersion: v1
kind: ResourceQuota
metadata:
  name: user-workload-quota
  namespace: {namespace}
  annotations:
    # 사용자 {quota['max_users']}명 x 1인 {per_user_cpu} CPU / {per_user_memory}
    sadp.example.io/source: contracts/platform-production.yaml spec.policy.userQuota
spec:
  hard:
    requests.cpu: "{total_cpu}"
    requests.memory: "{total_memory}"
    limits.cpu: "{total_cpu}"
    limits.memory: "{total_memory}"
    pods: "{total_pods}"
"""
        )
        rendered.append(
            f"""apiVersion: v1
kind: LimitRange
metadata:
  name: user-workload-limits
  namespace: {namespace}
  annotations:
    # Namespace 총량과 별개로 Pod 하나가 1인 상한을 넘지 못하게 한다.
    sadp.example.io/source: contracts/platform-production.yaml spec.policy.userQuota
spec:
  limits:
    - type: Pod
      max:
        cpu: "{per_user_cpu}"
        memory: "{per_user_memory}"
    - type: Container
      max:
        cpu: "{per_user_cpu}"
        memory: "{per_user_memory}"
      min:
        cpu: "{MIN_CONTAINER_CPU}"
        memory: "{MIN_CONTAINER_MEMORY}"
      # ResourceQuota 가 limits.* 를 걸면 값이 없는 Pod 는 생성 자체가 거부된다.
      # charts/app-profile 는 항상 채우지만, 직접 넣은 Pod 를 위해 기본값을 준다.
      default:
        cpu: "{DEFAULT_CONTAINER_CPU_LIMIT}"
        memory: "{DEFAULT_CONTAINER_MEMORY_LIMIT}"
      defaultRequest:
        cpu: "{DEFAULT_CONTAINER_CPU_REQUEST}"
        memory: "{DEFAULT_CONTAINER_MEMORY_REQUEST}"
"""
        )
    return rendered


def render(specification: dict) -> str:
    return HEADER + "---\n".join(documents(user_quota(specification)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    try:
        rendered = render(load_contract())
    except (KeyError, ValueError, TypeError) as error:
        print(f"[FAIL] Quota manifest generation failed: {error}", file=sys.stderr)
        return 1

    if arguments.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != rendered:
            print(
                f"[FAIL] {OUTPUT.relative_to(ROOT)} is not synchronized with the contract",
                file=sys.stderr,
            )
            return 1
        print("[OK]   Quota contract and manifest synchronization confirmed")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"[OK]   {OUTPUT.relative_to(ROOT)} generated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
