package main

import (
	"context"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGitContextPinsDetectedSourceCommit(t *testing.T) {
	request := renderedRequest(t, "public")
	request.Profile.Source.Repository = "https://forgejo.example/team/demo.git"
	request.Profile.Source.Revision = "main"
	request.Profile.Source.Commit = strings.Repeat("a", 40)

	want := "git://forgejo.example/team/demo.git#refs/heads/main#" + strings.Repeat("a", 40)
	if got := gitContext(request); got != want {
		t.Fatalf("git context=%q, want %q", got, want)
	}
	if tag := imageTag(request); !strings.HasPrefix(tag, strings.Repeat("a", 40)+"-") {
		t.Fatalf("image tag가 source commit을 포함하지 않음: %s", tag)
	}
}

func TestSourcePollCreatesOnePinnedUpdateRequestAndQueuesIt(t *testing.T) {
	oldCommit := strings.Repeat("a", 40)
	newCommit := strings.Repeat("b", 40)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/repos/team/demo/branches/main" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"commit":{"id":"` + newCommit + `"}}`))
	}))
	t.Cleanup(server.Close)

	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = requestStore.close() })
	config := forgejoConfig{
		BaseURL: server.URL, Owner: "platform", Repo: "gitops", Token: "test-token",
		TargetBranch: "main", BranchPrefix: "portal",
	}
	client := newForgejoClient(config, requestStore, log.New(io.Discard, "", 0))
	client.client = server.Client()
	api := &apiServer{store: requestStore, forgejo: client}

	now := time.Now().UTC()
	deployed := deploymentRequest{
		ID: "deployed-source", State: stateDeployed, CreatedAt: now, UpdatedAt: now,
		Requester: "owner", Generated: generatedPlan{Image: "registry.example/demo:old"},
	}
	deployed.Profile.App.Name = "demo"
	deployed.Profile.App.Project = "research"
	deployed.Profile.App.Environment = "prod"
	deployed.Profile.Source.Repository = server.URL + "/team/demo.git"
	deployed.Profile.Source.Revision = "main"
	deployed.Profile.Source.Commit = oldCommit
	deployed.Profile.Source.Dockerfile = "Dockerfile"
	if err := requestStore.create(deployed, "", ""); err != nil {
		t.Fatal(err)
	}

	api.pollSourceUpdates(context.Background())
	latest, found := requestStore.latestAppRequest(deployed.Profile)
	if !found || latest.ID == deployed.ID || latest.State != stateReceived || !latest.SourceUpdate {
		t.Fatalf("source update 요청이 만들어지지 않음: %+v", latest)
	}
	if latest.Profile.Source.Commit != newCommit || latest.Generated.Image != "" {
		t.Fatalf("새 commit 고정 또는 사전 build 경계 불일치: %+v", latest)
	}
	if got := len(client.queue); got != 1 {
		t.Fatalf("source update queue 길이=%d, want 1", got)
	}

	// worker가 아직 가져가지 않은 동안 다음 poll이 와도 같은 commit의 요청/queue를
	// 하나 더 만들면 안 된다.
	api.pollSourceUpdates(context.Background())
	if got := len(requestStore.list(10, "")); got != 2 {
		t.Fatalf("같은 commit source update가 중복 저장됨: %d", got)
	}
	if got := len(client.queue); got != 1 {
		t.Fatalf("같은 요청이 queue에 중복됨: %d", got)
	}
}

func TestSourcePollDoesNotCreateRequestForCurrentCommit(t *testing.T) {
	commit := strings.Repeat("c", 40)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"commit":{"id":"` + commit + `"}}`))
	}))
	t.Cleanup(server.Close)
	requestStore, err := newStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = requestStore.close() })
	client := newForgejoClient(forgejoConfig{
		BaseURL: server.URL, Owner: "platform", Repo: "gitops", Token: "test-token",
		TargetBranch: "main", BranchPrefix: "portal",
	}, requestStore, log.New(io.Discard, "", 0))
	client.client = server.Client()
	api := &apiServer{store: requestStore, forgejo: client}
	now := time.Now().UTC()
	request := deploymentRequest{ID: "same", State: stateDeployed, CreatedAt: now, UpdatedAt: now}
	request.Profile.App.Name = "demo"
	request.Profile.App.Project = "research"
	request.Profile.App.Environment = "prod"
	request.Profile.Source.Repository = server.URL + "/team/demo.git"
	request.Profile.Source.Revision = "main"
	request.Profile.Source.Commit = commit
	if err := requestStore.create(request, "", ""); err != nil {
		t.Fatal(err)
	}

	api.pollSourceUpdates(context.Background())
	if got := len(requestStore.list(10, "")); got != 1 {
		t.Fatalf("현재 commit인데 source update가 생성됨: %d", got)
	}
}
