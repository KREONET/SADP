#!/usr/bin/env bash
# 전체 테스트베드 설치 진입점. 반복 실행 가능하며 외부 registry push를 수행하지 않는다.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "${ROOT}"

python3 scripts/site/render-network.py
bash scripts/node/install-squid-egress.sh
source platform/network/proxy.env
# 레거시 진입점도 플랫폼 리소스 전에 실제 CRI pull을 확인해 containerd proxy 누락을
# ImagePullBackOff가 난 뒤에 발견하지 않게 한다.
bash scripts/cluster/preflight.sh --image-pull-only
bash scripts/cluster/install-testbed-platform.sh
bash scripts/cluster/build-local-images.sh
bash scripts/cluster/bootstrap-testbed-services.sh
bash scripts/cluster/deploy-testbed-apps.sh
bash scripts/verify/verify-testbed.sh
printf '[OK]   SADP 테스트베드 구축 및 핵심 acceptance 완료\n'
