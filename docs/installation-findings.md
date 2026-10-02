# 단일 서버 설치에서 확인한 문제와 반영 범위

이 문서는 단일 서버 시험에서 발견한 문제와 수정 범위를 정리한 **점검 기록**입니다.
설치 절차는 [설치 가이드](installation.md), 현재 장애의 조치 순서는 [복구 안내](recovery.md)를 따르세요.
아래 표는 어떤 증상을 코드에서 보완했는지 설명하며, 모든 운영 환경의 정상 동작을 보장하는 결과는 아닙니다.
image-loader는 노드에 이미지를 넣는 임시 작업이고, CRD는 Kubernetes가 추가 리소스 종류를 알도록
등록하는 정의입니다. 자세한 공통 용어는 [기본 개념](concepts.md)을 참고하세요.

| 문제 | 반영 |
| --- | --- |
| 단일 서버에서도 image-loader 3개를 기다림 | 계약의 topology에서 기대 노드 수 계산 |
| Auth.js가 빌드 중 런타임 Secret을 요구함 | 요청 시점 lazy 설정, Secret 누락 시 실제 로그인은 거부 |
| Helm이 NO_PROXY의 쉼표를 별도 값으로 해석함 | Helm 문자열 escaping 수정 |
| 구형 Devtron 번들 Argo CD가 다중 source/valuesObject를 제거함 | 고정 Argo CD 이미지와 같은 버전 CRD를 설치, 번들 CRD 설치 비활성 |
| Envoy Gateway CRD와 실제 ID token 전달 기능 차이 | 실검증한 Gateway/API 버전 조합 고정 |
| 제공한 TLS 사용 시 DNS-01 빈 배열을 읽고 중단 | provided 분기를 먼저 처리 |
| 머신 인증 client가 없으면 후속 항목 위치가 틀어짐 | 빈 목록의 불필요한 줄 제거 |
| OpenBao 진단 명령이 실행 전 positional argument 오류 | 진단 heredoc의 변수 확장 지연 |
| Portal의 Argo project가 고정값임 | site의 플랫폼 Namespace 값에서 생성 |
| 모니터링을 꺼도 bootstrap에서 다시 생성 | bootstrap directory에서 관련 Application 제외 |
| 외부 서비스 Namespace가 Argo 허용 목록에 없음 | 명시한 외부 서비스 Namespace만 목적지 추가 |
| 검수가 prod 환경·직접 properties를 가정 | catalog 환경/project 및 OpenAPI allOf 반영 |
| npm 전체 버전 이력을 받아 proxy 시험이 시간 초과 | 고정 Next 버전 metadata로 시험 |

정상 실행 중인 기존 Devtron을 새 버전으로 자동 전환하지 않는다. 새 설치 또는 동일 버전 failed
복구에 고정 Argo 설정을 적용한다. 기존 설정과 다른 경우 유지보수로 Helm image tag와 CRD
소유권/버전을 함께 검토한다. API 충돌을 `--force-conflicts`로 덮어쓰지 않는다.

LXD의 systemd 준비 지연, 비특권 컨테이너의 mknod 및 Calico nft 대량 규칙 제약은
SADP-SENDBOX에서 관리한다. 일반 SADP의 이중 NIC 분리와 guard 요구사항을 완화하지 않는다.
사설 CA/공유 NIC 예외는 샌드박스의 명시적 LXC overlay에서만 사용한다.

Argo가 승인 revision을 확인하기 전에 더 최신 commit으로 이동하면 Portal 배포 요청은
시간 초과 상태로 남을 수 있다. 이번 설치에서는 해당 시험 앱의 승인 revision을 실제로
동기화한 뒤 Portal 조회로 복구하고 main 추적을 복원했다. 상태 파일을 직접 수정하지 않는다.
이 변경에서 배포 revision 판정 자체의 의미를 바꾸지는 않았다.

사전 빌드 이미지의 생산·사용 절차는 [사전 빌드 앱 이미지](prebuilt-images.md)를 따른다.
