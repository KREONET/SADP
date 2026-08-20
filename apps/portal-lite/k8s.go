package main

// 클러스터 안에서 서비스 준비 상태를 읽는 최소 Kubernetes 클라이언트.
// 외부 의존성 없이 표준 라이브러리만 사용하며, 권한은 EndpointSlice 읽기 하나만 필요하다.
// ServiceAccount 토큰이 없으면(로컬 실행·테스트) 프로버 자체가 비활성이 되고
// 카탈로그는 기존과 똑같은 정적 상태를 그대로 돌려준다.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	serviceAccountDir = "/var/run/secrets/kubernetes.io/serviceaccount"
	// 상태 조회 응답을 재사용하는 기간. 카탈로그 요청이 몰려도 API 서버를 때리지 않는다.
	statusCacheTTL = 10 * time.Second
	// 프로브 1회에 허용하는 최대 시간.
	statusProbeTimeout = 2 * time.Second
	// 응답 본문 상한(EndpointSlice 목록이 커도 메모리를 지키게 한다).
	maxKubeResponseBody = 1 << 20
)

type k8sClient struct {
	base      string
	tokenPath string
	http      *http.Client
}

// newInClusterClient는 Pod 안에서만 성공한다. 그 밖에서는 에러를 돌려주고
// 호출자는 상태 프로브 없이 동작하면 된다.
func newInClusterClient() (*k8sClient, error) {
	host := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_HOST"))
	port := strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_PORT"))
	if host == "" || port == "" {
		return nil, errors.New("KUBERNETES_SERVICE_HOST/PORT가 없다(클러스터 밖)")
	}
	if _, err := os.Stat(serviceAccountDir + "/token"); err != nil {
		return nil, fmt.Errorf("ServiceAccount 토큰 없음: %w", err)
	}
	authority, err := os.ReadFile(serviceAccountDir + "/ca.crt")
	if err != nil {
		return nil, fmt.Errorf("ServiceAccount CA 읽기 실패: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(authority) {
		return nil, errors.New("ServiceAccount CA를 해석할 수 없다")
	}
	transport := &http.Transport{
		TLSClientConfig:     &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
		MaxIdleConns:        4,
		IdleConnTimeout:     60 * time.Second,
		TLSHandshakeTimeout: 5 * time.Second,
	}
	return &k8sClient{
		base:      "https://" + net.JoinHostPort(host, port),
		tokenPath: serviceAccountDir + "/token",
		http:      &http.Client{Transport: transport, Timeout: statusProbeTimeout},
	}, nil
}

// endpointSliceList는 필요한 필드만 담는다. 알 수 없는 필드는 그대로 버린다.
type endpointSliceList struct {
	Items []struct {
		Endpoints []struct {
			Conditions struct {
				Ready *bool `json:"ready"`
			} `json:"conditions"`
		} `json:"endpoints"`
	} `json:"items"`
}

// serviceReady는 지정한 Service에 Ready 상태의 엔드포인트가 하나라도 있는지 본다.
// Service가 없으면(false, nil), 권한·통신 문제면 에러를 돌려준다.
func (c *k8sClient) serviceReady(ctx context.Context, namespace, name string) (bool, error) {
	if !isDNS1123Name(namespace) || !isDNS1123Name(name) {
		return false, fmt.Errorf("이름 형식이 올바르지 않다: %q/%q", namespace, name)
	}
	token, err := os.ReadFile(c.tokenPath)
	if err != nil {
		return false, fmt.Errorf("토큰 읽기 실패: %w", err)
	}
	endpoint := c.base + "/apis/discovery.k8s.io/v1/namespaces/" + url.PathEscape(namespace) +
		"/endpointslices?limit=100&labelSelector=" + url.QueryEscape("kubernetes.io/service-name="+name)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return false, err
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	request.Header.Set("Accept", "application/json")
	response, err := c.http.Do(request)
	if err != nil {
		return false, err
	}
	defer func() {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, maxKubeResponseBody))
		_ = response.Body.Close()
	}()
	switch {
	case response.StatusCode == http.StatusNotFound:
		return false, nil
	case response.StatusCode != http.StatusOK:
		return false, fmt.Errorf("kube API 응답 %d", response.StatusCode)
	}
	var list endpointSliceList
	if err := json.NewDecoder(io.LimitReader(response.Body, maxKubeResponseBody)).Decode(&list); err != nil {
		return false, fmt.Errorf("EndpointSlice 해석 실패: %w", err)
	}
	for _, slice := range list.Items {
		for _, endpointEntry := range slice.Endpoints {
			// ready가 비어 있으면 준비된 것으로 본다(스펙 기본값).
			if endpointEntry.Conditions.Ready == nil || *endpointEntry.Conditions.Ready {
				return true, nil
			}
		}
	}
	return false, nil
}

func isDNS1123Name(value string) bool {
	if value == "" || len(value) > 253 {
		return false
	}
	for index, char := range value {
		switch {
		case char >= 'a' && char <= 'z', char >= '0' && char <= '9':
		case (char == '-' || char == '.') && index != 0 && index != len(value)-1:
		default:
			return false
		}
	}
	return true
}

type serviceRef struct {
	Namespace string
	Name      string
}

type cachedStatus struct {
	value   string
	checked time.Time
}

// statusProber는 카탈로그 서비스의 실제 상태를 TTL 캐시와 함께 제공한다.
type statusProber struct {
	client *k8sClient
	ttl    time.Duration
	mu     sync.Mutex
	cache  map[serviceRef]cachedStatus
}

func newStatusProber(client *k8sClient) *statusProber {
	if client == nil {
		return nil
	}
	return &statusProber{client: client, ttl: statusCacheTTL, cache: map[serviceRef]cachedStatus{}}
}

// status는 available·degraded·unknown 중 하나를 돌려준다.
func (p *statusProber) status(ctx context.Context, ref serviceRef) string {
	if p == nil {
		return ""
	}
	now := time.Now()
	p.mu.Lock()
	if entry, ok := p.cache[ref]; ok && now.Sub(entry.checked) < p.ttl {
		p.mu.Unlock()
		return entry.value
	}
	p.mu.Unlock()

	probeCtx, cancel := context.WithTimeout(ctx, statusProbeTimeout)
	defer cancel()
	ready, err := p.client.serviceReady(probeCtx, ref.Namespace, ref.Name)
	value := "unknown"
	if err == nil {
		value = "degraded"
		if ready {
			value = "available"
		}
	}

	p.mu.Lock()
	p.cache[ref] = cachedStatus{value: value, checked: now}
	p.mu.Unlock()
	return value
}
