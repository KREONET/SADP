package main

// Forgejo(Gitea 호환) REST API로 브랜치 생성 → values 파일 커밋 → Pull Request 생성을
// 순서대로 수행한다. 외부 모듈 없이 net/http만 쓰고, egress는 Squid 프록시를 거친다.
// 봇 토큰은 환경변수로만 받고 로그·PR 본문·에러 메시지에 절대 싣지 않는다.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	forgejoTimeout   = 20 * time.Second
	forgejoQueueSize = 256
	forgejoMaxTries  = 4

	// 포털이 소유한 파일만 갱신·삭제한다. 브랜치는 main에서 갈라지므로 이 표식이
	// 없는 기존 파일을 PUT으로 바꾸면 platform 내장 앱까지 덮어쓸 수 있다.
	portalManagedFileMarker = "# 이 파일은 SADP 포털이 생성했습니다. 직접 수정하지 마세요."
)

type forgejoConfig struct {
	BaseURL      string
	Owner        string
	Repo         string
	Token        string
	TargetBranch string
	BranchPrefix string
	// kaniko에 내부 Git credential을 전달할 수 있는 source host 목록이다.
	AllowedGitHosts []string
}

// forgejoConfigFromEnv는 필수 값이 모두 있고 https일 때만 설정됨으로 판정한다.
func forgejoConfigFromEnv() (forgejoConfig, bool) {
	config := forgejoConfig{
		BaseURL:      strings.TrimRight(configured("FORGEJO_BASE_URL", ""), "/"),
		Owner:        configured("FORGEJO_OWNER", ""),
		Repo:         configured("FORGEJO_REPO", ""),
		Token:        configured("FORGEJO_BOT_TOKEN", ""),
		TargetBranch: configured("FORGEJO_TARGET_BRANCH", "main"),
		BranchPrefix: configured("FORGEJO_BRANCH_PREFIX", "portal"),
	}
	if config.BaseURL == "" || config.Owner == "" || config.Repo == "" || config.Token == "" {
		return config, false
	}
	parsed, err := url.Parse(config.BaseURL)
	// 토큰을 평문으로 실어 보내지 않도록 https만 허용한다.
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return config, false
	}
	if !appNamePattern.MatchString(config.Owner) && !branchPattern.MatchString(config.Owner) {
		return config, false
	}
	if !branchPattern.MatchString(config.Repo) {
		return config, false
	}
	configuredHosts := parseCommaList(configured("PORTAL_ALLOWED_GIT_HOSTS", ""))
	config.AllowedGitHosts = append(config.AllowedGitHosts, parsed.Hostname())
	for _, host := range configuredHosts {
		host = strings.ToLower(strings.TrimSpace(host))
		if host != "" && !containsString(config.AllowedGitHosts, host) {
			config.AllowedGitHosts = append(config.AllowedGitHosts, host)
		}
	}
	return config, true
}

type forgejoClient struct {
	config  forgejoConfig
	client  *http.Client
	store   *store
	builder *buildPipeline
	openbao *openBaoClient
	queue   chan string
	logger  *log.Logger

	// 같은 멱등 요청을 브라우저가 재전송해도 한 워커에서 두 번 처리하지 않는다.
	// 큐에 넣을 때부터 process가 끝날 때까지 보존해야 처리 중 재전송도 막힌다.
	queueMu sync.Mutex
	queued  map[string]struct{}
	// processing 중 같은 ID가 다시 enqueue되면 단순 중복이 아니라 상태 전이 뒤 재실행일
	// 수 있다(배포 완료 직후 DELETE 등). rerun을 남겨 lost wakeup을 막는다.
	processing map[string]bool
	rerun      map[string]bool
}

func newForgejoClient(config forgejoConfig, requestStore *store, logger *log.Logger) *forgejoClient {
	transport := &http.Transport{
		// 폐쇄망 egress는 Squid만 열려 있으므로 표준 프록시 환경변수를 그대로 따른다.
		Proxy:               http.ProxyFromEnvironment,
		MaxIdleConns:        8,
		IdleConnTimeout:     60 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	}
	return &forgejoClient{
		config: config,
		client: &http.Client{Transport: transport, Timeout: forgejoTimeout},
		store:  requestStore,
		queue:  make(chan string, forgejoQueueSize),
		logger: logger,
		queued: make(map[string]struct{}), processing: make(map[string]bool), rerun: make(map[string]bool),
	}
}

// apiURL은 사용자 입력이 경로에 섞이더라도 안전하도록 각 구간을 이스케이프한다.
func (f *forgejoClient) apiURL(segments ...string) string {
	escaped := make([]string, 0, len(segments))
	for _, segment := range segments {
		escaped = append(escaped, url.PathEscape(segment))
	}
	return f.config.BaseURL + "/api/v1/" + strings.Join(escaped, "/")
}

// forgejoAPIError는 4xx/5xx 응답을 상태 코드와 함께 전달한다. 재시도 경로에서
// 문자열 비교 대신 코드로 분기하기 위해 필요하다. 토큰은 담기지 않는다.
type forgejoAPIError struct {
	Method string
	Status int
}

func (e *forgejoAPIError) Error() string {
	return fmt.Sprintf("Forgejo %s 응답 %d", e.Method, e.Status)
}

// forgejoStatus는 에러에서 HTTP 상태 코드를 꺼낸다. API 응답이 아니면 0이다.
func forgejoStatus(err error) int {
	var apiErr *forgejoAPIError
	if errors.As(err, &apiErr) {
		return apiErr.Status
	}
	return 0
}

// do는 JSON 요청을 보내고 성공 시 응답을 out에 담는다. 에러에는 토큰을 넣지 않는다.
func (f *forgejoClient) do(ctx context.Context, method, endpoint string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("요청 직렬화 실패: %w", err)
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return fmt.Errorf("요청 생성 실패: %w", err)
	}
	request.Header.Set("Authorization", "token "+f.config.Token)
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := f.client.Do(request)
	if err != nil {
		// url.Error는 요청 URL만 담고 헤더는 담지 않으므로 토큰이 새지 않는다.
		return fmt.Errorf("Forgejo 호출 실패: %w", err)
	}
	defer func() {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4<<10))
		_ = response.Body.Close()
	}()

	if response.StatusCode >= 400 {
		return &forgejoAPIError{
			Method: method,
			Status: response.StatusCode,
		}
	}
	if out != nil {
		decoded, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if err != nil {
			return fmt.Errorf("Forgejo 응답 읽기 실패: %w", err)
		}
		if err := json.Unmarshal(decoded, out); err != nil {
			return fmt.Errorf("Forgejo 응답 해석 실패: %w", err)
		}
	}
	return nil
}

// probe는 기동 시 연결 가능 여부를 판정한다. 실패해도 서비스는 계속 뜬다.
func (f *forgejoClient) probe(ctx context.Context) error {
	var version struct {
		Version string `json:"version"`
	}
	return f.do(ctx, http.MethodGet, f.config.BaseURL+"/api/v1/version", nil, &version)
}

func (f *forgejoClient) repoPath(tail ...string) string {
	segments := append([]string{"repos", f.config.Owner, f.config.Repo}, tail...)
	return f.apiURL(segments...)
}

// sourceRepoPath는 포털 GitOps 저장소가 아니라 사용자가 입력한 같은 Forgejo의
// 저장소를 읽을 때 쓴다. owner/repo는 URL 검증을 통과한 뒤에만 이 함수로 온다.
func (f *forgejoClient) sourceRepoPath(owner, repo string, tail ...string) string {
	segments := append([]string{"repos", owner, repo}, tail...)
	return f.apiURL(segments...)
}

type forgejoRepository struct {
	DefaultBranch string `json:"default_branch"`
}

type forgejoTreeEntry struct {
	Path string `json:"path"`
	Type string `json:"type"`
	Mode string `json:"mode"`
	Size int64  `json:"size"`
}

type forgejoTreePage struct {
	Entries    []forgejoTreeEntry `json:"tree"`
	Truncated  bool               `json:"truncated"`
	Page       int                `json:"page"`
	TotalCount int                `json:"total_count"`
}

func (f *forgejoClient) sourceRepository(ctx context.Context, owner, repo string) (forgejoRepository, error) {
	var result forgejoRepository
	err := f.do(ctx, http.MethodGet, f.sourceRepoPath(owner, repo), nil, &result)
	return result, err
}

func (f *forgejoClient) sourceBranchRevision(ctx context.Context, owner, repo, branch string) (string, error) {
	var detail struct {
		Commit struct {
			ID string `json:"id"`
		} `json:"commit"`
	}
	if err := f.do(ctx, http.MethodGet, f.sourceRepoPath(owner, repo, "branches", branch), nil, &detail); err != nil {
		return "", err
	}
	if detail.Commit.ID == "" {
		return "", errors.New("Forgejo branch commit id가 비어 있음")
	}
	return detail.Commit.ID, nil
}

// sourceTree는 자동 탐색에 필요한 경로만 읽는다. 페이지 수와 전체 entry 수를 함께
// 제한해 아주 큰 저장소가 Portal 메모리와 Forgejo API를 독점하지 못하게 한다.
func (f *forgejoClient) sourceTree(
	ctx context.Context, owner, repo, revision string, maxEntries int,
) ([]forgejoTreeEntry, error) {
	entries := make([]forgejoTreeEntry, 0, min(maxEntries, 1000))
	for page := 1; ; page++ {
		endpoint := f.sourceRepoPath(owner, repo, "git", "trees", revision) +
			fmt.Sprintf("?recursive=true&page=%d&per_page=1000", page)
		var result forgejoTreePage
		if err := f.do(ctx, http.MethodGet, endpoint, nil, &result); err != nil {
			return nil, err
		}
		if len(entries)+len(result.Entries) > maxEntries {
			return nil, fmt.Errorf("저장소 파일 수가 자동 탐색 상한 %d개를 넘습니다", maxEntries)
		}
		entries = append(entries, result.Entries...)
		if !result.Truncated {
			break
		}
		if len(result.Entries) == 0 {
			return nil, errors.New("Forgejo tree 응답이 잘린 상태에서 다음 페이지가 비었습니다")
		}
	}
	return entries, nil
}

func (f *forgejoClient) sourceFile(
	ctx context.Context, owner, repo, filePath, revision string,
) (string, error) {
	segments := strings.Split(strings.TrimPrefix(filePath, "/"), "/")
	escaped := make([]string, 0, len(segments))
	for _, segment := range segments {
		escaped = append(escaped, url.PathEscape(segment))
	}
	endpoint := f.sourceRepoPath(owner, repo, "contents") + "/" + strings.Join(escaped, "/")
	metadata, err := f.fileMetadata(ctx, endpoint, revision)
	if err != nil {
		return "", err
	}
	return metadata.Content, nil
}

func (f *forgejoClient) createBranch(ctx context.Context, branch string) error {
	payload := map[string]string{
		"new_branch_name": branch,
		"old_branch_name": f.config.TargetBranch,
	}
	err := f.do(ctx, http.MethodPost, f.repoPath("branches"), payload, nil)
	// 재시도로 이미 만들어진 브랜치는 성공으로 간주한다.
	if err != nil && (forgejoStatus(err) == http.StatusConflict || strings.Contains(err.Error(), "already exists")) {
		return nil
	}
	return err
}

// putFile은 values 파일을 새 브랜치에 커밋한다. contents API 경로는 별도로 이스케이프한다.
func (f *forgejoClient) putFile(ctx context.Context, branch, filePath, message, content string) error {
	segments := strings.Split(strings.TrimPrefix(filePath, "/"), "/")
	escaped := make([]string, 0, len(segments))
	for _, segment := range segments {
		escaped = append(escaped, url.PathEscape(segment))
	}
	endpoint := f.repoPath("contents") + "/" + strings.Join(escaped, "/")
	payload := map[string]string{
		"branch":  branch,
		"content": base64.StdEncoding.EncodeToString([]byte(content)),
		"message": message,
	}
	err := f.do(ctx, http.MethodPost, endpoint, payload, nil)
	if err == nil {
		return nil
	}
	// 앞선 시도가 커밋까지 성공하고 PR에서 실패했다면 파일이 이미 있다. 이때
	// POST는 영구 실패하므로 sha를 받아 PUT(갱신)으로 전환해 재시도를 살린다.
	status := forgejoStatus(err)
	if status != http.StatusConflict && status != http.StatusUnprocessableEntity {
		return err
	}
	meta, metaErr := f.fileMetadata(ctx, endpoint, branch)
	if metaErr != nil || meta.SHA == "" {
		return err
	}
	if !isPortalManagedFile(meta.Content) {
		return fmt.Errorf("GitOps 경로 %s에는 포털이 소유하지 않은 파일이 이미 있습니다", filePath)
	}
	payload["sha"] = meta.SHA
	return f.do(ctx, http.MethodPut, endpoint, payload, nil)
}

// updateFileAtSHA는 읽은 바로 그 blob만 갱신한다. runtime 전환처럼 기존 values를
// 부분 패치할 때 일반 putFile을 쓰면 GET 뒤 다른 commit을 새 snapshot으로 덮을 수 있다.
func (f *forgejoClient) updateFileAtSHA(
	ctx context.Context, branch, filePath, message, content, sha string,
) error {
	if sha == "" {
		return errors.New("GitOps 파일 갱신에 blob SHA가 없음")
	}
	payload := map[string]string{
		"branch": branch, "content": base64.StdEncoding.EncodeToString([]byte(content)),
		"message": message, "sha": sha,
	}
	return f.do(ctx, http.MethodPut, f.fileEndpoint(filePath), payload, nil)
}

type forgejoFileMetadata struct {
	SHA     string
	Content string
}

// fileMetadata는 기존 파일 갱신 전에 sha와 본문을 함께 읽는다. sha만 확인하면
// 정적 platform 파일도 포털 생성물로 오인해 PUT/DELETE할 수 있다.
func (f *forgejoClient) fileMetadata(ctx context.Context, endpoint, branch string) (forgejoFileMetadata, error) {
	var meta struct {
		SHA      string `json:"sha"`
		Content  string `json:"content"`
		Encoding string `json:"encoding"`
	}
	if err := f.do(ctx, http.MethodGet, endpoint+"?ref="+url.QueryEscape(branch), nil, &meta); err != nil {
		return forgejoFileMetadata{}, err
	}
	if meta.Encoding != "" && meta.Encoding != "base64" {
		return forgejoFileMetadata{}, fmt.Errorf("지원하지 않는 Forgejo 파일 인코딩: %s", meta.Encoding)
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' {
			return -1
		}
		return r
	}, meta.Content))
	if err != nil {
		return forgejoFileMetadata{}, fmt.Errorf("Forgejo 파일 본문 해석 실패: %w", err)
	}
	return forgejoFileMetadata{SHA: meta.SHA, Content: string(decoded)}, nil
}

func isPortalManagedFile(content string) bool {
	return content == portalManagedFileMarker ||
		strings.HasPrefix(content, portalManagedFileMarker+"\n") ||
		strings.HasPrefix(content, portalManagedFileMarker+"\r\n")
}

func (f *forgejoClient) deleteFile(ctx context.Context, branch, filePath, message string) (bool, error) {
	endpoint := f.fileEndpoint(filePath)
	meta, err := f.fileMetadata(ctx, endpoint, branch)
	if err != nil {
		// 재시도에서 이미 삭제된 파일은 성공으로 수렴시킨다.
		if forgejoStatus(err) == http.StatusNotFound {
			return false, nil
		}
		return false, err
	}
	if !isPortalManagedFile(meta.Content) {
		return false, fmt.Errorf("GitOps 경로 %s에는 포털이 소유하지 않은 파일이 있습니다", filePath)
	}
	payload := map[string]string{"branch": branch, "message": message, "sha": meta.SHA}
	if err := f.do(ctx, http.MethodDelete, endpoint, payload, nil); err != nil &&
		forgejoStatus(err) != http.StatusNotFound {
		return false, err
	}
	return true, nil
}

func (f *forgejoClient) fileEndpoint(filePath string) string {
	segments := strings.Split(strings.TrimPrefix(filePath, "/"), "/")
	escaped := make([]string, 0, len(segments))
	for _, segment := range segments {
		escaped = append(escaped, url.PathEscape(segment))
	}
	return f.repoPath("contents") + "/" + strings.Join(escaped, "/")
}

func (f *forgejoClient) fileExists(ctx context.Context, filePath, branch string) (bool, error) {
	_, err := f.fileMetadata(ctx, f.fileEndpoint(filePath), branch)
	if forgejoStatus(err) == http.StatusNotFound {
		return false, nil
	}
	return err == nil, err
}

func (f *forgejoClient) managedFileExists(ctx context.Context, filePath, branch string) (bool, error) {
	meta, err := f.fileMetadata(ctx, f.fileEndpoint(filePath), branch)
	if forgejoStatus(err) == http.StatusNotFound {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !isPortalManagedFile(meta.Content) {
		return false, fmt.Errorf("GitOps 경로 %s에는 포털이 소유하지 않은 파일이 있습니다", filePath)
	}
	return true, nil
}

func (f *forgejoClient) branchRevision(ctx context.Context, branch string) (string, error) {
	var detail struct {
		Commit struct {
			ID string `json:"id"`
		} `json:"commit"`
	}
	if err := f.do(ctx, http.MethodGet, f.repoPath("branches", branch), nil, &detail); err != nil {
		return "", err
	}
	if detail.Commit.ID == "" {
		return "", errors.New("Forgejo branch commit id가 비어 있음")
	}
	return detail.Commit.ID, nil
}

func (f *forgejoClient) createPullRequest(ctx context.Context, branch, title, body string) (*pullRequestRef, error) {
	payload := map[string]string{
		"head":  branch,
		"base":  f.config.TargetBranch,
		"title": title,
		"body":  body,
	}
	var created struct {
		Number  int    `json:"number"`
		HTMLURL string `json:"html_url"`
		State   string `json:"state"`
	}
	if err := f.do(ctx, http.MethodPost, f.repoPath("pulls"), payload, &created); err != nil {
		// Forgejo가 PR을 만들고 응답만 유실된 경우 HTTP 오류 종류와 무관하게 같은
		// deterministic branch의 open PR을 다시 찾는다. 찾지 않으면 다음 generation에
		// 닫을 pointer가 없어 stale stop/start PR이 나중에 병합될 수 있다.
		if existing, lookupErr := f.findPullRequest(ctx, branch); lookupErr == nil && existing != nil {
			return existing, nil
		}
		return nil, err
	}
	return &pullRequestRef{
		Number: created.Number,
		URL:    created.HTMLURL,
		Branch: branch,
		State:  created.State,
	}, nil
}

// findPullRequest는 해당 head 브랜치로 열려 있는 PR을 찾는다. 없으면 nil을 준다.
func (f *forgejoClient) findPullRequest(ctx context.Context, branch string) (*pullRequestRef, error) {
	var list []struct {
		Number  int    `json:"number"`
		HTMLURL string `json:"html_url"`
		State   string `json:"state"`
		Head    struct {
			Ref string `json:"ref"`
		} `json:"head"`
	}
	if err := f.do(ctx, http.MethodGet, f.repoPath("pulls")+"?state=open&limit=50", nil, &list); err != nil {
		return nil, err
	}
	for _, pr := range list {
		if pr.Head.Ref == branch {
			return &pullRequestRef{
				Number: pr.Number,
				URL:    pr.HTMLURL,
				Branch: branch,
				State:  pr.State,
			}, nil
		}
	}
	return nil, nil
}

// enqueue는 PR 생성 작업을 워커에 넘긴다. 큐가 가득 차면 즉시 실패로 표시한다.
func (f *forgejoClient) enqueue(requestID string) error {
	f.queueMu.Lock()
	defer f.queueMu.Unlock()
	if f.queued == nil {
		f.queued = make(map[string]struct{})
	}
	if _, exists := f.queued[requestID]; exists {
		if f.processing != nil && f.processing[requestID] {
			if f.rerun == nil {
				f.rerun = make(map[string]bool)
			}
			f.rerun[requestID] = true
		}
		return nil
	}
	select {
	case f.queue <- requestID:
		f.queued[requestID] = struct{}{}
		return nil
	default:
		return errors.New("PR 처리 대기열이 가득 찼습니다")
	}
}

func (f *forgejoClient) beginQueued(requestID string) {
	f.queueMu.Lock()
	if f.processing == nil {
		f.processing = make(map[string]bool)
	}
	f.processing[requestID] = true
	f.queueMu.Unlock()
}

// finishQueued는 처리 중 들어온 재예약이 있으면 marker를 지우지 않고 한 번 더 돌린다.
func (f *forgejoClient) finishQueued(requestID string) bool {
	f.queueMu.Lock()
	defer f.queueMu.Unlock()
	if f.rerun != nil && f.rerun[requestID] {
		delete(f.rerun, requestID)
		return true
	}
	delete(f.queued, requestID)
	delete(f.processing, requestID)
	return false
}

// run은 큐를 순차 처리한다. 순차 처리는 Forgejo에 부하를 주지 않으려는 의도적 선택이다.
func (f *forgejoClient) run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case requestID := <-f.queue:
			f.beginQueued(requestID)
			for {
				f.process(ctx, requestID)
				if !f.finishQueued(requestID) || ctx.Err() != nil {
					break
				}
			}
		}
	}
}

// prepareSourceUpdate는 자동 source update의 이미지를 PR 전에 만든다. 실행 중 values를
// CHANGE_ME tag로 먼저 바꾸면 Argo가 존재하지 않는 image를 rollout할 수 있으므로,
// 빌드가 성공해 Registry에 존재하는 immutable tag만 PR diff에 넣는다.
func (f *forgejoClient) prepareSourceUpdate(
	ctx context.Context, request deploymentRequest,
) (deploymentRequest, bool) {
	if !request.SourceUpdate || request.PullRequest != nil || request.Generated.Image != "" {
		return request, true
	}
	if request.State != stateReceived && request.State != stateBuilding {
		return request, true
	}
	if f.builder == nil {
		f.failRequest(request, "자동 source update 빌드가 준비되지 않았습니다.",
			errors.New("source update build pipeline이 비활성입니다"))
		return request, false
	}
	request.State = stateBuilding
	request.FailedFromState = ""
	f.saveRequest(request)
	tag, err := f.builder.build(ctx, request)
	if err != nil {
		f.failRequest(request, "새 source commit 이미지 빌드에 실패했습니다.", err)
		return request, false
	}
	request.Generated.Image = imageDestination(request, tag)
	request.State = stateReceived
	request.Message = ""
	f.saveRequest(request)
	f.logger.Printf("요청 %s source update 사전 빌드 완료: %s", request.ID, request.Generated.Image)
	return request, true
}

// process는 한 요청의 PR을 만들고 결과를 저장소에 반영한다.
func (f *forgejoClient) process(ctx context.Context, requestID string) {
	request, ok := f.store.get(requestID)
	if !ok {
		return
	}
	if prepared, proceed := f.prepareSourceUpdate(ctx, request); !proceed {
		return
	} else {
		request = prepared
	}
	// 이미 PR이 있는 요청은 남은 단계(병합·빌드·태그 커밋)만 이어서 밟는다.
	switch request.State {
	case stateDeployed, stateStopped, stateDeleted:
		return
	case stateDeleting:
		f.deleteApp(ctx, request)
		return
	case stateStopping, stateStarting:
		f.applyRuntimeState(ctx, request)
		return
	case stateFailed:
		if request.DeletionRequested {
			request.State = stateDeleting
			request.FailedFromState = ""
			f.saveRequest(request)
			f.deleteApp(ctx, request)
			return
		}
		if lifecycleTransition(request.FailedFromState) {
			// 프로세스 재시작 자동 복구도 닫힌 PR/branch와 충돌하지 않도록 새
			// runtime 세대를 만든다. 배포 생성 PR 감사 필드는 그대로 둔다.
			replacement := request
			replacement.RuntimeGeneration++
			if request.RuntimePullRequest != nil {
				replacement.RuntimeSupersededPullRequest = request.RuntimePullRequest
			}
			replacement.RuntimePullRequest = nil
			replacement.RuntimeDesiredRevision = ""
			replacement.RuntimeApplicationSynced = false
			replacement.State = request.FailedFromState
			replacement.FailedFromState = ""
			updated, applied, err := f.store.updateIfCurrent(request, replacement)
			if err != nil {
				f.logger.Printf("요청 %s runtime 복구 상태 기록 실패: %v", request.ID, err)
				return
			}
			if !applied {
				// DELETE나 사용자의 명시적 재시도가 먼저 전환한 상태를 오래된
				// startup worker가 되돌리지 않는다.
				return
			}
			f.applyRuntimeState(ctx, updated)
			return
		}
	case statePROpen, stateMerged, stateBuilding, stateDeploying:
		f.advance(ctx, request)
		return
	}
	request.State = statePRCreating
	request.FailedFromState = ""
	if err := f.store.update(request); err != nil {
		f.logger.Printf("요청 %s 상태 기록 실패: %v", requestID, err)
	}

	var lastErr error
	for attempt := 1; attempt <= forgejoMaxTries; attempt++ {
		if ctx.Err() != nil {
			return
		}
		pullRequest, err := f.submit(ctx, request)
		if err == nil {
			request.State = statePROpen
			request.PullRequest = pullRequest
			request.Message = ""
			request.Attempts = attempt
			if err := f.store.update(request); err != nil {
				f.logger.Printf("요청 %s PR 결과 기록 실패: %v", requestID, err)
			}
			f.logger.Printf("요청 %s PR #%d 생성 완료", requestID, pullRequest.Number)
			// 자동 승인이 켜져 있으면 이어서 병합·빌드·배포 커밋까지 진행한다.
			f.advance(ctx, request)
			return
		}
		lastErr = err
		f.logger.Printf("요청 %s PR 생성 %d회차 실패: %v", requestID, attempt, err)
		if attempt == forgejoMaxTries {
			break
		}
		backoff := time.Duration(1<<uint(attempt-1)) * 2 * time.Second
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
	}

	request.FailedFromState = statePRCreating
	request.State = stateFailed
	request.Attempts = forgejoMaxTries
	request.Message = "Pull Request 생성에 실패했습니다. 플랫폼 관리자에게 문의하세요."
	if lastErr != nil {
		f.logger.Printf("요청 %s 최종 실패: %v", requestID, lastErr)
	}
	if err := f.store.update(request); err != nil {
		f.logger.Printf("요청 %s 실패 기록 실패: %v", requestID, err)
	}
}

// submit은 브랜치·커밋·PR을 순서대로 만든다.
func (f *forgejoClient) submit(ctx context.Context, request deploymentRequest) (*pullRequestRef, error) {
	appName := request.Profile.App.Name
	environment := request.Profile.App.Environment
	branch := fmt.Sprintf("%s/%s-%s", f.config.BranchPrefix, appName, request.ID)
	filePath := appValuesPath(request.Profile)
	commitMessage := fmt.Sprintf("feat(%s): %s 앱 배포 요청 추가", appName, environment)
	if request.SourceUpdate {
		short := request.Profile.Source.Commit
		if len(short) > 12 {
			short = short[:12]
		}
		branch = fmt.Sprintf("%s/update-%s-%s-%s", f.config.BranchPrefix, appName, short, request.ID)
		commitMessage = fmt.Sprintf("chore(%s): source commit %s 이미지 반영", appName, short)
	}
	if err := f.validateSourceHost(request); err != nil {
		return nil, err
	}

	if err := f.createBranch(ctx, branch); err != nil {
		return nil, err
	}
	repoURL := fmt.Sprintf("%s/%s/%s", strings.TrimRight(f.config.BaseURL, "/"), f.config.Owner, f.config.Repo)
	// AppGroup 앱은 Namespace bootstrap 이 같은 PR 에 들어가야 한다. 나중에 따로 넣으면
	// 첫 앱이 없는 Namespace 를 향해 sync 하다 실패한다. putFile 은 이미 있는 파일이면
	// 갱신하므로, 같은 그룹의 두 번째 앱부터는 내용이 같아 diff 가 생기지 않는다.
	if group, grouped := groupOf(request.Profile); grouped && !request.SourceUpdate {
		groupValues := renderGroupValuesYAML(group, request.ID,
			request.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"))
		if err := f.putFile(ctx, branch, groupValuesPath(group), commitMessage, groupValues); err != nil {
			return nil, err
		}
		groupApplication := renderGroupArgoApplicationYAML(group, repoURL, f.config.TargetBranch)
		if err := f.putFile(ctx, branch, groupApplicationPath(group), commitMessage, groupApplication); err != nil {
			return nil, err
		}
	}
	if err := f.putFile(ctx, branch, filePath, commitMessage, renderValuesYAML(request)); err != nil {
		return nil, err
	}
	if !request.SourceUpdate {
		applicationPath := appApplicationPath(request.Profile)
		application := renderArgoApplicationYAML(request, repoURL, f.config.TargetBranch)
		if err := f.putFile(ctx, branch, applicationPath, commitMessage, application); err != nil {
			return nil, err
		}
	}
	title := fmt.Sprintf("[portal] %s (%s) 배포 요청", appName, environment)
	if request.SourceUpdate {
		short := request.Profile.Source.Commit
		if len(short) > 12 {
			short = short[:12]
		}
		title = fmt.Sprintf("[portal] %s source update (%s)", appName, short)
	}
	if group, grouped := groupOf(request.Profile); grouped {
		if request.SourceUpdate {
			short := request.Profile.Source.Commit
			if len(short) > 12 {
				short = short[:12]
			}
			title = fmt.Sprintf("[portal] %s/%s source update (%s)", group.Name, appName, short)
		} else {
			title = fmt.Sprintf("[portal] %s/%s (%s) 배포 요청", group.Name, appName, environment)
		}
	}
	return f.createPullRequest(ctx, branch, title, renderPullRequestBody(request))
}

// validateSourceHost는 사내 build credential이 임의 Git 서버로 전달되는 것을 막는다.
// prebuilt image는 clone하지 않으므로 검사 대상이 아니다.
func (f *forgejoClient) validateSourceHost(request deploymentRequest) error {
	if request.Profile.Source.Image != "" {
		return nil
	}
	repository, err := url.Parse(request.Profile.Source.Repository)
	if err != nil || repository.Hostname() == "" {
		return errors.New("소스 저장소 주소를 해석할 수 없습니다")
	}
	host := strings.ToLower(repository.Hostname())
	for _, allowed := range f.config.AllowedGitHosts {
		if host == strings.ToLower(strings.TrimSpace(allowed)) {
			return nil
		}
	}
	return fmt.Errorf("소스 저장소 host %s 는 build credential 허용 목록에 없습니다", host)
}

func (f *forgejoClient) submitDeletion(ctx context.Context, request deploymentRequest) (*pullRequestRef, error) {
	appName := request.Profile.App.Name
	environment := request.Profile.App.Environment
	removeGroup := request.GroupCleanupDecided && request.GroupCleanupPlanned
	if group, grouped := groupOf(request.Profile); grouped && !request.GroupCleanupDecided {
		removeGroup = !f.store.groupHasOtherAppsOwned(group.Name, group.Project, group.Environment,
			request.Requester, appName)
	}
	cleanupScope := "app"
	if removeGroup {
		cleanupScope = "group"
	}
	// cleanup 범위가 바뀌면 새 branch를 써야 앞선 부분 실패 branch의 stale group delete
	// commit을 다음 PR에 끌고 가지 않는다.
	branch := fmt.Sprintf("%s/delete-%s-%s-%s", f.config.BranchPrefix, appName, request.ID, cleanupScope)
	message := fmt.Sprintf("chore(%s): %s 앱 배포 삭제", appName, environment)
	if existing, err := f.findPullRequest(ctx, branch); err != nil {
		return nil, err
	} else if existing != nil {
		return existing, nil
	}

	if err := f.createBranch(ctx, branch); err != nil {
		return nil, err
	}
	valuesPath := appValuesPath(request.Profile)
	deletePaths := []string{valuesPath}
	_, err := f.deleteFile(ctx, branch, valuesPath, message)
	if err != nil {
		return nil, err
	}
	applicationPath := appApplicationPath(request.Profile)
	deletePaths = append(deletePaths, applicationPath)
	_, err = f.deleteFile(ctx, branch, applicationPath, message)
	if err != nil {
		return nil, err
	}
	// AppGroup 의 마지막 앱이면 Namespace bootstrap 도 함께 지운다. 남겨 두면 빈
	// Namespace 가 ResourceQuota 를 계속 붙들고, 다음 사용자에게는 원인이 보이지 않는다.
	if group, grouped := groupOf(request.Profile); grouped && removeGroup {
		deletePaths = append(deletePaths, groupValuesPath(group), groupApplicationPath(group))
		_, err := f.deleteFile(ctx, branch, groupValuesPath(group), message)
		if err != nil {
			return nil, err
		}
		_, err = f.deleteFile(ctx, branch, groupApplicationPath(group), message)
		if err != nil {
			return nil, err
		}
	}
	// 삭제 branch가 부분 커밋된 재시도에서도 target의 현재 ownership을 매번 확인한다.
	// 하나라도 새로 branch에서 지웠다는 이유로 이 검사를 건너뛰면, 앞서 지운 다른 path를
	// 사람이 비관리 파일로 교체한 뒤에도 stale delete commit으로 덮을 수 있다.
	pending := false
	for _, path := range deletePaths {
		exists, err := f.managedFileExists(ctx, path, f.config.TargetBranch)
		if err != nil {
			return nil, err
		}
		pending = pending || exists
	}
	if !pending {
		return nil, nil
	}
	body := fmt.Sprintf(
		"SADP 포털에서 `%s` 앱 삭제를 요청했습니다.\n\n"+
			"- 요청 ID: `%s`\n- 신청자: `%s`\n- Namespace: `%s`\n\n"+
			"원본 소스 저장소와 Registry image 이력은 삭제하지 않습니다.\n",
		markdownCode(appName), markdownCode(request.ID), markdownCode(request.Requester),
		markdownCode(request.Profile.namespace()),
	)
	if removeGroup {
		body += fmt.Sprintf(
			"\n앱 그룹 `%s`의 마지막 앱이라 전용 Namespace도 함께 정리합니다.\n",
			markdownCode(request.Profile.App.Group))
	}
	return f.createPullRequest(ctx, branch,
		fmt.Sprintf("[portal] %s (%s) 앱 삭제", appName, environment), body)
}
