package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func reconciliationAPI(t *testing.T, handler http.HandlerFunc) *apiServer {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	tokenPath := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenPath, []byte("test-token"), 0o600); err != nil {
		t.Fatal(err)
	}
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = requestStore.close() })
	builder := &buildPipeline{
		base: server.URL, tokenPath: tokenPath,
		client: &http.Client{Timeout: time.Second}, logger: log.New(io.Discard, "", 0),
	}
	return &apiServer{store: requestStore, forgejo: &forgejoClient{builder: builder}}
}

func TestReconcileMarksReadyDeploymentDeployed(t *testing.T) {
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/apis/apps/v1/namespaces/"+zoneNamespace()+"/deployments/demo" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"metadata":{"generation":2},"spec":{"replicas":1,"template":{"spec":{"containers":[{"image":"registry/demo:v1"}]}}},"status":{"observedGeneration":2,"replicas":1,"readyReplicas":1,"updatedReplicas":1,"availableReplicas":1}}`))
	})
	request := deploymentRequest{
		ID: "ready", State: stateFailed, Generated: generatedPlan{Image: "registry/demo:v1"},
		GitCommitted: true, ApplicationSynced: true, FailedFromState: stateDeploying,
	}
	request.Profile.App.Name = "demo"
	request.Profile.Replicas = 1
	if err := api.store.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	got := api.reconcileDeploymentRequest(context.Background(), request)
	if got.State != stateDeployed {
		t.Fatalf("state=%q, want %q", got.State, stateDeployed)
	}
}

func TestReconcileDoesNotPromoteFailedSameImageBeforeDesiredRevision(t *testing.T) {
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/apis/apps/v1/namespaces/"+zoneNamespace()+"/deployments/demo" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"metadata":{"generation":2},"spec":{"replicas":1,"template":{"spec":{"containers":[{"image":"registry/demo:v1"}]}}},"status":{"observedGeneration":2,"replicas":1,"readyReplicas":1,"updatedReplicas":1,"availableReplicas":1}}`))
	})
	request := deploymentRequest{
		ID: "merge-failed", State: stateFailed, Generated: generatedPlan{Image: "registry/demo:v1"},
		FailedFromState: statePROpen,
	}
	request.Profile.App.Name = "demo"
	got := api.reconcileDeploymentRequest(context.Background(), request)
	if got.State != stateFailed {
		t.Fatalf("state=%q, merge 전 실패를 deployed로 승격함", got.State)
	}
}

func TestReconcileRequiresArgoDesiredRevisionBeforeReadyImage(t *testing.T) {
	const revision = "0123456789abcdef"
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/apis/argoproj.io/v1alpha1/namespaces/" + argoNamespace + "/applications/demo-prod":
			_, _ = w.Write([]byte(`{"status":{"sync":{"status":"Synced","revisions":["` + revision + `"]}}}`))
		case "/apis/apps/v1/namespaces/" + zoneNamespace() + "/deployments/demo":
			_, _ = w.Write([]byte(`{"metadata":{"generation":2},"spec":{"replicas":1,"template":{"spec":{"containers":[{"image":"registry/demo:v1"}]}}},"status":{"observedGeneration":2,"replicas":1,"readyReplicas":1,"updatedReplicas":1,"availableReplicas":1}}`))
		default:
			http.NotFound(w, r)
		}
	})
	request := deploymentRequest{
		ID: "rollout-timeout", State: stateFailed, Generated: generatedPlan{Image: "registry/demo:v1"},
		GitCommitted: true, DesiredRevision: revision, FailedFromState: stateDeploying,
	}
	request.Profile.App.Name = "demo"
	request.Profile.App.Environment = "prod"
	request.Profile.Replicas = 1
	if err := api.store.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	got := api.reconcileDeploymentRequest(context.Background(), request)
	if got.State != stateDeployed || !got.ApplicationSynced {
		t.Fatalf("revision 동기화 뒤 수렴하지 않음: %+v", got)
	}
}

func TestGroupApplicationRevisionRequiresSyncedHealthyAndRevision(t *testing.T) {
	const revision = "0123456789abcdef"
	for _, testCase := range []struct {
		name      string
		response  string
		wantReady bool
		wantError bool
	}{
		{
			name: "ready",
			response: `{"status":{"sync":{"status":"Synced","revisions":["` + revision +
				`"]},"health":{"status":"Healthy"}}}`,
			wantReady: true,
		},
		{
			name: "baseline-health-pending",
			response: `{"status":{"sync":{"status":"Synced","revisions":["` + revision +
				`"]},"health":{"status":"Progressing"}}}`,
		},
		{
			name: "old-revision",
			response: `{"status":{"sync":{"status":"Synced","revisions":["old"]},` +
				`"health":{"status":"Healthy"}}}`,
		},
		{
			name: "invalid-spec",
			response: `{"status":{"sync":{"status":"Synced","revisions":["` + revision +
				`"]},"health":{"status":"Healthy"},"conditions":[{"type":"InvalidSpecError",` +
				`"message":"denied"}]}}`,
			wantError: true,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			var application argoApplicationStatus
			if err := json.Unmarshal([]byte(testCase.response), &application); err != nil {
				t.Fatal(err)
			}
			ready, err := groupApplicationAtRevisionReady(application, revision)
			if ready != testCase.wantReady || (err != nil) != testCase.wantError {
				t.Fatalf("ready=%v err=%v", ready, err)
			}
		})
	}
}

func TestReconcileDoesNotSkipDeletionCleanupWhenAppIsGone(t *testing.T) {
	api := reconciliationAPI(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	request := deploymentRequest{ID: "gone", State: stateDeleting, DeletionRequested: true}
	request.Profile.App.Name = "demo"
	request.Profile.App.Environment = "prod"
	got := api.reconcileDeploymentRequest(context.Background(), request)
	if got.State != stateDeleting {
		t.Fatalf("state=%q, want %q", got.State, stateDeleting)
	}
}

func TestDeleteNamedApplicationDoesNotAcceptOrphanNamespace(t *testing.T) {
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/namespaces/app-mobility" {
			_, _ = w.Write([]byte(`{"metadata":{"name":"app-mobility"}}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	err := api.forgejo.builder.deleteNamedApplication(ctx, "group-mobility-prod", "app-mobility")
	if err == nil {
		t.Fatal("Application 404만으로 남은 Namespace를 삭제 완료 처리함")
	}
}

func TestNamespaceExistsFailsClosed(t *testing.T) {
	for _, tc := range []struct {
		name       string
		status     int
		wantExists bool
		wantError  bool
	}{
		{name: "missing", status: http.StatusNotFound},
		{name: "existing", status: http.StatusOK, wantExists: true},
		{name: "forbidden", status: http.StatusForbidden, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != "/api/v1/namespaces/app-mobility" {
					t.Fatalf("예상하지 못한 Namespace 조회: %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(tc.status)
			})
			exists, err := api.forgejo.builder.namespaceExists(context.Background(), "app-mobility")
			if exists != tc.wantExists || (err != nil) != tc.wantError {
				t.Fatalf("exists=%v err=%v", exists, err)
			}
		})
	}
}

func TestBuildCredentialRequiresValidDockerConfig(t *testing.T) {
	validAuth := base64.StdEncoding.EncodeToString([]byte("builder:token"))
	valid := base64.StdEncoding.EncodeToString([]byte(`{"auths":{"registry.example":{"auth":"` + validAuth + `"}}}`))
	invalid := base64.StdEncoding.EncodeToString([]byte(`{"notAuths":{}}`))
	invalidAuth := base64.StdEncoding.EncodeToString([]byte(`{"auths":{"registry.example":{"auth":"raw-token"}}}`))
	for _, tc := range []struct {
		name    string
		encoded string
		wantErr bool
	}{
		{name: "valid", encoded: valid},
		{name: "missing", encoded: "", wantErr: true},
		{name: "invalid-json-shape", encoded: invalid, wantErr: true},
		{name: "invalid-inner-auth", encoded: invalidAuth, wantErr: true},
		{name: "invalid-base64", encoded: "%%%", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/v1/namespaces/"+buildNamespace+"/secrets/"+buildPushSecret {
					t.Fatalf("예상하지 못한 Secret 조회: %s", r.URL.Path)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{
					"data": map[string]string{buildPushSecretKey: tc.encoded},
				})
			})
			err := api.forgejo.builder.requireBuildCredential(context.Background())
			if (err != nil) != tc.wantErr {
				t.Fatalf("err=%v", err)
			}
		})
	}
}

func TestRegistryPullCredentialUsesExactZoneSecret(t *testing.T) {
	validAuth := base64.StdEncoding.EncodeToString([]byte("reader:token"))
	encoded := base64.StdEncoding.EncodeToString([]byte(
		`{"auths":{"registry.example":{"auth":"` + validAuth + `"}}}`))
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		want := "/api/v1/namespaces/" + zoneNamespace() + "/secrets/" + registryPullSecret
		if r.Method != http.MethodGet || r.URL.Path != want {
			t.Fatalf("예상하지 못한 registry pull Secret 조회: %s %s", r.Method, r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]string{".dockerconfigjson": encoded},
		})
	})
	if err := api.forgejo.builder.requireRegistryPullCredential(
		context.Background(), zoneNamespace()); err != nil {
		t.Fatalf("registry pull credential 검증 실패: %v", err)
	}
}

func TestPodFailureRejectsFatalWaitingReason(t *testing.T) {
	var pods podListStatus
	if err := json.Unmarshal([]byte(`{"items":[{"status":{"containerStatuses":[{"state":{"waiting":{"reason":"ImagePullBackOff","message":"image not found"}}}]}}]}`), &pods); err != nil {
		t.Fatal(err)
	}
	if got := podFailure(pods); got != "ImagePullBackOff: image not found" {
		t.Fatalf("failure=%q", got)
	}
}

func TestFatalApplicationConditionDetectsMissingProject(t *testing.T) {
	var application argoApplicationStatus
	body := `{"status":{"conditions":[{"type":"DeletionError","message":"error getting app project \"proj-research-prod\": not found\nstack"}]}}`
	if err := json.Unmarshal([]byte(body), &application); err != nil {
		t.Fatal(err)
	}
	want := `DeletionError: error getting app project "proj-research-prod": not found`
	if got := fatalApplicationCondition(application); got != want {
		t.Fatalf("condition=%q, want %q", got, want)
	}
}

func TestFatalApplicationConditionIgnoresBenignConditions(t *testing.T) {
	var application argoApplicationStatus
	body := `{"status":{"conditions":[{"type":"SharedResourceWarning","message":"shared"}]}}`
	if err := json.Unmarshal([]byte(body), &application); err != nil {
		t.Fatal(err)
	}
	if got := fatalApplicationCondition(application); got != "" {
		t.Fatalf("condition=%q, want empty", got)
	}
}
