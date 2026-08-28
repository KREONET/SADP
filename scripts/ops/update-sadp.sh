#!/usr/bin/env bash
# 공식 main을 별도 디렉터리에서 검증한 뒤 현재 checkout을 fast-forward로만 갱신한다.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT}"

REPOSITORY=https://github.com/KREONET/SADP.git
BRANCH=main
APPLY=false

usage() {
  cat <<'EOF'
SADP VERSION 기반 업데이트 확인기

사용법:
  bash ./sadp --update-sadp [--repository <git-url>] [--branch main] [--apply]

기본 동작은 GitHub main을 임시 clone해 로컬/원격 VERSION과 versions.lock.yaml의
패키지 변경만 출력한다. --apply는 다음 조건을 모두 만족할 때만 현재 checkout을 갱신한다.

  - 원격 VERSION이 로컬 VERSION보다 높음
  - 현재 worktree가 clean이고 원격 commit으로 fast-forward 가능
  - 원격 checkout에서 bash ./sadp --test가 통과

사이트별 branch가 main과 갈라졌으면 자동 merge하지 않는다. 별도 update branch에서
main을 병합하고 site.env 재렌더와 검토를 수행한다.
EOF
}

while (($#)); do
  case "$1" in
    --repository) REPOSITORY=${2:?--repository 값 필요}; shift ;;
    --branch) BRANCH=${2:?--branch 값 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
note() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }

for command in git python3; do
  command -v "${command}" >/dev/null 2>&1 || die "필수 명령을 찾을 수 없음: ${command}"
done
[[ -d .git && -r VERSION && -r versions.lock.yaml ]] \
  || die "SADP Git checkout 루트에서 실행해야 함"
[[ ${BRANCH} =~ ^[A-Za-z0-9._/-]+$ && ${BRANCH} != -* && ${BRANCH} != */../* ]] \
  || die "안전하지 않은 branch 이름: ${BRANCH}"

tmp_dir=$(mktemp -d -t sadp-update.XXXXXXXXXX)
trap 'rm -rf "${tmp_dir}"' EXIT
upstream_dir=${tmp_dir}/upstream

note "원격 ${REPOSITORY} branch=${BRANCH}를 임시 디렉터리에서 확인"
git clone --quiet --depth 1 --single-branch --branch "${BRANCH}" -- "${REPOSITORY}" "${upstream_dir}" \
  || die "원격 main clone 실패"
[[ -r ${upstream_dir}/VERSION && -r ${upstream_dir}/versions.lock.yaml ]] \
  || die "원격 main에 VERSION 또는 versions.lock.yaml이 없음"

version_output=$(python3 - "${ROOT}/VERSION" "${upstream_dir}/VERSION" <<'PY'
import pathlib
import re
import sys

pattern = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
values = []
for path in sys.argv[1:]:
    value = pathlib.Path(path).read_text(encoding="utf-8").strip()
    match = pattern.fullmatch(value)
    if not match:
        raise SystemExit(f"[FAIL] 잘못된 VERSION 형식: {path}: {value!r}")
    values.append((value, tuple(map(int, match.groups()))))
print(values[0][0])
print(values[1][0])
print((values[1][1] > values[0][1]) - (values[1][1] < values[0][1]))
PY
) || exit 1
mapfile -t version_result <<<"${version_output}"

local_version=${version_result[0]}
remote_version=${version_result[1]}
comparison=${version_result[2]}
remote_commit=$(git -C "${upstream_dir}" rev-parse HEAD)
note "SADP local=${local_version} remote=${remote_version} commit=${remote_commit:0:12}"

python3 - "${ROOT}/versions.lock.yaml" "${upstream_dir}/versions.lock.yaml" <<'PY'
import sys
import yaml

def flatten(value, prefix=""):
    if isinstance(value, dict):
        for key in sorted(value):
            path = f"{prefix}.{key}" if prefix else str(key)
            yield from flatten(value[key], path)
    else:
        yield prefix, str(value)

with open(sys.argv[1], encoding="utf-8") as handle:
    before = dict(flatten(yaml.safe_load(handle) or {}))
with open(sys.argv[2], encoding="utf-8") as handle:
    after = dict(flatten(yaml.safe_load(handle) or {}))

changes = []
for key in sorted(set(before) | set(after)):
    if before.get(key) != after.get(key):
        changes.append((key, before.get(key, "<없음>"), after.get(key, "<없음>")))
if changes:
    print("[INFO] 패키지 버전 변경:")
    for key, old, new in changes:
        print(f"       {key}: {old} -> {new}")
else:
    print("[INFO] versions.lock.yaml 패키지 버전 변경 없음")
PY

if ((comparison == 0)); then
  ok "이미 최신 SADP VERSION ${local_version}"
  exit 0
fi
((comparison > 0)) || die "원격 VERSION ${remote_version}이 로컬 ${local_version}보다 낮아 downgrade를 거부"

if [[ ${APPLY} == false ]]; then
  note "계획만 확인함. 적용하려면 같은 명령에 --apply"
  exit 0
fi

[[ -z $(git status --porcelain) ]] || die "worktree가 clean하지 않아 업데이트를 거부"

note "원격 checkout 회귀 시험 실행"
(cd "${upstream_dir}" && bash ./sadp --test) \
  || die "원격 SADP ${remote_version} 회귀 시험 실패"

update_ref=refs/sadp-update/${BRANCH//\//-}
git fetch --quiet --no-tags -- "${REPOSITORY}" "+${BRANCH}:${update_ref}" \
  || die "검증한 원격 commit fetch 실패"
fetched_commit=$(git rev-parse "${update_ref}")
[[ ${fetched_commit} == "${remote_commit}" ]] \
  || die "검증 중 원격 main이 변경됨; 처음부터 다시 확인해야 함"
git merge-base --is-ancestor HEAD "${update_ref}" \
  || die "현재 branch가 main과 갈라져 fast-forward 불가; 별도 update branch에서 수동 병합 필요"
git merge --ff-only "${update_ref}"
[[ $(<VERSION) == "${remote_version}" ]] || die "업데이트 후 VERSION 불일치"
ok "SADP ${local_version} -> ${remote_version} fast-forward 완료"
note "site.env 재렌더, diff/test, 사이트 GitOps branch push 후 패키지 수렴을 확인해야 함"
