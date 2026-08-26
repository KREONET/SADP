# SADP 네트워크·egress·NMS 운영 안내

> 대상: 다중 NIC, Squid, CoreDNS, cert-manager, NMS 경로를 운영하는 관리자
> 입력 기준: `site.env` → 계약 → `render-network.py`

SADP는 RKE2 Canal(Flannel VXLAN + Calico NetworkPolicy)을 사용합니다. Worker의 일반 인터넷
직접 egress는 열지 않고 승인된 HTTP(S)는 Squid, NMS는 별도 고정 경로 또는 승인 API로 보냅니다.

## 1. 통신 경계

```text
일반 앱 Pod
  ├─ DNS와 선언한 내부 앱 연결
  └─ blocked/web/custom AppProfile egress 정책

cert-manager controller
  ├─ Kubernetes API/CoreDNS 직접
  ├─ Squid → ACME HTTPS
  └─ RFC2136 authoritative DNS IPv4:port 직접

NMS 허용 Pod
  ├─ network mode → 내부 NIC → NMS gateway → 고정 SNAT → 전용 NIC
  └─ api mode     → 기존 route → 승인된 destination CIDR/port
```

Squid와 NMS 경로는 섞지 않습니다. 기본 Kubernetes NetworkPolicy는 FQDN allowlist를 제공하지
않으므로 앱의 `web` mode는 내부 대역을 제외한 TCP 80/443 포트 정책입니다.

## 2. 설정과 생성

사이트별 값은 `/etc/sadp/site.env`에서 고칩니다. 생성된 `platform/network/*`,
`platform/dns/*`, `rke/*`는 직접 편집하지 않습니다.

필수 확인:

- 기존 RKE2 Pod/Service CIDR과 cluster DNS
- 세 노드의 내부 IPv4와 공통 internal/external NIC 이름
- Kubernetes API 주소와 RKE2 server endpoint
- Squid 내부 IPv4/port와 node/Pod client CIDR
- CoreDNS upstream 내부 `<IPv4>:<port>`
- Gateway VIP/pool, public IP, NAT/direct mode
- RFC2136 update endpoint와 DNS-01 recursive resolver
- 선택한 NMS mode의 목적지 CIDR/port와 mode 전용 값

```bash
ip -br link
ip -br -4 address
ip -4 route

python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --check
python3 scripts/site/configure-site.py \
  --env-file /etc/sadp/site.env --write
bash ./sadp --test
```

생성 diff를 commit/push하고 각 노드에서 통합 installer의 node phase를 사용합니다.

## 3. 다중 NIC와 RKE2 identity

`INTERNAL_INTERFACE` 이름은 RKE2 node IP, server bind/advertise address와 Canal
`flannel.iface`에 사용됩니다. `EXTERNAL_INTERFACE`, NMS NIC, guarded NIC에는 Kubernetes
관리 port 차단이 적용됩니다.

이름이 실제 식별자이며 MAC으로 대체할 수 없습니다. MAC은 노드마다 다르므로 site.env에 넣지
않고, 개별 스크립트를 진단할 때 `--internal-mac`, `--external-mac`, `--nms-mac`으로 이름과 실제
NIC의 일치만 단언합니다. 노드별 이름이 다르면 `systemd.link`로 먼저 통일합니다.

통합 적용:

```bash
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env --phase node
sudo bash ./sadp --install \
  --env-file /etc/sadp/site.env --phase node --apply
```

node phase가 자동 역할 판별 후 수행하는 일:

- 해당 노드가 담당하면 Squid를 가장 먼저 설치·검증
- 계약 소유 RKE2 config field 병합
- 내부 NIC/IP identity와 Canal interface 고정
- external/NMS/guarded NIC 관리 port guard 설치
- embedded containerd proxy 설정
- control-plane이면 monitoring pull용 Docker daemon proxy 설정
- 해당 노드가 담당하면 DNS forwarder, NMS unit 설치

`SQUID_INTERNAL_IP`를 가진 노드의 node phase를 먼저 적용하고 `--install-squid --check`와
`--verify-squid`를 통과시킨 뒤 다른 노드와 cluster phase로 진행합니다. cluster phase는
Devtron/Helm chart 작업 전에 Squid를 다시 확인하고 Prometheus/Loki/Alloy 이미지를 이 경로로
모든 노드에 선배포합니다.

Docker daemon은 셸의 `HTTP_PROXY`만으로 바뀌지 않습니다. control-plane node phase 적용 후
`systemctl restart docker`를 사람이 실행하고 다음 검사를 통과시킵니다.

```bash
sudo bash ./sadp --install-docker-proxy --check
```

설치기는 RKE2를 자동 재시작하지 않습니다. worker를 한 대씩 drain → `rke2-agent` restart →
Ready → uncordon하고 마지막에 승인된 창에서 server를 재시작합니다.

### 개별 identity 진단

```bash
sudo bash ./sadp --install-network-identity \
  --role server \
  --internal-ip <CONTROL_PLANE_INTERNAL_IPV4> \
  --internal-interface <INTERNAL_NIC> \
  --external-interface <EXTERNAL_NIC>

sudo bash ./sadp --install-network-identity \
  --role server \
  --internal-ip <CONTROL_PLANE_INTERNAL_IPV4> \
  --internal-interface <INTERNAL_NIC> \
  --external-interface <EXTERNAL_NIC> \
  --apply
```

agent에는 `--server-url https://<RKE2_SERVER_INTERNAL_IPV4>:9345`를 추가합니다. 개별 스크립트도
재시작하지 않습니다.

## 4. interface guard

external/NMS/guarded NIC에서 API 6443, supervisor 9345, etcd 2379/2380, kubelet 10250 등 계약의
관리 TCP port를 IPv4/IPv6 모두 차단합니다. internal NIC은 guard 대상이 될 수 없습니다.

```bash
sudo bash ./sadp --install-interface-guard \
  --external-interface <EXTERNAL_NIC> \
  --blocked-tcp-ports 2379,2380,6443,9345,10250

sudo bash ./sadp --install-interface-guard \
  --external-interface <EXTERNAL_NIC> \
  --blocked-tcp-ports 2379,2380,3128,6443,9345,10250 \
  --apply
```

guard unit은 fail-open입니다. unit 실패가 RKE2 시작을 막지 않으므로 다음을 모니터링하고 외부
방화벽에서도 관리 port를 차단합니다.

```bash
systemctl status sadp-rke2-interface-guard.service
sudo iptables -S SADP_RKE2_GUARD
sudo ip6tables -S SADP_RKE2_GUARD
```

SSH/DB와 애플리케이션 port는 이 guard가 대신 통제하지 않습니다.

## 5. Squid

`spec.network.squid.internalIP`를 가진 노드에만 통합 node apply가 설치합니다. 직접 설치기는
`--apply` 2단계가 아니라 기본 실행이 설치이고 `--check`가 현재 상태 검사입니다.

```bash
sudo -E bash ./sadp --install-squid
sudo bash ./sadp --install-squid --check
bash ./sadp --verify-squid
```

최초 package 설치에는 승인된 upstream proxy나 내부 apt mirror가 필요합니다. Worker direct
인터넷을 임시로 열지 않습니다.

생성된 Squid는 승인된 ACME/chart/package/IdP domain만 허용하고 `ssl_bump`와 cache는 사용하지
않습니다. 장애 진단은 요청이 실제 Squid에 도착했는지부터 확인합니다.

```bash
grep ' <CLIENT_IPV4> ' /var/log/squid/access.log | tail
curl --fail --proxy 'http://<SQUID_INTERNAL_IPV4>:<SQUID_PORT>' \
  'https://<APPROVED_HOST>/'
```

로그가 없으면 ACL보다 client proxy 설정/DNS/route 문제입니다. `TCP_DENIED`가 있을 때만
site.env의 allowlist 입력과 생성 결과를 확인합니다.

## 6. RKE2 embedded containerd proxy

각 노드의 `/etc/default/rke2-server` 또는 `rke2-agent`에 `CONTAINERD_HTTP_PROXY`,
`CONTAINERD_HTTPS_PROXY`, `CONTAINERD_NO_PROXY` 관리 블록을 설치합니다. RKE2 API/노드 통신
전체에 shell proxy를 강제하지 않습니다.

```bash
sudo bash ./sadp --install-containerd-proxy --role server
sudo bash ./sadp --install-containerd-proxy --role server --apply
```

지원하는 적용 옵션에 `--restart`는 없습니다. 적용 뒤 관리자가 drain/유지보수 경계를 지켜
서비스를 재시작합니다. private 앱 image에는 별도 pull Secret이 필요하며 kaniko push credential과
재사용하지 않습니다.

## 7. CoreDNS upstream

Worker가 node `/etc/resolv.conf`의 resolver에 닿지 못하면 CoreDNS가 외부 이름을 `SERVFAIL`로
반환합니다. 이때 `CLUSTER_UPSTREAM_DNS=<INTERNAL_IPV4>:53`을 설정하고 그 주소의 노드에 내부 DNS
forwarder를 설치합니다.

```bash
# 기본 실행은 설치, --check는 설치된 상태 검사
sudo bash scripts/node/install-dns-forwarder.sh
sudo bash scripts/node/install-dns-forwarder.sh --check

kubectl rollout status -n kube-system deployment/rke2-coredns-rke2-coredns
```

통합 platform 설치가 생성된 CoreDNS ConfigMap을 적용하고 rollout을 기다립니다. 이 값은 DNS-01
self-check용 `DNS_RECURSIVE_NAMESERVERS`와 다릅니다. upstream은 일반 외부 이름, recursive
nameserver는 public `_acme-challenge` 권위 응답을 보기 위한 경로입니다.

## 8. cert-manager egress

`render-network.py`가 cert-manager Application과 NetworkPolicy를 함께 생성합니다.

- proxy env는 controller에만 적용하고 webhook/cainjector에는 적용하지 않습니다.
- controller는 Squid 3128을 통해 ACME HTTPS에 접근합니다.
- RFC2136 DNS UPDATE는 계약 nameserver의 TCP/UDP port로 직접 갑니다.
- CoreDNS와 Kubernetes API는 `NO_PROXY`/직접 경로입니다.
- recursive self-check는 `--dns01-recursive-nameservers-only`를 사용합니다.

Squid와 DNS 경로를 먼저 준비하지 않으면 ACME Challenge가 실패합니다. 발급과 staging/production
전환은 [DNS-01 안내](letsencrypt-dns01.md)에서 진행합니다.

## 9. NMS mode

`NMS_MODE`는 `disabled`, `network`, `api` 중 하나입니다.

### disabled

NMS allowed app, NIC, gateway, destination, URL 값을 비웁니다. 아직 역할이 없지만 public 주소를
받을 수 있는 NMS 예정 NIC은 `GUARDED_INTERFACES`에 두고 실제 활성화 시 `NMS_INTERFACE`로
옮깁니다.

### network

고정 destination CIDR/TCP port, NMS gateway node의 내부 IP, NMS NIC, 고정 SNAT IP, next-hop을
모두 입력합니다. gateway unit은 policy route, loose rp_filter, 지정 port FORWARD와 고정 SNAT를
적용하고 worker unit은 destination route와 Canal SNAT 예외를 적용합니다.

통합 node apply가 해당 node IP에 따라 역할을 고릅니다. 개별 진단:

```bash
sudo bash ./sadp --install-nms-egress gateway
sudo bash ./sadp --install-nms-egress worker

systemctl status sadp-nms-egress@gateway.service
systemctl status sadp-nms-egress@worker.service
```

기본 실행이 unit 설치입니다. RKE2/CNI upgrade로 iptables chain이 재생성되면 unit을 재시작해
검증합니다. 단일 gateway는 장애 지점이며 HA는 이 installer 범위 밖입니다.

### api

전용 NIC/gateway/SNAT 값을 비우고 API base URL, destination CIDR, port를 입력합니다. 이 mode는
NMS host unit을 설치하지 않고 AppProfile NetworkPolicy와 Portal 서버 전용 API 설정만 만듭니다.
token이 필요하면 값은 OpenBao에 두고 site.env에는 Secret key 이름만 둡니다. 브라우저로 upstream
URL이나 token을 반환하지 않습니다.

### 앱 정책

허용 앱에만 `nms-access: true` label과 목적지 CIDR/port NetworkPolicy가 생깁니다. 허용 Pod의
성공뿐 아니라 미허용 Pod의 실패도 함께 검증합니다.

```bash
kubectl exec -n <NAMESPACE> <ALLOWED_POD> -- \
  sh -c 'nc -z -w 5 <NMS_IPV4> <NMS_PORT>'
kubectl exec -n <NAMESPACE> <DENIED_POD> -- \
  sh -c '! nc -z -w 5 <NMS_IPV4> <NMS_PORT>'
```

## 10. 최종 검수

control-plane에서:

```bash
sudo bash ./sadp --verify-testbed
```

이 검수의 host interface/systemd 검사는 실행한 control-plane 한 대만 봅니다. 각 worker에서는
별도로 다음을 확인합니다.

```bash
ip -br -4 address
ip -4 route
systemctl status rke2-agent
systemctl status sadp-rke2-interface-guard.service
```

최종 기대 경계:

| 경로 | 허용 | 차단 |
| --- | --- | --- |
| internal NIC | RKE2/etcd/API/kubelet/Canal, Squid | 승인되지 않은 경로 |
| external NIC | Envoy TCP 80/443 | Kubernetes 관리 port, DB, 임의 ingress |
| NMS NIC | 승인 destination/port와 반환 | 관리 port, 신규 inbound |
| 앱 Pod | 선언한 DNS/internal/web/custom/NMS | 나머지 egress |

NetworkPolicy는 Pod 정책일 뿐 node 자체의 direct 인터넷 차단을 대신하지 않습니다. 경계와 host
방화벽에서 함께 검증합니다.
