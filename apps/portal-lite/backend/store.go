package main

// 배포 요청은 PVC의 append-only JSONL 로그에 기록한다. 외부 의존성 없이 재시작 후
// 상태를 복원하고, Idempotency-Key 재요청에 같은 결과를 돌려주기 위한 색인을 함께 만든다.

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	stateReceived   = "received"
	statePRCreating = "pr-creating"
	statePROpen     = "pr-open"
	// 승인 증거가 별도 필드에 영속화된 뒤에만 merged 이후 단계로 진행한다.
	stateMerged    = "merged"
	stateBuilding  = "building"
	stateDeploying = "deploying"
	stateDeployed  = "deployed"
	stateDeleting  = "deleting"
	stateDeleted   = "deleted"
	stateFailed    = "failed"

	// 보존 윈도우. 개발자 100명 기준 하루 수십 건이므로 약 반년 분량이다.
	// 한도를 넘기면 신규 요청을 거부하는 대신 종료된 오래된 요청을 밀어낸다.
	maxStoredRequests = 10000
	compactThreshold  = 30000

	storeFileName = "requests.jsonl"
)

var (
	errDeleteNotFound   = errors.New("삭제할 배포 요청을 찾을 수 없음")
	errDeleteStale      = errors.New("최신 앱 요청이 아님")
	errDeleteInProgress = errors.New("진행 중인 앱은 삭제할 수 없음")
	errArtifactClaimed  = errors.New("배포 대상이 이미 다른 앱에 선점됨")
)

type pullRequestRef struct {
	Number int    `json:"number"`
	URL    string `json:"url,omitempty"`
	Branch string `json:"branch"`
	State  string `json:"state"`
}

type deploymentRequest struct {
	ID                string            `json:"id"`
	State             string            `json:"state"`
	CreatedAt         time.Time         `json:"createdAt"`
	UpdatedAt         time.Time         `json:"updatedAt"`
	Requester         string            `json:"requester,omitempty"`
	Profile           normalizedProfile `json:"profile"`
	Generated         generatedPlan     `json:"generated"`
	PullRequest       *pullRequestRef   `json:"pullRequest,omitempty"`
	Message           string            `json:"message,omitempty"`
	Attempts          int               `json:"attempts,omitempty"`
	DeletionRequested bool              `json:"deletionRequested,omitempty"`
	// GitCommitted는 이 프로필의 desired state가 target branch에 들어갔음을 뜻한다.
	// 실패 상태만 보고 quota에서 빼면 merge 뒤 rollout 실패를 반복해 상한을 우회할 수 있다.
	GitCommitted bool `json:"gitCommitted,omitempty"`
	// DesiredRevision을 Argo Application이 실제로 관찰한 뒤에만 ApplicationSynced를 세운다.
	// 같은 image를 계속 쓰는 보안정책 재배포를 이전 Ready Deployment로 오인하지 않기 위한 증거다.
	DesiredRevision   string `json:"desiredRevision,omitempty"`
	ApplicationSynced bool   `json:"applicationSynced,omitempty"`
	// 실패 직전 단계를 보존해야 merge 전 실패와 rollout 후 실패를 구분할 수 있다.
	FailedFromState string `json:"failedFromState,omitempty"`
	// AppGroup 마지막 앱 판정은 Git 삭제와 Namespace/OpenBao 정리가 같은 결정을 써야 한다.
	GroupCleanupDecided bool `json:"groupCleanupDecided,omitempty"`
	GroupCleanupPlanned bool `json:"groupCleanupPlanned,omitempty"`
	// DesiredRuntimeState는 Service/PVC를 보존한 stop/start의 목표다. 빈 값은
	// 구버전 JSONL과 호환되는 running이며 generation은 PR branch를 유일하게 만든다.
	DesiredRuntimeState string `json:"desiredRuntimeState,omitempty"`
	RuntimeGeneration   int    `json:"runtimeGeneration,omitempty"`
	// 배포 생성 PR의 감사 정보를 덮어쓰지 않도록 stop/start PR과 Argo checkpoint는
	// 별도 필드에 둔다. 실패 재시도는 generation을 올리고 이 checkpoint만 초기화한다.
	RuntimePullRequest           *pullRequestRef `json:"runtimePullRequest,omitempty"`
	RuntimeSupersededPullRequest *pullRequestRef `json:"runtimeSupersededPullRequest,omitempty"`
	RuntimeDesiredRevision       string          `json:"runtimeDesiredRevision,omitempty"`
	RuntimeApplicationSynced     bool            `json:"runtimeApplicationSynced,omitempty"`
	// Secret 값보다 요청 기록이 먼저 durable해야 한다. true이면 OpenBao 쓰기가 아직
	// 확인되지 않았으므로 worker/restart가 GitOps 배포를 시작하면 안 된다.
	SecretWritePending bool `json:"secretWritePending,omitempty"`
	// SourceUpdate는 사용자가 등록한 Forgejo branch의 새 commit을 감지해 만든 자동
	// 재배포다. 최초 신청과 구분해야 빌드를 PR 전에 끝내고 immutable tag만 검토시킬 수 있다.
	SourceUpdate bool `json:"sourceUpdate,omitempty"`
	// Approval과 SecurityReview는 파이프라인 state와 분리한다. PR이 열렸다는 사실을
	// 승인으로 오인하거나, 재시작 뒤 승인 증거 없이 병합하는 일을 막기 위한 경계다.
	Approval       approvalDecision `json:"approval"`
	SecurityReview securityReview   `json:"securityReview"`
}

// storeRecord는 로그 한 줄이다. 같은 ID의 뒤에 오는 줄이 앞의 줄을 덮어쓴다.
type storeRecord struct {
	Kind           string             `json:"kind"`
	IdempotencyKey string             `json:"idempotencyKey,omitempty"`
	BodyHash       string             `json:"bodyHash,omitempty"`
	Request        *deploymentRequest `json:"request,omitempty"`
	Policy         *approvalPolicy    `json:"approvalPolicy,omitempty"`
}

type idempotencyEntry struct {
	requestID string
	bodyHash  string
}

type store struct {
	mu       sync.Mutex
	dir      string
	file     *os.File
	lines    int
	byID     map[string]deploymentRequest
	byIdem   map[string]idempotencyEntry
	ordered  []string
	policies map[string]approvalPolicy
}

// hashBody는 Idempotency-Key 재사용 시 본문이 같은지 비교할 지문을 만든다.
func hashBody(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func newStore(dir string) (*store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("상태 디렉터리 생성 실패: %w", err)
	}
	s := &store{
		dir:      dir,
		byID:     make(map[string]deploymentRequest),
		byIdem:   make(map[string]idempotencyEntry),
		policies: make(map[string]approvalPolicy),
	}
	if err := s.replay(); err != nil {
		return nil, err
	}
	if s.lines > compactThreshold {
		if err := s.compact(); err != nil {
			return nil, err
		}
	}
	file, err := os.OpenFile(s.path(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("상태 파일 열기 실패: %w", err)
	}
	s.file = file
	return s, nil
}

func (s *store) path() string {
	return filepath.Join(s.dir, storeFileName)
}

// replay는 기존 로그를 순서대로 적용해 메모리 상태를 복원한다. 손상된 줄은 건너뛴다.
func (s *store) replay() error {
	file, err := os.Open(s.path())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("상태 파일 읽기 실패: %w", err)
	}
	defer func() { _ = file.Close() }()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var record storeRecord
		if err := json.Unmarshal(line, &record); err != nil {
			continue
		}
		if record.Request == nil && (record.Policy == nil || record.Policy.Requester == "") {
			continue
		}
		s.lines++
		s.apply(record)
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("상태 파일 스캔 실패: %w", err)
	}
	return nil
}

// apply는 레코드 하나를 메모리 색인에 반영한다. 잠금은 호출자가 잡는다.
func (s *store) apply(record storeRecord) {
	if record.Policy != nil {
		s.policies[record.Policy.Requester] = *record.Policy
		return
	}
	if record.Request == nil {
		return
	}
	// 구버전 JSONL에는 내부 주소가 없다. Service의 논리 좌표에서 다시 만들 수 있는
	// 파생값이므로 마이그레이션용 쓰기 없이 replay 시 메모리 표현만 보강한다.
	record.Request.Profile.populateInternalAddress()
	backfillReviewEvidence(record.Request)
	id := record.Request.ID
	if _, seen := s.byID[id]; !seen {
		s.ordered = append(s.ordered, id)
	}
	s.byID[id] = *record.Request
	if record.IdempotencyKey != "" {
		s.byIdem[record.IdempotencyKey] = idempotencyEntry{requestID: id, bodyHash: record.BodyHash}
	}
}

// append는 한 줄을 기록하고 fsync까지 마친 뒤 메모리에 반영한다. 잠금은 호출자가 잡는다.
func (s *store) append(record storeRecord) error {
	encoded, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("상태 직렬화 실패: %w", err)
	}
	encoded = append(encoded, '\n')
	if _, err := s.file.Write(encoded); err != nil {
		return fmt.Errorf("상태 기록 실패: %w", err)
	}
	if err := s.file.Sync(); err != nil {
		return fmt.Errorf("상태 동기화 실패: %w", err)
	}
	s.lines++
	s.apply(record)
	return nil
}

// compact는 ID별 최신 상태만 남긴 파일로 원자적으로 교체한다. 잠금은 호출자가 잡는다.
func (s *store) compact() error {
	temporary, err := os.CreateTemp(s.dir, "requests-*.tmp")
	if err != nil {
		return fmt.Errorf("압축 임시 파일 생성 실패: %w", err)
	}
	temporaryPath := temporary.Name()
	defer func() {
		_ = temporary.Close()
		_ = os.Remove(temporaryPath)
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return fmt.Errorf("압축 임시 파일 권한 설정 실패: %w", err)
	}

	idemByID := make(map[string]idempotencyEntry, len(s.byIdem))
	keyByID := make(map[string]string, len(s.byIdem))
	for key, entry := range s.byIdem {
		idemByID[entry.requestID] = entry
		keyByID[entry.requestID] = key
	}

	writer := bufio.NewWriter(temporary)
	kept := s.retained()
	for _, id := range kept {
		request := s.byID[id]
		record := storeRecord{Kind: "create", Request: &request}
		if key, ok := keyByID[id]; ok {
			record.IdempotencyKey = key
			record.BodyHash = idemByID[id].bodyHash
		}
		encoded, err := json.Marshal(record)
		if err != nil {
			return fmt.Errorf("압축 직렬화 실패: %w", err)
		}
		if _, err := writer.Write(append(encoded, '\n')); err != nil {
			return fmt.Errorf("압축 기록 실패: %w", err)
		}
	}
	for _, policy := range s.policies {
		policyCopy := policy
		encoded, err := json.Marshal(storeRecord{Kind: "approval-policy", Policy: &policyCopy})
		if err != nil {
			return fmt.Errorf("승인 정책 압축 직렬화 실패: %w", err)
		}
		if _, err := writer.Write(append(encoded, '\n')); err != nil {
			return fmt.Errorf("승인 정책 압축 기록 실패: %w", err)
		}
	}
	if err := writer.Flush(); err != nil {
		return fmt.Errorf("압축 flush 실패: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		return fmt.Errorf("압축 동기화 실패: %w", err)
	}
	if err := os.Rename(temporaryPath, s.path()); err != nil {
		return fmt.Errorf("압축 교체 실패: %w", err)
	}
	if directory, err := os.Open(s.dir); err == nil {
		_ = directory.Sync()
		_ = directory.Close()
	}

	// 이미 열린 append 핸들은 교체로 삭제된 inode를 가리키므로 반드시 다시 연다.
	if s.file != nil {
		_ = s.file.Close()
		reopened, err := os.OpenFile(s.path(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			s.file = nil
			return fmt.Errorf("압축 후 상태 파일 재오픈 실패: %w", err)
		}
		s.file = reopened
	}

	// 메모리 색인을 남긴 집합으로 재구성한다.
	retained := make(map[string]deploymentRequest, len(kept))
	for _, id := range kept {
		retained[id] = s.byID[id]
	}
	for key, entry := range s.byIdem {
		if _, ok := retained[entry.requestID]; !ok {
			delete(s.byIdem, key)
		}
	}
	s.byID = retained
	s.ordered = kept
	s.lines = len(kept) + len(s.policies)
	return nil
}

// retained는 보존할 ID를 생성 순서로 돌려준다. 미완료 작업뿐 아니라 각 GitOps 앱
// identity의 최신 non-deleted 레코드도 반드시 남긴다. deployed를 일반 이력으로
// 밀어내면 실제 파일/Secret은 남아 있는데 ownership claim만 사라진다.
func (s *store) retained() []string {
	protected := make(map[string]struct{})
	seenLatest := make(map[string]struct{})
	decidedIdentity := make(map[string]struct{})
	for i := len(s.ordered) - 1; i >= 0; i-- {
		id := s.ordered[i]
		request, ok := s.byID[id]
		if !ok {
			continue
		}
		identity := appIdentity(request.Profile)
		if _, seen := seenLatest[identity]; !seen {
			seenLatest[identity] = struct{}{}
			// 최신 non-deleted 레코드는 failed여도 appClaim의 근거이므로 남긴다.
			// PR merge 뒤 rollout만 실패했을 때 GitOps 파일은 이미 존재할 수 있다.
			if request.State != stateDeleted {
				protected[id] = struct{}{}
			}
			if request.State != stateFailed {
				decidedIdentity[identity] = struct{}{}
			}
		} else if _, decided := decidedIdentity[identity]; !decided && request.State != stateFailed {
			// 최신 failed 재배포와 그 전에 실제로 살아 있던 프로필을 최대 두 건
			// 보존해야 누적 quota를 재시작 뒤에도 계산할 수 있다.
			decidedIdentity[identity] = struct{}{}
			if request.State != stateDeleted {
				protected[id] = struct{}{}
			}
		}
		if unfinishedRequest(request) {
			protected[id] = struct{}{}
		}
	}

	// 논리 identity(project/environment/group/app)는 다르더라도 같은 Git 경로와
	// Kubernetes 대상을 쓸 수 있다. 압축이 물리 대상의 현재 claim 근거를
	// 지우면 재시작 후 다른 프로젝트가 기존 리소스를 덮어쓸 수 있다.
	seenArtifactApps := make(map[string]map[string]struct{})
	for i := len(s.ordered) - 1; i >= 0; i-- {
		id := s.ordered[i]
		request, ok := s.byID[id]
		if !ok {
			continue
		}
		artifact := artifactIdentity(request.Profile)
		identity := appIdentity(request.Profile)
		seen, ok := seenArtifactApps[artifact]
		if !ok {
			seen = make(map[string]struct{})
			seenArtifactApps[artifact] = seen
		}
		if _, decided := seen[identity]; decided {
			continue
		}
		seen[identity] = struct{}{}
		if request.State == stateDeleted {
			continue
		}
		// 패치 전 로그에 충돌한 identity가 여럿 있으면 모두 남겨야
		// 재시작 후에도 호환되지 않는 소유자 하나를 놓치지 않는다.
		protected[id] = struct{}{}
	}

	budget := maxStoredRequests - len(protected)
	if budget < 0 {
		budget = 0
	}
	selected := make(map[string]struct{}, len(protected)+budget)
	for id := range protected {
		selected[id] = struct{}{}
	}
	for i := len(s.ordered) - 1; i >= 0 && budget > 0; i-- {
		id := s.ordered[i]
		if _, keep := selected[id]; keep {
			continue
		}
		if _, exists := s.byID[id]; !exists {
			continue
		}
		selected[id] = struct{}{}
		budget--
	}
	kept := make([]string, 0, len(selected))
	for _, id := range s.ordered {
		if _, keep := selected[id]; keep {
			kept = append(kept, id)
		}
	}
	return kept
}

func appIdentity(profile normalizedProfile) string {
	return profile.App.Project + "\x00" + profile.App.Environment + "\x00" +
		profile.App.Group + "\x00" + profile.App.Name
}

func sameAppIdentity(left, right normalizedProfile) bool {
	return appIdentity(left) == appIdentity(right)
}

// artifactIdentity는 실제 Kubernetes namespace/name 소유권 경계다. 단일 앱은
// project와 무관하게 공용 Zone을 쓰고, 그룹 앱은 AppGroup Namespace를 쓴다.
// 이 두 값은 Git values/Application 경로의 물리 충돌 범위보다도 더 보수적이다.
func artifactIdentity(profile normalizedProfile) string {
	return profile.namespace() + "\x00" + profile.App.Name
}

// pruneLocked는 보존 윈도우를 넘겼을 때 오래된 종료 요청을 정리한다. 잠금은 호출자가 잡는다.
func (s *store) pruneLocked() error {
	if s.lines <= compactThreshold && len(s.byID) <= maxStoredRequests {
		return nil
	}
	return s.compact()
}

func (s *store) create(request deploymentRequest, idempotencyKey, bodyHash string) error {
	return s.createBatch([]storeRecord{{
		Kind: "create", IdempotencyKey: idempotencyKey, BodyHash: bodyHash, Request: &request,
	}})
}

// createBatch는 AppGroup의 서비스 신청을 한 번의 append+fsync로 기록한다. 서비스마다
// 따로 저장하면 중간 디스크 오류에서 앞쪽 앱만 영구 저장되는 반쪽 스택이 생긴다.
func (s *store) createBatch(records []storeRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(records) == 0 {
		return nil
	}
	seenIDs := make(map[string]struct{}, len(records))
	seenKeys := make(map[string]struct{}, len(records))
	seenHosts := make(map[string]string, len(records))
	seenArtifacts := make(map[string]struct{}, len(records))
	encodedBatch := make([]byte, 0, len(records)*1024)
	for _, record := range records {
		if record.Request == nil || record.Request.ID == "" {
			return errors.New("배치 상태 레코드에 요청 ID가 없음")
		}
		if _, exists := s.byID[record.Request.ID]; exists {
			return fmt.Errorf("이미 저장된 요청 ID: %s", record.Request.ID)
		}
		if _, duplicate := seenIDs[record.Request.ID]; duplicate {
			return fmt.Errorf("배치 안에서 중복된 요청 ID: %s", record.Request.ID)
		}
		seenIDs[record.Request.ID] = struct{}{}
		artifact := artifactIdentity(record.Request.Profile)
		if _, duplicate := seenArtifacts[artifact]; duplicate {
			return fmt.Errorf("%w: 배치 안에서 배포 대상이 중복됨", errArtifactClaimed)
		}
		seenArtifacts[artifact] = struct{}{}
		if _, conflict := s.artifactConflictLocked(*record.Request); conflict {
			return fmt.Errorf("%w: app=%s", errArtifactClaimed, record.Request.Profile.App.Name)
		}
		if host := strings.ToLower(strings.TrimSpace(record.Request.Profile.Exposure.Host)); host != "" {
			identity := appIdentity(record.Request.Profile)
			if reservedPlatformHost(host) {
				return fmt.Errorf("플랫폼 예약 외부 도메인: %s", host)
			}
			if existing, claimed := s.hostClaimLocked(host); claimed &&
				!sameAppIdentity(existing.Profile, record.Request.Profile) {
				return fmt.Errorf("이미 다른 앱이 사용 중인 외부 도메인: %s", host)
			}
			if previous, duplicate := seenHosts[host]; duplicate && previous != identity {
				return fmt.Errorf("배치 안에서 서로 다른 앱의 외부 도메인이 중복됨: %s", host)
			}
			seenHosts[host] = identity
		}
		if record.IdempotencyKey != "" {
			if _, exists := s.byIdem[record.IdempotencyKey]; exists {
				return fmt.Errorf("이미 저장된 Idempotency-Key: %s", record.IdempotencyKey)
			}
			if _, duplicate := seenKeys[record.IdempotencyKey]; duplicate {
				return fmt.Errorf("배치 안에서 중복된 Idempotency-Key: %s", record.IdempotencyKey)
			}
			seenKeys[record.IdempotencyKey] = struct{}{}
		}
		encoded, err := json.Marshal(record)
		if err != nil {
			return fmt.Errorf("상태 직렬화 실패: %w", err)
		}
		encodedBatch = append(encodedBatch, encoded...)
		encodedBatch = append(encodedBatch, '\n')
	}
	stat, err := s.file.Stat()
	if err != nil {
		return fmt.Errorf("상태 파일 크기 확인 실패: %w", err)
	}
	rollback := func() {
		_ = s.file.Truncate(stat.Size())
		_ = s.file.Sync()
	}
	written, err := s.file.Write(encodedBatch)
	if err != nil || written != len(encodedBatch) {
		rollback()
		if err == nil {
			err = io.ErrShortWrite
		}
		return fmt.Errorf("상태 배치 기록 실패: %w", err)
	}
	if err := s.file.Sync(); err != nil {
		rollback()
		return fmt.Errorf("상태 배치 동기화 실패: %w", err)
	}
	for _, record := range records {
		s.lines++
		s.apply(record)
	}
	if err := s.pruneLocked(); err != nil {
		return err
	}
	return nil
}

type ownershipClaim struct {
	Requester   string
	Project     string
	Environment string
	Group       string
	App         string
}

func claimOf(request deploymentRequest) ownershipClaim {
	return ownershipClaim{
		Requester: request.Requester, Project: request.Profile.App.Project,
		Environment: request.Profile.App.Environment, Group: request.Profile.App.Group,
		App: request.Profile.App.Name,
	}
}

// failedRequestMayOwnResources는 실패가 target branch 반영 뒤에 일어났는지 판정한다.
// 새 레코드는 GitCommitted/FailedFromState를 명시한다. 예전 레코드는 그 정보가 없으므로
// 실제 Git 리소스를 quota 밖으로 빼는 것보다 보수적으로 살아 있다고 보는 편이 안전하다.
func failedRequestMayOwnResources(request deploymentRequest) bool {
	if request.State != stateFailed {
		return request.State != stateDeleted
	}
	if request.DeletionRequested || request.GitCommitted {
		return true
	}
	switch request.FailedFromState {
	case stateMerged, stateBuilding, stateDeploying, stateDeployed,
		stateStopping, stateStopped, stateStarting, stateDeleting:
		return true
	case stateReceived, statePRCreating, statePROpen:
		return false
	case "":
		// 구버전 로그에는 실패 단계가 없다. 소유권과 quota를 fail-closed로 유지한다.
		return true
	default:
		return true
	}
}

// liveProfiles는 requester가 현재 점유한 앱 identity별 유효 프로필을 반환한다.
// 실패한 재배포는 이전 deployed 앱을 없애지 않으므로 더 오래된 성공 레코드를 계속 본다.
func (s *store) liveProfiles(requester string) []normalizedProfile {
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := make(map[string]struct{})
	profiles := make([]normalizedProfile, 0)
	for i := len(s.ordered) - 1; i >= 0; i-- {
		request, ok := s.byID[s.ordered[i]]
		if !ok || request.Requester != requester {
			continue
		}
		identity := appIdentity(request.Profile)
		if _, decided := seen[identity]; decided {
			continue
		}
		switch request.State {
		case stateFailed:
			if !failedRequestMayOwnResources(request) {
				// merge 전 실패라면 앞선 성공 배포가 아직 실제 desired state다.
				continue
			}
			seen[identity] = struct{}{}
			profiles = append(profiles, request.Profile)
		case stateDeleted:
			seen[identity] = struct{}{}
			continue
		default:
			seen[identity] = struct{}{}
			profiles = append(profiles, request.Profile)
		}
	}
	return profiles
}

// liveProfile은 같은 규칙으로 논리 앱 하나의 현재 desired profile을 찾는다. PVC 같은
// 파괴적 필드 변경을 새 PR에 넣기 전에 기존 배포와 비교하는 데 사용한다.
func (s *store) liveProfile(requester string, candidate normalizedProfile) (normalizedProfile, bool) {
	for _, profile := range s.liveProfiles(requester) {
		if sameAppIdentity(profile, candidate) {
			return profile, true
		}
	}
	return normalizedProfile{}, false
}

// appClaim은 project/environment/group/app이 모두 같은 배포 정체성만 찾는다.
// 그룹별 GitOps/OpenBao 경로가 분리되므로 서로 다른 그룹의 api/redis 이름은 재사용한다.
func (s *store) appClaim(project, environment, group, app string) (ownershipClaim, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := len(s.ordered) - 1; i >= 0; i-- {
		request, ok := s.byID[s.ordered[i]]
		if !ok || request.Profile.App.Project != project || request.Profile.App.Environment != environment ||
			request.Profile.App.Group != group || request.Profile.App.Name != app {
			continue
		}
		if request.State == stateDeleted {
			return ownershipClaim{}, false
		}
		return claimOf(request), true
	}
	return ownershipClaim{}, false
}

// artifactConflictLocked는 각 논리 identity의 최신 상태를 본 뒤 같은 물리 대상을
// 점유한 호환되지 않는 요청을 찾는다. 패치 전 로그에 충돌한 identity가
// 여럿 있으면 가장 최신 하나만 보지 않고 하나라도 다르면 fail-close한다.
func (s *store) artifactConflictLocked(incoming deploymentRequest) (deploymentRequest, bool) {
	artifact := artifactIdentity(incoming.Profile)
	seenApps := make(map[string]struct{})
	for i := len(s.ordered) - 1; i >= 0; i-- {
		request, ok := s.byID[s.ordered[i]]
		if !ok || artifactIdentity(request.Profile) != artifact {
			continue
		}
		identity := appIdentity(request.Profile)
		if _, decided := seenApps[identity]; decided {
			continue
		}
		seenApps[identity] = struct{}{}
		if request.State != stateDeleted &&
			(request.DeletionRequested || request.State == stateDeleting ||
				request.State == stateStopped || lifecycleTransition(request.State) || lifecycleFailure(request) ||
				request.Requester != incoming.Requester || !sameAppIdentity(request.Profile, incoming.Profile)) {
			return request, true
		}
	}
	return deploymentRequest{}, false
}

// hostClaim은 Gateway 전체에서 같은 hostname을 쓰는 살아 있는 앱 identity를 찾는다.
// `<app>-<group>` 조합은 다른 하이픈 조합이나 같은 이름의 단일 앱과 충돌할 수 있으므로
// app/path ownership과 별도로 전역 claim이 필요하다.
func (s *store) hostClaim(host string) (deploymentRequest, bool) {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return deploymentRequest{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hostClaimLocked(host)
}

func (s *store) hostClaimLocked(host string) (deploymentRequest, bool) {
	seen := make(map[string]struct{})
	for i := len(s.ordered) - 1; i >= 0; i-- {
		request, ok := s.byID[s.ordered[i]]
		if !ok {
			continue
		}
		identity := appIdentity(request.Profile)
		if _, decided := seen[identity]; decided {
			continue
		}
		pendingBeforeCommit := request.State == stateReceived || request.State == statePRCreating ||
			request.State == statePROpen ||
			(request.State == stateFailed && !failedRequestMayOwnResources(request))
		if pendingBeforeCommit {
			// 새 host는 요청 접수 순간 예약하지만, 아직 Git에 반영되지 않았으므로 이전
			// deployed profile의 host claim도 계속 찾는다(external -> internal 재배포).
			if strings.EqualFold(request.Profile.Exposure.Host, host) {
				return request, true
			}
			continue
		}
		seen[identity] = struct{}{}
		if request.State == stateDeleted {
			continue
		}
		if strings.EqualFold(request.Profile.Exposure.Host, host) {
			return request, true
		}
	}
	return deploymentRequest{}, false
}

// groupClaim은 Namespace 이름을 전역 선점한 사용자/프로젝트/환경을 찾는다. AppGroup
// 이름이 같으면 Kubernetes Namespace도 같으므로 프로젝트나 환경을 바꿔 재사용할 수 없다.
func (s *store) groupClaim(group string) (ownershipClaim, bool) {
	if group == "" {
		return ownershipClaim{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	seenApps := make(map[string]struct{})
	for i := len(s.ordered) - 1; i >= 0; i-- {
		request, ok := s.byID[s.ordered[i]]
		if !ok || request.Profile.App.Group != group {
			continue
		}
		identity := request.Profile.App.Project + "\x00" + request.Profile.App.Environment + "\x00" + request.Profile.App.Name
		if _, seen := seenApps[identity]; seen {
			continue
		}
		seenApps[identity] = struct{}{}
		if request.State != stateDeleted {
			return claimOf(request), true
		}
	}
	return ownershipClaim{}, false
}

// groupDeletionInProgress는 삭제가 완전히 끝날 때까지 같은 Namespace에 새 앱을 받지 않는다.
// 삭제 worker의 "마지막 앱" 판정 뒤 새 서비스가 들어오면 살아 있는 Namespace와 shared
// registry role을 지우는 TOCTOU가 생기므로, handler가 appMu를 잡은 상태에서 사용한다.
func (s *store) groupDeletionInProgress(group string) bool {
	if group == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range s.ordered {
		request, ok := s.byID[id]
		if !ok || request.Profile.App.Group != group || !request.DeletionRequested {
			continue
		}
		if request.State != stateDeleted {
			return true
		}
	}
	return false
}

// groupHasOtherApps는 지정한 요청 말고 같은 AppGroup에 살아 있는 앱이 더 있는지 본다.
// 마지막 앱을 지울 때만 Namespace bootstrap까지 함께 정리하기 위한 판단이다.
// 앱 이름 기준으로 최신 상태 하나만 세므로, 같은 앱을 여러 번 신청한 이력은 중복되지 않는다.
func (s *store) groupHasOtherAppsOwned(group, project, environment, requester, exceptApp string) bool {
	if group == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := make(map[string]struct{})
	for i := len(s.ordered) - 1; i >= 0; i-- {
		request, ok := s.byID[s.ordered[i]]
		if !ok {
			continue
		}
		profile := request.Profile
		if profile.App.Group != group {
			continue
		}
		// except는 지금 지우는 정확한 identity 하나뿐이다. 같은 Namespace 이름 아래
		// 소유자/프로젝트/환경이 어긋난 레코드가 있으면 invariant 손상 상태이므로
		// 무시하고 Namespace를 지우지 말고 "다른 앱 있음"으로 fail-close 한다.
		if profile.App.Name == exceptApp && profile.App.Environment == environment &&
			(project == "" || profile.App.Project == project) &&
			(requester == "" || request.Requester == requester) {
			continue
		}
		identity := request.Requester + "\x00" + profile.App.Project + "\x00" +
			profile.App.Environment + "\x00" + profile.App.Name
		if _, counted := seen[identity]; counted {
			continue
		}
		seen[identity] = struct{}{}
		if request.State != stateDeleted {
			return true
		}
	}
	return false
}

// groupHasOtherApps는 기존 Forgejo 정리 호출부의 호환 wrapper다. 새 삭제 파이프라인은
// 소유권까지 받는 groupHasOtherAppsOwned를 사용한다.
func (s *store) groupHasOtherApps(group, environment, exceptApp string) bool {
	return s.groupHasOtherAppsOwned(group, "", environment, "", exceptApp)
}

func (s *store) update(request deploymentRequest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	request.UpdatedAt = time.Now().UTC()
	record := storeRecord{Kind: "update", Request: &request}
	if err := s.append(record); err != nil {
		return err
	}
	return s.pruneLocked()
}

// updateIfCurrent는 GET reconciliation처럼 외부 상태를 조회하는 동안 같은 요청이
// stop/start/delete로 전환됐을 때 오래된 snapshot이 새 상태를 덮지 않게 한다.
// UpdatedAt까지 비교해 PR·revision checkpoint만 바뀐 경쟁도 감지한다.
func (s *store) updateIfCurrent(expected, replacement deploymentRequest) (deploymentRequest, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current, ok := s.byID[expected.ID]
	if !ok || replacement.ID != expected.ID {
		return expected, false, nil
	}
	if current.State != expected.State || current.RuntimeGeneration != expected.RuntimeGeneration ||
		current.DeletionRequested != expected.DeletionRequested ||
		current.DesiredRuntimeState != expected.DesiredRuntimeState ||
		!current.UpdatedAt.Equal(expected.UpdatedAt) {
		return current, false, nil
	}
	replacement.UpdatedAt = time.Now().UTC()
	if err := s.append(storeRecord{Kind: "update", Request: &replacement}); err != nil {
		return current, false, err
	}
	if err := s.pruneLocked(); err != nil {
		return replacement, true, err
	}
	return replacement, true, nil
}

// beginDelete는 소유권·최신 요청·상태 확인과 deleting 전환을 한 잠금 안에서 처리한다.
// 검사와 갱신을 나누면 동시에 들어온 재배포가 다른 사용자의 앱을 지우는 TOCTOU가 생긴다.
// 두 번째 반환값은 새 삭제 작업을 queue에 넣어야 하는지를 뜻한다.
func (s *store) beginDelete(id, requester string) (deploymentRequest, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	request, ok := s.byID[id]
	if !ok || requester == "" || request.Requester != requester {
		return deploymentRequest{}, false, errDeleteNotFound
	}
	artifact := artifactIdentity(request.Profile)
	for i := len(s.ordered) - 1; i >= 0; i-- {
		candidate, found := s.byID[s.ordered[i]]
		if !found || artifactIdentity(candidate.Profile) != artifact {
			continue
		}
		if candidate.ID != request.ID {
			return deploymentRequest{}, false, errDeleteStale
		}
		break
	}

	switch request.State {
	case stateDeleted:
		return request, false, nil
	case stateDeleting:
		return request, false, nil
	case stateDeployed, stateStopped, stateFailed:
		request.State = stateDeleting
		request.FailedFromState = ""
		request.Message = "GitOps와 Kubernetes Namespace에서 애플리케이션을 삭제하는 중입니다."
		if !request.DeletionRequested {
			request.PullRequest = nil
			request.GroupCleanupDecided = false
			request.GroupCleanupPlanned = false
		}
		request.DeletionRequested = true
		request.UpdatedAt = time.Now().UTC()
		if err := s.append(storeRecord{Kind: "update", Request: &request}); err != nil {
			return deploymentRequest{}, false, err
		}
		if err := s.pruneLocked(); err != nil {
			return deploymentRequest{}, false, err
		}
		return request, true, nil
	default:
		return deploymentRequest{}, false, errDeleteInProgress
	}
}

func (s *store) get(id string) (deploymentRequest, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	request, ok := s.byID[id]
	return request, ok
}

// findByIdempotency는 저장된 요청과 그때의 본문 지문을 함께 돌려준다.
func (s *store) findByIdempotency(key string) (deploymentRequest, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.byIdem[key]
	if !ok {
		return deploymentRequest{}, "", false
	}
	request, ok := s.byID[entry.requestID]
	if !ok {
		return deploymentRequest{}, "", false
	}
	return request, entry.bodyHash, true
}

// list는 최신순으로 최대 limit건을 돌려준다. 생성 순서 색인을 역순으로 훑기 때문에
// 보관 건수가 늘어도 비용은 limit에만 비례한다. requester가 비어 있지 않으면 해당
// 신청자의 요청만 남긴다. 포털의 "내 신청" 화면이 남의 요청을 보지 않게 하는 장치다.
func (s *store) list(limit int, requester string) []deploymentRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	if limit <= 0 || limit > len(s.ordered) {
		limit = len(s.ordered)
	}
	requests := make([]deploymentRequest, 0, limit)
	for i := len(s.ordered) - 1; i >= 0 && len(requests) < limit; i-- {
		request, ok := s.byID[s.ordered[i]]
		if !ok {
			continue
		}
		if requester != "" && request.Requester != requester {
			continue
		}
		requests = append(requests, request)
	}
	return requests
}

// unfinishedState는 worker가 재시작 직후 이어야 하는 상태인지 알려준다. pr-open은
// 별도 승인 watcher가 보안/정책 증거를 확인하므로 여기서 무조건 재개하지 않는다.
func unfinishedState(state string) bool {
	switch state {
	case stateReceived, statePRCreating, stateMerged, stateBuilding, stateDeploying,
		stateStopping, stateStarting, stateDeleting:
		return true
	case statePROpen:
		return false
	}
	return false
}

func unfinishedRequest(request deploymentRequest) bool {
	if request.SecretWritePending {
		return false
	}
	// 삭제 cleanup 실패는 Git merge 뒤 Namespace/OpenBao 정리가 남아 있을 수 있다.
	// 일반 failed와 달리 재시작 때 반드시 delete 파이프라인으로 다시 보낸다.
	return unfinishedState(request.State) ||
		(request.State == stateFailed &&
			(request.DeletionRequested || lifecycleTransition(request.FailedFromState)))
}

// resumable은 재시작 후 남은 단계를 이어가야 하는 요청을 생성 순서로 돌려준다.
func (s *store) resumable() []deploymentRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	pending := make([]deploymentRequest, 0)
	for _, id := range s.ordered {
		request, ok := s.byID[id]
		if !ok {
			continue
		}
		if unfinishedRequest(request) {
			pending = append(pending, request)
		}
	}
	return pending
}

func (s *store) close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.file == nil {
		return nil
	}
	return s.file.Close()
}
