#!/usr/bin/env bash
# Block Kubernetes/RKE2 management ports on public and NMS interfaces.
set -euo pipefail

MODE=plan
EXTERNAL_INTERFACE=
NMS_INTERFACE=
EXTERNAL_MAC=
NMS_MAC=
GUARDED_INTERFACES=()
PORTS=2379,2380,6443,9345,10250
CHAIN=SADP_RKE2_GUARD

while (($#)); do
  case "$1" in
    --external-interface) EXTERNAL_INTERFACE=${2:-}; shift ;;
    --nms-interface) NMS_INTERFACE=${2:-}; shift ;;
    --external-mac) EXTERNAL_MAC=${2:-}; shift ;;
    --nms-mac) NMS_MAC=${2:-}; shift ;;
    --guarded-interface) GUARDED_INTERFACES+=("${2:-}"); shift ;;
    --blocked-tcp-ports) PORTS=${2:-}; shift ;;
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    --enforce) MODE=enforce ;;
    -h|--help)
      cat <<'EOF'
usage: sudo scripts/node/install-rke2-interface-guard.sh \
  --external-interface eth1 [--nms-interface eth2] \
  [--external-mac <MAC>] [--nms-mac <MAC>] \
  [--guarded-interface <NAME>]... \
  [--blocked-tcp-ports 2379,2380,3128,6443,9345,10250] [--apply|--check]

--guarded-interface는 여러 번 줄 수 있다. NMS용으로 꽂아만 두고 아직 NMS_MODE를 켜지
않은 NIC처럼, 계약상 역할이 비어 있는데 공인 주소를 갖는 NIC을 여기 넣어 external과
같은 관리 포트를 막는다. 계약의 GUARDED_INTERFACES(=platform/network/firewall.env)가
이 목록의 출처이며, NMS를 실제로 켜면 --nms-interface로 옮긴다.

기본 모드는 변경 없이 계획만 출력한다. --apply는 IPv4/IPv6 INPUT guard와 이를
부팅 때 복원하는 systemd unit을 설치한다. --enforce는 unit 내부용이다.

--*-mac은 선택이며 그 이름의 NIC이 실제로 그 MAC인지 확인한다. --apply로 준 MAC은
unit의 ExecStart에도 들어가므로 재부팅으로 이름이 밀리면 guard가 조용히 엉뚱한
NIC을 막는 대신 unit이 실패한다.
EOF
      exit 0
      ;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

valid_interface() {
  [[ $1 =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]
}

# 이름이 실제 식별자이고 MAC은 그 이름이 기대한 물리 포트를 가리키는지 확인하는
# 단언이다. VLAN/bonding은 부모 MAC을 공유하므로 MAC 단독 식별자로는 쓰지 않는다.
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

valid_ports() {
  [[ $1 =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  local old_ifs=${IFS} value
  IFS=,
  for value in $1; do
    ((value >= 1 && value <= 65535)) || { IFS=${old_ifs}; return 1; }
  done
  IFS=${old_ifs}
}

valid_ports "${PORTS}" || {
  echo "[FAIL] --blocked-tcp-ports는 1..65535 CSV여야 함" >&2
  exit 2
}

[[ -n ${EXTERNAL_INTERFACE} ]] || {
  echo "[FAIL] --external-interface가 필요함" >&2
  exit 2
}
valid_interface "${EXTERNAL_INTERFACE}" || {
  echo "[FAIL] 외부망 interface 이름이 올바르지 않음" >&2
  exit 2
}
ip link show "${EXTERNAL_INTERFACE}" >/dev/null 2>&1 || {
  echo "[FAIL] 외부망 interface가 없음: ${EXTERNAL_INTERFACE}" >&2
  exit 1
}
assert_mac "${EXTERNAL_INTERFACE}" "${EXTERNAL_MAC}"

interfaces=("${EXTERNAL_INTERFACE}")
if [[ -n ${NMS_INTERFACE} ]]; then
  valid_interface "${NMS_INTERFACE}" || {
    echo "[FAIL] NMS interface 이름이 올바르지 않음" >&2
    exit 2
  }
  [[ ${NMS_INTERFACE} != "${EXTERNAL_INTERFACE}" ]] || {
    echo "[FAIL] 외부망과 NMS interface가 같음" >&2
    exit 1
  }
  ip link show "${NMS_INTERFACE}" >/dev/null 2>&1 || {
    echo "[FAIL] NMS interface가 없음: ${NMS_INTERFACE}" >&2
    exit 1
  }
  assert_mac "${NMS_INTERFACE}" "${NMS_MAC}"
  interfaces+=("${NMS_INTERFACE}")
fi

# NMS 용으로 꽂아만 두고 아직 활성화하지 않은 NIC 처럼, 계약상 역할이 비어 있는데
# 공인 주소를 갖는 NIC 도 관리 포트는 막는다.
# 이 스크립트는 내부망 NIC 이름을 받지 않으므로 여기서 걸러낼 수 없다. 내부망 NIC 을
# 막으면 etcd/apiserver/kubelet 이 끊기므로, 그 검사는 계약 쪽
# (configure-site.py 의 GUARDED_INTERFACES, render-network.py 의 interfaces.guarded)에서 한다.
for guarded in ${GUARDED_INTERFACES[@]+"${GUARDED_INTERFACES[@]}"}; do
  valid_interface "${guarded}" || {
    echo "[FAIL] guarded interface 이름이 올바르지 않음: ${guarded}" >&2
    exit 2
  }
  ip link show "${guarded}" >/dev/null 2>&1 || {
    echo "[FAIL] guarded interface가 없음: ${guarded}" >&2
    exit 1
  }
  for existing in "${interfaces[@]}"; do
    [[ ${guarded} != "${existing}" ]] || {
      echo "[FAIL] 이미 차단 대상인 interface가 중복 지정됨: ${guarded}" >&2
      exit 2
    }
  done
  interfaces+=("${guarded}")
done

require_root() {
  [[ ${EUID} -eq 0 ]] || {
    echo "[FAIL] ${MODE} 모드는 root 권한이 필요함" >&2
    exit 1
  }
}

enforce_family() {
  local binary=$1 interface
  command -v "${binary}" >/dev/null 2>&1 || {
    echo "[FAIL] ${binary} 명령이 필요함" >&2
    exit 1
  }
  "${binary}" -w 5 -N "${CHAIN}" 2>/dev/null || true
  "${binary}" -w 5 -F "${CHAIN}"
  for interface in "${interfaces[@]}"; do
    "${binary}" -w 5 -A "${CHAIN}" -i "${interface}" -p tcp \
      -m multiport --dports "${PORTS}" -j DROP
  done
  "${binary}" -w 5 -A "${CHAIN}" -j RETURN
  "${binary}" -w 5 -C INPUT -j "${CHAIN}" 2>/dev/null || \
    "${binary}" -w 5 -I INPUT 1 -j "${CHAIN}"
}

check_family() {
  local binary=$1 interface
  "${binary}" -w 5 -C INPUT -j "${CHAIN}"
  for interface in "${interfaces[@]}"; do
    "${binary}" -w 5 -C "${CHAIN}" -i "${interface}" -p tcp \
      -m multiport --dports "${PORTS}" -j DROP
  done
  "${binary}" -w 5 -C "${CHAIN}" -j RETURN
}

case "${MODE}" in
  plan)
    echo "interfaces=${interfaces[*]}"
    echo "blocked_tcp_ports=${PORTS} address_families=ipv4,ipv6"
    echo "[INFO] --apply 전까지 host firewall는 변경되지 않음"
    ;;
  enforce)
    require_root
    enforce_family iptables
    enforce_family ip6tables
    echo "[OK] 외부/NMS interface의 RKE2 관리 포트 차단 적용"
    ;;
  check)
    require_root
    check_family iptables
    check_family ip6tables
    echo "[OK] IPv4/IPv6 RKE2 interface guard 검증"
    ;;
  apply)
    require_root
    install -D -m 0755 "$0" /usr/local/sbin/sadp-rke2-interface-guard
    unit=/etc/systemd/system/sadp-rke2-interface-guard.service
    temporary=$(mktemp)
    trap 'rm -f "${temporary}"' EXIT
    exec_start="/usr/local/sbin/sadp-rke2-interface-guard --enforce --external-interface ${EXTERNAL_INTERFACE}"
    [[ -z ${NMS_INTERFACE} ]] || exec_start+=" --nms-interface ${NMS_INTERFACE}"
    [[ -z ${EXTERNAL_MAC} ]] || exec_start+=" --external-mac ${EXTERNAL_MAC}"
    [[ -z ${NMS_MAC} ]] || exec_start+=" --nms-mac ${NMS_MAC}"
    for guarded in ${GUARDED_INTERFACES[@]+"${GUARDED_INTERFACES[@]}"}; do
      exec_start+=" --guarded-interface ${guarded}"
    done
    exec_start+=" --blocked-tcp-ports ${PORTS}"
    printf '%s\n' \
      '[Unit]' \
      'Description=Block RKE2 management ports on non-internal interfaces' \
      'Wants=network-online.target' \
      'After=network-online.target' \
      'Before=rke2-server.service rke2-agent.service' \
      '' \
      '[Service]' \
      'Type=oneshot' \
      "ExecStart=${exec_start}" \
      'RemainAfterExit=yes' \
      '' \
      '[Install]' \
      'WantedBy=multi-user.target' >"${temporary}"
    install -m 0644 "${temporary}" "${unit}"
    systemctl daemon-reload
    systemctl enable sadp-rke2-interface-guard.service
    # Type=oneshot + RemainAfterExit=yes 라서 이미 active 인 unit 에는 `--now` 가 아무 일도
    # 하지 않는다. 계약이 바뀌어 ExecStart 인자가 달라져도 체인에는 옛 규칙이 그대로 남고,
    # 바로 아래 check_family 가 "iptables: Bad rule" 만 뱉는다. 명시적으로 다시 실행한다.
    systemctl restart sadp-rke2-interface-guard.service
    systemctl is-active --quiet sadp-rke2-interface-guard.service
    check_family iptables
    check_family ip6tables
    echo "[OK] ${unit} 설치 및 RKE2 interface guard 적용"
    ;;
esac
