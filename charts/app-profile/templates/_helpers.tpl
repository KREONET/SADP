{{- define "app-profile.fullname" -}}
{{- .Values.app.name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{/*
  AppGroup 전역 식별자의 공통 원문과 63자 typed name. '-'로만 필드를 이어 붙이면
  (group=a-b, app=c)와 (group=a, app=b-c)가 같아지므로 '/' 구분 canonical tuple을
  kind prefix와 함께 항상 해시한다. Go의 canonicalAppID/typedDNSName과 같아야 한다.
*/}}
{{- define "app-profile.canonicalAppID" -}}
{{- printf "v1/app/%s/%s/%s/%s" .Values.app.project .Values.app.environment .Values.app.group .Values.app.name -}}
{{- end -}}

{{- define "app-profile.typedName" -}}
{{- $suffix := trunc 10 (sha256sum (printf "%s|%s" .prefix .canonical)) -}}
{{- $room := sub 52 (len .prefix) | int -}}
{{- $slug := trimAll "-" (trunc $room .slug) -}}
{{- printf "%s%s-%s" .prefix $slug $suffix -}}
{{- end -}}

{{- define "app-profile.groupHostLabel" -}}
{{- include "app-profile.typedName" (dict "prefix" "ga-" "slug" (printf "%s-%s" .Values.app.name .Values.app.group) "canonical" (include "app-profile.canonicalAppID" .)) -}}
{{- end -}}

{{- define "app-profile.egressPolicyName" -}}
{{- if .Values.app.group -}}
{{- include "app-profile.typedName" (dict "prefix" "np-e-" "slug" .Values.app.name "canonical" (include "app-profile.canonicalAppID" .)) -}}
{{- else -}}
{{- printf "%s-egress" (include "app-profile.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "app-profile.ingressPolicyName" -}}
{{- if .Values.app.group -}}
{{- include "app-profile.typedName" (dict "prefix" "np-i-" "slug" .Values.app.name "canonical" (include "app-profile.canonicalAppID" .)) -}}
{{- else -}}
{{- printf "%s-ingress" (include "app-profile.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "app-profile.statusReaderName" -}}
{{- if .Values.app.group -}}
{{- include "app-profile.typedName" (dict "prefix" "rb-a-" "slug" .Values.app.name "canonical" (include "app-profile.canonicalAppID" .)) -}}
{{- else -}}
{{- printf "%s-status-reader" (include "app-profile.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "app-profile.labels" -}}
app.kubernetes.io/name: {{ .Values.app.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.example.io/project: {{ .Values.app.project }}
platform.example.io/environment: {{ .Values.app.environment }}
{{- if .Values.app.group }}
platform.example.io/group: {{ .Values.app.group }}
{{- end }}
{{- end -}}

{{- define "app-profile.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.app.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* digest 우선. 둘 다 없으면 렌더 단계에서 실패시킨다(latest 방지의 마지막 방어선) */}}
{{- define "app-profile.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else if .Values.image.tag -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- else -}}
{{ fail "image.tag 또는 image.digest 중 하나는 반드시 지정해야 한다" }}
{{- end -}}
{{- end -}}

{{/*
  노출(exposure)과 인증(authentication)은 서로 독립된 축이다.

  예전 values 는 exposure.type=public|oidc 하나에 둘을 묶어 두었다. 그래서 "외부에
  열되 로그인은 없다"와 "내부 전용" 을 구분할 수 없었다. 새 values 는
  exposure.mode=external|internal, authentication.mode=none|oidc 로 나눠 적는다.
  기존 values 를 그대로 두어도 동작해야 하므로, 새 값이 비어 있을 때만 type 에서 유도한다.
    public -> external + none
    oidc   -> external + oidc
*/}}
{{- define "app-profile.legacyExposureType" -}}
{{- $type := default "" .Values.exposure.type -}}
{{- if and $type (not (has $type (list "public" "oidc"))) -}}
{{ fail (printf "exposure.type=%s 는 public 또는 oidc 여야 한다. 새 values 는 exposure.mode/authentication.mode 를 쓴다" $type) }}
{{- end -}}
{{- $type -}}
{{- end -}}

{{- define "app-profile.exposureMode" -}}
{{- $mode := default "" .Values.exposure.mode -}}
{{- if $mode -}}
{{- if not (has $mode (list "external" "internal")) -}}
{{ fail (printf "exposure.mode=%s 는 external 또는 internal 이어야 한다" $mode) }}
{{- end -}}
{{- $mode -}}
{{- else -}}
{{- $_ := include "app-profile.legacyExposureType" . -}}
external
{{- end -}}
{{- end -}}

{{- define "app-profile.authMode" -}}
{{- $mode := default "" .Values.authentication.mode -}}
{{- if $mode -}}
{{- if not (has $mode (list "none" "oidc")) -}}
{{ fail (printf "authentication.mode=%s 는 none 또는 oidc 여야 한다" $mode) }}
{{- end -}}
{{- $mode -}}
{{- else if eq (include "app-profile.legacyExposureType" .) "oidc" -}}
oidc
{{- else -}}
none
{{- end -}}
{{- end -}}

{{/* HTTPRoute 를 실제로 만드는 조건. 유지보수 중지(exposure.enabled=false)가 우선한다. */}}
{{- define "app-profile.routeEnabled" -}}
{{- if and .Values.exposure.enabled (eq (include "app-profile.exposureMode" .) "external") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
  값 조합 검증. Helm 은 include 된 template 만 평가하므로 항상 렌더되는
  service.yaml 에서 한 번 부른다(여기서 실패해야 잘못된 조합이 클러스터에 닿지 않는다).
*/}}
{{- define "app-profile.validate" -}}
{{- $legacy := include "app-profile.legacyExposureType" . -}}
{{- $exposure := include "app-profile.exposureMode" . -}}
{{- $auth := include "app-profile.authMode" . -}}
{{- /*
  migration 중에는 legacy type과 새 축이 잠시 함께 있을 수 있지만, 의미가 같은 경우만
  받는다. 특히 type=oidc + authentication.mode=none을 새 값 우선으로 처리하면 기존
  SSO가 조용히 해제되므로 렌더 단계에서 반드시 멈춘다.
*/ -}}
{{- if and $legacy .Values.exposure.mode (ne .Values.exposure.mode "external") -}}
{{ fail (printf "exposure.type=%s 는 외부 노출을 뜻하므로 exposure.mode=%s 와 함께 사용할 수 없다. 새 구조만 사용하세요" $legacy .Values.exposure.mode) }}
{{- end -}}
{{- if and (eq $legacy "public") .Values.authentication.mode (ne .Values.authentication.mode "none") -}}
{{ fail "exposure.type=public 과 authentication.mode=oidc 가 충돌한다. 새 구조만 사용하세요" }}
{{- end -}}
{{- if and (eq $legacy "oidc") .Values.authentication.mode (ne .Values.authentication.mode "oidc") -}}
{{ fail "exposure.type=oidc 과 authentication.mode=none 이 충돌한다. 기존 SSO를 해제하려면 exposure.type을 제거하고 새 구조만 사용하세요" }}
{{- end -}}
{{- if and (eq $auth "oidc") (ne $exposure "external") -}}
{{ fail "authentication.mode=oidc 는 exposure.mode=external 에서만 사용할 수 있습니다. SecurityPolicy 가 HTTPRoute 를 대상으로 하기 때문입니다" }}
{{- end -}}
{{- if and (not .Values.service.enabled) (ne (int .Values.service.port) 0) -}}
{{ fail "service.enabled=false인 worker는 service.port=0이어야 한다" }}
{{- end -}}
{{- if and .Values.service.enabled (lt (int .Values.service.port) 1) -}}
{{ fail "service.enabled=true이면 service.port는 1~65535여야 한다" }}
{{- end -}}
{{- if and (not .Values.service.enabled) (ne $exposure "internal") -}}
{{ fail "포트 없는 worker(service.enabled=false)는 exposure.mode=internal만 사용할 수 있다" }}
{{- end -}}
{{- if and (not .Values.service.enabled) (eq $auth "oidc") -}}
{{ fail "포트 없는 worker에는 HTTPRoute 대상 OIDC 인증을 사용할 수 없다" }}
{{- end -}}
{{- if lt (int .Values.replicaCount) 0 -}}
{{ fail "replicaCount는 0 이상이어야 한다" }}
{{- end -}}
{{- /* 0/노출 중지는 한 쌍이다. 어긋나면 빈 Service로 트래픽이 가거나 실행 중인 앱의 Route만 조용히 사라진다. */ -}}
{{- if and (eq (int .Values.replicaCount) 0) .Values.exposure.enabled -}}
{{ fail "replicaCount=0인 중지 상태는 exposure.enabled=false여야 한다" }}
{{- end -}}
{{- if and (gt (int .Values.replicaCount) 0) (not .Values.exposure.enabled) -}}
{{ fail "exposure.enabled=false인 중지 상태는 replicaCount=0이어야 한다" }}
{{- end -}}
{{- if and (not .Values.service.enabled) .Values.networkPolicy.ingress.allowedApps -}}
{{ fail "포트 없는 worker는 ingress.allowedApps 수신 대상이 될 수 없다" }}
{{- end -}}
{{- if .Values.persistence.enabled -}}
{{- if and .Values.app.group (ne .Values.persistence.accessMode "ReadWriteOnce") -}}{{ fail "AppGroup persistence는 ReadWriteOnce만 사용할 수 있다" }}{{- end -}}
{{- /* 0은 포털의 GitOps 중지 상태다. PVC와 Service를 남긴 채 Pod만 내린다. */ -}}
{{- if and .Values.app.group (gt (int .Values.replicaCount) 1) -}}{{ fail "AppGroup persistence는 replicaCount=0(중지) 또는 1이어야 한다" }}{{- end -}}
{{- if and .Values.app.group (or (not .Values.persistence.size) (not .Values.persistence.storageClass)) -}}{{ fail "AppGroup persistence에는 플랫폼 계약의 size/storageClass가 필요하다" }}{{- end -}}
{{- if and .Values.app.group .Values.persistence.existingClaim -}}{{ fail "AppGroup persistence는 기존 PVC를 채택할 수 없다" }}{{- end -}}
{{- if and .Values.app.group .Values.persistence.keepOnDelete -}}{{ fail "AppGroup PVC는 해당 앱 Application 삭제 시 즉시 정리되므로 keepOnDelete=false여야 한다" }}{{- end -}}
{{- if and .Values.app.group (ne .Values.persistence.size .Values.platform.appGroups.storage.volumeSize) -}}
{{ fail "AppGroup persistence.size는 플랫폼 계약의 volumeSize와 같아야 한다" }}
{{- end -}}
{{- if and .Values.app.group (ne .Values.persistence.storageClass .Values.platform.appGroups.storage.storageClass) -}}
{{ fail "AppGroup persistence.storageClass는 플랫폼 계약값과 같아야 한다" }}
{{- end -}}
{{- $approvedMount := "/data" -}}
{{- if eq .Values.podSecurity.profile "postgres" -}}{{- $approvedMount = "/var/lib/postgresql/data" -}}{{- end -}}
{{- if and .Values.app.group (ne .Values.persistence.mountPath $approvedMount) -}}
{{ fail (printf "AppGroup podSecurity.profile=%s의 승인된 persistence.mountPath는 %s다" .Values.podSecurity.profile $approvedMount) }}
{{- end -}}
{{- if has .Values.persistence.mountPath (list "/" "/etc" "/var/run" "/var/run/secrets") -}}
{{ fail "persistence.mountPath는 승인된 애플리케이션 데이터 경로여야 한다" }}
{{- end -}}
{{- end -}}
{{- if and (eq $auth "oidc") (not .Values.oidc.allowedGroups) -}}
{{ fail "authentication.mode=oidc 인데 oidc.allowedGroups 가 비어 있다. 노출 중지 상태에서도 인증 경계는 완전한 설정이어야 한다" }}
{{- end -}}
{{- if and (eq $auth "oidc") (not .Values.platform.identityProvider.issuer) -}}
{{ fail "authentication.mode=oidc 인데 platform.identityProvider.issuer 계약값이 비어 있다" }}
{{- end -}}
{{- $oidcSecretCount := 0 -}}
{{- range .Values.configuration.externalSecrets -}}
{{- if eq .name "oidc-client" -}}
{{- $oidcSecretCount = add1 $oidcSecretCount -}}
{{- if or (not (hasKey . "inject")) (ne .inject false) -}}
{{ fail "OIDC ExternalSecret은 앱 Pod 환경에 주입하지 않도록 inject=false여야 한다" }}
{{- end -}}
{{- if or (ne (len .keys) 1) (not (has "OIDC_CLIENT_SECRET" .keys)) -}}
{{ fail "OIDC ExternalSecret keys는 OIDC_CLIENT_SECRET 하나여야 한다" }}
{{- end -}}
{{- if ne (get (default (dict) .targetKeyMap) "OIDC_CLIENT_SECRET") "client-secret" -}}
{{ fail "OIDC ExternalSecret targetKeyMap은 OIDC_CLIENT_SECRET을 client-secret으로 매핑해야 한다" }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and (eq $auth "oidc") (ne (int $oidcSecretCount) 1) -}}
{{ fail "authentication.mode=oidc 앱은 oidc-client ExternalSecret 계약을 정확히 하나 가져야 한다" }}
{{- end -}}
{{- if and (eq $auth "none") (gt (int $oidcSecretCount) 0) -}}
{{ fail "authentication.mode=none 앱은 OIDC client ExternalSecret을 만들 수 없다" }}
{{- end -}}
{{- if and (eq $auth "oidc") (ne .Values.oidc.callbackPath "/oauth2/callback") -}}
{{ fail "OIDC callbackPath는 플랫폼 OIDC 계약과 같은 /oauth2/callback이어야 한다" }}
{{- end -}}
{{- if eq $auth "oidc" -}}
{{- range .Values.oidc.allowedGroups -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._/-]*$" .) -}}
{{ fail (printf "oidc.allowedGroups 에 사용할 수 없는 그룹 이름이 있다: %s" .) }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and (eq $exposure "external") .Values.exposure.enabled (not .Values.exposure.host) -}}
{{ fail "exposure.mode=external 은 exposure.host 가 필요하다" }}
{{- end -}}
{{- if and .Values.app.group (eq $exposure "external") .Values.exposure.enabled -}}
{{- $expectedHost := printf "%s.%s" (include "app-profile.groupHostLabel" .) .Values.platform.baseDomain -}}
{{- if ne .Values.exposure.host $expectedHost -}}
{{ fail (printf "AppGroup 외부 host=%s 는 canonical identity host %s 와 같아야 한다" .Values.exposure.host $expectedHost) }}
{{- end -}}
{{- end -}}
{{- if and (eq $exposure "internal") .Values.exposure.host -}}
{{ fail (printf "exposure.mode=internal 인데 exposure.host=%s 가 남아 있다. 내부 전용 앱은 외부 도메인을 갖지 않는다" .Values.exposure.host) }}
{{- end -}}
{{- if and .Values.app.group (not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" .Values.app.group)) -}}
{{ fail (printf "app.group=%s 는 소문자 DNS 이름이어야 한다" .Values.app.group) }}
{{- end -}}
{{- if .Values.app.group -}}
{{- $prefix := default "" .Values.platform.appGroups.namespacePrefix -}}
{{- if not $prefix -}}
{{ fail "AppGroup 앱에는 platform.appGroups.namespacePrefix 계약값이 필요하다" }}
{{- end -}}
{{- $expectedNamespace := printf "%s%s" $prefix .Values.app.group -}}
{{- if ne .Release.Namespace $expectedNamespace -}}
{{ fail (printf "app.group=%s 앱의 릴리스 Namespace는 %s 이어야 한다(현재 %s)" .Values.app.group $expectedNamespace .Release.Namespace) }}
{{- end -}}
{{- end -}}
{{- if and .Values.app.group (not .Values.networkPolicy.enabled) -}}
{{ fail "AppGroup 앱은 Namespace default-deny를 필요한 규칙으로 다시 여는 networkPolicy.enabled=true가 필요하다" }}
{{- end -}}
{{- if and (not .Values.app.group) (eq $exposure "internal") (not .Values.networkPolicy.enabled) -}}
{{ fail "내부 전용 단일 앱은 networkPolicy.enabled=true가 필요하다. 그렇지 않으면 다른 Namespace에서 ClusterIP로 직접 접근할 수 있다" }}
{{- end -}}
{{- if and .Values.app.group (kindIs "bool" .Values.networkPolicy.ingress.enabled) (not .Values.networkPolicy.ingress.enabled) -}}
{{ fail "AppGroup 앱은 networkPolicy.ingress.enabled=false를 사용할 수 없다. default-deny-ingress에서 앱이 완전히 고립된다" }}
{{- end -}}
{{- if and (not .Values.app.group) (eq $exposure "internal") (kindIs "bool" .Values.networkPolicy.ingress.enabled) (not .Values.networkPolicy.ingress.enabled) -}}
{{ fail "내부 전용 단일 앱은 networkPolicy.ingress.enabled=false를 사용할 수 없다. 다른 Namespace의 Service 접근을 차단할 ingress 정책이 필요하다" }}
{{- end -}}
{{- if and (not .Values.app.group) (or .Values.networkPolicy.allowedApps .Values.networkPolicy.ingress.allowedApps) -}}
{{ fail "networkPolicy allowedApps는 같은 Namespace 경계가 보장되는 AppGroup 앱에서만 사용할 수 있다" }}
{{- end -}}
{{- if or .Values.portalPipeline.enabled .Values.openbaoWriter.enabled -}}
{{- if or .Values.app.group (ne .Values.app.name "portal-lite") (ne .Release.Name "portal-lite") (ne .Release.Namespace .Values.platform.portal.namespace) -}}
{{ fail "portalPipeline/openbaoWriter 권한은 플랫폼 portal-lite의 정확한 release/Namespace에서만 사용할 수 있다" }}
{{- end -}}
{{- end -}}
{{- if and .Values.app.group .Values.eso.createSecretStore .Values.configuration.externalSecrets (not .Values.platform.openbao.caConfigMapNamespace) -}}
{{ fail "AppGroup의 ClusterSecretStore에는 platform.openbao.caConfigMapNamespace 계약값이 필요하다" }}
{{- end -}}
{{- if and .Values.eso.createSecretStore .Values.configuration.externalSecrets -}}
{{- /* 각 ExternalSecret의 path와 실제 role 쌍은 assertRemotePath가 함께 검증한다. */ -}}
{{- if not (include "app-profile.esoRole" .) -}}{{ fail "ESO role이 비어 있다" }}{{- end -}}
{{- end -}}
{{- if and .Values.configuration.externalSecrets (not .Values.eso.createSecretStore) -}}
{{ fail "ExternalSecret을 사용하는 앱은 앱 경계의 OpenBao SecretStore를 만들도록 eso.createSecretStore=true여야 한다" }}
{{- end -}}
{{- $expectedSA := printf "eso-%s" .Values.app.name -}}
{{- if .Values.app.group -}}
{{- $expectedSA = include "app-profile.groupESOServiceAccount" . -}}
{{- end -}}
{{- if and .Values.eso.serviceAccountName (ne .Values.eso.serviceAccountName $expectedSA) -}}
{{ fail (printf "eso.serviceAccountName=%s 는 앱 identity 이름 %s 와 같아야 한다" .Values.eso.serviceAccountName $expectedSA) }}
{{- end -}}
{{- if not .Values.app.group -}}
{{- $expectedStore := printf "openbao-%s" .Values.app.name -}}
{{- range .Values.configuration.externalSecrets -}}
{{- if ne .secretStore $expectedStore -}}
{{ fail (printf "configuration.externalSecrets[%s].secretStore=%s 는 앱 identity store %s 와 같아야 한다" .name .secretStore $expectedStore) }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* 승인 도메인 밖 host 차단 */}}
{{- define "app-profile.host" -}}
{{- $suffix := printf ".%s" .Values.platform.baseDomain -}}
{{- $isPortal := and (eq .Values.app.name "portal-lite") (eq .Release.Name "portal-lite") (eq .Release.Namespace .Values.platform.portal.namespace) -}}
{{- $isApex := eq .Values.exposure.host .Values.platform.baseDomain -}}
{{- if not (or (hasSuffix $suffix .Values.exposure.host) (and $isPortal $isApex)) -}}
{{ fail (printf "exposure.host=%s 는 승인 도메인 %s 하위여야 한다(apex는 플랫폼 portal-lite만 허용)" .Values.exposure.host .Values.platform.baseDomain) }}
{{- end -}}
{{ .Values.exposure.host }}
{{- end -}}

{{/* wildcard listener와 apex listener는 hostname 교집합이 없으므로 Portal만 정확히 선택한다. */}}
{{- define "app-profile.listenerName" -}}
{{- $isApex := eq .Values.exposure.host .Values.platform.baseDomain -}}
{{- $expectedApex := printf "apex-%s" .Values.platform.gateway.sectionName -}}
{{- if $isApex -}}
  {{- if ne .Values.exposure.sectionName $expectedApex -}}
  {{ fail (printf "apex Portal은 exposure.sectionName=%s 이어야 한다" $expectedApex) }}
  {{- end -}}
  {{- $expectedApex -}}
{{- else -}}
  {{- if .Values.exposure.sectionName -}}
  {{ fail "exposure.sectionName override는 apex 플랫폼 Portal에서만 사용할 수 있다" }}
  {{- end -}}
  {{- .Values.platform.gateway.sectionName -}}
{{- end -}}
{{- end -}}

{{/*
  앱별 인터넷 egress 프로파일.

    blocked  DNS 와 명시적으로 허용한 내부 앱/Pod 만. 인터넷 없음.
    web      위 + 인터넷 TCP 80/443. 사설망과 클러스터 대역은 ipBlock.except 로 뺀다.
    custom   위 + allowedCIDRs 로 직접 적은 목적지(기존 동작).

  기본값이 custom 인 이유는 하위호환이다. 기존 values 는 egressMode 를 적지 않고
  allowedCIDRs/allowedPods 만 갖고 있다.
*/}}
{{- define "app-profile.egressMode" -}}
{{- $mode := default "custom" .Values.networkPolicy.egressMode -}}
{{- if not (has $mode (list "blocked" "web" "custom")) -}}
{{ fail (printf "networkPolicy.egressMode=%s 는 blocked, web, custom 중 하나여야 한다" $mode) }}
{{- end -}}
{{- if and (ne $mode "custom") .Values.networkPolicy.allowedCIDRs -}}
{{ fail (printf "networkPolicy.egressMode=%s 에서는 allowedCIDRs 를 쓸 수 없다. 목적지를 직접 지정하려면 custom 을 선택한다" $mode) }}
{{- end -}}
{{- range .Values.networkPolicy.allowedCIDRs -}}
{{- if has .cidr (list "0.0.0.0/0" "::/0") -}}
{{ fail (printf "networkPolicy.allowedCIDRs의 %s 는 사용할 수 없다. 인터넷 80/443은 web 모드를 사용한다" .cidr) }}
{{- end -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/*
  egressMode=web 이 여는 "인터넷". 0.0.0.0/0 에서 계약이 정한 내부 대역을 뺀다.
  목록이 비어 있으면 사설망까지 열리므로 렌더를 실패시킨다(조용히 여는 것보다 낫다).
*/}}
{{- define "app-profile.internetExcept" -}}
{{- $cidrs := list -}}
{{- range .Values.platform.network.internalCIDRs -}}
{{- /* IPv4 ipBlock의 except에는 같은 IP family만 올 수 있다. IPv6 egress는 이 web
      규칙이 열지 않으므로 IPv6 내부 대역을 별도로 except할 필요도 없다. */ -}}
{{- if not (contains ":" .) -}}
{{- $cidrs = append $cidrs . -}}
{{- end -}}
{{- end -}}
{{- if not $cidrs -}}
{{ fail "networkPolicy.egressMode=web 에는 IPv4 platform.network.internalCIDRs 계약값이 필요하다. 비어 있으면 사설망 TCP 80/443 까지 열린다" }}
{{- end -}}
{{- toYaml $cidrs -}}
{{- end -}}

{{/*
  같은 AppGroup(= 같은 Namespace) 안의 앱을 이름으로 가리킨다.
  사용자가 raw label 을 적지 않게 하려고 app 이름만 받아 표준 selector 로 바꾼다.
  namespaceSelector 를 붙이지 않으므로 다른 Namespace/AppGroup 은 선택되지 않는다.
*/}}
{{- define "app-profile.appPeerSelector" -}}
- podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ .app }}
{{- end -}}

{{/*
  Ingress NetworkPolicy 를 만들지 여부.
  AppGroup Namespace 는 default-deny-ingress 를 깔기 때문에 그룹에 속한 앱은 기본으로 켠다.
  외부 단일 앱(Zone 공유)은 기존 동작을 유지하려고 기본 off다. internal 단일 앱은
  다른 Namespace의 ClusterIP 직접 접근을 막기 위해 같은 Namespace ingress만 연다.
*/}}
{{- define "app-profile.ingressPolicyEnabled" -}}
{{- if kindIs "bool" .Values.networkPolicy.ingress.enabled -}}
{{- .Values.networkPolicy.ingress.enabled -}}
{{- else if or .Values.app.group (eq (include "app-profile.exposureMode" .) "internal") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
  기존 단일 앱은 exact path + 앱별 role을 사용했다. 신규 단일 앱은 workload identity
  path + 고정 templated role을 쓴다. 이미 배포된 values는 계속 읽되 두 계약을 섞으면
  거부한다. AppGroup은 신규 기능이라 canonical 계약만 허용한다.
*/}}
{{- define "app-profile.legacyESORole" -}}
{{- printf "eso-%s-%s-%s" .Values.app.project .Values.app.environment .Values.app.name -}}
{{- end -}}

{{- define "app-profile.canonicalRemotePath" -}}
{{- $namespace := required "OpenBao workload 경로에는 platform.portal.namespace 계약값이 필요하다" .Values.platform.portal.namespace -}}
{{- if .Values.app.group -}}{{- $namespace = .Release.Namespace -}}{{- end -}}
{{- printf "%s/%s/%s/workloads/%s/%s" .Values.platform.openbao.pathPrefix .Values.app.project .Values.app.environment $namespace (include "app-profile.esoServiceAccount" .) -}}
{{- end -}}

{{- define "app-profile.legacyRemotePath" -}}
{{- printf "%s/%s/%s/%s" .Values.platform.openbao.pathPrefix .Values.app.project .Values.app.environment .Values.app.name -}}
{{- end -}}

{{- define "app-profile.assertRemotePath" -}}
{{- $canonicalPath := include "app-profile.canonicalRemotePath" .ctx -}}
{{- $canonicalRole := .ctx.Values.platform.openbao.roles.zoneApp -}}
{{- if .ctx.Values.app.group -}}{{- $canonicalRole = .ctx.Values.platform.openbao.roles.groupApp -}}{{- end -}}
{{- $actualRole := include "app-profile.esoRole" .ctx -}}
{{- if and (eq .path $canonicalPath) (eq $actualRole $canonicalRole) -}}
{{- /* canonical path + fixed role */ -}}
{{- else if and (not .ctx.Values.app.group)
      (eq .path (include "app-profile.legacyRemotePath" .ctx))
      (eq $actualRole (include "app-profile.legacyESORole" .ctx)) -}}
{{- if or (ne .ctx.Release.Name .ctx.Values.app.name)
      (ne .ctx.Release.Namespace .ctx.Values.platform.portal.namespace) -}}
{{ fail (printf "legacy OpenBao path/role은 release=%s, Namespace=%s에서만 사용할 수 있다" .ctx.Values.app.name .ctx.Values.platform.portal.namespace) }}
{{- end -}}
{{- /* legacy exact path + exact per-app role */ -}}
{{- else -}}
{{ fail (printf "remotePath=%s 와 eso.role=%s 조합이 허용되지 않는다. canonical path+fixed role 또는 단일 앱 legacy exact path+exact role을 함께 사용해야 한다" .path $actualRole) }}
{{- end -}}
{{- end -}}

{{- define "app-profile.esoServiceAccount" -}}
{{- if .Values.eso.serviceAccountName -}}
{{- .Values.eso.serviceAccountName -}}
{{- else if .Values.app.group -}}
{{- include "app-profile.groupESOServiceAccount" . -}}
{{- else -}}
{{- printf "eso-%s" .Values.app.name -}}
{{- end -}}
{{- end -}}

{{- define "app-profile.groupESOServiceAccount" -}}
{{- include "app-profile.typedName" (dict "prefix" "eso-sa-a-" "slug" .Values.app.name "canonical" (include "app-profile.canonicalAppID" .)) -}}
{{- end -}}

{{- define "app-profile.esoRole" -}}
{{- if .Values.eso.role -}}
{{- .Values.eso.role -}}
{{- else if .Values.app.group -}}
{{- required "AppGroup ESO에는 platform.openbao.roles.groupApp 계약값이 필요하다" .Values.platform.openbao.roles.groupApp -}}
{{- else -}}
{{- /* 구버전 Portal values는 앱별 role을 생략하고 Chart 기본값에 맡겼다. */ -}}
{{- $legacyPath := include "app-profile.legacyRemotePath" . -}}
{{- $legacy := gt (len .Values.configuration.externalSecrets) 0 -}}
{{- range .Values.configuration.externalSecrets -}}
{{- if ne .remotePath $legacyPath -}}{{- $legacy = false -}}{{- end -}}
{{- end -}}
{{- if $legacy -}}
{{- include "app-profile.legacyESORole" . -}}
{{- else -}}
{{- required "단일 앱 ESO에는 platform.openbao.roles.zoneApp 계약값이 필요하다" .Values.platform.openbao.roles.zoneApp -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
  ClusterSecretStore는 클러스터 범위 이름이라 Namespace를 포함한다. 긴 이름은 단순히
  잘라 충돌시키지 않고 원문 해시를 붙인다. conditions에서 실제 사용 Namespace도 한 곳만
  허용하므로 다른 AppGroup의 ExternalSecret이 이 store를 참조할 수 없다.
*/}}
{{- define "app-profile.groupSecretStore" -}}
{{- include "app-profile.typedName" (dict "prefix" "css-a-" "slug" (printf "%s-%s" .Values.app.group .Values.app.name) "canonical" (include "app-profile.canonicalAppID" .)) -}}
{{- end -}}

{{- define "app-profile.oidcSecretName" -}}
{{- default (printf "%s-oidc-client" .Values.app.name) .Values.oidc.clientSecretName -}}
{{- end -}}

{{/* AppGroup마다 api 같은 이름을 재사용하므로 OIDC client도 group 경계가 필요하다. */}}
{{- define "app-profile.oidcClientID" -}}
{{- if and (not .Values.app.group) (eq .Values.app.name "secure-demo") .Values.platform.identityProvider.sharedClientID -}}
{{- .Values.platform.identityProvider.sharedClientID -}}
{{- else if .Values.app.group -}}
{{- include "app-profile.typedName" (dict "prefix" "oc-a-" "slug" (printf "%s-%s-%s" .Values.app.group .Values.app.name .Values.app.environment) "canonical" (include "app-profile.canonicalAppID" .)) -}}
{{- else -}}
{{- printf "%s-%s" .Values.app.name .Values.app.environment -}}
{{- end -}}
{{- end -}}

{{/*
  앱 Pod가 쓸 ServiceAccount. rbac.enabled=false면 Pod는 default SA를 쓰되
  automountServiceAccountToken: false 이므로 토큰 자체가 들어가지 않는다.
*/}}
{{- define "app-profile.serviceAccountName" -}}
{{- default (include "app-profile.fullname" .) .Values.rbac.serviceAccountName -}}
{{- end -}}

{{/* 상태 PVC 이름. existingClaim이 있으면 그것을 그대로 쓴다. */}}
{{- define "app-profile.pvcName" -}}
{{- default (printf "%s-data" (include "app-profile.fullname" .)) .Values.persistence.existingClaim -}}
{{- end -}}

{{/*
  RBAC를 부여할 Namespace 목록. 비어 있으면 릴리스 Namespace 하나만 쓴다.
  다른 Namespace를 적으면 그 Namespace 안에 Role/RoleBinding이 생기므로
  ClusterRole 없이도 교차 Namespace 읽기가 가능하다(권한은 Namespace 단위로 갇힌다).
*/}}
{{- define "app-profile.rbacNamespaces" -}}
{{- $list := .Values.rbac.namespaces -}}
{{- if not $list -}}
{{- $list = list .Release.Namespace -}}
{{- end -}}
{{- toYaml (uniq $list) -}}
{{- end -}}
