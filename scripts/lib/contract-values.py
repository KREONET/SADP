#!/usr/bin/env python3
"""
[이 내용은 작성한 코드를 보고 ai가 내용을 작성해줌]
contracts/platform-production.yaml -> contracts/values-platform-production.yaml 생성.

Chart는 baseDomain/Gateway/OpenBao/Keycloak을 하드코딩하지 않고 이 파일만 참조한다.
생성물은 커밋하며, CI가 재생성 후 diff로 동기화 여부를 검사한다.
"""
import sys
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "contracts" / "platform-production.yaml"
DST = ROOT / "contracts" / "values-platform-production.yaml"


def rancher_workload_project(spec: dict, workload_namespace: str) -> str:
    """AppGroup Namespace 가 붙을 Rancher project id(<cluster>:<project>).

    Rancher 는 Namespace 에 field.cattle.io/projectId 가 없으면 'Not in a project' 로
    두고 프로젝트 권한(app-admin/developer)이 닿지 않는다. 사용자 앱 Namespace 는
    워크로드 Namespace 와 같은 project 에 넣어야 기존 RBAC 이 그대로 적용된다.
    """
    rancher = spec.get("rancher") or {}
    cluster_id = str(rancher.get("clusterId") or "")
    if not cluster_id:
        raise ValueError("spec.rancher.clusterId 가 비어 있어 AppGroup Rancher project를 계산할 수 없다")
    for project in rancher.get("projects") or []:
        namespaces = [str(item) for item in project.get("namespaces") or []]
        if workload_namespace in namespaces:
            project_name = str(project.get("name") or "")
            if not project_name:
                raise ValueError(
                    f"workload Namespace {workload_namespace} 를 소유한 Rancher project 이름이 비어 있다"
                )
            return f"{cluster_id}:{project_name}"
    raise ValueError(
        f"workload Namespace {workload_namespace} 를 소유한 Rancher project가 계약에 없다"
    )


def build(spec: dict) -> dict:
    gw = spec["gateway"]
    ob = spec["openbao"]
    net = spec.get("network") or {}
    policy = spec.get("policy") or {}
    user_quota = policy.get("userQuota") or {}
    workload_namespaces = [str(item) for item in (user_quota.get("namespaces") or [])]
    workload_namespace = workload_namespaces[0] if workload_namespaces else ""
    internal_cidrs = list(net.get("internalCIDRs") or [])
    if not internal_cidrs:
        # 비어 있으면 Chart 의 egressMode=web 이 사설망까지 여는 대신 렌더에서 실패한다.
        # 여기서 조용히 넘기면 그 실패 이유가 계약이라는 사실이 드러나지 않는다.
        print(
            f"[WARN] {SRC}: network.internalCIDRs 가 비어 있다. egressMode=web 은 사용할 수 없다.",
            file=sys.stderr,
        )
    return {
        "platform": {
            "baseDomain": spec["baseDomain"],
            "gateway": {
                "namespace": gw["namespace"],
                "name": gw["name"],
                "sectionName": gw["routeListener"],
                # 새 AppGroup Namespace 가 HTTPRoute 를 붙이려면 Gateway 의
                # allowedRoutes selector 와 같은 label 을 달아야 한다. 임의로 다른
                # label 체계를 만들면 Route 가 조용히 Accepted 되지 않는다.
                "routeSelectorLabels": dict(
                    (gw.get("allowedRouteSelector") or {}).get("matchLabels") or {}
                ),
            },
            # 앱 NetworkPolicy 가 "인터넷"을 0.0.0.0/0 에서 뺄 때 쓰는 대역.
            "network": {"internalCIDRs": internal_cidrs},
            "rancher": {"workloadProjectId": rancher_workload_project(spec, workload_namespace)},
            # AppGroup Namespace 는 나중에 생기므로 포털의 RBAC 을 미리 만들 수 없다.
            # app-group Chart 가 이 ServiceAccount 에 읽기 Role 을 만들어 준다.
            # 이름은 charts/app-profile 이 고정하는 릴리스 이름(= 앱 이름)이다.
            "portal": {
                "namespace": workload_namespace,
                "serviceAccountName": "portal-lite",
            },
            "appGroups": {
                "namespacePrefix": str(
                    (spec.get("appGroups") or {}).get("namespacePrefix") or ""
                ),
                "maxServices": int((spec.get("appGroups") or {}).get("maxServices") or 0),
                "storage": {
                    "storageClass": str(
                        ((spec.get("appGroups") or {}).get("storage") or {}).get("storageClass") or ""
                    ),
                    "volumeSize": str(
                        ((spec.get("appGroups") or {}).get("storage") or {}).get("volumeSize") or ""
                    ),
                    "maxClaims": int(
                        ((spec.get("appGroups") or {}).get("storage") or {}).get("maxClaims") or 0
                    ),
                    "total": str(
                        ((spec.get("appGroups") or {}).get("storage") or {}).get("total") or ""
                    ),
                },
            },
            "registry": {
                "pullSecretName": (spec.get("registry") or {}).get("pullSecretName", ""),
                "pullSecretRemotePath": (spec.get("registry") or {}).get(
                    "pullSecretRemotePath", ""
                ),
            },
            # AppGroup Namespace 의 ResourceQuota/LimitRange 기준. 사용자당 상한과 같은 값이다.
            "quota": {
                "cpu": str(user_quota.get("cpu", "")),
                "memory": str(user_quota.get("memory", "")),
                "maxReplicas": int(user_quota.get("maxReplicas") or 0),
            },
            "openbao": {
                "server": ob["server"],
                "kvMount": ob["kvMount"],
                "pathPrefix": ob["pathPrefix"],
                "authMount": ob["authMount"],
                "audience": ob["audience"],
                "caConfigMap": ob["caConfigMap"],
                "caConfigMapNamespace": ob["namespace"],
                "roles": {
                    "zoneApp": str((ob.get("roles") or {}).get("zoneApp") or ""),
                    "groupApp": str((ob.get("roles") or {}).get("groupApp") or ""),
                    "groupRegistry": str(
                        (ob.get("roles") or {}).get("groupRegistry") or ""
                    ),
                },
            },
            "keycloak": {"issuer": spec["keycloak"]["issuer"]},
        }
    }


def main() -> int:
    contract = yaml.safe_load(SRC.read_text(encoding="utf-8"))
    if contract.get("kind") != "PlatformContract":
        print(f"[FAIL] {SRC}: kind가 PlatformContract가 아니다", file=sys.stderr)
        return 1
    try:
        values = build(contract["spec"])
    except (KeyError, TypeError, ValueError) as error:
        print(f"[FAIL] {SRC}: {error}", file=sys.stderr)
        return 1
    header = (
        "# 자동 생성 파일 - 직접 수정 금지.\n"
        "# 원본: contracts/platform-production.yaml / 생성: scripts/lib/contract-values.py\n"
    )
    body = header + yaml.safe_dump(values, allow_unicode=True, sort_keys=False)

    if "--check" in sys.argv:
        current = DST.read_text(encoding="utf-8") if DST.exists() else ""
        if current != body:
            print("[FAIL] values-platform-production.yaml 이 계약과 동기화되지 않았다. "
                  "scripts/lib/contract-values.py 를 실행하고 커밋하라.", file=sys.stderr)
            return 1
        print("[OK] 계약 <-> values 동기화 확인")
        return 0

    DST.write_text(body, encoding="utf-8")
    print(f"[OK] {DST} 생성")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
