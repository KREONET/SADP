# 사전 빌드 앱 이미지

여러 사이트에 설치할 때 기본 앱 이미지를 한 번 만들어 재사용하는 방법입니다.
**이미지를 만드는 담당자**와 **이미지를 받아 설치하는 담당자**는 각자 해당 절을 따르세요.
전달하는 bundle은 이미지 압축 파일과 그 내용을 설명하는 목록 파일의 묶음입니다.
현재 지원 플랫폼은 `linux/amd64`입니다.

사전 빌드 이미지는 앱 빌드만 대체합니다. RKE2·네트워크·인증·Secret 설정은
[설치 가이드](installation.md)에 따라 별도로 준비해야 합니다.

## 배포 담당자

Docker Engine이 실행 중인 빌드 서버의 저장소 루트에서 소스를 검토·commit한 뒤 실행합니다.
출력 위치는 Git 밖의 **새 디렉터리**를 지정합니다. 먼저 계획을 확인하고 `--apply`로 빌드합니다.

```bash
bash ./sadp --release-images --output <ABSOLUTE_BUNDLE_DIRECTORY>
bash ./sadp --release-images --output <ABSOLUTE_BUNDLE_DIRECTORY> --apply
```

`images.tar`는 이미지 압축 파일, `bundle.json`은 소스 commit·플랫폼·이미지 참조·checksum을 담은
목록 파일입니다. 이미지 tag는 소스 commit SHA입니다. CI에서도 같은 명령을 사용합니다.
`--registry <REGISTRY_HOST>/<PROJECT>`는 이미지 이름만 선택하며 자동 push하지 않습니다.
외부 Registry에 게시하려면 해당 자격증명과 게시 대상을 준비해 별도로 push합니다.

빌드는 `git archive`로 선택한 앱 소스만 전달합니다. Git에서 제외된 `.env`, site.env, 인증서,
클러스터 상태와 실행용 Secret을 가져오지 않습니다. Portal과 Go의 코드 검사·시험·빌드를 통과해야
압축 파일을 만듭니다. Auth.js는 실제 요청을 처리할 때 OIDC 환경을 검사하므로
이미지 빌드에 OIDC 비밀번호가 필요하지 않습니다.

## 설치 담당자

신뢰하는 배포 경로에서 두 파일을 같은 디렉터리로 받습니다. checksum은 손상 확인용이며
배포자의 신원을 증명하는 서명은 아닙니다. 출처를 확인할 수 없는 파일은 사용하지 마세요.

이 사이트에서 사용하는 `site.env`(설치기 기본 위치는 `/etc/sadp/site.env`)에 다음을 기록합니다.
그 뒤 설정 생성 → 변경 검토·시험 → Git 반영 → 설치 순서를 따릅니다.

```dotenv
SADP_BUILD_IMAGES=false
SADP_PREBUILT_BUNDLE=<ABSOLUTE_BUNDLE_DIRECTORY_ON_CONTROL_PLANE>
TEST_APP_IMAGE_TAG=<BUNDLE_SOURCE_REVISION>
PORTAL_IMAGE_TAG=<BUNDLE_SOURCE_REVISION>
```

`SADP_PREBUILT_BUNDLE`은 control-plane에 받은 bundle의 경로이며 두 tag는 `bundle.json`의
`sourceRevision`과 같아야 합니다. 현재 사이트의 OCI registry/project는 그대로 선택할 수 있습니다.
import 명령이 압축 파일의 이미지 이름을 사이트에서 생성한 이름으로 연결합니다.
기존 동일 tag가 다른 내용을 가리키면 덮어쓰지 않고 멈춥니다.

기본 `IfNotPresent`는 노드에 이미지가 있으면 그것을 사용합니다. 매번 Registry에서 확인하는
`Always`를 사용하려면 같은 이미지를 실제 Registry에도 게시해야 합니다.
노드를 추가할 때도 동일 bundle을 import하거나 Registry에서 pull해야 합니다.

통합 설치기의 cluster 단계는 앱 빌드를 생략하고 bundle을 검사해 전체 노드에 넣습니다(import).
control-plane의 저장소 루트에서 별도로 실행할 수도 있습니다.

```bash
bash ./sadp --import-images --bundle <ABSOLUTE_BUNDLE_DIRECTORY>
sudo bash ./sadp --import-images --bundle <ABSOLUTE_BUNDLE_DIRECTORY> --apply
```

기본 명령은 checksum, 이미지 내부 파일(OCI blob), 참조, CPU 아키텍처를 검증하고 계획만 출력합니다.
`--apply`에서 계약의 전체 노드에 import하고 노드별 이미지 manifest digest를 대조합니다.
목표 노드에 맞는 이미지가 준비됐는지 확인하는 단계이며, 플랫폼 설정은 기존 설치 절차가 담당합니다.

범용 이미지는 기본 UI 표시값을 사용합니다. `NEXT_PUBLIC_*`는 빌드 때 고정되므로 사이트별
브랜드·표시 URL을 변경하려면 `--build-images`로 사이트 이미지를 다시 만듭니다.
실제 로그인 issuer/client/Secret은 실행 시점의 설정으로 공급합니다.

클러스터의 자원 제한이 있는 빌더 Pod에서 앱 배포 없이 압축 파일만 만들려면 다음 명령을 사용합니다.
이 경로는 현재 사이트의 공개 빌드값과 이미지 이름을 사용하므로 범용 배포물과 구분합니다.

```bash
sudo bash ./sadp --build-images --export-only
```

LXD VM 이미지 생성과 재사용은 별도 프로젝트 `SADP-SENDBOX/docs/prebuilt-images.md`를 따릅니다.
