package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func request(t *testing.T, method, target, body, contentType string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	recorder := httptest.NewRecorder()
	newHandler(&apiServer{}).ServeHTTP(recorder, req)
	return recorder
}

// newTestAPI는 임시 디렉터리 저장소와 가짜 Forgejo 서버를 붙인 핸들러를 만든다.
func newTestAPI(t *testing.T, forgejo *forgejoClient) (*apiServer, http.Handler) {
	t.Helper()
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	t.Cleanup(func() { _ = requestStore.close() })
	api := &apiServer{store: requestStore, forgejo: forgejo}
	if forgejo != nil {
		forgejo.store = requestStore
	}
	return api, newHandler(api)
}

func validInput(exposure string) string {
	return `{
  "appName":"research-viewer",
  "project":"research",
  "environment":"beta",
  "gitRepository":"https://forgejo.example/research/research-viewer.git",
  "branch":"main",
  "dockerfile":"Dockerfile",
  "containerPort":8080,
  "exposure":"` + exposure + `",
  "resourceSize":"small"
}`
}

func TestHealthAndSecurityHeaders(t *testing.T) {
	recorder := request(t, http.MethodGet, "/api/v1/health", "", "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	csp := recorder.Header().Get("Content-Security-Policy")
	if csp != "default-src 'none'; frame-ancestors 'none'" {
		t.Fatalf("API CSP 불일치: %s", csp)
	}
	if recorder.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("no-store가 없다")
	}
}

func TestCatalogHasNoInfrastructureSecrets(t *testing.T) {
	recorder := request(t, http.MethodGet, "/api/v1/catalog", "", "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d", recorder.Code)
	}
	body := recorder.Body.String()
	for _, forbidden := range []string{"password", "root_token", "clientSecret"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("catalog에 금지 문자열 %q 포함", forbidden)
		}
	}
	var catalog catalogResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &catalog); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(body, `"forgejoConnected":false`) {
		t.Fatalf("catalog Forgejo 필드 계약 불일치: %s", body)
	}
	if catalog.SubmissionEnabled || catalog.SecretInputAllowed || len(catalog.Templates) != 2 {
		t.Fatalf("예상하지 않은 catalog 상태: %+v", catalog)
	}
	seen := map[string]bool{}
	for _, template := range catalog.Templates {
		seen[template.Exposure] = true
	}
	if !seen["public"] || !seen["oidc"] {
		t.Fatalf("public/oidc 템플릿 누락: %+v", seen)
	}
}

// 위자드 선택지는 catalog 하나만 보고 그려야 한다. 목록이 비면 UI가 목데이터로 되돌아간다.
func TestCatalogCarriesWizardOptions(t *testing.T) {
	recorder := request(t, http.MethodGet, "/api/v1/catalog", "", "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d", recorder.Code)
	}
	var catalog catalogResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &catalog); err != nil {
		t.Fatal(err)
	}
	if len(catalog.Projects) == 0 || catalog.Projects[0] != allowedProjects[0] {
		t.Fatalf("catalog projects가 서버 허용 목록과 다르다: %+v vs %+v", catalog.Projects, allowedProjects)
	}
	if catalog.UserQuota.CPU != defaultUserQuotaCPU || catalog.UserQuota.Memory != defaultUserQuotaMemory {
		t.Fatalf("catalog userQuota 불일치: %+v", catalog.UserQuota)
	}
	if catalog.MaxReplicas != maxAppReplicas {
		t.Fatalf("catalog maxReplicas 불일치: %d", catalog.MaxReplicas)
	}
	if catalog.AppGroups.MaxServices > catalog.MaxReplicas {
		t.Fatalf("AppGroup 서비스 상한 %d가 Namespace Pod 상한 %d보다 큼",
			catalog.AppGroups.MaxServices, catalog.MaxReplicas)
	}
	if len(catalog.ResourcePresets) == 0 {
		t.Fatal("resourcePresets가 비었다")
	}
}

func TestValidatePublicProfile(t *testing.T) {
	recorder := request(t, http.MethodPost, "/api/v1/app-profiles/validate", validInput("public"), "application/json")
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var result validationResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Generated.ValuesTemplate != "apps/_template/values-public.yaml" || result.Generated.ExpectedAnonymous != http.StatusOK {
		t.Fatalf("public plan 불일치: %+v", result.Generated)
	}
	if result.Generated.KeycloakClientID != "" || result.Profile.Exposure.Host != "research-viewer."+baseDomain {
		t.Fatalf("public 결과 불일치: %+v", result)
	}
	if want := "research-viewer." + zoneNamespace() + ".svc:8080"; result.Profile.Service.InternalAddress != want {
		t.Fatalf("내부 Service DNS=%q, want %q", result.Profile.Service.InternalAddress, want)
	}
}

func TestValidateOIDCProfile(t *testing.T) {
	recorder := request(t, http.MethodPost, "/api/v1/app-profiles/validate", validInput("oidc"), "application/json; charset=utf-8")
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var result validationResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Generated.ValuesTemplate != "apps/_template/values-sso.yaml" || result.Generated.KeycloakClientID != "research-viewer-"+appEnvironment || result.Generated.ExpectedAnonymous != http.StatusFound {
		t.Fatalf("oidc plan 불일치: %+v", result.Generated)
	}
	if result.Generated.OIDCCallbackURL != "https://research-viewer."+baseDomain+"/oauth2/callback" {
		t.Fatalf("callback 불일치: %s", result.Generated.OIDCCallbackURL)
	}
}

func TestValidationErrorsUseProblemDetails(t *testing.T) {
	bad := strings.Replace(validInput("public"), `"appName":"research-viewer"`, `"appName":"Bad_Name"`, 1)
	recorder := request(t, http.MethodPost, "/api/v1/app-profiles/validate", bad, "application/json")
	if recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get("Content-Type") != "application/problem+json" {
		t.Fatalf("content-type=%s", recorder.Header().Get("Content-Type"))
	}
	var result problem
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Status != http.StatusUnprocessableEntity || len(result.Errors) != 1 || result.Errors[0].Field != "appName" {
		t.Fatalf("problem 불일치: %+v", result)
	}
}

func TestAllPolicyFieldsAreRejectedTogether(t *testing.T) {
	body := `{
  "appName":"Bad_Name",
  "project":"other",
  "environment":"prod",
  "gitRepository":"https://user:token@forgejo.example/repo.git?token=bad",
  "branch":"../main",
  "dockerfile":"../Dockerfile",
  "containerPort":70000,
  "exposure":"private",
  "resourceSize":"large"
}`
	recorder := request(t, http.MethodPost, "/api/v1/app-profiles/validate", body, "application/json")
	if recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var result problem
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Errors) != 9 {
		t.Fatalf("errors=%d body=%s", len(result.Errors), recorder.Body.String())
	}
}

func TestUnknownJSONFieldIsRejected(t *testing.T) {
	body := strings.TrimSuffix(validInput("public"), "}") + `,"secret":"do-not-send"}`
	recorder := request(t, http.MethodPost, "/api/v1/app-profiles/validate", body, "application/json")
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestPayloadAndContentTypeLimits(t *testing.T) {
	tooLarge := `{"appName":"` + strings.Repeat("a", maxJSONBody) + `"}`
	recorder := request(t, http.MethodPost, "/api/v1/app-profiles/validate", tooLarge, "application/json")
	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("large status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	recorder = request(t, http.MethodPost, "/api/v1/app-profiles/validate", validInput("public"), "text/plain")
	if recorder.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("media status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestDeploymentRequestIsUnavailableUntilForgejoCutover(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(requesterHeader, "owner@example.invalid")
	recorder := httptest.NewRecorder()
	newHandler(&apiServer{}).ServeHTTP(recorder, req)
	if recorder.Code != http.StatusServiceUnavailable || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("status=%d retry-after=%q", recorder.Code, recorder.Header().Get("Retry-After"))
	}
	if !strings.Contains(recorder.Body.String(), "FORGEJO_BOT_TOKEN") {
		t.Fatalf("공용 Forgejo 봇 준비 오류가 조치 가능한 설명을 주지 않음: %s", recorder.Body.String())
	}
}

func TestOpenAPIAndUnknownRoute(t *testing.T) {
	spec := request(t, http.MethodGet, "/api/v1/openapi.yaml", "", "")
	if spec.Code != http.StatusOK || !strings.Contains(spec.Body.String(), "openapi: 3.1.1") ||
		!strings.Contains(spec.Body.String(), "operationId: deleteDeploymentRequest") ||
		!strings.Contains(spec.Body.String(), "operationId: updateDeploymentRuntimeState") {
		t.Fatalf("openapi status=%d", spec.Code)
	}
	unknown := request(t, http.MethodGet, "/", "", "")
	if unknown.Code != http.StatusNotFound {
		t.Fatalf("API 서버가 UI route를 제공함: %d", unknown.Code)
	}
}

func TestAPIListenAddressMatchesTrustedBFFOrigin(t *testing.T) {
	tests := []struct {
		addr string
		ok   bool
	}{
		{addr: "127.0.0.1:8081", ok: true},
		{addr: "127.42.0.1:8081"},
		{addr: "[::1]:8081"},
		{addr: "127.0.0.1:9090"},
		{addr: "0.0.0.0:8081"},
		{addr: "[::]:8081"},
		{addr: "10.0.0.10:8081"},
		{addr: "localhost:8081"},
		{addr: ":8081"},
		{addr: "127.0.0.1"},
	}
	for _, test := range tests {
		t.Run(test.addr, func(t *testing.T) {
			err := validateAPIListenAddress(test.addr)
			if (err == nil) != test.ok {
				t.Fatalf("validateAPIListenAddress(%q) error=%v, ok=%t", test.addr, err, test.ok)
			}
		})
	}
}
