package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeForgejo는 브랜치·values·Application·PR·merge 엔드포인트를 흉내 내고 호출을 기록한다.
type fakeForgejo struct {
	mu       sync.Mutex
	calls    []string
	bodies   map[string]string
	files    map[string]string
	failNext int
	merged   bool
	checks   string
}

func newFakeForgejo(t *testing.T) (*fakeForgejo, *forgejoClient) {
	t.Helper()
	fake := &fakeForgejo{bodies: map[string]string{}, files: map[string]string{}, checks: "success"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		_ = json.Unmarshal(body, &payload)
		fake.mu.Lock()
		fake.calls = append(fake.calls, r.Method+" "+r.URL.Path)
		fake.bodies[r.Method+" "+r.URL.Path] = string(body)
		fail := fake.failNext > 0
		if fail {
			fake.failNext--
		}
		fileContent, fileExists := fake.files[r.URL.Path]
		if strings.Contains(r.URL.Path, "/contents/") {
			switch r.Method {
			case http.MethodPost:
				fake.files[r.URL.Path] = payload["content"]
			case http.MethodPut:
				// Forgejo contents API는 target/branch별 blob을 갖는다. 기존 fake는
				// path만 저장했으므로 runtime branch 갱신을 target 조회에도 반영한다.
				// branch를 분리하면 merge 시 target으로 옮기는 별도 모사가 필요하다.
				fake.files[r.URL.Path] = payload["content"]
			case http.MethodDelete:
				delete(fake.files, r.URL.Path)
			}
		}
		fake.mu.Unlock()

		if r.Header.Get("Authorization") == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		switch {
		case strings.Contains(r.URL.Path, "/contents/") && r.Method == http.MethodGet:
			if !fileExists {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"sha":"blob-sha","encoding":"base64","content":` +
				strconv.Quote(fileContent) + `}`))
		case strings.HasSuffix(r.URL.Path, "/pulls") && r.Method == http.MethodGet:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`[]`))
		case strings.HasSuffix(r.URL.Path, "/pulls"):
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"number":7,"html_url":"https://forgejo.example/x/y/pulls/7","state":"open"}`))
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/pulls/7"):
			fake.mu.Lock()
			merged := fake.merged
			fake.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"merged":` + strconv.FormatBool(merged) +
				`,"state":"open","head":{"sha":"test-head"}}`))
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/commits/test-head/status"):
			fake.mu.Lock()
			checks := fake.checks
			fake.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"state":` + strconv.Quote(checks) +
				`,"total_count":1,"statuses":[{"status":` + strconv.Quote(checks) + `}]}`))
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/pulls/7/merge"):
			fake.mu.Lock()
			fake.merged = true
			fake.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{}`))
		default:
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	t.Cleanup(server.Close)

	config := forgejoConfig{
		BaseURL:         server.URL,
		Owner:           "platform",
		Repo:            "gitops",
		Token:           "test-token",
		TargetBranch:    "main",
		BranchPrefix:    "portal",
		AllowedGitHosts: []string{"forgejo.example"},
	}
	return fake, newForgejoClient(config, nil, log.New(io.Discard, "", 0))
}

func (f *fakeForgejo) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func postRequest(t *testing.T, handler http.Handler, body, idempotencyKey string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(requesterHeader, "owner@example.invalid")
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func decodeRequest(t *testing.T, recorder *httptest.ResponseRecorder) deploymentRequest {
	t.Helper()
	var request deploymentRequest
	if err := json.Unmarshal(recorder.Body.Bytes(), &request); err != nil {
		t.Fatalf("응답 해석 실패: %v body=%s", err, recorder.Body.String())
	}
	return request
}

// waitForState는 워커가 상태를 바꿀 때까지 짧게 기다린다.
func waitForState(t *testing.T, api *apiServer, id, want string) deploymentRequest {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if request, ok := api.store.get(id); ok && request.State == want {
			return request
		}
		time.Sleep(5 * time.Millisecond)
	}
	request, _ := api.store.get(id)
	t.Fatalf("상태가 %s가 되지 않음: %+v", want, request)
	return request
}

func TestDeploymentRequestCreatesPullRequest(t *testing.T) {
	fake, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	ctx, cancel := contextWithCancel(t)
	defer cancel()
	go client.run(ctx)

	recorder := postRequest(t, handler, validInput("public"), "")
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	created := decodeRequest(t, recorder)
	if created.ID == "" || created.State != stateReceived {
		t.Fatalf("초기 응답이 올바르지 않음: %+v", created)
	}
	if location := recorder.Header().Get("Location"); location != "/api/v1/deployment-requests/"+created.ID {
		t.Fatalf("Location=%q", location)
	}

	// 자동 승인이 켜져 있으므로 PR은 열리자마자 병합까지 진행된다.
	// 테스트에는 빌드 파이프라인이 없어 merged에서 멈춘다.
	final := waitForState(t, api, created.ID, stateMerged)
	if final.PullRequest == nil || final.PullRequest.Number != 7 {
		t.Fatalf("PR 정보 없음: %+v", final)
	}
	if final.PullRequest.State != "merged" {
		t.Fatalf("PR 상태=%q", final.PullRequest.State)
	}
	if fake.callCount() != 8 {
		t.Fatalf("Forgejo 호출 %d회: %v", fake.callCount(), fake.calls)
	}
	mergeBody := fake.bodies["POST /api/v1/repos/platform/gitops/pulls/7/merge"]
	if !strings.Contains(mergeBody, `"merge_when_checks_succeed":false`) {
		t.Fatalf("timeout 뒤 late merge를 막는 명시 merge 요청이 아님: %s", mergeBody)
	}
	if values := fake.bodies["POST /api/v1/repos/platform/gitops/contents/apps/research-viewer/values-beta.yaml"]; values == "" {
		t.Fatalf("values 커밋 호출이 없음: %v", fake.calls)
	}
	if application := fake.bodies["POST /api/v1/repos/platform/gitops/contents/argocd/applications/research-viewer.yaml"]; application == "" {
		t.Fatalf("Argo CD Application 커밋 호출이 없음: %v", fake.calls)
	}
}

func TestMergeDoesNotScheduleWhenChecksArePending(t *testing.T) {
	fake, client := newFakeForgejo(t)
	fake.mu.Lock()
	fake.checks = "pending"
	fake.mu.Unlock()

	previousTimeout := mergeTimeoutSeconds
	mergeTimeoutSeconds = 0
	t.Cleanup(func() { mergeTimeoutSeconds = previousTimeout })

	err := client.mergePullRequest(context.Background(), 7)
	if err == nil || !strings.Contains(err.Error(), "제한 시간") {
		t.Fatalf("pending checks가 timeout으로 끝나지 않음: %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	for _, call := range fake.calls {
		if call == "POST /api/v1/repos/platform/gitops/pulls/7/merge" {
			t.Fatalf("pending checks인데 late merge 예약/명시 merge를 호출함: %v", fake.calls)
		}
	}
}

func TestDeploymentRequestIdempotency(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	ctx, cancel := contextWithCancel(t)
	defer cancel()
	go client.run(ctx)

	first := postRequest(t, handler, validInput("public"), "key-1")
	if first.Code != http.StatusAccepted {
		t.Fatalf("first status=%d", first.Code)
	}
	created := decodeRequest(t, first)

	second := postRequest(t, handler, validInput("public"), "key-1")
	if second.Code != http.StatusOK {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	if replayed := decodeRequest(t, second); replayed.ID != created.ID {
		t.Fatalf("같은 키인데 새 요청이 생성됨: %s != %s", replayed.ID, created.ID)
	}

	conflict := postRequest(t, handler, validInput("oidc"), "key-1")
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflict status=%d body=%s", conflict.Code, conflict.Body.String())
	}
	if list := api.store.list(0, ""); len(list) != 1 {
		t.Fatalf("저장된 요청 %d건", len(list))
	}
}

func TestGroupedDeploymentRequestDoesNotAdoptExistingNamespace(t *testing.T) {
	tests := []struct {
		name        string
		kubeStatus  int
		wantStatus  int
		wantProblem string
	}{
		{
			name: "existing namespace", kubeStatus: http.StatusOK,
			wantStatus: http.StatusConflict, wantProblem: "namespace-owned",
		},
		{
			name: "namespace lookup unavailable", kubeStatus: http.StatusForbidden,
			wantStatus: http.StatusServiceUnavailable, wantProblem: "namespace-check-unavailable",
		},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			fake, client := newFakeForgejo(t)
			api, handler := newTestAPI(t, client)
			probeAPI := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != "/api/v1/namespaces/app-stack" {
					t.Fatalf("예상하지 못한 Namespace 조회: %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(testCase.kubeStatus)
			})
			api.forgejo.builder = probeAPI.forgejo.builder

			body := strings.Replace(validInput("public"),
				`"appName":"research-viewer"`, `"appName":"research-viewer","group":"stack"`, 1)
			recorder := postRequest(t, handler, body, "grouped-request")
			if recorder.Code != testCase.wantStatus || !strings.Contains(recorder.Body.String(), testCase.wantProblem) {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
			if stored := api.store.list(0, "owner@example.invalid"); len(stored) != 0 {
				t.Fatalf("Namespace 확인 실패 뒤 요청 %d건이 저장됨", len(stored))
			}
			if calls := fake.callCount(); calls != 0 {
				t.Fatalf("Namespace 확인 실패 뒤 Forgejo가 %d회 호출됨: %v", calls, fake.calls)
			}
		})
	}
}

func TestGroupedDeploymentRequestBootstrapsWhenNamespaceIsMissing(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	probeAPI := reconciliationAPI(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/namespaces/app-stack" {
			t.Fatalf("예상하지 못한 Namespace 조회: %s %s", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusNotFound)
	})
	api.forgejo.builder = probeAPI.forgejo.builder
	// group 입력은 기존 AppProfile API 호환 계약이다. Namespace가 없으면 bootstrap을
	// 계속 허용해야 하므로, prebuilt image로 빌드 credential 검사와 분리해 확인한다.
	api.openbao = &openBaoClient{}
	input := profileFromJSON(t, validInput("public"))
	input.Group = "stack"
	input.Image = "nginx:1.27"
	input.GitRepository = ""
	input.Branch = ""
	input.Dockerfile = ""
	input.Exposure = exposureInput{Mode: exposureExternal}
	input.Authentication = authenticationInput{Mode: authNone}
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}

	recorder := postRequest(t, handler, string(body), "grouped-new-namespace")
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if stored := api.store.list(0, "owner@example.invalid"); len(stored) != 1 {
		t.Fatalf("Namespace가 없는데 요청이 저장되지 않음: %d건", len(stored))
	}
}

func TestSingleRequestQueueFullReplayReenqueuesDurableRequest(t *testing.T) {
	_, client := newFakeForgejo(t)
	client.queue = make(chan string, 1)
	client.queued = make(map[string]struct{})
	client.queue <- "occupy"
	api, handler := newTestAPI(t, client)

	first := postRequest(t, handler, validInput("public"), "queue-replay")
	if first.Code != http.StatusServiceUnavailable {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	items := api.store.list(10, "owner@example.invalid")
	if len(items) != 1 || items[0].State != stateReceived {
		t.Fatalf("queue full 뒤 durable received가 아님: %+v", items)
	}
	<-client.queue
	replay := postRequest(t, handler, validInput("public"), "queue-replay")
	if replay.Code != http.StatusOK {
		t.Fatalf("replay status=%d body=%s", replay.Code, replay.Body.String())
	}
	if len(api.store.list(10, "owner@example.invalid")) != 1 || len(client.queue) != 1 {
		t.Fatalf("replay가 중복 저장됐거나 queue 복구 실패: stored=%d queued=%d",
			len(api.store.list(10, "owner@example.invalid")), len(client.queue))
	}
}

func TestExternalHostTypedIdentityAvoidsHyphenCollision(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	existingInput := profileFromJSON(t, strings.Replace(validInput("public"),
		`"appName":"research-viewer"`, `"appName":"api"`, 1))
	existingInput.Group = "mobility"
	if errs := validateInput(&existingInput); len(errs) > 0 {
		t.Fatalf("existing profile invalid: %+v", errs)
	}
	existing := deploymentRequest{
		ID: "existing-host", State: stateDeployed, Requester: "owner@example.invalid",
		Profile: validationResult(existingInput, true).Profile,
	}
	if err := api.store.create(existing, "", ""); err != nil {
		t.Fatal(err)
	}
	colliding := strings.Replace(validInput("public"),
		`"appName":"research-viewer"`, `"appName":"api-mobility"`, 1)
	response := postRequest(t, handler, colliding, "host-collision")
	if response.Code != http.StatusAccepted {
		t.Fatalf("injective host인데 status=%d body=%s", response.Code, response.Body.String())
	}
	var created deploymentRequest
	if err := json.Unmarshal(response.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Profile.Exposure.Host == existing.Profile.Exposure.Host ||
		!strings.HasPrefix(existing.Profile.Exposure.Host, "ga-") {
		t.Fatalf("group/single host identity가 분리되지 않음: group=%q single=%q",
			existing.Profile.Exposure.Host, created.Profile.Exposure.Host)
	}
}

func TestDeploymentRequestRejectsAppNameOwnedByAnotherUser(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)
	postAs := func(user string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests", strings.NewReader(validInput("public")))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(requesterHeader, user)
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		return recorder
	}
	if first := postAs("owner@example.invalid"); first.Code != http.StatusAccepted {
		t.Fatalf("첫 신청 status=%d body=%s", first.Code, first.Body.String())
	}
	if second := postAs("other@example.invalid"); second.Code != http.StatusConflict {
		t.Fatalf("다른 사용자 재신청 status=%d body=%s", second.Code, second.Body.String())
	}
}

func TestOIDCDeploymentFailsClosedWithoutOpenBao(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)
	response := postRequest(t, handler, validInput("oidc"), "")
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("OpenBao 없는 OIDC 생성 status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestDeploymentRequestGetAndList(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	created := decodeRequest(t, postRequest(t, handler, validInput("public"), ""))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/deployment-requests/"+created.ID, nil)
	req.Header.Set(requesterHeader, "owner@example.invalid")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("get status=%d", recorder.Code)
	}
	if fetched := decodeRequest(t, recorder); fetched.ID != created.ID {
		t.Fatalf("다른 요청 반환: %s", fetched.ID)
	}

	missing := httptest.NewRequest(http.MethodGet, "/api/v1/deployment-requests/deadbeefdeadbeef", nil)
	missing.Header.Set(requesterHeader, "owner@example.invalid")
	missingRecorder := httptest.NewRecorder()
	handler.ServeHTTP(missingRecorder, missing)
	if missingRecorder.Code != http.StatusNotFound {
		t.Fatalf("missing status=%d", missingRecorder.Code)
	}

	listReq := httptest.NewRequest(http.MethodGet, "/api/v1/deployment-requests?limit=10", nil)
	listReq.Header.Set(requesterHeader, "owner@example.invalid")
	listRecorder := httptest.NewRecorder()
	handler.ServeHTTP(listRecorder, listReq)
	if listRecorder.Code != http.StatusOK {
		t.Fatalf("list status=%d", listRecorder.Code)
	}
	var list deploymentRequestList
	if err := json.Unmarshal(listRecorder.Body.Bytes(), &list); err != nil {
		t.Fatalf("목록 해석 실패: %v", err)
	}
	if list.Count != 1 || len(list.Items) != 1 || list.Items[0].ID != created.ID {
		t.Fatalf("목록이 올바르지 않음: %+v", list)
	}

	badLimit := httptest.NewRequest(http.MethodGet, "/api/v1/deployment-requests?limit=0", nil)
	badLimit.Header.Set(requesterHeader, "owner@example.invalid")
	badRecorder := httptest.NewRecorder()
	handler.ServeHTTP(badRecorder, badLimit)
	if badRecorder.Code != http.StatusBadRequest {
		t.Fatalf("limit=0 status=%d", badRecorder.Code)
	}
}

func TestDeploymentRequestUserHandlersRequireRequesterHeader(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	tests := []struct {
		method string
		target string
		body   string
	}{
		{http.MethodPost, "/api/v1/deployment-requests?requester=spoofed", validInput("public")},
		{http.MethodGet, "/api/v1/deployment-requests?requester=spoofed", ""},
		{http.MethodGet, "/api/v1/deployment-requests/deadbeefdeadbeef?requester=spoofed", ""},
		{http.MethodPut, "/api/v1/deployment-requests/deadbeefdeadbeef/runtime-state?requester=spoofed", `{"state":"stopped"}`},
		{http.MethodDelete, "/api/v1/deployment-requests/deadbeefdeadbeef?requester=spoofed", ""},
		{http.MethodGet, "/api/v1/quota-usage?requester=spoofed", ""},
	}
	for _, testCase := range tests {
		req := httptest.NewRequest(testCase.method, testCase.target, strings.NewReader(testCase.body))
		if testCase.body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("%s %s status=%d body=%s", testCase.method, testCase.target, recorder.Code, recorder.Body.String())
		}
	}
}

func TestDeleteDeploymentRequestRequiresOwnerAndIsIdempotent(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	ctx, cancel := contextWithCancel(t)
	defer cancel()
	go client.run(ctx)

	post := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests",
		strings.NewReader(validInput("public")))
	post.Header.Set("Content-Type", "application/json")
	post.Header.Set(requesterHeader, "owner@example.invalid")
	createdRecorder := httptest.NewRecorder()
	handler.ServeHTTP(createdRecorder, post)
	created := decodeRequest(t, createdRecorder)
	deployed := waitForState(t, api, created.ID, stateMerged)
	deployed.State = stateDeployed
	if err := api.store.update(deployed); err != nil {
		t.Fatal(err)
	}

	remove := func(user string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(http.MethodDelete,
			"/api/v1/deployment-requests/"+created.ID, nil)
		req.Header.Set(requesterHeader, user)
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		return recorder
	}

	if other := remove("other@example.invalid"); other.Code != http.StatusNotFound {
		t.Fatalf("남의 앱 삭제 status=%d body=%s", other.Code, other.Body.String())
	}
	accepted := remove("owner@example.invalid")
	if accepted.Code != http.StatusAccepted {
		t.Fatalf("삭제 접수 status=%d body=%s", accepted.Code, accepted.Body.String())
	}
	deleted := waitForState(t, api, created.ID, stateDeleted)
	if !deleted.DeletionRequested || (deleted.PullRequest != nil && deleted.PullRequest.State != "merged") {
		t.Fatalf("삭제 결과가 올바르지 않음: %+v", deleted)
	}
	if replay := remove("owner@example.invalid"); replay.Code != http.StatusOK {
		t.Fatalf("삭제 재요청 status=%d body=%s", replay.Code, replay.Body.String())
	}
}

func TestDeleteDeploymentRequestRejectsStaleAndInProgress(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)

	create := func() deploymentRequest {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests",
			strings.NewReader(validInput("public")))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(requesterHeader, "owner@example.invalid")
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		return decodeRequest(t, recorder)
	}
	old := create()
	latest := create()

	remove := func(id string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(http.MethodDelete,
			"/api/v1/deployment-requests/"+id, nil)
		req.Header.Set(requesterHeader, "owner@example.invalid")
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		return recorder
	}
	if stale := remove(old.ID); stale.Code != http.StatusConflict {
		t.Fatalf("과거 요청 삭제 status=%d body=%s", stale.Code, stale.Body.String())
	}
	if active := remove(latest.ID); active.Code != http.StatusConflict {
		t.Fatalf("진행 중 요청 삭제 status=%d body=%s", active.Code, active.Body.String())
	}
	if request, _ := api.store.get(latest.ID); request.State != stateReceived {
		t.Fatalf("거부된 최신 요청 상태가 바뀜: %+v", request)
	}
}

// 포털의 "내 애플리케이션"은 남의 신청을 보여주면 안 된다. 목록 API가 신청자
// 기준으로 좁혀지는지, 이력이 없는 사용자에게 빈 목록이 가는지 확인한다.
func TestDeploymentRequestListFiltersByRequester(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	post := func(user, appName string) deploymentRequest {
		t.Helper()
		body := strings.Replace(validInput("public"), `"research-viewer"`, `"`+appName+`"`, 1)
		req := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(requesterHeader, user)
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		if recorder.Code != http.StatusAccepted {
			t.Fatalf("post status=%d body=%s", recorder.Code, recorder.Body.String())
		}
		return decodeRequest(t, recorder)
	}

	mine := post("me@example.invalid", "paper-catalog")
	post("other@example.invalid", "other-app")

	listBy := func(query string, header ...string) deploymentRequestList {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/api/v1/deployment-requests"+query, nil)
		if len(header) == 1 {
			req.Header.Set(requesterHeader, header[0])
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		if recorder.Code != http.StatusOK {
			t.Fatalf("list status=%d body=%s", recorder.Code, recorder.Body.String())
		}
		var list deploymentRequestList
		if err := json.Unmarshal(recorder.Body.Bytes(), &list); err != nil {
			t.Fatalf("목록 해석 실패: %v", err)
		}
		return list
	}

	scoped := listBy("?requester=other%40example.invalid", "me@example.invalid")
	if scoped.Count != 1 || scoped.Items[0].ID != mine.ID {
		t.Fatalf("본인 신청만 보여야 함: %+v", scoped)
	}
	if scoped.Requester != "me@example.invalid" {
		t.Fatalf("requester 에코가 다름: %q", scoped.Requester)
	}
	if first := listBy("?requester=me%40example.invalid", "newcomer@example.invalid"); first.Count != 0 || len(first.Items) != 0 {
		t.Fatalf("첫 사용자에게는 빈 목록이어야 함: %+v", first)
	}

	// 신원은 헤더가 우선이다. 파라미터를 빼거나 남의 이름을 넣어도
	// 헤더 주인의 신청만 나와야 한다.
	byHeader := listBy("", "me@example.invalid")
	if byHeader.Count != 1 || byHeader.Items[0].ID != mine.ID {
		t.Fatalf("헤더만으로 본인 신청이 걸러져야 함: %+v", byHeader)
	}
	spoofed := listBy("?requester=other%40example.invalid", "me@example.invalid")
	if spoofed.Count != 1 || spoofed.Items[0].ID != mine.ID {
		t.Fatalf("파라미터가 헤더를 덮어쓰면 안 됨: %+v", spoofed)
	}

	// 헤더가 없으면 query에 requester를 넣어도 인증 자료로 쓰지 않는다.
	missingIdentity := httptest.NewRequest(http.MethodGet,
		"/api/v1/deployment-requests?requester=me%40example.invalid", nil)
	missingIdentityRecorder := httptest.NewRecorder()
	handler.ServeHTTP(missingIdentityRecorder, missingIdentity)
	if missingIdentityRecorder.Code != http.StatusBadRequest {
		t.Fatalf("헤더 없는 목록 status=%d body=%s", missingIdentityRecorder.Code, missingIdentityRecorder.Body.String())
	}

	// 상세 URL도 같은 소유권 경계를 지킨다. 남의 ID는 404로 존재 여부를 숨긴다.
	detail := httptest.NewRequest(http.MethodGet, "/api/v1/deployment-requests/"+mine.ID, nil)
	detail.Header.Set(requesterHeader, "other@example.invalid")
	detailRecorder := httptest.NewRecorder()
	handler.ServeHTTP(detailRecorder, detail)
	if detailRecorder.Code != http.StatusNotFound {
		t.Fatalf("남의 상세 요청 status=%d body=%s", detailRecorder.Code, detailRecorder.Body.String())
	}
}

// TestQuotaUsageScopesToHeaderIdentity는 사용량 막대가 헤더 주인의 것만
// 합산하는지 본다. 파라미터를 조작해 남의 사용량을 들여다볼 수 없어야 한다.
func TestQuotaUsageScopesToHeaderIdentity(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	post := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests",
		strings.NewReader(validInput("public")))
	post.Header.Set("Content-Type", "application/json")
	post.Header.Set(requesterHeader, "other@example.invalid")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, post)
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("post status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	usageFor := func(query, header string) quotaUsageResponse {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/api/v1/quota-usage"+query, nil)
		if header != "" {
			req.Header.Set(requesterHeader, header)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("quota-usage status=%d body=%s", rec.Code, rec.Body.String())
		}
		var usage quotaUsageResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &usage); err != nil {
			t.Fatalf("사용량 해석 실패: %v", err)
		}
		return usage
	}

	if owner := usageFor("", "other@example.invalid"); owner.Applications != 1 {
		t.Fatalf("본인 사용량은 1건이어야 함: %+v", owner)
	}
	newcomer := usageFor("?requester=other%40example.invalid", "newcomer@example.invalid")
	if newcomer.Applications != 0 || newcomer.UsedCPUMilli != 0 || newcomer.Pods != 0 {
		t.Fatalf("첫 사용자 사용량은 0이어야 함: %+v", newcomer)
	}
	if newcomer.LimitCPUMilli == 0 || newcomer.LimitMemoryBytes == 0 {
		t.Fatalf("상한은 0이면 안 됨: %+v", newcomer)
	}
}

func contextWithCancel(t *testing.T) (context.Context, context.CancelFunc) {
	t.Helper()
	return context.WithCancel(context.Background())
}

func TestDeploymentRequestRejectsBadInput(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	cases := []struct {
		name string
		body string
		want int
	}{
		{"빈 객체", `{}`, http.StatusUnprocessableEntity},
		{"알 수 없는 필드", `{"appName":"a","unknown":1}`, http.StatusBadRequest},
		{"본문 2개", validInput("public") + validInput("public"), http.StatusBadRequest},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			recorder := postRequest(t, handler, testCase.body, "")
			if recorder.Code != testCase.want {
				t.Fatalf("status=%d want=%d body=%s", recorder.Code, testCase.want, recorder.Body.String())
			}
		})
	}
}

// statefulForgejo는 실제 Forgejo의 충돌 응답(브랜치 409, 파일 422, PR 409)을 흉내 낸다.
type statefulForgejo struct {
	mu       sync.Mutex
	branches map[string]bool
	files    map[string]string
	pulls    map[string]int
	failPull bool
	merged   bool
	calls    []string
}

func newStatefulForgejo(t *testing.T) (*statefulForgejo, *forgejoClient) {
	t.Helper()
	fake := &statefulForgejo{
		branches: map[string]bool{"main": true},
		files:    map[string]string{},
		pulls:    map[string]int{},
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		_ = json.Unmarshal(body, &payload)

		fake.mu.Lock()
		defer fake.mu.Unlock()
		fake.calls = append(fake.calls, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")

		switch {
		case r.URL.Path == "/api/v1/repos/platform/gitops/branches":
			if fake.branches[payload["new_branch_name"]] {
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"message":"branch already exists"}`))
				return
			}
			fake.branches[payload["new_branch_name"]] = true
			for key, content := range fake.files {
				if strings.HasSuffix(key, "@"+payload["old_branch_name"]) {
					path := strings.TrimSuffix(key, "@"+payload["old_branch_name"])
					fake.files[path+"@"+payload["new_branch_name"]] = content
				}
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{}`))

		case r.URL.Path == "/api/v1/repos/platform/gitops/pulls":
			if r.Method == http.MethodGet {
				items := make([]string, 0, len(fake.pulls))
				for head, number := range fake.pulls {
					items = append(items, `{"number":`+strconv.Itoa(number)+
						`,"html_url":"https://forgejo.example/x/y/pulls/7","state":"open","head":{"ref":"`+head+`"}}`)
				}
				_, _ = w.Write([]byte("[" + strings.Join(items, ",") + "]"))
				return
			}
			if fake.failPull {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			if _, exists := fake.pulls[payload["head"]]; exists {
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"message":"pull request already exists"}`))
				return
			}
			fake.pulls[payload["head"]] = 7
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"number":7,"html_url":"https://forgejo.example/x/y/pulls/7","state":"open"}`))

		case r.URL.Path == "/api/v1/repos/platform/gitops/pulls/7/merge":
			fake.merged = true
			_, _ = w.Write([]byte(`{}`))

		case r.URL.Path == "/api/v1/repos/platform/gitops/pulls/7":
			_, _ = w.Write([]byte(`{"merged":` + strconv.FormatBool(fake.merged) +
				`,"state":"open","head":{"sha":"test-head"}}`))

		case r.URL.Path == "/api/v1/repos/platform/gitops/commits/test-head/status":
			_, _ = w.Write([]byte(`{"state":"success","total_count":1,"statuses":[{"status":"success"}]}`))

		case strings.HasPrefix(r.URL.Path, "/api/v1/repos/platform/gitops/contents/"):
			key := r.URL.Path + "@" + payload["branch"] + r.URL.Query().Get("ref")
			switch r.Method {
			case http.MethodGet:
				content, ok := fake.files[r.URL.Path+"@"+r.URL.Query().Get("ref")]
				if !ok {
					w.WriteHeader(http.StatusNotFound)
					return
				}
				_, _ = w.Write([]byte(`{"sha":"blob-sha-1","encoding":"base64","content":` +
					strconv.Quote(content) + `}`))
			case http.MethodPost:
				if _, ok := fake.files[key]; ok {
					w.WriteHeader(http.StatusUnprocessableEntity)
					_, _ = w.Write([]byte(`{"message":"repository file already exists"}`))
					return
				}
				fake.files[key] = payload["content"]
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(`{}`))
			case http.MethodPut:
				if payload["sha"] != "blob-sha-1" {
					w.WriteHeader(http.StatusUnprocessableEntity)
					return
				}
				fake.files[key] = payload["content"]
				_, _ = w.Write([]byte(`{}`))
			case http.MethodDelete:
				delete(fake.files, r.URL.Path+"@"+payload["branch"])
				_, _ = w.Write([]byte(`{}`))
			}

		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)

	config := forgejoConfig{
		BaseURL:         server.URL,
		Owner:           "platform",
		Repo:            "gitops",
		Token:           "test-token",
		TargetBranch:    "main",
		BranchPrefix:    "portal",
		AllowedGitHosts: []string{"forgejo.example"},
	}
	return fake, newForgejoClient(config, nil, log.New(io.Discard, "", 0))
}

// 앞선 시도가 커밋까지 성공하고 PR에서 끊긴 뒤의 재시도가 성공으로 수렴해야 한다.
func TestForgejoSubmitRecoversFromPartialFailure(t *testing.T) {
	fake, client := newStatefulForgejo(t)
	var input appProfileInput
	if err := json.Unmarshal([]byte(validInput("public")), &input); err != nil {
		t.Fatalf("입력 해석 실패: %v", err)
	}
	result := validationResult(input, true)
	if !result.Valid {
		t.Fatal("정상 입력인데 검증에 실패했다")
	}
	request := deploymentRequest{ID: "req-1", Profile: result.Profile}

	fake.mu.Lock()
	fake.failPull = true
	fake.mu.Unlock()
	if _, err := client.submit(context.Background(), request); err == nil {
		t.Fatal("PR 단계 실패가 에러로 오지 않았다")
	}

	fake.mu.Lock()
	fake.failPull = false
	fake.mu.Unlock()
	pr, err := client.submit(context.Background(), request)
	if err != nil {
		t.Fatalf("재시도가 실패했다: %v", err)
	}
	if pr == nil || pr.Number != 7 {
		t.Fatalf("PR 정보가 올바르지 않음: %+v", pr)
	}

	// 세 번째 시도는 PR까지 이미 열려 있으므로 기존 PR을 찾아 돌려주어야 한다.
	again, err := client.submit(context.Background(), request)
	if err != nil {
		t.Fatalf("PR 중복 시도가 실패했다: %v", err)
	}
	if again == nil || again.Number != 7 {
		t.Fatalf("기존 PR을 찾지 못함: %+v", again)
	}
}

func TestSourceUpdatePullRequestContainsBuiltImageAndOnlyUpdatesValues(t *testing.T) {
	fake, client := newStatefulForgejo(t)
	request := renderedRequest(t, "public")
	request.ID = "source-update"
	request.SourceUpdate = true
	request.Profile.Source.Commit = strings.Repeat("d", 40)
	request.Generated.Image = "registry.example/research-viewer:dddddddddddd-source"
	valuesPath := appValuesPath(request.Profile)
	fake.files["/api/v1/repos/platform/gitops/contents/"+valuesPath+"@main"] =
		base64.StdEncoding.EncodeToString([]byte(portalManagedFileMarker + "\n"))

	pr, err := client.submit(context.Background(), request)
	if err != nil {
		t.Fatalf("source update PR 생성 실패: %v", err)
	}
	if pr == nil || pr.Number != 7 {
		t.Fatalf("source update PR 정보 없음: %+v", pr)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	for _, call := range fake.calls {
		if strings.Contains(call, "/contents/"+appApplicationPath(request.Profile)) {
			t.Fatalf("source update가 기존 Argo Application을 불필요하게 다시 커밋함: %s", call)
		}
	}
	foundImage := false
	for key, encoded := range fake.files {
		if !strings.Contains(key, "/contents/"+valuesPath+"@portal/update-") {
			continue
		}
		decoded, decodeErr := base64.StdEncoding.DecodeString(encoded)
		if decodeErr != nil {
			t.Fatal(decodeErr)
		}
		foundImage = strings.Contains(string(decoded), "repository: \"registry.example/research-viewer\"") &&
			strings.Contains(string(decoded), "tag: \"dddddddddddd-source\"")
	}
	if !foundImage {
		t.Fatalf("source update PR values에 사전 빌드 image가 없음: %v", fake.files)
	}
}

func TestForgejoDeletionWithoutGitOpsFilesIsNoop(t *testing.T) {
	_, client := newStatefulForgejo(t)
	request := renderedRequest(t, "public")
	request.Requester = "owner@example.invalid"

	pullRequest, err := client.submitDeletion(context.Background(), request)
	if err != nil {
		t.Fatalf("GitOps 파일 없는 앱 삭제가 실패함: %v", err)
	}
	if pullRequest != nil {
		t.Fatalf("변경 없는 삭제가 PR을 만들면 안 됨: %+v", pullRequest)
	}
}

func TestForgejoDeletionRecoversAfterDeleteCommitBeforePR(t *testing.T) {
	fake, client := newStatefulForgejo(t)
	request := renderedRequest(t, "public")
	request.ID = "delete-retry"
	request.Requester = "owner@example.invalid"
	for _, path := range []string{appValuesPath(request.Profile), appApplicationPath(request.Profile)} {
		key := "/api/v1/repos/platform/gitops/contents/" + path + "@main"
		fake.files[key] = base64.StdEncoding.EncodeToString([]byte(portalManagedFileMarker + "\n"))
	}
	fake.failPull = true
	if _, err := client.submitDeletion(context.Background(), request); err == nil {
		t.Fatal("PR 생성 전 실패가 호출자에게 전달되지 않았다")
	}
	fake.failPull = false
	pr, err := client.submitDeletion(context.Background(), request)
	if err != nil {
		t.Fatalf("부분 삭제 재시도가 실패함: %v", err)
	}
	if pr == nil || pr.Number != 7 {
		t.Fatalf("삭제 branch 차이를 PR로 복구하지 못함: %+v", pr)
	}
}

func TestForgejoDeletionRecoveryRefusesUnmanagedTargetReplacement(t *testing.T) {
	fake, client := newStatefulForgejo(t)
	request := renderedRequest(t, "public")
	request.ID = "delete-replaced"
	request.Requester = "owner@example.invalid"
	paths := []string{appValuesPath(request.Profile), appApplicationPath(request.Profile)}
	for _, path := range paths {
		fake.files["/api/v1/repos/platform/gitops/contents/"+path+"@main"] =
			base64.StdEncoding.EncodeToString([]byte(portalManagedFileMarker + "\n"))
	}
	fake.failPull = true
	if _, err := client.submitDeletion(context.Background(), request); err == nil {
		t.Fatal("PR 생성 전 실패가 전달되지 않음")
	}
	fake.failPull = false
	// branch의 delete commit 뒤 target 경로를 사람이 비관리 파일로 교체한 상황이다.
	fake.files["/api/v1/repos/platform/gitops/contents/"+paths[0]+"@main"] =
		base64.StdEncoding.EncodeToString([]byte("# manually managed\n"))
	if _, err := client.submitDeletion(context.Background(), request); err == nil ||
		!strings.Contains(err.Error(), "소유하지 않은 파일") {
		t.Fatalf("비관리 target 교체를 거부하지 않음: %v", err)
	}
}

func TestForgejoQueueDeduplicatesIdempotentRetry(t *testing.T) {
	client := &forgejoClient{queue: make(chan string, 2), queued: make(map[string]struct{})}
	if err := client.enqueue("same-request"); err != nil {
		t.Fatal(err)
	}
	if err := client.enqueue("same-request"); err != nil {
		t.Fatal(err)
	}
	if got := len(client.queue); got != 1 {
		t.Fatalf("동일 요청이 큐에 %d번 들어감", got)
	}
	if got := <-client.queue; got != "same-request" {
		t.Fatalf("queue request=%q", got)
	}
	client.finishQueued("same-request")
	if err := client.enqueue("same-request"); err != nil {
		t.Fatal(err)
	}
	if got := len(client.queue); got != 1 {
		t.Fatalf("처리 완료 뒤 재시도는 다시 큐에 들어가야 함: %d", got)
	}
}

func TestForgejoQueueRerunsTransitionMadeWhileProcessing(t *testing.T) {
	client := &forgejoClient{queue: make(chan string, 1), queued: make(map[string]struct{})}
	if err := client.enqueue("transitioning"); err != nil {
		t.Fatal(err)
	}
	if got := <-client.queue; got != "transitioning" {
		t.Fatalf("queue request=%q", got)
	}
	client.beginQueued("transitioning")
	// worker가 deployed/failed를 기록한 직후 DELETE가 같은 ID를 다시 예약하는 창이다.
	if err := client.enqueue("transitioning"); err != nil {
		t.Fatal(err)
	}
	if rerun := client.finishQueued("transitioning"); !rerun {
		t.Fatal("processing 중 상태 전이 재예약을 잃음")
	}
	if rerun := client.finishQueued("transitioning"); rerun {
		t.Fatal("한 번 소비한 rerun flag가 남음")
	}
}

func TestForgejoRefusesToOverwriteOrDeleteUnmanagedFile(t *testing.T) {
	fake, client := newStatefulForgejo(t)
	const filePath = "apps/portal-lite/values-beta.yaml"
	key := "/api/v1/repos/platform/gitops/contents/" + filePath + "@main"
	fake.mu.Lock()
	fake.files[key] = base64.StdEncoding.EncodeToString([]byte("# platform 정적 파일\napp:\n  name: portal-lite\n"))
	fake.mu.Unlock()

	err := client.putFile(context.Background(), "main", filePath, "unsafe update",
		portalManagedFileMarker+"\n")
	if err == nil || !strings.Contains(err.Error(), "소유하지 않은 파일") {
		t.Fatalf("정적 파일 덮어쓰기를 거부하지 않음: %v", err)
	}
	deleted, err := client.deleteFile(context.Background(), "main", filePath, "unsafe delete")
	if err == nil || deleted || !strings.Contains(err.Error(), "소유하지 않은 파일") {
		t.Fatalf("정적 파일 삭제를 거부하지 않음: deleted=%t err=%v", deleted, err)
	}
}

func TestForgejoDoesNotSendBuildCredentialsToUnapprovedGitHost(t *testing.T) {
	fake, client := newFakeForgejo(t)
	request := renderedRequest(t, "public")
	request.Profile.Source.Repository = "https://attacker.invalid/capture/repository.git"

	if _, err := client.submit(context.Background(), request); err == nil ||
		!strings.Contains(err.Error(), "credential 허용 목록") {
		t.Fatalf("미승인 Git host를 거부하지 않음: %v", err)
	}
	if calls := fake.callCount(); calls != 0 {
		t.Fatalf("거부 전에 Forgejo 변경 호출이 발생함: %d", calls)
	}
}

// 자동 승인을 끄면 예전처럼 PR만 열고 사람 손을 기다려야 한다.
func TestDeploymentRequestKeepsPullRequestOpenWithoutAutoApprove(t *testing.T) {
	previous := autoApprove
	autoApprove = false
	t.Cleanup(func() { autoApprove = previous })

	fake, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	ctx, cancel := contextWithCancel(t)
	defer cancel()
	go client.run(ctx)

	recorder := postRequest(t, handler, validInput("public"), "")
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	created := decodeRequest(t, recorder)

	final := waitForState(t, api, created.ID, statePROpen)
	if final.PullRequest == nil || final.PullRequest.State == "merged" {
		t.Fatalf("자동 병합이 일어남: %+v", final)
	}
	for _, call := range fake.calls {
		if strings.Contains(call, "/merge") {
			t.Fatalf("병합 호출이 있음: %v", fake.calls)
		}
	}
}
