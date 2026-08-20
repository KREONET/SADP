# SADP 백업·복원 안내

> 대상: 승인된 백업 검증과 RKE2/OpenBao/Keycloak 복원을 수행하는 관리자
> 백업 구현: `scripts/ops/backup-testbed.sh`
> 검증 구현: `scripts/verify/verify-backups.sh`

복원은 기존 상태를 덮어쓸 수 있는 별도 변경 작업입니다. 일반 장애 조사 중 바로 실행하지 않고
백업 시각, 영향 범위, 서비스 중지, 롤백 기준을 승인받습니다.

## 1. 실제 백업 산출물

백업은 `/var/lib/sadp/backups/<UTC_TIMESTAMP>/`에 생성되고 `latest` symlink가 마지막 run을
가리킵니다.

| 파일 | 내용 |
| --- | --- |
| `sadp-etcd-*.zip` | 압축된 RKE2 etcd snapshot |
| `rke2-server-token` | 해당 snapshot과 함께 필요한 server token |
| `openbao-raft.snap` | OpenBao Raft snapshot |
| `keycloak-postgresql.dump` | in-cluster Keycloak PostgreSQL custom dump |
| `cluster-inventory.txt` | 백업 시점 Node 목록 |
| `gateway-inventory.txt` | 백업 시점 Gateway/HTTPRoute 목록 |
| `SHA256SUMS` | 같은 디렉터리 파일 checksum |

`KEYCLOAK_DEPLOYMENT=external`이면 PostgreSQL dump를 만들지 않습니다. 외부 VM의 DB 백업과 복원
훈련은 외부 Keycloak 운영 책임입니다.

백업에는 cluster 복원 material과 인증 데이터가 포함됩니다. 디렉터리는 root-only로 유지하고
별도 호스트 또는 암호화된 객체 저장소에 2차 복제합니다. `openbao-init.json`은 snapshot에 포함되지
않으므로 승인된 별도 보안 매체에도 보관합니다.

## 2. 백업과 비파괴 검증

control-plane에서:

```bash
sudo bash ./sadp --backup
sudo bash ./sadp --verify-backups
```

특정 run 검증:

```bash
sudo bash scripts/verify/verify-backups.sh \
  /var/lib/sadp/backups/<UTC_TIMESTAMP>
```

검증은 다음을 수행합니다.

- `SHA256SUMS` 전체 확인
- etcd ZIP과 OpenBao gzip 형식 검사
- RKE2 server token 존재 확인
- in-cluster Keycloak이면 임시 DB에 dump를 실제 복원하고 realm 수를 확인한 뒤 삭제

검증 성공은 cluster 전체 복원 성공을 대신하지 않습니다. 정기적으로 격리 환경에서 전체 복원
훈련을 수행합니다.

## 3. 복원 전 공통 절차

1. 장애 시각, 선택 백업, 담당자, 변경 승인과 중단 기준을 기록합니다.
2. 대상 디렉터리에서 checksum과 `--verify-backups`를 통과시킵니다.
3. 손상 상황이 허용하면 현재 상태의 새 안전 백업을 만듭니다.
4. 사용자 쓰기와 배포 파이프라인을 중지합니다.
5. Argo CD 자동 sync가 복원 중 리소스를 되돌리지 않도록 승인된 방식으로 일시 중지합니다.
6. snapshot, server token, `openbao-init.json`, Keycloak dump의 site/시각이 일치하는지 확인합니다.
7. 복원 후 component별 검수와 `verify-testbed`를 실행합니다.

Secret 값과 token은 작업 기록, shell trace, 화면 공유에 남기지 않습니다.

## 4. RKE2 etcd 복원

현재 topology는 server 1대, worker 2대이므로 server 한 대에서 복원합니다. 선택한 snapshot과 같은
backup run의 `rke2-server-token`을 사용합니다.

```bash
sudo systemctl stop rke2-server
sudo rke2 server \
  --cluster-reset \
  --etcd-s3=false \
  --cluster-reset-restore-path=/var/lib/sadp/backups/<UTC_TIMESTAMP>/<ETCD_SNAPSHOT>.zip \
  --token-file=/var/lib/sadp/backups/<UTC_TIMESTAMP>/rke2-server-token
sudo systemctl start rke2-server
```

복원 대상의 RKE2 버전은 backup 생성 버전과 호환돼야 합니다. topology가 여러 server로 확장됐다면
이 단일 server 절차를 그대로 사용하지 말고 pinned RKE2 버전의 multi-server restore 절차에 따라
모든 server 중지, 첫 server reset, 나머지 재가입을 별도로 계획합니다.

확인:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get applications -n devtroncd
```

## 5. OpenBao Raft 복원

snapshot은 같은 seal key 체계로 복원합니다. 다른 seal key에 대한 `-force`는 일반 runbook 범위가
아니며 별도 재난복구 승인이 필요합니다.

```bash
kubectl -n openbao cp \
  /var/lib/sadp/backups/<UTC_TIMESTAMP>/openbao-raft.snap \
  openbao-0:/tmp/openbao-raft.snap

sudo jq -er '.root_token' /var/lib/sadp/openbao-init.json | \
  kubectl -n openbao exec -i openbao-0 -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    exec bao operator raft snapshot restore "$2"
  ' sh 'https://openbao.openbao.svc.cluster.local:8200' '/tmp/openbao-raft.snap'
```

root token을 command argv나 `kubectl exec -- env BAO_TOKEN=...`에 넣지 않습니다. 고정 shell이 stdin으로
받고 Pod 안에서만 export합니다. 복원 후 임시 snapshot을 제거하고 승인된 unseal threshold로
unseal합니다.

검수 순서:

1. OpenBao health와 Raft peer
2. audit device
3. KV v2 mount/path
4. Kubernetes auth와 OIDC auth
5. ESO SecretStore/ExternalSecret Ready
6. 앱 rollout과 Secret 비노출

## 6. in-cluster Keycloak PostgreSQL 복원

외부 Keycloak 사이트에서는 이 절을 실행하지 않습니다. in-cluster 배포에서 Keycloak 쓰기를
막고, 현재 DB를 별도 보존한 뒤 승인된 dump를 복원합니다.

```bash
kubectl -n keycloak scale deployment/keycloak --replicas=0
kubectl -n keycloak cp \
  /var/lib/sadp/backups/<UTC_TIMESTAMP>/keycloak-postgresql.dump \
  keycloak-postgresql-0:/tmp/keycloak.dump

kubectl -n keycloak exec keycloak-postgresql-0 -- sh -ceu '
  PGPASSWORD="$POSTGRES_PASSWORD" dropdb \
    --if-exists --username="$POSTGRES_USER" "$POSTGRES_DB"
  PGPASSWORD="$POSTGRES_PASSWORD" createdb \
    --username="$POSTGRES_USER" "$POSTGRES_DB"
  PGPASSWORD="$POSTGRES_PASSWORD" pg_restore \
    --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" \
    --no-owner --single-transaction --exit-on-error /tmp/keycloak.dump
'

kubectl -n keycloak scale deployment/keycloak --replicas=1
kubectl -n keycloak rollout status deployment/keycloak --timeout=15m
kubectl -n keycloak exec keycloak-postgresql-0 -- rm -f /tmp/keycloak.dump
```

DB drop 직전에는 현재 DB의 별도 dump가 실제로 생성됐는지 다시 확인합니다. 복원 후 계약 realm,
Portal/앱 client, group/role mapper, broker alias, break-glass admin, login callback을 검증합니다.

## 7. 전체 복원 후 검수

```bash
kubectl get nodes -o wide
kubectl get applications -n devtroncd
kubectl get gateway,httproute -A
kubectl get certificate -A
kubectl get externalsecret,secretstore,clustersecretstore -A

sudo bash ./sadp --verify-portal-auth
sudo bash ./sadp --verify-testbed
```

사용자 트래픽과 Argo 자동 sync는 다음이 모두 확인된 뒤 재개합니다.

- 세 Node Ready와 핵심 Application 수렴
- Gateway/TLS와 public/OIDC/internal 접근 경계
- OpenBao/ESO Secret 동기화
- Keycloak login과 role mapping
- Portal 신청 조회와 새 테스트 신청
- 백업 이후 Git commit과 cluster 상태 차이 검토

복원 중 만든 임시 dump/snapshot/token 복사본을 제거하고, 복원 결과와 다음 백업 시각을 기록합니다.
