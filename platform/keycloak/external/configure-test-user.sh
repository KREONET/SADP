#!/usr/bin/env bash
# 외부 Keycloak의 acceptance 테스트 사용자를 in-cluster bootstrap과 같은 role로 수렴시킨다.
# 사용자명/비밀번호는 SSH stdin의 base64 두 줄로만 받고 argv·환경·원격 파일에 남기지 않는다.
set -euo pipefail

[[ $# == 6 ]] || {
  echo "[FAIL] env-file/kcadm/server/realm/client/base-domain 인자 필요" >&2
  exit 2
}
env_file=$1
kcadm=$2
server=$3
realm=$4
client_id=$5
base_domain=$6

[[ -r ${env_file} && -x ${kcadm} ]] \
  || { echo "[FAIL] Keycloak EnvironmentFile 또는 kcadm을 읽을 수 없음" >&2; exit 1; }
[[ ${server} =~ ^http://[A-Za-z0-9.-]+:[0-9]+$ ]] \
  || { echo "[FAIL] Keycloak server 형식 오류" >&2; exit 1; }
for value in "${realm}" "${client_id}"; do
  [[ ${value} =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "[FAIL] realm/client 형식 오류" >&2; exit 1; }
done
[[ ${base_domain} =~ ^[A-Za-z0-9.-]+$ ]] \
  || { echo "[FAIL] base domain 형식 오류" >&2; exit 1; }

IFS= read -r encoded_username \
  || { echo "[FAIL] 테스트 사용자 입력이 없음" >&2; exit 1; }
IFS= read -r encoded_password \
  || { echo "[FAIL] 테스트 비밀번호 입력이 없음" >&2; exit 1; }
test_username=$(printf '%s' "${encoded_username}" | base64 -d 2>/dev/null) \
  || { echo "[FAIL] 테스트 사용자 입력 형식 오류" >&2; exit 1; }
test_password=$(printf '%s' "${encoded_password}" | base64 -d 2>/dev/null) \
  || { echo "[FAIL] 테스트 비밀번호 입력 형식 오류" >&2; exit 1; }
unset encoded_username encoded_password
[[ ${test_username} =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "[FAIL] 테스트 사용자명 형식 오류" >&2; exit 1; }
((${#test_password} >= 32)) \
  || { echo "[FAIL] 테스트 비밀번호가 너무 짧음" >&2; exit 1; }

env_file_value() {
  local key=$1 rows
  rows=$(sed -n "s/^${key}=//p" "${env_file}")
  [[ $(grep -c '^' <<<"${rows}") == 1 && -n ${rows} ]] \
    || { echo "[FAIL] Keycloak EnvironmentFile에서 ${key}를 정확히 하나 읽지 못함" >&2; exit 1; }
  if [[ ${rows} == \"*\" && ${rows} == *\" ]]; then
    rows=${rows:1:${#rows}-2}
  elif [[ ${rows} == \'*\' && ${rows} == *\' ]]; then
    rows=${rows:1:${#rows}-2}
  fi
  printf '%s' "${rows}"
}

# /run은 noexec일 수 있으므로 실행 파일은 만들지 않고 kcadm config 데이터만 둔다.
run_dir=$(mktemp -d /run/sadp-keycloak-test-user.XXXXXX)
kcadm_config=${run_dir}/kcadm.config
cleanup() {
  unset test_password test_username KC_CLI_PASSWORD
  rm -f "${kcadm_config}"
  rmdir "${run_dir}" 2>/dev/null || true
}
trap cleanup EXIT
kc() { "${kcadm}" "$@" --config "${kcadm_config}"; }

export KC_CLI_PASSWORD
KC_CLI_PASSWORD=$(env_file_value KC_BOOTSTRAP_ADMIN_PASSWORD)
admin_user=$(env_file_value KC_BOOTSTRAP_ADMIN_USERNAME)
kc config credentials --server "${server}" --realm master --user "${admin_user}" \
  >/dev/null 2>&1 \
  || { echo "[FAIL] 외부 Keycloak 관리자 로그인 실패" >&2; exit 1; }
unset KC_CLI_PASSWORD

clients=$(kc get clients -r "${realm}" -q clientId="${client_id}")
client_uuid=$(jq -er --arg client "${client_id}" '
  [.[] | select(.clientId == $client)] as $matches
  | select(($matches | length) == 1)
  | $matches[0].id
' <<<"${clients}") \
  || { echo "[FAIL] Portal client를 정확히 하나 찾지 못함" >&2; exit 1; }

for role in platform-admin viewer; do
  groups=$(kc get groups -r "${realm}" -q search="${role}")
  group_count=$(jq --arg role "${role}" '[.[] | select(.name == $role)] | length' \
    <<<"${groups}")
  ((group_count <= 1)) || { echo "[FAIL] ${role} 그룹이 둘 이상임" >&2; exit 1; }
  if ((group_count == 0)); then
    kc create groups -r "${realm}" -s name="${role}" >/dev/null
    groups=$(kc get groups -r "${realm}" -q search="${role}")
  fi
  group_id=$(jq -er --arg role "${role}" \
    '.[] | select(.name == $role) | .id' <<<"${groups}") \
    || { echo "[FAIL] ${role} 그룹을 찾지 못함" >&2; exit 1; }

  kc get "roles/${role}" -r "${realm}" >/dev/null 2>&1 \
    || kc create roles -r "${realm}" -s name="${role}" >/dev/null
  kc get "clients/${client_uuid}/roles/${role}" -r "${realm}" >/dev/null 2>&1 \
    || kc create "clients/${client_uuid}/roles" -r "${realm}" -s name="${role}" >/dev/null
  kc add-roles -r "${realm}" --gname "${role}" --rolename "${role}" >/dev/null
  kc add-roles -r "${realm}" --gname "${role}" --cclientid "${client_id}" \
    --rolename "${role}" >/dev/null

  kc get "groups/${group_id}/role-mappings/realm" -r "${realm}" |
    jq -e --arg role "${role}" 'any(.[]; .name == $role)' >/dev/null \
    || { echo "[FAIL] ${role} realm role 그룹 매핑 실패" >&2; exit 1; }
  kc get "groups/${group_id}/role-mappings/clients/${client_uuid}" -r "${realm}" |
    jq -e --arg role "${role}" 'any(.[]; .name == $role)' >/dev/null \
    || { echo "[FAIL] ${role} client role 그룹 매핑 실패" >&2; exit 1; }
done

users=$(kc get users -r "${realm}" -q username="${test_username}")
user_count=$(jq --arg username "${test_username}" \
  '[.[] | select(.username == $username)] | length' <<<"${users}")
((user_count <= 1)) || { echo "[FAIL] acceptance 테스트 사용자가 둘 이상임" >&2; exit 1; }
user_document=$(jq -nc --arg username "${test_username}" --arg domain "${base_domain}" '{
  username:$username, enabled:true, emailVerified:true,
  email:($username + "@" + $domain), firstName:"SADP", lastName:"Tester"
}')
if ((user_count == 0)); then
  user_id=$(printf '%s' "${user_document}" |
    kc create users -r "${realm}" -i -f -)
else
  user_id=$(jq -er --arg username "${test_username}" \
    '.[] | select(.username == $username) | .id' <<<"${users}")
  printf '%s' "${user_document}" |
    kc update "users/${user_id}" -r "${realm}" -f - >/dev/null
fi

# 비밀번호는 jq와 kcadm에도 stdin으로만 전달해 원격 프로세스 argv에 남기지 않는다.
printf '%s' "${test_password}" |
  jq -Rsc '{type:"password", value:(sub("[\\r\\n]+$"; "")), temporary:false}' |
  kc update "users/${user_id}/reset-password" -r "${realm}" -f - >/dev/null
unset test_password

for role in platform-admin viewer; do
  group_id=$(kc get groups -r "${realm}" -q search="${role}" |
    jq -er --arg role "${role}" '.[] | select(.name == $role) | .id')
  kc update "users/${user_id}/groups/${group_id}" -r "${realm}" -n >/dev/null
done

user_groups=$(kc get "users/${user_id}/groups" -r "${realm}")
realm_roles=$(kc get "users/${user_id}/role-mappings/realm/composite" -r "${realm}")
client_roles=$(kc get \
  "users/${user_id}/role-mappings/clients/${client_uuid}/composite" -r "${realm}")
for role in platform-admin viewer; do
  jq -e --arg role "${role}" 'any(.[]; .name == $role)' <<<"${user_groups}" >/dev/null \
    || { echo "[FAIL] acceptance 테스트 사용자 ${role} 그룹 할당 실패" >&2; exit 1; }
  jq -e --arg role "${role}" 'any(.[]; .name == $role)' <<<"${realm_roles}" >/dev/null \
    || { echo "[FAIL] acceptance 테스트 사용자 ${role} realm role 누락" >&2; exit 1; }
  jq -e --arg role "${role}" 'any(.[]; .name == $role)' <<<"${client_roles}" >/dev/null \
    || { echo "[FAIL] acceptance 테스트 사용자 ${role} client role 누락" >&2; exit 1; }
done

echo "[OK]   외부 Keycloak acceptance 테스트 사용자와 realm/client role 수렴"
