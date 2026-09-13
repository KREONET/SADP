#!/usr/bin/env bash
# 백업과 Kubernetes 상태 경계를 지켜 1+N 노드 RKE2 서비스를 순서대로 켜고 끈다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

ACTION=${1:-status}
if (($#)); then shift; fi
ROLE=
NODE_NAME=$(hostname -s)
APPLY=false
DRAINED_NODE=
POWER_STATE_DIR=${TESTBED_STATE_DIR}/power
PREPARED_FILE=${POWER_STATE_DIR}/prepared-off

usage() {
  cat <<'EOF'
SADP 테스트베드 안전 기동/종료

사용법:
  sudo bash ./sadp --power prepare-off --role server [--apply]
  sudo bash ./sadp --power off --role agent --drained-node <현재노드명> [--apply]
  sudo bash ./sadp --power off --role server [--apply]
  sudo bash ./sadp --power on --role server|agent [--apply]
  sudo bash ./sadp --power resume --role server [--apply]
  bash ./sadp --power status --role server|agent

종료 순서: prepare-off(control-plane) -> 모든 worker agent(단일 노드는 생략) off -> server off.
기동 순서: server on -> 모든 worker agent(단일 노드는 생략) on -> resume(control-plane).
이 명령은 RKE2 서비스만 제어하며 OS poweroff와 원격 전원 켜기는 수행하지 않는다.
EOF
}

while (($#)); do
  case "$1" in
    --role) ROLE=${2:?--role 값 필요}; shift ;;
    --node-name) NODE_NAME=${2:?--node-name 값 필요}; shift ;;
    --drained-node) DRAINED_NODE=${2:?--drained-node 값 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

case ${ROLE} in server|agent) ;; *) die "--role은 server|agent 중 하나여야 함" ;; esac
case ${ACTION} in prepare-off|off|on|resume|status) ;; *) usage >&2; die "알 수 없는 action: ${ACTION}" ;; esac
service=rke2-${ROLE}.service

print_plan() {
  case ${ACTION}:${ROLE} in
    prepare-off:server)
      note "전체 백업 검증 -> 모든 worker cordon/drain -> 종료 준비 marker 기록"
      ;;
    off:agent)
      note "drain 확인 후 현재 노드의 rke2-agent 중지"
      note "필요하면 서비스 중지 확인 뒤 운영체제를 종료"
      ;;
    off:server)
      note "모든 worker가 cordon+NotReady인지 확인 -> 최종 etcd snapshot -> rke2-server 중지"
      note "서비스 중지 확인 뒤 마지막으로 control-plane 운영체제를 종료"
      ;;
    on:server)
      note "rke2-server 시작 -> Kubernetes API와 control-plane Ready 대기"
      ;;
    on:agent)
      note "rke2-agent 시작; control-plane에서 전체 Ready 후 resume 필요"
      ;;
    resume:server)
      note "전체 Node Ready 확인 -> worker uncordon -> 종료 marker 제거"
      ;;
    status:*) ;;
    *) die "${ACTION}은 role=${ROLE}에서 지원하지 않음" ;;
  esac
}

if [[ ${ACTION} == status ]]; then
  state=$(systemctl is-active "${service}" 2>/dev/null || true)
  enabled=$(systemctl is-enabled "${service}" 2>/dev/null || true)
  prepared=no
  [[ -r ${PREPARED_FILE} ]] && prepared=yes
  printf 'node=%s role=%s service=%s enabled=%s shutdownPrepared=%s\n' \
    "${NODE_NAME}" "${ROLE}" "${state:-unknown}" "${enabled:-unknown}" "${prepared}"
  exit 0
fi

print_plan
if [[ ${APPLY} == false ]]; then
  note "계획만 확인함. 적용하려면 같은 명령에 --apply"
  exit 0
fi
require_root

worker_nodes() {
  kctl get nodes -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

case ${ACTION}:${ROLE} in
  prepare-off:server)
    systemctl is-active --quiet rke2-server.service || die "rke2-server가 active가 아님"
    kctl wait node --all --for=condition=Ready --timeout=3m >/dev/null \
      || die "종료 준비 전 모든 Node가 Ready가 아님"
    check_cluster_topology --allow-unschedulable
    note "종료 전 전체 백업"
    bash scripts/ops/backup-testbed.sh
    latest_backup=$(readlink -f "${BACKUP_DIR}/latest")
    [[ -d ${latest_backup} ]] || die "최신 백업 경로를 확인할 수 없음"
    mapfile -t workers < <(worker_nodes)
    for worker in "${workers[@]}"; do
      note "worker cordon/drain: ${worker}"
      kctl cordon "${worker}" >/dev/null
      # PDB와 unmanaged Pod 우회 옵션은 쓰지 않는다. 안전하게 비울 수 없으면 여기서 멈춘다.
      kctl drain "${worker}" --ignore-daemonsets --delete-emptydir-data --timeout=10m >/dev/null
    done
    install -d -m 0700 "${POWER_STATE_DIR}"
    {
      printf 'prepared_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'backup_path=%s\n' "${latest_backup}"
      printf 'workers=%s\n' "$(IFS=,; printf '%s' "${workers[*]}")"
      printf 'sadp_version=%s\n' "$(<VERSION)"
    } >"${PREPARED_FILE}"
    chmod 0600 "${PREPARED_FILE}"
    if ((${#workers[@]})); then
      ok "종료 준비 완료; 각 worker에서 --power off --role agent 실행"
    else
      ok "종료 준비 완료; 단일 서버에서 --power off --role server 실행"
    fi
    ;;
  off:agent)
    [[ ${DRAINED_NODE} == "${NODE_NAME}" ]] \
      || die "--drained-node ${NODE_NAME} 확인이 필요함"
    systemctl stop rke2-agent.service
    systemctl is-active --quiet rke2-agent.service && die "rke2-agent 중지 실패"
    ok "rke2-agent 중지 완료: ${NODE_NAME}"
    ;;
  off:server)
    [[ -r ${PREPARED_FILE} ]] || die "prepare-off marker가 없음: ${PREPARED_FILE}"
    check_cluster_topology --allow-not-ready --allow-unschedulable
    # 단일 server를 먼저 끄면 drain 확인도 최종 snapshot도 불가능하므로 worker 상태를 강제한다.
    kctl get nodes -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' -o json | \
      python3 -c '
import json, sys
nodes = json.load(sys.stdin).get("items", [])
bad = []
for node in nodes:
    ready = next((c.get("status") for c in node.get("status", {}).get("conditions", []) if c.get("type") == "Ready"), "Unknown")
    if not node.get("spec", {}).get("unschedulable") or ready == "True":
        name = node.get("metadata", {}).get("name", "unknown")
        cordoned = node.get("spec", {}).get("unschedulable", False)
        bad.append(f"{name}(cordon={cordoned},Ready={ready})")
if bad:
    raise SystemExit("[FAIL] 먼저 모든 worker agent를 중지해야 함: " + ", ".join(bad))
' || exit 1
    install -d -m 0700 "${POWER_STATE_DIR}"
    final_dir=${POWER_STATE_DIR}/$(date -u +%Y%m%dT%H%M%SZ)
    install -d -m 0700 "${final_dir}"
    "${SADP_RKE2_BIN:-/usr/local/bin/rke2}" etcd-snapshot save \
      --dir "${final_dir}" --name sadp-poweroff --snapshot-compress >/dev/null
    find "${final_dir}" -maxdepth 1 -type f -name 'sadp-poweroff-*' -size +0c | grep -q . \
      || die "종료 직전 etcd snapshot 생성 실패"
    systemctl stop rke2-server.service
    systemctl is-active --quiet rke2-server.service && die "rke2-server 중지 실패"
    ok "rke2-server 중지 완료; 이제 control-plane 운영체제를 종료할 수 있음"
    ;;
  on:server)
    systemctl start rke2-server.service
    deadline=$((SECONDS + 300))
    until systemctl is-active --quiet rke2-server.service && \
      [[ $(kctl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; do
      ((SECONDS < deadline)) || die "control-plane Ready 대기 timeout"
      sleep 5
    done
    ok "control-plane RKE2 Ready; worker가 있으면 agent 시작 후 resume, 단일 노드는 바로 resume"
    ;;
  on:agent)
    systemctl start rke2-agent.service
    systemctl is-active --quiet rke2-agent.service || die "rke2-agent 시작 실패"
    ok "rke2-agent active; control-plane에서 Node Ready를 확인"
    ;;
  resume:server)
    [[ -r ${PREPARED_FILE} ]] || die "prepare-off marker가 없음: ${PREPARED_FILE}"
    kctl wait node --all --for=condition=Ready --timeout=10m >/dev/null \
      || die "모든 Node가 Ready가 아니므로 uncordon하지 않음"
    check_cluster_topology --allow-unschedulable
    mapfile -t workers < <(worker_nodes)
    for worker in "${workers[@]}"; do kctl uncordon "${worker}" >/dev/null; done
    rm -f -- "${PREPARED_FILE}"
    ok "모든 Node Ready, worker uncordon, 정상 운영 재개"
    ;;
  *) die "${ACTION}은 role=${ROLE}에서 지원하지 않음" ;;
esac
