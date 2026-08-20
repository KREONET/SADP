#!/usr/bin/env bash
# ArgoCD가 GitOps 저장소에 접속하기 위한 repository Secret을 만든다.
#
# 이 스크립트가 존재하는 이유:
#   repository Secret을 손으로 만들면 argocd/*.yaml의 repoURL과 조용히 어긋난다.
#   ArgoCD는 URL이 한 글자만 달라도 자격증명을 찾지 못하고 익명 접속으로 떨어지며,
#   private 저장소에서는 "repository not found"로만 보여 원인 추적이 오래 걸린다.
#   그래서 URL을 사람이 다시 입력하지 않고 argocd/bootstrap-application.yaml에서
#   그대로 읽어 온다. 매니페스트가 진실이고 Secret은 거기서 파생된다.
#
# 또한 이 클러스터의 Pod는 공인 도메인을 DNS로 해석하지 못하므로(CoreDNS 상위 차단)
# 저장소 접속은 반드시 Squid를 경유해야 한다. ArgoCD의 per-repository proxy 필드를
# 사용하며 Deployment는 건드리지 않는다. Deployment를 패치하면 devtron Helm 릴리스의
# 다음 upgrade 때 조용히 사라진다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

TOKEN_FILE=
USERNAME=
CHECK_ONLY=false
SECRET_NAME=sadp-repo
ARGOCD_NAMESPACE=devtroncd

usage() {
  cat <<'USAGE'
사용법: configure-argocd-repo.sh --token-file PATH --username NAME [--check]

  --token-file PATH   Forgejo 봇 토큰 파일 (내용은 출력하지 않는다)
  --username NAME     Forgejo 계정명 (토큰 소유자)
  --check             변경 없이 현재 상태만 검사한다
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --token-file) TOKEN_FILE=${2:?--token-file 값 필요}; shift ;;
    --username) USERNAME=${2:?--username 값 필요}; shift ;;
    --check) CHECK_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in python3 git; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
cd "${TESTBED_ROOT}"
source platform/network/proxy.env

# ── 1. repoURL을 매니페스트에서 읽는다(사람이 다시 입력하지 않는다) ──────────────
REPO_URL=$(python3 - <<'PY'
import glob
import sys

import yaml

urls = set()
for path in glob.glob("argocd/**/*.yaml", recursive=True):
    if path.endswith("_template-application.yaml"):
        continue  # 템플릿은 placeholder를 담고 있으므로 제외한다
    with open(path, encoding="utf-8") as handle:
        for document in yaml.safe_load_all(handle):
            if not isinstance(document, dict):
                continue
            kind = document.get("kind")
            spec = document.get("spec") or {}
            if kind == "Application":
                sources = spec.get("sources") or [spec.get("source") or {}]
                for source in sources:
                    url = (source or {}).get("repoURL", "")
                    if url and not url.startswith("oci://") and "://" in url:
                        # Helm chart 저장소(chart 필드 동반)는 자격증명 대상이 아니다
                        if not (source or {}).get("chart"):
                            urls.add(url)
            elif kind == "AppProject":
                for url in spec.get("sourceRepos") or []:
                    if url.startswith(("http://", "https://")) and url.endswith("SADP"):
                        urls.add(url)

if not urls:
    sys.exit("argocd/ 에서 GitOps repoURL을 찾지 못함")
if len(urls) > 1:
    sys.exit("argocd/ 안의 GitOps repoURL이 서로 다름: " + ", ".join(sorted(urls)))
print(urls.pop())
PY
) || die "${REPO_URL:-repoURL 추출 실패}"
ok "매니페스트에서 읽은 GitOps 저장소: ${REPO_URL}"

# ── 2. Pod가 실제로 쓸 egress 경로를 계약에서 가져온다 ─────────────────────────
REPO_PROXY=${HTTPS_PROXY}
REPO_NO_PROXY=${NO_PROXY}
[[ -n ${REPO_PROXY} ]] || die "platform/network/proxy.env 에 HTTPS_PROXY가 없음"

# ── 3. 검사 모드: 현재 Secret이 매니페스트와 일치하는지만 본다 ────────────────
current_url=$(kctl get secret "${SECRET_NAME}" -n "${ARGOCD_NAMESPACE}" \
  -o jsonpath='{.data.url}' 2>/dev/null | base64 -d 2>/dev/null || true)
current_proxy=$(kctl get secret "${SECRET_NAME}" -n "${ARGOCD_NAMESPACE}" \
  -o jsonpath='{.data.proxy}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ ${CHECK_ONLY} == true ]]; then
  [[ -n ${current_url} ]] || die "repository Secret 없음: ${ARGOCD_NAMESPACE}/${SECRET_NAME}"
  [[ ${current_url} == "${REPO_URL}" ]] \
    || die "Secret url(${current_url})이 매니페스트 repoURL(${REPO_URL})과 다름"
  [[ ${current_proxy} == "${REPO_PROXY}" ]] \
    || die "Secret proxy(${current_proxy:-없음})가 승인된 egress(${REPO_PROXY})와 다름"
  ok "repository Secret이 매니페스트/egress 계약과 일치"
  exit 0
fi

[[ -n ${TOKEN_FILE} ]] || { usage >&2; die "--token-file 필요"; }
[[ -n ${USERNAME} ]] || { usage >&2; die "--username 필요"; }
TOKEN=$(read_secret_file "${TOKEN_FILE}")
[[ -n ${TOKEN} ]] || die "토큰 파일이 비어 있음: ${TOKEN_FILE}"

# ── 4. 쓰기 전에 자격증명이 실제로 통하는지 확인한다 ──────────────────────────
# 잘못된 자격증명을 Secret에 넣으면 ArgoCD는 몇 분간 재시도만 반복하고
# 원인은 repo-server 로그 깊은 곳에만 남는다. 먼저 검증하고 나중에 쓴다.
probe_url=${REPO_URL/https:\/\//https://${USERNAME}:${TOKEN}@}
if git -c "http.proxy=${REPO_PROXY}" ls-remote "${probe_url}" HEAD >/dev/null 2>&1; then
  ok "Squid(${REPO_PROXY}) 경유 저장소 인증 성공"
else
  die "저장소 인증 실패: ${REPO_URL} (사용자 ${USERNAME}, proxy ${REPO_PROXY})"
fi

# ── 5. Secret을 매니페스트에서 파생된 값으로 갱신한다 ────────────────────────
kctl create secret generic "${SECRET_NAME}" -n "${ARGOCD_NAMESPACE}" \
  --from-literal=type=git \
  --from-literal=url="${REPO_URL}" \
  --from-literal=username="${USERNAME}" \
  --from-literal=password="${TOKEN}" \
  --from-literal=proxy="${REPO_PROXY}" \
  --from-literal=noProxy="${REPO_NO_PROXY}" \
  --dry-run=client -o yaml \
  | kctl label --local -f - --dry-run=client -o yaml \
      argocd.argoproj.io/secret-type=repository \
  | kctl apply -f - >/dev/null
ok "repository Secret 갱신: ${ARGOCD_NAMESPACE}/${SECRET_NAME}"

if [[ -n ${current_url} && ${current_url} != "${REPO_URL}" ]]; then
  note "이전 저장소 주소였던 ${current_url} 는 더 이상 사용되지 않는다"
fi

# ── 6. 업스트림 Helm 차트 저장소도 같은 egress를 타게 한다 ───────────────────
# repo-server는 chart 앱을 만들 때 `helm pull`을 직접 실행하는데, 이때는 위의 git
# Secret을 보지 않는다. proxy 없이 나가서 Squid에 막히면 매니페스트 생성 자체가
# 실패하고 앱은 Degraded도 Missing도 아닌 sync status Unknown 으로만 남는다.
# (원인이 조건 메시지 안쪽에만 찍혀서 찾기 어렵다.)
#
# repo-server에 HTTPS_PROXY 환경변수를 거는 방법도 있지만 그러면 클러스터 내부
# 트래픽까지 전부 프록시 후보가 된다. 여기서는 git과 동일하게 저장소 단위
# proxy 필드를 쓴다. 목록은 매니페스트에서 파생시켜 차트 앱이 늘어도
# 이 스크립트를 고칠 필요가 없게 한다.
chart_repos=$(python3 - <<'PY'
import glob, sys, yaml

urls = set()
for path in sorted(glob.glob("argocd/applications/*.yaml")):
    with open(path, encoding="utf-8") as fh:
        for doc in yaml.safe_load_all(fh):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            spec = doc.get("spec") or {}
            sources = spec.get("sources") or []
            if spec.get("source"):
                sources = [spec["source"], *sources]
            for src in sources:
                # chart 가 없으면 git 소스다. git 은 위의 repository Secret 이 덮는다.
                if isinstance(src, dict) and src.get("chart") and src.get("repoURL"):
                    urls.add(str(src["repoURL"]).strip())
print("\n".join(sorted(urls)))
PY
) || die "argocd/applications 파싱 실패"
if [[ -z ${chart_repos} ]]; then
  note "chart 기반 Application이 없어 helm 저장소 Secret은 건너뛴다"
else
  while read -r chart_url; do
    [[ -n ${chart_url} ]] || continue
    # Secret 이름은 URL에서 파생한다. 소문자/숫자/'-'만 남겨 RFC1123을 지킨다.
    slug=$(printf '%s' "${chart_url#https://}" \
      | tr '[:upper:]' '[:lower:]' | sed 's,[^a-z0-9-],-,g; s,-\+,-,g; s,^-,,; s,-$,,')
    # scheme 이 없으면 OCI 레지스트리다(예: docker.io/envoyproxy).
    # enableOCI 를 켜지 않으면 ArgoCD가 index.yaml 을 찾다가 실패한다.
    enable_oci=false
    [[ ${chart_url} == https://* ]] || enable_oci=true
    kctl create secret generic "helm-${slug}" -n "${ARGOCD_NAMESPACE}" \
      --from-literal=type=helm \
      --from-literal=name="${slug}" \
      --from-literal=url="${chart_url}" \
      --from-literal=enableOCI="${enable_oci}" \
      --from-literal=proxy="${REPO_PROXY}" \
      --from-literal=noProxy="${REPO_NO_PROXY}" \
      --dry-run=client -o yaml \
      | kctl label --local -f - --dry-run=client -o yaml \
          argocd.argoproj.io/secret-type=repository \
      | kctl apply -f - >/dev/null
    ok "helm 저장소 Secret: ${chart_url}"
  done <<<"${chart_repos}"
fi

note "ArgoCD가 새 자격증명을 집어들도록 repo-server 캐시를 비운다"
kctl rollout restart deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}" >/dev/null
kctl rollout status deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=180s >/dev/null \
  || die "argocd-repo-server 재시작이 완료되지 않음"
ok "argocd-repo-server 재시작 완료"
