package main

// 배포 승인과 보안 검토는 GitOps 파이프라인 상태와 별도로 영속화한다. PR이 열렸다는
// 사실이나 프로세스 메모리의 플래그를 승인 증거로 오인하지 않도록 모든 결정은 먼저
// append-only 저장소에 fsync되고, 그 뒤에만 병합 worker를 깨운다.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	approvalPending  = "pending"
	approvalApproved = "approved"
	approvalRejected = "rejected"

	securityPending  = "pending"
	securityPassed   = "passed"
	securityRejected = "rejected"

	adminRole   = "platform-admin"
	rolesHeader = "X-Portal-Roles"
)

var (
	errApprovalNotFound       = errors.New("승인할 배포 요청을 찾을 수 없음")
	errApprovalNotReviewable  = errors.New("승인 가능한 열린 배포 PR이 아님")
	errApprovalAlreadyDecided = errors.New("이미 승인 결정이 끝난 요청")
	errSecurityChecksPending  = errors.New("보안 검사가 아직 통과하지 않음")
	errSecurityChecksRejected = errors.New("보안 검사에서 문제가 발견됨")

	cvePattern = regexp.MustCompile(`(?i)\bCVE-\d{4}-\d{4,}\b`)
)

type approvalDecision struct {
	Status       string     `json:"status"`
	DecidedBy    string     `json:"decidedBy,omitempty"`
	DecidedAt    *time.Time `json:"decidedAt,omitempty"`
	Automatic    bool       `json:"automatic"`
	RejectReason string     `json:"rejectReason,omitempty"`
}

type securityFinding struct {
	Package      string `json:"package"`
	CVE          string `json:"cve"`
	FixedVersion string `json:"fixedVersion"`
	Message      string `json:"message"`
}

type securityReview struct {
	Status    string            `json:"status"`
	CheckedAt *time.Time        `json:"checkedAt,omitempty"`
	Summary   string            `json:"summary,omitempty"`
	Findings  []securityFinding `json:"findings,omitempty"`
}

type approvalPolicyChange struct {
	Enabled   bool      `json:"enabled"`
	ChangedBy string    `json:"changedBy"`
	ChangedAt time.Time `json:"changedAt"`
}

type approvalPolicy struct {
	Requester string                 `json:"requester"`
	Enabled   bool                   `json:"enabled"`
	UpdatedBy string                 `json:"updatedBy,omitempty"`
	UpdatedAt *time.Time             `json:"updatedAt,omitempty"`
	History   []approvalPolicyChange `json:"history,omitempty"`
}

// backfillReviewEvidence는 예전 JSONL을 보수적으로 읽는다. merge 전 레코드는 항상
// 승인 대기로 두고, 이미 target branch에 들어간 레코드만 legacy 자동 승인으로 표시한다.
func backfillReviewEvidence(request *deploymentRequest) {
	if request.Approval.Status == "" {
		request.Approval = approvalDecision{Status: approvalPending}
		if request.GitCommitted || request.State == stateMerged || request.State == stateBuilding ||
			request.State == stateDeploying || request.State == stateDeployed || request.State == stateStopped {
			decidedAt := request.UpdatedAt.UTC()
			request.Approval = approvalDecision{
				Status: approvalApproved, DecidedBy: "legacy-auto-approval",
				DecidedAt: &decidedAt, Automatic: true,
			}
		}
	}
	if request.SecurityReview.Status == "" {
		request.SecurityReview = securityReview{Status: securityPending}
		if request.Approval.Status == approvalApproved {
			checkedAt := request.UpdatedAt.UTC()
			request.SecurityReview = securityReview{
				Status: securityPassed, CheckedAt: &checkedAt,
				Summary: "기존 배포 기록에서 승인 완료 상태를 이전했습니다.",
			}
		}
	}
}

func newReviewEvidence() (approvalDecision, securityReview) {
	return approvalDecision{Status: approvalPending}, securityReview{Status: securityPending}
}

// publicDeploymentRequest는 private GitOps 저장소 주소와 branch를 일반 사용자 API에서
// 제거한다. 사용자는 승인/보안 상태와 자신의 source 좌표만 보고, 감사 PR은 관리자 API만 본다.
func publicDeploymentRequest(request deploymentRequest) deploymentRequest {
	request.PullRequest = nil
	request.RuntimePullRequest = nil
	request.RuntimeSupersededPullRequest = nil
	request.SecurityReview.Findings = nil
	request.SecurityReview.Summary = ""
	return request
}

func publicDeploymentRequests(requests []deploymentRequest) []deploymentRequest {
	result := make([]deploymentRequest, len(requests))
	for index, request := range requests {
		result[index] = publicDeploymentRequest(request)
	}
	return result
}

func scopedAdmin(r *http.Request) (string, bool) {
	requester, valid := scopedRequester(r)
	if !valid {
		return "", false
	}
	for _, role := range strings.Split(r.Header.Get(rolesHeader), ",") {
		if strings.TrimSpace(role) == adminRole {
			return requester, true
		}
	}
	return "", false
}

func requireAdmin(w http.ResponseWriter, r *http.Request) (string, bool) {
	admin, valid := scopedAdmin(r)
	if valid {
		return admin, true
	}
	writeProblem(w, http.StatusForbidden,
		"urn:sadp:portal:problem:admin-required", "관리자 권한 필요",
		adminRole+" 역할이 있는 외부 OIDC 세션만 이 작업을 수행할 수 있습니다.", nil)
	return "", false
}

func extractFindingValue(description string, keys ...string) string {
	for _, field := range strings.FieldsFunc(description, func(r rune) bool {
		return r == ';' || r == ',' || r == '|' || r == '\n'
	}) {
		pair := strings.SplitN(strings.TrimSpace(field), "=", 2)
		if len(pair) != 2 {
			pair = strings.SplitN(strings.TrimSpace(field), ":", 2)
		}
		if len(pair) != 2 {
			continue
		}
		for _, key := range keys {
			if strings.EqualFold(strings.TrimSpace(pair[0]), key) {
				return strings.TrimSpace(pair[1])
			}
		}
	}
	return ""
}

func findingFromStatus(status forgejoCommitStatus) securityFinding {
	packageName := extractFindingValue(status.Description, "package", "pkg")
	if packageName == "" {
		packageName = strings.TrimSpace(strings.TrimPrefix(status.Context, "security/"))
	}
	if packageName == "" {
		packageName = "미제공"
	}
	cve := extractFindingValue(status.Description, "cve", "vulnerability")
	if cve == "" {
		cve = cvePattern.FindString(status.Description)
	}
	if cve == "" {
		cve = "미제공"
	}
	fixed := extractFindingValue(status.Description, "fixed", "fixed-version", "fixed_version")
	if fixed == "" {
		fixed = "미제공"
	}
	message := strings.TrimSpace(status.Description)
	if message == "" {
		message = "보안 검사가 실패했지만 상세 설명을 제공하지 않았습니다."
	}
	return securityFinding{Package: packageName, CVE: strings.ToUpper(cve), FixedVersion: fixed, Message: message}
}

// inspectSecurityReview는 required check가 하나 이상 있고 combined status가 success일 때만
// 통과시킨다. check가 아직 등록되지 않은 상태를 성공으로 간주하지 않는 fail-closed 판정이다.
func (f *forgejoClient) inspectSecurityReview(ctx context.Context, request deploymentRequest) (securityReview, error) {
	if request.PullRequest == nil {
		return securityReview{Status: securityPending}, errApprovalNotReviewable
	}
	detail, err := f.pullRequestStatus(ctx, request.PullRequest.Number)
	if err != nil {
		return request.SecurityReview, err
	}
	if detail.Merged || !strings.EqualFold(detail.State, "open") {
		return request.SecurityReview, errApprovalNotReviewable
	}
	if detail.Head.SHA == "" {
		return request.SecurityReview, errors.New("Forgejo PR 응답에 head commit SHA가 없습니다")
	}
	checks, err := f.commitStatus(ctx, detail.Head.SHA)
	if err != nil {
		return request.SecurityReview, err
	}
	now := time.Now().UTC()
	review := securityReview{Status: securityPending, CheckedAt: &now, Summary: "필수 보안 검사가 완료되기를 기다리고 있습니다."}
	switch strings.ToLower(checks.State) {
	case "success":
		if checks.TotalCount > 0 && len(checks.Statuses) > 0 {
			review.Status = securityPassed
			review.Summary = "필수 보안 검사를 모두 통과했습니다."
		}
	case "failure", "error":
		review.Status = securityRejected
		review.Summary = "보안 검사에서 문제가 발견되어 배포가 반려되었습니다."
		for _, status := range checks.Statuses {
			if value := strings.ToLower(status.Status); value == "failure" || value == "error" {
				review.Findings = append(review.Findings, findingFromStatus(status))
			}
		}
		if len(review.Findings) == 0 {
			review.Findings = []securityFinding{{
				Package: "미제공", CVE: "미제공", FixedVersion: "미제공",
				Message: "Forgejo required check가 실패했지만 상세 취약점 정보를 제공하지 않았습니다.",
			}}
		}
	}
	return review, nil
}

func sameSecurityReview(left, right securityReview) bool {
	left.CheckedAt = nil
	right.CheckedAt = nil
	leftJSON, _ := json.Marshal(left)
	rightJSON, _ := json.Marshal(right)
	return bytes.Equal(leftJSON, rightJSON)
}

func securityRejectionReason() string {
	return "보안 검사에서 문제가 발견되었습니다. 신청한 소스 저장소에서 취약 package/CVE의 수정 버전을 반영하는 수정 PR을 만들거나 이슈를 등록해 패치한 뒤 다시 신청하세요."
}

// reviewForAdvance는 승인과 보안 증거를 원자적으로 확인한다. false면 병합 단계는
// 절대 실행하지 않는다. 사용자별 예외도 보안 통과 뒤에만 승인 레코드를 만든다.
func (f *forgejoClient) reviewForAdvance(ctx context.Context, snapshot deploymentRequest) (deploymentRequest, bool) {
	f.decisionMu.Lock()
	defer f.decisionMu.Unlock()

	request, ok := f.store.get(snapshot.ID)
	if !ok || request.State != statePROpen || request.PullRequest == nil {
		return request, false
	}
	if request.Approval.Status == approvalRejected {
		return f.finishRejection(ctx, request), false
	}
	review, err := f.inspectSecurityReview(ctx, request)
	if err != nil {
		f.logger.Printf("요청 %s 보안 검사 상태 확인 실패: %v", request.ID, err)
		return request, false
	}
	if review.Status == securityRejected {
		now := time.Now().UTC()
		replacement := request
		replacement.SecurityReview = review
		replacement.Approval = approvalDecision{
			Status: approvalRejected, DecidedBy: "security-checks", DecidedAt: &now,
			Automatic: true, RejectReason: securityRejectionReason(),
		}
		replacement.Message = replacement.Approval.RejectReason
		updated, applied, updateErr := f.store.updateIfCurrent(request, replacement)
		if updateErr != nil {
			f.logger.Printf("요청 %s 보안 반려 증거 기록 실패: %v", request.ID, updateErr)
			return request, false
		}
		if applied {
			return f.finishRejection(ctx, updated), false
		}
		return request, false
	}

	if !sameSecurityReview(request.SecurityReview, review) {
		replacement := request
		replacement.SecurityReview = review
		updated, applied, updateErr := f.store.updateIfCurrent(request, replacement)
		if updateErr != nil || !applied {
			return request, false
		}
		request = updated
	}
	if review.Status != securityPassed {
		return request, false
	}

	switch request.Approval.Status {
	case approvalRejected:
		return request, false
	case approvalApproved:
		return request, true
	case approvalPending:
		policy := f.store.approvalPolicy(request.Requester)
		if !policy.Enabled {
			return request, false
		}
		now := time.Now().UTC()
		replacement := request
		replacement.Approval = approvalDecision{
			Status: approvalApproved, DecidedBy: policy.UpdatedBy, DecidedAt: &now,
			Automatic: true,
		}
		updated, applied, updateErr := f.store.updateIfCurrent(request, replacement)
		if updateErr != nil || !applied {
			return request, false
		}
		return updated, true
	default:
		return request, false
	}
}

// 반려 증거를 먼저 저장해야 외부 PR 변경 실패에도 관리자 결정이 유실되지 않는다.
func (f *forgejoClient) finishRejection(ctx context.Context, request deploymentRequest) deploymentRequest {
	if err := f.closePullRequest(ctx, request.PullRequest.Number); err != nil {
		f.logger.Printf("요청 %s 반려 PR 닫기 실패: %v", request.ID, err)
		return request
	}
	replacement := request
	pr := *request.PullRequest
	pr.State = "closed"
	replacement.PullRequest = &pr
	updated, applied, err := f.store.updateIfCurrent(request, replacement)
	if err != nil || !applied {
		return request
	}
	return updated
}

func (f *forgejoClient) closePullRequest(ctx context.Context, number int) error {
	detail, err := f.pullRequestStatus(ctx, number)
	if err != nil {
		return err
	}
	if detail.Merged {
		return errors.New("이미 병합된 Pull Request는 반려할 수 없습니다")
	}
	if strings.EqualFold(detail.State, "closed") {
		return nil
	}
	endpoint := fmt.Sprintf("%s/%d", f.repoPath("pulls"), number)
	return f.do(ctx, http.MethodPatch, endpoint, map[string]string{"state": "closed"}, nil)
}

type approvalInput struct {
	Decision string `json:"decision"`
	Reason   string `json:"reason,omitempty"`
}

func readApprovalInput(w http.ResponseWriter, r *http.Request) (approvalInput, bool) {
	var input approvalInput
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeProblem(w, http.StatusUnsupportedMediaType,
			"urn:sadp:portal:problem:unsupported-media-type", "지원하지 않는 본문 형식",
			"Content-Type은 application/json이어야 합니다.", nil)
		return input, false
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "요청 본문 읽기 실패", "요청을 다시 보내세요.", nil)
		return input, false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "JSON 요청 해석 실패",
			"알 수 없는 필드 없이 하나의 올바른 JSON 객체를 보내세요.", nil)
		return input, false
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "JSON 요청 해석 실패",
			"요청 본문에는 JSON 객체 하나만 허용합니다.", nil)
		return input, false
	}
	input.Decision = strings.TrimSpace(input.Decision)
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Decision != approvalApproved && input.Decision != approvalRejected {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "승인 결정 검증 실패",
			"decision은 approved 또는 rejected여야 합니다.", nil)
		return input, false
	}
	if input.Decision == approvalRejected && input.Reason == "" {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "반려 사유 필요",
			"반려할 때는 감사 가능한 사유를 반드시 입력해야 합니다.", nil)
		return input, false
	}
	if len(input.Reason) > 2000 || strings.ContainsRune(input.Reason, '\x00') {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "반려 사유 검증 실패",
			"사유는 제어문자 없이 2000자 이하여야 합니다.", nil)
		return input, false
	}
	return input, true
}

func (f *forgejoClient) decideApproval(
	ctx context.Context, requestID, admin string, input approvalInput,
) (deploymentRequest, error) {
	f.decisionMu.Lock()
	request, ok := f.store.get(requestID)
	if !ok {
		f.decisionMu.Unlock()
		return deploymentRequest{}, errApprovalNotFound
	}
	if request.State != statePROpen || request.PullRequest == nil {
		f.decisionMu.Unlock()
		return request, errApprovalNotReviewable
	}
	if request.Approval.Status != approvalPending {
		if request.Approval.Status == input.Decision {
			f.decisionMu.Unlock()
			if input.Decision == approvalApproved {
				_ = f.enqueue(request.ID)
			} else {
				request = f.finishRejection(ctx, request)
			}
			return request, nil
		}
		f.decisionMu.Unlock()
		return request, errApprovalAlreadyDecided
	}

	if input.Decision == approvalRejected {
		now := time.Now().UTC()
		replacement := request
		replacement.Approval = approvalDecision{
			Status: approvalRejected, DecidedBy: admin, DecidedAt: &now,
			Automatic: false, RejectReason: input.Reason,
		}
		replacement.Message = input.Reason
		updated, applied, err := f.store.updateIfCurrent(request, replacement)
		f.decisionMu.Unlock()
		if err != nil {
			return request, err
		}
		if !applied {
			return updated, errApprovalAlreadyDecided
		}
		return f.finishRejection(ctx, updated), nil
	}

	review, err := f.inspectSecurityReview(ctx, request)
	if err != nil {
		f.decisionMu.Unlock()
		return request, err
	}
	if review.Status != securityPassed {
		replacement := request
		replacement.SecurityReview = review
		if review.Status == securityRejected {
			now := time.Now().UTC()
			replacement.Approval = approvalDecision{
				Status: approvalRejected, DecidedBy: "security-checks", DecidedAt: &now,
				Automatic: true, RejectReason: securityRejectionReason(),
			}
			replacement.Message = replacement.Approval.RejectReason
		}
		updated, _, updateErr := f.store.updateIfCurrent(request, replacement)
		f.decisionMu.Unlock()
		if updateErr != nil {
			return request, updateErr
		}
		if review.Status == securityRejected {
			return f.finishRejection(ctx, updated), errSecurityChecksRejected
		}
		return updated, errSecurityChecksPending
	}
	// Secret 준비는 승인 조건이 아니다. durable 결정 이후 advance의 병합 경계에서 검사한다.
	now := time.Now().UTC()
	replacement := request
	replacement.SecurityReview = review
	replacement.Approval = approvalDecision{
		Status: approvalApproved, DecidedBy: admin, DecidedAt: &now, Automatic: false,
	}
	updated, applied, err := f.store.updateIfCurrent(request, replacement)
	f.decisionMu.Unlock()
	if err != nil {
		return request, err
	}
	if !applied {
		return updated, errApprovalAlreadyDecided
	}
	if err := f.enqueue(updated.ID); err != nil {
		// 승인 증거가 durable하므로 watcher와 재시작 복구가 다시 enqueue한다.
		return updated, nil
	}
	return updated, nil
}

func (api *apiServer) handleAdminApprovalDecision(w http.ResponseWriter, r *http.Request) {
	admin, valid := requireAdmin(w, r)
	if !valid {
		return
	}
	if !api.submissionEnabled() {
		writeForgejoUnavailable(w)
		return
	}
	input, ok := readApprovalInput(w, r)
	if !ok {
		return
	}
	request, err := api.forgejo.decideApproval(r.Context(), r.PathValue("requestID"), admin, input)
	if err != nil {
		switch {
		case errors.Is(err, errApprovalNotFound):
			writeProblem(w, http.StatusNotFound, "urn:sadp:portal:problem:not-found",
				"요청을 찾을 수 없음", "승인할 배포 요청을 찾을 수 없습니다.", nil)
		case errors.Is(err, errApprovalNotReviewable), errors.Is(err, errApprovalAlreadyDecided):
			writeProblem(w, http.StatusConflict, "urn:sadp:portal:problem:approval-conflict",
				"승인 상태 충돌", err.Error(), nil)
		case errors.Is(err, errSecurityChecksPending), errors.Is(err, errSecurityChecksRejected):
			writeProblem(w, http.StatusConflict, "urn:sadp:portal:problem:security-review",
				"보안 검사 미통과", err.Error(), nil)
		default:
			writeProblem(w, http.StatusBadGateway, "urn:sadp:portal:problem:approval-failed",
				"승인 처리 실패", "Forgejo와 승인 저장소를 확인한 뒤 다시 시도하세요.", nil)
		}
		return
	}
	status := http.StatusOK
	if input.Decision == approvalApproved {
		status = http.StatusAccepted
	}
	writeJSON(w, status, request)
}

type approvalPolicyInput struct {
	Enabled *bool `json:"enabled"`
}

func readApprovalPolicyInput(w http.ResponseWriter, r *http.Request) (approvalPolicyInput, bool) {
	var input approvalPolicyInput
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeProblem(w, http.StatusUnsupportedMediaType,
			"urn:sadp:portal:problem:unsupported-media-type", "지원하지 않는 본문 형식",
			"Content-Type은 application/json이어야 합니다.", nil)
		return input, false
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxJSONBody))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.Enabled == nil {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "자동 승인 정책 해석 실패",
			"enabled boolean 필드 하나를 보내세요.", nil)
		return input, false
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "JSON 요청 해석 실패",
			"요청 본문에는 JSON 객체 하나만 허용합니다.", nil)
		return input, false
	}
	return input, true
}

func validPolicyRequester(value string) bool {
	return value != "" && len(value) <= maxRequesterLength && safeHeaderValue(value, maxRequesterLength) != "" &&
		!strings.ContainsAny(value, "/\\")
}

func (api *apiServer) handleAdminApprovalPolicy(w http.ResponseWriter, r *http.Request) {
	admin, valid := requireAdmin(w, r)
	if !valid {
		return
	}
	if api.store == nil {
		writeProblem(w, http.StatusServiceUnavailable,
			"urn:sadp:portal:problem:storage-unavailable", "승인 저장소 비활성",
			"배포 승인 저장소가 준비되지 않았습니다.", nil)
		return
	}
	requester := strings.TrimSpace(r.PathValue("requester"))
	if !validPolicyRequester(requester) {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "사용자 식별자 검증 실패",
			"사용자 식별자는 제어문자와 경로 구분자 없이 128자 이하여야 합니다.", nil)
		return
	}
	input, ok := readApprovalPolicyInput(w, r)
	if !ok {
		return
	}
	policy, err := api.store.setApprovalPolicy(requester, admin, *input.Enabled)
	if err != nil {
		writeProblem(w, http.StatusInternalServerError,
			"urn:sadp:portal:problem:storage-unavailable", "자동 승인 정책 저장 실패",
			"정책 저장소를 확인한 뒤 다시 시도하세요.", nil)
		return
	}
	if policy.Enabled && api.forgejo != nil {
		for _, requestID := range api.store.reviewableFor(requester) {
			_ = api.forgejo.enqueue(requestID)
		}
	}
	writeJSON(w, http.StatusOK, policy)
}

type adminApprovalDashboard struct {
	Requests []deploymentRequest `json:"requests"`
	Policies []approvalPolicy    `json:"policies"`
	Count    int                 `json:"count"`
}

func (api *apiServer) handleAdminApprovalDashboard(w http.ResponseWriter, r *http.Request) {
	if _, valid := requireAdmin(w, r); !valid {
		return
	}
	if api.store == nil {
		writeProblem(w, http.StatusServiceUnavailable,
			"urn:sadp:portal:problem:storage-unavailable", "승인 저장소 비활성",
			"배포 승인 저장소가 준비되지 않았습니다.", nil)
		return
	}
	requests := api.store.list(0, "")
	writeJSON(w, http.StatusOK, adminApprovalDashboard{
		Requests: requests, Policies: api.store.approvalPolicies(requests), Count: len(requests),
	})
}

func (s *store) approvalPolicy(requester string) approvalPolicy {
	s.mu.Lock()
	defer s.mu.Unlock()
	if policy, ok := s.policies[requester]; ok {
		return policy
	}
	return approvalPolicy{Requester: requester, Enabled: false}
}

func (s *store) setApprovalPolicy(requester, admin string, enabled bool) (approvalPolicy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	policy, exists := s.policies[requester]
	if !exists {
		policy = approvalPolicy{Requester: requester}
	}
	if exists && policy.Enabled == enabled {
		return policy, nil
	}
	now := time.Now().UTC()
	policy.Enabled = enabled
	policy.UpdatedBy = admin
	policy.UpdatedAt = &now
	policy.History = append(policy.History, approvalPolicyChange{
		Enabled: enabled, ChangedBy: admin, ChangedAt: now,
	})
	policyCopy := policy
	if err := s.append(storeRecord{Kind: "approval-policy", Policy: &policyCopy}); err != nil {
		return approvalPolicy{}, err
	}
	if err := s.pruneLocked(); err != nil {
		return approvalPolicy{}, err
	}
	return policy, nil
}

func (s *store) approvalPolicies(requests []deploymentRequest) []approvalPolicy {
	s.mu.Lock()
	defer s.mu.Unlock()
	users := make(map[string]struct{}, len(requests)+len(s.policies))
	for _, request := range requests {
		if request.Requester != "" {
			users[request.Requester] = struct{}{}
		}
	}
	for requester := range s.policies {
		users[requester] = struct{}{}
	}
	result := make([]approvalPolicy, 0, len(users))
	for requester := range users {
		if policy, ok := s.policies[requester]; ok {
			result = append(result, policy)
		} else {
			result = append(result, approvalPolicy{Requester: requester, Enabled: false})
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Requester < result[j].Requester })
	return result
}

// reviewableFor는 보안 검사 진행 중, 승인 완료 후 병합 전, 또는 사용자별 자동 승인
// 예외가 켜진 요청만 고른다. 수동 승인 대기+보안 통과 요청은 불필요하게 polling하지 않는다.
func (s *store) reviewableFor(requester string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]string, 0)
	for _, id := range s.ordered {
		request, ok := s.byID[id]
		if !ok || request.State != statePROpen || request.PullRequest == nil ||
			(requester != "" && request.Requester != requester) || request.Approval.Status == approvalRejected {
			continue
		}
		policy := s.policies[request.Requester]
		if request.SecurityReview.Status == securityPending || request.Approval.Status == approvalApproved || policy.Enabled {
			result = append(result, id)
		}
	}
	return result
}

func (f *forgejoClient) pollApprovalQueue() {
	for _, requestID := range f.store.reviewableFor("") {
		_ = f.enqueue(requestID)
	}
}

func (f *forgejoClient) watchApprovals(ctx context.Context) {
	f.pollApprovalQueue()
	ticker := time.NewTicker(buildPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			f.pollApprovalQueue()
		}
	}
}
