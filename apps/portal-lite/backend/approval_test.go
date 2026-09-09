package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"
)

func adminRequest(
	t *testing.T, handler http.Handler, method, target, body, role string,
) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	request.Header.Set(requesterHeader, "platform-admin@example.invalid")
	request.Header.Set(rolesHeader, role)
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func waitForApproval(
	t *testing.T, api *apiServer, requestID, status string,
) deploymentRequest {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if request, ok := api.store.get(requestID); ok && request.Approval.Status == status && (status != approvalRejected || (request.PullRequest != nil && request.PullRequest.State == "closed")) {
			return request
		}
		time.Sleep(5 * time.Millisecond)
	}
	request, _ := api.store.get(requestID)
	t.Fatalf("승인 상태가 %s가 되지 않음: %+v", status, request)
	return request
}

func createManualApprovalRequest(
	t *testing.T, checks string,
) (*fakeForgejo, *forgejoClient, *apiServer, http.Handler, deploymentRequest, func()) {
	t.Helper()
	fake, client := newFakeForgejo(t)
	fake.mu.Lock()
	fake.checks = checks
	fake.mu.Unlock()
	api, handler := newTestAPI(t, client)
	if _, err := api.store.setApprovalPolicy("owner@example.invalid", "test-platform-admin", false); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := contextWithCancel(t)
	go client.run(ctx)
	recorder := postRequest(t, handler, validInput("public"), "")
	if recorder.Code != http.StatusAccepted {
		cancel()
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	created := decodeRequest(t, recorder)
	waitForState(t, api, created.ID, statePROpen)
	return fake, client, api, handler, created, cancel
}

func TestAdminApprovalEndpointsRequirePlatformAdmin(t *testing.T) {
	_, client := newFakeForgejo(t)
	_, handler := newTestAPI(t, client)

	for _, role := range []string{"", "viewer", "app-admin", "deployments:write"} {
		recorder := adminRequest(t, handler, http.MethodGet,
			"/api/v1/admin/approval-dashboard", "", role)
		if recorder.Code != http.StatusForbidden {
			t.Fatalf("role=%q status=%d body=%s", role, recorder.Code, recorder.Body.String())
		}
	}
	recorder := adminRequest(t, handler, http.MethodGet,
		"/api/v1/admin/approval-dashboard", "", adminRole)
	if recorder.Code != http.StatusOK {
		t.Fatalf("platform-admin status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestManualApprovalPersistsEvidenceBeforeMerge(t *testing.T) {
	fake, _, api, handler, created, cancel := createManualApprovalRequest(t, "success")
	defer cancel()

	recorder := adminRequest(t, handler, http.MethodPost,
		"/api/v1/admin/deployment-requests/"+created.ID+"/decision",
		`{"decision":"approved"}`, adminRole)
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	approved := waitForApproval(t, api, created.ID, approvalApproved)
	if approved.Approval.DecidedBy != "platform-admin@example.invalid" ||
		approved.Approval.DecidedAt == nil || approved.Approval.Automatic {
		t.Fatalf("수동 승인 감사 증거가 올바르지 않음: %+v", approved.Approval)
	}
	final := waitForState(t, api, created.ID, stateMerged)
	if final.SecurityReview.Status != securityPassed {
		t.Fatalf("보안 통과 증거 없이 병합됨: %+v", final.SecurityReview)
	}
	fake.mu.Lock()
	merged := fake.merged
	fake.mu.Unlock()
	if !merged {
		t.Fatal("승인 뒤 Forgejo 병합이 실행되지 않음")
	}
}

func TestManualRejectionClosesPullRequestAndHidesPrivateLink(t *testing.T) {
	fake, _, api, handler, created, cancel := createManualApprovalRequest(t, "pending")
	defer cancel()

	recorder := adminRequest(t, handler, http.MethodPost,
		"/api/v1/admin/deployment-requests/"+created.ID+"/decision",
		`{"decision":"rejected","reason":"승인 범위가 과도합니다."}`, adminRole)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	rejected := waitForApproval(t, api, created.ID, approvalRejected)
	if rejected.Approval.RejectReason != "승인 범위가 과도합니다." ||
		rejected.Approval.DecidedBy != "platform-admin@example.invalid" || rejected.Approval.Automatic {
		t.Fatalf("반려 감사 증거가 올바르지 않음: %+v", rejected.Approval)
	}
	fake.mu.Lock()
	closed, merged := fake.closed, fake.merged
	fake.mu.Unlock()
	if !closed || merged {
		t.Fatalf("PR close/merge 경계 불일치: closed=%t merged=%t", closed, merged)
	}

	request := httptest.NewRequest(http.MethodGet,
		"/api/v1/deployment-requests/"+created.ID, nil)
	request.Header.Set(requesterHeader, "owner@example.invalid")
	public := httptest.NewRecorder()
	handler.ServeHTTP(public, request)
	if public.Code != http.StatusOK || strings.Contains(public.Body.String(), "/pulls/7") ||
		strings.Contains(public.Body.String(), `"pullRequest"`) {
		t.Fatalf("일반 사용자 응답에 private PR이 노출됨: status=%d body=%s",
			public.Code, public.Body.String())
	}
}

func TestApprovalPolicyPersistsAndAppliesToExistingPendingRequest(t *testing.T) {
	_, _, api, handler, created, cancel := createManualApprovalRequest(t, "success")
	defer cancel()

	recorder := adminRequest(t, handler, http.MethodPut,
		"/api/v1/admin/approval-policies/owner@example.invalid",
		`{"enabled":true}`, adminRole)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	final := waitForState(t, api, created.ID, stateMerged)
	if final.Approval.Status != approvalApproved || !final.Approval.Automatic ||
		final.Approval.DecidedBy != "platform-admin@example.invalid" {
		t.Fatalf("기존 대기 요청에 자동 승인 정책이 적용되지 않음: %+v", final.Approval)
	}

	directory := t.TempDir()
	stored, err := newStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	policy, err := stored.setApprovalPolicy("persisted@example.invalid", "audit-admin", true)
	if err != nil {
		t.Fatal(err)
	}
	if err := stored.close(); err != nil {
		t.Fatal(err)
	}
	restored, err := newStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = restored.close() })
	got := restored.approvalPolicy("persisted@example.invalid")
	if !got.Enabled || got.UpdatedBy != "audit-admin" || len(got.History) != 1 ||
		got.History[0].ChangedAt != policy.History[0].ChangedAt {
		t.Fatalf("재시작 뒤 정책 감사 이력 유실: %+v", got)
	}
}

func TestSecurityRejectionCannotBeBypassedByAutoApproval(t *testing.T) {
	fake, client := newFakeForgejo(t)
	fake.mu.Lock()
	fake.checks = "failure"
	fake.mu.Unlock()
	api, handler := newTestAPI(t, client)
	ctx, cancel := contextWithCancel(t)
	defer cancel()
	go client.run(ctx)

	recorder := postRequest(t, handler, validInput("public"), "")
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	created := decodeRequest(t, recorder)
	rejected := waitForApproval(t, api, created.ID, approvalRejected)
	if rejected.SecurityReview.Status != securityRejected ||
		len(rejected.SecurityReview.Findings) != 1 ||
		rejected.SecurityReview.Findings[0].CVE != "CVE-2026-1234" ||
		rejected.SecurityReview.Findings[0].FixedVersion != "3.0.1" {
		t.Fatalf("보안 반려 상세가 유실됨: %+v", rejected.SecurityReview)
	}
	fake.mu.Lock()
	closed, merged := fake.closed, fake.merged
	fake.mu.Unlock()
	if !closed || merged {
		t.Fatalf("자동 승인 예외가 보안 반려를 우회함: closed=%t merged=%t", closed, merged)
	}

	approve := adminRequest(t, handler, http.MethodPost,
		"/api/v1/admin/deployment-requests/"+created.ID+"/decision",
		`{"decision":"approved"}`, adminRole)
	if approve.Code != http.StatusConflict {
		t.Fatalf("보안 반려 뒤 관리자 승인이 허용됨: status=%d body=%s",
			approve.Code, approve.Body.String())
	}
}

func TestRestartKeepsUnapprovedPullRequestFailClosed(t *testing.T) {
	directory := t.TempDir()
	requestStore, err := newStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	request := renderedRequest(t, "public")
	request.State = statePROpen
	request.PullRequest = &pullRequestRef{
		Number: 7, URL: "https://forgejo.example.invalid/x/y/pulls/7",
		Branch: "portal/request", State: "open",
	}
	request.Approval, request.SecurityReview = newReviewEvidence()
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	if err := requestStore.close(); err != nil {
		t.Fatal(err)
	}

	restored, err := newStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = restored.close() })
	fake, client := newFakeForgejo(t)
	client.store = restored
	client.logger = log.New(io.Discard, "", 0)
	snapshot, ok := restored.get(request.ID)
	if !ok {
		t.Fatal("재시작 뒤 요청이 복원되지 않음")
	}
	client.advance(t.Context(), snapshot)
	got, _ := restored.get(request.ID)
	if got.State != statePROpen || got.Approval.Status != approvalPending {
		t.Fatalf("승인 증거 없이 재시작 뒤 진행됨: %+v", got)
	}
	fake.mu.Lock()
	merged := fake.merged
	fake.mu.Unlock()
	if merged {
		t.Fatal("승인 증거 없이 Forgejo merge가 호출됨")
	}
}

func TestAdminDashboardContainsPrivatePullRequest(t *testing.T) {
	_, _, _, handler, created, cancel := createManualApprovalRequest(t, "success")
	defer cancel()
	recorder := adminRequest(t, handler, http.MethodGet,
		"/api/v1/admin/approval-dashboard", "", adminRole)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var dashboard adminApprovalDashboard
	if err := json.Unmarshal(recorder.Body.Bytes(), &dashboard); err != nil {
		t.Fatal(err)
	}
	if len(dashboard.Requests) != 1 || dashboard.Requests[0].ID != created.ID ||
		dashboard.Requests[0].PullRequest == nil || dashboard.Requests[0].PullRequest.URL == "" {
		t.Fatalf("관리자 응답에 감사 PR이 없음: %+v", dashboard)
	}
}

func TestApprovalWithoutOIDCSecretPersistsBeforeDeploymentBoundary(t *testing.T) {
	for _, automatic := range []bool{false, true} {
		t.Run(fmt.Sprintf("automatic=%t", automatic), func(t *testing.T) {
			fake, client := newFakeForgejo(t)
			api, handler := newTestAPI(t, client)
			request := renderedRequest(t, "oidc")
			request.Requester = "owner@example.invalid"
			request.State = statePROpen
			request.PullRequest = &pullRequestRef{Number: 7, State: "open"}
			request.Approval, request.SecurityReview = newReviewEvidence()
			if err := api.store.create(request, "", ""); err != nil {
				t.Fatal(err)
			}
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				switch {
				case strings.Contains(r.URL.Path, "/sys/policies/acl/"):
					writeTestOpenBaoJSON(t, w, testOpenBaoPolicy(testWorkloadPolicy(request.Profile.App.Project, request.Profile.App.Environment)))
				case strings.Contains(r.URL.Path, "/auth/kubernetes/role/"):
					writeTestOpenBaoJSON(t, w, testOpenBaoRole([]string{"*"}, []string{request.Profile.namespace()}, "", openBaoWorkloadPolicy))
				case strings.Contains(r.URL.Path, "/kv/metadata/"):
					writeTestOpenBaoJSON(t, w, testOpenBaoLiveMetadata(1))
				case strings.Contains(r.URL.Path, "/kv/subkeys/"):
					writeTestOpenBaoJSON(t, w, testOpenBaoSubkeys())
				default:
					t.Errorf("unexpected OpenBao call: %s", r.URL.Path)
					w.WriteHeader(http.StatusForbidden)
				}
			}))
			defer server.Close()
			baseURL, _ := url.Parse(server.URL)
			client.openbao = &openBaoClient{baseURL: baseURL, http: server.Client(), token: "test-token", expires: time.Now().Add(time.Hour)}
			if automatic {
				if _, allowed := client.reviewForAdvance(t.Context(), request); !allowed {
					t.Fatal("automatic approval blocked")
				}
			} else {
				response := adminRequest(t, handler, http.MethodPost, "/api/v1/admin/deployment-requests/"+request.ID+"/decision", `{"decision":"approved"}`, adminRole)
				if response.Code != http.StatusAccepted {
					t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
				}
			}
			if calls != 0 {
				t.Fatalf("approval checked OpenBao: %d calls", calls)
			}
			approved, _ := api.store.get(request.ID)
			if approved.Approval.Status != approvalApproved || approved.Approval.Automatic != automatic || approved.Approval.DecidedAt == nil || approved.Approval.DecidedBy == "" {
				t.Fatalf("missing audit: %+v", approved.Approval)
			}
			client.advance(t.Context(), approved)
			failed, _ := api.store.get(request.ID)
			if calls != 4 || failed.State != stateFailed || failed.FailedFromState != statePROpen || failed.Message == "" || !reflect.DeepEqual(failed.Approval, approved.Approval) {
				t.Fatalf("deployment boundary: calls=%d request=%+v", calls, failed)
			}
			if fake.merged {
				t.Fatal("missing OIDC_CLIENT_SECRET allowed merge")
			}
			restored, err := newStore(api.store.dir)
			if err != nil {
				t.Fatal(err)
			}
			defer restored.close()
			durable, _ := restored.get(request.ID)
			if !reflect.DeepEqual(durable.Approval, approved.Approval) {
				t.Fatal("approval audit not durable")
			}
		})
	}
}

func TestManualApprovalRejectsNonAdminPendingChecksAndClosedPR(t *testing.T) {
	for _, scenario := range []string{"non-admin", "pending", "closed"} {
		t.Run(scenario, func(t *testing.T) {
			fake, client := newFakeForgejo(t)
			api, handler := newTestAPI(t, client)
			request := renderedRequest(t, "public")
			request.State = statePROpen
			request.PullRequest = &pullRequestRef{Number: 7, State: "open"}
			request.Approval, request.SecurityReview = newReviewEvidence()
			if err := api.store.create(request, "", ""); err != nil {
				t.Fatal(err)
			}
			role, status := adminRole, http.StatusConflict
			switch scenario {
			case "non-admin":
				role, status = "app-admin", http.StatusForbidden
			case "pending":
				fake.checks = "pending"
			case "closed":
				fake.closed = true
			}
			response := adminRequest(t, handler, http.MethodPost, "/api/v1/admin/deployment-requests/"+request.ID+"/decision", `{"decision":"approved"}`, role)
			got, _ := api.store.get(request.ID)
			if response.Code != status || got.Approval.Status != approvalPending {
				t.Fatalf("status=%d approval=%+v", response.Code, got.Approval)
			}
		})
	}
}

func TestPublicReviewHidesSecurityAuditDetails(t *testing.T) {
	request := renderedRequest(t, "public")
	request.SecurityReview = securityReview{Status: securityRejected, Summary: "private audit", Findings: []securityFinding{{Message: "private finding"}}}
	public := publicDeploymentRequest(request)
	if public.SecurityReview.Status != securityRejected || public.SecurityReview.Summary != "" || len(public.SecurityReview.Findings) != 0 {
		t.Fatal("public security audit exposed")
	}
	if len(request.SecurityReview.Findings) != 1 {
		t.Fatal("stored audit modified")
	}
}

type approvalAuditTransport struct {
	base        http.RoundTripper
	beforeClose func()
}

func (transport approvalAuditTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.Method == http.MethodPatch && strings.HasSuffix(request.URL.Path, "/pulls/7") {
		transport.beforeClose()
	}
	return transport.base.RoundTrip(request)
}

func TestRejectionAuditIsDurableBeforeClosingPR(t *testing.T) {
	_, client := newFakeForgejo(t)
	api, handler := newTestAPI(t, client)
	request := renderedRequest(t, "public")
	request.State = statePROpen
	request.PullRequest = &pullRequestRef{Number: 7, State: "open"}
	request.Approval, request.SecurityReview = newReviewEvidence()
	if err := api.store.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	checked := false
	client.client.Transport = approvalAuditTransport{base: client.client.Transport, beforeClose: func() {
		checked = true
		restored, err := newStore(api.store.dir)
		if err != nil {
			t.Fatal(err)
		}
		defer restored.close()
		got, _ := restored.get(request.ID)
		if got.Approval.Status != approvalRejected || got.Approval.DecidedBy != "platform-admin@example.invalid" || got.Approval.DecidedAt == nil || got.Approval.Automatic || got.Approval.RejectReason != "범위 수정 필요" {
			t.Fatalf("PR closed before durable audit: %+v", got.Approval)
		}
	}}
	response := adminRequest(t, handler, http.MethodPost, "/api/v1/admin/deployment-requests/"+request.ID+"/decision", `{"decision":"rejected","reason":"범위 수정 필요"}`, adminRole)
	if response.Code != http.StatusOK || !checked {
		t.Fatalf("status=%d checked=%t", response.Code, checked)
	}
}
