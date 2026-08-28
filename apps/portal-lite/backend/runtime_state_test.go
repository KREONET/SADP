package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
)

func putRuntimeState(
	t *testing.T, handler http.Handler, id, requester, desired string,
) *httptest.ResponseRecorder {
	t.Helper()
	body := `{"state":` + strconvQuote(desired) + `}`
	req := httptest.NewRequest(http.MethodPut,
		"/api/v1/deployment-requests/"+id+"/runtime-state", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(requesterHeader, requester)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func strconvQuote(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func TestRuntimeStateStopAndResumeThroughGitOps(t *testing.T) {
	fake, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	ctx, cancel := contextWithCancel(t)
	defer cancel()
	go client.run(ctx)

	createdRecorder := postRequest(t, handler, validInput("public"), "runtime-app")
	if createdRecorder.Code != http.StatusAccepted {
		t.Fatalf("생성 status=%d body=%s", createdRecorder.Code, createdRecorder.Body.String())
	}
	created := decodeRequest(t, createdRecorder)
	deployed := waitForState(t, api, created.ID, stateMerged)
	deployed.State = stateDeployed
	deployed.Generated.Image = "registry.example/research-viewer:build-0123"
	if err := api.store.update(deployed); err != nil {
		t.Fatal(err)
	}
	// 실제 소스 배포는 build 완료 뒤 target values의 CHANGE_ME tag를 최종 tag로
	// 바꾼다. runtime patch가 이 값을 보존하는지 같은 단계의 fixture로 검증한다.
	fake.mu.Lock()
	for path, encoded := range fake.files {
		if !strings.Contains(path, "/contents/apps/research-viewer/values-beta.yaml") {
			continue
		}
		decoded, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			fake.mu.Unlock()
			t.Fatal(err)
		}
		values := strings.Replace(string(decoded),
			"repository: \""+registryBase+"/research-viewer\"\n  tag: \"CHANGE_ME_COMMIT_SHA\"",
			"repository: \"registry.example/research-viewer\"\n  tag: \"build-0123\"", 1)
		fake.files[path] = base64.StdEncoding.EncodeToString([]byte(values))
	}
	fake.mu.Unlock()

	stop := putRuntimeState(t, handler, created.ID, "owner@example.invalid", runtimeStopped)
	if stop.Code != http.StatusAccepted {
		t.Fatalf("중지 status=%d body=%s", stop.Code, stop.Body.String())
	}
	stopped := waitForState(t, api, created.ID, stateStopped)
	if requestRuntimeState(stopped) != runtimeStopped || stopped.RuntimeGeneration != 1 {
		t.Fatalf("중지 결과가 올바르지 않음: %+v", stopped)
	}
	assertFakeValues(t, fake, "replicaCount: 0", "  enabled: false")
	assertFakeValues(t, fake, "repository: \"registry.example/research-viewer\"", "tag: \"build-0123\"")
	fake.mu.Lock()
	conditionalUpdate := false
	for key, body := range fake.bodies {
		if strings.HasPrefix(key, http.MethodPut+" ") && strings.Contains(key, "/contents/") &&
			strings.Contains(body, `"sha":"blob-sha"`) {
			conditionalUpdate = true
		}
	}
	fake.mu.Unlock()
	if !conditionalUpdate {
		t.Fatal("runtime values가 예상 blob SHA 없이 갱신됨")
	}

	// 같은 목표 상태 재요청은 새 PR 없이 현재 결과를 돌려준다.
	if replay := putRuntimeState(t, handler, created.ID, "owner@example.invalid", runtimeStopped); replay.Code != http.StatusOK {
		t.Fatalf("중지 재요청 status=%d body=%s", replay.Code, replay.Body.String())
	}

	start := putRuntimeState(t, handler, created.ID, "owner@example.invalid", runtimeRunning)
	if start.Code != http.StatusAccepted {
		t.Fatalf("재개 status=%d body=%s", start.Code, start.Body.String())
	}
	running := waitForState(t, api, created.ID, stateDeployed)
	if requestRuntimeState(running) != runtimeRunning || running.RuntimeGeneration != 2 {
		t.Fatalf("재개 결과가 올바르지 않음: %+v", running)
	}
	assertFakeValues(t, fake, "replicaCount: 1", "  enabled: true")
}

func TestRuntimeCrashAfterMergeRecoversWithoutDeletedBranch(t *testing.T) {
	_, client := newFakeForgejo(t)
	client.mergedForTest(t)
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	client.store = requestStore
	request := renderedRequest(t, "public")
	request.State = stateStopping
	request.DesiredRuntimeState = runtimeStopped
	request.RuntimeGeneration = 1
	request.RuntimePullRequest = &pullRequestRef{
		Number: 7, Branch: client.runtimeBranch(request), State: "open",
	}
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	// merge가 끝나 branch가 삭제된 crash window다. PR 상태를 먼저 보면 values
	// branch 조회 없이 terminal로 복구할 수 있다.
	client.applyRuntimeState(context.Background(), request)
	got, _ := requestStore.get(request.ID)
	if got.State != stateStopped || got.RuntimePullRequest == nil || got.RuntimePullRequest.State != "merged" {
		t.Fatalf("merge 직후 crash 복구 실패: %+v", got)
	}
}

func (f *forgejoClient) mergedForTest(t *testing.T) {
	t.Helper()
	// 이 helper는 fake 서버의 merge 상태를 직접 바꿀 수 없으므로 실제 merge endpoint를
	// 한 번 호출해 이후 PR 조회가 merged=true를 돌려주게 한다.
	if err := f.do(context.Background(), http.MethodPost, f.repoPath("pulls", "7", "merge"),
		map[string]string{}, nil); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeRetryClosesSupersededOpenPullRequest(t *testing.T) {
	fake, client := newFakeForgejo(t)
	var logs strings.Builder
	client.logger = log.New(&logs, "", 0)
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	client.store = requestStore
	request := renderedRequest(t, "public")
	request.State = stateStopping
	request.DesiredRuntimeState = runtimeStopped
	request.RuntimeGeneration = 2
	request.RuntimeSupersededPullRequest = &pullRequestRef{Number: 7, Branch: "portal/old-stop", State: "open"}
	values, err := patchRuntimeValues(renderValuesYAML(request), request)
	if err != nil {
		t.Fatal(err)
	}
	targetURL, err := url.Parse(client.fileEndpoint(appValuesPath(request.Profile)))
	if err != nil {
		t.Fatal(err)
	}
	fake.files[targetURL.Path] =
		base64.StdEncoding.EncodeToString([]byte(values))
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	client.applyRuntimeState(context.Background(), request)
	got, _ := requestStore.get(request.ID)
	if got.State != stateStopped || got.RuntimeSupersededPullRequest != nil {
		t.Fatalf("이전 runtime PR 무효화 후 수렴 실패: %+v logs=%s", got, logs.String())
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	foundClose := false
	for _, call := range fake.calls {
		if call == http.MethodPatch+" /api/v1/repos/platform/gitops/pulls/7" {
			foundClose = true
		}
	}
	if !foundClose {
		t.Fatalf("이전 open PR close 호출 누락: %v", fake.calls)
	}
}

func assertFakeValues(t *testing.T, fake *fakeForgejo, fragments ...string) {
	t.Helper()
	fake.mu.Lock()
	defer fake.mu.Unlock()
	var values string
	for path, encoded := range fake.files {
		if !strings.Contains(path, "/contents/apps/research-viewer/values-beta.yaml") {
			continue
		}
		decoded, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			t.Fatalf("fake values base64 해석 실패: %v", err)
		}
		values = string(decoded)
	}
	if values == "" {
		t.Fatal("fake Forgejo에서 앱 values를 찾지 못함")
	}
	for _, fragment := range fragments {
		if !strings.Contains(values, fragment) {
			t.Fatalf("values에 %q가 없음:\n%s", fragment, values)
		}
	}
}

func TestRuntimeStateRequiresOwnerLatestAndValidBody(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	request := renderedRequest(t, "public")
	request.ID = "0123456789abcdef"
	request.State = stateDeployed
	request.Requester = "owner@example.invalid"
	if err := api.store.create(request, "", ""); err != nil {
		t.Fatal(err)
	}

	if other := putRuntimeState(t, handler, request.ID, "other@example.invalid", runtimeStopped); other.Code != http.StatusNotFound {
		t.Fatalf("남의 앱 중지 status=%d body=%s", other.Code, other.Body.String())
	}
	invalid := putRuntimeState(t, handler, request.ID, request.Requester, "paused")
	if invalid.Code != http.StatusUnprocessableEntity {
		t.Fatalf("잘못된 상태 status=%d body=%s", invalid.Code, invalid.Body.String())
	}

	newer := request
	newer.ID = "fedcba9876543210"
	newer.CreatedAt = newer.CreatedAt.AddDate(0, 0, 1)
	newer.UpdatedAt = newer.CreatedAt
	if err := api.store.create(newer, "", ""); err != nil {
		t.Fatal(err)
	}
	if stale := putRuntimeState(t, handler, request.ID, request.Requester, runtimeStopped); stale.Code != http.StatusConflict {
		t.Fatalf("과거 요청 중지 status=%d body=%s", stale.Code, stale.Body.String())
	}
}

func TestStoreResumesLifecycleTransitionAndAllowsStoppedDeletion(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	request := renderedRequest(t, "public")
	request.ID = "runtime-resume"
	request.Requester = "owner@example.invalid"
	request.State = stateDeployed
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}

	stopping, enqueue, err := requestStore.beginRuntimeState(request.ID, request.Requester, runtimeStopped)
	if err != nil || !enqueue || stopping.State != stateStopping || stopping.RuntimeGeneration != 1 {
		t.Fatalf("중지 전환 결과 request=%+v enqueue=%t err=%v", stopping, enqueue, err)
	}
	if resumable := requestStore.resumable(); len(resumable) != 1 || resumable[0].ID != request.ID {
		t.Fatalf("중지 전환이 재시작 복구 대상이 아님: %+v", resumable)
	}
	stopping.State = stateStopped
	if err := requestStore.update(stopping); err != nil {
		t.Fatal(err)
	}
	deleting, enqueue, err := requestStore.beginDelete(request.ID, request.Requester)
	if err != nil || !enqueue || deleting.State != stateDeleting {
		t.Fatalf("정지 앱 삭제 결과 request=%+v enqueue=%t err=%v", deleting, enqueue, err)
	}
}

func TestStoppedAndTransitioningAppsRejectSilentRedeployAndReserveQuota(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	request := renderedRequest(t, "public")
	request.Requester = "owner@example.invalid"
	request.State = stateDeployed
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	stopping, _, err := requestStore.beginRuntimeState(request.ID, request.Requester, runtimeStopped)
	if err != nil {
		t.Fatal(err)
	}

	assertRedeployRejected := func(id string) {
		t.Helper()
		incoming := request
		incoming.ID = id
		incoming.State = stateReceived
		if err := requestStore.create(incoming, "", ""); !errors.Is(err, errArtifactClaimed) {
			t.Fatalf("정지 상태 재배포 err=%v, want artifact claim", err)
		}
	}
	assertRedeployRejected("1111111111111111")
	stopping.State = stateStopped
	if err := requestStore.update(stopping); err != nil {
		t.Fatal(err)
	}
	assertRedeployRejected("2222222222222222")
	profiles := requestStore.liveProfiles(request.Requester)
	if len(profiles) != 1 || profiles[0].Replicas != request.Profile.Replicas {
		t.Fatalf("정지 앱의 재시작 용량이 quota에서 빠짐: %+v", profiles)
	}
}

func TestPatchRuntimeValuesChangesOnlyReplicaAndExposure(t *testing.T) {
	request := renderedRequest(t, "public")
	content := strings.Replace(renderValuesYAML(request),
		"  tag: \"CHANGE_ME_COMMIT_SHA\"", "  tag: \"already-built-image\"", 1)
	stopped := request
	stopped.DesiredRuntimeState = runtimeStopped
	got, err := patchRuntimeValues(content, stopped)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Replace(content, "replicaCount: 1", "replicaCount: 0", 1)
	want = strings.Replace(want, "exposure:\n  enabled: true", "exposure:\n  enabled: false", 1)
	if got != want || !strings.Contains(got, "  tag: \"already-built-image\"") {
		t.Fatalf("runtime patch가 다른 values를 변경함:\n%s", got)
	}
	wrong := stopped
	wrong.ID = "fedcba9876543210"
	if _, err := patchRuntimeValues(content, wrong); err == nil {
		t.Fatal("target values와 다른 요청 ID를 허용함")
	}
	if _, err := patchRuntimeValues(content+"replicaCount: 7\n", stopped); err == nil {
		t.Fatal("중복 replicaCount를 허용함")
	}
}

func TestVerifyRuntimeBranchRejectsChangesBeyondTargetPatch(t *testing.T) {
	request := renderedRequest(t, "public")
	request.DesiredRuntimeState = runtimeStopped
	target := renderValuesYAML(renderedRequest(t, "public"))
	expected, err := patchRuntimeValues(target, request)
	if err != nil {
		t.Fatal(err)
	}
	branchContent := expected
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.URL.Path, "/contents/") {
			http.NotFound(w, r)
			return
		}
		content := target
		if r.URL.Query().Get("ref") != "main" {
			content = branchContent
		}
		_ = json.NewEncoder(w).Encode(map[string]string{
			"sha": "blob-sha", "encoding": "base64",
			"content": base64.StdEncoding.EncodeToString([]byte(content)),
		})
	}))
	t.Cleanup(server.Close)
	client := newForgejoClient(forgejoConfig{
		BaseURL: server.URL, Owner: "platform", Repo: "gitops", Token: "token", TargetBranch: "main",
	}, nil, log.New(io.Discard, "", 0))
	branch := client.runtimeBranch(request)
	if err := client.verifyRuntimeBranch(context.Background(), request, branch, appValuesPath(request.Profile)); err != nil {
		t.Fatalf("정확한 target patch 거부: %v", err)
	}
	branchContent = strings.Replace(expected, "LOG_LEVEL: \"info\"", "LOG_LEVEL: \"debug\"", 1)
	if err := client.verifyRuntimeBranch(context.Background(), request, branch, appValuesPath(request.Profile)); err == nil {
		t.Fatal("runtime 외 설정까지 바꾼 PR head를 허용함")
	}
}

func TestCreatePullRequestRecoversWhenSuccessResponseIsLost(t *testing.T) {
	created := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/pulls"):
			// Forgejo에는 생성됐지만 reverse proxy 응답이 유실된 상황을 흉내 낸다.
			created = true
			http.Error(w, "upstream response lost", http.StatusBadGateway)
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/pulls") && created:
			_, _ = w.Write([]byte(`[{
  "number":11,"html_url":"https://forgejo.example/pulls/11","state":"open",
  "head":{"ref":"portal/stop-demo-request-1"}
}]`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	client := newForgejoClient(forgejoConfig{
		BaseURL: server.URL, Owner: "platform", Repo: "gitops", Token: "token", TargetBranch: "main",
	}, nil, log.New(io.Discard, "", 0))
	pr, err := client.createPullRequest(context.Background(),
		"portal/stop-demo-request-1", "stop", "body")
	if err != nil || pr == nil || pr.Number != 11 {
		t.Fatalf("응답 유실 뒤 기존 open PR 복구 실패: pr=%+v err=%v", pr, err)
	}
}

func TestRuntimeApplicationAcceptsSyncedDescendantWithDesiredValues(t *testing.T) {
	request := renderedRequest(t, "public")
	request.Profile.App.Environment = "prod"
	request.DesiredRuntimeState = runtimeStopped
	values, err := patchRuntimeValues(renderValuesYAML(request), request)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/applications/"):
			_, _ = w.Write([]byte(`{"status":{"sync":{"status":"Synced","revision":"descendant-revision"}}}`))
		case strings.Contains(r.URL.Path, "/contents/") && r.URL.Query().Get("ref") == "descendant-revision":
			_ = json.NewEncoder(w).Encode(map[string]string{
				"sha": "blob-sha", "encoding": "base64",
				"content": base64.StdEncoding.EncodeToString([]byte(values)),
			})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	tokenPath := writeTestToken(t)
	client := newForgejoClient(forgejoConfig{
		BaseURL: server.URL, Owner: "platform", Repo: "gitops", Token: "token", TargetBranch: "main",
	}, nil, log.New(io.Discard, "", 0))
	client.builder = &buildPipeline{
		base: server.URL, tokenPath: tokenPath,
		client: &http.Client{}, logger: log.New(io.Discard, "", 0),
	}
	synced, err := client.runtimeApplicationSynced(context.Background(), request, "skipped-revision")
	if err != nil || !synced {
		t.Fatalf("원하는 values를 포함한 후속 Synced revision 거부: synced=%t err=%v", synced, err)
	}
}

func writeTestToken(t *testing.T) string {
	t.Helper()
	path := t.TempDir() + "/token"
	if err := os.WriteFile(path, []byte("test-token"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDeploymentReadyRequiresExactStatusReplicaCount(t *testing.T) {
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/deployments/demo"):
			_, _ = w.Write([]byte(`{"metadata":{"generation":2},"spec":{"replicas":1,"template":{"spec":{"containers":[{"image":"registry/demo:v1"}]}}},"status":{"observedGeneration":2,"replicas":2,"readyReplicas":1,"updatedReplicas":1,"availableReplicas":1}}`))
		case strings.Contains(r.URL.Path, "/pods"):
			_, _ = w.Write([]byte(`{"items":[]}`))
		default:
			http.NotFound(w, r)
		}
	})
	request := deploymentRequest{Generated: generatedPlan{Image: "registry/demo:v1"}}
	request.Profile.App.Name = "demo"
	request.Profile.Replicas = 1
	ready, err := api.forgejo.builder.deploymentReady(context.Background(), request, request.Generated.Image)
	if err != nil || ready {
		t.Fatalf("status.replicas 초과 rollout을 Ready로 판정: ready=%t err=%v", ready, err)
	}
}

func TestDeploymentStoppedWaitsUntilSelectedPodsAreGone(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		podJSON string
		want    bool
	}{
		{name: "terminating pod remains", podJSON: `{"items":[{}]}`},
		{name: "completed pod remains", podJSON: `{"items":[{"status":{"phase":"Succeeded"}}]}`, want: true},
		{name: "failed pod remains", podJSON: `{"items":[{"status":{"phase":"Failed"}}]}`, want: true},
		{name: "all pods gone", podJSON: `{"items":[]}`, want: true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/apis/apps/v1/namespaces/" + zoneNamespace() + "/deployments/demo":
					_, _ = w.Write([]byte(`{"metadata":{"generation":3},"spec":{"replicas":0},"status":{"observedGeneration":3,"replicas":0,"readyReplicas":0,"updatedReplicas":0,"availableReplicas":0}}`))
				case "/api/v1/namespaces/" + zoneNamespace() + "/pods":
					_, _ = w.Write([]byte(testCase.podJSON))
				default:
					http.NotFound(w, r)
				}
			})
			request := deploymentRequest{}
			request.Profile.App.Name = "demo"
			got, err := api.forgejo.builder.deploymentStopped(context.Background(), request)
			if err != nil || got != testCase.want {
				t.Fatalf("stopped=%t err=%v, want %t", got, err, testCase.want)
			}
		})
	}
}

func TestLifecycleReconcileCASDoesNotOverwriteConcurrentDelete(t *testing.T) {
	const revision = "runtime-revision"
	entered := make(chan struct{})
	release := make(chan struct{})
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/applications/") {
			close(entered)
			<-release
			_, _ = w.Write([]byte(`{"status":{"sync":{"status":"Synced","revisions":["` + revision + `"]}}}`))
			return
		}
		http.NotFound(w, r)
	})
	request := deploymentRequest{
		ID: "runtime-race", State: stateFailed, FailedFromState: stateStopping,
		Requester: "owner@example.invalid", DesiredRuntimeState: runtimeStopped,
		RuntimeGeneration: 1, RuntimeDesiredRevision: revision,
	}
	request.Profile.App.Name = "demo"
	request.Profile.App.Environment = "prod"
	if err := api.store.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	result := make(chan deploymentRequest, 1)
	go func() {
		result <- api.reconcileDeploymentRequest(context.Background(), request)
	}()
	<-entered
	deleting, _, err := api.store.beginDelete(request.ID, request.Requester)
	if err != nil {
		t.Fatal(err)
	}
	close(release)
	got := <-result
	stored, _ := api.store.get(request.ID)
	if got.State != stateDeleting || stored.State != stateDeleting ||
		got.UpdatedAt != deleting.UpdatedAt {
		t.Fatalf("오래된 reconcile이 동시 삭제를 덮음: got=%+v stored=%+v", got, stored)
	}
}

func TestReconcileLifecycleAfterWorkerTimeout(t *testing.T) {
	const revision = "runtime-revision"
	api := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/apis/argoproj.io/v1alpha1/namespaces/" + argoNamespace + "/applications/demo-prod":
			_, _ = w.Write([]byte(`{"status":{"sync":{"status":"Synced","revisions":["` + revision + `"]}}}`))
		case "/apis/apps/v1/namespaces/" + zoneNamespace() + "/deployments/demo":
			_, _ = w.Write([]byte(`{"metadata":{"generation":3},"spec":{"replicas":0},"status":{"observedGeneration":3,"replicas":0,"readyReplicas":0,"updatedReplicas":0,"availableReplicas":0}}`))
		case "/api/v1/namespaces/" + zoneNamespace() + "/pods":
			_, _ = w.Write([]byte(`{"items":[]}`))
		default:
			http.NotFound(w, r)
		}
	})
	request := deploymentRequest{
		ID: "runtime-timeout", State: stateFailed, FailedFromState: stateStopping,
		DesiredRuntimeState: runtimeStopped, RuntimeDesiredRevision: revision,
	}
	request.Profile.App.Name = "demo"
	request.Profile.App.Environment = "prod"
	if err := api.store.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	got := api.reconcileDeploymentRequest(context.Background(), request)
	if got.State != stateStopped || !got.RuntimeApplicationSynced || got.FailedFromState != "" {
		t.Fatalf("중지 상태로 수렴하지 않음: %+v", got)
	}
}
