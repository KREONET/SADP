package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseSourceRepositoryURLRestrictsForgejoOrigin(t *testing.T) {
	config := forgejoConfig{BaseURL: "https://forgejo.example"}
	coordinates, err := parseSourceRepositoryURL(config, "https://forgejo.example/research/demo.git")
	if err != nil {
		t.Fatalf("정상 저장소 URL 거부: %v", err)
	}
	if coordinates.Owner != "research" || coordinates.Repo != "demo" ||
		coordinates.URL != "https://forgejo.example/research/demo.git" {
		t.Fatalf("저장소 좌표 불일치: %+v", coordinates)
	}
	for _, raw := range []string{
		"https://other.example/research/demo.git",
		"https://token@forgejo.example/research/demo.git",
		"http://forgejo.example/research/demo.git",
		"https://forgejo.example/research/demo/src/branch/main",
	} {
		if _, err := parseSourceRepositoryURL(config, raw); err == nil {
			t.Fatalf("허용하면 안 되는 저장소 URL: %s", raw)
		}
	}
}

func TestSelectRepositoryInputPrefersUnambiguousRoot(t *testing.T) {
	entries := []forgejoTreeEntry{
		{Path: "compose.yaml", Type: "blob"},
		{Path: "charts/old/Chart.yaml", Type: "blob"},
	}
	kind, selected, err := selectRepositoryInput(entries)
	if err != nil || kind != "compose" || selected != "compose.yaml" {
		t.Fatalf("루트 Compose 자동 선택 실패: kind=%s path=%s err=%v", kind, selected, err)
	}
	entries = append(entries, forgejoTreeEntry{Path: "Chart.yaml", Type: "blob"})
	if _, _, err := selectRepositoryInput(entries); err == nil || !strings.Contains(err.Error(), "여러 개") {
		t.Fatalf("루트 후보 모호성을 허용함: %v", err)
	}
}

func TestImportRepositoryReadsComposeFromDefaultBranchCommit(t *testing.T) {
	compose := "services:\n  api:\n    image: registry.example/api:1.2.3\n    expose: [8080]\n"
	revision := strings.Repeat("a", 40)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/v1/repos/research/demo":
			_ = json.NewEncoder(w).Encode(map[string]string{"default_branch": "main"})
		case r.URL.Path == "/api/v1/repos/research/demo/branches/main":
			_, _ = io.WriteString(w, `{"commit":{"id":"`+revision+`"}}`)
		case r.URL.Path == "/api/v1/repos/research/demo/git/trees/"+revision:
			if r.URL.Query().Get("recursive") != "true" {
				t.Error("recursive tree 조회가 아님")
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"tree":      []map[string]any{{"path": "compose.yaml", "type": "blob", "mode": "100644", "size": len(compose)}},
				"truncated": false,
			})
		case r.URL.Path == "/api/v1/repos/research/demo/contents/compose.yaml":
			if r.URL.Query().Get("ref") != revision {
				t.Errorf("파일 ref=%q", r.URL.Query().Get("ref"))
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"sha": "blob123", "encoding": "base64", "content": base64.StdEncoding.EncodeToString([]byte(compose)),
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := newForgejoClient(forgejoConfig{BaseURL: server.URL, Token: "test"}, nil, log.New(io.Discard, "", 0))
	client.client = server.Client()
	imported, err := client.importRepository(t.Context(), server.URL+"/research/demo.git", "")
	if err != nil {
		t.Fatalf("Git Compose import 실패: %v", err)
	}
	if imported.Source.Type != "compose" || imported.Source.Revision != revision || imported.Source.Path != "compose.yaml" {
		t.Fatalf("source 불일치: %+v", imported.Source)
	}
	if len(imported.Parsed.Services) != 1 || imported.Parsed.Services[0].Name != "api" {
		t.Fatalf("서비스 import 불일치: %+v", imported.Parsed.Services)
	}
}

func TestImportHelmChartRendersWithBoundedHelmProcess(t *testing.T) {
	revision := strings.Repeat("b", 40)
	files := map[string]string{
		"Chart.yaml": "apiVersion: v2\nname: multi-app\nversion: 0.1.0\n",
		"templates/api.yaml": `apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-api
spec:
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels: {app: api}
    spec:
      containers:
        - name: api
          image: registry.example/api:1.2.3
          ports:
            - {name: http, containerPort: 8080}
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector: {app: api}
  ports:
    - {port: 80, targetPort: http}
`,
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		prefix := "/api/v1/repos/research/chart/contents/"
		if !strings.HasPrefix(r.URL.Path, prefix) || r.URL.Query().Get("ref") != revision {
			http.NotFound(w, r)
			return
		}
		filePath := strings.TrimPrefix(r.URL.Path, prefix)
		content, found := files[filePath]
		if !found {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{
			"sha": "blob", "encoding": "base64", "content": base64.StdEncoding.EncodeToString([]byte(content)),
		})
	}))
	defer server.Close()
	client := newForgejoClient(forgejoConfig{BaseURL: server.URL, Token: "test"}, nil, log.New(io.Discard, "", 0))
	client.client = server.Client()
	entries := make([]forgejoTreeEntry, 0, len(files))
	for filePath, content := range files {
		entries = append(entries, forgejoTreeEntry{Path: filePath, Type: "blob", Mode: "100644", Size: int64(len(content))})
	}
	parsed, err := client.importHelmChart(t.Context(), sourceRepositoryCoordinates{
		Owner: "research", Repo: "chart", URL: server.URL + "/research/chart.git",
	}, revision, "Chart.yaml", entries)
	if err != nil {
		t.Fatalf("실제 helm template import 실패: %v", err)
	}
	if len(parsed.Services) != 1 || parsed.Services[0].Name != "api" || parsed.Services[0].Port != 8080 {
		t.Fatalf("Helm Chart 서비스 변환 불일치: %+v", parsed.Services)
	}
}

func TestParseHelmManifestsBuildsMultipleServices(t *testing.T) {
	manifest := `
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-import-api
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: registry.example/api:1.2.3
          env:
            - name: LOG_LEVEL
              value: info
          ports:
            - name: http
              containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-import-worker
spec:
  template:
    metadata:
      labels:
        app: worker
    spec:
      containers:
        - name: worker
          image: registry.example/worker:4.5.6
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ignored
data:
  key: value
`
	parsed, err := parseHelmManifests([]byte(manifest))
	if err != nil {
		t.Fatalf("Helm manifest 변환 실패: %v", err)
	}
	if len(parsed.Services) != 2 {
		t.Fatalf("변환 서비스 수=%d: %+v", len(parsed.Services), parsed.Services)
	}
	api := parsed.Services[0]
	worker := parsed.Services[1]
	if api.Name != "api" || api.Port != 8080 || api.Replicas != 2 || api.Image != "registry.example/api:1.2.3" || api.Config["LOG_LEVEL"] != "info" {
		t.Fatalf("api 변환 불일치: %+v", api)
	}
	if worker.Name != "worker" || worker.Port != 0 {
		t.Fatalf("worker 변환 불일치: %+v", worker)
	}
	if !strings.Contains(strings.Join(parsed.Warnings, "\n"), "ConfigMap") {
		t.Fatalf("무시한 리소스 안내 누락: %+v", parsed.Warnings)
	}
}

func TestParseHelmManifestsRejectsUnportableOrSensitiveWorkloads(t *testing.T) {
	for name, manifest := range map[string]string{
		"stateful": `apiVersion: apps/v1
kind: StatefulSet
metadata: {name: db}
`,
		"secret env": `apiVersion: apps/v1
kind: Deployment
metadata: {name: portal-import-api}
spec:
  template:
    metadata:
      labels: {app: api}
    spec:
      containers:
        - name: api
          image: registry.example/api:1.2.3
          env:
            - name: API_TOKEN
              value: should-not-move-to-git
`,
		"volume": `apiVersion: apps/v1
kind: Deployment
metadata: {name: portal-import-api}
spec:
  template:
    metadata:
      labels: {app: api}
    spec:
      volumes:
        - name: host
          hostPath: {path: /etc}
      containers:
        - name: api
          image: registry.example/api:1.2.3
`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseHelmManifests([]byte(manifest)); err == nil {
				t.Fatal("안전하게 변환할 수 없는 Helm workload가 통과함")
			}
		})
	}
}
