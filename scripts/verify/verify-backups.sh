#!/usr/bin/env bash
# 백업 checksum과 RKE2/OpenBao snapshot 포맷을 검사한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

require_root
for command in python3 gzip sha256sum; do require_command "${command}"; done
backup_path=${1:-${BACKUP_DIR}/latest}
backup_path=$(realpath "${backup_path}")
case ${backup_path} in
  "${BACKUP_DIR}"/*) ;;
  *) die "백업 경로는 ${BACKUP_DIR} 아래여야 함" ;;
esac
[[ -d ${backup_path} ]] || die "백업 디렉터리 없음: ${backup_path}"

(
  cd "${backup_path}"
  sha256sum --check SHA256SUMS >/dev/null
)
ok "백업 SHA256SUMS 일치"

etcd_snapshot=$(find "${backup_path}" -maxdepth 1 -type f -name 'sadp-etcd-*.zip' -print -quit)
[[ -s ${etcd_snapshot} ]] || die "etcd snapshot 없음"
python3 -m zipfile --test "${etcd_snapshot}" >/dev/null
gzip --test "${backup_path}/openbao-raft.snap"
[[ -s ${backup_path}/rke2-server-token ]] || die "RKE2 server token 백업 없음"
ok "RKE2 zip/OpenBao gzip 포맷 검사"
