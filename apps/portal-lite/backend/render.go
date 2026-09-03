package main

// GitOps 저장소에 커밋할 values 파일과 PR 본문을 만든다.
// 외부 YAML 라이브러리 없이 문자열로 조립하므로, 모든 스칼라는 반드시
// yamlString을 통해 따옴표로 감싸 주입을 막는다.

import (
	"fmt"
	"path"
	"sort"
	"strings"
)

// yamlString은 값을 큰따옴표 문자열로 안전하게 만든다. 역슬래시·따옴표를 escape 하고
// 개행과 제어문자는 \n, \uXXXX 형태로 바꿔 한 줄을 절대 벗어나지 않게 한다.
func yamlString(value string) string {
	var builder strings.Builder
	builder.Grow(len(value) + 2)
	builder.WriteByte('"')
	for _, r := range value {
		switch r {
		case '\\':
			builder.WriteString(`\\`)
		case '"':
			builder.WriteString(`\"`)
		case '\n':
			builder.WriteString(`\n`)
		case '\r':
			builder.WriteString(`\r`)
		case '\t':
			builder.WriteString(`\t`)
		default:
			if r < 0x20 || r == 0x7f {
				builder.WriteString(fmt.Sprintf(`\u%04x`, r))
				continue
			}
			builder.WriteRune(r)
		}
	}
	builder.WriteByte('"')
	return builder.String()
}

// sortedKeys는 map 순회 순서를 고정해 같은 입력이 항상 같은 YAML을 만들게 한다.
func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// splitPrebuiltImage는 "registry/name:tag" 또는 "registry/name@sha256:..." 을
// repository 와 참조로 나눈다. 값이 없으면 세 번째 반환값이 false다.
func splitPrebuiltImage(image string) (string, string, bool) {
	if image == "" {
		return "", "", false
	}
	if repository, digest, found := strings.Cut(image, "@"); found {
		return repository, digest, true
	}
	// 포트가 붙은 레지스트리(registry:5000/name)와 태그 구분자를 헷갈리지 않게
	// 마지막 슬래시 뒤에서만 콜론을 찾는다.
	slash := strings.LastIndex(image, "/")
	colon := strings.LastIndex(image, ":")
	if colon > slash {
		return image[:colon], image[colon+1:], true
	}
	return image, "", false
}

// prebuiltImageUsesPullSecret는 Docker Hub 공개 image에만 공용 pull Secret을 빼 준다.
// 다른 registry는 private일 수 있으므로 명시적으로 public이라는 입력이 생기기 전까지
// Secret을 유지한다. 잘못된 플랫폼 Secret이 nginx 같은 공개 image까지 막아서는 안 된다.
func prebuiltImageUsesPullSecret(repository string) bool {
	registryHost := func(value string) string {
		value = strings.TrimPrefix(strings.TrimPrefix(strings.ToLower(value), "https://"), "http://")
		first, _, found := strings.Cut(value, "/")
		if !found || (!strings.Contains(first, ".") && !strings.Contains(first, ":") && first != "localhost") {
			return "docker.io"
		}
		return first
	}
	return registryHost(repository) != "docker.io"
}

// writeNetworkPolicyBlock은 앱별 통신 정책을 values로 옮긴다.
// 사용자는 raw NetworkPolicy를 적지 않는다 — 여기서 Chart가 아는 형태로만 만든다.
func writeNetworkPolicyBlock(builder *strings.Builder, profile normalizedProfile) {
	policy := profile.NetworkPolicy
	egressMode := policy.EgressMode
	if egressMode == "" {
		egressMode = egressBlocked
	}
	builder.WriteString("networkPolicy:\n")
	builder.WriteString("  enabled: true\n")
	fmt.Fprintf(builder, "  egressMode: %s\n", yamlString(egressMode))
	writeAppPeerList(builder, "  allowedApps", policy.AllowedApps)
	if len(policy.AllowedCIDRs) == 0 {
		builder.WriteString("  allowedCIDRs: []\n")
	} else {
		builder.WriteString("  allowedCIDRs:\n")
		for _, peer := range policy.AllowedCIDRs {
			fmt.Fprintf(builder, "    - cidr: %s\n", yamlString(peer.CIDR))
			fmt.Fprintf(builder, "      protocol: %s\n", yamlString(defaultProtocol(peer.Protocol)))
			fmt.Fprintf(builder, "      port: %d\n", peer.Port)
		}
	}
	builder.WriteString("  ingress:\n")
	// AppGroup Namespace는 default-deny-ingress이고, 단일 internal 앱도 다른
	// Namespace의 ClusterIP 접근을 막아야 한다. 둘 다 명시적으로 켜 둔다.
	ingressEnabled := profile.App.Group != "" || profile.exposureMode() == exposureInternal
	fmt.Fprintf(builder, "    enabled: %t\n", ingressEnabled)
	writeAppPeerList(builder, "    allowedApps", policy.Ingress.AllowedApps)
}

func writeAppPeerList(builder *strings.Builder, label string, peers []appPeerInput) {
	if len(peers) == 0 {
		fmt.Fprintf(builder, "%s: []\n", label)
		return
	}
	indent := strings.Repeat(" ", len(label)-len(strings.TrimLeft(label, " "))+2)
	fmt.Fprintf(builder, "%s:\n", label)
	for _, peer := range peers {
		fmt.Fprintf(builder, "%s- app: %s\n", indent, yamlString(peer.App))
		fmt.Fprintf(builder, "%s  protocol: %s\n", indent, yamlString(defaultProtocol(peer.Protocol)))
		if peer.Port > 0 {
			fmt.Fprintf(builder, "%s  port: %d\n", indent, peer.Port)
		}
	}
}

func defaultProtocol(value string) string {
	if value == "" {
		return "TCP"
	}
	return value
}

func writeResourceBlock(builder *strings.Builder, label string, values map[string]string) {
	fmt.Fprintf(builder, "    %s:\n", label)
	for _, key := range sortedKeys(values) {
		fmt.Fprintf(builder, "      %s: %s\n", key, yamlString(values[key]))
	}
}

// renderValuesYAML은 charts/app-profile이 직접 읽을 수 있는 values 파일을 만든다.
// 이미지 태그는 포털의 kaniko 빌드가 끝난 뒤 같은 파일에서 치환한다.
func renderValuesYAML(request deploymentRequest) string {
	profile := request.Profile
	var builder strings.Builder
	replicas := max(profile.Replicas, 1)
	exposureEnabled := true
	if requestRuntimeState(request) == runtimeStopped {
		// 중지는 Service/DNS 계약과 PVC를 남긴 채 실행 Pod와 외부 Route만 내린다.
		// 삭제와 같은 파일 제거로 구현하면 내부 주소와 영구 데이터까지 함께 사라진다.
		replicas = 0
		exposureEnabled = false
	}

	builder.WriteString("# 이 파일은 SADP 포털이 생성했습니다. 직접 수정하지 마세요.\n")
	fmt.Fprintf(&builder, "# 요청 ID: %s\n", request.ID)
	fmt.Fprintf(&builder, "# 생성 시각: %s\n", request.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"))
	builder.WriteString("---\n")

	builder.WriteString("app:\n")
	fmt.Fprintf(&builder, "  name: %s\n", yamlString(profile.App.Name))
	if profile.App.Group != "" {
		fmt.Fprintf(&builder, "  group: %s\n", yamlString(profile.App.Group))
	}
	fmt.Fprintf(&builder, "  project: %s\n", yamlString(profile.App.Project))
	fmt.Fprintf(&builder, "  environment: %s\n", yamlString(profile.App.Environment))
	fmt.Fprintf(&builder, "replicaCount: %d\n", replicas)

	builder.WriteString("image:\n")
	image := profile.Source.Image
	usePullSecret := true
	if image == "" && request.Generated.Image != "" {
		// 소스 빌드 앱의 최종 tag는 최초 렌더 뒤에 정해진다. 정지/재개가 다시
		// values를 만들 때 CHANGE_ME로 되돌리지 않도록 저장된 최종 좌표를 쓴다.
		image = request.Generated.Image
	}
	if repository, reference, prebuilt := splitPrebuiltImage(image); prebuilt {
		// Compose 가 지정한 기존 이미지다. 빌드가 없으므로 태그 치환도 하지 않는다.
		usePullSecret = prebuiltImageUsesPullSecret(repository)
		fmt.Fprintf(&builder, "  repository: %s\n", yamlString(repository))
		if strings.HasPrefix(reference, "sha256:") {
			builder.WriteString("  tag: \"\"\n")
			fmt.Fprintf(&builder, "  digest: %s\n", yamlString(reference))
		} else {
			fmt.Fprintf(&builder, "  tag: %s\n", yamlString(reference))
			builder.WriteString("  digest: \"\"\n")
		}
	} else {
		repositoryName := profile.App.Name
		if profile.App.Group != "" {
			repositoryName = profile.App.Group + "/" + profile.App.Name
		}
		fmt.Fprintf(&builder, "  repository: %s\n",
			yamlString(fmt.Sprintf("%s/%s", strings.TrimRight(registryBase, "/"), repositoryName)))
		// Actions 워크플로가 커밋 SHA로 치환한다. 사람이 손대는 값이 아니다.
		builder.WriteString("  tag: \"CHANGE_ME_COMMIT_SHA\"\n")
		builder.WriteString("  digest: \"\"\n")
	}
	builder.WriteString("  pullPolicy: \"IfNotPresent\"\n")
	fmt.Fprintf(&builder, "  usePullSecret: %t\n", usePullSecret)
	if usePullSecret {
		builder.WriteString("imagePullSecrets:\n")
		fmt.Fprintf(&builder, "  - %s\n", yamlString(registryPullSecret))
	} else {
		builder.WriteString("imagePullSecrets: []\n")
	}

	builder.WriteString("service:\n")
	fmt.Fprintf(&builder, "  enabled: %t\n", profile.serviceEnabled())
	fmt.Fprintf(&builder, "  port: %d\n", profile.Service.Port)
	builder.WriteString("  probe:\n")
	probeType := "http"
	if profile.App.Group != "" {
		// Compose 이미지에는 공통 /healthz 계약이 없다. TCP 소켓 준비 여부를 쓰면
		// PostgreSQL/Redis와 일반 웹 서비스 모두 거짓 HTTP probe로 막히지 않는다.
		probeType = "tcp"
	}
	if !profile.serviceEnabled() {
		probeType = "none"
	}
	fmt.Fprintf(&builder, "    type: %s\n", yamlString(probeType))
	fmt.Fprintf(&builder, "  healthPath: %s\n", yamlString(profile.Service.HealthPath))
	securityProfile := "restricted"
	if profile.App.Group != "" {
		imageRepository, _, _ := splitPrebuiltImage(profile.Source.Image)
		base := path.Base(imageRepository)
		switch base {
		case "postgres":
			securityProfile = "postgres"
		case "redis":
			securityProfile = "redis"
		}
	}
	builder.WriteString("podSecurity:\n")
	fmt.Fprintf(&builder, "  profile: %s\n", yamlString(securityProfile))
	builder.WriteString("  runAsUser: 10001\n")
	builder.WriteString("  runAsGroup: 10001\n")

	if profile.Persistence.Enabled {
		builder.WriteString("persistence:\n")
		builder.WriteString("  enabled: true\n")
		builder.WriteString("  existingClaim: \"\"\n")
		builder.WriteString("  accessMode: \"ReadWriteOnce\"\n")
		fmt.Fprintf(&builder, "  size: %s\n", yamlString(profile.Persistence.Size))
		fmt.Fprintf(&builder, "  storageClass: %s\n", yamlString(profile.Persistence.StorageClass))
		fmt.Fprintf(&builder, "  mountPath: %s\n", yamlString(profile.Persistence.MountPath))
		// AppGroup 앱 Application을 지우면 그 앱의 PVC도 즉시 prune된다. 보존되는 척하는
		// Helm keep annotation을 붙이지 않고 이 데이터 수명주기를 values에 고정한다.
		builder.WriteString("  keepOnDelete: false\n")
	}

	// 노출과 인증은 별개로 적는다. exposure.type(public|oidc)은 더 쓰지 않는다.
	builder.WriteString("exposure:\n")
	fmt.Fprintf(&builder, "  enabled: %t\n", exposureEnabled)
	fmt.Fprintf(&builder, "  mode: %s\n", yamlString(profile.exposureMode()))
	fmt.Fprintf(&builder, "  host: %s\n", yamlString(profile.Exposure.Host))
	builder.WriteString("authentication:\n")
	fmt.Fprintf(&builder, "  mode: %s\n", yamlString(profile.authMode()))

	writeNetworkPolicyBlock(&builder, profile)

	builder.WriteString("resources:\n")
	writeResourceBlock(&builder, "requests", profile.Resources.Requests)
	writeResourceBlock(&builder, "limits", profile.Resources.Limits)

	builder.WriteString("configuration:\n")
	builder.WriteString("  config:\n")
	// 사용자가 같은 key 를 분류해 왔으면 그쪽이 이긴다. 기본값을 뒤에 덮어쓰면
	// 화면에서 값을 바꿔도 배포에는 반영되지 않는 어긋남이 생긴다.
	config := map[string]string{"APP_ENV": profile.App.Environment, "LOG_LEVEL": "info"}
	for key, value := range profile.Configuration.Config {
		config[key] = value
	}
	for _, key := range sortedKeys(config) {
		fmt.Fprintf(&builder, "    %s: %s\n", key, yamlString(config[key]))
	}
	esoContract, _ := resolveESOAccessContract(profile, request.Generated.OpenBaoPath)
	remotePath := esoContract.SecretPath
	secretStore := "openbao-" + profile.App.Name
	needsOIDCSecret := profile.authMode() == authOIDC
	if len(profile.Configuration.SecretKeys) == 0 && !needsOIDCSecret {
		builder.WriteString("  externalSecrets: []\n")
	} else {
		builder.WriteString("  externalSecrets:\n")
		if len(profile.Configuration.SecretKeys) > 0 {
			// 값이 아니라 key 이름만 적는다.
			builder.WriteString("    - name: \"app-env\"\n")
			fmt.Fprintf(&builder, "      secretStore: %s\n", yamlString(secretStore))
			fmt.Fprintf(&builder, "      remotePath: %s\n", yamlString(remotePath))
			builder.WriteString("      inject: true\n")
			builder.WriteString("      keys:\n")
			for _, key := range profile.Configuration.SecretKeys {
				fmt.Fprintf(&builder, "        - %s\n", yamlString(key))
			}
		}
		if needsOIDCSecret {
			// SecurityPolicy 가 참조하는 <app>-oidc-client Secret 이다. 이 항목이 없으면
			// Envoy 는 존재하지 않는 Secret 을 가리키고 로그인 자체가 시작되지 않는다.
			// 앱 컨테이너에는 넣지 않는다(inject: false) — 인증은 Gateway 가 한다.
			builder.WriteString("    - name: \"oidc-client\"\n")
			fmt.Fprintf(&builder, "      secretStore: %s\n", yamlString(secretStore))
			fmt.Fprintf(&builder, "      remotePath: %s\n", yamlString(remotePath))
			builder.WriteString("      inject: false\n")
			builder.WriteString("      keys:\n")
			builder.WriteString("        - \"OIDC_CLIENT_SECRET\"\n")
			builder.WriteString("      targetKeyMap:\n")
			builder.WriteString("        OIDC_CLIENT_SECRET: \"client-secret\"\n")
		}
	}
	builder.WriteString("  injection:\n")
	builder.WriteString("    mode: \"envFrom\"\n")
	builder.WriteString("  reload:\n")
	builder.WriteString("    enabled: true\n")
	builder.WriteString("    pausePeriod: \"1m\"\n")

	// ExternalSecret 은 openbao-<app> SecretStore 를 참조한다. Secret key 를 하나라도
	// 쓰면 그 SecretStore 가 있어야 하므로, OIDC 가 아니어도 만들어야 한다.
	//
	// 조건은 프로필(노출/인증)에서 직접 판단한다. 예전에는 Generated.OIDCClientID를
	// 봤는데, 그건 계획 계산 결과라 프로필과 따로 채워질 수 있다. 둘이 어긋나면
	// SecurityPolicy 는 생기고 그것이 참조하는 Secret 만 없는 상태가 된다.
	builder.WriteString("eso:\n")
	if needsOIDCSecret || len(profile.Configuration.SecretKeys) > 0 {
		builder.WriteString("  createSecretStore: true\n")
		// role/SA/path를 values에 모두 명시한다. role은 bootstrap이 만든 고정 역할이고,
		// AppGroup SA는 canonical tuple hash라 전역 이름 충돌이 없다.
		if esoContract.Role != "" && esoContract.ServiceAccount != "" {
			fmt.Fprintf(&builder, "  serviceAccountName: %s\n", yamlString(esoContract.ServiceAccount))
			fmt.Fprintf(&builder, "  role: %s\n", yamlString(esoContract.Role))
		}
	} else {
		builder.WriteString("  createSecretStore: false\n")
	}
	if needsOIDCSecret {
		// 한 realm 을 여러 시스템이 나눠 쓰므로 로그인만으로 통과하면 안 된다.
		// 앱 전용 그룹을 기본으로 넣고, AppGroup은 흔한 앱 이름을 재사용하므로 group을
		// 포함한다. 그룹 구성은 외부 IdP 관리자가 한다.
		builder.WriteString("oidc:\n")
		builder.WriteString("  allowedGroups:\n")
		fmt.Fprintf(&builder, "    - %s\n", yamlString(oidcAllowedGroup(profile)))
	}

	return builder.String()
}

// renderArgoApplicationYAML은 bootstrap Application이 자동 발견하는 child Application이다.
// 단일 앱은 기존 platform-prod/Zone 경계를 유지하고, AppGroup 앱은 app-* Namespace가
// 허용된 app-groups 프로젝트를 쓴다. destination만 바꾸고 project를 그대로 두면 Argo가
// InvalidSpecError로 거부하므로 두 값은 반드시 함께 바뀌어야 한다.
func renderArgoApplicationYAML(request deploymentRequest, repoURL, revision string) string {
	appName := request.Profile.App.Name
	valuesPath := appValuesPath(request.Profile)
	applicationProject := argoProject
	if request.Profile.App.Group != "" {
		applicationProject = groupArgoProject
	}
	var builder strings.Builder

	builder.WriteString("# 이 파일은 SADP 포털이 생성했습니다. 직접 수정하지 마세요.\n")
	builder.WriteString("apiVersion: argoproj.io/v1alpha1\n")
	builder.WriteString("kind: Application\n")
	builder.WriteString("metadata:\n")
	fmt.Fprintf(&builder, "  name: %s\n", yamlString(appApplicationName(request.Profile)))
	fmt.Fprintf(&builder, "  namespace: %s\n", yamlString(argoNamespace))
	if request.Profile.App.Group != "" {
		// platform-bootstrap은 group Application이 Healthy가 된 다음 wave에서만
		// 이 Application을 만든다. Namespace가 먼저 생겼어도 default-deny가 아직
		// 적용되지 않은 짧은 구간에 워크로드가 뜨는 것을 막는다.
		builder.WriteString("  annotations:\n")
		fmt.Fprintf(&builder, "    argocd.argoproj.io/sync-wave: %s\n", yamlString(groupedAppSyncWave))
	}
	builder.WriteString("  finalizers:\n")
	builder.WriteString("    - \"resources-finalizer.argocd.argoproj.io\"\n")
	builder.WriteString("spec:\n")
	fmt.Fprintf(&builder, "  project: %s\n", yamlString(applicationProject))
	builder.WriteString("  sources:\n")
	fmt.Fprintf(&builder, "    - repoURL: %s\n", yamlString(repoURL))
	fmt.Fprintf(&builder, "      targetRevision: %s\n", yamlString(revision))
	builder.WriteString("      path: \"charts/app-profile\"\n")
	builder.WriteString("      helm:\n")
	fmt.Fprintf(&builder, "        releaseName: %s\n", yamlString(appName))
	builder.WriteString("        valueFiles:\n")
	builder.WriteString("          - \"$values/contracts/values-platform-production.yaml\"\n")
	fmt.Fprintf(&builder, "          - %s\n", yamlString("$values/"+valuesPath))
	fmt.Fprintf(&builder, "    - repoURL: %s\n", yamlString(repoURL))
	fmt.Fprintf(&builder, "      targetRevision: %s\n", yamlString(revision))
	builder.WriteString("      ref: \"values\"\n")
	builder.WriteString("  destination:\n")
	builder.WriteString("    server: \"https://kubernetes.default.svc\"\n")
	fmt.Fprintf(&builder, "    namespace: %s\n", yamlString(request.Profile.namespace()))
	builder.WriteString("  syncPolicy:\n")
	builder.WriteString("    automated:\n")
	// 같은 앱을 external+oidc에서 internal+none으로 바꾸면 HTTPRoute/SecurityPolicy가
	// 렌더 집합에서 사라진다. 개별 포털 앱 Application은 이를 prune해야 이전 외부 경로가
	// orphan으로 남지 않는다. Namespace bootstrap Application의 보존 정책과는 별개다.
	builder.WriteString("      prune: true\n")
	builder.WriteString("      selfHeal: true\n")
	// AppGroup Namespace는 group Application이 만든다. 여기서 만들면 quota/default-deny
	// 없이 먼저 생겨 버려 경계가 없는 Namespace가 잠깐 존재한다.
	builder.WriteString("    syncOptions:\n")
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

// renderPullRequestBody는 검토자가 승인 전에 확인할 요약을 만든다.
// 토큰 등 비밀값은 포함하지 않고, 사용자 입력은 코드 스팬으로 감싼다.
func renderPullRequestBody(request deploymentRequest) string {
	profile := request.Profile
	var builder strings.Builder

	builder.WriteString("SADP 포털에서 생성한 자동 배포 요청입니다.\n\n")
	builder.WriteString("| 항목 | 값 |\n| --- | --- |\n")
	fmt.Fprintf(&builder, "| 요청 ID | `%s` |\n", markdownCode(request.ID))
	fmt.Fprintf(&builder, "| 앱 이름 | `%s` |\n", markdownCode(profile.App.Name))
	fmt.Fprintf(&builder, "| 프로젝트 | `%s` |\n", markdownCode(profile.App.Project))
	fmt.Fprintf(&builder, "| 환경 | `%s` |\n", markdownCode(profile.App.Environment))
	fmt.Fprintf(&builder, "| 소스 저장소 | `%s` |\n", markdownCode(profile.Source.Repository))
	fmt.Fprintf(&builder, "| 브랜치 | `%s` |\n", markdownCode(profile.Source.Revision))
	if profile.Source.Commit != "" {
		fmt.Fprintf(&builder, "| 소스 commit | `%s` |\n", markdownCode(profile.Source.Commit))
	}
	fmt.Fprintf(&builder, "| Dockerfile | `%s` |\n", markdownCode(profile.Source.Dockerfile))
	if profile.serviceEnabled() {
		fmt.Fprintf(&builder, "| 컨테이너 포트 | `%d` |\n", profile.Service.Port)
	} else {
		builder.WriteString("| 워크로드 | `worker (Service/Probe 없음)` |\n")
	}
	if profile.Persistence.Enabled {
		fmt.Fprintf(&builder, "| 영구 저장 경로 | `%s` (RWO, replica 1, 앱 삭제 시 데이터 삭제) |\n", markdownCode(profile.Persistence.MountPath))
	}
	if profile.App.Group != "" {
		fmt.Fprintf(&builder, "| 앱 그룹 | `%s` |\n", markdownCode(profile.App.Group))
		fmt.Fprintf(&builder, "| Namespace | `%s` |\n", markdownCode(profile.namespace()))
	}
	fmt.Fprintf(&builder, "| 노출 방식 | `%s` |\n", markdownCode(profile.exposureMode()))
	fmt.Fprintf(&builder, "| 접속 인증 | `%s` |\n", markdownCode(profile.authMode()))
	if profile.Exposure.Host != "" {
		fmt.Fprintf(&builder, "| 접속 주소 | `%s` |\n", markdownCode(profile.Exposure.Host))
	}
	fmt.Fprintf(&builder, "| 외부 통신 | `%s` |\n", markdownCode(profile.NetworkPolicy.EgressMode))
	if request.Requester != "" {
		fmt.Fprintf(&builder, "| 신청자 | `%s` |\n", markdownCode(request.Requester))
	}
	if request.SourceUpdate {
		builder.WriteString("| 요청 유형 | `source-update` |\n")
	}

	builder.WriteString("\n### 승인 전 확인 사항\n")
	builder.WriteString("1. 소스 저장소가 사내 Forgejo이고 신청자에게 권한이 있는지 확인합니다.\n")
	builder.WriteString("2. 노출 방식이 `external`이면 Envoy Gateway 외부 노출 정책에 부합하는지, 인증이 필요한 시스템인지 확인합니다.\n")
	builder.WriteString("3. 리소스 요청량이 해당 프로젝트 쿼터 안에 들어오는지 확인합니다.\n")
	builder.WriteString("4. 외부 통신이 `web`이면 인터넷 TCP 80/443이 실제로 필요한 앱인지 확인합니다.\n")
	builder.WriteString("\n머지하면 Argo CD가 동기화하고 Forgejo Actions가 이미지를 빌드합니다.\n")

	return builder.String()
}

// markdownCode는 백틱과 개행을 제거해 표 셀과 코드 스팬을 깨뜨리지 못하게 한다.
func markdownCode(value string) string {
	replacer := strings.NewReplacer("`", "", "|", "", "\n", " ", "\r", " ")
	return replacer.Replace(value)
}
