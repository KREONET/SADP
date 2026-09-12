# SADP 보안 보장과 한계

> 대상: 앱 승인자, 플랫폼 관리자, 보안 검토자

SADP는 앱이 선의로 동작한다고 가정하지 않습니다. 동시에 NetworkPolicy와 컨테이너 제한만으로
침해된 앱을 안전한 블랙박스로 만들었다고 주장하지도 않습니다. 이 문서는 배포 전에 검증할 수
있는 플랫폼 보장과 앱이 직접 책임져야 하는 데이터 인가를 구분합니다.

## 플랫폼이 보장하는 범위

| 경계 | 검증 가능한 약속 | 검증 위치 |
| --- | --- | --- |
| 외부 연결 | 앱 Pod가 새로 만드는 연결을 DNS와 선언한 `blocked/web/custom` 규칙으로 제한 | AppProfile NetworkPolicy, `render-test.sh`, `verify-testbed.sh` |
| 수신 연결 | 외부 경로를 Envoy Gateway로 모으고, OIDC 앱은 지정 그룹만 통과 | HTTPRoute/SecurityPolicy, Gateway Accepted 검사 |
| 앱 데이터 접근 | 앱별 OpenBao 경로·ESO identity·Secret을 고정하고 기본 ServiceAccount token 자동 마운트를 끔 | Chart 렌더 가드, OpenBao 사전검사 |
| 실행 격리 | non-root, read-only root filesystem, capability 전체 제거, RuntimeDefault seccomp 적용 | AppProfile Deployment |
| 브라우저 응답 | 일반 외부 앱에 동일 origin 중심 CSP와 CORP·Permissions·Referrer·nosniff·frame 방지 헤더를 강제 | HTTPRoute ResponseHeaderModifier |
| 사고 격리 | child Argo reconcile 중지, 외부 HTTPRoute 제거, Deployment 0을 한 명령으로 적용 | `--quarantine-app` |
| 복구 | immutable image와 GitOps 기록으로 재배포하고 플랫폼 etcd/OpenBao는 검증 백업에서 복원 | 배포 pipeline, 복구 Runbook |

`egressMode=web`은 FQDN 정책이 아니라 내부 대역을 제외한 TCP 80/443 허용입니다. `custom`도
CIDR·port 연결 정책입니다. Kubernetes NetworkPolicy는 허용된 연결의 응답 트래픽을 암묵적으로
허용하고 정책들이 합집합으로 적용됩니다. 따라서 “egress가 닫혔으니 앱 응답으로는 유출할 수
없다”는 결론은 성립하지 않습니다. 기준 의미는
[Kubernetes NetworkPolicy 공식 문서](https://kubernetes.io/docs/concepts/services-networking/network-policies/)를
따릅니다.

## 플랫폼이 보장하지 않는 범위

- 앱이 읽을 수 있는 데이터를 정상 HTTP 응답, 오류 본문, 파일 다운로드 또는 redirect에 담는
  행위는 NetworkPolicy가 막지 않습니다.
- OIDC `allowedGroups`는 앱 진입 권한입니다. 레코드·파일·프로젝트·사용자별 데이터 인가를
  대신하지 않습니다. 앱은 모든 읽기와 변경 요청에서 서버 측 객체 권한을 다시 확인해야 합니다.
- 브라우저 보안 헤더는 외부 script·fetch·form·subresource와 framing을 줄입니다. 서버가 응답
  자체에 데이터를 싣는 행위, top-level 이동, 사용자의 복사·다운로드, 브라우저·확장 프로그램·
  단말 침해를 막는 DLP는 아닙니다.
- 앱이 자기 PVC·주입된 Secret·허용된 내부 서비스에서 읽은 값을 오용하거나, 자기 권한으로
  데이터를 변조·삭제하는 행위는 컨테이너 sandbox가 막지 않습니다.
- AppGroup은 Namespace를 공유합니다. Pod 간 연결은 앱별 NetworkPolicy로 제한하지만 Namespace를
  별도 클러스터나 강한 적대적 멀티테넌시 경계로 취급하지 않습니다.
- 기본 백업은 RKE2 etcd와 OpenBao Raft입니다. 앱 PVC 내용의 백업·시점 복구는 앱 소유자가 별도
  정책을 준비해야 하며, 준비되지 않은 앱 데이터의 복구 가능성을 보장하지 않습니다.
- NetworkPolicy는 이미 허용된 연결을 정책 변경 때 즉시 끊는다고 보장하지 않습니다. 구현별
  동작 차이를 피하려고 격리 명령은 Route 삭제와 Pod 종료를 함께 수행합니다.

## 앱 승인 기준

보안 승인은 이미지 취약점 검사만으로 끝나지 않습니다. 최소한 다음을 확인합니다.

1. 모든 조회·변경 API가 로그인 여부만 보지 않고 요청자와 대상 객체의 관계를 서버에서 검사한다.
2. 목록·검색·내보내기·파일 URL·WebSocket·캐시 key에도 같은 사용자 범위를 적용한다.
3. 앱에는 실제로 필요한 Secret key와 내부 서비스만 허용하고, `web` egress는 필요가 입증된 경우만 쓴다.
4. 데이터 삭제·대량 내보내기·권한 변경은 감사 식별자와 복구 절차를 갖는다.
5. PVC 데이터의 RPO/RTO가 필요하면 앱 백업과 격리 복원 시험을 별도로 운영한다.

SADP의 보안 검사는 애플리케이션 비즈니스 로직의 사용자별 인가를 증명하지 않습니다. 승인자는
위 항목의 앱 시험 또는 코드 검토 증거가 없으면 민감 데이터 접근 앱을 승인하지 않습니다.

## 침해 의심 앱 격리와 복구

먼저 대상의 정확한 Application을 읽기 전용으로 확인합니다.

```bash
sudo bash ./sadp --quarantine-app \
  --app <APP_NAME> --namespace <APP_NAMESPACE>
```

계획의 app/namespace/Application이 모두 맞으면 적용합니다.

```bash
sudo bash ./sadp --quarantine-app \
  --app <APP_NAME> --namespace <APP_NAMESPACE> --apply
```

이 명령은 child Application에 `skip-reconcile`, HTTPRoute 삭제, Deployment replicas 0을 적용하고
Pod가 모두 종료됐는지 확인합니다. Service, PVC, Secret, Portal 신청 기록은 증거와 복구를 위해
삭제하지 않습니다. 상위 GitOps가 Route를 다시 만들면 실패로 종료하므로 상위 Application도
즉시 조사합니다.

격리 뒤에는 다음 순서를 지킵니다.

1. Application 원본 증거 파일과 플랫폼·앱 로그를 보존하고, 노출된 것으로 볼 Secret을 회전합니다.
2. 데이터 변조 범위를 확인하고 앱 PVC 백업이 있으면 별도 Namespace에서 복원 검증합니다.
3. 알려진 정상 소스와 고정 image tag/digest로 GitOps desired state를 고칩니다. 먼저
   `replicaCount: 0`, `exposure.enabled: false` 상태를 반영합니다.
4. child Application의 `argocd.argoproj.io/skip-reconcile`을 제거하고 중지 상태의 정확한 revision이
   Synced인지 확인합니다.
5. 보안 검토가 끝난 별도 재개 변경으로 replica와 Route를 복구하고 OIDC·인가·CSP·데이터 무결성을
   확인합니다. 격리 전 이미지를 그대로 켜는 복구는 하지 않습니다.

격리 명령 자체는 원인을 제거하거나 앱 데이터를 복원하지 않습니다. 알려진 정상 이미지,
회전된 자격증명, 필요한 앱 데이터 백업이 모두 준비됐을 때만 복구 가능성을 약속할 수 있습니다.
