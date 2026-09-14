#!/usr/bin/env bash
# 사이트 파일을 보내지 않고 검토된 Git 소스에서 재사용 가능한 앱 이미지 두 개를 만든다.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APPLY=false
OUTPUT=
REGISTRY=registry.example.invalid/sadp
while (($#)); do
  case "$1" in
    --output) OUTPUT=${2:?output 필요}; shift ;;
    --registry) REGISTRY=${2:?registry/project 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help) echo '사용법: bash ./sadp --release-images --output <새 디렉터리> [--registry <registry/project>] [--apply]'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n ${OUTPUT} && ${REGISTRY} =~ ^[a-z0-9][a-z0-9./_-]*$ ]] || { echo 'output과 registry/project 확인 필요' >&2; exit 1; }
revision=$(git -C "${ROOT}" rev-parse HEAD)
printf '[INFO] linux/amd64 test-app / portal-lite, tag=%s\n' "${revision}"
printf '[INFO] 출력: %s (registry에 자동 push하지 않음)\n' "${OUTPUT}"
[[ ${APPLY} == true ]] || exit 0
[[ -z $(git -C "${ROOT}" status --porcelain --untracked-files=normal) ]] || { echo '검토한 소스를 먼저 commit해야 함' >&2; exit 1; }
[[ ! -e ${OUTPUT} ]] || { echo '기존 출력 경로를 덮어쓰지 않음' >&2; exit 1; }
docker info >/dev/null
mkdir -p "${OUTPUT}"
OUTPUT=$(cd "${OUTPUT}" && pwd)
context=$(mktemp -d)
trap 'rm -rf -- "${context}"' EXIT
# ignored .env/인증서뿐 아니라 추적되지 않은 파일도 build context에 포함하지 않는다.
git -C "${ROOT}" archive HEAD apps/test-app apps/portal-lite | tar -xf - -C "${context}"
test_ref=${REGISTRY}/test-app:${revision}
portal_ref=${REGISTRY}/portal-lite:${revision}
docker build --platform linux/amd64 -t "${test_ref}" "${context}/apps/test-app"
docker build --platform linux/amd64 -t "${portal_ref}" "${context}/apps/portal-lite"
docker save -o "${OUTPUT}/images.tar.part" "${test_ref}" "${portal_ref}"
mv "${OUTPUT}/images.tar.part" "${OUTPUT}/images.tar"
python3 "${ROOT}/scripts/release/image-bundle.py" create --directory "${OUTPUT}" \
  --test-app-ref "${test_ref}" --portal-ref "${portal_ref}" --revision "${revision}"
printf '[OK] bundle 생성 완료. 사이트별 NEXT_PUBLIC 표시값이 필요하면 별도 사이트 빌드를 사용한다.\n'
