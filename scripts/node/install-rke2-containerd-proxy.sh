#!/usr/bin/env bash
# RKE2가 시작할 embedded containerd에만 승인 Squid 환경을 전달한다. 값은 어떤 경로에서도
# 출력하지 않고, 재시작은 노드별 유지보수 창에서 운영자가 직접 수행하게 둔다.
set -euo pipefail

ROLE=auto
PROXY_ENV=
ROOT_PREFIX=
MODE=plan

usage() {
  cat <<'EOF'
usage: sudo scripts/node/install-rke2-containerd-proxy.sh \
  [--role auto|server|agent] [--proxy-env platform/network/proxy.env] \
  [--root-prefix /host] [--apply|--check]

기본은 server/agent를 자동 판별하고 변경될 파일과 변수 이름만 보여준다. --apply는
/etc/default/rke2-<role>의 SADP 관리 블록을 mode 0600으로 멱등 갱신하지만 RKE2를
재시작하지 않는다. 유지보수 창의 수동 재시작 뒤 --check로 관리 파일, 실행 중 RKE2,
RKE2 embedded containerd 환경을 함께 확인한다. 값이나 credential은 출력하지 않는다.

--role은 자동 판별할 서비스/프로세스가 없거나 둘 다 발견된 경우에만 명시적으로 쓴다.
--root-prefix는 host root를 mount한 진단/테스트 환경에서만 사용한다.
EOF
}

while (($#)); do
  case "$1" in
    --role) ROLE=${2:-}; shift ;;
    --proxy-env) PROXY_ENV=${2:-}; shift ;;
    --root-prefix) ROOT_PREFIX=${2:-}; shift ;;
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case ${ROLE} in auto|server|agent) ;; *) printf '[FAIL] --role은 auto|server|agent여야 함\n' >&2; exit 2 ;; esac
if [[ -n ${ROOT_PREFIX} ]]; then
  [[ ${ROOT_PREFIX} == /* && ${ROOT_PREFIX} != / ]] || {
    printf '[FAIL] --root-prefix는 /가 아닌 절대 경로여야 함\n' >&2
    exit 2
  }
  [[ -d ${ROOT_PREFIX}/etc && -d ${ROOT_PREFIX}/proc ]] || {
    printf '[FAIL] host root 구조를 찾을 수 없음\n' >&2
    exit 1
  }
fi
if [[ -z ${PROXY_ENV} ]]; then
  PROXY_ENV=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/platform/network/proxy.env
fi
[[ -f ${PROXY_ENV} && ! -L ${PROXY_ENV} && -r ${PROXY_ENV} ]] || {
  printf '[FAIL] proxy env가 읽을 수 있는 일반 파일이 아님\n' >&2
  exit 1
}

# 생성된 proxy.env만 입력으로 받는다. 임의 shell 파일을 source하면 credential 검증 전에
# 코드가 실행될 수 있으므로 허용한 export 행만 직접 읽는다.
declare -A proxy_values=()
while IFS= read -r line || [[ -n ${line} ]]; do
  [[ ${line} == 'export '* ]] || continue
  assignment=${line#export }
  name=${assignment%%=*}
  value=${assignment#*=}
  case ${name} in HTTP_PROXY|HTTPS_PROXY|NO_PROXY) ;; *) continue ;; esac
  [[ ${value} != '"'* && ${value} != "'"* ]] || value=${value:1:${#value}-2}
  proxy_values["${name}"]=${value}
done <"${PROXY_ENV}"

HTTP_PROXY=${proxy_values[HTTP_PROXY]:-}
HTTPS_PROXY=${proxy_values[HTTPS_PROXY]:-}
NO_PROXY=${proxy_values[NO_PROXY]:-}
for name in HTTP_PROXY HTTPS_PROXY; do
  value=${!name}
  [[ ${value} =~ ^https?://[^/@[:space:]]+(:[0-9]{1,5})?/?$ && ${value} != *@* ]] || {
    printf '[FAIL] %s는 credential 없는 http(s) URL이어야 함\n' "${name}" >&2
    exit 1
  }
done
[[ -n ${NO_PROXY} && ${NO_PROXY} != *[[:space:]]* && ${NO_PROXY} != *@* ]] || {
  printf '[FAIL] NO_PROXY는 credential과 공백이 없는 comma 목록이어야 함\n' >&2
  exit 1
}

read_cmdline() {
  local path=$1 destination=$2
  local -n result=${destination}
  result=()
  [[ -r ${path} ]] || return 1
  mapfile -d '' -t result <"${path}" || true
  ((${#result[@]} > 0))
}

rke2_role_from_argv() {
  local destination=$1 first base
  local -n argv_ref=${destination}
  ((${#argv_ref[@]} > 0)) || return 1
  first=${argv_ref[0]}
  base=${first##*/}
  if [[ ${base} == rke2 && ${#argv_ref[@]} -ge 2 \
      && ( ${argv_ref[1]} == server || ${argv_ref[1]} == agent ) ]]; then
    printf '%s\n' "${argv_ref[1]}"
    return 0
  fi
  if [[ ${first} =~ (^|/)rke2[[:space:]]+(server|agent)($|[[:space:]]) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

scan_rke2_processes() {
  local process_dir process_role
  local -a argv=()
  for process_dir in "${ROOT_PREFIX}"/proc/[0-9]*; do
    [[ -d ${process_dir} ]] || continue
    read_cmdline "${process_dir}/cmdline" argv || continue
    process_role=$(rke2_role_from_argv argv 2>/dev/null) || continue
    printf '%s %s\n' "${process_role}" "${process_dir##*/}"
  done
}

detect_role() {
  local path process_role
  local -a roles=()
  for process_role in server agent; do
    for path in \
      "${ROOT_PREFIX}/etc/systemd/system/rke2-${process_role}.service" \
      "${ROOT_PREFIX}/usr/lib/systemd/system/rke2-${process_role}.service" \
      "${ROOT_PREFIX}/usr/local/lib/systemd/system/rke2-${process_role}.service"; do
      [[ ! -e ${path} && ! -L ${path} ]] || { roles+=("${process_role}"); break; }
    done
  done
  while read -r process_role _; do
    [[ -n ${process_role} ]] && roles+=("${process_role}")
  done < <(scan_rke2_processes)

  mapfile -t roles < <(printf '%s\n' "${roles[@]}" | awk 'NF && !seen[$0]++')
  if ((${#roles[@]} != 1)); then
    printf '[FAIL] RKE2 role 자동 판별이 모호함(server/agent 중 정확히 하나 필요); --role로 해소하라\n' >&2
    return 1
  fi
  printf '%s\n' "${roles[0]}"
}

if [[ ${ROLE} == auto ]]; then
  ROLE=$(detect_role)
fi

begin='# BEGIN SADP MANAGED CONTAINERD PROXY'
end='# END SADP MANAGED CONTAINERD PROXY'
target=${ROOT_PREFIX}/etc/default/rke2-${ROLE}
expected_names=(
  CONTAINERD_HTTP_PROXY CONTAINERD_HTTPS_PROXY CONTAINERD_NO_PROXY
)
declare -A expected=(
  [CONTAINERD_HTTP_PROXY]="${HTTP_PROXY}"
  [CONTAINERD_HTTPS_PROXY]="${HTTPS_PROXY}"
  [CONTAINERD_NO_PROXY]="${NO_PROXY}"
  [HTTP_PROXY]="${HTTP_PROXY}"
  [HTTPS_PROXY]="${HTTPS_PROXY}"
  [NO_PROXY]="${NO_PROXY}"
)

validate_target_shape() {
  local file=$1
  [[ ! -L ${file} ]] || { printf '[FAIL] 관리 대상이 symlink임: %s\n' "${file}" >&2; return 1; }
  [[ ! -e ${file} || -f ${file} ]] || {
    printf '[FAIL] 관리 대상이 일반 파일이 아님: %s\n' "${file}" >&2
    return 1
  }
  [[ ! -e ${file} ]] && return 0
  awk -v begin="${begin}" -v end="${end}" '
    $0 == begin { begins++; if (inside) bad=1; inside=1; next }
    $0 == end { ends++; if (!inside) bad=1; inside=0; next }
    END { if (bad || inside || begins != ends || begins > 1) exit 1 }
  ' "${file}" || {
    printf '[FAIL] SADP 관리 표식이 중첩되었거나 짝이 맞지 않음: %s\n' "${file}" >&2
    return 1
  }
}
validate_target_shape "${target}"

read_managed_block() {
  local file=$1 destination=$2 line name value inside=false
  local -n result=${destination}
  result=()
  while IFS= read -r line || [[ -n ${line} ]]; do
    [[ ${line} != "${begin}" ]] || { inside=true; continue; }
    [[ ${line} != "${end}" ]] || { inside=false; continue; }
    [[ ${inside} == true ]] || continue
    [[ ${line} == *=* ]] || return 1
    name=${line%%=*}
    value=${line#*=}
    [[ -n ${name} && ! -v "result[${name}]" ]] || return 1
    result["${name}"]=${value}
  done <"${file}"
}

check_expected_map() {
  local destination=$1 context=$2 name
  local -n actual=${destination}
  for name in "${expected_names[@]}"; do
    if [[ ! -v "actual[${name}]" || ${actual[${name}]} != "${expected[${name}]}" ]]; then
      printf '[FAIL] %s 환경 불일치: %s\n' "${context}" "${name}" >&2
      return 1
    fi
  done
}

read_process_environment() {
  local pid=$1 destination=$2 entry name value
  local -n result=${destination}
  result=()
  [[ -r ${ROOT_PREFIX}/proc/${pid}/environ ]] || return 1
  while IFS= read -r -d '' entry || [[ -n ${entry} ]]; do
    [[ -n ${entry} && ${entry} == *=* ]] || continue
    name=${entry%%=*}
    value=${entry#*=}
    [[ -n ${name} ]] || continue
    result["${name}"]=${value}
  done <"${ROOT_PREFIX}/proc/${pid}/environ"
}

embedded_containerd_pids() {
  local process_dir executable
  for process_dir in "${ROOT_PREFIX}"/proc/[0-9]*; do
    [[ -d ${process_dir} ]] || continue
    # argv[0]은 PATH 실행이나 process title 변경으로 짧아질 수 있다. 실제 실행 파일을
    # 확인해야 Docker containerd/shim과 구분하면서 RKE2의 짧은 argv도 놓치지 않는다.
    executable=$(readlink "${process_dir}/exe" 2>/dev/null) || continue
    # 실행 중 바이너리가 교체되어도 기존 프로세스의 proxy 환경 검사는 계속 필요하다.
    executable=${executable% (deleted)}
    if [[ ${executable} == /var/lib/rancher/rke2/bin/containerd \
        || ${executable} == /var/lib/rancher/rke2/*/bin/containerd ]]; then
      printf '%s\n' "${process_dir##*/}"
    fi
  done
}

if [[ ${MODE} == check ]]; then
  [[ -f ${target} && ! -L ${target} ]] || {
    printf '[FAIL] 관리 파일이 없음: %s\n' "${target}" >&2
    exit 1
  }
  [[ $(stat -c '%a' "${target}") == 600 ]] || {
    printf '[FAIL] 관리 파일 mode가 0600이 아님: %s\n' "${target}" >&2
    exit 1
  }
  declare -A managed=()
  read_managed_block "${target}" managed || {
    printf '[FAIL] 관리 블록 형식이 잘못됨\n' >&2
    exit 1
  }
  check_expected_map managed '관리 파일'

  mapfile -t rke2_processes < <(scan_rke2_processes | awk -v role="${ROLE}" '$1 == role {print $2}')
  ((${#rke2_processes[@]} == 1)) || {
    printf '[FAIL] 실행 중 rke2-%s 프로세스가 정확히 하나가 아님\n' "${ROLE}" >&2
    exit 1
  }
  declare -A rke2_environment=()
  read_process_environment "${rke2_processes[0]}" rke2_environment || {
    printf '[FAIL] 실행 중 RKE2 환경을 읽지 못함\n' >&2
    exit 1
  }
  for name in CONTAINERD_HTTP_PROXY CONTAINERD_HTTPS_PROXY CONTAINERD_NO_PROXY; do
    if [[ ! -v "rke2_environment[${name}]" \
        || ${rke2_environment[${name}]} != "${expected[${name}]}" ]]; then
      printf '[FAIL] 실행 중 RKE2 환경 불일치: %s\n' "${name}" >&2
      exit 1
    fi
  done

  mapfile -t containerd_processes < <(embedded_containerd_pids)
  ((${#containerd_processes[@]} == 1)) || {
    printf '[FAIL] RKE2 embedded containerd 프로세스가 정확히 하나가 아님(count=%s)\n' "${#containerd_processes[@]}" >&2
    if ((${#containerd_processes[@]})); then
      printf '[INFO] 확인된 embedded containerd PID: %s\n' "${containerd_processes[*]}" >&2
    fi
    printf '[NEXT] ps -C containerd -o pid,ppid,comm으로 실제 개수를 확인하세요. 검사를 우회하거나 자동 재시작하지 않습니다.\n' >&2
    exit 1
  }
  declare -A containerd_environment=()
  read_process_environment "${containerd_processes[0]}" containerd_environment || {
    printf '[FAIL] embedded containerd 환경을 읽지 못함\n' >&2
    exit 1
  }
  for name in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [[ ! -v "containerd_environment[${name}]" \
        || ${containerd_environment[${name}]} != "${expected[${name}]}" ]]; then
      printf '[FAIL] embedded containerd 환경 불일치: %s\n' "${name}" >&2
      exit 1
    fi
  done
  printf '[OK]   rke2-%s 관리 파일과 실행 중 RKE2/containerd proxy 환경 일치(값 비출력)\n' "${ROLE}"
  exit 0
fi

if [[ ${MODE} == plan ]]; then
  printf '[INFO] role=%s 대상=%s\n' "${ROLE}" "${target}"
  printf '[INFO] 관리 변수: %s\n' "${expected_names[*]}"
  printf '[INFO] 재시작 후 embedded containerd 검사 변수: HTTP_PROXY HTTPS_PROXY NO_PROXY\n'
  printf '[INFO] 값은 출력하지 않음. 적용하려면 --apply, 수동 재시작 뒤 --check\n'
  exit 0
fi

if [[ -z ${ROOT_PREFIX} && ${EUID} -ne 0 ]]; then
  printf '[FAIL] --apply는 root 권한이 필요함\n' >&2
  exit 1
fi
install -d -m 0755 "${target%/*}"
temporary=$(mktemp)
trap 'rm -f "${temporary}"' EXIT
if [[ -f ${target} ]]; then
  awk -v begin="${begin}" -v end="${end}" '
    $0 == begin { inside=1; next }
    $0 == end { inside=0; next }
    !inside { print }
  ' "${target}" >"${temporary}"
fi
while [[ -s ${temporary} && $(tail -c 1 "${temporary}" | wc -l) -eq 0 ]]; do
  printf '\n' >>"${temporary}"
done
{
  printf '%s\n' "${begin}"
  for name in "${expected_names[@]}"; do
    printf '%s=%s\n' "${name}" "${expected[${name}]}"
  done
  printf '%s\n' "${end}"
} >>"${temporary}"
install -m 0600 "${temporary}" "${target}"
printf '[OK]   rke2-%s containerd proxy 관리 블록 설치(값 비출력): %s\n' "${ROLE}" "${target}"
printf '[NEXT] RKE2는 재시작하지 않았다. 유지보수 창에서 실행: sudo systemctl restart rke2-%s\n' "${ROLE}"
printf '[NEXT] Ready 확인 뒤 실행: sudo bash ./sadp --install-containerd-proxy --role %s --check\n' "${ROLE}"
