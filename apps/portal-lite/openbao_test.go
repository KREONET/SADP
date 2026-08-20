package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestOpenBaoClientUsesKubernetesLoginAndWritesKVv2(t *testing.T) {
	jwtPath := t.TempDir() + "/token"
	if err := os.WriteFile(jwtPath, []byte("projected-jwt\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var calls []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		calls = append(calls, r.Method+" "+r.URL.Path+" "+string(body))
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/v1/auth/kubernetes/login" {
			_, _ = w.Write([]byte(`{"auth":{"client_token":"user-scoped-token","lease_duration":900}}`))
			return
		}
		if r.Header.Get("X-Vault-Token") != "user-scoped-token" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.Method == http.MethodPatch {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	baseURL, _ := url.Parse(server.URL)
	client := &openBaoClient{
		baseURL: baseURL, http: server.Client(), jwtPath: jwtPath,
		role: "portal-app-secret-writer", expires: time.Time{},
	}
	// 구버전 PVC 레코드는 mount 접두사까지 포함했다. retry는 같은 logical KV 문서에 써야 한다.
	if err := client.put(context.Background(), "kv/apps/research/prod/my-app", map[string]string{"API_TOKEN": "secret-value"}); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 3 || !strings.HasPrefix(calls[0], "POST /v1/auth/kubernetes/login ") ||
		!strings.HasPrefix(calls[1], "PATCH /v1/kv/data/apps/research/prod/my-app ") ||
		!strings.HasPrefix(calls[2], "POST /v1/kv/data/apps/research/prod/my-app ") {
		t.Fatalf("예상하지 못한 OpenBao 호출: %#v", calls)
	}
	var payload struct {
		Data map[string]string `json:"data"`
	}
	if err := json.Unmarshal([]byte(strings.SplitN(calls[2], " ", 3)[2]), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Data["API_TOKEN"] != "secret-value" {
		t.Fatalf("KV v2 payload 불일치: %#v", payload.Data)
	}
}

func TestOpenBaoKVv2MergePatchPreservesUnsubmittedKeys(t *testing.T) {
	jwtPath := t.TempDir() + "/token"
	if err := os.WriteFile(jwtPath, []byte("projected-jwt\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var methods []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/auth/kubernetes/login" {
			_, _ = w.Write([]byte(`{"auth":{"client_token":"token","lease_duration":900}}`))
			return
		}
		methods = append(methods, r.Method)
		if got := r.Header.Get("Content-Type"); got != "application/merge-patch+json" {
			t.Errorf("Content-Type=%q", got)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	baseURL, _ := url.Parse(server.URL)
	client := &openBaoClient{baseURL: baseURL, http: server.Client(), jwtPath: jwtPath, role: "writer"}
	if err := client.put(context.Background(), "apps/research/prod/my-app", map[string]string{"NEW_KEY": "value"}); err != nil {
		t.Fatal(err)
	}
	if len(methods) != 1 || methods[0] != http.MethodPatch {
		t.Fatalf("기존 KV에서 create POST가 호출됨: %#v", methods)
	}
}

// esoProfile은 Chart가 기대하는 이름과 맞물리는지만 보는 최소 프로필이다.
func esoProfile(project, environment, name string) normalizedProfile {
	var profile normalizedProfile
	profile.App.Project = project
	profile.App.Environment = environment
	profile.App.Name = name
	return profile
}

func testWorkloadPolicy(project, environment string) string {
	const accessor = "auth_kubernetes_test_accessor"
	return fmt.Sprintf(`path "kv/data/apps/%s/%s/workloads/{{identity.entity.aliases.%s.metadata.service_account_namespace}}/{{identity.entity.aliases.%s.metadata.service_account_name}}" {
  capabilities = ["read"]
}
path "kv/metadata/apps/%s/%s/workloads/{{identity.entity.aliases.%s.metadata.service_account_namespace}}/{{identity.entity.aliases.%s.metadata.service_account_name}}" {
  capabilities = ["read"]
}`, project, environment, accessor, accessor, project, environment, accessor, accessor)
}

func testRegistryPolicy(remotePath string) string {
	return fmt.Sprintf(`path "kv/data/%s" { capabilities = ["read"] }
path "kv/metadata/%s" { capabilities = ["read"] }`, remotePath, remotePath)
}

func testOpenBaoPolicy(policy string) any {
	return map[string]any{"data": map[string]any{"policy": policy}}
}

func testOpenBaoRole(serviceAccounts, namespaces []string, selector, policy string) any {
	return map[string]any{"data": map[string]any{
		"bound_service_account_names":              serviceAccounts,
		"bound_service_account_namespaces":         namespaces,
		"bound_service_account_namespace_selector": selector,
		"audience": openBaoKubernetesAudience,
		"policies": []string{policy},
	}}
}

func testOpenBaoLiveMetadata(version int) any {
	return map[string]any{"data": map[string]any{
		"current_version": version,
		"versions": map[string]any{
			fmt.Sprint(version): map[string]any{"deletion_time": "", "destroyed": false},
		},
	}}
}

func testOpenBaoSubkeys(keys ...string) any {
	subkeys := make(map[string]any, len(keys))
	for _, key := range keys {
		subkeys[key] = nil
	}
	return map[string]any{"subkeys": subkeys, "metadata": map[string]any{"version": 1}}
}

func writeTestOpenBaoJSON(t *testing.T, w http.ResponseWriter, value any) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(value); err != nil {
		t.Errorf("OpenBao test 응답 기록 실패: %v", err)
	}
}

func TestESOAccessNamesMatchChartHelpers(t *testing.T) {
	role, serviceAccount, secretPath, err := esoAccessNames(esoProfile("research", "prod", "tester"))
	if err != nil {
		t.Fatal(err)
	}
	// app-profile.esoRole / app-profile.esoServiceAccount / assertRemotePath 와 같은 값이어야 한다.
	if role != "portal-zone-app-eso" || serviceAccount != "eso-tester" ||
		secretPath != "apps/research/prod/workloads/research-beta/eso-tester" {
		t.Fatalf("role=%q sa=%q path=%q", role, serviceAccount, secretPath)
	}
}

func TestESOAccessNamesRejectPathEscape(t *testing.T) {
	for _, name := range []string{"../platform-admin", "a/b", "UPPER", ""} {
		if _, _, _, err := esoAccessNames(esoProfile("research", "prod", name)); err == nil {
			t.Fatalf("app 이름 %q 가 통과했다", name)
		}
	}
}

func TestESOAccessNamesIncludeAppGroupIdentity(t *testing.T) {
	profile := esoProfile("research", "prod", "api")
	profile.App.Group = "mobility"
	role, serviceAccount, secretPath, err := esoAccessNames(profile)
	if err != nil {
		t.Fatal(err)
	}
	if role != "portal-group-app-eso" || serviceAccount != "eso-sa-a-api-3cf0704c0d" ||
		secretPath != "apps/research/prod/workloads/app-mobility/eso-sa-a-api-3cf0704c0d" {
		t.Fatalf("role=%q sa=%q path=%q", role, serviceAccount, secretPath)
	}
}

func TestResolveESOAccessContractSupportsStoredLegacyPath(t *testing.T) {
	profile := esoProfile("research", "prod", "tester")
	contract, err := resolveESOAccessContract(profile, "kv/apps/research/prod/tester")
	if err != nil {
		t.Fatal(err)
	}
	if !contract.Legacy || contract.Role != "eso-research-prod-tester" ||
		contract.ServiceAccount != "eso-tester" || contract.SecretPath != "apps/research/prod/tester" {
		t.Fatalf("legacy contract=%+v", contract)
	}
	canonical, err := resolveESOAccessContract(profile, "")
	if err != nil {
		t.Fatal(err)
	}
	if canonical.Legacy || canonical.Role != openBaoZoneRole ||
		canonical.SecretPath != "apps/research/prod/workloads/research-beta/eso-tester" {
		t.Fatalf("canonical contract=%+v", canonical)
	}
}

func TestResolveESOAccessContractRejectsIdentityDriftAndGroupedLegacy(t *testing.T) {
	profile := esoProfile("research", "prod", "tester")
	for _, path := range []string{
		"apps/research/dev/tester",
		"apps/research/prod/other",
		"kv/apps/research/prod/other",
	} {
		if _, err := resolveESOAccessContract(profile, path); err == nil {
			t.Fatalf("identity와 다른 path %q가 통과했다", path)
		}
	}
	profile.App.Group = "mobility"
	if _, err := resolveESOAccessContract(profile, "kv/apps/research/prod/tester"); err == nil {
		t.Fatal("AppGroup legacy path가 통과했다")
	}
}

func TestESOAccessNamesRejectConfiguredRoleDrift(t *testing.T) {
	originalZoneRole := openbaoZoneAppRole
	originalGroupRegistryRole := openbaoGroupRegistryRole
	t.Cleanup(func() {
		openbaoZoneAppRole = originalZoneRole
		openbaoGroupRegistryRole = originalGroupRegistryRole
	})
	openbaoZoneAppRole = "drifted-zone-role"
	if _, _, _, err := esoAccessNames(esoProfile("research", "prod", "tester")); err == nil {
		t.Fatal("Chart와 다른 workload role 설정이 통과했다")
	}
	openbaoZoneAppRole = originalZoneRole
	openbaoGroupRegistryRole = "drifted-registry-role"
	if _, _, err := groupRegistryAccessNames(newAppGroup("mobility", "research", "prod")); err == nil {
		t.Fatal("Chart와 다른 registry role 설정이 통과했다")
	}
}

func TestESORequirementFailsClosedWithoutOpenBao(t *testing.T) {
	client := &forgejoClient{}
	plain := deploymentRequest{Profile: esoProfile("research", "prod", "plain")}
	if err := client.grantSecretAccess(context.Background(), plain); err != nil {
		t.Fatalf("Secret 없는 일반 앱이 OpenBao를 요구함: %v", err)
	}
	oidc := plain
	oidc.Profile.Authentication.Mode = authOIDC
	if err := client.grantSecretAccess(context.Background(), oidc); err == nil {
		t.Fatal("OIDC-only 앱이 OpenBao 없이 통과했다")
	}
	grouped := plain
	grouped.Profile.App.Group = "mobility"
	if err := client.grantSecretAccess(context.Background(), grouped); err == nil {
		t.Fatal("AppGroup registry ESO가 OpenBao 없이 통과했다")
	}
}

func TestGrantESOAccessChecksSharedPolicyRoleAndSeed(t *testing.T) {
	jwtPath := t.TempDir() + "/token"
	if err := os.WriteFile(jwtPath, []byte("projected-jwt\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var calls []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		calls = append(calls, r.Method+" "+r.URL.Path+" "+string(body))
		if r.URL.Path == "/v1/auth/kubernetes/login" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"auth":{"client_token":"user-scoped-token","lease_duration":900}}`))
			return
		}
		switch r.URL.Path {
		case "/v1/sys/policies/acl/portal-workload-secret-reader":
			writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(testWorkloadPolicy("research", "prod")))
		case "/v1/auth/kubernetes/role/portal-zone-app-eso":
			role := testOpenBaoRole([]string{"*"}, []string{"research-beta"}, "", openBaoWorkloadPolicy).(map[string]any)
			// Kubernetes auth API 문서의 단일 값 응답도 exact-list 계약으로 해석한다.
			roleData := role["data"].(map[string]any)
			roleData["bound_service_account_names"] = "*"
			roleData["bound_service_account_namespaces"] = "research-beta"
			roleData["policies"] = openBaoWorkloadPolicy
			writeTestOpenBaoJSON(t, w, role)
		case "/v1/kv/metadata/apps/research/prod/workloads/research-beta/eso-tester":
			writeTestOpenBaoJSON(t, w, testOpenBaoLiveMetadata(3))
		case "/v1/kv/subkeys/apps/research/prod/workloads/research-beta/eso-tester":
			if r.URL.Query().Get("version") != "3" {
				t.Errorf("workload subkeys version=%q", r.URL.Query().Get("version"))
			}
			writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys("API_TOKEN"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	baseURL, _ := url.Parse(server.URL)
	client := &openBaoClient{
		baseURL: baseURL, http: server.Client(), jwtPath: jwtPath,
		role: "portal-app-secret-writer", expires: time.Time{},
	}
	profile := esoProfile("research", "prod", "tester")
	profile.Configuration.SecretKeys = []string{"API_TOKEN"}
	if err := client.grantESOAccess(context.Background(), profile, profile.namespace()); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"POST /v1/auth/kubernetes/login ",
		"GET /v1/sys/policies/acl/portal-workload-secret-reader ",
		"GET /v1/auth/kubernetes/role/portal-zone-app-eso ",
		"GET /v1/kv/metadata/apps/research/prod/workloads/research-beta/eso-tester ",
		"GET /v1/kv/subkeys/apps/research/prod/workloads/research-beta/eso-tester ",
	}
	if len(calls) != len(want) {
		t.Fatalf("예상하지 못한 OpenBao 호출: %#v", calls)
	}
	for index := range want {
		if !strings.HasPrefix(calls[index], want[index]) {
			t.Fatalf("OpenBao 호출[%d]=%q, want prefix %q", index, calls[index], want[index])
		}
	}
	for _, call := range calls[1:] {
		if !strings.HasPrefix(call, "GET ") {
			t.Fatalf("readiness 확인이 OpenBao 상태를 변경함: %s", call)
		}
		if strings.Contains(call, "/v1/kv/data/") {
			t.Fatalf("workload readiness가 Secret 값 endpoint를 읽음: %s", call)
		}
	}
}

func TestStoredLegacyESORequestResumesAndDeletesExactPathReadOnly(t *testing.T) {
	profile := esoProfile("research", "prod", "tester")
	profile.Configuration.SecretKeys = []string{"API_TOKEN"}
	contract, err := resolveESOAccessContract(profile, "kv/apps/research/prod/tester")
	if err != nil {
		t.Fatal(err)
	}
	var deletedPath string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if (strings.HasPrefix(r.URL.Path, "/v1/sys/policies/") ||
			strings.HasPrefix(r.URL.Path, "/v1/auth/kubernetes/role/")) && r.Method != http.MethodGet {
			t.Errorf("legacy resume가 policy/role을 변경함: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/v1/sys/policies/acl/" + contract.Role:
			policy := fmt.Sprintf(
				"path \"kv/data/%s\" { capabilities = [\"read\"] }\n"+
					"path \"kv/metadata/%s\" { capabilities = [\"read\", \"list\"] }\n",
				contract.SecretPath, contract.SecretPath)
			writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(policy))
		case "/v1/auth/kubernetes/role/" + contract.Role:
			writeTestOpenBaoJSON(t, w, testOpenBaoRole(
				[]string{contract.ServiceAccount}, []string{profile.namespace()}, "", contract.Role))
		case "/v1/kv/metadata/" + contract.SecretPath:
			if r.Method == http.MethodDelete {
				deletedPath = r.URL.Path
				w.WriteHeader(http.StatusNoContent)
				return
			}
			writeTestOpenBaoJSON(t, w, testOpenBaoLiveMetadata(2))
		case "/v1/kv/subkeys/" + contract.SecretPath:
			writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys("API_TOKEN"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	baseURL, _ := url.Parse(server.URL)
	client := &openBaoClient{
		baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour),
	}
	storedPath := "kv/apps/research/prod/tester"
	if err := client.grantESOAccessAt(context.Background(), profile, profile.namespace(), storedPath); err != nil {
		t.Fatal(err)
	}
	if err := client.revokeESOAccessAt(context.Background(), profile, storedPath); err != nil {
		t.Fatal(err)
	}
	if deletedPath != "/v1/kv/metadata/apps/research/prod/tester" {
		t.Fatalf("legacy KV metadata delete path=%q", deletedPath)
	}
}

func TestGrantGroupESOAccessChecksDeclaredAndOIDCKeys(t *testing.T) {
	profile := esoProfile("research", "prod", "api")
	profile.App.Group = "mobility"
	profile.Authentication.Mode = authOIDC
	profile.Configuration.SecretKeys = []string{"POSTGRES_PASSWORD"}
	_, _, secretPath, err := esoAccessNames(profile)
	if err != nil {
		t.Fatal(err)
	}
	var calledDataEndpoint bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/v1/kv/data/") {
			calledDataEndpoint = true
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/v1/sys/policies/acl/portal-workload-secret-reader":
			writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(testWorkloadPolicy("research", "prod")))
		case "/v1/auth/kubernetes/role/portal-group-app-eso":
			writeTestOpenBaoJSON(t, w, testOpenBaoRole([]string{"*"}, nil,
				`{"matchLabels":{"platform.example.io/app-group":"true"}}`, openBaoWorkloadPolicy))
		case "/v1/kv/metadata/" + secretPath:
			writeTestOpenBaoJSON(t, w, testOpenBaoLiveMetadata(4))
		case "/v1/kv/subkeys/" + secretPath:
			if r.URL.Query().Get("version") != "4" {
				t.Errorf("workload subkeys version=%q", r.URL.Query().Get("version"))
			}
			writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys("POSTGRES_PASSWORD", "OIDC_CLIENT_SECRET"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	baseURL, _ := url.Parse(server.URL)
	client := &openBaoClient{
		baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour),
	}
	if err := client.grantESOAccess(context.Background(), profile, profile.namespace()); err != nil {
		t.Fatal(err)
	}
	if calledDataEndpoint {
		t.Fatal("workload preflight가 Secret data endpoint를 호출했다")
	}
}

func TestGrantESOAccessRejectsMissingRequiredProperty(t *testing.T) {
	profile := esoProfile("research", "prod", "tester")
	profile.Authentication.Mode = authOIDC
	profile.Configuration.SecretKeys = []string{"API_TOKEN"}
	_, _, secretPath, err := esoAccessNames(profile)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/sys/policies/acl/portal-workload-secret-reader":
			writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(testWorkloadPolicy("research", "prod")))
		case "/v1/auth/kubernetes/role/portal-zone-app-eso":
			writeTestOpenBaoJSON(t, w, testOpenBaoRole([]string{"*"}, []string{profile.namespace()}, "",
				openBaoWorkloadPolicy))
		case "/v1/kv/metadata/" + secretPath:
			writeTestOpenBaoJSON(t, w, testOpenBaoLiveMetadata(1))
		case "/v1/kv/subkeys/" + secretPath:
			// API_TOKEN만 있어도 OIDC client Secret이 없으면 SecurityPolicy가 동작하지 않는다.
			writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys("API_TOKEN"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	baseURL, _ := url.Parse(server.URL)
	client := &openBaoClient{
		baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour),
	}
	err = client.grantESOAccess(context.Background(), profile, profile.namespace())
	if err == nil || !strings.Contains(err.Error(), "OIDC_CLIENT_SECRET") {
		t.Fatalf("누락된 OIDC property가 거부되지 않음: %v", err)
	}
}

func TestRequireWorkloadPolicyRejectsBroadenedOrWrongPath(t *testing.T) {
	profile := esoProfile("research", "prod", "tester")
	tests := map[string]string{
		"wrong-environment": testWorkloadPolicy("research", "dev"),
		"extra-path": testWorkloadPolicy("research", "prod") +
			"\n" + `path "kv/data/apps/research/prod/workloads/*" { capabilities = ["read"] }`,
		"write-capability": strings.Replace(testWorkloadPolicy("research", "prod"),
			`capabilities = ["read"]`, `capabilities = ["read", "update"]`, 1),
	}
	for name, policy := range tests {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(policy))
			}))
			defer server.Close()
			baseURL, _ := url.Parse(server.URL)
			client := &openBaoClient{
				baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour),
			}
			if err := client.requireWorkloadPolicy(context.Background(), profile); err == nil {
				t.Fatal("넓거나 다른 workload policy가 통과했다")
			}
		})
	}
}

func TestGrantGroupRegistryAccessUsesReadOnlyGroupRole(t *testing.T) {
	jwtPath := t.TempDir() + "/token"
	if err := os.WriteFile(jwtPath, []byte("projected-jwt\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var calls []string
	var subkeysVersion string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		calls = append(calls, r.Method+" "+r.URL.Path+" "+string(body))
		if r.URL.Path == "/v1/auth/kubernetes/login" {
			_, _ = w.Write([]byte(`{"auth":{"client_token":"token","lease_duration":900}}`))
			return
		}
		switch r.URL.Path {
		case "/v1/sys/policies/acl/portal-registry-pull-reader":
			writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(testRegistryPolicy("platform/registry/pull-secret")))
		case "/v1/auth/kubernetes/role/portal-group-registry-eso":
			writeTestOpenBaoJSON(t, w, testOpenBaoRole([]string{"eso-registry"}, nil,
				`{"matchLabels":{"platform.example.io/app-group":"true"}}`, openBaoRegistryPolicy))
		case "/v1/kv/metadata/platform/registry/pull-secret":
			writeTestOpenBaoJSON(t, w, testOpenBaoLiveMetadata(7))
		case "/v1/kv/subkeys/platform/registry/pull-secret":
			subkeysVersion = r.URL.Query().Get("version")
			writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys(openBaoRegistryRequiredKey))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	baseURL, _ := url.Parse(server.URL)
	client := &openBaoClient{baseURL: baseURL, http: server.Client(), jwtPath: jwtPath, role: "writer"}
	group := newAppGroup("mobility", "research", "prod")
	if err := client.grantGroupRegistryAccess(context.Background(), group,
		"platform/registry/pull-secret"); err != nil {
		t.Fatal(err)
	}
	role, serviceAccount, err := groupRegistryAccessNames(group)
	if err != nil {
		t.Fatal(err)
	}
	if role != "portal-group-registry-eso" || serviceAccount != "eso-registry" {
		t.Fatalf("registry fixed identity 불일치: role=%q sa=%q", role, serviceAccount)
	}
	want := []string{
		"POST /v1/auth/kubernetes/login ",
		"GET /v1/sys/policies/acl/portal-registry-pull-reader ",
		"GET /v1/auth/kubernetes/role/portal-group-registry-eso ",
		"GET /v1/kv/metadata/platform/registry/pull-secret ",
		"GET /v1/kv/subkeys/platform/registry/pull-secret ",
	}
	if len(calls) != len(want) {
		t.Fatalf("예상하지 못한 호출: %#v", calls)
	}
	for index := range want {
		if !strings.HasPrefix(calls[index], want[index]) {
			t.Fatalf("OpenBao 호출[%d]=%q, want prefix %q", index, calls[index], want[index])
		}
	}
	for _, call := range calls[1:] {
		if !strings.HasPrefix(call, "GET ") {
			t.Fatalf("registry preflight가 OpenBao 상태를 변경함: %s", call)
		}
		if strings.Contains(call, "/v1/kv/data/") {
			t.Fatalf("registry preflight가 Secret 값 endpoint를 읽음: %s", call)
		}
	}
	if subkeysVersion != "7" {
		t.Fatalf("subkeys version=%q, want latest version 7", subkeysVersion)
	}
}

func TestGrantGroupRegistryAccessRejectsBrokenContractAndSeed(t *testing.T) {
	cases := []string{
		"policy-path",
		"policy-capability",
		"role-service-account",
		"role-namespace",
		"role-selector",
		"role-audience",
		"role-token-policy",
		"latest-destroyed",
		"latest-deleted",
		"required-property",
	}
	for _, testCase := range cases {
		t.Run(testCase, func(t *testing.T) {
			const remotePath = "platform/registry/pull-secret"
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.Contains(r.URL.Path, "/v1/kv/data/") {
					t.Errorf("preflight가 Secret data endpoint를 호출함: %s", r.URL.Path)
					w.WriteHeader(http.StatusForbidden)
					return
				}
				switch r.URL.Path {
				case "/v1/sys/policies/acl/portal-registry-pull-reader":
					policy := testRegistryPolicy(remotePath)
					if testCase == "policy-path" {
						policy = testRegistryPolicy("platform/registry/other")
					}
					if testCase == "policy-capability" {
						policy = strings.Replace(policy, `capabilities = ["read"]`, `capabilities = ["read", "list"]`, 1)
					}
					writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(policy))
				case "/v1/auth/kubernetes/role/portal-group-registry-eso":
					serviceAccounts := []string{"eso-registry"}
					namespaces := []string(nil)
					selector := `{"matchLabels":{"platform.example.io/app-group":"true"}}`
					policy := openBaoRegistryPolicy
					if testCase == "role-service-account" {
						serviceAccounts = []string{"*"}
					}
					if testCase == "role-namespace" {
						namespaces = []string{"app-mobility"}
					}
					if testCase == "role-selector" {
						selector = `{"matchLabels":{"platform.example.io/app-group":"false"}}`
					}
					if testCase == "role-token-policy" {
						policy = "default"
					}
					role := testOpenBaoRole(serviceAccounts, namespaces, selector, policy).(map[string]any)
					if testCase == "role-audience" {
						role["data"].(map[string]any)["audience"] = "other-audience"
					}
					writeTestOpenBaoJSON(t, w, role)
				case "/v1/kv/metadata/platform/registry/pull-secret":
					metadata := testOpenBaoLiveMetadata(2).(map[string]any)
					version := metadata["data"].(map[string]any)["versions"].(map[string]any)["2"].(map[string]any)
					if testCase == "latest-destroyed" {
						version["destroyed"] = true
					}
					if testCase == "latest-deleted" {
						version["deletion_time"] = time.Now().Add(-time.Minute).UTC().Format(time.RFC3339Nano)
					}
					writeTestOpenBaoJSON(t, w, metadata)
				case "/v1/kv/subkeys/platform/registry/pull-secret":
					if r.URL.Query().Get("version") != "2" {
						t.Errorf("subkeys version=%q", r.URL.Query().Get("version"))
					}
					if testCase == "required-property" {
						writeTestOpenBaoJSON(t, w, map[string]any{
							"subkeys":                        map[string]any{"other": nil},
							"debug_value_that_must_not_leak": "SENSITIVE-REGISTRY-CREDENTIAL",
						})
					} else {
						writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys(openBaoRegistryRequiredKey))
					}
				default:
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer server.Close()
			baseURL, _ := url.Parse(server.URL)
			client := &openBaoClient{
				baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour),
			}
			err := client.grantGroupRegistryAccess(context.Background(),
				newAppGroup("mobility", "research", "prod"), remotePath)
			if err == nil {
				t.Fatal("깨진 OpenBao 계약/seed가 readiness를 통과했다")
			}
			if strings.Contains(err.Error(), "SENSITIVE-REGISTRY-CREDENTIAL") {
				t.Fatalf("Secret 값이 오류에 노출됨: %v", err)
			}
		})
	}
}
