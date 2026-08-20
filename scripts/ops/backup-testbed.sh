#!/usr/bin/env bash
# RKE2 etcd, OpenBao Raft, Keycloak PostgreSQL을 root-only 디렉터리에 백업한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

require_root
for command in jq sha256sum; do require_command "${command}"; done
ensure_state_dirs

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_dir=${BACKUP_DIR}/${timestamp}
install -d -m 0700 "${run_dir}"

/usr/local/bin/rke2 etcd-snapshot save --dir "${run_dir}" \
  --name sadp-etcd --snapshot-compress >/dev/null
etcd_snapshot=$(find "${run_dir}" -maxdepth 1 -type f -name 'sadp-etcd-*' -print -quit)
[[ -s ${etcd_snapshot} ]] || die "RKE2 etcd snapshot 생성 실패"
install -m 0600 /var/lib/rancher/rke2/server/token "${run_dir}/rke2-server-token"
ok "RKE2 etcd snapshot 생성"

openbao_init=${TESTBED_STATE_DIR}/openbao-init.json
[[ -s ${openbao_init} ]] || die "OpenBao 초기화 상태 파일 없음: ${openbao_init}"
jq -e '.root_token | type == "string" and length > 0' "${openbao_init}" >/dev/null \
  || die "OpenBao root token 없음"
openbao_remote=/tmp/openbao-${timestamp}.snap
openbao_local=${run_dir}/openbao-raft.snap
# root token은 kubectl exec argv/env에 넣지 않는다. 고정 shell이 stdin으로 받은 뒤 Pod
# 안에서만 export하고, snapshot 경로처럼 비밀이 아닌 인자만 command에 남긴다.
jq -er '.root_token' "${openbao_init}" |
  kctl exec -i -n openbao openbao-0 -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    exec bao operator raft snapshot save "$2"
  ' sh https://openbao.openbao.svc.cluster.local:8200 "${openbao_remote}" >/dev/null
kctl exec -n openbao openbao-0 -- test -s "${openbao_remote}"
kctl cp -n openbao -c openbao "openbao-0:${openbao_remote}" "${openbao_local}" >/dev/null
kctl exec -n openbao openbao-0 -- rm -f "${openbao_remote}"
[[ -s ${openbao_local} ]] || die "OpenBao Raft snapshot 복사 실패"
ok "OpenBao Raft snapshot 생성"

if keycloak_is_external; then
  # 외부 Keycloak은 DB도 외부 VM에 있다. 이 저장소의 백업 대상이 아니므로 건너뛴다.
  note "Keycloak deployment=external: PostgreSQL 백업은 외부 VM 책임(docs/keycloak-external.md)"
else
  postgres_remote=/tmp/keycloak-${timestamp}.dump
  postgres_local=${run_dir}/keycloak-postgresql.dump
  kctl exec -n keycloak keycloak-postgresql-0 -- sh -ceu '
    umask 077
    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
      --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" \
      --format=custom --file="$1"
    pg_restore --list "$1" >/dev/null
  ' sh "${postgres_remote}"
  kctl cp -n keycloak -c postgresql \
    "keycloak-postgresql-0:${postgres_remote}" "${postgres_local}" >/dev/null
  kctl exec -n keycloak keycloak-postgresql-0 -- rm -f "${postgres_remote}"
  [[ -s ${postgres_local} ]] || die "Keycloak PostgreSQL dump 복사 실패"
  ok "Keycloak PostgreSQL custom dump 생성 및 catalog 검사"
fi

kctl get nodes -o wide >"${run_dir}/cluster-inventory.txt"
kctl get gateway,httproute -A >"${run_dir}/gateway-inventory.txt"
(
  cd "${run_dir}"
  sha256sum ./* >SHA256SUMS
  sha256sum --check SHA256SUMS >/dev/null
)
chmod 0600 "${run_dir}"/*
ln -sfn "${timestamp}" "${BACKUP_DIR}/latest"
ok "백업 checksum 검증 완료: ${run_dir}"
