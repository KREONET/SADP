package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func renderedRequest(t *testing.T, exposure string) deploymentRequest {
	t.Helper()
	var input appProfileInput
	if err := json.Unmarshal([]byte(validInput(exposure)), &input); err != nil {
		t.Fatalf("입력 해석 실패: %v", err)
	}
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("입력 검증 실패: %+v", errors)
	}
	result := validationResult(input, true)
	return deploymentRequest{ID: "0123456789abcdef", Profile: result.Profile, Generated: result.Generated}
}

func TestRenderValuesMatchesAppProfileChart(t *testing.T) {
	values := renderValuesYAML(renderedRequest(t, "public"))
	for _, required := range []string{
		"app:\n  name: \"research-viewer\"",
		"imagePullSecrets:\n  - \"" + registryPullSecret + "\"",
		"  usePullSecret: true",
		// 노출과 인증은 별개 값으로 나가야 한다. 예전 exposure.type 은 더 쓰지 않는다.
		"exposure:\n  enabled: true\n  mode: \"external\"",
		"authentication:\n  mode: \"none\"",
		"networkPolicy:\n  enabled: true\n  egressMode: \"blocked\"",
		"configuration:\n  config:",
		"eso:\n  createSecretStore: false",
	} {
		if !strings.Contains(values, required) {
			t.Fatalf("필수 chart values가 없음 %q:\n%s", required, values)
		}
	}
	for _, forbidden := range []string{
		"nameOverride:", "  type: \"public\"", "  type: \"ClusterIP\"", "  group:",
	} {
		if strings.Contains(values, forbidden) {
			t.Fatalf("chart와 맞지 않는 이전 필드 %q가 남음:\n%s", forbidden, values)
		}
	}
}

func TestPrebuiltPublicImageDoesNotUsePlatformPullSecret(t *testing.T) {
	request := renderedRequest(t, "public")
	request.Profile.App.Group = "test"
	request.Profile.Source.Repository = ""
	request.Profile.Source.Image = "docker.io/nginxinc/nginx-unprivileged:1.27-alpine"
	values := renderValuesYAML(request)
	if !strings.Contains(values, "  usePullSecret: false") ||
		!strings.Contains(values, "imagePullSecrets: []") {
		t.Fatalf("Docker Hub public image에 플랫폼 pull Secret이 남음:\n%s", values)
	}
}

// 분류기에서 넘어온 환경변수가 chart 계약대로 나오는지 본다. ConfigMap 값은 그대로,
// OpenBao 항목은 **이름만** 나와야 하고 SecretStore 가 함께 켜져야 ExternalSecret 이 푼다.
func TestRenderValuesCarriesClassifiedEnvVars(t *testing.T) {
	var input appProfileInput
	if err := json.Unmarshal([]byte(validInput("public")), &input); err != nil {
		t.Fatalf("입력 해석 실패: %v", err)
	}
	input.EnvVars = []envVarInput{
		{Key: "APP_MODE", Value: "readonly", Classification: "configmap"},
		{Key: "DB_PASSWORD", Value: "only-in-request", Classification: "openbao"},
	}
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("입력 검증 실패: %+v", errors)
	}
	result := validationResult(input, true)
	values := renderValuesYAML(deploymentRequest{
		ID: "0123456789abcdef", Profile: result.Profile, Generated: result.Generated,
	})

	for _, required := range []string{
		"    APP_MODE: \"readonly\"",
		"  externalSecrets:\n    - name: \"app-env\"",
		"      remotePath: \"apps/research/beta/workloads/research-beta/eso-research-viewer\"",
		"        - \"DB_PASSWORD\"",
		"eso:\n  createSecretStore: true",
		"  serviceAccountName: \"eso-research-viewer\"",
		"  role: \"portal-zone-app-eso\"",
	} {
		if !strings.Contains(values, required) {
			t.Fatalf("환경변수 렌더 결과에 %q 가 없음:\n%s", required, values)
		}
	}
	// 민감 key 가 ConfigMap 쪽으로 새면 Helm 렌더가 실패한다. 그 전에 여기서 잡는다.
	if strings.Contains(values, "    DB_PASSWORD:") {
		t.Fatalf("Secret key 가 ConfigMap 에 들어감:\n%s", values)
	}
}

func TestRenderValuesPreservesStoredLegacyESOContractOnResume(t *testing.T) {
	request := renderedRequest(t, "oidc")
	request.Profile.Configuration.SecretKeys = []string{"API_TOKEN"}
	// 구버전 PVC에는 mount 이름까지 포함한 표시용 경로가 저장됐다.
	request.Generated.OpenBaoPath = "kv/apps/research/beta/research-viewer"
	values := renderValuesYAML(request)
	for _, required := range []string{
		`remotePath: "apps/research/beta/research-viewer"`,
		`serviceAccountName: "eso-research-viewer"`,
		`role: "eso-research-beta-research-viewer"`,
	} {
		if !strings.Contains(values, required) {
			t.Fatalf("legacy resume values에 %q가 없음:\n%s", required, values)
		}
	}
	if strings.Contains(values, "workloads/research-beta/eso-research-viewer") {
		t.Fatalf("legacy resume가 canonical 경로로 조용히 이동함:\n%s", values)
	}
}

// OpenBao 값은 필수이고 민감 key를 ConfigMap으로 보내는 입력은 계속 차단한다.
func TestValidateSecretInputAndRejectsUnsafeClassification(t *testing.T) {
	cases := []struct {
		name    string
		envVars []envVarInput
	}{
		{
			name:    "openbao 값 누락",
			envVars: []envVarInput{{Key: "DB_PASSWORD", Classification: "openbao"}},
		},
		{
			name:    "민감 key 를 configmap 으로",
			envVars: []envVarInput{{Key: "API_KEY", Value: "abc", Classification: "configmap"}},
		},
		{
			name:    "자격증명 URI를 configmap 으로",
			envVars: []envVarInput{{Key: "ENDPOINT", Value: "postgres://user:password@postgres/app", Classification: "configmap"}},
		},
		{
			name:    "분류되지 않음",
			envVars: []envVarInput{{Key: "APP_MODE", Value: "x", Classification: ""}},
		},
		{
			name:    "key 형식 위반",
			envVars: []envVarInput{{Key: "9BAD-KEY", Value: "x", Classification: "configmap"}},
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			var input appProfileInput
			if err := json.Unmarshal([]byte(validInput("public")), &input); err != nil {
				t.Fatalf("입력 해석 실패: %v", err)
			}
			input.EnvVars = testCase.envVars
			if errors := validateInput(&input); len(errors) == 0 {
				t.Fatalf("거부되어야 하는 입력이 통과함: %+v", testCase.envVars)
			}
		})
	}
}

func TestRenderArgoApplicationTargetsSingleZone(t *testing.T) {
	application := renderArgoApplicationYAML(
		renderedRequest(t, "public"),
		"https://forgejo.example/platform/gitops",
		"main",
	)
	for _, required := range []string{
		"path: \"charts/app-profile\"",
		"$values/apps/research-viewer/values-beta.yaml",
		"namespace: \"" + zoneNamespace() + "\"",
		"project: \"" + argoProject + "\"",
		"finalizers:\n    - \"resources-finalizer.argocd.argoproj.io\"",
	} {
		if !strings.Contains(application, required) {
			t.Fatalf("Application 필수 값이 없음 %q:\n%s", required, application)
		}
	}
}

func TestRenderArgoApplicationTargetsAppGroupProject(t *testing.T) {
	request := renderedRequest(t, "public")
	request.Profile.App.Group = "mobility-platform"
	application := renderArgoApplicationYAML(
		request,
		"https://forgejo.example/platform/gitops",
		"main",
	)
	for _, required := range []string{
		"namespace: \"" + groupNamespace("mobility-platform") + "\"",
		"project: \"" + groupArgoProject + "\"",
		"argocd.argoproj.io/sync-wave: \"0\"",
		"name: \"aa-mobility-platform-research-viewer-beta-e8ff790ab0\"",
		"$values/apps/_groups/mobility-platform/apps/research-viewer/values-beta.yaml",
		"automated:\n      prune: true",
		"kind: \"Deployment\"\n      jqPathExpressions:\n        - \".status.terminatingReplicas\"",
		"kind: \"ReplicaSet\"\n      jqPathExpressions:\n        - \".status.terminatingReplicas\"",
	} {
		if !strings.Contains(application, required) {
			t.Fatalf("AppGroup Application 필수 값이 없음 %q:\n%s", required, application)
		}
	}
	if strings.Contains(application, "project: \""+argoProject+"\"") {
		t.Fatalf("AppGroup Application이 단일 Zone 프로젝트를 사용함:\n%s", application)
	}
}

func TestSingleAppApplicationHasNoGroupSyncWave(t *testing.T) {
	application := renderArgoApplicationYAML(
		renderedRequest(t, "public"),
		"https://forgejo.example/platform/gitops",
		"main",
	)
	if strings.Contains(application, "argocd.argoproj.io/sync-wave") {
		t.Fatalf("단일 앱 Application에 AppGroup 전용 sync wave가 들어감:\n%s", application)
	}
}

func TestPortalManagedAppApplicationPrunesRemovedExposureResources(t *testing.T) {
	request := renderedRequest(t, "oidc")
	application := renderArgoApplicationYAML(request, "https://forgejo.example/platform/gitops", "main")
	if !strings.Contains(application, "automated:\n      prune: true\n      selfHeal: true") {
		t.Fatalf("개별 앱 Application이 optional HTTPRoute/SecurityPolicy를 prune하지 않음:\n%s", application)
	}
	// 전환 후 values에는 Route/SecurityPolicy 생성 조건이 모두 사라지고, 같은 Application의
	// prune=true가 기존 리소스를 지운다. Helm 자체 종류 검증은 render-test.sh가 담당한다.
	request.Profile.Exposure.Mode = exposureInternal
	request.Profile.Exposure.Type = exposureInternal
	request.Profile.Exposure.Host = ""
	request.Profile.Authentication.Mode = authNone
	values := renderValuesYAML(request)
	if !strings.Contains(values, "mode: \"internal\"") ||
		!strings.Contains(values, "authentication:\n  mode: \"none\"") {
		t.Fatalf("internal+none 전환 values 불일치:\n%s", values)
	}
}

func TestGroupedAppGitOpsPathsAreScopedAndNamesAreStable(t *testing.T) {
	profile := renderedRequest(t, "public").Profile
	profile.App.Name = "api"
	profile.App.Group = "mobility-platform"
	profile.App.Environment = "prod"
	if got, want := appValuesPath(profile), "apps/_groups/mobility-platform/apps/api/values-prod.yaml"; got != want {
		t.Fatalf("group values path=%q, want %q", got, want)
	}
	if got, want := appApplicationPath(profile), "argocd/applications/aa-mobility-platform-api-prod-2b6eeb3085.yaml"; got != want {
		t.Fatalf("group application path=%q, want %q", got, want)
	}
	if got, want := appApplicationName(profile), "aa-mobility-platform-api-prod-2b6eeb3085"; got != want {
		t.Fatalf("group application name=%q, want %q", got, want)
	}

	profile.App.Name = strings.Repeat("a", 40)
	profile.App.Group = strings.Repeat("b", 40)
	first := appApplicationName(profile)
	second := appApplicationName(profile)
	if first != second || len(first) > 63 {
		t.Fatalf("긴 application 이름이 안정적이지 않거나 63자를 넘음: first=%q second=%q", first, second)
	}
}
