# 사전 빌드 앱 이미지

설치 대상에서 Portal을 매번 빌드하지 않고, 검토한 Git commit의 `test-app`과 `portal-lite`를
한 번 빌드해 여러 사이트에서 재사용한다. 현재 bundle은 `linux/amd64`다.

## 배포 담당자

Docker Engine이 실행 중인 빌드 호스트에서 소스를 검토·commit한 뒤 실행한다.
출력은 Git 밖의 **새 디렉터리**를 지정한다.

```bash
bash ./sadp --release-images --output <ABSOLUTE_BUNDLE_DIRECTORY>
bash ./sadp --release-images --output <ABSOLUTE_BUNDLE_DIRECTORY> --apply
```

`images.tar`와 `bundle.json`이 생성된다. 이미지 tag는 source commit SHA이고, manifest에
archive SHA-256·플랫폼·두 이미지 참조가 기록된다. CI에서도 같은 명령을 사용한다.
`--registry <REGISTRY_HOST>/<PROJECT>`는 이미지 이름만 선택하며 자동 push하지 않는다.
외부 Registry 게시가 필요하면 해당 자격 증명과 게시 대상을 준비해 별도로 push한다.

빌드는 `git archive`로 선택한 앱 소스만 전달한다. ignored `.env`, site.env, 인증서,
클러스터 상태와 런타임 Secret을 가져오지 않는다. Portal Dockerfile의 lint/typecheck/test/build와
Go vet/test를 통과해야 archive를 만든다. Auth.js는 실제 요청에서 OIDC 환경을 검사하므로
이미지 빌드에 OIDC 비밀번호가 필요하지 않다.

## 설치 담당자

신뢰하는 배포 경로에서 두 파일을 같은 디렉터리로 받는다. checksum은 손상 확인용이며
배포자의 신원을 증명하는 서명은 아니다. 무조건 신뢰할 수 없는 파일을 가져오지 않는다.

`environments/site.env`에 다음을 지정한 뒤 기존 configure-site → Git 게시 → 설치 순서를 따른다.

```dotenv
SADP_BUILD_IMAGES=false
SADP_PREBUILT_BUNDLE=<ABSOLUTE_BUNDLE_DIRECTORY_ON_CONTROL_PLANE>
TEST_APP_IMAGE_TAG=<BUNDLE_SOURCE_REVISION>
PORTAL_IMAGE_TAG=<BUNDLE_SOURCE_REVISION>
```

`SADP_PREBUILT_BUNDLE`은 설치 노드의 경로이며 두 tag는 `bundle.json`의 `sourceRevision`과 같다.
현재 사이트의 OCI registry/project는 그대로 선택할 수 있다. import 명령이 archive 이름을
사이트에서 렌더한 이름으로 연결한다. 기존 동일 tag가 다른 내용을 가리키면 덮어쓰지 않고 멈춘다.
이미지는 `IfNotPresent`로 사용하며, `Always`를 사용하려면 같은 이미지를 실제 Registry에도
게시해야 한다. 노드를 추가할 때도 동일 bundle을 import하거나 Registry에서 pull해야 한다.

통합 설치기의 cluster phase는 앱 빌드를 생략하고 bundle을 검사·import한다. 별도로 실행할 수도 있다.

```bash
bash ./sadp --import-images --bundle <ABSOLUTE_BUNDLE_DIRECTORY>
sudo bash ./sadp --import-images --bundle <ABSOLUTE_BUNDLE_DIRECTORY> --apply
```

기본 명령은 checksum·모든 OCI blob·참조·아키텍처를 검증하고 계획만 출력한다.
`--apply`에서 계약의 전체 노드에 import하고 노드별 manifest digest를 대조한다.
Kubernetes/RKE2와 플랫폼·OIDC·OpenBao 설정은 기존 설치 절차가 담당한다.

범용 이미지는 기본 UI 표시값을 사용한다. `NEXT_PUBLIC_*`는 빌드 시 고정되므로 사이트별
브랜드·표시 URL을 변경하려면 기존 `--build-images`로 사이트 이미지를 만든다.
실제 로그인 issuer/client/Secret은 계속 런타임 설정으로 들어간다.

클러스터의 제한된 빌더 Pod에서 배포하지 않고 archive만 만들려면 다음 명령을 사용한다.
이 경로는 현재 사이트의 공개 build 값과 이미지 이름을 사용하므로 범용 배포물과 구분한다.

```bash
sudo bash ./sadp --build-images --export-only
```

LXD VM 이미지 생성과 재사용은 형제 저장소 `SADP-SENDBOX/docs/prebuilt-images.md`를 따른다.
