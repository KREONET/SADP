#!/usr/bin/env python3
"""설치·검수 실패의 원인 분류와 다음 행동 안내(공용, 읽기 전용).

실제 사이트 장애 대부분은 메시지가 증상("미수락", "unavailable")만 말하고 원인과 다음 명령을
말하지 않아 진단에 시간이 들었다. 이 모듈은 kubectl이 돌려준 JSON·로그를 stdin으로 받아 원인을
분류하고 `[CAUSE]`/`[NEXT]` 줄을 stderr로 출력한다. verify-testbed, preflight, doctor가 같은
분류를 쓰도록 한 곳에 둔다.

값 비노출: Secret 값, 로그 원문, URL, IP, hostname은 출력하지 않는다. 리소스 이름, key 이름,
Kubernetes가 정한 reason 식별자와 분류만 출력한다. 원문 요약이 필요한 곳은 mask()를 거친다.

종료 코드: 0 정상(아무것도 출력하지 않음), 1 문제 발견(원인과 다음 행동 출력), 2 입력 오류,
3 판정 불가(node-idp-route에서 이름 해석 실패. 막지 않되 확인했다고 말하지 않는다).
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import socket
import subprocess
import sys
from urllib.parse import urlsplit


RELAY_STEPS = (
    "site.env IDP_RELAY_ENABLED=true → python3 scripts/site/configure-site.py --env-file <SITE_ENV> --write "
    "→ Squid 호스트에서 sudo bash ./sadp --install-idp-relay --apply "
    "→ kubectl apply -f platform/dns/rke2-coredns-config.yaml "
    "→ kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway"
)
RELAY_CHECK = (
    "Squid 호스트에서 sudo bash ./sadp --install-idp-relay --check, "
    "CoreDNS 적용(kubectl apply -f platform/dns/rke2-coredns-config.yaml) 후 "
    "kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway"
)
# 이 key가 비면 어느 단계가 빠졌는지 알려 준다. 사이트에서 Forgejo token 주입 단계를 건너뛰어
# Portal이 503으로만 보였던 장애가 실제로 있었다.
SECRET_KEY_STEPS = {
    "FORGEJO_BOT_TOKEN": (
        "Forgejo 봇 token이 OpenBao에 주입되지 않음",
        "sudo bash scripts/cluster/install-portal-backend.sh --token-only "
        "--forgejo-token-file <site.env의 SADP_PORTAL_FORGEJO_TOKEN_FILE>",
    ),
    "AUTH_OIDC_SECRET": (
        "Portal OIDC client Secret이 OpenBao에 없음",
        "root-only OIDC client Secret 파일을 확인한 뒤 sudo bash ./sadp --bootstrap-services",
    ),
    "client-secret": (
        "OIDC client Secret이 OpenBao에 없음",
        "root-only OIDC client Secret 파일을 확인한 뒤 sudo bash ./sadp --bootstrap-services",
    ),
}


# 노드 inotify 하한. Ubuntu 기본 max_user_instances=128은 한 노드에 Pod가 몰리면(다른 worker
# cordon 등) 바로 바닥나 NATS reloader 같은 sidecar가 "too many open files"로 죽는다. 실제 사이트
# 재설치에서 Devtron 전체가 Ready가 되지 않았다. 설치 스크립트와 검사가 이 값 하나를 공유한다.
NODE_SYSCTL_MINIMUMS = {
    "fs.inotify.max_user_instances": 8192,
    "fs.inotify.max_user_watches": 524288,
}
NODE_SYSCTL_NEXT = "그 노드에서 sudo bash ./sadp --install-node-sysctl (계획) → --apply (재시작 불필요)"


def cause(text: str) -> None:
    print(f"[CAUSE] {text}", file=sys.stderr)


def next_step(text: str) -> None:
    print(f"[NEXT] {text}", file=sys.stderr)


def mask(text: str, limit: int = 160) -> str:
    """원문 요약에서 URL, IP, hostname을 가린다. 분류만으로 부족할 때의 단서용이다."""
    text = re.sub(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s\"'<>]+", "<URL>", text)
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b", "<IP>", text)
    text = re.sub(r"\b[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+(?::\d+)?\b", "<HOST>", text)
    text = " ".join(text.split())
    return text[:limit] + ("…" if len(text) > limit else "")


def identifier(value: object) -> str:
    """Kubernetes 이름/reason만 남긴다. 다른 문자가 섞이면 출력하지 않는다."""
    text = str(value or "")
    return text if re.fullmatch(r"[A-Za-z0-9._/-]{1,253}", text) else "<invalid>"


def image_ref(value: object) -> str:
    """이미지 참조는 tag/digest 구분자(:, @)를 허용한다. 자격증명 형식(user:pass@)은 거른다."""
    text = str(value or "")
    if re.fullmatch(r"[A-Za-z0-9._/-]+(?::[A-Za-z0-9._-]+)?(?:@sha256:[0-9a-f]{64})?", text):
        return text
    return "<IMAGE>"


def load_json() -> object:
    try:
        return json.load(sys.stdin)
    except ValueError:
        print("[FAIL] diagnose: JSON 입력이 아님", file=sys.stderr)
        raise SystemExit(2)


# --- SecurityPolicy ---------------------------------------------------------


def classify_policy_message(message: str, relay_enabled: bool) -> tuple[str, str, str]:
    lowered = message.lower()
    if re.search(r"no route to host|network is unreachable|i/o timeout|connection timed out|"
                 r"context deadline exceeded|tls handshake timeout", lowered):
        return (
            "idp-unreachable",
            "Envoy Gateway가 외부 IdP에 연결하지 못함(Envoy Gateway는 HTTPS_PROXY를 쓰지 않음)",
            RELAY_CHECK if relay_enabled else RELAY_STEPS,
        )
    if "connection refused" in lowered:
        return (
            "idp-refused",
            "IdP 또는 relay 443이 연결을 거부함",
            RELAY_CHECK if relay_enabled else "IdP HTTPS 공개 상태와 방화벽을 확인하라",
        )
    if re.search(r"no such host|server misbehaving|lookup ", lowered):
        return (
            "dns",
            "Envoy Gateway가 IdP 이름을 해석하지 못함",
            "CoreDNS forward 대상(site.env CLUSTER_UPSTREAM_DNS)과 kubectl -n kube-system "
            "rollout status deploy/rke2-coredns-rke2-coredns를 확인하라",
        )
    if "issuer" in lowered:
        return (
            "issuer-mismatch",
            "IdP discovery의 issuer가 계약 issuer와 정확히 같지 않음(끝 '/' 포함)",
            "bash ./sadp --verify-idp --env-file <SITE_ENV>",
        )
    if re.search(r"x509|certificate|tls:", lowered):
        return (
            "tls",
            "IdP 인증서 검증 실패",
            "IdP 인증서 체인과 만료를 확인하라. relay를 쓰면 TLS는 끝단 그대로다",
        )
    if re.search(r"secret .*not found|clientsecret|client secret", lowered):
        return (
            "client-secret",
            "OIDC client Secret 참조가 준비되지 않음",
            "ExternalSecret secure-demo-oidc-client Ready를 확인하라(bash ./sadp --doctor --env-file <SITE_ENV>)",
        )
    return ("unclassified", "분류되지 않은 거부 사유", "kubectl get securitypolicy -o yaml의 status를 확인하라")


def security_policy(args: argparse.Namespace) -> int:
    document = load_json()
    if not isinstance(document, dict):
        return 2
    name = identifier((document.get("metadata") or {}).get("name"))
    rejected = []
    ancestors = (document.get("status") or {}).get("ancestors") or []
    for ancestor in ancestors:
        for condition in ancestor.get("conditions") or []:
            if condition.get("type") == "Accepted" and condition.get("status") != "True":
                rejected.append(str(condition.get("message") or condition.get("reason") or ""))
    if ancestors and not rejected:
        return 0
    if not ancestors:
        cause(f"SecurityPolicy {name}: Gateway가 아직 status를 기록하지 않음")
        next_step("kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway 후 다시 확인하라")
        return 1
    seen = set()
    for message in rejected:
        kind, text, action = classify_policy_message(message, args.relay_enabled == "true")
        if kind in seen:
            continue
        seen.add(kind)
        cause(f"SecurityPolicy {name} 미수락[{kind}]: {text} (요약: {mask(message)})")
        next_step(action)
    return 1


# --- ExternalSecret ---------------------------------------------------------


MISSING_KEY = re.compile(r"cannot find secret data for key:?\s*\\?\"?([A-Za-z0-9_.\-/]+)")


def external_secret(_args: argparse.Namespace) -> int:
    document = load_json()
    if not isinstance(document, dict):
        return 2
    item = document.get("externalSecret") or {}
    name = identifier((item.get("metadata") or {}).get("name"))
    conditions = (item.get("status") or {}).get("conditions") or []
    if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions):
        return 0
    messages = [str(c.get("message") or "") for c in conditions]
    messages += [str(e.get("message") or "") for e in (document.get("events") or {}).get("items") or []]
    store = document.get("store") or {}
    store_ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in (store.get("status") or {}).get("conditions") or []
    )
    found = False
    if store and not store_ready:
        found = True
        cause(f"ExternalSecret {name}: SecretStore가 Ready가 아님(OpenBao sealed 또는 인증 실패)")
        next_step("sudo bash ./sadp --unseal-openbao 로 seal 상태를 보고, sealed면 --apply")
    keys = sorted({match.group(1) for message in messages for match in MISSING_KEY.finditer(message)})
    for key in keys:
        found = True
        reason, action = SECRET_KEY_STEPS.get(
            key,
            (
                "OpenBao KV에 key가 없음",
                "해당 앱 KV를 시드하는 단계(sudo bash ./sadp --deploy-apps 또는 --bootstrap-services)를 다시 실행하라",
            ),
        )
        cause(f"ExternalSecret {name}: key {identifier(key)} 없음 - {reason}")
        next_step(action)
    joined = " ".join(messages).lower()
    if not found and re.search(r"permission denied|403|forbidden", joined):
        found = True
        cause(f"ExternalSecret {name}: OpenBao가 읽기를 거부함(role/policy)")
        next_step("sudo bash ./sadp --bootstrap-services 로 OpenBao role/policy를 다시 수렴시켜라")
    if not found:
        cause(f"ExternalSecret {name}: Ready 아님(요약: {mask(' '.join(messages)) or 'condition 없음'})")
        next_step(f"kubectl get events --field-selector involvedObject.name={name} 로 최근 이벤트 reason을 확인하라")
    return 1


# --- Deployment / Pod -------------------------------------------------------


TAINT = re.compile(r"untolerated taint\(?s?\)?\s*\{([^:}]+)")


def summarize_unschedulable(message: str) -> tuple[str, str]:
    reasons = []
    action = "kubectl describe pod 의 Events에서 스케줄 사유를 확인하라"
    taints = sorted(set(TAINT.findall(message)))
    if taints:
        reasons.append("taint " + ",".join(identifier(item.strip()) for item in taints))
        if any("control-plane" in item for item in taints):
            action = (
                "control-plane에 두어야 하는 Pod면 toleration이 필요하다. direct 모드 Envoy는 "
                "python3 scripts/site/render-exposure.py 재렌더 후 platform/exposure/resources.yaml 적용"
            )
    for pattern, label in (
        (r"Insufficient (cpu|memory|pods|ephemeral-storage)", "자원 부족"),
        (r"didn't match Pod's node affinity/selector", "nodeSelector/affinity 불일치"),
        (r"unbound immediate PersistentVolumeClaims|pod has unbound", "PVC 미바인딩"),
        (r"were unschedulable", "cordon된 노드"),
    ):
        match = re.search(pattern, message)
        if match:
            reasons.append(label + (f"({match.group(1)})" if match.groups() else ""))
            if label == "cordon된 노드" and not taints:
                action = "유지보수가 끝난 노드면 kubectl uncordon <NODE>, 아니면 대상 노드를 확인하라"
            if label == "PVC 미바인딩":
                action = "기본 StorageClass와 PVC 상태를 확인하라(sudo bash ./sadp --install-local-path-storage)"
    return ", ".join(reasons) or "사유 미상", action


def deployment(args: argparse.Namespace) -> int:
    document = load_json()
    if not isinstance(document, dict):
        return 2
    item = document.get("deployment") or {}
    name = identifier((item.get("metadata") or {}).get("name"))
    status = item.get("status") or {}
    desired = int((item.get("spec") or {}).get("replicas", 1) or 0)
    pods = (document.get("pods") or {}).get("items") or []
    problems = []
    for pod in pods:
        pod_name = identifier((pod.get("metadata") or {}).get("name"))
        pod_status = pod.get("status") or {}
        if pod_status.get("phase") == "Pending":
            scheduled = next(
                (c for c in pod_status.get("conditions") or [] if c.get("type") == "PodScheduled"), {}
            )
            if scheduled.get("status") == "False":
                summary, action = summarize_unschedulable(str(scheduled.get("message") or ""))
                problems.append((f"Pod {pod_name} Pending(스케줄 불가: {summary})", action))
                continue
        images = {c.get("name"): c.get("image") for c in (pod.get("spec") or {}).get("containers") or []}
        for container in pod_status.get("containerStatuses") or []:
            if container.get("ready"):
                continue
            waiting = (container.get("state") or {}).get("waiting") or {}
            reason = identifier(waiting.get("reason") or "")
            message = str(waiting.get("message") or "")
            label = f"Pod {pod_name}/{identifier(container.get('name'))} {reason}"
            if reason == "CreateContainerConfigError":
                secret = re.search(r'secret "([^"]+)" not found', message)
                key = re.search(r"couldn't find key (\S+) in Secret [^/\s]+/(\S+)", message)
                if key:
                    problems.append((
                        f"{label}: Secret {identifier(key.group(2))}에 key {identifier(key.group(1))} 없음",
                        f"Secret {identifier(key.group(2))}를 만드는 ExternalSecret의 Ready와 빠진 key를 확인하라",
                    ))
                elif secret:
                    problems.append((
                        f"{label}: Secret {identifier(secret.group(1))} 없음",
                        f"Secret {identifier(secret.group(1))}를 만드는 ExternalSecret Ready를 확인하라"
                        "(bash ./sadp --doctor --env-file <SITE_ENV>)",
                    ))
                else:
                    problems.append((label, "kubectl describe pod 로 참조 ConfigMap/Secret을 확인하라"))
            elif reason in {"ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull"}:
                image = image_ref(images.get(container.get("name")) or "")
                problems.append((
                    f"{label}: 이미지를 노드에서 찾거나 받지 못함",
                    f"sudo bash ./sadp --sync-images --image {image} (사이트 빌드 이미지면 --build-images/--import-images)",
                ))
            elif reason == "CrashLoopBackOff":
                problems.append((
                    f"{label}: 컨테이너가 반복 종료",
                    f"kubectl -n <NAMESPACE> logs {pod_name} -c {identifier(container.get('name'))} --previous "
                    "로 종료 원인을 확인하라(로그에 Secret이 없는지 보고 공유)",
                ))
            elif reason:
                problems.append((label, "kubectl describe pod 의 Events를 확인하라"))
            else:
                problems.append((f"Pod {pod_name}/{identifier(container.get('name'))} Ready 아님",
                                 "readinessProbe 대상과 의존 서비스(OpenBao, IdP)를 확인하라"))
    available = int(status.get("availableReplicas") or 0)
    updated = int(status.get("updatedReplicas") or 0)
    if not problems and available >= desired and updated >= desired:
        return 0
    # 옛 ReplicaSet Pod가 트래픽을 받는 동안 새 Pod가 멈춰 있으면 겉으로는 정상처럼 보인다.
    if available >= desired and updated < desired:
        cause(f"Deployment {name}: 옛 Pod는 가용하지만 새 revision rollout이 멈춤(updated={updated}/{desired})")
    elif available < desired:
        cause(f"Deployment {name}: 가용 Pod {available}/{desired}")
    for text, action in problems:
        cause(text)
        next_step(action)
    if not problems:
        next_step(f"kubectl rollout status deploy/{name} 와 kubectl describe pod 로 대기 사유를 확인하라")
    return 1


# --- Portal 로그 ------------------------------------------------------------


def portal_logs(args: argparse.Namespace) -> int:
    text = sys.stdin.read()
    patterns = {
        "fetch-failed": r"TypeError: fetch failed",
        "connect-timeout": r"UND_ERR_CONNECT_TIMEOUT|ETIMEDOUT",
        "refused": r"ECONNREFUSED",
        "dns": r"ENOTFOUND|EAI_AGAIN",
    }
    found = [name for name, pattern in patterns.items() if re.search(pattern, text)]
    if not found:
        return 0
    cause("Portal(Auth.js)의 서버 측 fetch가 외부 IdP에 연결하지 못함[" + ",".join(found) + "]"
          "(Node fetch는 HTTPS_PROXY를 쓰지 않음, 로그 원문은 출력하지 않음)")
    if args.relay_enabled == "true":
        next_step("Portal NetworkPolicy에 relay <SQUID_INTERNAL_IP>/32:443 egress가 있는지 확인하고"
                  "(configure-site --write 재렌더 → sudo bash ./sadp --deploy-apps), " + RELAY_CHECK)
    else:
        next_step(RELAY_STEPS + " → sudo bash ./sadp --deploy-apps")
    return 1


# --- 노드 IdP 경로 -----------------------------------------------------------


def node_idp_route(args: argparse.Namespace) -> int:
    """이 노드에서 IdP 주소로 가는 route가 있는지 본다. relay를 켜면 확인하지 않는다.

    worker에 default route가 없으면 Envoy Gateway·Portal처럼 proxy를 쓰지 않는 소비자가 IdP에
    닿지 못한다. 설치가 끝난 뒤 SecurityPolicy 미수락으로 드러나기 전에 node phase에서 멈춘다.
    """
    import yaml

    spec = yaml.safe_load(open(args.contract, encoding="utf-8"))["spec"]
    network = spec.get("network") or {}
    if (network.get("identityProviderRelay") or {}).get("enabled"):
        return 0
    host = urlsplit(str((spec.get("identityProvider") or {}).get("issuer") or "")).hostname or ""
    try:
        addresses = sorted({item[4][0] for item in socket.getaddrinfo(host, 443, socket.AF_INET)})
    except OSError:
        print("[WARN] 이 노드에서 IdP 이름을 해석하지 못해 route를 판정하지 않음"
              "(CoreDNS로만 해석되는 구성이면 정상일 수 있음)", file=sys.stderr)
        # 판정 불가는 통과(0)와 구분한다. 호출자가 "확인함"이라고 잘못 말하지 않게 한다.
        return 3
    internal = [ipaddress.ip_network(str(item)) for item in network.get("nodeInternalCIDRs") or []]
    for address in addresses:
        if any(ipaddress.ip_address(address) in network for network in internal):
            return 0
        result = subprocess.run(["ip", "-4", "route", "get", address], capture_output=True, text=True,
                                check=False)
        if result.returncode == 0:
            return 0
    print("[FAIL] 이 노드에 외부 IdP로 가는 route가 없는데 IDP_RELAY_ENABLED=false임"
          "(Envoy Gateway·Portal은 HTTPS_PROXY를 쓰지 않음)", file=sys.stderr)
    next_step(RELAY_STEPS)
    return 1


# --- 노드 inotify / CrashLoop 로그 --------------------------------------------


def node_limits(_args: argparse.Namespace) -> int:
    for key, value in NODE_SYSCTL_MINIMUMS.items():
        print(f"{key}={value}")
    return 0


def node_inotify(_args: argparse.Namespace) -> int:
    """{"nodes": {name: {"fs.inotify.max_user_instances": n|null, ...}}}를 하한과 비교한다."""
    document = load_json()
    nodes = (document or {}).get("nodes") or {}
    low = False
    for name, values in sorted(nodes.items()):
        for key, minimum in NODE_SYSCTL_MINIMUMS.items():
            raw = (values or {}).get(key)
            if raw is None or not str(raw).isdigit():
                print(f"[WARN] node {identifier(name)}: {key} 값을 읽지 못함"
                      "(그 노드에서 sudo bash ./sadp --install-node-sysctl --check)", file=sys.stderr)
                continue
            if int(raw) < minimum:
                low = True
                cause(f"node {identifier(name)}: {key}={int(raw)} < {minimum}"
                      "(Pod가 몰리면 inotify가 바닥나 sidecar가 too many open files로 죽음)")
    if low:
        next_step(NODE_SYSCTL_NEXT)
    return 1 if low else 0


LOOKUP_FAILURE = re.compile(r"lookup ([a-z0-9-]+)(?:\.[a-z0-9-]+)*\S* on \S+: no such host")


def crashloop_logs(_args: argparse.Namespace) -> int:
    """CrashLoop 컨테이너의 직전 로그(패턴만 본다)와 Pod 위치로 연쇄 장애의 첫 원인을 고른다.

    inotify가 바닥나면 한 sidecar만 죽어도 그 Pod가 Ready가 아니어서 Service endpoint가 비고,
    의존 Pod들이 "lookup <svc> ... no such host"로 줄줄이 죽는다. 뒤의 것은 결과일 뿐이므로
    too many open files를 먼저 원인으로 보고한다.
    """
    document = load_json()
    pods = {identifier((pod.get("metadata") or {}).get("name")): pod
            for pod in ((document or {}).get("pods") or {}).get("items") or []}
    logs = (document or {}).get("logs") or {}
    exhausted: dict[str, set[str]] = {}
    lookups: set[str] = set()
    for key, text in logs.items():
        pod_name = identifier(str(key).split("/", 1)[0])
        if re.search(r"too many open files", str(text), re.IGNORECASE):
            node = identifier((pods.get(pod_name, {}).get("spec") or {}).get("nodeName") or "unknown")
            exhausted.setdefault(node, set()).add(identifier(key))
        for match in LOOKUP_FAILURE.finditer(str(text)):
            lookups.add(identifier(match.group(1)))
    if not exhausted and not lookups:
        return 0
    for node, containers in sorted(exhausted.items()):
        cause(f"노드 {node} inotify 한도 부족: {', '.join(sorted(containers))}가 too many open files로 종료")
        next_step(NODE_SYSCTL_NEXT.replace("그 노드", f"노드 {node}"))
    if lookups:
        service_list = ", ".join(sorted(lookups))
        if exhausted:
            cause(f"Service DNS 조회 실패({service_list})는 위 Pod가 Ready가 아니라 endpoint가 없어서 생긴 결과")
        else:
            cause(f"Service DNS 조회 실패({service_list}): 대상 Service의 Pod가 Ready가 아님")
            next_step("kubectl get endpoints <SERVICE> 와 대상 Pod 상태를 먼저 확인하라"
                      "(sudo bash ./sadp --doctor --env-file <SITE_ENV>)")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name, handler in (("security-policy", security_policy), ("portal-logs", portal_logs)):
        command = sub.add_parser(name)
        command.add_argument("--relay-enabled", choices=("true", "false"), default="false")
        command.set_defaults(handler=handler)
    for name, handler in (("external-secret", external_secret), ("deployment", deployment)):
        sub.add_parser(name).set_defaults(handler=handler)
    sub.add_parser("node-limits").set_defaults(handler=node_limits)
    sub.add_parser("node-inotify").set_defaults(handler=node_inotify)
    sub.add_parser("crashloop-logs").set_defaults(handler=crashloop_logs)
    route = sub.add_parser("node-idp-route")
    route.add_argument("--contract", default="contracts/platform-production.yaml")
    route.set_defaults(handler=node_idp_route)
    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
