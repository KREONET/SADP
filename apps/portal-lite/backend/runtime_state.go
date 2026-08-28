package main

// 애플리케이션 정지/재개는 Kubernetes를 직접 scale하지 않고 Forgejo의 desired
// state를 바꾼다. 직접 scale하면 Argo CD selfHeal이 원래 replica 수로 되돌리므로,
// Service/PVC는 남기고 values의 replicaCount와 외부 Route만 GitOps로 전환한다.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	stateStopping = "stopping"
	stateStopped  = "stopped"
	stateStarting = "starting"

	runtimeRunning = "running"
	runtimeStopped = "stopped"
)

var (
	errRuntimeNotFound   = errors.New("실행 상태를 바꿀 배포 요청을 찾을 수 없음")
	errRuntimeStale      = errors.New("최신 앱 요청이 아님")
	errRuntimeInProgress = errors.New("진행 중인 앱은 실행 상태를 바꿀 수 없음")
)

type runtimeStateInput struct {
	State string `json:"state"`
}

// requestRuntimeState는 desiredRuntimeState 필드가 없던 JSONL도 실행 중으로 읽는다.
// 구버전 앱은 replicaCount가 항상 1 이상이었으므로 이 기본값이 실제 desired state다.
func requestRuntimeState(request deploymentRequest) string {
	if request.DesiredRuntimeState == runtimeStopped {
		return runtimeStopped
	}
	return runtimeRunning
}

func runtimeTransitionState(desired string) string {
	if desired == runtimeStopped {
		return stateStopping
	}
	return stateStarting
}

func runtimeTerminalState(desired string) string {
	if desired == runtimeStopped {
		return stateStopped
	}
	return stateDeployed
}

func lifecycleTransition(state string) bool {
	return state == stateStopping || state == stateStarting
}

func lifecycleFailure(request deploymentRequest) bool {
	return request.State == stateFailed && lifecycleTransition(request.FailedFromState)
}

func readRuntimeStateBody(w http.ResponseWriter, r *http.Request) (runtimeStateInput, bool) {
	var input runtimeStateInput
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
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeProblem(w, http.StatusRequestEntityTooLarge,
				"urn:sadp:portal:problem:payload-too-large", "요청 본문 제한 초과",
				"JSON 요청은 64 KiB 이하여야 합니다.", nil)
			return input, false
		}
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "요청 본문 읽기 실패",
			"요청을 다시 보내세요.", nil)
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
	input.State = strings.TrimSpace(input.State)
	if input.State != runtimeRunning && input.State != runtimeStopped {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "실행 상태 검증 실패",
			"state는 running 또는 stopped여야 합니다.", []fieldError{{
				Field: "state", Message: "running 또는 stopped를 선택하세요.",
			}})
		return input, false
	}
	return input, true
}

// beginRuntimeState는 소유권·최신 요청·현재 상태 확인과 전환 기록을 한 잠금 안에서
// 처리한다. 배포/삭제 생성과는 api.appMu로 직렬화하고, 여기서는 같은 앱의 중복
// stop/start 요청이 generation을 두 번 올리지 않게 한다.
func (s *store) beginRuntimeState(id, requester, desired string) (deploymentRequest, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	request, ok := s.byID[id]
	if !ok || requester == "" || request.Requester != requester {
		return deploymentRequest{}, false, errRuntimeNotFound
	}
	artifact := artifactIdentity(request.Profile)
	for i := len(s.ordered) - 1; i >= 0; i-- {
		candidate, found := s.byID[s.ordered[i]]
		if !found || artifactIdentity(candidate.Profile) != artifact {
			continue
		}
		if candidate.ID != request.ID {
			return deploymentRequest{}, false, errRuntimeStale
		}
		break
	}
	if request.DeletionRequested || request.State == stateDeleting || request.State == stateDeleted {
		return deploymentRequest{}, false, errRuntimeInProgress
	}

	currentDesired := requestRuntimeState(request)
	transition := runtimeTransitionState(desired)
	terminal := runtimeTerminalState(desired)
	if currentDesired == desired {
		switch {
		case request.State == terminal:
			return request, false, nil
		case request.State == transition:
			// queue 전달 직후 응답이 유실된 재시도다. enqueue 자체도 ID 기준 멱등이다.
			return request, true, nil
		case request.State == stateFailed && request.FailedFromState == transition:
			// 닫힌 PR/남은 branch를 다시 쓰지 않도록 명시적 재시도도 새 세대를 쓴다.
			request.RuntimeGeneration++
			request.State = transition
			request.FailedFromState = ""
			if request.RuntimePullRequest != nil {
				request.RuntimeSupersededPullRequest = request.RuntimePullRequest
			}
			request.RuntimePullRequest = nil
			request.RuntimeDesiredRevision = ""
			request.RuntimeApplicationSynced = false
			request.Message = runtimeTransitionMessage(desired)
		default:
			return deploymentRequest{}, false, errRuntimeInProgress
		}
	} else {
		switch desired {
		case runtimeStopped:
			// 일반 배포 실패 record로 정지를 시작하면 오래된 profile이 현재 target
			// values를 덮거나 존재하지 않는 앱을 부활시킬 수 있다. 안정 상태에서만 받는다.
			if request.State != stateDeployed {
				return deploymentRequest{}, false, errRuntimeInProgress
			}
		case runtimeRunning:
			if request.State != stateStopped {
				return deploymentRequest{}, false, errRuntimeInProgress
			}
		}
		request.DesiredRuntimeState = desired
		request.RuntimeGeneration++
		request.State = transition
		request.FailedFromState = ""
		request.RuntimePullRequest = nil
		request.RuntimeSupersededPullRequest = nil
		request.RuntimeDesiredRevision = ""
		request.RuntimeApplicationSynced = false
		request.Message = runtimeTransitionMessage(desired)
	}

	request.UpdatedAt = time.Now().UTC()
	if err := s.append(storeRecord{Kind: "update", Request: &request}); err != nil {
		return deploymentRequest{}, false, err
	}
	if err := s.pruneLocked(); err != nil {
		return deploymentRequest{}, false, err
	}
	return request, true, nil
}

func runtimeTransitionMessage(desired string) string {
	if desired == runtimeStopped {
		return "GitOps에서 Pod와 외부 Route를 안전하게 중지하는 중입니다."
	}
	return "GitOps에서 원래 replica와 외부 Route를 복원하는 중입니다."
}

func (api *apiServer) handleUpdateRuntimeState(w http.ResponseWriter, r *http.Request) {
	requester, valid := scopedRequester(r)
	if !valid {
		writeInvalidRequester(w)
		return
	}
	if !api.submissionEnabled() {
		writeForgejoUnavailable(w)
		return
	}
	input, ok := readRuntimeStateBody(w, r)
	if !ok {
		return
	}

	api.appMu.Lock()
	defer api.appMu.Unlock()
	request, enqueue, err := api.store.beginRuntimeState(r.PathValue("requestID"), requester, input.State)
	if err != nil {
		switch {
		case errors.Is(err, errRuntimeNotFound):
			writeProblem(w, http.StatusNotFound,
				"urn:sadp:portal:problem:not-found", "앱을 찾을 수 없음",
				"실행 상태를 바꿀 앱을 찾을 수 없습니다.", nil)
		case errors.Is(err, errRuntimeStale):
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:stale-request", "최신 앱 요청이 아님",
				"내 애플리케이션 목록을 새로고침한 뒤 최신 항목에서 다시 시도하세요.", nil)
		case errors.Is(err, errRuntimeInProgress):
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:runtime-transition", "실행 상태 변경 불가",
				"현재 배포·삭제·실행 상태 변경이 끝난 뒤 다시 시도하세요.", nil)
		default:
			writeProblem(w, http.StatusInternalServerError,
				"urn:sadp:portal:problem:storage-unavailable", "실행 상태 저장 실패",
				"잠시 후 다시 시도하세요.", nil)
		}
		return
	}
	if enqueue {
		if err := api.forgejo.enqueue(request.ID); err != nil {
			replacement := request
			replacement.FailedFromState = request.State
			replacement.State = stateFailed
			replacement.Message = "실행 상태 처리 대기열이 가득 찼습니다. 같은 상태로 다시 요청하세요."
			if updated, applied, updateErr := api.store.updateIfCurrent(request, replacement); updateErr == nil && applied {
				request = updated
			} else {
				request = replacement
			}
			w.Header().Set("Retry-After", "60")
			writeProblem(w, http.StatusServiceUnavailable,
				"urn:sadp:portal:problem:queue-full", "처리 대기열 포화",
				request.Message, nil)
			return
		}
	}
	w.Header().Set("Location", "/api/v1/deployment-requests/"+request.ID)
	status := http.StatusAccepted
	if !enqueue {
		status = http.StatusOK
	}
	writeJSON(w, status, request)
}

func (f *forgejoClient) runtimeBranch(request deploymentRequest) string {
	action := "start"
	if requestRuntimeState(request) == runtimeStopped {
		action = "stop"
	}
	return fmt.Sprintf("%s/%s-%s-%s-%d", f.config.BranchPrefix, action,
		request.Profile.App.Name, request.ID, max(request.RuntimeGeneration, 1))
}

// patchRuntimeValues는 포털이 생성한 values의 실행 상태 두 필드만 바꾼다. 전체
// profile을 다시 렌더하면 운영 중 반영된 이미지 tag나 설정을 오래된 요청이 덮을 수
// 있으므로, 요청 ID와 구조를 검증하고 나머지 바이트는 그대로 보존한다.
func patchRuntimeValues(content string, request deploymentRequest) (string, error) {
	if !isPortalManagedFile(content) {
		return "", errors.New("포털 소유 values가 아님")
	}
	lines := strings.Split(content, "\n")
	expectedHeader := "# 요청 ID: " + request.ID
	headerCount := 0
	replicaCount := 0
	exposureCount := 0
	inExposure := false
	desiredReplicas := max(request.Profile.Replicas, 1)
	desiredExposure := true
	if requestRuntimeState(request) == runtimeStopped {
		desiredReplicas = 0
		desiredExposure = false
	}

	for index, rawLine := range lines {
		line := strings.TrimSuffix(rawLine, "\r")
		if line == expectedHeader {
			headerCount++
		}
		if strings.HasPrefix(line, "replicaCount:") {
			value := strings.TrimSpace(strings.TrimPrefix(line, "replicaCount:"))
			if _, err := strconv.Atoi(value); err != nil {
				return "", errors.New("replicaCount가 정수가 아님")
			}
			replicaCount++
			lines[index] = fmt.Sprintf("replicaCount: %d", desiredReplicas)
			continue
		}
		if len(line) > 0 && line[0] != ' ' && line[0] != '#' && line != "---" {
			inExposure = line == "exposure:"
			continue
		}
		if inExposure && strings.HasPrefix(line, "  enabled:") {
			value := strings.TrimSpace(strings.TrimPrefix(line, "  enabled:"))
			if value != "true" && value != "false" {
				return "", errors.New("exposure.enabled가 boolean이 아님")
			}
			exposureCount++
			lines[index] = fmt.Sprintf("  enabled: %t", desiredExposure)
		}
	}
	if headerCount != 1 {
		return "", fmt.Errorf("target values의 요청 ID가 최신 요청 %s와 다릅니다", request.ID)
	}
	if replicaCount != 1 || exposureCount != 1 {
		return "", errors.New("target values의 실행 상태 필드가 유일하지 않음")
	}
	return strings.Join(lines, "\n"), nil
}

// submitRuntimeState는 target branch의 최신 포털 소유 values만 갱신한다. 파일이
// 없으면 새로 만들지 않는다 — 삭제와 경합한 stale 요청이 앱을 부활시키기 때문이다.
func (f *forgejoClient) submitRuntimeState(
	ctx context.Context, request deploymentRequest,
) (*pullRequestRef, error) {
	filePath := appValuesPath(request.Profile)
	endpoint := f.fileEndpoint(filePath)
	meta, err := f.fileMetadata(ctx, endpoint, f.config.TargetBranch)
	if err != nil {
		if forgejoStatus(err) == http.StatusNotFound {
			return nil, fmt.Errorf("GitOps values %s가 없어 실행 상태를 바꿀 수 없습니다", filePath)
		}
		return nil, err
	}
	targetValues, err := patchRuntimeValues(meta.Content, request)
	if err != nil {
		return nil, fmt.Errorf("GitOps 경로 %s의 실행 상태 변경 거부: %w", filePath, err)
	}
	if meta.Content == targetValues {
		// merge 성공 뒤 응답/rollout만 실패한 재시도는 빈 PR을 만들지 않는다.
		return nil, nil
	}

	branch := f.runtimeBranch(request)
	if existing, err := f.findPullRequest(ctx, branch); err != nil {
		return nil, err
	} else if existing != nil {
		if err := f.verifyRuntimeBranch(ctx, request, branch, filePath); err != nil {
			return nil, err
		}
		return existing, nil
	}
	if err := f.createBranch(ctx, branch); err != nil {
		return nil, err
	}
	// branch 생성 시점의 target HEAD를 다시 읽고 그 blob을 SHA 조건부 갱신한다.
	// 첫 GET 이후 target이 바뀌어도 branch가 실제로 복제한 최신 설정만 패치한다.
	branchMeta, err := f.fileMetadata(ctx, endpoint, branch)
	if err != nil {
		return nil, err
	}
	values, err := patchRuntimeValues(branchMeta.Content, request)
	if err != nil {
		return nil, fmt.Errorf("runtime branch %s의 values 변경 거부: %w", branch, err)
	}
	action := "재개"
	if requestRuntimeState(request) == runtimeStopped {
		action = "중지"
	}
	message := fmt.Sprintf("chore(%s): 앱 %s", request.Profile.App.Name, action)
	if err := f.updateFileAtSHA(ctx, branch, filePath, message, values, branchMeta.SHA); err != nil {
		return nil, err
	}
	body := fmt.Sprintf(
		"SADP 포털에서 `%s` 앱 %s를 요청했습니다.\n\n"+
			"- 요청 ID: `%s`\n- 신청자: `%s`\n- Namespace: `%s`\n"+
			"- 목표 상태: `%s`\n\nService와 PVC는 보존합니다.\n",
		markdownCode(request.Profile.App.Name), action, markdownCode(request.ID),
		markdownCode(request.Requester), markdownCode(request.Profile.namespace()),
		markdownCode(requestRuntimeState(request)),
	)
	return f.createPullRequest(ctx, branch,
		fmt.Sprintf("[portal] %s 앱 %s", request.Profile.App.Name, action), body)
}

// verifyRuntimeBranch는 재시도에서 발견한 기존 PR이나 merge 직전 PR head가 정확히
// 요청한 두 runtime 필드만 반영한 포털 values인지 확인한다. 사람이 branch를 바꾸거나
// 오래된 PR이 남아 있어도 required checks만 믿고 병합하지 않는다.
func (f *forgejoClient) verifyRuntimeBranch(
	ctx context.Context, request deploymentRequest, branch, filePath string,
) error {
	endpoint := f.fileEndpoint(filePath)
	branchMeta, err := f.fileMetadata(ctx, endpoint, branch)
	if err != nil {
		return err
	}
	targetMeta, err := f.fileMetadata(ctx, endpoint, f.config.TargetBranch)
	if err != nil {
		return err
	}
	expected, err := patchRuntimeValues(targetMeta.Content, request)
	if err != nil {
		return err
	}
	if branchMeta.Content != expected {
		return fmt.Errorf("runtime branch %s가 최신 target values의 %s 패치와 다릅니다",
			branch, requestRuntimeState(request))
	}
	return nil
}

func (f *forgejoClient) applyRuntimeState(ctx context.Context, request deploymentRequest) {
	desired := requestRuntimeState(request)
	// PR 생성은 성공했지만 응답이 유실되면 store에 number가 남지 않는다. 다음 세대는
	// 바로 이전 generation의 stop/start deterministic branch 둘을 찾아 open PR을 회수한다.
	if request.RuntimeSupersededPullRequest == nil && request.RuntimeGeneration > 1 {
		previous := request
		previous.RuntimeGeneration--
		for _, previousDesired := range []string{runtimeStopped, runtimeRunning} {
			previous.DesiredRuntimeState = previousDesired
			found, err := f.findPullRequest(ctx, f.runtimeBranch(previous))
			if err != nil {
				f.failRequest(request, "이전 실행 상태 PR을 확인하지 못했습니다.", err)
				return
			}
			if found != nil {
				request.RuntimeSupersededPullRequest = found
				f.saveRequest(request)
				break
			}
		}
	}
	if request.RuntimeSupersededPullRequest != nil {
		if err := f.closeRuntimePullRequest(ctx, request.RuntimeSupersededPullRequest); err != nil {
			f.failRequest(request, "이전 실행 상태 PR을 안전하게 무효화하지 못했습니다.", err)
			return
		}
		request.RuntimeSupersededPullRequest = nil
		f.saveRequest(request)
	}
	pullRequest := request.RuntimePullRequest
	if pullRequest == nil {
		var err error
		pullRequest, err = f.submitRuntimeState(ctx, request)
		if err != nil {
			f.failRequest(request, "GitOps 실행 상태 요청 생성에 실패했습니다. 잠시 후 다시 시도해 주세요.", err)
			return
		}
		request.RuntimePullRequest = pullRequest
		f.saveRequest(request)
	}
	if pullRequest != nil && pullRequest.State != "merged" {
		detail, statusErr := f.pullRequestStatus(ctx, pullRequest.Number)
		if statusErr != nil || !detail.Merged {
			if err := f.verifyRuntimeBranch(ctx, request, pullRequest.Branch, appValuesPath(request.Profile)); err != nil {
				f.failRequest(request, "GitOps 실행 상태 PR 내용이 요청과 달라 병합하지 않았습니다.", err)
				return
			}
			if err := f.mergePullRequest(ctx, pullRequest.Number); err != nil {
				f.failRequest(request, "GitOps 실행 상태 요청 자동 승인에 실패했습니다.", err)
				return
			}
		}
		// store snapshot의 포인터를 직접 바꾸면 fsync 전 공유 메모리가 변한다.
		// 새 객체로 교체해 저장 실패 시에도 이전 상태를 그대로 보존한다.
		merged := *pullRequest
		merged.State = "merged"
		request.RuntimePullRequest = &merged
		f.saveRequest(request)
	}

	if f.builder != nil {
		revision, err := f.branchRevision(ctx, f.config.TargetBranch)
		if err != nil {
			f.failRequest(request, "실행 상태 커밋 확인에 실패했습니다.", err)
			return
		}
		request.RuntimeDesiredRevision = revision
		request.RuntimeApplicationSynced = false
		f.saveRequest(request)
		f.builder.refreshApplication(ctx, appApplicationName(request.Profile))
		if err := f.waitForRuntimeApplication(ctx, request, revision); err != nil {
			f.failRequest(request, "Argo CD가 실행 상태 Git revision을 동기화하지 못했습니다.", err)
			return
		}
		request.RuntimeApplicationSynced = true
		f.saveRequest(request)
		if desired == runtimeStopped {
			if err := f.builder.waitForDeploymentStopped(ctx, request); err != nil {
				f.failRequest(request, "앱 Pod가 완전히 중지되지 않았습니다.", err)
				return
			}
		} else if err := f.builder.waitForDeployment(ctx, request, request.Generated.Image); err != nil {
			f.failRequest(request, "앱이 원래 replica 수로 준비되지 않았습니다.", err)
			return
		}
	}

	request.State = runtimeTerminalState(desired)
	request.FailedFromState = ""
	request.Message = ""
	f.saveRequest(request)
	f.logger.Printf("요청 %s 앱 실행 상태 변경 완료: %s", request.ID, desired)
}

// closeRuntimePullRequest는 실패한 이전 세대의 open PR을 닫는다. 새 세대가 성공한
// 뒤 사람이 옛 stop PR을 병합해 JSONL desired state와 Git을 다시 어긋나게 하지 않는다.
func (f *forgejoClient) closeRuntimePullRequest(ctx context.Context, pullRequest *pullRequestRef) error {
	if pullRequest == nil || pullRequest.Number < 1 {
		return nil
	}
	detail, err := f.pullRequestStatus(ctx, pullRequest.Number)
	if err != nil {
		if forgejoStatus(err) == http.StatusNotFound {
			return nil
		}
		return err
	}
	if detail.Merged || strings.EqualFold(detail.State, "closed") {
		return nil
	}
	payload := map[string]string{"state": "closed"}
	return f.do(ctx, http.MethodPatch,
		fmt.Sprintf("%s/%d", f.repoPath("pulls"), pullRequest.Number), payload, nil)
}

// runtimeApplicationSynced는 Argo가 정확한 merge 직후 revision 또는 그 이후
// revision에서 원하는 runtime values를 실제로 동기화했는지 확인한다. target branch에
// 후속 commit이 빨리 들어오면 Argo가 중간 revision을 건너뛸 수 있으므로 exact SHA만
// 기다리면 적용된 앱도 timeout될 수 있다.
func (f *forgejoClient) runtimeApplicationSynced(
	ctx context.Context, request deploymentRequest, desiredRevision string,
) (bool, error) {
	if f == nil || f.builder == nil {
		return false, errors.New("runtime Argo 상태 조회가 비활성임")
	}
	var application argoApplicationStatus
	status, err := f.builder.do(ctx, http.MethodGet,
		f.builder.applicationPath(appApplicationName(request.Profile)), nil, &application)
	if err != nil {
		if status == http.StatusNotFound {
			return false, nil
		}
		return false, err
	}
	if application.Status.Sync.Status != "Synced" {
		return false, nil
	}
	if argoHasRevision(application, desiredRevision) {
		return true, nil
	}
	revisions := append([]string(nil), application.Status.Sync.Revisions...)
	if application.Status.Sync.Revision != "" {
		revisions = append(revisions, application.Status.Sync.Revision)
	}
	endpoint := f.fileEndpoint(appValuesPath(request.Profile))
	for _, revision := range revisions {
		if revision == "" {
			continue
		}
		meta, readErr := f.fileMetadata(ctx, endpoint, revision)
		if readErr != nil {
			continue
		}
		expected, patchErr := patchRuntimeValues(meta.Content, request)
		if patchErr == nil && expected == meta.Content {
			return true, nil
		}
	}
	return false, nil
}

func (f *forgejoClient) waitForRuntimeApplication(
	ctx context.Context, request deploymentRequest, desiredRevision string,
) error {
	deadline := time.Now().Add(time.Duration(rolloutTimeoutSeconds) * time.Second)
	for {
		synced, err := f.runtimeApplicationSynced(ctx, request, desiredRevision)
		if err == nil && synced {
			return nil
		}
		if err != nil {
			f.logger.Printf("Argo Application %s runtime revision 확인 실패: %v",
				appApplicationName(request.Profile), err)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Argo Application %s가 runtime values를 제한 시간 안에 동기화하지 못했습니다",
				appApplicationName(request.Profile))
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

func (p *buildPipeline) deploymentStopped(ctx context.Context, request deploymentRequest) (bool, error) {
	path := "/apis/apps/v1/namespaces/" + url.PathEscape(request.Profile.namespace()) +
		"/deployments/" + url.PathEscape(request.Profile.App.Name)
	var deployment deploymentStatus
	status, err := p.do(ctx, http.MethodGet, path, nil, &deployment)
	if err != nil {
		if status == http.StatusNotFound {
			return false, nil
		}
		return false, err
	}
	deploymentEmpty := deployment.Spec.Replicas == 0 &&
		deployment.Status.ObservedGeneration >= deployment.Metadata.Generation &&
		deployment.Status.Replicas == 0 && deployment.Status.ReadyReplicas == 0 &&
		deployment.Status.UpdatedReplicas == 0 && deployment.Status.AvailableReplicas == 0
	if !deploymentEmpty {
		return false, nil
	}
	// Deployment status가 먼저 0으로 수렴해도 종료 중 Pod가 잠시 남을 수 있다. 같은
	// selector의 Pod 목록까지 비어야 사용자가 데이터 정비를 시작할 수 있는 정지다.
	selector := "app.kubernetes.io/name=" + request.Profile.App.Name +
		",app.kubernetes.io/instance=" + request.Profile.App.Name
	podPath := "/api/v1/namespaces/" + url.PathEscape(request.Profile.namespace()) +
		"/pods?labelSelector=" + url.QueryEscape(selector)
	var pods podListStatus
	if _, err := p.do(ctx, http.MethodGet, podPath, nil, &pods); err != nil {
		return false, err
	}
	for _, pod := range pods.Items {
		if pod.Status.Phase != "Succeeded" && pod.Status.Phase != "Failed" {
			return false, nil
		}
	}
	return true, nil
}

func (p *buildPipeline) waitForDeploymentStopped(ctx context.Context, request deploymentRequest) error {
	deadline := time.Now().Add(time.Duration(rolloutTimeoutSeconds) * time.Second)
	for {
		stopped, err := p.deploymentStopped(ctx, request)
		if err == nil && stopped {
			return nil
		}
		if err != nil {
			p.logger.Printf("배포 %s 중지 상태 조회 실패: %v", request.Profile.App.Name, err)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Namespace %s의 Deployment가 제한 시간(%d초) 안에 중지되지 않았습니다",
				request.Profile.namespace(), rolloutTimeoutSeconds)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}
