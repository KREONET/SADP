# SADP 사용자 가이드

이 문서는 Portal에서 앱을 신청하고 상태를 확인하는 사람을 위한 안내입니다. 사용자는 kubeconfig,
RKE2 token, OpenBao root token, Forgejo bot token이 필요하지 않습니다.

## 1. 시작 전에 받을 것

- Portal 주소 `https://<PORTAL_HOST>`
- 조직 SSO 계정
- 조회 권한 `deployments:read`
- 신청·중지·재개·삭제가 필요하면 쓰기 권한 `deployments:write`

브라우저에 인증서 경고가 나타나면 무시하고 로그인하지 말고 관리자에게 알립니다.

## 2. 로그인

1. Portal 주소를 엽니다.
2. 조직 SSO 로그인을 선택합니다.
3. 조직 SSO 화면이 나오면 조직 계정으로 로그인합니다.
4. 다시 Portal로 돌아오는지 확인합니다.

로그인이 반복돼도 새 계정을 만들지 않습니다. 사용자 ID, 발생 시각, 화면의 오류 문구만 관리자에게
전달하고 password, token, cookie는 보내지 않습니다.

## 3. 화면 지도

| 메뉴 | 하는 일 |
| --- | --- |
| 홈 | 내 워크로드, 최근 신청, 쿼터 확인 |
| 서비스 | 사용할 수 있는 공개·SSO·관리 서비스 확인 |
| 내 앱 | 신청 상태, PR 링크, 오류, 실행 상태 확인 |
| 배포 | `.env` 값을 일반 설정과 Secret으로 분류 |
| 새 앱 | 단일 앱 또는 AppGroup 신청 |

## 4. 단일 앱 신청

새 앱 화면의 다섯 단계를 순서대로 진행합니다.

1. 앱 이름과 프로젝트를 정합니다.
2. credential이 없는 HTTPS Git URL, branch, Dockerfile 경로를 입력합니다.
3. 컨테이너 port, replica, 자원 preset을 선택합니다.
4. 외부 공개 여부, SSO, 외부 통신 정책을 선택합니다.
5. 예상 URL과 자원을 검토하고 신청합니다.

신청이 끝나면 신청 ID를 기록하고 **내 앱**에서 진행 상태를 확인합니다. 같은 앱을 반복 신청하지
않습니다.

## 5. 환경변수 분류

| 분류 | 넣는 값 | 저장 위치 |
| --- | --- | --- |
| ConfigMap | 공개돼도 되는 일반 설정 | GitOps values |
| OpenBao | password, token, API key 등 민감값 | OpenBao → ESO → Kubernetes Secret |

민감한지 애매하면 OpenBao를 선택합니다. OpenBao 값은 제출 전 브라우저 메모리에만 있으므로
새로고침했다면 다시 입력해야 합니다. Git에는 값이 아니라 key 이름만 남습니다.

## 6. 여러 앱 함께 배포(AppGroup)

1. **새 앱**에서 Compose 배포 링크를 엽니다.
2. 플랫폼 전체에서 유일한 그룹 이름을 정합니다.
3. Git URL 또는 Compose 원문을 입력합니다.
4. **앱 구성 확인**을 실행합니다.
5. 서비스별 공개, SSO, 통신, Secret key를 설정합니다.
6. 설정을 바꿨다면 다시 **앱 구성 확인**을 실행합니다.
7. 검증 결과가 맞으면 **배포 신청**을 누릅니다.

AppGroup은 고정 tag나 digest의 기존 이미지만 사용합니다. Compose `build:`는 지원하지 않습니다.
같은 그룹 안의 앱도 송신·수신 양쪽에서 연결을 허용해야 통신할 수 있습니다.

## 7. 내 앱과 상태

| 상태 | 의미 |
| --- | --- |
| `PENDING` | PR, build, 배포 또는 상태 변경 진행 중 |
| `RUNNING` | 배포 완료, 목표 replica Ready |
| `STOPPED` | replica 0, 외부 Route 제거 완료 |
| `FAILED` | build, 배포 또는 실행 상태 변경 실패 |

`FAILED`이면 상세 화면의 신청 ID, 단계, 메시지, PR 링크를 먼저 확인합니다.

## 8. 중지·재개·삭제

- 중지: replica를 0으로 만들고 외부 Route를 제거합니다. Secret과 PVC는 유지합니다.
- 재개: 원래 replica와 외부 Route를 복원합니다.
- 삭제: 앱 values와 Argo Application을 제거합니다. named volume의 PVC 데이터도 삭제됩니다.

데이터가 필요하면 삭제 전에 관리자에게 백업을 요청합니다.

## 9. 자주 묻는 문제

| 증상 | 먼저 할 일 |
| --- | --- |
| Portal에 접속되지 않음 | 정확한 HTTPS 주소와 발생 시각 확인 |
| 로그인 반복 | 새 계정을 만들지 말고 사용자 ID와 오류 전달 |
| 신청 거부 | 빨간 입력 필드와 서버 메시지 확인 |
| 오래 `PENDING` | 상세 단계와 PR 링크 확인 |
| `RUNNING`인데 접속 실패 | 앱 URL, container port, 발생 시각 전달 |
| Secret 저장 실패 | 값은 보내지 말고 앱 이름과 key 이름만 전달 |

## 10. 문제를 전달할 때

관리자에게 앱 이름, 신청 ID, 발생 시각, 오류 문구, Git commit을 전달합니다. password, API token,
private key, session cookie, 전체 `.env`, kubeconfig, OpenBao root token은 보내지 않습니다.

저장소와 Dockerfile을 준비해야 하면 [개발자 가이드](developer-guide.md)를 읽으십시오.
