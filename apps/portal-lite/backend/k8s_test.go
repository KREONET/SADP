package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// newTestProber는 httptest 서버를 kube API로 삼는 프로버를 만든다.
func newTestProber(t *testing.T, handler http.HandlerFunc) (*statusProber, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	tokenPath := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenPath, []byte("test-token\n"), 0o600); err != nil {
		t.Fatalf("토큰 파일 생성 실패: %v", err)
	}
	client := &k8sClient{
		base:      server.URL,
		tokenPath: tokenPath,
		http:      &http.Client{Timeout: 2 * time.Second},
	}
	return newStatusProber(client), server
}

func endpointSliceBody(t *testing.T, ready ...bool) string {
	t.Helper()
	type conditions struct {
		Ready *bool `json:"ready"`
	}
	type endpoint struct {
		Conditions conditions `json:"conditions"`
	}
	slice := struct {
		Items []struct {
			Endpoints []endpoint `json:"endpoints"`
		} `json:"items"`
	}{}
	entries := make([]endpoint, 0, len(ready))
	for index := range ready {
		value := ready[index]
		entries = append(entries, endpoint{Conditions: conditions{Ready: &value}})
	}
	slice.Items = append(slice.Items, struct {
		Endpoints []endpoint `json:"endpoints"`
	}{Endpoints: entries})
	body, err := json.Marshal(slice)
	if err != nil {
		t.Fatalf("본문 생성 실패: %v", err)
	}
	return string(body)
}

func TestServiceReadyReadsEndpointSlices(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		body       string
		wantReady  bool
		wantErrors bool
	}{
		{name: "ready", status: http.StatusOK, body: endpointSliceBody(t, false, true), wantReady: true},
		{name: "not-ready", status: http.StatusOK, body: endpointSliceBody(t, false), wantReady: false},
		{name: "empty", status: http.StatusOK, body: `{"items":[]}`, wantReady: false},
		{name: "missing", status: http.StatusNotFound, body: `{}`, wantReady: false},
		{name: "forbidden", status: http.StatusForbidden, body: `{}`, wantErrors: true},
		{name: "garbage", status: http.StatusOK, body: `{`, wantErrors: true},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			prober, _ := newTestProber(t, func(w http.ResponseWriter, r *http.Request) {
				// 요청은 반드시 토큰과 서비스 라벨 셀렉터를 달고 와야 한다.
				if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
					t.Errorf("Authorization 헤더=%q", got)
				}
				if got := r.URL.Query().Get("labelSelector"); got != "kubernetes.io/service-name=hello" {
					t.Errorf("labelSelector=%q", got)
				}
				if !strings.HasPrefix(r.URL.Path, "/apis/discovery.k8s.io/v1/namespaces/research-beta/") {
					t.Errorf("path=%q", r.URL.Path)
				}
				w.WriteHeader(testCase.status)
				_, _ = w.Write([]byte(testCase.body))
			})

			ready, err := prober.client.serviceReady(context.Background(), "research-beta", "hello")
			if testCase.wantErrors {
				if err == nil {
					t.Fatalf("에러를 기대했지만 ready=%v", ready)
				}
				return
			}
			if err != nil {
				t.Fatalf("예상치 못한 에러: %v", err)
			}
			if ready != testCase.wantReady {
				t.Fatalf("ready=%v, want %v", ready, testCase.wantReady)
			}
		})
	}
}

func TestServiceReadyRejectsBadNames(t *testing.T) {
	prober, _ := newTestProber(t, func(w http.ResponseWriter, _ *http.Request) {
		t.Error("잘못된 이름은 API 서버까지 가면 안 된다")
		w.WriteHeader(http.StatusOK)
	})
	for _, bad := range []string{"", "Bad-Name", "ns/../etc", "-lead", "trail-", "a b"} {
		if _, err := prober.client.serviceReady(context.Background(), bad, "hello"); err == nil {
			t.Errorf("namespace %q는 거부되어야 한다", bad)
		}
		if _, err := prober.client.serviceReady(context.Background(), "research-beta", bad); err == nil {
			t.Errorf("name %q는 거부되어야 한다", bad)
		}
	}
}

func TestStatusProberCachesAndDegrades(t *testing.T) {
	var calls int64
	prober, _ := newTestProber(t, func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt64(&calls, 1)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(endpointSliceBody(t, false)))
	})

	ref := serviceRef{Namespace: "research-beta", Name: "hello"}
	for range 3 {
		if got := prober.status(context.Background(), ref); got != "degraded" {
			t.Fatalf("status=%q, want degraded", got)
		}
	}
	if got := atomic.LoadInt64(&calls); got != 1 {
		t.Fatalf("API 호출 %d회, TTL 캐시로 1회여야 한다", got)
	}

	// 다른 서비스는 캐시를 공유하지 않는다.
	prober.status(context.Background(), serviceRef{Namespace: "research-beta", Name: "secure-demo"})
	if got := atomic.LoadInt64(&calls); got != 2 {
		t.Fatalf("API 호출 %d회, 서비스별로 조회해야 한다", got)
	}
}

func TestStatusProberUnknownOnAPIFailure(t *testing.T) {
	prober, server := newTestProber(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	server.Close() // 통신 자체가 끊긴 상황.

	got := prober.status(context.Background(), serviceRef{Namespace: "research-beta", Name: "hello"})
	if got != "unknown" {
		t.Fatalf("status=%q, want unknown", got)
	}
}

func TestNilProberKeepsStaticCatalog(t *testing.T) {
	var nilProber *statusProber
	if got := nilProber.status(context.Background(), serviceRef{Namespace: "research-beta", Name: "hello"}); got != "" {
		t.Fatalf("nil 프로버 status=%q, want 빈 문자열", got)
	}
	if newStatusProber(nil) != nil {
		t.Fatal("nil 클라이언트로는 프로버가 만들어지면 안 된다")
	}

	api := &apiServer{}
	response := catalog()
	before := make([]string, len(response.Services))
	for index, service := range response.Services {
		before[index] = service.Status
	}
	api.applyLiveStatus(httptest.NewRequest(http.MethodGet, "/api/v1/catalog", nil), response.Services)
	for index, service := range response.Services {
		if service.Status != before[index] {
			t.Fatalf("%s 상태가 %q에서 %q로 바뀌었다", service.ID, before[index], service.Status)
		}
	}
}

func TestCatalogAppliesLiveStatus(t *testing.T) {
	prober, _ := newTestProber(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		// hello만 Ready, 나머지는 준비되지 않은 상태로 답한다.
		if r.URL.Query().Get("labelSelector") == "kubernetes.io/service-name=hello" {
			_, _ = w.Write([]byte(endpointSliceBody(t, true)))
			return
		}
		_, _ = w.Write([]byte(endpointSliceBody(t, false)))
	})

	api := &apiServer{prober: prober}
	recorder := httptest.NewRecorder()
	api.handleCatalog(recorder, httptest.NewRequest(http.MethodGet, "/api/v1/catalog", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d", recorder.Code)
	}
	var response catalogResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("응답 해석 실패: %v", err)
	}

	targets := catalogProbeTargets()
	seen := 0
	for _, service := range response.Services {
		if _, probed := targets[service.ID]; !probed {
			continue
		}
		seen++
		want := "degraded"
		if service.ID == "hello" {
			want = "available"
		}
		if service.Status != want {
			t.Errorf("%s 상태=%q, want %q", service.ID, service.Status, want)
		}
	}
	if seen != len(targets) {
		t.Fatalf("프로브 대상 %d개 중 %d개만 카탈로그에 있다", len(targets), seen)
	}
	// 프로버가 붙어도 Forgejo 미설정이면 신청은 계속 막혀 있어야 한다.
	if response.SubmissionEnabled || response.ForgejoConnected {
		t.Fatal("Forgejo 없이 신청이 열렸다")
	}
}
