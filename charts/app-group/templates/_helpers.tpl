{{- define "app-group.name" -}}
{{- $name := .Values.group.name | trim -}}
{{- if not $name -}}
{{ fail "group.name 이 비어 있다" }}
{{- end -}}
{{- if not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{ fail (printf "group.name=%s 는 소문자 DNS 이름이어야 한다" $name) }}
{{- end -}}
{{- if gt (len $name) 40 -}}
{{ fail (printf "group.name=%s 은 40자를 넘을 수 없다" $name) }}
{{- end -}}
{{- $name -}}
{{- end -}}

{{/* Go의 canonicalGroupID/typedDNSName과 같은 AppGroup 전역 식별자 규칙이다. */}}
{{- define "app-group.canonicalGroupID" -}}
{{- printf "v1/group/%s/%s/%s" .Values.group.project .Values.group.environment (include "app-group.name" .) -}}
{{- end -}}

{{- define "app-group.typedName" -}}
{{- $suffix := trunc 10 (sha256sum (printf "%s|%s" .prefix .canonical)) -}}
{{- $room := sub 52 (len .prefix) | int -}}
{{- $slug := trimAll "-" (trunc $room .slug) -}}
{{- printf "%s%s-%s" .prefix $slug $suffix -}}
{{- end -}}

{{/*
  AppGroup Namespace 이름. Release.Namespace 와 반드시 같아야 한다.
  다르면 Argo 가 이 Chart 를 엉뚱한 Namespace 에 넣고, 같은 이름의 Namespace 를
  두 AppGroup 이 나눠 갖는 상태가 된다.
*/}}
{{- define "app-group.namespace" -}}
{{- $prefix := default .Values.platform.appGroups.namespacePrefix .Values.group.namespacePrefix -}}
{{- default (printf "%s%s" $prefix (include "app-group.name" .)) .Values.group.namespace -}}
{{- end -}}

{{- define "app-group.labels" -}}
app.kubernetes.io/name: {{ include "app-group.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.example.io/group: {{ include "app-group.name" . }}
platform.example.io/app-group: "true"
platform.example.io/project: {{ .Values.group.project }}
platform.example.io/environment: {{ .Values.group.environment }}
{{- end -}}

{{- define "app-group.validate" -}}
{{- $contractPrefix := default "" .Values.platform.appGroups.namespacePrefix -}}
{{- if not $contractPrefix -}}
{{ fail "platform.appGroups.namespacePrefix 계약값이 비어 있다" }}
{{- end -}}
{{- if and .Values.group.namespacePrefix (ne .Values.group.namespacePrefix $contractPrefix) -}}
{{ fail (printf "group.namespacePrefix=%s 는 플랫폼 계약값 %s 와 같아야 한다" .Values.group.namespacePrefix $contractPrefix) }}
{{- end -}}
{{- $expectedNamespace := printf "%s%s" $contractPrefix (include "app-group.name" .) -}}
{{- if and .Values.group.namespace (ne .Values.group.namespace $expectedNamespace) -}}
{{ fail (printf "group.namespace=%s 는 플랫폼 계약 Namespace %s 와 같아야 한다" .Values.group.namespace $expectedNamespace) }}
{{- end -}}
{{- $namespace := include "app-group.namespace" . -}}
{{- if ne $namespace .Release.Namespace -}}
{{ fail (printf "이 Chart 는 Namespace %s 를 만들지만 릴리스 Namespace 는 %s 다. Argo Application 의 destination.namespace 를 맞춰라" $namespace .Release.Namespace) }}
{{- end -}}
{{- if not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" (default "" .Values.group.project)) -}}
{{ fail "group.project 는 소문자 DNS 이름이어야 한다" }}
{{- end -}}
{{- if not (has .Values.group.environment (list "dev" "beta" "prod")) -}}
{{ fail (printf "group.environment=%s 는 dev, beta, prod 중 하나여야 한다" .Values.group.environment) }}
{{- end -}}
{{- if not .Values.platform.gateway.routeSelectorLabels -}}
{{ fail "platform.gateway.routeSelectorLabels 계약값이 비어 있다. 이 label 이 없으면 Namespace 안의 HTTPRoute 가 Gateway 에 붙지 못한다" }}
{{- end -}}
{{- if not .Values.platform.rancher.workloadProjectId -}}
{{ fail "platform.rancher.workloadProjectId 계약값이 비어 있다. AppGroup Namespace는 기존 Rancher 프로젝트 권한 경계에 반드시 포함되어야 한다" }}
{{- end -}}
{{- if or (not .Values.defaultDeny.ingress) (not .Values.defaultDeny.egress) -}}
{{ fail "AppGroup Namespace의 defaultDeny.ingress와 defaultDeny.egress는 모두 true여야 한다" }}
{{- end -}}
{{- if not .Values.quota.enabled -}}
{{ fail "AppGroup Namespace는 quota.enabled=false를 사용할 수 없다" }}
{{- end -}}
{{- if not .Values.limitRange.enabled -}}
{{ fail "AppGroup Namespace는 limitRange.enabled=false를 사용할 수 없다" }}
{{- end -}}
{{- if and (gt (int .Values.quota.pods) 0) (ne (int .Values.quota.pods) (int .Values.platform.quota.maxReplicas)) -}}
{{ fail "quota.pods는 API의 AppGroup 전체 Pod 상한인 platform.quota.maxReplicas와 같아야 한다" }}
{{- end -}}
{{- if and .Values.quota.cpu (ne .Values.quota.cpu .Values.platform.quota.cpu) -}}
{{ fail "quota.cpu는 Portal API와 같은 platform.quota.cpu 계약값이어야 한다" }}
{{- end -}}
{{- if and .Values.quota.memory (ne .Values.quota.memory .Values.platform.quota.memory) -}}
{{ fail "quota.memory는 Portal API와 같은 platform.quota.memory 계약값이어야 한다" }}
{{- end -}}
{{- $pullName := default "" .Values.platform.registry.pullSecretName -}}
{{- $pullPath := default "" .Values.platform.registry.pullSecretRemotePath -}}
{{- if ne (not (empty $pullName)) (not (empty $pullPath)) -}}
{{ fail "platform.registry.pullSecretName과 pullSecretRemotePath는 함께 설정하거나 함께 비워야 한다" }}
{{- end -}}
{{- if and $pullPath (not .Values.platform.openbao.caConfigMapNamespace) -}}
{{ fail "registry pull ClusterSecretStore에는 platform.openbao.caConfigMapNamespace 계약값이 필요하다" }}
{{- end -}}
{{- if and $pullPath (not .Values.platform.openbao.roles.groupRegistry) -}}
{{ fail "registry pull ClusterSecretStore에는 platform.openbao.roles.groupRegistry 계약값이 필요하다" }}
{{- end -}}
{{- if and $pullPath .Values.registryPullSecret.role (ne .Values.registryPullSecret.role .Values.platform.openbao.roles.groupRegistry) -}}
{{ fail (printf "registryPullSecret.role=%s 는 플랫폼 고정 role %s 와 같아야 한다" .Values.registryPullSecret.role .Values.platform.openbao.roles.groupRegistry) }}
{{- end -}}
{{- if and .Values.registryPullSecret.serviceAccountName (ne .Values.registryPullSecret.serviceAccountName (include "app-group.defaultPullSecretServiceAccount" .)) -}}
{{ fail (printf "registryPullSecret.serviceAccountName=%s 는 canonical identity 이름 %s 와 같아야 한다" .Values.registryPullSecret.serviceAccountName (include "app-group.defaultPullSecretServiceAccount" .)) }}
{{- end -}}
{{- end -}}

{{- define "app-group.quotaCPU" -}}
{{- default .Values.platform.quota.cpu .Values.quota.cpu -}}
{{- end -}}

{{- define "app-group.quotaMemory" -}}
{{- default .Values.platform.quota.memory .Values.quota.memory -}}
{{- end -}}

{{- define "app-group.quotaPods" -}}
{{- if gt (int .Values.quota.pods) 0 -}}
{{- .Values.quota.pods -}}
{{- else -}}
{{- .Values.platform.quota.maxReplicas -}}
{{- end -}}
{{- end -}}

{{- define "app-group.pullSecretName" -}}
{{- .Values.platform.registry.pullSecretName -}}
{{- end -}}

{{- define "app-group.pullSecretStore" -}}
{{- include "app-group.typedName" (dict "prefix" "css-g-" "slug" (include "app-group.name" .) "canonical" (include "app-group.canonicalGroupID" .)) -}}
{{- end -}}

{{- define "app-group.pullSecretServiceAccount" -}}
{{- default (include "app-group.defaultPullSecretServiceAccount" .) .Values.registryPullSecret.serviceAccountName -}}
{{- end -}}

{{- define "app-group.defaultPullSecretServiceAccount" -}}
eso-registry
{{- end -}}

{{- define "app-group.pullSecretRole" -}}
{{- default (required "AppGroup registry ESO에는 platform.openbao.roles.groupRegistry 계약값이 필요하다" .Values.platform.openbao.roles.groupRegistry) .Values.registryPullSecret.role -}}
{{- end -}}
