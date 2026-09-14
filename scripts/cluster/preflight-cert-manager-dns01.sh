#!/usr/bin/env bash
# cert-manager controller가 실제 배치된 노드의 host network에서 권위 DNS TCP/UDP 53을 검사한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

APPLY=false
while (($#)); do
  case "$1" in
    --apply) APPLY=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo bash ./sadp --preflight-dns01 [--apply]

기본 실행은 계약의 DNS-01 목적지와 cert-manager placement 계획만 출력한다.
--apply는 현재 cert-manager controller Pod가 Ready인 각 노드에 일시적인 host-network
probe Pod를 만들고 authoritative DNS의 TCP/UDP 포트와 SOA 응답을 확인한 뒤 즉시 삭제한다.
자격증명, DNS 응답 본문과 목적지 주소는 출력하지 않는다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in jq python3 sha256sum; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
cd "${TESTBED_ROOT}"

CONTRACT_PATH=${SADP_DNS01_CONTRACT_PATH:-${TESTBED_ROOT}/contracts/platform-production.yaml}
contract_output=$(python3 - "${CONTRACT_PATH}" <<'PY'
import ipaddress
import sys

import yaml

spec = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}).get("spec") or {}
tls = spec.get("tls") or {}
solver = tls.get("solver") or {}
mode = str(solver.get("dns01Mode") or "direct-rfc2136")
source = str(tls.get("source") or "")
placement = str(tls.get("certManagerPlacement") or "any")
namespace = str(tls.get("certManagerNamespace") or "cert-manager")

if source != "acme":
    print(source)
    print(namespace)
    print(placement)
    print("")
    print("")
    print("")
    raise SystemExit(0)
if str(solver.get("provider") or "") != "rfc2136":
    raise SystemExit("[FAIL] DNS-01 preflight는 rfc2136 solver 계약이 필요하다")
nameserver = str((solver.get("rfc2136") or {}).get("nameserver") or "")
host, separator, port = nameserver.rpartition(":")
if not separator:
    raise SystemExit("[FAIL] tls.solver.rfc2136.nameserver는 IPv4:port여야 한다")
ipaddress.IPv4Address(host)
if not 1 <= int(port) <= 65535:
    raise SystemExit("[FAIL] authoritative DNS port 범위 오류")
zone = str(spec.get("baseDomain") or "")
if mode == "delegated-rfc2136":
    zone = str((solver.get("delegation") or {}).get("zone") or "")
if not zone:
    raise SystemExit("[FAIL] authoritative DNS SOA probe zone이 비어 있다")

print(source)
print(namespace)
print(placement)
print(host)
print(port)
print(zone.rstrip("."))
PY
) || exit 1
mapfile -t contract_values <<<"${contract_output}"
TLS_SOURCE=${contract_values[0]}
CERT_MANAGER_NAMESPACE=${contract_values[1]}
CERT_MANAGER_PLACEMENT=${contract_values[2]}

if [[ ${TLS_SOURCE} != acme ]]; then
  note "TLS_SOURCE=provided: cert-manager DNS-01 노드 경로 검사는 적용되지 않음"
  exit 0
fi

DNS_SERVER=${contract_values[3]}
DNS_PORT=${contract_values[4]}
DNS_ZONE=${contract_values[5]}

note "DNS-01 경로 계획: placement=${CERT_MANAGER_PLACEMENT}, destination=authoritative-dns, protocols=TCP/UDP"
if [[ ${APPLY} != true ]]; then
  note "실제 controller 노드 경로를 검사하려면 --preflight-dns01 --apply"
  exit 0
fi

controller_pods=$(kctl get pod -n "${CERT_MANAGER_NAMESPACE}" \
  -l app.kubernetes.io/instance=cert-manager,app.kubernetes.io/component=controller \
  -o json 2>/dev/null) || die "cert-manager controller Pod 조회 실패"
mapfile -t controller_nodes < <(jq -r '
  .items[]?
  | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  | .spec.nodeName // empty
' <<<"${controller_pods}" | sort -u)
((${#controller_nodes[@]})) || die "Ready인 cert-manager controller Pod가 없어 DNS-01 경로를 검사할 수 없음"

if [[ ${CERT_MANAGER_PLACEMENT} == control-plane ]]; then
  for node in "${controller_nodes[@]}"; do
    [[ $(kctl get node "${node}" \
      -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null) == true ]] \
      || die "cert-manager controller가 계약의 control-plane placement 밖에 배치됨: node=${node}"
  done
fi

# probe image를 새로 pull하면 DNS 경로 검사 전에 registry egress가 개입한다. 이미 모든
# RKE2 노드에서 실행 중인 Canal image를 재사용하고 host root의 python3로 socket을 연다.
PROBE_IMAGE=$(kctl get daemonset -n kube-system rke2-canal \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
[[ -n ${PROBE_IMAGE} ]] || die "RKE2 Canal image를 찾을 수 없어 node host-network probe를 만들 수 없음"

probe_names=()
cleanup_dns01_probes() {
  local probe
  for probe in "${probe_names[@]}"; do
    kctl delete pod -n "${CERT_MANAGER_NAMESPACE}" "${probe}" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup_dns01_probes EXIT INT TERM

dns01_probe_node() {
  local node=$1 digest probe output reason
  digest=$(printf '%s' "${node}" | sha256sum | cut -c1-10)
  probe="sadp-dns01-preflight-${digest}"
  probe_names+=("${probe}")
  kctl delete pod -n "${CERT_MANAGER_NAMESPACE}" "${probe}" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true

  jq -n --arg namespace "${CERT_MANAGER_NAMESPACE}" --arg name "${probe}" \
    --arg node "${node}" --arg image "${PROBE_IMAGE}" '{
      apiVersion:"v1", kind:"Pod",
      metadata:{namespace:$namespace,name:$name,labels:{"app.kubernetes.io/name":"sadp-dns01-preflight"}},
      spec:{
        nodeName:$node, hostNetwork:true, hostPID:true, dnsPolicy:"ClusterFirstWithHostNet",
        automountServiceAccountToken:false, restartPolicy:"Never",
        tolerations:[{operator:"Exists"}],
        containers:[{
          name:"probe", image:$image, imagePullPolicy:"IfNotPresent",
          command:["/bin/sh","-ceu","while :; do sleep 30; done"],
          securityContext:{privileged:true,allowPrivilegeEscalation:true,readOnlyRootFilesystem:true},
          volumeMounts:[{name:"host-root",mountPath:"/host",readOnly:true}]
        }],
        volumes:[{name:"host-root",hostPath:{path:"/",type:"Directory"}}]
      }
    }' | kctl apply -f - >/dev/null
  kctl wait pod -n "${CERT_MANAGER_NAMESPACE}" "${probe}" \
    --for=condition=Ready --timeout=2m >/dev/null \
    || die "DNS-01 probe Pod Ready 실패: node=${node}, destination=authoritative-dns"

  if output=$(kctl exec -i -n "${CERT_MANAGER_NAMESPACE}" "${probe}" -- \
      chroot /host /bin/bash -ceu 'exec python3 - "$@"' bash \
      "${DNS_SERVER}" "${DNS_PORT}" "${DNS_ZONE}" 2>&1 <<'PY'
import errno
import random
import socket
import struct
import sys

host, raw_port, zone = sys.argv[1:]
port = int(raw_port)

def reason(error):
    if isinstance(error, (TimeoutError, socket.timeout)):
        return "timeout"
    if getattr(error, "errno", None) in (errno.EHOSTUNREACH, errno.ENETUNREACH):
        return "no-route"
    if getattr(error, "errno", None) == errno.ECONNREFUSED:
        return "refused"
    return "failed"

try:
    with socket.create_connection((host, port), timeout=5):
        pass
except OSError as error:
    raise SystemExit(f"tcp:{reason(error)}")
print("tcp:ok")

labels = zone.rstrip(".").split(".")
qname = b"".join(bytes([len(label.encode("ascii"))]) + label.encode("ascii") for label in labels) + b"\0"
identifier = random.SystemRandom().randrange(0, 65536)
query = struct.pack("!HHHHHH", identifier, 0x0100, 1, 0, 0, 0) + qname + struct.pack("!HH", 6, 1)
try:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(5)
        client.sendto(query, (host, port))
        response, _ = client.recvfrom(4096)
except OSError as error:
    raise SystemExit(f"udp:{reason(error)}")
if len(response) < 12 or struct.unpack("!H", response[:2])[0] != identifier:
    raise SystemExit("udp:invalid-response")
flags = struct.unpack("!H", response[2:4])[0]
if not flags & 0x8000 or not flags & 0x0400:
    raise SystemExit("udp:not-authoritative")
print("udp:ok")
PY
  ); then
    [[ ${output} == $'tcp:ok\nudp:ok' ]] || {
      printf '[FAIL] DNS-01 node route 실패: node=%s destination=authoritative-dns reason=invalid-probe-result\n' "${node}" >&2
      return 1
    }
  else
    reason=$(grep -Eo '(tcp|udp):(no-route|timeout|refused|failed|invalid-response|not-authoritative)' \
      <<<"${output}" | tail -n1)
    [[ -n ${reason} ]] || reason=probe-unavailable
    printf '[FAIL] DNS-01 node route 실패: node=%s destination=authoritative-dns reason=%s\n' \
      "${node}" "${reason}" >&2
    cat >&2 <<EOF
[ACTION] 값 비노출 확인 명령:
  kubectl -n ${CERT_MANAGER_NAMESPACE} get pod -l app.kubernetes.io/instance=cert-manager,app.kubernetes.io/component=controller -o wide
  kubectl get node ${node} -o jsonpath='{.metadata.labels}{"\n"}'
  sudo bash ./sadp --preflight-dns01 --apply
EOF
    return 1
  fi
  ok "DNS-01 node route: node=${node} destination=authoritative-dns TCP/UDP authoritative response"
}

for node in "${controller_nodes[@]}"; do
  dns01_probe_node "${node}" || exit 1
done
ok "cert-manager controller 배치 노드의 authoritative DNS-01 경로 확인"
