package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
)

// quotaInput은 preset과 replicas만 바꾼 유효한 신청 본문이다.
func quotaInput(resourceSize string, replicas int) string {
	return `{
  "appName":"research-viewer",
  "project":"research",
  "environment":"beta",
  "gitRepository":"https://forgejo.example/research/research-viewer.git",
  "branch":"main",
  "dockerfile":"Dockerfile",
  "containerPort":8080,
  "exposure":"public",
  "resourceSize":"` + resourceSize + `",
  "replicas":` + strconv.Itoa(replicas) + `
}`
}

func TestParseQuantities(t *testing.T) {
	cpuCases := map[string]int64{"500m": 500, "1": 1000, "1.5": 1500, "0.1": 100, "3": 3000}
	for input, want := range cpuCases {
		got, err := parseCPUMilli(input)
		if err != nil || got != want {
			t.Fatalf("parseCPUMilli(%q)=%d,%v want %d", input, got, err, want)
		}
	}
	memoryCases := map[string]int64{"512Mi": 512 << 20, "5Gi": 5 << 30, "1G": 1000 * 1000 * 1000, "1024": 1024}
	for input, want := range memoryCases {
		got, err := parseMemoryBytes(input)
		if err != nil || got != want {
			t.Fatalf("parseMemoryBytes(%q)=%d,%v want %d", input, got, err, want)
		}
	}
	for _, bad := range []string{"", "abc", "-1", "1Xi", "500 m"} {
		if _, err := parseCPUMilli(bad); err == nil {
			t.Fatalf("parseCPUMilli(%q)가 통과했다", bad)
		}
	}
	// 상한 문자열이 깨졌으면 "무제한"이 아니라 오류여야 한다.
	original := configuredUserQuota
	t.Cleanup(func() { configuredUserQuota = original })
	configuredUserQuota = userQuota{CPU: "세개", Memory: "5Gi"}
	if _, _, err := exceedsUserQuota(catalog().ResourcePresets["small"], 1); err == nil {
		t.Fatal("상한 오타를 통과시켰다")
	}
}

// TestUserQuotaBoundary는 상한 3 CPU / 5Gi 경계를 고정한다.
// medium(limit 1 CPU / 1Gi) 기준으로 3 Pod까지 허용, 4 Pod부터 거부다.
func TestUserQuotaBoundary(t *testing.T) {
	if configuredUserQuota.CPU != "3" || configuredUserQuota.Memory != "5Gi" {
		t.Fatalf("기본 상한이 계약과 다르다: %+v", configuredUserQuota)
	}
	presets := catalog().ResourcePresets
	cases := []struct {
		size       string
		replicas   int
		wantCPUOut bool
		wantMemOut bool
	}{
		{"small", 5, false, false},  // 2500m / 2560Mi
		{"medium", 3, false, false}, // 3 CPU / 3Gi — 경계 안쪽(같음은 허용)
		{"medium", 4, true, false},  // 4 CPU / 4Gi
		{"medium", 5, true, false},  // 5 CPU / 5Gi — 메모리는 같아서 통과
	}
	for _, testCase := range cases {
		cpuOver, memoryOver, err := exceedsUserQuota(presets[testCase.size], testCase.replicas)
		if err != nil {
			t.Fatalf("%s×%d: %v", testCase.size, testCase.replicas, err)
		}
		if cpuOver != testCase.wantCPUOut || memoryOver != testCase.wantMemOut {
			t.Fatalf("%s×%d: cpuOver=%v memOver=%v want %v/%v",
				testCase.size, testCase.replicas, cpuOver, memoryOver,
				testCase.wantCPUOut, testCase.wantMemOut)
		}
	}
}

// TestValidateRejectsOverQuota는 위저드가 호출하는 검증 API가 상한 초과를 막는지 본다.
func TestValidateRejectsOverQuota(t *testing.T) {
	recorder := request(t, http.MethodPost, "/api/v1/app-profiles/validate",
		quotaInput("medium", 4), "application/json")
	if recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d want=422 body=%s", recorder.Code, recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), "CPU 상한") {
		t.Fatalf("상한 초과 사유가 없다: %s", recorder.Body.String())
	}

	ok := request(t, http.MethodPost, "/api/v1/app-profiles/validate",
		quotaInput("medium", 3), "application/json")
	if ok.Code != http.StatusOK {
		t.Fatalf("경계 안쪽인데 거부됐다: status=%d body=%s", ok.Code, ok.Body.String())
	}
}

// TestCreateRejectsOverQuota는 UI를 우회한 직접 POST도 막히는지 본다.
func TestCreateRejectsOverQuota(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	recorder := postRequest(t, handler, quotaInput("medium", 5), "")
	if recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d want=422 body=%s", recorder.Code, recorder.Body.String())
	}
	over := postRequest(t, handler, quotaInput("medium", 9), "")
	if over.Code != http.StatusUnprocessableEntity {
		t.Fatalf("replicas 상한 초과 status=%d want=422", over.Code)
	}
}

func TestCreateQuotaIncludesExistingAppsButReplacesSameIdentity(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	if first := postAs(t, handler, "owner@example.invalid", quotaInput("medium", 2)); first.Code != http.StatusAccepted {
		t.Fatalf("기존 앱 생성 status=%d body=%s", first.Code, first.Body.String())
	}
	otherApp := strings.Replace(quotaInput("medium", 2), `"research-viewer"`, `"other-app"`, 1)
	if over := postAs(t, handler, "owner@example.invalid", otherApp); over.Code != http.StatusUnprocessableEntity {
		t.Fatalf("기존 2CPU + 신규 2CPU가 통과함: status=%d body=%s", over.Code, over.Body.String())
	}
	// 같은 identity 재배포는 기존 2CPU에 더하지 않고 3CPU로 대체한다.
	if replacement := postAs(t, handler, "owner@example.invalid", quotaInput("medium", 3)); replacement.Code != http.StatusAccepted {
		t.Fatalf("동일 앱 3CPU 교체가 거부됨: status=%d body=%s", replacement.Code, replacement.Body.String())
	}
}

// postAs는 requester 헤더를 붙여 신청을 만든다. 사용량 막대는 사람별로
// 갈라져야 하므로 테스트도 사람을 구분해서 넣는다.
func postAs(t *testing.T, handler http.Handler, requester, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/deployment-requests", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(requesterHeader, requester)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func quotaUsageAs(t *testing.T, handler http.Handler, requester string) quotaUsageResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/quota-usage?requester="+url.QueryEscape(requester), nil)
	req.Header.Set(requesterHeader, requester)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("quota-usage status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var usage quotaUsageResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &usage); err != nil {
		t.Fatalf("사용량 해석 실패: %v", err)
	}
	return usage
}

// TestQuotaUsageIsPerRequester는 사용량 막대가 (1) 첫 사용자에게 0으로 보이고
// (2) 남의 신청을 세지 않는지 고정한다. 지금까지 대시보드가 목데이터를 쓰던 탓에
// 첫 로그인부터 남의 워크로드가 보이던 문제가 이 두 가지였다.
func TestQuotaUsageIsPerRequester(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	first := quotaUsageAs(t, handler, "newcomer@example.invalid")
	if first.UsedCPUMilli != 0 || first.UsedMemoryBytes != 0 || first.Applications != 0 || first.Pods != 0 {
		t.Fatalf("첫 사용자인데 사용량이 0이 아니다: %+v", first)
	}
	if first.Limit.CPU != "3" || first.Limit.Memory != "5Gi" {
		t.Fatalf("상한이 계약과 다르다: %+v", first.Limit)
	}

	// small 1 Pod 신청 하나. 상한이 아니라 신청한 만큼만 올라가야 한다.
	if recorder := postAs(t, handler, "owner@example.invalid", quotaInput("small", 1)); recorder.Code != http.StatusAccepted {
		t.Fatalf("신청 status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	owner := quotaUsageAs(t, handler, "owner@example.invalid")
	preset := catalog().ResourcePresets["small"]
	wantCPU, wantMemory, err := quotaUsage(preset, 1)
	if err != nil {
		t.Fatalf("quotaUsage: %v", err)
	}
	if owner.UsedCPUMilli != wantCPU || owner.UsedMemoryBytes != wantMemory {
		t.Fatalf("사용량 불일치: got cpu=%d mem=%d want cpu=%d mem=%d",
			owner.UsedCPUMilli, owner.UsedMemoryBytes, wantCPU, wantMemory)
	}
	if owner.Applications != 1 || owner.Pods != 1 {
		t.Fatalf("앱/Pod 수 불일치: %+v", owner)
	}
	if owner.UsedCPUMilli > owner.LimitCPUMilli || owner.UsedMemoryBytes > owner.LimitMemoryBytes {
		t.Fatalf("사용량이 상한을 넘었다: %+v", owner)
	}

	// 다른 사람의 막대는 여전히 비어 있어야 한다.
	other := quotaUsageAs(t, handler, "newcomer@example.invalid")
	if other.Applications != 0 || other.UsedCPUMilli != 0 {
		t.Fatalf("남의 신청이 사용량에 섞였다: %+v", other)
	}
}

// TestQuotaUsageCountsLatestPerAppOnly는 같은 앱을 다시 신청했을 때 사용량이
// 두 배로 보이지 않는지 확인한다. 배포되는 것은 앱 하나이기 때문이다.
func TestQuotaUsageCountsLatestPerAppOnly(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)

	for i := 0; i < 3; i++ {
		if recorder := postAs(t, handler, "owner@example.invalid", quotaInput("small", 1)); recorder.Code != http.StatusAccepted {
			t.Fatalf("%d번째 신청 status=%d body=%s", i, recorder.Code, recorder.Body.String())
		}
	}
	// 신청 자체는 3건이 저장돼야 이 테스트가 의미가 있다(중복 제거는 집계 단계의 몫).
	if stored := api.store.list(maxRequestList, "owner@example.invalid"); len(stored) != 3 {
		t.Fatalf("신청이 %d건만 저장됐다. 집계 중복 제거를 검증할 수 없다", len(stored))
	}
	usage := quotaUsageAs(t, handler, "owner@example.invalid")
	if usage.Applications != 1 || usage.Pods != 1 {
		t.Fatalf("같은 앱 재신청이 중복 집계됐다: %+v", usage)
	}
}

// TestCatalogPublishesQuota는 UI가 상한을 하드코딩하지 않도록 카탈로그가
// 상한과 Pod 수 상한을 함께 내려주는지 확인한다.
func TestCatalogPublishesQuota(t *testing.T) {
	recorder := request(t, http.MethodGet, "/api/v1/catalog", "", "")
	var response catalogResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("카탈로그 해석 실패: %v", err)
	}
	if response.UserQuota.CPU != "3" || response.UserQuota.Memory != "5Gi" {
		t.Fatalf("카탈로그 상한 불일치: %+v", response.UserQuota)
	}
	if response.MaxReplicas != maxAppReplicas {
		t.Fatalf("maxReplicas=%d want=%d", response.MaxReplicas, maxAppReplicas)
	}
	// 어떤 preset도 1 Pod만으로 상한을 넘으면 안 된다(첫 신청부터 막히는 상황 방지).
	for name, preset := range response.ResourcePresets {
		cpuOver, memoryOver, err := exceedsUserQuota(preset, 1)
		if err != nil || cpuOver || memoryOver {
			t.Fatalf("preset %s가 1 Pod로 상한을 넘는다(err=%v)", name, err)
		}
	}
}

func TestQuotaCountsFailedRequestAfterGitCommit(t *testing.T) {
	input := profileFromJSON(t, quotaInput("small", 1))
	if errs := validateInput(&input); len(errs) > 0 {
		t.Fatalf("profile invalid: %+v", errs)
	}
	request := deploymentRequest{
		ID: "rollout-failed", State: stateFailed, Requester: "owner@example.invalid",
		Profile:      validationResult(input, true).Profile,
		GitCommitted: true, FailedFromState: stateDeploying,
	}
	cpu, memory, apps, pods := quotaUsageFor([]deploymentRequest{request})
	wantCPU, wantMemory, _ := quotaUsage(request.Profile.Resources, 1)
	if cpu != wantCPU || memory != wantMemory || apps != 1 || pods != 1 {
		t.Fatalf("Git 반영 후 failed가 quota에서 빠짐: cpu=%d memory=%d apps=%d pods=%d",
			cpu, memory, apps, pods)
	}
}

func TestQuotaFallsBackToPreviousDeploymentAfterPreMergeFailure(t *testing.T) {
	oldInput := profileFromJSON(t, quotaInput("small", 1))
	newInput := profileFromJSON(t, quotaInput("medium", 1))
	if errs := validateInput(&oldInput); len(errs) > 0 {
		t.Fatal(errs)
	}
	if errs := validateInput(&newInput); len(errs) > 0 {
		t.Fatal(errs)
	}
	failed := deploymentRequest{ID: "new", State: stateFailed,
		Profile: validationResult(newInput, true).Profile, FailedFromState: statePROpen}
	deployed := deploymentRequest{ID: "old", State: stateDeployed,
		Profile: validationResult(oldInput, true).Profile}
	cpu, _, apps, pods := quotaUsageFor([]deploymentRequest{failed, deployed})
	wantCPU, _, _ := quotaUsage(deployed.Profile.Resources, 1)
	if cpu != wantCPU || apps != 1 || pods != 1 {
		t.Fatalf("merge 전 failed가 이전 배포 quota를 가림: cpu=%d apps=%d pods=%d", cpu, apps, pods)
	}
}
