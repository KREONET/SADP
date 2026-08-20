package main

// 저장소는 재시작 후 상태 복원과 Idempotency-Key 재요청이 핵심이므로 그 두 가지와
// 보존 윈도우가 미완료 요청을 버리지 않는지를 검증한다.

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func sampleRequest(id, state string) deploymentRequest {
	request := deploymentRequest{
		ID:        id,
		State:     state,
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
		Requester: "tester@example.invalid",
	}
	request.Profile.App.Name = id
	return request
}

func TestStoreReloadsAfterRestart(t *testing.T) {
	dir := t.TempDir()
	first, err := newStore(dir)
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	if err := first.create(sampleRequest("req-1", stateReceived), "key-1", "hash-1"); err != nil {
		t.Fatalf("create: %v", err)
	}
	updated := sampleRequest("req-1", statePROpen)
	updated.PullRequest = &pullRequestRef{Number: 7, URL: "https://forgejo.example.invalid/o/r/pulls/7", State: "open"}
	if err := first.update(updated); err != nil {
		t.Fatalf("update: %v", err)
	}
	if err := first.close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	second, err := newStore(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = second.close() }()

	restored, ok := second.get("req-1")
	if !ok {
		t.Fatal("재시작 후 요청이 복원되지 않았습니다")
	}
	if restored.State != statePROpen {
		t.Fatalf("state=%q, 최신 상태가 반영되지 않았습니다", restored.State)
	}
	if restored.PullRequest == nil || restored.PullRequest.Number != 7 {
		t.Fatalf("pullRequest=%+v, PR 정보가 유실되었습니다", restored.PullRequest)
	}
	if _, hash, found := second.findByIdempotency("key-1"); !found || hash != "hash-1" {
		t.Fatalf("found=%v hash=%q, Idempotency 색인이 복원되지 않았습니다", found, hash)
	}
}

func TestStoreBackfillsInternalAddressForLegacyRecord(t *testing.T) {
	dir := t.TempDir()
	first, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	legacy := sampleRequest("api", stateDeployed)
	legacy.Profile.App.Group = "mobility"
	legacy.Profile.Service.Port = 8080
	// 구버전 레코드는 enabled/internalAddress가 없고 port만으로 Service를 표현했다.
	if err := first.create(legacy, "", ""); err != nil {
		t.Fatal(err)
	}
	if err := first.close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = reopened.close() }()
	restored, ok := reopened.get(legacy.ID)
	if !ok {
		t.Fatal("구버전 요청을 복원하지 못함")
	}
	if want := "api." + groupNamespace("mobility") + ".svc:8080"; restored.Profile.Service.InternalAddress != want {
		t.Fatalf("복원한 내부 Service DNS=%q, want %q", restored.Profile.Service.InternalAddress, want)
	}
}

func TestStoreIdempotencyDistinguishesBody(t *testing.T) {
	store, err := newStore(t.TempDir())
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	defer func() { _ = store.close() }()

	if err := store.create(sampleRequest("req-a", stateReceived), "same-key", "hash-a"); err != nil {
		t.Fatalf("create: %v", err)
	}
	found, hash, ok := store.findByIdempotency("same-key")
	if !ok || found.ID != "req-a" {
		t.Fatalf("재요청이 같은 요청으로 이어지지 않았습니다: %+v", found)
	}
	if hash == "hash-b" {
		t.Fatal("서로 다른 본문이 같은 지문으로 취급되었습니다")
	}
	if _, _, ok := store.findByIdempotency("unknown-key"); ok {
		t.Fatal("등록되지 않은 키가 조회되었습니다")
	}
}

func TestStoreBatchPersistsAllRequestsAndDerivedKeys(t *testing.T) {
	dir := t.TempDir()
	requestStore, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	first := sampleRequest("frontend", stateReceived)
	second := sampleRequest("api", stateReceived)
	records := []storeRecord{
		{Kind: "create", IdempotencyKey: "group:key:frontend", BodyHash: "hash-frontend", Request: &first},
		{Kind: "create", IdempotencyKey: "group:key:api", BodyHash: "hash-api", Request: &second},
	}
	if err := requestStore.createBatch(records); err != nil {
		t.Fatal(err)
	}
	if err := requestStore.close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = reopened.close() }()
	for key, wantID := range map[string]string{"group:key:frontend": "frontend", "group:key:api": "api"} {
		request, _, found := reopened.findByIdempotency(key)
		if !found || request.ID != wantID {
			t.Fatalf("key=%s request=%+v found=%t", key, request, found)
		}
	}
}

func TestStoreClaimsScopeAppsByGroupAndGroupsGlobally(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	request := sampleRequest("req-api", stateDeployed)
	request.Profile.App.Name = "api"
	request.Profile.App.Project = "research"
	request.Profile.App.Environment = "beta"
	request.Profile.App.Group = "mobility"
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, found := requestStore.appClaim("research", "beta", "mobility", "api"); !found {
		t.Fatal("동일 그룹 앱 claim을 찾지 못함")
	}
	if _, found := requestStore.appClaim("research", "beta", "other-stack", "api"); found {
		t.Fatal("다른 그룹의 같은 서비스 이름을 전역 충돌로 취급함")
	}
	claim, found := requestStore.groupClaim("mobility")
	if !found || claim.Requester != request.Requester || claim.Project != "research" || claim.Environment != "beta" {
		t.Fatalf("AppGroup claim 불일치: %+v found=%t", claim, found)
	}
}

func TestStoreListIsNewestFirstAndBounded(t *testing.T) {
	store, err := newStore(t.TempDir())
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	defer func() { _ = store.close() }()

	for _, id := range []string{"old", "middle", "newest"} {
		if err := store.create(sampleRequest(id, statePROpen), "", ""); err != nil {
			t.Fatalf("create %s: %v", id, err)
		}
	}
	listed := store.list(2, "")
	if len(listed) != 2 {
		t.Fatalf("len=%d, limit이 지켜지지 않았습니다", len(listed))
	}
	if listed[0].ID != "newest" || listed[1].ID != "middle" {
		t.Fatalf("order=%s,%s 최신순이 아닙니다", listed[0].ID, listed[1].ID)
	}
	if all := store.list(0, ""); len(all) != 3 {
		t.Fatalf("len=%d, limit 0은 전체를 돌려줘야 합니다", len(all))
	}
}

func TestStoreListFiltersByRequester(t *testing.T) {
	store, err := newStore(t.TempDir())
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	defer func() { _ = store.close() }()

	mine := sampleRequest("mine", statePROpen)
	other := sampleRequest("other", statePROpen)
	other.Requester = "someone-else@example.invalid"
	for _, request := range []deploymentRequest{mine, other} {
		if err := store.create(request, "", ""); err != nil {
			t.Fatalf("create %s: %v", request.ID, err)
		}
	}

	listed := store.list(0, "tester@example.invalid")
	if len(listed) != 1 || listed[0].ID != "mine" {
		t.Fatalf("listed=%v, 신청자 본인 요청만 남아야 합니다", listed)
	}
	if none := store.list(0, "nobody@example.invalid"); len(none) != 0 {
		t.Fatalf("len=%d, 신청 이력이 없는 사용자에게는 빈 목록이어야 합니다", len(none))
	}
	if all := store.list(0, ""); len(all) != 2 {
		t.Fatalf("len=%d, requester가 비면 전체를 돌려줘야 합니다", len(all))
	}
}

func TestStoreRetentionKeepsUnfinishedRequests(t *testing.T) {
	store, err := newStore(t.TempDir())
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	defer func() { _ = store.close() }()

	// 가장 오래된 요청만 미완료로 두고 보존 한도를 넘긴다.
	store.mu.Lock()
	store.apply(storeRecord{Kind: "create", Request: ptr(sampleRequest("unfinished", statePRCreating))})
	for i := 0; i < maxStoredRequests+5; i++ {
		store.apply(storeRecord{Kind: "create", Request: ptr(sampleRequest("done-"+strconv.Itoa(i), stateDeleted))})
	}
	kept := store.retained()
	store.mu.Unlock()

	if len(kept) > maxStoredRequests+1 {
		t.Fatalf("len=%d, 보존 윈도우가 지켜지지 않았습니다", len(kept))
	}
	if kept[0] != "unfinished" {
		t.Fatalf("kept[0]=%q, 미완료 요청이 밀려났습니다", kept[0])
	}
	if kept[len(kept)-1] != "done-"+strconv.Itoa(maxStoredRequests+4) {
		t.Fatalf("kept last=%q, 최신 요청이 보존되지 않았습니다", kept[len(kept)-1])
	}
}

func TestStoreRetentionKeepsLatestActiveOwnershipClaim(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	active := sampleRequest("active-record", stateDeployed)
	active.Profile.App.Name = "api"
	active.Profile.App.Project = "research"
	active.Profile.App.Environment = "beta"
	active.Profile.App.Group = "mobility"

	requestStore.mu.Lock()
	requestStore.apply(storeRecord{Kind: "create", Request: &active})
	for i := 0; i < maxStoredRequests+5; i++ {
		history := sampleRequest("deleted-"+strconv.Itoa(i), stateDeleted)
		requestStore.apply(storeRecord{Kind: "create", Request: &history})
	}
	kept := requestStore.retained()
	requestStore.mu.Unlock()
	found := false
	for _, id := range kept {
		if id == active.ID {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("오래된 active ownership 레코드가 보존 윈도우에서 밀려났다")
	}
}

func TestStoreRetentionKeepsFailedClaimAndPreviousLiveProfile(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	deployed := sampleRequest("deployed", stateDeployed)
	deployed.Profile.App.Name = "api"
	deployed.Profile.App.Project = "research"
	deployed.Profile.App.Environment = "beta"
	failed := deployed
	failed.ID = "failed-redeploy"
	failed.State = stateFailed

	requestStore.mu.Lock()
	requestStore.apply(storeRecord{Kind: "create", Request: &deployed})
	requestStore.apply(storeRecord{Kind: "create", Request: &failed})
	for i := 0; i < maxStoredRequests+5; i++ {
		history := sampleRequest("history-"+strconv.Itoa(i), stateDeleted)
		requestStore.apply(storeRecord{Kind: "create", Request: &history})
	}
	kept := requestStore.retained()
	requestStore.mu.Unlock()
	keptSet := make(map[string]bool, len(kept))
	for _, id := range kept {
		keptSet[id] = true
	}
	if !keptSet[failed.ID] || !keptSet[deployed.ID] {
		t.Fatalf("failed claim과 이전 live profile을 함께 보존하지 않음: failed=%t deployed=%t",
			keptSet[failed.ID], keptSet[deployed.ID])
	}
}

func TestStoreCompactionKeepsAppendableFile(t *testing.T) {
	dir := t.TempDir()
	store, err := newStore(dir)
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}

	if err := store.create(sampleRequest("survivor", statePROpen), "key-s", "hash-s"); err != nil {
		t.Fatalf("create: %v", err)
	}
	store.mu.Lock()
	compactErr := store.compact()
	store.mu.Unlock()
	if compactErr != nil {
		t.Fatalf("compact: %v", compactErr)
	}

	// 압축으로 파일이 교체된 뒤에도 기록이 실제 파일에 남아야 한다.
	if err := store.create(sampleRequest("after-compact", stateReceived), "key-c", "hash-c"); err != nil {
		t.Fatalf("compact 후 create: %v", err)
	}
	if err := store.close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	contents, err := os.ReadFile(filepath.Join(dir, storeFileName))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if len(contents) == 0 {
		t.Fatal("압축 후 기록이 유실되었습니다")
	}

	reopened, err := newStore(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.close() }()
	if _, ok := reopened.get("after-compact"); !ok {
		t.Fatal("압축 후 append한 요청이 재시작에서 사라졌습니다")
	}
	if _, ok := reopened.get("survivor"); !ok {
		t.Fatal("압축이 보존해야 할 요청을 지웠습니다")
	}
}

func TestStoreResumesFailedDeletionCleanup(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	request := sampleRequest("cleanup-failed", stateFailed)
	request.DeletionRequested = true
	request.FailedFromState = stateDeleting
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	resumable := requestStore.resumable()
	if len(resumable) != 1 || resumable[0].ID != request.ID {
		t.Fatalf("failed deletion이 재시작 복구 대상이 아님: %+v", resumable)
	}
}

func TestStoreHostClaimReleasesOnlyAfterDeleted(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	request := sampleRequest("host-owner", stateDeployed)
	request.Profile.App.Project = "research"
	request.Profile.App.Environment = "beta"
	request.Profile.Exposure.Host = "api-mobility.example.test"
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, claimed := requestStore.hostClaim(request.Profile.Exposure.Host); !claimed {
		t.Fatal("deployed external host claim이 없음")
	}
	request.State = stateDeleted
	if err := requestStore.update(request); err != nil {
		t.Fatal(err)
	}
	if _, claimed := requestStore.hostClaim(request.Profile.Exposure.Host); claimed {
		t.Fatal("deleted app의 external host claim이 해제되지 않음")
	}
}

func TestStoreAtomicallyRejectsDifferentIdentityWithSameHost(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()
	first := sampleRequest("first", stateDeployed)
	first.Profile.App.Project = "research"
	first.Profile.App.Environment = "beta"
	first.Profile.App.Group = "mobility"
	first.Profile.Exposure.Host = "api-mobility.example.test"
	if err := requestStore.create(first, "", ""); err != nil {
		t.Fatal(err)
	}
	second := sampleRequest("api-mobility", stateReceived)
	second.Profile.App.Project = "research"
	second.Profile.App.Environment = "beta"
	second.Profile.Exposure.Host = first.Profile.Exposure.Host
	if err := requestStore.create(second, "", ""); err == nil {
		t.Fatal("서로 다른 identity의 동일 host가 store 잠금 안에서 통과함")
	}
}

func TestStoreAtomicallyClaimsSingleArtifactAcrossProjects(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	first := sampleRequest("first-single", stateDeployed)
	first.Profile.App.Name = "api"
	first.Profile.App.Project = "research"
	first.Profile.App.Environment = "beta"
	if err := requestStore.create(first, "", ""); err != nil {
		t.Fatal(err)
	}

	// 같은 논리 identity의 재배포는 같은 사용자에게 허용한다.
	redeploy := first
	redeploy.ID = "same-identity-redeploy"
	redeploy.State = stateReceived
	if err := requestStore.create(redeploy, "", ""); err != nil {
		t.Fatalf("동일 identity 재배포가 거부됨: %v", err)
	}

	otherProject := first
	otherProject.ID = "other-project"
	otherProject.State = stateReceived
	otherProject.Profile.App.Project = "education"
	if err := requestStore.create(otherProject, "", ""); !errors.Is(err, errArtifactClaimed) {
		t.Fatalf("다른 project의 같은 단일 앱 대상이 errArtifactClaimed로 거부되지 않음: %v", err)
	}
	if _, found := requestStore.get(otherProject.ID); found {
		t.Fatal("충돌한 요청이 저장소에 부분 기록됨")
	}

	otherOwner := first
	otherOwner.ID = "other-owner"
	otherOwner.State = stateReceived
	otherOwner.Requester = "other@example.invalid"
	if err := requestStore.create(otherOwner, "", ""); !errors.Is(err, errArtifactClaimed) {
		t.Fatalf("다른 사용자의 동일 identity가 거부되지 않음: %v", err)
	}
}

func TestStoreReleasesArtifactOnlyAfterLatestIdentityIsDeleted(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	owner := sampleRequest("artifact-owner", stateDeployed)
	owner.Profile.App.Name = "worker"
	owner.Profile.App.Project = "research"
	owner.Profile.App.Environment = "beta"
	if err := requestStore.create(owner, "", ""); err != nil {
		t.Fatal(err)
	}
	owner.State = stateDeleted
	if err := requestStore.update(owner); err != nil {
		t.Fatal(err)
	}

	replacement := sampleRequest("replacement", stateReceived)
	replacement.Profile.App.Name = "worker"
	replacement.Profile.App.Project = "education"
	replacement.Profile.App.Environment = "beta"
	if err := requestStore.create(replacement, "", ""); err != nil {
		t.Fatalf("삭제 완료 후 물리 대상을 재사용하지 못함: %v", err)
	}
}

func TestStoreAllowsSameAppNameInDifferentGroups(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	first := sampleRequest("group-one-api", stateReceived)
	first.Profile.App.Name = "api"
	first.Profile.App.Project = "research"
	first.Profile.App.Environment = "beta"
	first.Profile.App.Group = "mobility"
	second := first
	second.ID = "group-two-api"
	second.Profile.App.Group = "weather"
	if err := requestStore.create(first, "", ""); err != nil {
		t.Fatal(err)
	}
	if err := requestStore.create(second, "", ""); err != nil {
		t.Fatalf("다른 AppGroup의 같은 앱 이름이 충돌함: %v", err)
	}
}

func TestStoreRejectsRedeployWhilePhysicalArtifactDeletionIsUnfinished(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	deleting := sampleRequest("deleting-api", stateDeleting)
	deleting.Profile.App.Name = "api"
	deleting.Profile.App.Project = "research"
	deleting.Profile.App.Environment = "beta"
	deleting.DeletionRequested = true
	if err := requestStore.create(deleting, "", ""); err != nil {
		t.Fatal(err)
	}
	redeploy := deleting
	redeploy.ID = "redeploy-during-delete"
	redeploy.State = stateReceived
	redeploy.DeletionRequested = false
	if err := requestStore.create(redeploy, "", ""); !errors.Is(err, errArtifactClaimed) {
		t.Fatalf("삭제 중인 물리 대상의 재배포가 거부되지 않음: %v", err)
	}
}

func TestStoreBatchArtifactConflictIsAllOrNothing(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	first := sampleRequest("batch-first", stateReceived)
	first.Profile.App.Name = "api"
	first.Profile.App.Project = "research"
	first.Profile.App.Environment = "beta"
	second := sampleRequest("batch-second", stateReceived)
	second.Profile.App.Name = "api"
	second.Profile.App.Project = "education"
	second.Profile.App.Environment = "beta"
	records := []storeRecord{
		{Kind: "create", Request: &first},
		{Kind: "create", Request: &second},
	}
	if err := requestStore.createBatch(records); !errors.Is(err, errArtifactClaimed) {
		t.Fatalf("배치 내 물리 대상 충돌이 거부되지 않음: %v", err)
	}
	if _, found := requestStore.get(first.ID); found {
		t.Fatal("실패한 배치의 첫 요청이 부분 저장됨")
	}
	if _, found := requestStore.get(second.ID); found {
		t.Fatal("실패한 배치의 둘째 요청이 부분 저장됨")
	}
}

func TestStoreBeginDeleteRejectsNewerPhysicalArtifactRequest(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	old := sampleRequest("legacy-project-a", stateDeployed)
	old.Profile.App.Name = "api"
	old.Profile.App.Project = "research"
	old.Profile.App.Environment = "beta"
	newer := old
	newer.ID = "legacy-project-b"
	newer.Profile.App.Project = "education"

	// 패치 전 로그에 논리 identity 충돌이 이미 있는 상태를 재현한다.
	requestStore.mu.Lock()
	requestStore.apply(storeRecord{Kind: "create", Request: &old})
	requestStore.apply(storeRecord{Kind: "create", Request: &newer})
	requestStore.mu.Unlock()

	if _, _, err := requestStore.beginDelete(old.ID, old.Requester); !errors.Is(err, errDeleteStale) {
		t.Fatalf("최신 물리 대상이 아닌 요청 삭제가 거부되지 않음: %v", err)
	}
}

func TestStoreLegacyCompatibleClaimCannotHideDifferentPhysicalOwner(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	legacyOwner := sampleRequest("legacy-other-project", stateDeployed)
	legacyOwner.Profile.App.Name = "api"
	legacyOwner.Profile.App.Project = "education"
	legacyOwner.Profile.App.Environment = "beta"
	currentOwner := sampleRequest("current-project", stateDeployed)
	currentOwner.Profile.App.Name = "api"
	currentOwner.Profile.App.Project = "research"
	currentOwner.Profile.App.Environment = "beta"
	requestStore.mu.Lock()
	requestStore.apply(storeRecord{Kind: "create", Request: &legacyOwner})
	requestStore.apply(storeRecord{Kind: "create", Request: &currentOwner})
	requestStore.mu.Unlock()

	redeploy := currentOwner
	redeploy.ID = "current-redeploy"
	redeploy.State = stateReceived
	if err := requestStore.create(redeploy, "", ""); !errors.Is(err, errArtifactClaimed) {
		t.Fatalf("최신 호환 claim 뒤의 legacy 물리 소유자를 놓침: %v", err)
	}
}

func TestStoreCompactionRetainsPhysicalArtifactClaim(t *testing.T) {
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = requestStore.close() }()

	active := sampleRequest("old-physical-owner", stateDeployed)
	active.Profile.App.Name = "api"
	active.Profile.App.Project = "research"
	active.Profile.App.Environment = "beta"
	requestStore.mu.Lock()
	requestStore.apply(storeRecord{Kind: "create", Request: &active})
	for i := 0; i < maxStoredRequests+5; i++ {
		history := sampleRequest("physical-history-"+strconv.Itoa(i), stateDeleted)
		requestStore.apply(storeRecord{Kind: "create", Request: &history})
	}
	if err := requestStore.compact(); err != nil {
		requestStore.mu.Unlock()
		t.Fatal(err)
	}
	requestStore.mu.Unlock()

	competitor := sampleRequest("new-project-api", stateReceived)
	competitor.Profile.App.Name = "api"
	competitor.Profile.App.Project = "education"
	competitor.Profile.App.Environment = "beta"
	if err := requestStore.create(competitor, "", ""); !errors.Is(err, errArtifactClaimed) {
		t.Fatalf("압축 후 물리 claim이 유실됨: %v", err)
	}
}

func ptr(request deploymentRequest) *deploymentRequest {
	return &request
}
