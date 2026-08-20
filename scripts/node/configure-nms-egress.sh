#!/usr/bin/env bash
# Apply the rendered Canal/Calico OSS host route and fixed-source NMS SNAT.
set -euo pipefail

MODE=${1:-check}
ENV_FILE=${2:-/etc/sadp/nms-egress.env}
[[ -r ${ENV_FILE} ]] || { echo "[FAIL] ${ENV_FILE}을 읽을 수 없음" >&2; exit 1; }
source "${ENV_FILE}"

[[ ${NMS_MODE:-disabled} == network ]] || {
  echo "[FAIL] 이 installer는 network 모드 전용임(NMS_MODE=${NMS_MODE:-disabled})" >&2
  exit 1
}
for name in NMS_DESTINATION_CIDR NMS_PORT NMS_GATEWAY_INTERNAL_IP \
  NMS_INTERFACE NMS_GATEWAY_IP NMS_NEXT_HOP POD_CIDR; do
  [[ -n ${!name:-} && ${!name} != 0 ]] || {
    echo "[FAIL] ${name} 값이 없음" >&2
    exit 1
  }
done
command -v ip >/dev/null || { echo "[FAIL] ip 명령이 필요함" >&2; exit 1; }

case "${MODE}" in
  check)
    echo "mode=network destination=${NMS_DESTINATION_CIDR} port=${NMS_PORT}"
    echo "gateway=${NMS_GATEWAY_INTERNAL_IP} nms_interface=${NMS_INTERFACE}"
    echo "snat_source=${NMS_GATEWAY_IP} next_hop=${NMS_NEXT_HOP}"
    ;;
  worker)
    [[ ${EUID} -eq 0 ]] || { echo "[FAIL] root 권한이 필요함" >&2; exit 1; }
    command -v iptables >/dev/null || { echo "[FAIL] iptables가 필요함" >&2; exit 1; }
    k8s_interface=$(ip -4 route get "${NMS_GATEWAY_INTERNAL_IP}" | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    [[ -n ${k8s_interface} ]] || {
      echo "[FAIL] Kubernetes 내부망 interface를 찾지 못함" >&2
      exit 1
    }
    ip route replace "${NMS_DESTINATION_CIDR}" \
      via "${NMS_GATEWAY_INTERNAL_IP}" dev "${k8s_interface}"

    # Canal의 일반 외부 SNAT보다 먼저 NMS 패킷을 제외해 gateway가 원래 Pod CIDR을 보게 한다.
    iptables -t nat -N SADP_NMS_BYPASS 2>/dev/null || true
    iptables -t nat -F SADP_NMS_BYPASS
    iptables -t nat -A SADP_NMS_BYPASS \
      -s "${POD_CIDR}" -d "${NMS_DESTINATION_CIDR}" \
      -p tcp --dport "${NMS_PORT}" -j ACCEPT
    iptables -t nat -A SADP_NMS_BYPASS -j RETURN
    iptables -t nat -C POSTROUTING -j SADP_NMS_BYPASS 2>/dev/null ||
      iptables -t nat -I POSTROUTING 1 -j SADP_NMS_BYPASS
    echo "[OK] worker NMS route와 Canal SNAT 예외 적용"
    ;;
  gateway)
    [[ ${EUID} -eq 0 ]] || { echo "[FAIL] root 권한이 필요함" >&2; exit 1; }
    command -v iptables >/dev/null || { echo "[FAIL] iptables가 필요함" >&2; exit 1; }
    ip link show "${NMS_INTERFACE}" >/dev/null
    ip -4 addr show dev "${NMS_INTERFACE}" | grep -Fq " ${NMS_GATEWAY_IP}/" || {
      echo "[FAIL] ${NMS_INTERFACE}에 ${NMS_GATEWAY_IP}가 없음" >&2
      exit 1
    }
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w "net.ipv4.conf.${NMS_INTERFACE}.rp_filter=2" >/dev/null
    ip route replace "${NMS_DESTINATION_CIDR}" \
      via "${NMS_NEXT_HOP}" dev "${NMS_INTERFACE}" \
      src "${NMS_GATEWAY_IP}" table 200
    ip rule show | grep -Fq "to ${NMS_DESTINATION_CIDR} lookup 200" ||
      ip rule add priority 100 to "${NMS_DESTINATION_CIDR}" lookup 200

    iptables -t nat -N SADP_NMS_SNAT 2>/dev/null || true
    iptables -t nat -F SADP_NMS_SNAT
    iptables -t nat -A SADP_NMS_SNAT \
      -s "${POD_CIDR}" -d "${NMS_DESTINATION_CIDR}" \
      -o "${NMS_INTERFACE}" -p tcp --dport "${NMS_PORT}" \
      -j SNAT --to-source "${NMS_GATEWAY_IP}"
    iptables -t nat -A SADP_NMS_SNAT -j RETURN
    iptables -t nat -C POSTROUTING -j SADP_NMS_SNAT 2>/dev/null ||
      iptables -t nat -I POSTROUTING 1 -j SADP_NMS_SNAT

    iptables -N SADP_NMS_FWD 2>/dev/null || true
    iptables -F SADP_NMS_FWD
    iptables -A SADP_NMS_FWD \
      -s "${POD_CIDR}" -d "${NMS_DESTINATION_CIDR}" \
      -o "${NMS_INTERFACE}" -p tcp --dport "${NMS_PORT}" \
      -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    iptables -A SADP_NMS_FWD \
      -d "${POD_CIDR}" -s "${NMS_DESTINATION_CIDR}" \
      -i "${NMS_INTERFACE}" -p tcp --sport "${NMS_PORT}" \
      -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A SADP_NMS_FWD \
      -s "${POD_CIDR}" -d "${NMS_DESTINATION_CIDR}" -j DROP
    iptables -A SADP_NMS_FWD -j RETURN
    iptables -C FORWARD -j SADP_NMS_FWD 2>/dev/null ||
      iptables -I FORWARD 1 -j SADP_NMS_FWD
    echo "[OK] gateway NMS policy route, FORWARD 정책과 고정 SNAT 적용"
    ;;
  *)
    echo "usage: $0 check|worker|gateway [env-file]" >&2
    exit 2
    ;;
esac
