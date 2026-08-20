#!/usr/bin/env bash
# Pin RKE2 to the Kubernetes-internal NIC on multi-homed production nodes.
set -euo pipefail

ROLE=
INTERNAL_IP=
INTERNAL_INTERFACE=eth0
EXTERNAL_INTERFACE=
NMS_INTERFACE=
INTERNAL_MAC=
EXTERNAL_MAC=
NMS_MAC=
SERVER_URL=
SERVICE_CIDR=10.43.0.0/16
APPLY=false

while (($#)); do
  case "$1" in
    --role) ROLE=${2:-}; shift ;;
    --internal-ip) INTERNAL_IP=${2:-}; shift ;;
    --internal-interface) INTERNAL_INTERFACE=${2:-}; shift ;;
    --external-interface) EXTERNAL_INTERFACE=${2:-}; shift ;;
    --nms-interface) NMS_INTERFACE=${2:-}; shift ;;
    --internal-mac) INTERNAL_MAC=${2:-}; shift ;;
    --external-mac) EXTERNAL_MAC=${2:-}; shift ;;
    --nms-mac) NMS_MAC=${2:-}; shift ;;
    --server-url) SERVER_URL=${2:-}; shift ;;
    --service-cidr) SERVICE_CIDR=${2:-}; shift ;;
    --apply) APPLY=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo scripts/node/install-rke2-network-identity.sh \
  --role server|agent --internal-ip <IPv4> \
  [--internal-interface eth0] [--external-interface eth1] \
  [--nms-interface eth2] [--server-url https://<internal-ip>:9345] \
  [--service-cidr 10.43.0.0/16] [--apply] \
  [--internal-mac <MAC>] [--external-mac <MAC>] [--nms-mac <MAC>]

--*-mac은 선택이다. 값을 주면 그 이름의 NIC이 실제로 그 MAC인지 확인하고 다르면
설치를 멈춘다. 이름이 여전히 실제 식별자이고 MAC은 오결선/이름 밀림을 잡는 단언이다.
MAC은 노드마다 다르므로 계약이 아니라 노드별 인자로 전달한다.

--server-url은 agent에서만 사용하며, 재부팅 때 사라질 수 있는 단일 호스트명 대신
RKE2 server의 내부 IPv4 endpoint를 drop-in에 함께 고정한다.
agent에서는 서비스 CIDR과 Calico 가상 gateway 경로도 내부망에 고정한다.
EOF
      exit 0
      ;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ ${ROLE} == server || ${ROLE} == agent ]] || {
  echo "[FAIL] --role server|agent가 필요함" >&2
  exit 2
}
[[ -n ${INTERNAL_INTERFACE} ]] || {
  echo "[FAIL] --internal-interface 값이 비어 있음" >&2
  exit 2
}
[[ ${INTERNAL_INTERFACE} =~ ^[[:alnum:]_.:-]{1,15}$ ]] || {
  echo "[FAIL] 유효하지 않은 interface 이름: ${INTERNAL_INTERFACE}" >&2
  exit 2
}
python3 - "${INTERNAL_IP}" "${SERVER_URL}" "${ROLE}" "${SERVICE_CIDR}" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

value = ipaddress.ip_address(sys.argv[1])
if value.version != 4 or value.is_loopback or value.is_multicast or value.is_unspecified:
    raise SystemExit("유효한 Kubernetes 내부 IPv4가 아님")

server_url, role, service_cidr = sys.argv[2:]
try:
    service_network = ipaddress.ip_network(service_cidr, strict=True)
except ValueError as exc:
    raise SystemExit("--service-cidr는 정규 IPv4 CIDR이어야 함") from exc
if (
    service_network.version != 4
    or service_network.is_loopback
    or service_network.is_multicast
    or service_network.is_unspecified
):
    raise SystemExit("--service-cidr는 유효한 IPv4 CIDR이어야 함")
if value in service_network:
    raise SystemExit("내부 node IPv4와 service CIDR이 겹침")

if role == "server" and server_url:
    raise SystemExit("--server-url은 agent에서만 사용 가능")
if server_url:
    parsed = urlsplit(server_url)
    if (
        parsed.scheme != "https"
        or parsed.username
        or parsed.password
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
        or parsed.port != 9345
    ):
        raise SystemExit("--server-url은 https://<internal-ip>:9345 형식이어야 함")
    try:
        endpoint = ipaddress.ip_address(parsed.hostname or "")
    except ValueError as exc:
        raise SystemExit("--server-url host는 내부 IPv4여야 함") from exc
    if endpoint.version != 4 or endpoint.is_loopback or endpoint.is_unspecified:
        raise SystemExit("--server-url host는 내부 IPv4여야 함")
    if endpoint in service_network:
        raise SystemExit("RKE2 server IPv4와 service CIDR이 겹침")
PY
# MAC은 NIC을 유일하게 식별하지 못한다. VLAN 하위 interface는 부모의 MAC을 그대로
# 쓰고 bonding slave는 bond의 MAC을 따라간다. 그래서 이름을 대체하지 않고, 이름으로
# 고른 NIC이 기대한 물리 포트인지 확인하는 단언으로만 쓴다.
assert_mac() {
  local name=$1 expected=$2 actual
  [[ -n ${expected} ]] || return 0
  [[ ${expected} =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
    echo "[FAIL] MAC 형식이 올바르지 않음: ${expected}" >&2
    exit 2
  }
  actual=$(cat "/sys/class/net/${name}/address" 2>/dev/null) || {
    echo "[FAIL] ${name}의 MAC을 읽지 못함" >&2
    exit 1
  }
  [[ ${actual,,} == "${expected,,}" ]] || {
    echo "[FAIL] ${name} MAC 불일치: 기대 ${expected}, 실제 ${actual}" >&2
    exit 1
  }
}

ip link show "${INTERNAL_INTERFACE}" >/dev/null 2>&1 || {
  echo "[FAIL] 내부망 interface가 없음: ${INTERNAL_INTERFACE}" >&2
  exit 1
}
assert_mac "${INTERNAL_INTERFACE}" "${INTERNAL_MAC}"
ip -4 addr show dev "${INTERNAL_INTERFACE}" | grep -Fq " ${INTERNAL_IP}/" || {
  echo "[FAIL] ${INTERNAL_INTERFACE}에 ${INTERNAL_IP}가 없음" >&2
  exit 1
}

if [[ -n ${EXTERNAL_INTERFACE} ]]; then
  [[ ${EXTERNAL_INTERFACE} != "${INTERNAL_INTERFACE}" ]] || {
    echo "[FAIL] 내부망과 외부망 interface가 같음" >&2
    exit 1
  }
  ip link show "${EXTERNAL_INTERFACE}" >/dev/null 2>&1 || {
    echo "[FAIL] 외부망 interface가 없음: ${EXTERNAL_INTERFACE}" >&2
    exit 1
  }
  assert_mac "${EXTERNAL_INTERFACE}" "${EXTERNAL_MAC}"
  ip -4 route show default | grep -Eq "(^| )dev ${EXTERNAL_INTERFACE}( |$)" || {
    echo "[FAIL] IPv4 default route가 ${EXTERNAL_INTERFACE}에 없음" >&2
    exit 1
  }
fi

if [[ -n ${NMS_INTERFACE} ]]; then
  [[ ${NMS_INTERFACE} != "${INTERNAL_INTERFACE}" && ${NMS_INTERFACE} != "${EXTERNAL_INTERFACE}" ]] || {
    echo "[FAIL] NMS interface는 내부망/외부망과 달라야 함" >&2
    exit 1
  }
  ip link show "${NMS_INTERFACE}" >/dev/null 2>&1 || {
    echo "[FAIL] NMS interface가 없음: ${NMS_INTERFACE}" >&2
    exit 1
  }
  assert_mac "${NMS_INTERFACE}" "${NMS_MAC}"
fi

content="node-ip: ${INTERNAL_IP}"
if [[ ${ROLE} == server ]]; then
  content+=$'\n'"advertise-address: ${INTERNAL_IP}"
  content+=$'\n'"bind-address: ${INTERNAL_IP}"
elif [[ -n ${SERVER_URL} ]]; then
  content+=$'\n'"server: ${SERVER_URL}"
else
  echo "[WARN] --server-url이 없어 기존 agent server endpoint는 변경하지 않음" >&2
fi
printf '%s\n' "${content}"

if [[ ${APPLY} == true ]]; then
  [[ ${EUID} -eq 0 ]] || { echo "[FAIL] --apply는 root 권한이 필요함" >&2; exit 1; }
  target=/etc/rancher/rke2/config.yaml.d/10-internal-network.yaml
  install -d -m 0755 "${target%/*}"
  temporary=$(mktemp)
  trap 'rm -f "${temporary}"' EXIT
  printf '%s\n' "${content}" >"${temporary}"
  install -m 0600 "${temporary}" "${target}"

  if [[ ${ROLE} == agent && -n ${SERVER_URL} ]]; then
    server_ip=${SERVER_URL#https://}
    server_ip=${server_ip%:9345}
    ip_binary=$(command -v ip)
    route_service=sadp-rke2-network-routes.service
    route_target=/etc/systemd/system/${route_service}
    cat >"${temporary}" <<EOF
[Unit]
Description=Keep RKE2 service and Calico gateway routes on the internal network
Wants=network-online.target
After=network-online.target
Before=rke2-agent.service

[Service]
Type=oneshot
ExecStart=${ip_binary} route replace ${SERVICE_CIDR} via ${server_ip} dev ${INTERNAL_INTERFACE}
ExecStart=${ip_binary} route replace 169.254.1.1/32 dev lo
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "${temporary}" "${route_target}"
    systemctl daemon-reload
    systemctl enable "${route_service}" >/dev/null
    systemctl restart "${route_service}"
    echo "[OK] ${route_target} 설치 및 경로 적용"
  elif [[ ${ROLE} == agent ]]; then
    echo "[WARN] --server-url이 없어 service/Calico 경로 unit은 설치하지 않음" >&2
  fi

  if [[ ${ROLE} == server ]]; then
    canal_target=/var/lib/rancher/rke2/server/manifests/rke2-canal-config.yaml
    install -d -m 0755 "${canal_target%/*}"
    cat >"${temporary}" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-canal
  namespace: kube-system
spec:
  valuesContent: |-
    flannel:
      iface: ${INTERNAL_INTERFACE}
EOF
    install -m 0644 "${temporary}" "${canal_target}"
    echo "[OK] ${canal_target} 설치(Canal=${INTERNAL_INTERFACE})"
  fi

  service=rke2-agent
  [[ ${ROLE} == server ]] && service=rke2-server
  echo "[OK] ${target} 설치. 유지보수 창에 systemctl restart ${service} 실행 필요"
fi
