#!/usr/bin/env python3
"""scripts/site/render-exposure.py 회귀 시험(EX-01~EX-25).

계약을 바꿔가며 렌더러를 실행한다. 저장소를 더럽히지 않도록 매번 임시 사본에서 돌린다.
정상 입력은 반드시 통과해야 하고, 금지 입력은 반드시 실패해야 한다.
"""

from __future__ import annotations

import ipaddress
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sadp_test_fixture  # noqa: E402

# 사이트 checkout의 계약·생성물에 기대는 시험이다. 직접 실행해도 예제 site.env로
# 렌더한 fixture 사본에서 돌게 해 사이트 값 때문에 생기는 거짓 실패를 막는다.
sadp_test_fixture.reexec_in_fixture(__file__)

ROOT = pathlib.Path(__file__).resolve().parents[2]
COPY_PATHS = ("contracts", "scripts/site/templates", "scripts/site/render-exposure.py", "rke/etc/hosts")
EXPOSURE = "platform/exposure/resources.yaml"
TLS = "platform/cert-manager/resources.yaml"


def contract_spec(root: pathlib.Path | None = None) -> dict:
    """계약을 읽어 기대값을 만든다. 사이트를 옮겨도 시험이 따라오게 한다."""
    base = root if root is not None else ROOT
    return yaml.safe_load(
        (base / "contracts" / "platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]


SPEC = contract_spec()
NODE_NETWORK = ipaddress.ip_network(SPEC["network"]["nodeInternalCIDRs"][0])
NODE_ADDRESSES = [str(item) for item in SPEC["network"].get("nodeAddresses") or []]
WORKLOAD_NAMESPACES = sorted(SPEC["gateway"]["allowedRouteNamespaces"])
PLATFORM_NAMESPACE = SPEC["gateway"]["redirectRouteNamespace"]
ISSUER = SPEC["tls"]["clusterIssuerName"]
GATEWAY_SECRET = SPEC["gateway"]["wildcardTlsSecret"]
BASE_DOMAIN = SPEC["baseDomain"]


def _node_free_runs() -> list[list[str]]:
    """계약 CIDR에서 노드 주소가 하나도 없는 '연속 구간'들을 뽑는다.

    주소를 하나씩 걸러 목록으로 모으면 안 된다. addressPoolRange 는 `첫-끝` 범위
    문자열이라, 목록에서 건너뛴 노드가 범위로 표현하는 순간 다시 안으로 들어온다.
    노드 CIDR 이 노드 수보다 훨씬 넓으면(/24 등) 우연히 드러나지 않지만,
    /28 처럼 좁으면 상단 몇 개를 뽑는 것만으로 네트워크 전체를 덮어 노드와 겹친다.
    """
    runs: list[list[str]] = []
    current: list[str] = []
    for candidate in NODE_NETWORK.hosts():
        text = str(candidate)
        if text in NODE_ADDRESSES:
            if current:
                runs.append(current)
                current = []
            continue
        current.append(text)
    if current:
        runs.append(current)
    return runs


# 시험용 VIP/pool 은 노드를 건드리면 안 되므로 가장 긴 노드-free 연속 구간을 통째로 쓴다.
_RUNS = sorted(_node_free_runs(), key=len, reverse=True)
if not _RUNS or len(_RUNS[0]) < 2:
    raise SystemExit(
        "계약 nodeInternalCIDRs 에 노드가 없는 연속 주소가 2개 이상 있어야 시험 pool 을 만든다"
    )
_POOL = _RUNS[0]
ADDRESS_POOL_RANGE = f"{_POOL[0]}-{_POOL[-1]}"
VIP = _POOL[len(_POOL) // 2]
EMAIL = f"{PLATFORM_NAMESPACE}@example.com"
# solver 시험용 권한 DNS 주소는 pool 밖의 노드-free 주소에서 고른다. 그런 구간이 없으면
# pool 의 첫 주소를 쓴다(렌더러는 nameserver 와 pool 의 겹침을 따지지 않는다).
_OUTSIDE_POOL = [address for run in _RUNS[1:] for address in run]
NAMESERVER = f"{(_OUTSIDE_POOL or _POOL)[0]}:53"

# EX-14: VIP 를 포함하지 않는 pool. 노드와도 겹치면 안 된다(겹치면 VIP 누락이 아니라
# 노드 충돌로 거부돼 시험이 엉뚱한 이유로 통과한다). 그래서 같은 구간에서 VIP 앞부분만 자른다.
POOL_WITHOUT_VIP = f"{_POOL[0]}-{_POOL[len(_POOL) // 2 - 1]}"
# EX-15: 노드 주소를 삼키는 pool. 노드가 없는 계약이면 하단 주소를 노드처럼 취급한다.
_NODE = NODE_ADDRESSES[0] if NODE_ADDRESSES else _LOW[5]
_NODE_INDEX = list(NODE_NETWORK.hosts()).index(ipaddress.ip_address(_NODE))
_ALL = [str(item) for item in NODE_NETWORK.hosts()]
_START = max(0, _NODE_INDEX - 3)
NODE_OVERLAP_POOL = f"{_ALL[_START]}-{_ALL[min(len(_ALL) - 1, _NODE_INDEX + 3)]}"
NODE_OVERLAP_VIP = _ALL[min(len(_ALL) - 1, _NODE_INDEX + 1)]


def workspace() -> pathlib.Path:
    root = pathlib.Path(tempfile.mkdtemp(prefix="render-exposure-test-"))
    for relative in COPY_PATHS:
        source = ROOT / relative
        target = root / relative
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


def run(root: pathlib.Path, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(root / "scripts" / "site" / "render-exposure.py"), *arguments],
        capture_output=True,
        text=True,
        cwd=root,
    )


def ready(spec: dict, _status: dict) -> None:
    spec["tls"]["source"] = "acme"
    spec["gateway"]["vip"] = VIP
    spec["gateway"]["addressPoolRange"] = ADDRESS_POOL_RANGE
    spec["tls"]["acme"]["email"] = EMAIL
    spec["tls"]["solver"]["provider"] = "rfc2136"
    spec["tls"]["solver"]["rfc2136"].update(
        {
            "nameserver": NAMESERVER,
            "tsigKeyName": "beta-acme",
            "tsigAlgorithm": "HMACSHA256",
        }
    )
    # 아래 값들을 계약 파일에서 물려받으면, 사이트가 계약을 바꿀 때 그 값을 검증 대상으로
    # 삼지도 않는 case 들이 함께 깨진다. 기준값을 여기서 고정하고, 필요한 case 는
    # 자기 값으로 덮어쓴다(delegate(), EX-06 의 issuerMode 등).
    spec["tls"]["issuerMode"] = "staging"
    spec["tls"]["stagingPreserveExistingGatewaySecret"] = False
    spec["tls"]["solver"]["dns01Mode"] = "direct-rfc2136"
    spec["tls"]["solver"]["delegation"] = {"type": "", "zone": ""}
    spec["gateway"]["routeListener"] = "http"


def pending(spec: dict, _status: dict) -> None:
    spec["tls"]["source"] = "acme"
    spec["gateway"]["vip"] = "pending"
    spec["gateway"]["addressPoolRange"] = "pending"
    spec["tls"]["acme"]["email"] = "pending"
    spec["tls"]["solver"]["provider"] = "pending"


PASSED: list[str] = []
FAILED: list[str] = []


def case(label: str, mutate, expect_success: bool, verify=None, arguments=(), seed=None) -> None:
    root = workspace()
    if seed:
        seed(root)
    apply(root, mutate)
    result = run(root, *arguments)
    detail = ""
    succeeded = result.returncode == 0
    if succeeded != expect_success:
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


def documents(root: pathlib.Path, relative: str) -> list[dict]:
    path = root / relative
    if not path.exists():
        return []
    return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]


def no_outputs(root: pathlib.Path, _result) -> str:
    for relative in (EXPOSURE, TLS):
        if (root / relative).exists():
            return f"{relative} 이 생성되면 안 된다"
    return ""


def staging_probe(root: pathlib.Path, _result) -> str:
    exposure = documents(root, EXPOSURE)
    address_pool = next((d for d in exposure if d["kind"] == "IPAddressPool"), None)
    if address_pool is None or address_pool["spec"]["addresses"] != [ADDRESS_POOL_RANGE]:
        return "MetalLB address pool 범위가 계약과 다르다"
    gateway = next((d for d in exposure if d["kind"] == "Gateway"), None)
    if gateway is None:
        return "Gateway 문서 없음"
    listeners = [listener["name"] for listener in gateway["spec"]["listeners"]]
    if listeners != ["http", "apex-http"]:
        return f"staging인데 HTTPS listener가 활성화됨: {listeners}"
    namespaces = sorted(d["metadata"]["name"] for d in exposure if d["kind"] == "Namespace")
    if namespaces != WORKLOAD_NAMESPACES:
        return f"라벨링된 Namespace 목록이 계약과 다르다: {namespaces}"

    tls = documents(root, TLS)
    kinds = [d["kind"] for d in tls]
    if kinds != ["ClusterIssuer", "ClusterIssuer", "Certificate"]:
        return f"TLS 문서 구성이 다르다: {kinds}"
    certificate = tls[2]
    if certificate["spec"]["issuerRef"]["name"] != f"{ISSUER}-staging":
        return "issuerMode=staging 인데 production issuer 를 참조한다"
    if certificate["metadata"]["name"] != f"{GATEWAY_SECRET}-staging":
        return "staging Certificate 이름이 운영 Certificate와 분리되지 않음"
    if certificate["spec"]["secretName"] != f"{GATEWAY_SECRET}-staging":
        return "staging Secret이 운영 Gateway Secret과 분리되지 않음"
    contract = yaml.safe_load(
        (root / "contracts" / "platform-production.yaml").read_text(encoding="utf-8")
    )
    base_domain = contract["spec"]["baseDomain"]
    if certificate["spec"]["dnsNames"] != [f"*.{base_domain}", base_domain]:
        return "wildcard 와 apex 가 모두 dnsNames 에 없다"
    if "rfc2136" not in tls[0]["spec"]["acme"]["solvers"][0]["dns01"]:
        return "rfc2136 solver 가 렌더되지 않았다"
    return ""


def staging_preserves_existing_https(root: pathlib.Path, _result) -> str:
    exposure = documents(root, EXPOSURE)
    gateway = next((d for d in exposure if d["kind"] == "Gateway"), None)
    if gateway is None:
        return "Gateway 문서 없음"
    listeners = [listener["name"] for listener in gateway["spec"]["listeners"]]
    if listeners != ["http", "apex-http", "https", "apex-https"]:
        return f"기존 Secret 보존 staging인데 listener가 다름: {listeners}"
    tls = documents(root, TLS)
    certificate = next((d for d in tls if d["kind"] == "Certificate"), None)
    if certificate is None:
        return "staging Certificate 없음"
    if certificate["spec"]["secretName"] != f"{GATEWAY_SECRET}-staging":
        return "staging probe가 운영 Gateway Secret을 대상으로 함"
    return ""


def direct_public_service(root: pathlib.Path, _result) -> str:
    contract = yaml.safe_load(
        (root / "contracts" / "platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    envoy_proxy = next(
        d for d in documents(root, EXPOSURE) if d["kind"] == "EnvoyProxy"
    )
    service = envoy_proxy["spec"]["provider"]["kubernetes"]["envoyService"]
    if service.get("externalTrafficPolicy") != "Local":
        return "direct mode Envoy Service가 Local externalTrafficPolicy를 쓰지 않는다"
    deployment = envoy_proxy["spec"]["provider"]["kubernetes"]["envoyDeployment"]
    expected_node = contract["public"]["nodeName"]
    if deployment["pod"].get("nodeSelector") != {
        "kubernetes.io/hostname": expected_node
    }:
        return "direct mode Envoy Pod가 공인 IP 노드에 고정되지 않는다"
    tolerations = deployment["pod"].get("tolerations") or []
    if not any(
        item.get("key") == "node-role.kubernetes.io/control-plane"
        and item.get("effect") == "NoSchedule"
        for item in tolerations
    ):
        return "공인 IP 노드가 control-plane이면 Envoy Pod가 taint 때문에 Pending이 된다"
    external_ips = service.get("patch", {}).get("value", {}).get("spec", {}).get("externalIPs")
    if external_ips != [contract["gateway"]["vip"], contract["public"]["ip"]]:
        return f"direct mode externalIPs 불일치: {external_ips}"
    return ""


def nat_public_service(root: pathlib.Path, _result) -> str:
    envoy_proxy = next(
        d for d in documents(root, EXPOSURE) if d["kind"] == "EnvoyProxy"
    )
    service = envoy_proxy["spec"]["provider"]["kubernetes"]["envoyService"]
    if "patch" in service or "externalTrafficPolicy" in service:
        return "nat mode가 direct Service patch를 렌더했다"
    if "envoyDeployment" in envoy_proxy["spec"]["provider"]["kubernetes"]:
        return "nat mode가 direct Envoy nodeSelector를 렌더했다"
    return ""


def solver_is(provider: str):
    def verify(root: pathlib.Path, _result) -> str:
        tls = documents(root, TLS)
        dns01 = tls[0]["spec"]["acme"]["solvers"][0]["dns01"]
        if provider not in dns01:
            return f"{provider} solver 가 아니다: {sorted(dns01)}"
        return ""

    return verify


def production_issuer(root: pathlib.Path, _result) -> str:
    certificate = documents(root, TLS)[2]
    if certificate["spec"]["issuerRef"]["name"] != ISSUER:
        return "issuerMode=production 인데 staging issuer 를 참조한다"
    if certificate["metadata"]["name"] != GATEWAY_SECRET:
        return "production Certificate 이름 불일치"
    if certificate["spec"]["secretName"] != GATEWAY_SECRET:
        return "production Secret이 Gateway Secret과 불일치"
    gateway = next(
        d for d in documents(root, EXPOSURE) if d["kind"] == "Gateway"
    )
    listeners = [listener["name"] for listener in gateway["spec"]["listeners"]]
    if listeners != ["http", "apex-http", "https", "apex-https"]:
        return f"production HTTPS listener 누락: {listeners}"
    return ""


def rfc2136(spec: dict, status: dict) -> None:
    ready(spec, status)
    spec["tls"]["solver"]["provider"] = "rfc2136"
    spec["tls"]["solver"]["rfc2136"].update(
        {"nameserver": NAMESERVER, "tsigKeyName": "beta-acme", "tsigAlgorithm": "HMACSHA256"}
    )


def route53(spec: dict, status: dict) -> None:
    ready(spec, status)
    spec["tls"]["solver"]["provider"] = "route53"


def seed_stale(root: pathlib.Path) -> None:
    path = root / EXPOSURE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# 이전 실행에서 남은 산출물\n", encoding="utf-8")


def seed_legacy(root: pathlib.Path) -> None:
    path = root / "platform" / "exposure" / "d4-resources.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# render-d4.py 시절 산출물\n", encoding="utf-8")


def provided(spec: dict, status: dict) -> None:
    ready(spec, status)
    spec["tls"]["source"] = "provided"
    spec["tls"]["provided"] = {
        "certificatePath": "wildcard/fullchain.pem",
        "privateKeyPath": "wildcard/privkey.pem",
    }
    spec["gateway"]["routeListener"] = "https"


def provided_https(root: pathlib.Path, _result) -> str:
    if (root / TLS).exists():
        return "provided 모드에서 cert-manager TLS 산출물이 생성되면 안 된다"
    exposure = documents(root, EXPOSURE)
    gateway = next((d for d in exposure if d["kind"] == "Gateway"), None)
    if gateway is None:
        return "Gateway 문서 없음"
    listeners = [listener["name"] for listener in gateway["spec"]["listeners"]]
    if listeners != ["http", "apex-http", "https", "apex-https"]:
        return f"wildcard/apex HTTP,HTTPS listener 구성이 다르다: {listeners}"
    redirects = [
        d for d in exposure
        if d["kind"] == "HTTPRoute" and d["metadata"]["name"] == "http-to-https-redirect"
    ]
    if len(redirects) != 1:
        return "HTTP->HTTPS redirect 가 정확히 하나가 아니다"
    apex_redirects = [
        d for d in exposure
        if d["kind"] == "HTTPRoute" and d["metadata"]["name"] == "apex-http-to-https-redirect"
    ]
    if len(apex_redirects) != 1:
        return "apex HTTP->HTTPS redirect 가 정확히 하나가 아니다"
    apex_redirect = apex_redirects[0]
    if apex_redirect["spec"]["parentRefs"][0]["sectionName"] != "apex-http":
        return "apex redirect가 apex HTTP listener에 붙지 않았다"
    if apex_redirect["spec"]["hostnames"] != [BASE_DOMAIN]:
        return "apex redirect hostname이 baseDomain과 다르다"
    return ""


def seed_stale_tls(root: pathlib.Path) -> None:
    path = root / TLS
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# stale ACME output\n", encoding="utf-8")


case("EX-01 pending 계약은 산출물을 만들지 않는다", pending, True, no_outputs)
case("EX-02 staging은 운영 Gateway와 분리된 probe 인증서를 생성한다", ready, True, staging_probe)
case("EX-03 rfc2136 solver 렌더", rfc2136, True, solver_is("rfc2136"))
case("EX-04 비승인 route53 solver 거부", route53, False)
case(
    "EX-05 rfc2136 nameserver 누락 거부",
    lambda spec, status: (rfc2136(spec, status), spec["tls"]["solver"]["rfc2136"].update({"nameserver": ""})),
    False,
)
case(
    "EX-06 production 모드는 production issuer 를 참조한다",
    lambda spec, status: (
        ready(spec, status),
        spec["tls"].update({"issuerMode": "production"}),
        spec["gateway"].update({"routeListener": "https"}),
    ),
    True,
    production_issuer,
)
case(
    "EX-07 잘못된 ACME 이메일 거부",
    lambda spec, status: (ready(spec, status), spec["tls"]["acme"].update({"email": "not-an-email"})),
    False,
)
case(
    "EX-08 TLS pending 상태에서 routeListener=https 거부",
    lambda spec, status: (
        pending(spec, status),
        spec["gateway"].update(
            {"vip": VIP, "addressPoolRange": ADDRESS_POOL_RANGE, "routeListener": "https"}
        ),
    ),
    False,
)
case(
    "EX-09 Gateway Namespace 를 allowedRouteNamespaces 에 넣으면 거부",
    lambda spec, status: (
        ready(spec, status),
        spec["gateway"]["allowedRouteNamespaces"].append("envoy-gateway-system"),
    ),
    False,
)
case("EX-10 pending 인데 남은 산출물이 있으면 거부", pending, False, seed=seed_stale)
case("EX-11 render-d4 시절 산출물이 남아 있으면 거부", ready, False, seed=seed_legacy)
case(
    "EX-12 VIP 가 RKE2 노드 주소와 충돌하면 거부",
    lambda spec, status: spec["gateway"].update({"vip": NODE_ADDRESSES[0]}),
    False,
)
case("EX-13 --check 는 미동기화 산출물을 잡는다", ready, False, arguments=("--check",))
case(
    "EX-14 VIP 를 포함하지 않는 address pool 거부",
    lambda spec, status: (
        ready(spec, status),
        spec["gateway"].update({"addressPoolRange": POOL_WITHOUT_VIP}),
    ),
    False,
)
case(
    "EX-15 RKE2 노드와 겹치는 address pool 거부",
    lambda spec, status: (
        ready(spec, status),
        spec["gateway"].update(
            {"vip": NODE_OVERLAP_VIP, "addressPoolRange": NODE_OVERLAP_POOL}
        ),
    ),
    False,
)


# --- D6 플랫폼 UI 공개 경로와 Rancher Project 편입 ---------------------------


def platform_route(root: pathlib.Path, _result) -> str:
    contract = yaml.safe_load(
        (root / "contracts" / "platform-production.yaml").read_text(encoding="utf-8")
    )
    base_domain = contract["spec"]["baseDomain"]
    exposure = documents(root, EXPOSURE)
    route = next(
        (d for d in exposure if d["kind"] == "HTTPRoute" and d["metadata"]["name"] == "rancher"),
        None,
    )
    if route is None:
        return "rancher HTTPRoute 가 없다"
    if route["metadata"]["namespace"] != PLATFORM_NAMESPACE:
        return "플랫폼 HTTPRoute 가 redirectRouteNamespace 에 없다"
    parent = route["spec"]["parentRefs"][0]
    if parent["sectionName"] != contract["spec"]["gateway"]["routeListener"]:
        return f"parentRefs sectionName 이 routeListener 와 다르다: {parent['sectionName']}"
    if route["spec"]["hostnames"] != [f"rancher.{base_domain}"]:
        return f"hostname 이 계약과 다르다: {route['spec']['hostnames']}"
    backend = route["spec"]["rules"][0]["backendRefs"][0]
    if backend["namespace"] != "cattle-system" or backend["port"] != 80:
        return f"backendRef 가 계약과 다르다: {backend}"

    grant = next((d for d in exposure if d["kind"] == "ReferenceGrant"), None)
    if grant is None:
        return "ReferenceGrant 가 없다(다른 Namespace 의 Service 를 참조할 수 없다)"
    if grant["metadata"]["namespace"] != "cattle-system":
        return "ReferenceGrant 가 대상 Namespace 에 없다"
    if grant["spec"]["from"][0]["namespace"] != PLATFORM_NAMESPACE:
        return "ReferenceGrant from 이 redirectRouteNamespace 가 아니다"
    if grant["spec"]["to"][0]["name"] != "rancher":
        return "ReferenceGrant to 가 대상 Service 를 지정하지 않는다"
    return ""


def project_annotation(root: pathlib.Path, _result) -> str:
    # 어느 Namespace 가 어느 Rancher Project 에 들어가는지는 계약이 정한다.
    expected = {
        namespace: f"local:{project['name']}"
        for project in contract_spec(root).get("rancher", {}).get("projects") or []
        for namespace in project.get("namespaces") or []
    }
    for document in documents(root, EXPOSURE):
        if document["kind"] != "Namespace":
            continue
        name = document["metadata"]["name"]
        annotation = (document["metadata"].get("annotations") or {}).get(
            "field.cattle.io/projectId"
        )
        if annotation != expected.get(name):
            return f"{name} 의 projectId annotation 이 {annotation!r}, 기대값 {expected.get(name)!r}"
        if not (document["metadata"].get("labels") or {}).get("platform.example.io/route"):
            return f"{name} 에서 route 라벨이 사라졌다"
    return ""


def bad_platform_host(spec: dict, status: dict) -> None:
    ready(spec, status)
    spec["platformServices"][0]["host"] = "rancher.evil.com"


case("EX-16 플랫폼 UI 는 HTTPRoute 와 ReferenceGrant 를 생성한다", ready, True, platform_route)
case("EX-17 Namespace 가 Rancher Project 에 편입된다", ready, True, project_annotation)
case("EX-18 플랫폼 UI host 가 승인 도메인 밖이면 거부", bad_platform_host, False)
case(
    "EX-19 플랫폼 UI 를 Gateway Namespace 에 두면 거부",
    lambda spec, status: (
        ready(spec, status),
        spec["platformServices"][0].update({"namespace": "envoy-gateway-system"}),
    ),
    False,
)
case(
    "EX-20 플랫폼 UI host 중복 거부",
    lambda spec, status: (
        ready(spec, status),
        spec["platformServices"].append({**spec["platformServices"][0], "name": "rancher-dup"}),
    ),
    False,
)
case(
    "EX-21 렌더되지 않는 Namespace 를 Rancher Project 가 참조하면 거부",
    lambda spec, status: (
        ready(spec, status),
        spec["rancher"]["projects"][0]["namespaces"].append("cattle-system"),
    ),
    False,
)
case(
    "EX-22 한 Namespace 를 두 Project 가 소유하면 거부",
    lambda spec, status: (
        ready(spec, status),
        spec["rancher"]["projects"][1]["namespaces"].append(
            spec["rancher"]["projects"][0]["namespaces"][0]
        ),
    ),
    False,
)
case("EX-23 provided 인증서는 HTTPS만 렌더하고 Secret/Certificate를 쓰지 않는다", provided, True, provided_https)
case("EX-24 provided 모드에서 남은 ACME 산출물을 거부한다", provided, False, seed=seed_stale_tls)
case(
    "EX-25 provided private key가 wildcard 밖이면 거부한다",
    lambda spec, status: (
        provided(spec, status),
        spec["tls"]["provided"].update({"privateKeyPath": "../privkey.pem"}),
    ),
    False,
)


def api_key_machine_auth(spec: dict, status: dict) -> None:
    ready(spec, status)
    spec["machineAuth"] = {
        "mode": "api-key",
        "clients": ["grafana-central", "wazuh-connector"],
        "allowedCIDRs": ["203.0.113.10/32", "198.51.100.20/32"],
        "apiKey": {
            "header": "X-SADP-API-Key",
            "remotePathPrefix": "platform/machine-auth",
            "secretStoreName": "machine-auth-openbao",
            "esoServiceAccount": "eso-machine-auth",
            "esoRole": "machine-auth-eso",
            "credentialSecretPrefix": "machine-auth-",
        },
    }
    spec["platformServices"].append(
        {
            "name": "metrics",
            "host": f"metrics.{spec['baseDomain']}",
            "namespace": "monitoring",
            "service": "prometheus",
            "port": 9090,
            "machineAuth": True,
        }
    )


def verify_api_key_machine_auth(root: pathlib.Path, _result) -> str:
    rendered = documents(root, EXPOSURE)
    policy = next(
        (item for item in rendered if item.get("kind") == "SecurityPolicy"
         and item["metadata"]["name"] == "metrics-machine-auth"),
        None,
    )
    if policy is None:
        return "api-key SecurityPolicy가 없다"
    auth = policy["spec"].get("apiKeyAuth") or {}
    if auth.get("sanitize") is not True:
        return "API key header를 backend 전에 제거하지 않는다"
    if auth.get("extractFrom") != [{"headers": ["X-SADP-API-Key"]}]:
        return f"API key header 불일치: {auth.get('extractFrom')!r}"
    if policy["spec"].get("jwt"):
        return "api-key 정책에 OIDC JWT가 함께 켜졌다"
    principal = policy["spec"]["authorization"]["rules"][0]["principal"]
    if principal != {"clientCIDRs": ["203.0.113.10/32", "198.51.100.20/32"]}:
        return f"CIDR principal 불일치: {principal!r}"
    external_secrets = [item for item in rendered if item.get("kind") == "ExternalSecret"]
    if len(external_secrets) != 2:
        return f"클라이언트별 ExternalSecret 수 불일치: {len(external_secrets)}"
    if any(item.get("kind") == "Secret" for item in rendered):
        return "실제 Secret을 렌더했다"
    return ""


case("EX-26 machine-auth mode 누락 거부", lambda spec, status: (
    ready(spec, status), spec.pop("machineAuth", None)
), False)
case("EX-27 machine-auth mode 오타 거부", lambda spec, status: (
    ready(spec, status), spec["machineAuth"].update({"mode": "apikey"})
), False)
case("EX-28 api-key client 누락 거부", lambda spec, status: (
    api_key_machine_auth(spec, status), spec["machineAuth"].update({"clients": []})
), False)
case("EX-29 api-key CIDR 누락 거부", lambda spec, status: (
    api_key_machine_auth(spec, status), spec["machineAuth"].update({"allowedCIDRs": []})
), False)
case("EX-30 api-key 전체 인터넷 CIDR 거부", lambda spec, status: (
    api_key_machine_auth(spec, status),
    spec["machineAuth"].update({"allowedCIDRs": ["0.0.0.0/0"]}),
), False)
case(
    "EX-31 api-key는 OpenBao/ESO/APIKeyAuth/CIDR/header sanitize를 렌더",
    api_key_machine_auth,
    True,
    verify_api_key_machine_auth,
)
case(
    "EX-26 기존 Gateway Secret을 보존하며 staging probe를 분리한다",
    lambda spec, status: (
        ready(spec, status),
        spec["tls"].update({"stagingPreserveExistingGatewaySecret": True}),
        spec["gateway"].update({"routeListener": "https"}),
        status.update({"wildcardTls": "ready"}),
    ),
    True,
    staging_preserves_existing_https,
)
case(
    "EX-27 공인 NIC direct 모드는 Envoy Service externalIPs를 생성한다",
    # 사이트 계약이 nat 일 수도 있으므로 direct 를 시험 안에서 명시한다.
    lambda spec, status: (
        ready(spec, status),
        spec["public"].update({"mode": "direct", "nodeName": "sadp-control-plane-1"}),
    ),
    True,
    direct_public_service,
)
case(
    "EX-28 경계 NAT 모드는 공인 externalIPs를 생성하지 않는다",
    lambda spec, status: (ready(spec, status), spec["public"].update({"mode": "nat"})),
    True,
    nat_public_service,
)
case(
    "EX-29 direct 모드에서 external interface 누락을 거부한다",
    lambda spec, status: (
        ready(spec, status),
        spec["public"].update({"mode": "direct", "nodeName": "sadp-control-plane-1"}),
        spec["network"]["interfaces"].update({"external": ""}),
    ),
    False,
)
case(
    "EX-30 direct 모드에서 공인 IP 노드 누락을 거부한다",
    lambda spec, status: (
        ready(spec, status),
        spec["public"].update({"mode": "direct"}),
        spec["public"].pop("nodeName", None),
    ),
    False,
)


def add_analytics_system(spec: dict) -> str:
    domain = f"analytics.{spec['baseDomain']}"
    spec["systems"] = [
        {
            "name": "analytics",
            "domain": domain,
            "workloadNamespace": "analytics-beta",
            "project": "proj-analytics-beta",
            "wildcardTlsSecret": "analytics-wildcard-tls",
            "httpListener": "http-analytics",
            "httpsListener": "https-analytics",
        }
    ]
    spec["gateway"]["allowedRouteNamespaces"] = [
        *spec["gateway"]["allowedRouteNamespaces"],
        "analytics-beta",
    ]
    spec.setdefault("rancher", {}).setdefault("projects", []).append(
        {
            "name": "proj-analytics-beta",
            "displayName": "analytics-beta",
            "description": "analytics 시스템",
            "namespaces": ["analytics-beta"],
        }
    )
    return domain


def system_exposure(root: pathlib.Path, _result) -> str:
    contract = yaml.safe_load(
        (root / "contracts" / "platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    domain = contract["systems"][0]["domain"]
    exposure = documents(root, EXPOSURE)
    gateway = next(d for d in exposure if d["kind"] == "Gateway")
    listener = next((l for l in gateway["spec"]["listeners"] if l["name"] == "http-analytics"), None)
    if listener is None:
        return "http-analytics listener 가 렌더되지 않았다"
    if listener["hostname"] != f"*.{domain}":
        return f"http-analytics listener hostname 불일치: {listener['hostname']}"
    namespaces = {d["metadata"]["name"] for d in exposure if d["kind"] == "Namespace"}
    if "analytics-beta" not in namespaces:
        return "analytics-beta Namespace 가 렌더되지 않았다"
    tls = documents(root, TLS)
    certificate = next(
        (d for d in tls if d["kind"] == "Certificate" and d["metadata"]["name"] == "analytics-wildcard-tls-staging"),
        None,
    )
    if certificate is None:
        return "시스템 wildcard Certificate 가 렌더되지 않았다"
    if certificate["spec"]["dnsNames"] != [f"*.{domain}", domain]:
        return f"시스템 Certificate dnsNames 불일치: {certificate['spec']['dnsNames']}"
    return ""


case(
    "EX-30 systems 계약이 있으면 시스템별 Gateway listener/Namespace/Certificate가 추가된다",
    lambda spec, status: (ready(spec, status), add_analytics_system(spec)),
    True,
    system_exposure,
)
case(
    "EX-31 systems 도메인이 baseDomain 밖이면 거부한다",
    lambda spec, status: (
        ready(spec, status),
        add_analytics_system(spec),
        spec["systems"][0].update({"domain": "analytics.other.example.com"}),
    ),
    False,
)

def delegate(spec: dict, kind: str, zone: str) -> None:
    spec["tls"]["solver"]["dns01Mode"] = "delegated-rfc2136"
    spec["tls"]["solver"]["delegation"].update({"type": kind, "zone": zone})


def delegated_solver(cname_strategy: str, nameserver: str):
    def verify(root: pathlib.Path, _result) -> str:
        dns01 = documents(root, TLS)[0]["spec"]["acme"]["solvers"][0]["dns01"]
        if "rfc2136" not in dns01:
            return f"위임 모드인데 rfc2136 solver 가 아니다: {sorted(dns01)}"
        if dns01["rfc2136"].get("nameserver") != nameserver:
            return (
                "UPDATE 대상이 위임 DNS 가 아니다: "
                f"{dns01['rfc2136'].get('nameserver')}"
            )
        actual = dns01.get("cnameStrategy", "")
        if actual != cname_strategy:
            return f"cnameStrategy={actual!r} expected={cname_strategy!r}"
        return ""

    return verify


case(
    "EX-32 delegated-rfc2136/cname 은 cnameStrategy=Follow 로 위임 zone 을 UPDATE 한다",
    lambda spec, status: (
        ready(spec, status),
        delegate(spec, "cname", "acme.example.net"),
    ),
    True,
    delegated_solver("Follow", NAMESERVER),
)
case(
    "EX-33 delegated-rfc2136/ns 는 cnameStrategy=None(따라가지 않음) 으로 렌더한다",
    lambda spec, status: (
        ready(spec, status),
        delegate(spec, "ns", f"_acme-challenge.{BASE_DOMAIN}"),
    ),
    True,
    # cert-manager CNAMEStrategy enum 의 "None" 문자열이다. YAML 에서 bare None 은
    # null 이 아니라 문자열로 파싱되므로 그대로 두어도 안전하다.
    delegated_solver("None", NAMESERVER),
)
case(
    "EX-34 direct-rfc2136 에 delegation 값이 남아 있으면 거부한다",
    lambda spec, status: (
        ready(spec, status),
        spec["tls"]["solver"]["delegation"].update(
            {"type": "cname", "zone": "acme.example.net"}
        ),
    ),
    False,
)
case(
    "EX-35 delegation.type=ns 인데 zone 이 _acme-challenge.<baseDomain> 이 아니면 거부한다",
    lambda spec, status: (
        ready(spec, status),
        delegate(spec, "ns", "acme.example.net"),
    ),
    False,
)
case(
    "EX-36 위임 zone 이 baseDomain 과 같으면 거부한다",
    lambda spec, status: (ready(spec, status), delegate(spec, "cname", BASE_DOMAIN)),
    False,
)
case(
    "EX-37 알 수 없는 dns01Mode 는 거부한다",
    lambda spec, status: (
        ready(spec, status),
        spec["tls"]["solver"].update({"dns01Mode": "acme-dns"}),
    ),
    False,
)
case(
    "EX-38 monitoring 비활성 계약은 monitoring backend 노출을 거부한다",
    lambda spec, status: (
        ready(spec, status),
        spec.update({"monitoring": {"enabled": False}}),
        spec["machineAuth"].update(
            {"clients": ["grafana-central"], "allowedCIDRs": ["192.0.2.40/32"]}
        ),
        spec["platformServices"].append(
            {
                "name": "metrics",
                "host": f"metrics.{BASE_DOMAIN}",
                "namespace": "monitoring",
                "service": "prometheus-server",
                "port": 80,
                "machineAuth": True,
            }
        ),
    ),
    False,
)

print(f"통과 {len(PASSED)} / 실패 {len(FAILED)}")
raise SystemExit(1 if FAILED else 0)
