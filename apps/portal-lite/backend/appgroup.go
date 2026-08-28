package main

// AppGroup(Stack) — 서로 연관된 앱 여러 개를 Namespace 하나로 묶는다.
//
// 단일 앱 배포는 예전 그대로 사이트 공용 Zone(research-prod)에 들어간다.
// AppGroup 은 전용 Namespace(app-<group>)를 만들고, 그 안에서만 앱끼리
// Kubernetes Service DNS 로 통신한다. Namespace 는 default-deny 로 시작하므로
// 같은 그룹이라는 이유만으로 서로 열리지 않는다.
//
// 흐름은 단일 앱과 같다.
//
//	포털 -> Forgejo PR -> (자동 승인) -> Argo CD -> Namespace + 앱
//
// 포털이 클러스터에 직접 쓰지 않는다. Namespace 도 Argo 가 Chart 를 보고 만든다.

import (
	"crypto/sha256"
	"fmt"
	"strings"
)

const (
	maxGroupNameLength = 40
	// platform-bootstrap의 app-of-apps 동기화에서 Namespace baseline을 먼저
	// 완성해야 한다. 앱 Application은 wave 0이므로 더 낮은 wave에 둔다.
	groupBootstrapSyncWave = "-10"
	groupedAppSyncWave     = "0"
)

// appGroup은 AppGroup 하나의 식별 정보다. 앱 프로필과 달리 소스/이미지가 없다.
type appGroup struct {
	Name        string `json:"name"`
	Namespace   string `json:"namespace"`
	Project     string `json:"project"`
	Environment string `json:"environment"`
}

func newAppGroup(name, project, environment string) appGroup {
	return appGroup{
		Name:        name,
		Namespace:   groupNamespace(name),
		Project:     project,
		Environment: environment,
	}
}

// groupOf는 요청에 실린 AppGroup을 돌려준다. 두 번째 값이 false면 단일 앱 배포다.
func groupOf(profile normalizedProfile) (appGroup, bool) {
	if profile.App.Group == "" {
		return appGroup{}, false
	}
	return newAppGroup(profile.App.Group, profile.App.Project, profile.App.Environment), true
}

/* --------------------------- GitOps 파일 경로 --------------------------- */

// groupValuesPath는 AppGroup Namespace bootstrap values의 저장소 경로다.
// 앱 values(apps/<app>/values-<env>.yaml)와 섞이지 않게 _groups 아래에 둔다.
func groupValuesPath(group appGroup) string {
	return fmt.Sprintf("apps/_groups/%s/values-%s.yaml", group.Name, group.Environment)
}

func groupApplicationPath(group appGroup) string {
	return fmt.Sprintf("argocd/applications/%s.yaml", groupApplicationName(group))
}

func groupApplicationName(group appGroup) string {
	return typedDNSName("ag-", group.Name+"-"+group.Environment, canonicalGroupID(group))
}

// appValuesPath와 appApplicationPath는 앱이 어느 배포 경계에 속하는지에 따라
// GitOps 경로를 한 곳에서 결정한다. AppGroup 앱을 전역 apps/<app> 경로에 두면 서로
// 다른 그룹이 같은 service 이름(api, redis 등)을 정상적으로 재사용할 수 없다.
func appValuesPath(profile normalizedProfile) string {
	if profile.App.Group != "" {
		return fmt.Sprintf("apps/_groups/%s/apps/%s/values-%s.yaml",
			profile.App.Group, profile.App.Name, profile.App.Environment)
	}
	return fmt.Sprintf("apps/%s/values-%s.yaml", profile.App.Name, profile.App.Environment)
}

func appApplicationPath(profile normalizedProfile) string {
	if profile.App.Group != "" {
		return fmt.Sprintf("argocd/applications/%s.yaml", appApplicationName(profile))
	}
	return fmt.Sprintf("argocd/applications/%s.yaml", profile.App.Name)
}

func appApplicationName(profile normalizedProfile) string {
	if profile.App.Group != "" {
		return typedDNSName("aa-", fmt.Sprintf("%s-%s-%s",
			profile.App.Group, profile.App.Name, profile.App.Environment), canonicalAppID(profile))
	}
	return stableDNSName(fmt.Sprintf("%s-%s", profile.App.Name, profile.App.Environment))
}

// canonicalAppID와 canonicalGroupID는 전역 리소스 이름의 해시 원문이다. 각 구성요소는
// API에서 '/'를 쓸 수 없는 DNS 이름으로 검증되므로 구분자가 모호해지지 않는다. 사람이
// 읽는 이름을 '-'로 이어 붙이는 것만으로는 (g=a-b, app=c)와 (g=a, app=b-c)가 같아진다.
func canonicalAppID(profile normalizedProfile) string {
	return fmt.Sprintf("v1/app/%s/%s/%s/%s", profile.App.Project, profile.App.Environment,
		profile.App.Group, profile.App.Name)
}

func canonicalGroupID(group appGroup) string {
	return fmt.Sprintf("v1/group/%s/%s/%s", group.Project, group.Environment, group.Name)
}

func externalHostLabel(profile normalizedProfile) string {
	if profile.App.Group == "" {
		return profile.App.Name
	}
	return typedDNSName("ga-", profile.App.Name+"-"+profile.App.Group, canonicalAppID(profile))
}

func keycloakClientID(profile normalizedProfile) string {
	if profile.App.Group == "" {
		return profile.App.Name + "-" + profile.App.Environment
	}
	return typedDNSName("kc-a-", profile.App.Group+"-"+profile.App.Name+"-"+profile.App.Environment,
		canonicalAppID(profile))
}

func oidcAllowedGroup(profile normalizedProfile) string {
	if profile.App.Group == "" {
		return profile.App.Name + "-user"
	}
	return typedDNSName("kg-a-", profile.App.Group+"-"+profile.App.Name+"-user", canonicalAppID(profile))
}

// typedDNSName은 종류(prefix)와 canonical identity를 함께 해시해 63자 DNS label을 만든다.
// 짧은 이름에도 항상 해시를 붙여, 단순 연결이 만든 짧은 충돌도 제거한다. Helm의
// app-profile.typedName/app-group.typedName과 seed 및 절단 규칙이 정확히 같아야 한다.
func typedDNSName(prefix, slug, canonical string) string {
	sum := sha256.Sum256([]byte(prefix + "|" + canonical))
	suffix := fmt.Sprintf("-%x", sum[:5])
	room := 63 - len(prefix) - len(suffix)
	if room < 1 {
		panic("typed DNS name prefix is too long")
	}
	if len(slug) > room {
		slug = slug[:room]
	}
	slug = strings.TrimRight(slug, "-")
	return prefix + slug + suffix
}

// stableDNSName은 Argo Application의 Kubernetes 이름을 63자 안에 고정한다. 단순
// trunc는 서로 다른 긴 이름을 같은 이름으로 만들 수 있어, 잘린 경우 원문 해시를 붙인다.
func stableDNSName(value string) string {
	if len(value) <= 63 {
		return value
	}
	sum := sha256.Sum256([]byte(value))
	return fmt.Sprintf("%s-%x", strings.TrimSuffix(value[:52], "-"), sum[:5])
}

// writeArgoTerminatingIgnoreDifferences는 Kubernetes 1.33의 새 status 필드를 알지 못하는
// 현재 Argo CD(v2.13)가 Deployment/ReplicaSet을 ComparisonError로 만들지 않게 한다.
// 정적 child Application과 포털이 나중에 만드는 Application이 같은 예외를 가져야 한다.
func writeArgoTerminatingIgnoreDifferences(builder *strings.Builder) {
	builder.WriteString("  ignoreDifferences:\n")
	for _, kind := range []string{"Deployment", "ReplicaSet"} {
		builder.WriteString("    - group: \"apps\"\n")
		fmt.Fprintf(builder, "      kind: %s\n", yamlString(kind))
		builder.WriteString("      jqPathExpressions:\n")
		builder.WriteString("        - \".status.terminatingReplicas\"\n")
	}
}

/* ------------------------------ 렌더 ------------------------------ */

// renderGroupValuesYAML은 charts/app-group이 읽는 values를 만든다.
// 쿼터·기본 차단·Rancher project·Gateway label 은 Chart 와 계약이 정하므로 여기서
// 다시 적지 않는다. 여기 적는 것은 "어느 그룹인가" 뿐이다.
func renderGroupValuesYAML(group appGroup, requestID, createdAt string) string {
	var builder strings.Builder
	builder.WriteString("# 이 파일은 SADP 포털이 생성했습니다. 직접 수정하지 마세요.\n")
	fmt.Fprintf(&builder, "# 요청 ID: %s\n", requestID)
	fmt.Fprintf(&builder, "# 생성 시각: %s\n", createdAt)
	builder.WriteString("---\n")
	builder.WriteString("group:\n")
	fmt.Fprintf(&builder, "  name: %s\n", yamlString(group.Name))
	fmt.Fprintf(&builder, "  project: %s\n", yamlString(group.Project))
	fmt.Fprintf(&builder, "  environment: %s\n", yamlString(group.Environment))
	fmt.Fprintf(&builder, "  namespacePrefix: %s\n", yamlString(groupNamespacePrefix))
	// Namespace 안의 앱끼리도 명시적으로 허용한 연결만 통한다.
	builder.WriteString("defaultDeny:\n")
	builder.WriteString("  ingress: true\n")
	builder.WriteString("  egress: true\n")
	return builder.String()
}

// renderGroupArgoApplicationYAML은 Namespace를 만드는 child Application이다.
// 앱 Application과 project가 다르다 — platform-prod는 ResourceQuota를 막고 있어서
// Namespace bootstrap을 그 프로젝트로는 넣을 수 없다.
func renderGroupArgoApplicationYAML(group appGroup, repoURL, revision string) string {
	var builder strings.Builder
	builder.WriteString("# 이 파일은 SADP 포털이 생성했습니다. 직접 수정하지 마세요.\n")
	builder.WriteString("apiVersion: argoproj.io/v1alpha1\n")
	builder.WriteString("kind: Application\n")
	builder.WriteString("metadata:\n")
	fmt.Fprintf(&builder, "  name: %s\n", yamlString(groupApplicationName(group)))
	fmt.Fprintf(&builder, "  namespace: %s\n", yamlString(argoNamespace))
	builder.WriteString("  annotations:\n")
	fmt.Fprintf(&builder, "    argocd.argoproj.io/sync-wave: %s\n", yamlString(groupBootstrapSyncWave))
	builder.WriteString("  finalizers:\n")
	builder.WriteString("    - \"resources-finalizer.argocd.argoproj.io\"\n")
	builder.WriteString("spec:\n")
	fmt.Fprintf(&builder, "  project: %s\n", yamlString(groupArgoProject))
	builder.WriteString("  sources:\n")
	fmt.Fprintf(&builder, "    - repoURL: %s\n", yamlString(repoURL))
	fmt.Fprintf(&builder, "      targetRevision: %s\n", yamlString(revision))
	builder.WriteString("      path: \"charts/app-group\"\n")
	builder.WriteString("      helm:\n")
	fmt.Fprintf(&builder, "        releaseName: %s\n", yamlString(group.Name))
	builder.WriteString("        valueFiles:\n")
	builder.WriteString("          - \"$values/contracts/values-platform-production.yaml\"\n")
	fmt.Fprintf(&builder, "          - %s\n", yamlString("$values/"+groupValuesPath(group)))
	fmt.Fprintf(&builder, "    - repoURL: %s\n", yamlString(repoURL))
	fmt.Fprintf(&builder, "      targetRevision: %s\n", yamlString(revision))
	builder.WriteString("      ref: \"values\"\n")
	builder.WriteString("  destination:\n")
	builder.WriteString("    server: \"https://kubernetes.default.svc\"\n")
	fmt.Fprintf(&builder, "    namespace: %s\n", yamlString(group.Namespace))
	builder.WriteString("  syncPolicy:\n")
	builder.WriteString("    automated:\n")
	// prune=false 라 Git 에서 파일이 사라져도 Namespace 는 남는다. 삭제는 포털이
	// Application 을 finalizer 와 함께 지워 cascade 로 처리한다.
	builder.WriteString("      prune: false\n")
	builder.WriteString("      selfHeal: true\n")
	builder.WriteString("    syncOptions:\n")
	// Namespace 를 이 Chart 가 직접 만든다. Argo 가 먼저 만들면 label/annotation 없이 생긴다.
	builder.WriteString("      - \"CreateNamespace=false\"\n")
	builder.WriteString("      - \"SkipDryRunOnMissingResource=true\"\n")
	builder.WriteString("    retry:\n")
	builder.WriteString("      limit: 10\n")
	builder.WriteString("      backoff:\n")
	builder.WriteString("        duration: \"10s\"\n")
	builder.WriteString("        factor: 2\n")
	builder.WriteString("        maxDuration: \"3m\"\n")
	writeArgoTerminatingIgnoreDifferences(&builder)
	return builder.String()
}
