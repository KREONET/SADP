package main

// Portal에 등록된 Forgejo source branch를 주기적으로 확인해 새 commit을 별도 배포
// 요청으로 만든다. source 저장소에 webhook 권한이나 callback Secret을 추가하지 않고,
// 기존 read token으로 branch head만 읽는다. 실제 배포 변경은 언제나 GitOps PR을 지난다.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"
	"time"
)

func sourceUpdateIdempotencyKey(request deploymentRequest, commit string) string {
	sum := sha256.Sum256([]byte(appIdentity(request.Profile) + "\x00" +
		request.Profile.Source.Repository + "\x00" + request.Profile.Source.Revision + "\x00" + commit))
	return "source-update:" + hex.EncodeToString(sum[:])
}

// trackedSourceCommit은 GitOps와 같은 Forgejo에 있는 branch만 추적한다. 별도 허용 host는
// clone 자격증명 경계일 뿐 API 좌표와 token이 없으므로 기존처럼 one-shot build로 둔다.
func (f *forgejoClient) trackedSourceCommit(
	ctx context.Context, repositoryURL, branch string,
) (string, bool, error) {
	candidate, candidateErr := url.Parse(strings.TrimSpace(repositoryURL))
	base, baseErr := url.Parse(f.config.BaseURL)
	if candidateErr != nil || baseErr != nil || candidate.Host == "" || base.Host == "" ||
		!strings.EqualFold(candidate.Host, base.Host) {
		return "", false, nil
	}
	coordinates, err := parseSourceRepositoryURL(f.config, repositoryURL)
	if err != nil {
		return "", true, err
	}
	commit, err := f.sourceBranchRevision(ctx, coordinates.Owner, coordinates.Repo, branch)
	if err != nil {
		return "", true, err
	}
	commit = strings.ToLower(strings.TrimSpace(commit))
	if !gitCommitPattern.MatchString(commit) {
		return "", true, fmt.Errorf("Forgejo source branch commit 형식이 올바르지 않습니다")
	}
	return commit, true, nil
}

// latestSourceRequests는 앱 identity별 최신 레코드만 돌려준다. 진행 중 요청 뒤의 오래된
// deployed 레코드를 다시 감시하면 같은 commit PR을 병렬로 만들 수 있어 최신 상태가 경계다.
func (s *store) latestSourceRequests() []deploymentRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := make(map[string]struct{})
	requests := make([]deploymentRequest, 0)
	for index := len(s.ordered) - 1; index >= 0; index-- {
		request, ok := s.byID[s.ordered[index]]
		if !ok {
			continue
		}
		identity := appIdentity(request.Profile)
		if _, decided := seen[identity]; decided {
			continue
		}
		seen[identity] = struct{}{}
		if request.Profile.Source.Image != "" || request.Profile.Source.Repository == "" ||
			request.Profile.Source.Revision == "" || request.DeletionRequested || request.State == stateDeleted {
			continue
		}
		requests = append(requests, request)
	}
	return requests
}

func (s *store) latestAppRequest(profile normalizedProfile) (deploymentRequest, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	identity := appIdentity(profile)
	for index := len(s.ordered) - 1; index >= 0; index-- {
		request, ok := s.byID[s.ordered[index]]
		if ok && appIdentity(request.Profile) == identity {
			return request, true
		}
	}
	return deploymentRequest{}, false
}

func (api *apiServer) watchSourceUpdates(ctx context.Context) {
	interval := time.Duration(sourcePollIntervalSeconds) * time.Second
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			api.pollSourceUpdates(ctx)
		}
	}
}

func (api *apiServer) pollSourceUpdates(ctx context.Context) {
	if !api.submissionEnabled() {
		return
	}
	for _, candidate := range api.store.latestSourceRequests() {
		if ctx.Err() != nil {
			return
		}
		// queue 포화 직전에 durable 기록만 끝난 경우 다음 poll이 같은 ID를 다시 깨운다.
		if candidate.SourceUpdate && candidate.State == stateReceived {
			if err := api.forgejo.enqueue(candidate.ID); err != nil {
				api.forgejo.logger.Printf("source update 요청 %s queue 재시도 실패: %v", candidate.ID, err)
			}
			continue
		}
		// 실행 중 배포를 덮지 않는다. source update가 실패한 뒤 branch가 더 전진한 경우만
		// 새 commit으로 복구하고, 같은 실패 commit은 무한 재시도하지 않는다.
		if candidate.State != stateDeployed && !(candidate.SourceUpdate && candidate.State == stateFailed) {
			continue
		}
		commit, tracked, err := api.forgejo.trackedSourceCommit(ctx,
			candidate.Profile.Source.Repository, candidate.Profile.Source.Revision)
		if err != nil {
			api.forgejo.logger.Printf("앱 %s source branch 확인 실패: %v", candidate.Profile.App.Name, err)
			continue
		}
		if !tracked || commit == candidate.Profile.Source.Commit {
			continue
		}
		if err := api.createSourceUpdate(candidate, commit); err != nil {
			api.forgejo.logger.Printf("앱 %s source update 생성 실패: %v", candidate.Profile.App.Name, err)
		}
	}
}

func (api *apiServer) createSourceUpdate(expected deploymentRequest, commit string) error {
	api.appMu.Lock()
	defer api.appMu.Unlock()

	current, ok := api.store.latestAppRequest(expected.Profile)
	if !ok || current.ID != expected.ID || !current.UpdatedAt.Equal(expected.UpdatedAt) {
		return nil
	}
	if current.State != stateDeployed && !(current.SourceUpdate && current.State == stateFailed) {
		return nil
	}
	if current.Profile.Source.Commit == commit {
		return nil
	}
	key := sourceUpdateIdempotencyKey(current, commit)
	if existing, _, found := api.store.findByIdempotency(key); found {
		if existing.State == stateReceived {
			return api.forgejo.enqueue(existing.ID)
		}
		return nil
	}
	id, err := newRequestID()
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	request := deploymentRequest{
		ID: id, State: stateReceived, CreatedAt: now, UpdatedAt: now,
		Requester: current.Requester, Profile: current.Profile, Generated: current.Generated,
		SourceUpdate: true,
	}
	request.Profile.Source.Commit = commit
	// 이전 immutable image는 현재 앱을 설명할 뿐 새 build 결과가 아니다. pre-PR build가
	// 성공한 뒤에만 새 좌표를 채워 PR에 존재하는 tag만 기록한다.
	request.Generated.Image = ""
	bodyHash := hashBody([]byte(appIdentity(request.Profile) + "\x00" + commit))
	if err := api.store.create(request, key, bodyHash); err != nil {
		return err
	}
	api.forgejo.logger.Printf("앱 %s source commit 변경 감지: %s", request.Profile.App.Name, commit)
	return api.forgejo.enqueue(request.ID)
}
