package main

// 노출/인증/네트워크 정책이 서로 독립인지, Compose -> AppGroup 변환이
// 우리가 막기로 한 것을 실제로 막는지 확인한다.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func appGroupRequestBody(t *testing.T, image string) string {
	t.Helper()
	input := appGroupInput{
		Group: "stack", Project: "research", Environment: "beta",
		Compose:      "services:\n  api:\n    image: " + image + "\n    expose:\n      - 8080\n",
		ResourceSize: "small",
		Services:     []appGroupServiceInput{{Name: "api", Exposure: exposureInput{Mode: exposureInternal}}},
	}
	encoded, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

// AppGroup 생성 handler는 저장 전에 shared registry policy/role과 pull Secret seed를
// GET으로 확인한다. 테스트도 동적 policy/role 쓰기를 흉내 내지 않고 그 준비 상태만 답한다.
func registryReadyOpenBao(t *testing.T) *openBaoClient {
	t.Helper()
	expected := map[string]bool{
		"/v1/sys/policies/acl/portal-registry-pull-reader":   true,
		"/v1/auth/kubernetes/role/portal-group-registry-eso": true,
		"/v1/kv/metadata/platform/registry/pull-secret":      true,
		"/v1/kv/subkeys/platform/registry/pull-secret":       true,
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !expected[r.URL.Path] {
			t.Errorf("예상하지 못한 registry preflight: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		switch r.URL.Path {
		case "/v1/sys/policies/acl/portal-registry-pull-reader":
			writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(testRegistryPolicy("platform/registry/pull-secret")))
		case "/v1/auth/kubernetes/role/portal-group-registry-eso":
			writeTestOpenBaoJSON(t, w, testOpenBaoRole([]string{"eso-registry"}, nil,
				`{"matchLabels":{"platform.example.io/app-group":"true"}}`, openBaoRegistryPolicy))
		case "/v1/kv/metadata/platform/registry/pull-secret":
			writeTestOpenBaoJSON(t, w, testOpenBaoLiveMetadata(1))
		case "/v1/kv/subkeys/platform/registry/pull-secret":
			if r.URL.Query().Get("version") != "1" {
				t.Errorf("subkeys가 최신 버전으로 고정되지 않음: %s", r.URL.RawQuery)
			}
			writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys(openBaoRegistryRequiredKey))
		}
	}))
	t.Cleanup(server.Close)
	baseURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	return &openBaoClient{
		baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour),
	}
}

func TestAppGroupCreateReturns503WhenOpenBaoContractDrifts(t *testing.T) {
	_, forgejo := newFakeForgejo(t)
	api, handler := newTestAPI(t, forgejo)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/sys/policies/acl/portal-registry-pull-reader":
			writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(testRegistryPolicy("platform/registry/pull-secret")))
		case "/v1/auth/kubernetes/role/portal-group-registry-eso":
			role := testOpenBaoRole([]string{"eso-registry"}, nil,
				`{"matchLabels":{"platform.example.io/app-group":"true"}}`, openBaoRegistryPolicy).(map[string]any)
			role["data"].(map[string]any)["audience"] = "drifted-audience"
			writeTestOpenBaoJSON(t, w, role)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	baseURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	api.openbao = &openBaoClient{
		baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour),
	}
	previousPath := registryPullRemotePath
	registryPullRemotePath = "platform/registry/pull-secret"
	t.Cleanup(func() { registryPullRemotePath = previousPath })
	request := httptest.NewRequest(http.MethodPost, "/api/v1/app-groups",
		strings.NewReader(appGroupRequestBody(t, "nginx:1.27")))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(requesterHeader, "owner@example.invalid")
	request.Header.Set("Idempotency-Key", "openbao-role-drift")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusServiceUnavailable ||
		!strings.Contains(recorder.Body.String(), "registry-secret-unavailable") {
		t.Fatalf("OpenBao role drift status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestAppGroupCreateRequiresIdentityAndIdempotencyAndReplays(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	api.openbao = registryReadyOpenBao(t)
	previousPath := registryPullRemotePath
	registryPullRemotePath = "platform/registry/pull-secret"
	t.Cleanup(func() { registryPullRemotePath = previousPath })
	body := appGroupRequestBody(t, "nginx:1.27")
	validateWithoutHeader := httptest.NewRequest(http.MethodPost,
		"/api/v1/app-groups/validate?requester=spoofed", strings.NewReader(body))
	validateWithoutHeader.Header.Set("Content-Type", "application/json")
	validateRecorder := httptest.NewRecorder()
	handler.ServeHTTP(validateRecorder, validateWithoutHeader)
	if validateRecorder.Code != http.StatusBadRequest {
		t.Fatalf("요청자 없는 검증 status=%d body=%s", validateRecorder.Code, validateRecorder.Body.String())
	}

	post := func(requester, key, requestBody string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/app-groups", strings.NewReader(requestBody))
		req.Header.Set("Content-Type", "application/json")
		if requester != "" {
			req.Header.Set(requesterHeader, requester)
		}
		if key != "" {
			req.Header.Set("Idempotency-Key", key)
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		return recorder
	}
	if response := post("", "group-key", body); response.Code != http.StatusBadRequest {
		t.Fatalf("요청자 없는 생성 status=%d body=%s", response.Code, response.Body.String())
	}
	if response := post("owner@example.invalid", "", body); response.Code != http.StatusBadRequest {
		t.Fatalf("멱등 키 없는 생성 status=%d body=%s", response.Code, response.Body.String())
	}
	first := post("owner@example.invalid", "group-key", body)
	if first.Code != http.StatusAccepted {
		t.Fatalf("첫 생성 status=%d body=%s", first.Code, first.Body.String())
	}
	var created appGroupCreated
	if err := json.Unmarshal(first.Body.Bytes(), &created); err != nil || created.Count != 1 {
		t.Fatalf("생성 응답 해석 실패: %v %+v", err, created)
	}
	second := post("owner@example.invalid", "group-key", body)
	if second.Code != http.StatusOK {
		t.Fatalf("재시도 status=%d body=%s", second.Code, second.Body.String())
	}
	if stored := api.store.list(0, "owner@example.invalid"); len(stored) != 1 {
		t.Fatalf("재시도 후 요청 수=%d", len(stored))
	}
	if taken := post("other@example.invalid", "other-key", body); taken.Code != http.StatusConflict {
		t.Fatalf("다른 사용자의 AppGroup 선점 status=%d body=%s", taken.Code, taken.Body.String())
	}
	conflict := post("owner@example.invalid", "group-key", appGroupRequestBody(t, "nginx:1.28"))
	if conflict.Code != http.StatusConflict {
		t.Fatalf("다른 본문 재사용 status=%d body=%s", conflict.Code, conflict.Body.String())
	}
}

func TestAppGroupQuotaIncludesExistingApps(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	api.openbao = registryReadyOpenBao(t)
	previousPath := registryPullRemotePath
	registryPullRemotePath = "platform/registry/pull-secret"
	t.Cleanup(func() { registryPullRemotePath = previousPath })

	existingInput := profileFromJSON(t, quotaInput("medium", 3))
	if errors := validateInput(&existingInput); len(errors) > 0 {
		t.Fatalf("기존 프로필 검증 실패: %+v", errors)
	}
	existing := deploymentRequest{
		ID: "existing-medium", State: stateDeployed, Requester: "owner@example.invalid",
		Profile: validationResult(existingInput, true).Profile,
	}
	if err := api.store.create(existing, "", ""); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/app-groups",
		strings.NewReader(appGroupRequestBody(t, "nginx:1.27")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(requesterHeader, "owner@example.invalid")
	req.Header.Set("Idempotency-Key", "quota-group")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("기존 3CPU 뒤 AppGroup 추가가 통과함: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestAppGroupCreateBlocksWhileGroupDeletionIsUnfinished(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	input := appGroupInput{
		Group: "stack", Project: "research", Environment: "beta",
		Compose:      "services:\n  old:\n    image: nginx:1.27\n    expose:\n      - 8080\n",
		ResourceSize: "small",
		Services:     []appGroupServiceInput{{Name: "old", Exposure: exposureInput{Mode: exposureInternal}}},
	}
	profiles, _, errs := buildGroupProfiles(&input)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	deleting := deploymentRequest{
		ID: "deleting-stack", State: stateFailed, Requester: "owner@example.invalid",
		Profile:           validationResult(profiles[0], true).Profile,
		DeletionRequested: true, FailedFromState: stateDeleting,
	}
	if err := api.store.create(deleting, "", ""); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/app-groups",
		strings.NewReader(appGroupRequestBody(t, "nginx:1.27")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(requesterHeader, "owner@example.invalid")
	req.Header.Set("Idempotency-Key", "during-delete")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusConflict || !strings.Contains(recorder.Body.String(), "app-group-deleting") {
		t.Fatalf("삭제 중 group 생성 status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestAppGroupCreateDoesNotAdoptExistingNamespace(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	probeAPI := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/api/v1/namespaces/app-stack" {
			_, _ = w.Write([]byte(`{"metadata":{"name":"app-stack"}}`))
			return
		}
		http.NotFound(w, r)
	})
	api.forgejo.builder = probeAPI.forgejo.builder

	req := httptest.NewRequest(http.MethodPost, "/api/v1/app-groups",
		strings.NewReader(appGroupRequestBody(t, "nginx:1.27")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(requesterHeader, "owner@example.invalid")
	req.Header.Set("Idempotency-Key", "existing-namespace")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusConflict || !strings.Contains(recorder.Body.String(), "namespace-owned") {
		t.Fatalf("기존 Namespace 채택 status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func profileFromJSON(t *testing.T, body string) appProfileInput {
	t.Helper()
	var input appProfileInput
	if err := json.Unmarshal([]byte(body), &input); err != nil {
		t.Fatalf("입력 해석 실패: %v", err)
	}
	return input
}

// 예전 위저드는 exposure를 문자열로 보낸다. 그 요청이 계속 같은 결과를 내야 한다.
func TestLegacyExposureStringStillWorks(t *testing.T) {
	for _, testCase := range []struct {
		legacy         string
		wantExposure   string
		wantAuth       string
		wantCompatType string
	}{
		{"public", exposureExternal, authNone, "public"},
		{"oidc", exposureExternal, authOIDC, "oidc"},
	} {
		input := profileFromJSON(t, validInput(testCase.legacy))
		if errors := validateInput(&input); len(errors) > 0 {
			t.Fatalf("%s 검증 실패: %+v", testCase.legacy, errors)
		}
		profile := validationResult(input, true).Profile
		if profile.Exposure.Mode != testCase.wantExposure || profile.Authentication.Mode != testCase.wantAuth {
			t.Fatalf("%s -> exposure=%s auth=%s (기대 %s/%s)",
				testCase.legacy, profile.Exposure.Mode, profile.Authentication.Mode,
				testCase.wantExposure, testCase.wantAuth)
		}
		if profile.Exposure.Type != testCase.wantCompatType {
			t.Fatalf("%s -> 호환 type=%s (기대 %s)", testCase.legacy, profile.Exposure.Type, testCase.wantCompatType)
		}
	}
}

// 알 수 없는 예전 값은 external 로 승격되지 않고 거부되어야 한다.
func TestUnknownLegacyExposureRejected(t *testing.T) {
	input := profileFromJSON(t, validInput("office-oidc"))
	errors := validateInput(&input)
	if !hasFieldError(errors, "exposure") {
		t.Fatalf("office-oidc가 거부되지 않았다: %+v", errors)
	}
}

func TestLegacyAndNewAuthenticationConflictRejected(t *testing.T) {
	input := profileFromJSON(t, validInput("oidc"))
	input.Authentication.Mode = authNone
	if !hasFieldError(validateInput(&input), "authentication") {
		t.Fatal("legacy oidc와 authentication none 충돌이 통과했다")
	}
	input = profileFromJSON(t, validInput("public"))
	input.Authentication.Mode = authOIDC
	if !hasFieldError(validateInput(&input), "authentication") {
		t.Fatal("legacy public과 authentication oidc 충돌이 통과했다")
	}
}

func TestSingleAppReservedNamesRejectedButGroupScopedNamesAllowed(t *testing.T) {
	for _, name := range []string{"hello", "secure-demo", "portal-lite", "group-platform", "aa-generated", "ag-generated", "ga-generated"} {
		input := profileFromJSON(t, strings.Replace(validInput("public"), "research-viewer", name, 1))
		if !hasFieldError(validateInput(&input), "appName") {
			t.Fatalf("예약 단일 앱 이름 %q가 통과했다", name)
		}
	}
	input := profileFromJSON(t, strings.Replace(validInput("public"), "research-viewer", "portal-lite", 1))
	input.Group = "isolated-stack"
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("그룹 경로로 격리된 앱 이름이 거부됨: %+v", errors)
	}
}

func TestGroupedExternalIdentityIncludesGroup(t *testing.T) {
	input := profileFromJSON(t, validInput("oidc"))
	input.Group = "mobility"
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("검증 실패: %+v", errors)
	}
	result := validationResult(input, true)
	if result.Profile.Exposure.Host != "ga-research-viewer-mobility-376e074d38."+baseDomain ||
		result.Generated.OIDCClientID != "oc-a-mobility-research-viewer-beta-36fd2a5528" ||
		result.Generated.OpenBaoPath != "apps/research/beta/workloads/app-mobility/eso-sa-a-research-viewer-1b04590771" {
		t.Fatalf("그룹 identity가 경로에 포함되지 않음: %+v", result)
	}
}

func TestInternalWithOIDCRejected(t *testing.T) {
	input := profileFromJSON(t, `{
  "appName":"postgres",
  "group":"mobility-platform",
  "project":"research",
  "environment":"beta",
  "image":"docker.io/library/postgres:16",
  "containerPort":5432,
  "exposure":{"mode":"internal"},
  "authentication":{"mode":"oidc"},
  "resourceSize":"small"
}`)
	errors := validateInput(&input)
	if !hasFieldError(errors, "authentication") {
		t.Fatalf("internal + oidc 조합이 통과했다: %+v", errors)
	}
}

// 내부 전용 앱은 외부 주소를 갖지 않는다. host 가 남으면 화면에는 주소가 보이는데
// HTTPRoute 는 없는 상태가 된다.
func TestInternalAppHasNoHost(t *testing.T) {
	input := profileFromJSON(t, `{
  "appName":"redis",
  "group":"mobility-platform",
  "project":"research",
  "environment":"beta",
  "image":"docker.io/library/redis:7.2",
  "containerPort":6379,
  "exposure":{"mode":"internal"},
  "resourceSize":"small"
}`)
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("검증 실패: %+v", errors)
	}
	profile := validationResult(input, true).Profile
	if profile.Exposure.Host != "" {
		t.Fatalf("내부 전용 앱에 host가 남았다: %s", profile.Exposure.Host)
	}
	values := renderValuesYAML(deploymentRequest{ID: "0123456789abcdef", Profile: profile})
	if !strings.Contains(values, "  mode: \"internal\"") || !strings.Contains(values, "  host: \"\"") {
		t.Fatalf("internal values가 예상과 다르다:\n%s", values)
	}
	if profile.namespace() != groupNamespace("mobility-platform") {
		t.Fatalf("AppGroup Namespace가 아니다: %s", profile.namespace())
	}
	if want := "redis." + groupNamespace("mobility-platform") + ".svc:6379"; profile.Service.InternalAddress != want {
		t.Fatalf("AppGroup 내부 Service DNS=%q, want %q", profile.Service.InternalAddress, want)
	}
}

func TestSingleInternalAppRendersIngressPolicyEnabled(t *testing.T) {
	input := profileFromJSON(t, strings.Replace(validInput("public"),
		`"exposure":"public"`, `"exposure":{"mode":"internal"}`, 1))
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("검증 실패: %+v", errors)
	}
	values := renderValuesYAML(deploymentRequest{
		ID: "single-internal", Profile: validationResult(input, true).Profile,
	})
	if !strings.Contains(values, "  ingress:\n    enabled: true") {
		t.Fatalf("단일 internal 앱 ingress 정책이 꺼져 있음:\n%s", values)
	}
}

// egressMode 기본값은 blocked 다. 아무것도 적지 않은 앱이 인터넷으로 나가면 안 된다.
func TestEgressDefaultsToBlocked(t *testing.T) {
	input := profileFromJSON(t, validInput("public"))
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("검증 실패: %+v", errors)
	}
	if input.NetworkPolicy.EgressMode != egressBlocked {
		t.Fatalf("기본 egressMode=%s (기대 blocked)", input.NetworkPolicy.EgressMode)
	}
}

// CIDR 직접 지정은 custom 에서만. web/blocked 에서 허용하면 "80/443만"이 깨진다.
func TestAllowedCIDRsRequireCustomMode(t *testing.T) {
	input := profileFromJSON(t, validInput("public"))
	input.NetworkPolicy.EgressMode = egressWeb
	input.NetworkPolicy.AllowedCIDRs = []cidrPeerInput{{CIDR: "203.0.113.10/32", Port: 443}}
	if !hasFieldError(validateInput(&input), "networkPolicy.allowedCIDRs") {
		t.Fatal("web 모드에서 allowedCIDRs가 통과했다")
	}
}

func TestAllowedCIDRsRejectDefaultRoute(t *testing.T) {
	input := profileFromJSON(t, validInput("public"))
	input.NetworkPolicy.EgressMode = egressCustom
	input.NetworkPolicy.AllowedCIDRs = []cidrPeerInput{{CIDR: "0.0.0.0/0", Port: 443}}
	if !hasFieldError(validateInput(&input), "networkPolicy.allowedCIDRs[0]") {
		t.Fatal("0.0.0.0/0 전체 허용이 통과했다")
	}
}

func TestAllowedCIDRsAreCanonicalizedForKubernetes(t *testing.T) {
	input := profileFromJSON(t, validInput("public"))
	input.NetworkPolicy.EgressMode = egressCustom
	input.NetworkPolicy.AllowedCIDRs = []cidrPeerInput{{CIDR: "203.0.113.10/24", Port: 443}}
	if errors := validateInput(&input); len(errors) != 0 {
		t.Fatalf("정규화 가능한 CIDR 검증 실패: %+v", errors)
	}
	if got := input.NetworkPolicy.AllowedCIDRs[0].CIDR; got != "203.0.113.0/24" {
		t.Fatalf("canonical CIDR=%q", got)
	}
}

// 앱 사이 연결은 AppGroup 안에서만 뜻이 있다. 그룹이 없으면 공용 Zone의 남의 앱을 연다.
func TestAllowedAppsRequireGroup(t *testing.T) {
	input := profileFromJSON(t, validInput("public"))
	input.NetworkPolicy.AllowedApps = []appPeerInput{{App: "postgres", Port: 5432}}
	if !hasFieldError(validateInput(&input), "networkPolicy.allowedApps") {
		t.Fatal("AppGroup 없이 앱 사이 연결이 통과했다")
	}
}

func TestAllowedAppsOnlySupportTCPServiceConnections(t *testing.T) {
	input := profileFromJSON(t, validInput("public"))
	input.Group = "stack"
	input.NetworkPolicy.AllowedApps = []appPeerInput{{App: "postgres", Port: 5432, Protocol: "UDP"}}
	if !hasFieldError(validateInput(&input), "networkPolicy.allowedApps[0]") {
		t.Fatal("TCP Service만 생성하면서 UDP 앱 연결이 통과했다")
	}
}

func TestPrebuiltImageRejectsMutableTag(t *testing.T) {
	input := profileFromJSON(t, `{
  "appName":"redis",
  "group":"stack",
  "project":"research",
  "environment":"beta",
  "image":"docker.io/library/redis:latest",
  "containerPort":6379,
  "exposure":{"mode":"internal"},
  "resourceSize":"small"
}`)
	if !hasFieldError(validateInput(&input), "image") {
		t.Fatal("latest 태그 이미지가 통과했다")
	}
}

func TestPrebuiltImageRejectsMutableTagBehindRegistryPort(t *testing.T) {
	input := profileFromJSON(t, `{
  "appName":"api",
  "group":"stack",
  "project":"research",
  "environment":"beta",
  "image":"registry.example:5000/team/api:LATEST",
  "containerPort":8080,
  "exposure":{"mode":"internal"},
  "resourceSize":"small"
}`)
	if !hasFieldError(validateInput(&input), "image") {
		t.Fatal("포트가 있는 registry의 가변 태그 이미지가 통과했다")
	}
}

func TestPrebuiltImageAndGitAreExclusive(t *testing.T) {
	input := profileFromJSON(t, validInput("public"))
	input.Image = "docker.io/library/redis:7.2"
	if !hasFieldError(validateInput(&input), "image") {
		t.Fatal("이미지와 Git 소스를 함께 지정했는데 통과했다")
	}
}

// SecurityPolicy 는 <app>-oidc-client Secret 을 참조한다. values 가 그 ExternalSecret 을
// 함께 내지 않으면 Envoy 가 없는 Secret 을 가리키고 로그인 자체가 시작되지 않는다.
// 조건은 프로필의 인증 값에서 나와야 한다(계획 계산 결과에 기대면 둘이 어긋난다).
func TestOIDCValuesCarryClientSecret(t *testing.T) {
	input := profileFromJSON(t, validInput("oidc"))
	if errors := validateInput(&input); len(errors) > 0 {
		t.Fatalf("검증 실패: %+v", errors)
	}
	profile := validationResult(input, true).Profile
	// Generated 를 일부러 비워 둔다. 렌더가 그것에 의존하면 여기서 드러난다.
	values := renderValuesYAML(deploymentRequest{ID: "0123456789abcdef", Profile: profile})
	for _, required := range []string{
		"    - name: \"oidc-client\"",
		"      inject: false",
		"        - \"OIDC_CLIENT_SECRET\"",
		"        OIDC_CLIENT_SECRET: \"client-secret\"",
		"eso:\n  createSecretStore: true",
		"oidc:\n  allowedGroups:\n    - \"research-viewer-user\"",
	} {
		if !strings.Contains(values, required) {
			t.Fatalf("OIDC values에 %q 가 없음:\n%s", required, values)
		}
	}

	grouped := input
	grouped.Group = "mobility"
	if errors := validateInput(&grouped); len(errors) > 0 {
		t.Fatalf("그룹 OIDC 검증 실패: %+v", errors)
	}
	groupedValues := renderValuesYAML(deploymentRequest{
		ID: "0123456789abcdef", Profile: validationResult(grouped, true).Profile,
	})
	if !strings.Contains(groupedValues, "    - \"og-a-mobility-research-viewer-user-cc4d18e89e\"") ||
		!strings.Contains(groupedValues, "  serviceAccountName: \"eso-sa-a-research-viewer-1b04590771\"") ||
		!strings.Contains(groupedValues, "  role: \"portal-group-app-eso\"") ||
		!strings.Contains(groupedValues, "      remotePath: \"apps/research/beta/workloads/app-mobility/eso-sa-a-research-viewer-1b04590771\"") ||
		strings.Contains(groupedValues, "    - \"research-viewer-user\"") {
		t.Fatalf("AppGroup OIDC 허용 그룹이 group 경계를 포함하지 않음:\n%s", groupedValues)
	}

	// 인증이 없는 앱에는 OIDC 관련 값이 하나도 없어야 한다.
	plain := profileFromJSON(t, validInput("public"))
	if errors := validateInput(&plain); len(errors) > 0 {
		t.Fatalf("검증 실패: %+v", errors)
	}
	plainValues := renderValuesYAML(deploymentRequest{
		ID: "0123456789abcdef", Profile: validationResult(plain, true).Profile,
	})
	for _, forbidden := range []string{"oidc-client", "allowedGroups", "createSecretStore: true"} {
		if strings.Contains(plainValues, forbidden) {
			t.Fatalf("인증 없는 앱에 %q 가 남았다:\n%s", forbidden, plainValues)
		}
	}
}

/* ------------------------------ Compose ------------------------------ */

const composeStack = `
services:
  frontend:
    image: registry.example/frontend:1.2.3
    ports:
      - "3000:3000"
    depends_on:
      - api
  api:
    image: registry.example/api:1.2.3
    expose:
      - "8080"
    depends_on:
      - postgres
      - redis
  postgres:
    image: docker.io/library/postgres:16
    expose:
      - 5432
  redis:
    image: docker.io/library/redis:7.2
    expose:
      - 6379
`

func TestParseComposeStack(t *testing.T) {
	parsed, err := parseCompose(composeStack)
	if err != nil {
		t.Fatalf("compose 해석 실패: %v", err)
	}
	if len(parsed.Services) != 4 {
		t.Fatalf("서비스 수=%d (기대 4)", len(parsed.Services))
	}
	// 의존 대상이 먼저, 같은 단계는 이름순이다.
	wantOrder := []string{"postgres", "redis", "api", "frontend"}
	for index, want := range wantOrder {
		if parsed.Services[index].Name != want {
			t.Fatalf("서비스 순서[%d]=%s want=%s: %+v", index, parsed.Services[index].Name, want, parsed.Services)
		}
	}
	byName := make(map[string]composeService, len(parsed.Services))
	for _, service := range parsed.Services {
		byName[service.Name] = service
	}
	api := byName["api"]
	if api.Image != "registry.example/api:1.2.3" || api.Port != 8080 {
		t.Fatalf("api 서비스 해석이 다르다: %+v", api)
	}
	frontend := byName["frontend"]
	// "3000:3000" 은 host:container 다. 컨테이너 쪽만 쓴다.
	if frontend.Port != 3000 || frontend.Image != "registry.example/frontend:1.2.3" {
		t.Fatalf("frontend 서비스 해석이 다르다: %+v", frontend)
	}
	postgres := byName["postgres"]
	if postgres.Image != "docker.io/library/postgres:16" || postgres.Port != 5432 {
		t.Fatalf("postgres 서비스 해석이 다르다: %+v", postgres)
	}
}

func TestComposeRejectsBuildToProtectPipelineCredentials(t *testing.T) {
	for _, document := range []string{
		"services:\n  api:\n    build: .\n    expose: [8080]\n",
		"services:\n  api:\n    build:\n      context: services/api\n      dockerfile: Dockerfile\n    expose: [8080]\n",
	} {
		if _, err := parseCompose(document); err == nil || !strings.Contains(err.Error(), "credential") {
			t.Fatalf("Compose build가 통과함: %v", err)
		}
	}
}

func TestAppGroupAPIRejectsLegacyBuildCoordinates(t *testing.T) {
	body := strings.TrimSuffix(appGroupRequestBody(t, "nginx:1.27"), "}") +
		`,"gitRepository":"https://forgejo.example/research/app.git","branch":"main"}`
	request := httptest.NewRequest(http.MethodPost, "/api/v1/app-groups/validate", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(requesterHeader, "owner@example.invalid")
	recorder := httptest.NewRecorder()
	newHandler(&apiServer{}).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest || !strings.Contains(recorder.Body.String(), "알 수 없는 필드") {
		t.Fatalf("Compose Git/build 좌표 status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestComposeRejectsForbiddenKeys(t *testing.T) {
	for name, document := range map[string]string{
		"host network": "services:\n  app:\n    image: nginx:1.27\n    network_mode: host\n    expose:\n      - 80\n",
		"bind mount":   "services:\n  app:\n    image: nginx:1.27\n    expose:\n      - 80\n    volumes:\n      - /etc:/host-etc\n",
		"privileged":   "services:\n  app:\n    image: nginx:1.27\n    expose:\n      - 80\n    privileged: true\n",
		"top volumes":  "volumes:\n  data: {}\nservices:\n  app:\n    image: nginx:1.27\n    expose:\n      - 80\n",
	} {
		if _, err := parseCompose(document); err == nil {
			t.Fatalf("%s 가 거부되지 않았다", name)
		}
	}
}

func TestComposePortlessWorkerHasNoServiceOrProbe(t *testing.T) {
	input := appGroupInput{
		Group: "jobs", Project: "research", Environment: appEnvironment,
		Compose:      "services:\n  worker:\n    image: registry.example/worker:1.2.3\n",
		ResourceSize: "small",
	}
	profiles, warnings, errs := buildGroupProfiles(&input)
	if len(errs) != 0 || len(profiles) != 1 {
		t.Fatalf("worker 검증 실패: profiles=%+v errors=%+v", profiles, errs)
	}
	if profiles[0].WorkloadMode != workloadWorker || profiles[0].ContainerPort != 0 {
		t.Fatalf("포트 없는 서비스가 worker로 정규화되지 않음: %+v", profiles[0])
	}
	if len(warnings) == 0 || !strings.Contains(strings.Join(warnings, " "), "worker") {
		t.Fatalf("worker 변환 경고 누락: %v", warnings)
	}
	normalized := validationResult(profiles[0], true).Profile
	if normalized.serviceEnabled() || normalized.Exposure.Mode != exposureInternal {
		t.Fatalf("worker가 Service/external로 열림: %+v", normalized)
	}
	if normalized.Service.InternalAddress != "" {
		t.Fatalf("Service 없는 worker에 내부 주소가 생김: %q", normalized.Service.InternalAddress)
	}
	encoded, err := json.Marshal(normalized)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), `"internalAddress"`) {
		t.Fatalf("worker 응답에 internalAddress가 포함됨: %s", encoded)
	}
	values := renderValuesYAML(deploymentRequest{ID: "worker-request", Profile: normalized})
	for _, required := range []string{"service:\n  enabled: false\n  port: 0", "    type: \"none\""} {
		if !strings.Contains(values, required) {
			t.Fatalf("worker values에 %q 누락:\n%s", required, values)
		}
	}
}

func TestComposeNamedVolumeBecomesContractBoundRwoPVC(t *testing.T) {
	oldSize, oldClass := appGroupVolumeSize, appGroupVolumeStorageClass
	appGroupVolumeSize, appGroupVolumeStorageClass = "5Gi", "approved-class"
	t.Cleanup(func() {
		appGroupVolumeSize, appGroupVolumeStorageClass = oldSize, oldClass
	})
	input := appGroupInput{
		Group: "data-stack", Project: "research", Environment: appEnvironment,
		Compose:      "volumes:\n  pgdata: {}\nservices:\n  postgres:\n    image: docker.io/library/postgres:16\n    expose:\n      - 5432\n    volumes:\n      - pgdata:/var/lib/postgresql/data\n",
		ResourceSize: "small",
		Services:     []appGroupServiceInput{{Name: "postgres", Replicas: 1}},
	}
	profiles, _, errs := buildGroupProfiles(&input)
	if len(errs) != 0 || len(profiles) != 1 {
		t.Fatalf("named volume 검증 실패: profiles=%+v errors=%+v", profiles, errs)
	}
	normalized := validationResult(profiles[0], true).Profile
	if !normalized.Persistence.Enabled || normalized.Persistence.MountPath != "/var/lib/postgresql/data" ||
		normalized.Persistence.Size != "5Gi" || normalized.Persistence.StorageClass != "approved-class" {
		t.Fatalf("PVC 계약 정규화 불일치: %+v", normalized.Persistence)
	}
	values := renderValuesYAML(deploymentRequest{ID: "volume-request", Profile: normalized})
	for _, required := range []string{
		"persistence:\n  enabled: true", "  accessMode: \"ReadWriteOnce\"",
		"  size: \"5Gi\"", "  storageClass: \"approved-class\"",
		"  mountPath: \"/var/lib/postgresql/data\"", "  keepOnDelete: false",
	} {
		if !strings.Contains(values, required) {
			t.Fatalf("PVC values에 %q 누락:\n%s", required, values)
		}
	}
}

func TestComposeNamedVolumeRejectsUnsafeOrSharedMounts(t *testing.T) {
	tests := map[string]string{
		"external":    "volumes:\n  data:\n    external: true\nservices:\n  app:\n    image: nginx:1.27\n    expose: [80]\n    volumes: [data:/data]\n",
		"bind":        "services:\n  app:\n    image: nginx:1.27\n    expose: [80]\n    volumes: [/host:/data]\n",
		"shared":      "volumes:\n  data: {}\nservices:\n  one:\n    image: nginx:1.27\n    expose: [80]\n    volumes: [data:/data]\n  two:\n    image: nginx:1.27\n    expose: [81]\n    volumes: [data:/data]\n",
		"system path": "volumes:\n  data: {}\nservices:\n  app:\n    image: nginx:1.27\n    expose: [80]\n    volumes: [data:/etc]\n",
	}
	for name, document := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseCompose(document); err == nil {
				t.Fatalf("위험한 volume이 통과함: %s", document)
			}
		})
	}
}

func TestDestructivePersistenceChangeDetectsDisableAndMountMove(t *testing.T) {
	live := normalizedProfile{}
	live.Persistence.Enabled = true
	live.Persistence.MountPath = "/var/lib/postgresql/data"

	disabled := live
	disabled.Persistence.Enabled = false
	if _, destructive := destructivePersistenceChange(live, disabled); !destructive {
		t.Fatal("persistence enabled→disabled 변경이 감지되지 않음")
	}

	moved := live
	moved.Persistence.MountPath = "/data"
	if _, destructive := destructivePersistenceChange(live, moved); !destructive {
		t.Fatal("persistence mountPath 변경이 감지되지 않음")
	}

	unchanged := live
	if reason, destructive := destructivePersistenceChange(live, unchanged); destructive {
		t.Fatalf("동일 persistence 재배포가 거부됨: %s", reason)
	}
}

func TestAppGroupRedeployCannotPruneLivePVC(t *testing.T) {
	_, forgejo := newFakeForgejo(t)
	api, handler := newTestAPI(t, forgejo)
	requester := "owner@example.invalid"
	live := sampleRequest("existing-volume", stateDeployed)
	live.Requester = requester
	live.Profile.App.Name = "api"
	live.Profile.App.Group = "stack"
	live.Profile.App.Project = "research"
	live.Profile.App.Environment = "beta"
	live.Profile.Persistence.Enabled = true
	live.Profile.Persistence.MountPath = "/data"
	if err := api.store.create(live, "", ""); err != nil {
		t.Fatalf("기존 PVC 앱 seed 실패: %v", err)
	}

	body := appGroupRequestBody(t, "nginx:1.27")
	call := func(path string, create bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(requesterHeader, requester)
		if create {
			req.Header.Set("Idempotency-Key", "disable-live-pvc")
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		return recorder
	}

	validation := call("/api/v1/app-groups/validate", false)
	if validation.Code != http.StatusUnprocessableEntity ||
		!strings.Contains(validation.Body.String(), "services.api.persistence") {
		t.Fatalf("PVC 제거 사전검증 status=%d body=%s", validation.Code, validation.Body.String())
	}
	creation := call("/api/v1/app-groups", true)
	if creation.Code != http.StatusConflict ||
		!strings.Contains(creation.Body.String(), "persistence-change") {
		t.Fatalf("PVC 제거 생성 차단 status=%d body=%s", creation.Code, creation.Body.String())
	}
}

func TestComposeWorkerCannotBeInboundConnectionTarget(t *testing.T) {
	input := appGroupInput{
		Group: "jobs", Project: "research", Environment: appEnvironment,
		Compose:      "services:\n  api:\n    image: nginx:1.27\n    expose: [8080]\n  worker:\n    image: registry.example/worker:1.2.3\n",
		ResourceSize: "small",
		Services: []appGroupServiceInput{{
			Name: "api", NetworkPolicy: networkPolicyInput{
				AllowedApps: []appPeerInput{{App: "worker", Port: 9000}},
			},
		}},
	}
	_, _, errs := buildGroupProfiles(&input)
	if !hasFieldError(errs, "services.api.networkPolicy.allowedApps[0]") {
		t.Fatalf("worker가 수신 연결 대상으로 허용됨: %+v", errs)
	}
}

func TestComposeRejectsSecretLookingEnvironment(t *testing.T) {
	for name, environment := range map[string]string{
		"secret key":     "DB_PASSWORD: hunter2",
		"database url":   "DATABASE_URL: postgres://db.internal/app",
		"credential uri": "ENDPOINT: postgres://user:password@postgres/app",
		"access key":     "AWS_ACCESS_KEY_ID: AKIATESTVALUE",
		"generic key":    "APP_VALUE: super-secret-password",
	} {
		t.Run(name, func(t *testing.T) {
			document := "services:\n  app:\n    image: nginx:1.27\n    expose:\n      - 80\n    environment:\n      " + environment + "\n"
			_, err := parseCompose(document)
			if err == nil || !strings.Contains(err.Error(), "OpenBao") {
				t.Fatalf("평문 Secret 이 거부되지 않았다: %v", err)
			}
		})
	}
}

func TestComposeRejectsCaseVariantsUnknownUDPAndNormalizedDuplicates(t *testing.T) {
	tests := map[string]string{
		"lowercase secret": "services:\n  app:\n    image: nginx:1.27\n    expose:\n      - 80\n    environment:\n      db_password: hunter2\n",
		"unknown key":      "services:\n  app:\n    image: nginx:1.27\n    expose:\n      - 80\n    command: nginx\n",
		"udp port":         "services:\n  app:\n    image: nginx:1.27\n    ports:\n      - 53:53/udp\n",
		"multiple ports":   "services:\n  app:\n    image: nginx:1.27\n    ports:\n      - 8080:80\n      - 8443:443\n",
		"ports and expose": "services:\n  app:\n    image: nginx:1.27\n    expose:\n      - 80\n    ports:\n      - 8080:80\n",
		"duplicate name":   "services:\n  API:\n    image: nginx:1.27\n    expose:\n      - 80\n  api:\n    image: nginx:1.27\n    expose:\n      - 80\n",
		"dependency cycle": "services:\n  api:\n    image: nginx:1.27\n    expose:\n      - 80\n    depends_on:\n      - db\n  db:\n    image: postgres:16\n    expose:\n      - 5432\n    depends_on:\n      - api\n",
	}
	for name, document := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseCompose(document); err == nil {
				t.Fatalf("%s 입력이 거부되지 않았다", name)
			}
		})
	}
}

// Compose 서비스 하나가 AppProfile 하나가 되어야 한다(한 Pod 에 몰아넣지 않는다).
func TestBuildGroupProfilesSplitsEveryService(t *testing.T) {
	input := appGroupInput{
		Group:        "mobility-platform",
		Project:      "research",
		Environment:  "beta",
		Compose:      composeStack,
		ResourceSize: "small",
		Services: []appGroupServiceInput{
			{
				Name:           "frontend",
				Exposure:       exposureInput{Mode: exposureExternal},
				Authentication: authenticationInput{Mode: authOIDC},
				NetworkPolicy: networkPolicyInput{
					EgressMode:  egressWeb,
					AllowedApps: []appPeerInput{{App: "api", Port: 8080}},
				},
			},
			{
				Name:     "api",
				Exposure: exposureInput{Mode: exposureInternal},
				NetworkPolicy: networkPolicyInput{
					EgressMode: egressWeb,
					AllowedApps: []appPeerInput{
						{App: "postgres", Port: 5432},
						{App: "redis", Port: 6379},
					},
					Ingress: ingressInput{AllowedApps: []appPeerInput{{App: "frontend", Port: 8080}}},
				},
			},
			{
				Name:     "postgres",
				Exposure: exposureInput{Mode: exposureInternal},
				NetworkPolicy: networkPolicyInput{
					EgressMode: egressBlocked,
					Ingress:    ingressInput{AllowedApps: []appPeerInput{{App: "api", Port: 5432}}},
				},
			},
			{Name: "redis", Exposure: exposureInput{Mode: exposureInternal}},
		},
	}
	profiles, _, errors := buildGroupProfiles(&input)
	if len(errors) > 0 {
		t.Fatalf("그룹 검증 실패: %+v", errors)
	}
	if len(profiles) != 4 {
		t.Fatalf("AppProfile 수=%d (기대 4)", len(profiles))
	}
	byName := map[string]appProfileInput{}
	for _, profile := range profiles {
		byName[profile.AppName] = profile
	}
	if byName["frontend"].Image == "" || byName["frontend"].GitRepository != "" {
		t.Fatalf("prebuilt 서비스에 Git build 입력이 붙었다: %+v", byName["frontend"])
	}
	if byName["postgres"].GitRepository != "" || byName["postgres"].Image == "" {
		t.Fatalf("image 서비스에 Git 소스가 붙었다: %+v", byName["postgres"])
	}
	// 선택을 주지 않은 redis 는 가장 좁은 값이어야 한다.
	if byName["redis"].NetworkPolicy.EgressMode != egressBlocked {
		t.Fatalf("기본 egress가 blocked가 아니다: %s", byName["redis"].NetworkPolicy.EgressMode)
	}
	values := renderValuesYAML(deploymentRequest{
		ID:      "0123456789abcdef",
		Profile: validationResult(byName["api"], true).Profile,
	})
	for _, required := range []string{
		"  group: \"mobility-platform\"",
		"  egressMode: \"web\"",
		"    - app: \"postgres\"",
		"      port: 5432",
		"  ingress:\n    enabled: true",
		"      - app: \"frontend\"",
	} {
		if !strings.Contains(values, required) {
			t.Fatalf("그룹 values에 %q 가 없음:\n%s", required, values)
		}
	}
}

// Compose 에 없는 앱을 가리키는 연결은 조용히 만들어지면 안 된다.
func TestGroupPeerMustExistInCompose(t *testing.T) {
	input := appGroupInput{
		Group: "stack", Project: "research", Environment: "beta",
		Compose:      "services:\n  api:\n    image: nginx:1.27\n    expose:\n      - 8080\n",
		ResourceSize: "small",
		Services: []appGroupServiceInput{{
			Name:     "api",
			Exposure: exposureInput{Mode: exposureInternal},
			NetworkPolicy: networkPolicyInput{
				AllowedApps: []appPeerInput{{App: "postgres", Port: 5432}},
			},
		}},
	}
	_, _, errors := buildGroupProfiles(&input)
	if !hasFieldError(errors, "services.api.networkPolicy.allowedApps[0]") {
		t.Fatalf("없는 서비스 연결이 통과했다: %+v", errors)
	}
}

func TestGroupPeerPortsMustMatchServicePorts(t *testing.T) {
	input := appGroupInput{
		Group: "stack", Project: "research", Environment: "beta",
		Compose:      "services:\n  api:\n    image: nginx:1.27\n    expose:\n      - 8080\n  db:\n    image: postgres:16\n    expose:\n      - 5432\n",
		ResourceSize: "small",
		Services: []appGroupServiceInput{
			{Name: "api", Exposure: exposureInput{Mode: exposureInternal}, NetworkPolicy: networkPolicyInput{
				AllowedApps: []appPeerInput{{App: "db", Port: 443}},
			}},
			{Name: "db", Exposure: exposureInput{Mode: exposureInternal}, NetworkPolicy: networkPolicyInput{
				Ingress: ingressInput{AllowedApps: []appPeerInput{{App: "api", Port: 8080}}},
			}},
		},
	}
	_, _, errors := buildGroupProfiles(&input)
	if !hasFieldError(errors, "services.api.networkPolicy.allowedApps[0].port") ||
		!hasFieldError(errors, "services.db.networkPolicy.ingress.allowedApps[0].port") {
		t.Fatalf("서비스 포트와 다른 연결이 통과했다: %+v", errors)
	}
}

func TestGroupSecretKeysDeclareNamesWithoutValues(t *testing.T) {
	input := appGroupInput{
		Group: "stack", Project: "research", Environment: "beta",
		Compose:      "services:\n  db:\n    image: postgres:16\n    expose:\n      - 5432\n",
		ResourceSize: "small",
		Services: []appGroupServiceInput{{
			Name: "db", Exposure: exposureInput{Mode: exposureInternal},
			SecretKeys: []string{"POSTGRES_PASSWORD"},
		}},
	}
	profiles, _, errors := buildGroupProfiles(&input)
	if len(errors) > 0 {
		t.Fatalf("Secret key 선언 실패: %+v", errors)
	}
	profile := validationResult(profiles[0], true).Profile
	if len(profile.Configuration.SecretKeys) != 1 || profile.Configuration.SecretKeys[0] != "POSTGRES_PASSWORD" {
		t.Fatalf("Secret key가 프로필로 전달되지 않음: %+v", profile.Configuration)
	}
	if _, leaked := profile.Configuration.Config["POSTGRES_PASSWORD"]; leaked {
		t.Fatal("Secret 값이 ConfigMap에 들어갔다")
	}

}

// AppGroup Namespace 이름은 Chart/Argo AppProject 와 같은 규칙이어야 한다.
func TestGroupArtifactsUseSameNamespace(t *testing.T) {
	group := newAppGroup("mobility-platform", "research", "beta")
	if group.Namespace != "app-mobility-platform" {
		t.Fatalf("Namespace=%s", group.Namespace)
	}
	if got, want := groupApplicationPath(group), "argocd/applications/ag-mobility-platform-beta-64960bc5b2.yaml"; got != want {
		t.Fatalf("그룹 Application 경로=%q, want %q", got, want)
	}
	values := renderGroupValuesYAML(group, "0123456789abcdef", "2026-01-01T00:00:00Z")
	if !strings.Contains(values, "  name: \"mobility-platform\"") ||
		!strings.Contains(values, "  namespacePrefix: \"app-\"") ||
		!strings.Contains(values, "defaultDeny:\n  ingress: true\n  egress: true") {
		t.Fatalf("그룹 values가 예상과 다르다:\n%s", values)
	}
	application := renderGroupArgoApplicationYAML(group, "https://forgejo.example/root/repo", "main")
	for _, required := range []string{
		"  name: \"ag-mobility-platform-beta-64960bc5b2\"",
		"    argocd.argoproj.io/sync-wave: \"-10\"",
		"  project: \"app-groups\"",
		"      path: \"charts/app-group\"",
		"    namespace: \"app-mobility-platform\"",
		"      - \"CreateNamespace=false\"",
		"kind: \"Deployment\"\n      jqPathExpressions:\n        - \".status.terminatingReplicas\"",
		"kind: \"ReplicaSet\"\n      jqPathExpressions:\n        - \".status.terminatingReplicas\"",
	} {
		if !strings.Contains(application, required) {
			t.Fatalf("그룹 Application에 %q 가 없음:\n%s", required, application)
		}
	}
}

func TestTypedGlobalNamesAreInjectiveAndStable(t *testing.T) {
	first := normalizedProfile{}
	first.App.Project = "research"
	first.App.Environment = "beta"
	first.App.Group = "x-app-y"
	first.App.Name = "z"
	second := normalizedProfile{}
	second.App.Project = "research"
	second.App.Environment = "beta"
	second.App.Group = "x"
	second.App.Name = "y-app-z"

	if canonicalAppID(first) == canonicalAppID(second) {
		t.Fatal("서로 다른 AppGroup/app tuple의 canonical ID가 같다")
	}
	for label, names := range map[string][2]string{
		"application": {appApplicationName(first), appApplicationName(second)},
		"git-path":    {appApplicationPath(first), appApplicationPath(second)},
		"host":        {externalHostLabel(first), externalHostLabel(second)},
		"oidc-client": {oidcClientID(first), oidcClientID(second)},
		"oidc-group":  {oidcAllowedGroup(first), oidcAllowedGroup(second)},
	} {
		if names[0] == names[1] {
			t.Fatalf("%s typed name 충돌: %q", label, names[0])
		}
		if len(names[0]) > 63 || len(names[1]) > 63 {
			t.Fatalf("%s typed name이 63자를 넘음: %#v", label, names)
		}
	}
	if got := typedDNSName("aa-", "mobility-platform-api-prod",
		"v1/app/research/prod/mobility-platform/api"); got != "aa-mobility-platform-api-prod-2b6eeb3085" {
		t.Fatalf("Go/Helm golden typed name=%q", got)
	}

	// 절단 지점에 연속 '-'가 와도 hash 앞 human slug가 '-'로 끝나면 DNS label이 깨진다.
	trimmed := typedDNSName("aa-", strings.Repeat("a", 48)+"---tail",
		"v1/app/research/beta/group/app")
	if strings.Contains(trimmed, "--") || !appNamePattern.MatchString(trimmed) || len(trimmed) > 63 {
		t.Fatalf("연속 dash 절단 결과가 DNS 이름이 아님: %q", trimmed)
	}
}

func TestGroupBootstrapAndAppApplicationPathsCannotCollide(t *testing.T) {
	group := newAppGroup("x-app-y", "research", "beta")
	profile := normalizedProfile{}
	profile.App.Project = "research"
	profile.App.Environment = "beta"
	profile.App.Group = "x"
	profile.App.Name = "y"
	if groupApplicationPath(group) == appApplicationPath(profile) ||
		groupApplicationName(group) == appApplicationName(profile) {
		t.Fatalf("group bootstrap과 app Application이 충돌: %s / %s",
			groupApplicationPath(group), appApplicationPath(profile))
	}
}

func hasFieldError(errors []fieldError, field string) bool {
	for _, item := range errors {
		if item.Field == field {
			return true
		}
	}
	return false
}
