#!/usr/bin/env bash
# 백업 checksum/포맷을 검사하고 PostgreSQL dump를 임시 DB에 실제 복원한다.
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

if keycloak_is_external; then
  # 외부 Keycloak은 DB가 외부 VM에 있어 이 저장소 백업에 dump가 없다. 복원 훈련도 그쪽에서 한다.
  note "Keycloak deployment=external: PostgreSQL 복원 훈련은 외부 VM 책임"
  exit 0
fi

timestamp=$(date +%s)
scratch_db=keycloak_restore_drill_${timestamp}
remote_dump=/tmp/${scratch_db}.dump
cleanup() {
  kctl exec -n keycloak keycloak-postgresql-0 -- sh -ceu '
    PGPASSWORD="$POSTGRES_PASSWORD" dropdb \
      --if-exists --username="$POSTGRES_USER" "$1"
    rm -f "$2"
  ' sh "${scratch_db}" "${remote_dump}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
kctl cp -n keycloak -c postgresql \
  "${backup_path}/keycloak-postgresql.dump" \
  "keycloak-postgresql-0:${remote_dump}" >/dev/null
kctl exec -n keycloak keycloak-postgresql-0 -- sh -ceu '
  PGPASSWORD="$POSTGRES_PASSWORD" createdb --username="$POSTGRES_USER" "$1"
  PGPASSWORD="$POSTGRES_PASSWORD" pg_restore \
    --username="$POSTGRES_USER" --dbname="$1" --no-owner --no-privileges \
    --single-transaction --exit-on-error "$2"
  realm_count=$(PGPASSWORD="$POSTGRES_PASSWORD" psql \
    --username="$POSTGRES_USER" --dbname="$1" --tuples-only --no-align \
    --command="SELECT COUNT(*) FROM realm;")
  test "$realm_count" -ge 2
' sh "${scratch_db}" "${remote_dump}"
cleanup
trap - EXIT
ok "Keycloak dump를 임시 DB에 실제 복원하고 realm 데이터 검증 후 제거"
