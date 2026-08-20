package main

// PR이 열린 뒤의 자동화 단계를 담당한다.
//
//	pr-open → (자동 승인) merged → (kaniko 빌드) building → deploying → deployed
//
// 빌드는 클러스터 안에서 kaniko Job으로 돌린다. 포털 파드는 Job을 만들고 상태만
// 지켜보며, 레지스트리 자격증명은 Job이 마운트하는 Secret에만 존재한다.
// 실패하면 요청을 failed로 남기고 사람이 PR을 직접 처리할 수 있게 둔다.

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	// 빌드 Job 생성/조회에 쓰는 호출 상한. 상태 프로브(2초)보다 넉넉해야 한다.
	buildAPITimeout = 20 * time.Second
	// Job 상태를 확인하는 주기.
	buildPollInterval = 5 * time.Second
	// 이미지 태그로 쓸 수 있는 문자만 남긴다.
	maxImageTagLength      = 100
	argoResourcesFinalizer = "resources-finalizer.argocd.argoproj.io"
)

var unsafeTagChars = regexp.MustCompile(`[^A-Za-z0-9_.-]+`)

// buildPipeline은 kube API로 kaniko Job을 만들고 완료를 기다린다.
type buildPipeline struct {
	base      string
	tokenPath string
	client    *http.Client
	logger    *log.Logger
}

// newBuildPipeline은 클러스터 안에서만 만들어진다. 밖에서는 nil을 돌려주고
// 호출자는 자동 빌드 없이 PR까지만 수행한다.
func newBuildPipeline(kube *k8sClient, logger *log.Logger) *buildPipeline {
	if kube == nil {
		return nil
	}
	transport, ok := kube.http.Transport.(*http.Transport)
	if !ok || transport == nil {
		return nil
	}
	cloned := transport.Clone()
	cloned.TLSClientConfig = &tls.Config{
		RootCAs:    transport.TLSClientConfig.RootCAs,
		MinVersion: tls.VersionTLS12,
	}
	return &buildPipeline{
		base:      kube.base,
		tokenPath: kube.tokenPath,
		client:    &http.Client{Transport: cloned, Timeout: buildAPITimeout},
		logger:    logger,
	}
}

// do는 kube API를 호출한다. 404는 호출자가 구분할 수 있게 그대로 알려준다.
func (p *buildPipeline) do(ctx context.Context, method, path string, body any, out any) (int, error) {
	return p.doWithContentType(ctx, method, path, "application/json", body, out)
}

func (p *buildPipeline) doWithContentType(
	ctx context.Context, method, path, contentType string, body any, out any,
) (int, error) {
	token, err := os.ReadFile(p.tokenPath)
	if err != nil {
		return 0, fmt.Errorf("토큰 읽기 실패: %w", err)
	}
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return 0, fmt.Errorf("요청 직렬화 실패: %w", err)
		}
		reader = strings.NewReader(string(encoded))
	}
	request, err := http.NewRequestWithContext(ctx, method, p.base+path, reader)
	if err != nil {
		return 0, err
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", contentType)
	}
	response, err := p.client.Do(request)
	if err != nil {
		return 0, fmt.Errorf("kube API 호출 실패: %w", err)
	}
	defer func() {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, maxKubeResponseBody))
		_ = response.Body.Close()
	}()
	payload, readErr := io.ReadAll(io.LimitReader(response.Body, maxKubeResponseBody))
	if response.StatusCode >= 400 {
		return response.StatusCode, fmt.Errorf("kube API 응답 %d: %s",
			response.StatusCode, strings.TrimSpace(firstLine(string(payload))))
	}
	if readErr != nil {
		return response.StatusCode, fmt.Errorf("kube API 응답 읽기 실패: %w", readErr)
	}
	if out != nil {
		if err := json.Unmarshal(payload, out); err != nil {
			return response.StatusCode, fmt.Errorf("kube API 응답 해석 실패: %w", err)
		}
	}
	return response.StatusCode, nil
}

// namespaceExists는 AppGroup이 새 Namespace 이름을 선점하기 전에 기존 플랫폼/수동
// Namespace를 덮지 않도록 read-only로 확인한다. Portal은 Namespace를 직접 만들거나
// 수정하지 않고, 없다는 것이 확인된 경우에만 GitOps bootstrap을 제출한다.
func (p *buildPipeline) namespaceExists(ctx context.Context, namespace string) (bool, error) {
	status, err := p.do(ctx, http.MethodGet,
		"/api/v1/namespaces/"+url.PathEscape(namespace), nil, nil)
	if status == http.StatusNotFound {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return status == http.StatusOK, nil
}

func firstLine(value string) string {
	if index := strings.IndexByte(value, '\n'); index >= 0 {
		return value[:index]
	}
	if len(value) > 300 {
		return value[:300]
	}
	return value
}

// imageTag는 재현 가능한 태그를 만든다. 같은 요청은 항상 같은 태그를 쓴다.
func imageTag(request deploymentRequest) string {
	revision := request.Profile.Source.Commit
	if revision == "" {
		revision = request.Profile.Source.Revision
	}
	revision = unsafeTagChars.ReplaceAllString(revision, "-")
	revision = strings.Trim(revision, "-._")
	if revision == "" {
		revision = "build"
	}
	short := strings.ReplaceAll(request.ID, "-", "")
	if len(short) > 12 {
		short = short[:12]
	}
	tag := revision + "-" + short
	if len(tag) > maxImageTagLength {
		tag = tag[len(tag)-maxImageTagLength:]
	}
	return tag
}

func buildJobName(request deploymentRequest) string {
	short := strings.ReplaceAll(request.ID, "-", "")
	if len(short) > 12 {
		short = short[:12]
	}
	name := "portal-build-" + strings.ToLower(request.Profile.App.Name) + "-" + short
	if len(name) > 63 {
		name = name[:63]
	}
	return strings.Trim(name, "-")
}

// imageDestination은 레지스트리 경로를 만든다. 태그까지 포함한 완전한 이름이다.
func imageDestination(request deploymentRequest, tag string) string {
	repository := strings.ToLower(request.Profile.App.Name)
	if request.Profile.App.Group != "" {
		repository = strings.ToLower(request.Profile.App.Group + "/" + request.Profile.App.Name)
	}
	return fmt.Sprintf("%s/%s:%s",
		strings.TrimRight(registryBase, "/"), repository, tag)
}

// gitContext는 kaniko가 읽을 소스 위치다. 사설 저장소는 GIT_USERNAME/GIT_PASSWORD로 인증한다.
func gitContext(request deploymentRequest) string {
	repository := strings.TrimSuffix(request.Profile.Source.Repository, ".git")
	repository = strings.TrimPrefix(repository, "https://")
	repository = strings.TrimPrefix(repository, "http://")
	revision := request.Profile.Source.Revision
	if revision == "" {
		revision = "main"
	}
	context := fmt.Sprintf("git://%s.git#refs/heads/%s", repository, revision)
	if commit := strings.TrimSpace(request.Profile.Source.Commit); commit != "" {
		// kaniko는 #reference#commit-id 형식으로 branch 이동 뒤에도 정확히 같은 tree를
		// clone한다. 감지한 SHA와 실제 image 내용이 갈라지지 않게 반드시 둘 다 준다.
		context += "#" + commit
	}
	return context
}

// jobManifest는 kaniko Job 하나를 기술한다. 파드는 egress 정책 라벨을 달고
// 프록시를 통해서만 밖으로 나간다.
func (p *buildPipeline) jobManifest(request deploymentRequest, tag string) map[string]any {
	name := buildJobName(request)
	dockerfile := request.Profile.Source.Dockerfile
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}
	args := []string{
		"--context=" + gitContext(request),
		"--dockerfile=" + dockerfile,
		"--destination=" + imageDestination(request, tag),
		"--single-snapshot",
		"--cleanup",
	}
	if contextPath := request.Profile.Source.Context; contextPath != "" && contextPath != "." {
		// Compose build.context의 COPY/ADD 기준을 보존한다. 경로는 Compose 검증에서
		// 저장소 내부 상대 경로로 제한되며 사용자 임의 kaniko 인자는 받지 않는다.
		args = append(args, "--context-sub-path="+contextPath)
	}
	env := []map[string]any{
		{"name": "GIT_USERNAME", "value": buildGitUsername},
		{"name": "GIT_PASSWORD", "valueFrom": map[string]any{
			"secretKeyRef": map[string]any{"name": buildGitSecret, "key": buildGitSecretKey},
		}},
		{"name": "NO_PROXY", "value": buildNoProxy},
		{"name": "no_proxy", "value": buildNoProxy},
	}
	if buildHTTPProxy != "" {
		env = append(env,
			map[string]any{"name": "HTTP_PROXY", "value": buildHTTPProxy},
			map[string]any{"name": "HTTPS_PROXY", "value": buildHTTPProxy},
			map[string]any{"name": "http_proxy", "value": buildHTTPProxy},
			map[string]any{"name": "https_proxy", "value": buildHTTPProxy},
		)
	}
	return map[string]any{
		"apiVersion": "batch/v1",
		"kind":       "Job",
		"metadata": map[string]any{
			"name":      name,
			"namespace": buildNamespace,
			"labels": map[string]any{
				"app.kubernetes.io/name":         "portal-build",
				"app.kubernetes.io/component":    "image-build",
				"portal.example.invalid/request": shortRequestLabel(request.ID),
			},
		},
		"spec": map[string]any{
			"backoffLimit":            0,
			"ttlSecondsAfterFinished": 3600,
			"activeDeadlineSeconds":   buildTimeoutSeconds,
			"template": map[string]any{
				"metadata": map[string]any{
					"labels": map[string]any{
						"app.kubernetes.io/name":         "portal-build",
						"portal.example.invalid/request": shortRequestLabel(request.ID),
					},
				},
				"spec": map[string]any{
					"restartPolicy":                "Never",
					"automountServiceAccountToken": false,
					"containers": []map[string]any{{
						"name":  "kaniko",
						"image": buildImage,
						"args":  args,
						"env":   env,
						"resources": map[string]any{
							"requests": map[string]any{"cpu": "500m", "memory": "1Gi"},
							"limits":   map[string]any{"cpu": "2", "memory": "4Gi"},
						},
						"volumeMounts": []map[string]any{{
							"name":      "registry-credentials",
							"mountPath": "/kaniko/.docker",
							"readOnly":  true,
						}},
					}},
					"volumes": []map[string]any{{
						"name": "registry-credentials",
						"secret": map[string]any{
							"secretName": buildPushSecret,
							"items":      []map[string]any{{"key": buildPushSecretKey, "path": "config.json"}},
						},
					}},
				},
			},
		},
	}
}

// shortRequestLabel은 라벨 값 제한(63자)에 맞춘 요청 식별자를 만든다.
func shortRequestLabel(requestID string) string {
	value := strings.ReplaceAll(requestID, "-", "")
	if len(value) > 63 {
		value = value[:63]
	}
	return value
}

type jobStatus struct {
	Status struct {
		Succeeded  int `json:"succeeded"`
		Failed     int `json:"failed"`
		Conditions []struct {
			Type    string `json:"type"`
			Status  string `json:"status"`
			Reason  string `json:"reason"`
			Message string `json:"message"`
		} `json:"conditions"`
	} `json:"status"`
}

type podListStatus struct {
	Items []struct {
		Status struct {
			Phase             string `json:"phase"`
			ContainerStatuses []struct {
				State struct {
					Waiting *struct {
						Reason  string `json:"reason"`
						Message string `json:"message"`
					} `json:"waiting"`
					Terminated *struct {
						Reason   string `json:"reason"`
						Message  string `json:"message"`
						ExitCode int    `json:"exitCode"`
					} `json:"terminated"`
				} `json:"state"`
			} `json:"containerStatuses"`
		} `json:"status"`
	} `json:"items"`
}

type secretKeyStatus struct {
	Data map[string]string `json:"data"`
}

type dockerCredential struct {
	Auth     string `json:"auth"`
	Username string `json:"username"`
	Password string `json:"password"`
}

func validDockerCredential(credential dockerCredential) bool {
	if credential.Auth == "" {
		return credential.Username != "" && credential.Password != ""
	}
	decoded, err := base64.StdEncoding.DecodeString(credential.Auth)
	return err == nil && bytes.Contains(decoded, []byte(":"))
}

// requireBuildCredential는 소스 빌드 신청을 받기 전에 고정 push Secret과 key가 실제로
// 있는지 확인한다. 값은 로그/응답에 남기지 않고 map 존재 여부만 본다.
func (p *buildPipeline) requireBuildCredential(ctx context.Context) error {
	if p == nil {
		return errors.New("클러스터 build pipeline이 비활성입니다")
	}
	var secret secretKeyStatus
	secretPath := fmt.Sprintf("/api/v1/namespaces/%s/secrets/%s",
		url.PathEscape(buildNamespace), url.PathEscape(buildPushSecret))
	if _, err := p.do(ctx, http.MethodGet, secretPath, nil, &secret); err != nil {
		return fmt.Errorf("registry push Secret 확인 실패: %w", err)
	}
	encoded, exists := secret.Data[buildPushSecretKey]
	if !exists || encoded == "" {
		return fmt.Errorf("registry push Secret %s에 key %s가 없습니다", buildPushSecret, buildPushSecretKey)
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return fmt.Errorf("registry push Secret %s의 Docker config 인코딩이 올바르지 않습니다", buildPushSecret)
	}
	var dockerConfig struct {
		Auths map[string]dockerCredential `json:"auths"`
	}
	if json.Unmarshal(decoded, &dockerConfig) != nil || len(dockerConfig.Auths) == 0 {
		return fmt.Errorf("registry push Secret %s의 Docker config 형식이 올바르지 않습니다", buildPushSecret)
	}
	for _, credential := range dockerConfig.Auths {
		if !validDockerCredential(credential) {
			return fmt.Errorf("registry push Secret %s의 auth는 base64(username:password) 형식이어야 합니다", buildPushSecret)
		}
	}
	return nil
}

var fatalPodWaitingReasons = map[string]bool{
	"ErrImagePull": true, "ImagePullBackOff": true, "CreateContainerConfigError": true,
	"CreateContainerError": true, "InvalidImageName": true, "RunContainerError": true,
	"CrashLoopBackOff": true,
}

func podFailure(list podListStatus) string {
	for _, pod := range list.Items {
		for _, container := range pod.Status.ContainerStatuses {
			if waiting := container.State.Waiting; waiting != nil && fatalPodWaitingReasons[waiting.Reason] {
				return strings.TrimSpace(waiting.Reason + ": " + firstLine(waiting.Message))
			}
			if terminated := container.State.Terminated; terminated != nil && terminated.ExitCode != 0 {
				return strings.TrimSpace(terminated.Reason + ": " + firstLine(terminated.Message))
			}
		}
	}
	return ""
}

func (p *buildPipeline) buildPodFailure(ctx context.Context, jobName string) string {
	return p.podFailureForSelector(ctx, buildNamespace, "job-name="+jobName)
}

// appPodFailure는 배포된 앱 Pod의 확정 실패를 본다. chart의 selectorLabels와 같은 조합이라
// 같은 Zone의 다른 앱 Pod를 잘못 집지 않는다.
func (p *buildPipeline) appPodFailure(ctx context.Context, request deploymentRequest) string {
	name := request.Profile.App.Name
	selector := "app.kubernetes.io/name=" + name + ",app.kubernetes.io/instance=" + name
	return p.podFailureForSelector(ctx, request.Profile.namespace(), selector)
}

func (p *buildPipeline) podFailureForSelector(ctx context.Context, namespace, selector string) string {
	path := "/api/v1/namespaces/" + url.PathEscape(namespace) + "/pods?labelSelector=" +
		url.QueryEscape(selector)
	var pods podListStatus
	if _, err := p.do(ctx, http.MethodGet, path, nil, &pods); err != nil {
		return ""
	}
	return podFailure(pods)
}

type deploymentStatus struct {
	Metadata struct {
		Generation int64 `json:"generation"`
	} `json:"metadata"`
	Spec struct {
		Replicas int `json:"replicas"`
		Template struct {
			Spec struct {
				Containers []struct {
					Image string `json:"image"`
				} `json:"containers"`
			} `json:"spec"`
		} `json:"template"`
	} `json:"spec"`
	Status struct {
		ObservedGeneration int64 `json:"observedGeneration"`
		Replicas           int   `json:"replicas"`
		ReadyReplicas      int   `json:"readyReplicas"`
		UpdatedReplicas    int   `json:"updatedReplicas"`
		AvailableReplicas  int   `json:"availableReplicas"`
	} `json:"status"`
}

type argoApplicationStatus struct {
	Metadata struct {
		Finalizers        []string `json:"finalizers"`
		DeletionTimestamp string   `json:"deletionTimestamp"`
	} `json:"metadata"`
	Status struct {
		Sync struct {
			Status    string   `json:"status"`
			Revision  string   `json:"revision"`
			Revisions []string `json:"revisions"`
		} `json:"sync"`
		Health struct {
			Status string `json:"status"`
		} `json:"health"`
		Conditions []struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"conditions"`
	} `json:"status"`
}

func argoHasRevision(application argoApplicationStatus, revision string) bool {
	if revision == "" {
		return false
	}
	if application.Status.Sync.Revision == revision {
		return true
	}
	return containsString(application.Status.Sync.Revisions, revision)
}

// applicationRevisionSynced는 이 요청의 Git revision을 app Application이 실제로
// 관찰했는지 확인한다. image만 같다고 성공 처리하면 HTTPRoute/SecurityPolicy 변경이
// 아직 적용되지 않은 이전 Deployment를 새 배포로 오인할 수 있다.
func (p *buildPipeline) applicationRevisionSynced(ctx context.Context, request deploymentRequest, revision string) (bool, error) {
	var application argoApplicationStatus
	status, err := p.do(ctx, http.MethodGet, p.applicationPath(appApplicationName(request.Profile)), nil, &application)
	if err != nil {
		if status == http.StatusNotFound {
			return false, nil
		}
		return false, err
	}
	return application.Status.Sync.Status == "Synced" && argoHasRevision(application, revision), nil
}

func (p *buildPipeline) waitForApplicationRevision(ctx context.Context, request deploymentRequest, revision string) error {
	deadline := time.Now().Add(time.Duration(rolloutTimeoutSeconds) * time.Second)
	for {
		synced, err := p.applicationRevisionSynced(ctx, request, revision)
		if err == nil && synced {
			return nil
		}
		if err != nil {
			p.logger.Printf("Argo Application %s revision 확인 실패: %v", appApplicationName(request.Profile), err)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Argo Application %s가 Git revision %s를 제한 시간 안에 동기화하지 못했습니다",
				appApplicationName(request.Profile), revision)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

// groupApplicationRevisionReady는 AppGroup Namespace의 baseline 전체가 해당 Git
// revision으로 적용됐는지 확인한다. Synced만 보면 Namespace가 생긴 직후 quota나
// default-deny의 health 판정이 끝나기 전에 앱 배포를 재촉할 수 있으므로 Healthy도
// 함께 요구한다.
func (p *buildPipeline) groupApplicationRevisionReady(
	ctx context.Context, group appGroup, revision string,
) (bool, error) {
	var application argoApplicationStatus
	status, err := p.do(ctx, http.MethodGet,
		p.applicationPath(groupApplicationName(group)), nil, &application)
	if err != nil {
		if status == http.StatusNotFound {
			return false, nil
		}
		return false, err
	}
	return groupApplicationAtRevisionReady(application, revision)
}

func groupApplicationAtRevisionReady(
	application argoApplicationStatus, revision string,
) (bool, error) {
	if failure := fatalApplicationCondition(application); failure != "" {
		return false, fmt.Errorf("%w: %s", errFatalApplicationCondition, failure)
	}
	return application.Status.Sync.Status == "Synced" &&
		application.Status.Health.Status == "Healthy" &&
		argoHasRevision(application, revision), nil
}

func (p *buildPipeline) waitForGroupApplicationRevision(
	ctx context.Context, group appGroup, revision string,
) error {
	deadline := time.Now().Add(time.Duration(rolloutTimeoutSeconds) * time.Second)
	for {
		ready, err := p.groupApplicationRevisionReady(ctx, group, revision)
		if err == nil && ready {
			return nil
		}
		if err != nil {
			p.logger.Printf("AppGroup Application %s baseline 확인 실패: %v",
				groupApplicationName(group), err)
			if errors.Is(err, errFatalApplicationCondition) {
				return err
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("AppGroup Application %s가 Git revision %s로 Synced/Healthy가 되지 못했습니다",
				groupApplicationName(group), revision)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

// AppProject가 없으면 resource finalizer가 cascade 정리를 시작조차 못 해서 Application이
// Terminating으로 영원히 남는다. 스스로 낫지 않는 조건이므로 제한 시간을 다 쓰지 않고 끊는다.
var fatalApplicationConditions = map[string]bool{
	"DeletionError":    true,
	"InvalidSpecError": true,
}

var errFatalApplicationCondition = errors.New("Argo Application spec 오류")

func fatalApplicationCondition(application argoApplicationStatus) string {
	for _, condition := range application.Status.Conditions {
		if fatalApplicationConditions[condition.Type] {
			return strings.TrimSpace(condition.Type + ": " + firstLine(condition.Message))
		}
	}
	return ""
}

func (p *buildPipeline) jobPath(name string) string {
	path := "/apis/batch/v1/namespaces/" + url.PathEscape(buildNamespace) + "/jobs"
	if name == "" {
		return path
	}
	return path + "/" + url.PathEscape(name)
}

// build는 Job을 만들고 끝날 때까지 기다린다. 성공하면 태그를 돌려준다.
func (p *buildPipeline) build(ctx context.Context, request deploymentRequest) (string, error) {
	tag := imageTag(request)
	name := buildJobName(request)

	// 재시도로 남은 이전 Job은 지우고 새로 만든다. 지우기 실패는 생성 단계에서 드러난다.
	if _, err := p.do(ctx, http.MethodDelete,
		p.jobPath(name)+"?propagationPolicy=Background", nil, nil); err != nil {
		p.logger.Printf("빌드 Job %s 정리 생략: %v", name, err)
	}
	// 삭제가 반영될 때까지 잠깐 기다린다. 곧바로 만들면 409가 난다.
	deadline := time.Now().Add(30 * time.Second)
	for {
		status, _ := p.do(ctx, http.MethodGet, p.jobPath(name), nil, nil)
		if status == http.StatusNotFound || time.Now().After(deadline) {
			break
		}
		if err := sleepContext(ctx, 2*time.Second); err != nil {
			return "", err
		}
	}

	if _, err := p.do(ctx, http.MethodPost, p.jobPath(""), p.jobManifest(request, tag), nil); err != nil {
		return "", fmt.Errorf("빌드 Job 생성 실패: %w", err)
	}
	p.logger.Printf("요청 %s 이미지 빌드 시작: %s", request.ID, imageDestination(request, tag))

	buildDeadline := time.Now().Add(time.Duration(buildTimeoutSeconds+60) * time.Second)
	for {
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return "", err
		}
		var status jobStatus
		if _, err := p.do(ctx, http.MethodGet, p.jobPath(name), nil, &status); err != nil {
			p.logger.Printf("빌드 Job %s 상태 조회 실패: %v", name, err)
			if time.Now().After(buildDeadline) {
				return "", fmt.Errorf("빌드 상태를 확인할 수 없습니다")
			}
			continue
		}
		if status.Status.Succeeded > 0 {
			return tag, nil
		}
		for _, condition := range status.Status.Conditions {
			if condition.Type == "Failed" && condition.Status == "True" {
				return "", fmt.Errorf("이미지 빌드 실패: %s", condition.Reason)
			}
		}
		if failure := p.buildPodFailure(ctx, name); failure != "" {
			return "", fmt.Errorf("빌드 Pod 시작 실패: %s", failure)
		}
		if time.Now().After(buildDeadline) {
			return "", fmt.Errorf("이미지 빌드가 제한 시간(%d초)을 넘겼습니다", buildTimeoutSeconds)
		}
	}
}

// waitForDeployment은 Argo CD가 새 image tag를 반영하고 모든 replica가 Ready가 될 때까지
// 기다린다. 이름과 namespace는 검증된 앱 이름과 단일 Zone만 사용한다.
func (p *buildPipeline) waitForDeployment(ctx context.Context, request deploymentRequest, image string) error {
	deadline := time.Now().Add(time.Duration(rolloutTimeoutSeconds) * time.Second)
	for {
		ready, err := p.deploymentReady(ctx, request, image)
		if ready {
			return nil
		}
		if err != nil {
			p.logger.Printf("배포 %s 상태 조회 실패: %v", request.Profile.App.Name, err)
		}
		// ExternalSecret이 동기화되지 못하면 앱 Pod는 CreateContainerConfigError로 계속
		// 재시도만 한다. Deployment condition에는 안 드러나므로 Pod를 직접 본다.
		if failure := p.appPodFailure(ctx, request); failure != "" {
			return fmt.Errorf("앱 Pod 시작 실패: %s", failure)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Namespace %s의 Deployment가 제한 시간(%d초) 안에 Ready가 되지 않았습니다",
				request.Profile.namespace(), rolloutTimeoutSeconds)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

// deploymentReady는 화면 조회에서도 재사용하는 1회성 실제 상태 확인이다.
// 긴 rollout 대기가 끝난 직후 리소스가 준비된 경우 다음 조회에서 즉시 수렴시킨다.
func (p *buildPipeline) deploymentReady(ctx context.Context, request deploymentRequest, image string) (bool, error) {
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
	imageApplied := image == ""
	for _, container := range deployment.Spec.Template.Spec.Containers {
		if container.Image == image {
			imageApplied = true
			break
		}
	}
	// 재개 성공은 현재 Deployment가 우연히 Ready인지만 보지 않고 신청 당시의
	// replica 수가 실제 spec에 복원됐는지까지 확인한다.
	replicas := max(request.Profile.Replicas, 1)
	ready := imageApplied && deployment.Status.ObservedGeneration >= deployment.Metadata.Generation &&
		deployment.Spec.Replicas == replicas && deployment.Status.Replicas == replicas &&
		deployment.Status.ReadyReplicas >= replicas &&
		deployment.Status.UpdatedReplicas >= replicas && deployment.Status.AvailableReplicas >= replicas
	if !ready {
		selector := "app.kubernetes.io/instance=" + request.Profile.App.Name +
			",app.kubernetes.io/name=" + request.Profile.App.Name
		if failure := p.podFailureForSelector(ctx, request.Profile.namespace(), selector); failure != "" {
			return false, fmt.Errorf("앱 Pod 시작 실패: %s", failure)
		}
	}
	return ready, nil
}

// appResourcesGone은 삭제 완료 여부를 한 번만 조회한다. Application과 Deployment가
// 모두 없을 때만 완료로 보므로 일시적인 API 오류를 삭제 성공으로 오인하지 않는다.
func (p *buildPipeline) appResourcesGone(ctx context.Context, request deploymentRequest) (bool, error) {
	appName := appApplicationName(request.Profile)
	appStatus, appErr := p.do(ctx, http.MethodGet, p.applicationPath(appName), nil, nil)
	deploymentPath := "/apis/apps/v1/namespaces/" + url.PathEscape(request.Profile.namespace()) +
		"/deployments/" + url.PathEscape(request.Profile.App.Name)
	deploymentStatus, deploymentErr := p.do(ctx, http.MethodGet, deploymentPath, nil, nil)
	if appErr != nil && appStatus != http.StatusNotFound {
		return false, appErr
	}
	if deploymentErr != nil && deploymentStatus != http.StatusNotFound {
		return false, deploymentErr
	}
	return appStatus == http.StatusNotFound && deploymentStatus == http.StatusNotFound, nil
}

func (p *buildPipeline) applicationPath(name string) string {
	return "/apis/argoproj.io/v1alpha1/namespaces/" + url.PathEscape(argoNamespace) +
		"/applications/" + url.PathEscape(name)
}

// refreshApplication은 Argo CD에 "지금 Git을 다시 봐라"를 알린다. Forgejo는 클러스터 밖이라
// Argo webhook을 쏠 수 없고, 폴링 주기(timeout.reconciliation)만 기다리면 커밋마다 그만큼
// 늦어진다. 방금 우리가 만든 커밋이라 hard refresh로 manifest 캐시까지 무효화한다.
// 실패해도 폴링이 결국 따라잡으므로 로그만 남기고 진행한다.
func (p *buildPipeline) refreshApplication(ctx context.Context, name string) {
	patch := map[string]any{
		"metadata": map[string]any{
			"annotations": map[string]any{"argocd.argoproj.io/refresh": "hard"},
		},
	}
	if _, err := p.doWithContentType(ctx, http.MethodPatch, p.applicationPath(name),
		"application/merge-patch+json", patch, nil); err != nil {
		p.logger.Printf("Argo Application %s refresh 요청 실패: %v", name, err)
	}
}

// waitForBootstrapRevision은 Git 삭제 커밋을 app-of-apps가 관찰한 뒤에만 child Application을
// 지우게 한다. 그렇지 않으면 오래된 desired state가 child를 다시 만들 수 있다.
func (p *buildPipeline) waitForBootstrapRevision(ctx context.Context, revision string) error {
	// 삭제 경로에서만 쓰이므로 삭제 쪽 제한 시간을 따른다.
	deadline := time.Now().Add(time.Duration(deleteTimeoutSeconds) * time.Second)
	path := p.applicationPath(argoBootstrapApplication)
	p.refreshApplication(ctx, argoBootstrapApplication)
	for {
		var application argoApplicationStatus
		if _, err := p.do(ctx, http.MethodGet, path, nil, &application); err == nil &&
			application.Status.Sync.Revision == revision {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Argo bootstrap이 Git revision %s를 제한 시간 안에 관찰하지 못했습니다", revision)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

// deleteApplication은 Argo resource finalizer를 보장한 뒤 child Application을 지운다.
// finalizer가 실제 Deployment/Service/HTTPRoute 등 chart 리소스를 cascade 정리한다.
func (p *buildPipeline) deleteApplication(ctx context.Context, request deploymentRequest) error {
	appName := appApplicationName(request.Profile)
	applicationPath := p.applicationPath(appName)
	deploymentPath := "/apis/apps/v1/namespaces/" + url.PathEscape(request.Profile.namespace()) +
		"/deployments/" + url.PathEscape(request.Profile.App.Name)
	deadline := time.Now().Add(time.Duration(deleteTimeoutSeconds) * time.Second)
	// 조건은 sync 직후 잠깐 나타났다 사라질 수 있다. 연속 2회 본 것만 확정으로 친다.
	fatalStreak := 0

	for {
		var application argoApplicationStatus
		appStatus, appErr := p.do(ctx, http.MethodGet, applicationPath, nil, &application)
		if appErr == nil {
			if failure := fatalApplicationCondition(application); failure != "" {
				fatalStreak++
				if fatalStreak >= 2 {
					return fmt.Errorf("Argo Application %s를 지울 수 없습니다: %s", appName, failure)
				}
			} else {
				fatalStreak = 0
			}
		}
		if appErr == nil && application.Metadata.DeletionTimestamp == "" {
			if !containsString(application.Metadata.Finalizers, argoResourcesFinalizer) {
				finalizers := append(application.Metadata.Finalizers, argoResourcesFinalizer)
				patch := map[string]any{"metadata": map[string]any{"finalizers": finalizers}}
				if _, err := p.doWithContentType(ctx, http.MethodPatch, applicationPath,
					"application/merge-patch+json", patch, nil); err != nil {
					return fmt.Errorf("Argo Application finalizer 설정 실패: %w", err)
				}
			}
			if _, err := p.do(ctx, http.MethodDelete,
				applicationPath+"?propagationPolicy=Foreground", nil, nil); err != nil {
				return fmt.Errorf("Argo Application 삭제 실패: %w", err)
			}
		} else if appErr != nil && appStatus != http.StatusNotFound {
			p.logger.Printf("Argo Application %s 삭제 상태 조회 실패: %v", appName, appErr)
		}

		deploymentStatus, deploymentErr := p.do(ctx, http.MethodGet, deploymentPath, nil, nil)
		appGone := appStatus == http.StatusNotFound
		deploymentGone := deploymentStatus == http.StatusNotFound
		if appGone && deploymentGone {
			return nil
		}
		if deploymentErr != nil && deploymentStatus != http.StatusNotFound {
			p.logger.Printf("Deployment %s 삭제 상태 조회 실패: %v", request.Profile.App.Name, deploymentErr)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Namespace %s의 앱 리소스가 제한 시간(%d초) 안에 삭제되지 않았습니다",
				request.Profile.namespace(), deleteTimeoutSeconds)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

// deleteNamedApplication은 이름만 알고 있는 child Application을 지우고 실제 Namespace
// 404까지 확인한다. Application이 이미 사라졌다는 사실만으로는 수동 orphan 삭제 뒤 남은
// Namespace를 구분할 수 없으므로 AppGroup cleanup 성공으로 보지 않는다.
func (p *buildPipeline) deleteNamedApplication(ctx context.Context, name, namespace string) error {
	applicationPath := p.applicationPath(name)
	namespacePath := "/api/v1/namespaces/" + url.PathEscape(namespace)
	deadline := time.Now().Add(time.Duration(deleteTimeoutSeconds) * time.Second)
	for {
		var application argoApplicationStatus
		status, err := p.do(ctx, http.MethodGet, applicationPath, nil, &application)
		if status == http.StatusNotFound {
			namespaceStatus, namespaceErr := p.do(ctx, http.MethodGet, namespacePath, nil, nil)
			if namespaceStatus == http.StatusNotFound {
				return nil
			}
			if namespaceErr != nil {
				return fmt.Errorf("AppGroup Namespace %s 삭제 상태 조회 실패: %w", namespace, namespaceErr)
			}
		}
		if err != nil && status != http.StatusNotFound {
			return err
		}
		if err == nil && application.Metadata.DeletionTimestamp == "" {
			if !containsString(application.Metadata.Finalizers, argoResourcesFinalizer) {
				finalizers := append(application.Metadata.Finalizers, argoResourcesFinalizer)
				patch := map[string]any{"metadata": map[string]any{"finalizers": finalizers}}
				if _, err := p.doWithContentType(ctx, http.MethodPatch, applicationPath,
					"application/merge-patch+json", patch, nil); err != nil {
					return fmt.Errorf("Argo Application %s finalizer 설정 실패: %w", name, err)
				}
			}
			if _, err := p.do(ctx, http.MethodDelete,
				applicationPath+"?propagationPolicy=Foreground", nil, nil); err != nil {
				return fmt.Errorf("Argo Application %s 삭제 실패: %w", name, err)
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Argo Application %s와 Namespace %s가 제한 시간(%d초) 안에 삭제되지 않았습니다",
				name, namespace, deleteTimeoutSeconds)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

func sleepContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// mergePullRequest는 required checks가 성공해 Forgejo가 명시 merge를 받아들일 때까지
// 재시도한다. merge_when_checks_succeed 예약은 timeout 뒤에도 나중에 병합될 수 있어,
// 포털이 failed로 끝낸 삭제 PR만 뒤늦게 적용되는 위험 때문에 사용하지 않는다.
func (f *forgejoClient) mergePullRequest(ctx context.Context, number int) error {
	payload := map[string]any{
		"Do":                        "merge",
		"delete_branch_after_merge": true,
		"merge_when_checks_succeed": false,
	}
	endpoint := fmt.Sprintf("%s/%d/merge", f.repoPath("pulls"), number)
	var lastErr error
	deadline := time.Now().Add(time.Duration(mergeTimeoutSeconds) * time.Second)
	for {
		detail, err := f.pullRequestStatus(ctx, number)
		if err == nil && detail.Merged {
			return nil
		}
		if err != nil {
			lastErr = err
		} else if detail.Head.SHA == "" {
			lastErr = errors.New("Forgejo PR 응답에 head commit SHA가 없습니다")
		} else {
			checks, checkErr := f.commitStatus(ctx, detail.Head.SHA)
			if checkErr != nil {
				lastErr = checkErr
			} else {
				switch strings.ToLower(checks.State) {
				case "failure", "error":
					return fmt.Errorf("Forgejo required checks가 %s 상태입니다", checks.State)
				case "success":
					err = f.do(ctx, http.MethodPost, endpoint, payload, nil)
					lastErr = err
				default:
					// check run이 아직 하나도 등록되지 않았을 때만 명시 merge를 한 번
					// 시도한다. branch protection이 준비 전 병합을 거부하며 예약은 남지 않는다.
					if checks.TotalCount == 0 && len(checks.Statuses) == 0 {
						err = f.do(ctx, http.MethodPost, endpoint, payload, nil)
						lastErr = err
					}
				}
			}
		}
		if merged, checkErr := f.pullRequestMerged(ctx, number); checkErr == nil && merged {
			return nil
		}
		if time.Now().After(deadline) {
			if lastErr != nil {
				return fmt.Errorf("Forgejo required checks/명시 병합 대기 제한 초과: %w", lastErr)
			}
			return fmt.Errorf("Forgejo PR #%d가 명시 merge 뒤 제한 시간 안에 merged 상태가 되지 않았습니다", number)
		}
		if err := sleepContext(ctx, buildPollInterval); err != nil {
			return err
		}
	}
}

type forgejoPullStatus struct {
	Merged bool   `json:"merged"`
	State  string `json:"state"`
	Head   struct {
		SHA string `json:"sha"`
	} `json:"head"`
}

func (f *forgejoClient) pullRequestStatus(ctx context.Context, number int) (forgejoPullStatus, error) {
	var detail forgejoPullStatus
	endpoint := fmt.Sprintf("%s/%d", f.repoPath("pulls"), number)
	if err := f.do(ctx, http.MethodGet, endpoint, nil, &detail); err != nil {
		return forgejoPullStatus{}, err
	}
	return detail, nil
}

type forgejoCombinedStatus struct {
	State      string `json:"state"`
	TotalCount int    `json:"total_count"`
	Statuses   []struct {
		Status string `json:"status"`
	} `json:"statuses"`
}

func (f *forgejoClient) commitStatus(ctx context.Context, sha string) (forgejoCombinedStatus, error) {
	var status forgejoCombinedStatus
	if sha == "" {
		return status, errors.New("Forgejo commit status 조회에 SHA가 없습니다")
	}
	if err := f.do(ctx, http.MethodGet, f.repoPath("commits", sha, "status"), nil, &status); err != nil {
		return forgejoCombinedStatus{}, err
	}
	return status, nil
}

func (f *forgejoClient) pullRequestMerged(ctx context.Context, number int) (bool, error) {
	detail, err := f.pullRequestStatus(ctx, number)
	return detail.Merged, err
}

func profileNeedsAppESO(profile normalizedProfile) bool {
	return len(profile.Configuration.SecretKeys) > 0 || profile.authMode() == authOIDC
}

func profileNeedsESO(profile normalizedProfile) bool {
	return profileNeedsAppESO(profile) || profile.App.Group != ""
}

// grantSecretAccess는 앱 Secret/OIDC와 AppGroup registry pull용 ESO 권한을 만든다.
// 어느 하나라도 필요한데 OpenBao가 없으면 PR merge 전에 실패해 fail-closed 한다.
func (f *forgejoClient) grantSecretAccess(ctx context.Context, request deploymentRequest) error {
	if !profileNeedsESO(request.Profile) {
		return nil
	}
	if f.openbao == nil {
		return errors.New("OpenBao client가 없어 필요한 ESO 권한을 만들 수 없음")
	}
	if profileNeedsAppESO(request.Profile) {
		if err := f.openbao.grantESOAccessAt(ctx, request.Profile, request.Profile.namespace(),
			request.Generated.OpenBaoPath); err != nil {
			return err
		}
	}
	if group, grouped := groupOf(request.Profile); grouped {
		if registryPullRemotePath == "" {
			return errors.New("PORTAL_REGISTRY_PULL_REMOTE_PATH가 비어 있음")
		}
		if err := f.openbao.grantGroupRegistryAccess(ctx, group, registryPullRemotePath); err != nil {
			return err
		}
	}
	f.logger.Printf("요청 %s 앱 ESO 접근 권한 설정 완료: %s",
		request.ID, request.Profile.App.Name)
	return nil
}

// advance는 PR이 열린 뒤의 자동 승인·빌드·배포 커밋을 수행한다.
// 자동 승인이 꺼져 있으면 아무것도 하지 않고 pr-open 상태를 유지한다.
func (f *forgejoClient) advance(ctx context.Context, request deploymentRequest) {
	if !autoApprove || request.PullRequest == nil {
		return
	}
	// Argo가 merge 직후 리소스를 만들 수 있으므로 ESO 권한은 반드시 merge 전에 준비한다.
	if err := f.grantSecretAccess(ctx, request); err != nil {
		f.failRequest(request, "앱 Secret 접근 권한 설정에 실패했습니다. 플랫폼 관리자에게 문의하세요.", err)
		return
	}
	if err := f.mergePullRequest(ctx, request.PullRequest.Number); err != nil {
		f.failRequest(request, "Pull Request 자동 승인에 실패했습니다. 저장소에서 직접 병합해 주세요.", err)
		return
	}
	request.PullRequest.State = "merged"
	request.State = stateMerged
	request.GitCommitted = true
	request.FailedFromState = ""
	request.Message = ""
	f.saveRequest(request)
	f.logger.Printf("요청 %s PR #%d 자동 병합 완료", request.ID, request.PullRequest.Number)

	if f.builder == nil {
		// 클러스터 밖(개발 환경)에서는 빌드 없이 병합까지만 한다.
		return
	}

	// source update는 PR 전에 build를 끝내고 존재하는 immutable tag만 diff에 넣었다.
	// merge 뒤에는 다시 빌드하거나 동일 파일을 no-op commit하지 않고 rollout만 확인한다.
	if request.SourceUpdate && request.Generated.Image != "" {
		revision, err := f.branchRevision(ctx, f.config.TargetBranch)
		if err != nil {
			f.failRequest(request, "배포 Git revision 확인에 실패했습니다.", err)
			return
		}
		request.State = stateDeploying
		request.Message = fmt.Sprintf("Argo CD가 %s에 새 source image를 배포하는 중입니다.", request.Profile.namespace())
		request.DesiredRevision = revision
		request.ApplicationSynced = false
		f.saveRequest(request)
		// Compose가 이미 만들어진 이미지를 지정했으면 빌드할 소스가 없다(postgres:16 등).
		// values에는 처음부터 그 이미지가 들어가 있으므로 태그 치환 커밋도 필요 없다.
	} else if prebuilt := request.Profile.Source.Image; prebuilt != "" {
		revision, err := f.branchRevision(ctx, f.config.TargetBranch)
		if err != nil {
			f.failRequest(request, "배포 Git revision 확인에 실패했습니다.", err)
			return
		}
		request.State = stateDeploying
		request.Message = fmt.Sprintf("Argo CD가 %s에 배포하는 중입니다.", request.Profile.namespace())
		request.Generated.Image = prebuilt
		request.DesiredRevision = revision
		request.ApplicationSynced = false
		f.saveRequest(request)
		f.logger.Printf("요청 %s 빌드 없이 배포: %s", request.ID, prebuilt)
	} else {
		if request.Profile.Source.Commit == "" {
			commit, tracked, err := f.trackedSourceCommit(ctx,
				request.Profile.Source.Repository, request.Profile.Source.Revision)
			if err != nil {
				f.failRequest(request, "빌드할 source commit 확인에 실패했습니다.", err)
				return
			}
			if tracked {
				request.Profile.Source.Commit = commit
				f.saveRequest(request)
			}
		}
		request.State = stateBuilding
		f.saveRequest(request)
		tag, err := f.builder.build(ctx, request)
		if err != nil {
			f.failRequest(request, "이미지 빌드에 실패했습니다. 소스와 Dockerfile을 확인해 주세요.", err)
			return
		}

		filePath := appValuesPath(request.Profile)
		values := strings.Replace(renderValuesYAML(request),
			"\"CHANGE_ME_COMMIT_SHA\"", yamlString(tag), 1)
		message := fmt.Sprintf("chore(%s): %s 이미지 태그 %s 반영",
			request.Profile.App.Name, request.Profile.App.Environment, tag)
		if err := f.putFile(ctx, f.config.TargetBranch, filePath, message, values); err != nil {
			f.failRequest(request, "이미지 태그 커밋에 실패했습니다. 플랫폼 관리자에게 문의하세요.", err)
			return
		}
		revision, err := f.branchRevision(ctx, f.config.TargetBranch)
		if err != nil {
			f.failRequest(request, "배포 Git revision 확인에 실패했습니다.", err)
			return
		}

		request.State = stateDeploying
		request.Message = fmt.Sprintf("Argo CD가 %s에 배포하는 중입니다.", request.Profile.namespace())
		request.Generated.Image = imageDestination(request, tag)
		request.DesiredRevision = revision
		request.ApplicationSynced = false
		f.saveRequest(request)
	}
	f.logger.Printf("요청 %s 배포 커밋 완료, rollout 대기: %s", request.ID, request.Generated.Image)
	// AppGroup 앱은 Namespace만 존재하는 것으로 충분하지 않다. app-of-apps의 sync wave와
	// 여기의 Synced/Healthy gate를 함께 써서 quota/default-deny baseline이 모두 적용된 뒤에만
	// 앱 Application을 재촉한다.
	if group, grouped := groupOf(request.Profile); grouped {
		f.builder.refreshApplication(ctx, argoBootstrapApplication)
		f.builder.refreshApplication(ctx, groupApplicationName(group))
		if err := f.builder.waitForGroupApplicationRevision(ctx, group, request.DesiredRevision); err != nil {
			f.failRequest(request, "AppGroup Namespace 보안 baseline이 준비되지 않았습니다.", err)
			return
		}
	}
	// 방금 태그를 커밋했으니 폴링 주기를 기다리지 않고 바로 동기화시킨다.
	f.builder.refreshApplication(ctx, appApplicationName(request.Profile))
	if err := f.builder.waitForApplicationRevision(ctx, request, request.DesiredRevision); err != nil {
		f.failRequest(request, "Argo CD가 배포 Git revision을 동기화하지 못했습니다.", err)
		return
	}
	request.ApplicationSynced = true
	f.saveRequest(request)
	if err := f.builder.waitForDeployment(ctx, request, request.Generated.Image); err != nil {
		f.failRequest(request, "배포가 준비되지 않았습니다. Secret 신청을 포함했다면 관리자에게 앱 Secret 접근 권한 설정을 요청하세요.", err)
		return
	}

	request.State = stateDeployed
	request.FailedFromState = ""
	request.Message = ""
	f.saveRequest(request)
	f.logger.Printf("요청 %s Zone 배포 완료: %s", request.ID, request.Generated.Image)
}

func (f *forgejoClient) deleteApp(ctx context.Context, request deploymentRequest) {
	group, grouped := groupOf(request.Profile)
	lastGroupApp := false
	if grouped {
		currentlyLast := !f.store.groupHasOtherAppsOwned(group.Name, group.Project,
			group.Environment, request.Requester, request.Profile.App.Name)
		// false -> true는 허용한다. 두 삭제 중 앞 요청이 실패한 사이 뒤 요청도 false로
		// 결정됐더라도, 재시도 시 실제 마지막 앱이면 Namespace를 결국 정리해야 한다.
		// true -> false는 생성 handler가 deletion flag 동안 새 앱을 막으므로 일어나지 않는다.
		upgradedToGroupCleanup := request.GroupCleanupDecided && !request.GroupCleanupPlanned && currentlyLast
		if !request.GroupCleanupDecided || upgradedToGroupCleanup {
			request.GroupCleanupDecided = true
			request.GroupCleanupPlanned = currentlyLast
			if upgradedToGroupCleanup {
				// app-only PR은 group bootstrap을 지우지 않는다. 범위가 커졌으면 group
				// suffix의 새 branch/PR로 다시 만들어 Git과 runtime cleanup 결정을 맞춘다.
				request.PullRequest = nil
			}
			f.saveRequest(request)
		}
		lastGroupApp = request.GroupCleanupPlanned
	}
	pullRequest := request.PullRequest
	if pullRequest == nil {
		var err error
		pullRequest, err = f.submitDeletion(ctx, request)
		if err != nil {
			f.failRequest(request, "GitOps 삭제 요청 생성에 실패했습니다. 잠시 후 다시 시도해 주세요.", err)
			return
		}
		request.PullRequest = pullRequest
		f.saveRequest(request)
	}
	if pullRequest != nil {
		if err := f.mergePullRequest(ctx, pullRequest.Number); err != nil {
			f.failRequest(request, "GitOps 삭제 요청 자동 승인에 실패했습니다.", err)
			return
		}
		request.PullRequest.State = "merged"
		f.saveRequest(request)
	}

	if f.builder != nil {
		revision, err := f.branchRevision(ctx, f.config.TargetBranch)
		if err != nil {
			f.failRequest(request, "삭제 커밋 확인에 실패했습니다.", err)
			return
		}
		if err := f.builder.waitForBootstrapRevision(ctx, revision); err != nil {
			f.failRequest(request, "Argo CD가 삭제 커밋을 확인하지 못했습니다.", err)
			return
		}
		if err := f.builder.deleteApplication(ctx, request); err != nil {
			f.failRequest(request, "애플리케이션 삭제에 실패했습니다.", err)
			return
		}
		// 앱이 사라진 뒤에만 Namespace 를 정리한다. 먼저 지우면 앱 리소스가 함께
		// 사라져 삭제 확인(appResourcesGone)이 무엇을 봤는지 알 수 없게 된다.
		if lastGroupApp {
			if err := f.builder.deleteNamedApplication(ctx, groupApplicationName(group), group.Namespace); err != nil {
				// Namespace baseline과 registry 권한까지 정리되어야 삭제가 끝난 것이다.
				// 실패를 성공으로 숨기면 이후 재시도 기회가 사라져 orphan Namespace가 남는다.
				f.failRequest(request, "AppGroup Namespace 정리에 실패했습니다. 잠시 후 다시 시도해 주세요.", err)
				return
			}
		}
	}

	// 권한 회수는 앱 리소스가 사라진 뒤에 한다. 권한이 필요한 앱에서 OpenBao가
	// 없거나 revoke가 실패하면 deleted로 확정하지 않아 재시작 후 다시 정리할 수 있다.
	if profileNeedsESO(request.Profile) && f.openbao == nil {
		f.failRequest(request, "앱 Secret 접근 권한을 회수하지 못했습니다. 플랫폼 관리자에게 문의하세요.",
			errors.New("OpenBao client가 없어 필요한 ESO 권한을 회수할 수 없음"))
		return
	}
	if profileNeedsAppESO(request.Profile) {
		if err := f.openbao.revokeESOAccessAt(ctx, request.Profile,
			request.Generated.OpenBaoPath); err != nil {
			f.failRequest(request, "앱 Secret 접근 권한을 회수하지 못했습니다. 플랫폼 관리자에게 문의하세요.", err)
			return
		}
	}
	if lastGroupApp {
		if err := f.openbao.revokeGroupRegistryAccess(ctx, group); err != nil {
			f.failRequest(request, "AppGroup registry 접근 권한을 회수하지 못했습니다. 플랫폼 관리자에게 문의하세요.", err)
			return
		}
	}

	request.State = stateDeleted
	request.Message = ""
	f.saveRequest(request)
	f.logger.Printf("요청 %s 앱 삭제 완료: %s", request.ID, request.Profile.App.Name)
}

func (f *forgejoClient) saveRequest(request deploymentRequest) {
	if err := f.store.update(request); err != nil {
		f.logger.Printf("요청 %s 상태 기록 실패: %v", request.ID, err)
	}
}

// failRequest는 사용자에게 보여줄 문구만 남기고 원인은 로그에만 적는다.
func (f *forgejoClient) failRequest(request deploymentRequest, message string, cause error) {
	request.FailedFromState = request.State
	request.State = stateFailed
	request.Message = message
	f.saveRequest(request)
	if cause != nil {
		f.logger.Printf("요청 %s 파이프라인 실패: %v", request.ID, cause)
	}
}
