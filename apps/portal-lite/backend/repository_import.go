package main

// Git 저장소를 AppGroup 입력으로 읽는다.
//
// 저장소의 manifest를 클러스터에 적용하지 않는다. Compose는 기존 제한 파서로,
// Helm Chart는 격리한 `helm template` 결과에서 표현 가능한 Deployment/Service만 읽고
// 다시 app-profile values로 만든다. 이 경계를 지켜야 Chart가 RBAC, hostPath, Secret을
// 몰래 추가하거나 기존 플랫폼 보안 기본값을 우회할 수 없다.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	maxRepositoryEntries = 2000
	maxChartFiles        = 200
	maxChartFileBytes    = 256 << 10
	maxChartTotalBytes   = 2 << 20
	maxHelmOutputBytes   = 2 << 20
	helmRenderTimeout    = 8 * time.Second
	helmReleaseName      = "portal-import"
)

var forgejoRepoSegmentPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`)
var gitCommitPattern = regexp.MustCompile(`^[a-f0-9]{40}([a-f0-9]{24})?$`)

// Helm 렌더는 외부 프로세스라 동시에 무제한 실행하면 작은 입력 여러 개로도 Portal Pod의
// CPU/메모리를 독점할 수 있다. HTTP timeout과 별개로 프로세스 수를 작게 고정한다.
var helmRenderSlots = make(chan struct{}, 2)

type appGroupSource struct {
	Type       string `json:"type"`
	Repository string `json:"repository,omitempty"`
	Revision   string `json:"revision,omitempty"`
	Path       string `json:"path,omitempty"`
}

type repositoryImport struct {
	Parsed composeFile
	Source appGroupSource
}

type repositoryImportError struct {
	Message   string
	Temporary bool
}

func (e repositoryImportError) Error() string { return e.Message }

type sourceRepositoryCoordinates struct {
	Owner string
	Repo  string
	URL   string
}

func parseSourceRepositoryURL(config forgejoConfig, raw string) (sourceRepositoryCoordinates, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return sourceRepositoryCoordinates{}, errors.New("Git 저장소 주소를 입력하세요.")
	}
	if len(raw) > 2048 {
		return sourceRepositoryCoordinates{}, errors.New("Git 저장소 주소가 너무 깁니다.")
	}
	candidate, err := url.Parse(raw)
	if err != nil || candidate.Scheme != "https" || candidate.Host == "" {
		return sourceRepositoryCoordinates{}, errors.New("HTTPS Forgejo 저장소 주소를 입력하세요.")
	}
	if candidate.User != nil || candidate.RawQuery != "" || candidate.Fragment != "" {
		return sourceRepositoryCoordinates{}, errors.New("주소에 계정, 토큰, query 또는 fragment를 넣을 수 없습니다.")
	}
	base, err := url.Parse(config.BaseURL)
	if err != nil || !strings.EqualFold(candidate.Host, base.Host) {
		return sourceRepositoryCoordinates{}, errors.New("현재 Portal에 설정된 Forgejo 호스트의 저장소만 사용할 수 있습니다.")
	}
	segments := strings.Split(strings.Trim(candidate.EscapedPath(), "/"), "/")
	if len(segments) != 2 {
		return sourceRepositoryCoordinates{}, errors.New("저장소 주소는 https://<FORGEJO>/<OWNER>/<REPOSITORY> 형식이어야 합니다.")
	}
	owner, ownerErr := url.PathUnescape(segments[0])
	repo, repoErr := url.PathUnescape(segments[1])
	repo = strings.TrimSuffix(repo, ".git")
	if ownerErr != nil || repoErr != nil || !forgejoRepoSegmentPattern.MatchString(owner) ||
		!forgejoRepoSegmentPattern.MatchString(repo) {
		return sourceRepositoryCoordinates{}, errors.New("저장소 owner 또는 이름 형식이 올바르지 않습니다.")
	}
	return sourceRepositoryCoordinates{
		Owner: owner,
		Repo:  repo,
		URL:   strings.TrimRight(config.BaseURL, "/") + "/" + owner + "/" + repo + ".git",
	}, nil
}

func isComposeCandidate(filePath string) bool {
	switch strings.ToLower(path.Base(filePath)) {
	case "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml":
		return true
	default:
		return false
	}
}

// selectRepositoryInput는 주소만으로도 동작하도록 최상위 표준 파일을 우선한다.
// 같은 우선순위에 후보가 여러 개면 임의로 고르지 않는다. 다른 파일이 배포되는 것보다
// 사용자가 저장소 구조를 명확하게 만드는 편이 안전하다.
func selectRepositoryInput(entries []forgejoTreeEntry) (kind, selected string, err error) {
	rootCompose := make([]string, 0)
	rootCharts := make([]string, 0)
	allCompose := make([]string, 0)
	allCharts := make([]string, 0)
	for _, entry := range entries {
		if entry.Type != "blob" {
			continue
		}
		clean := path.Clean(entry.Path)
		if clean != entry.Path || strings.HasPrefix(clean, "../") || strings.HasPrefix(clean, "/") {
			return "", "", errors.New("저장소에 안전하게 해석할 수 없는 파일 경로가 있습니다.")
		}
		if isComposeCandidate(clean) {
			allCompose = append(allCompose, clean)
			if !strings.Contains(clean, "/") {
				rootCompose = append(rootCompose, clean)
			}
		}
		if path.Base(clean) == "Chart.yaml" {
			allCharts = append(allCharts, clean)
			if clean == "Chart.yaml" {
				rootCharts = append(rootCharts, clean)
			}
		}
	}
	sort.Strings(rootCompose)
	sort.Strings(rootCharts)
	sort.Strings(allCompose)
	sort.Strings(allCharts)

	preferredCompose, preferredCharts := allCompose, allCharts
	if len(rootCompose) > 0 || len(rootCharts) > 0 {
		preferredCompose, preferredCharts = rootCompose, rootCharts
	}
	candidates := len(preferredCompose) + len(preferredCharts)
	if candidates == 0 {
		return "", "", errors.New("docker-compose.yml/compose.yaml 또는 Chart.yaml을 찾지 못했습니다.")
	}
	if candidates > 1 {
		paths := append(append([]string{}, preferredCompose...), preferredCharts...)
		return "", "", fmt.Errorf("자동 선택할 입력 파일이 여러 개입니다: %s", strings.Join(paths, ", "))
	}
	if len(preferredCompose) == 1 {
		return "compose", preferredCompose[0], nil
	}
	return "helm", preferredCharts[0], nil
}

func (f *forgejoClient) importRepository(ctx context.Context, rawURL, requestedRevision string) (repositoryImport, error) {
	coordinates, err := parseSourceRepositoryURL(f.config, rawURL)
	if err != nil {
		return repositoryImport{}, repositoryImportError{Message: err.Error()}
	}
	repository, err := f.sourceRepository(ctx, coordinates.Owner, coordinates.Repo)
	if err != nil {
		return repositoryImport{}, repositoryImportError{
			Message:   "Forgejo 저장소를 읽지 못했습니다. 주소와 Portal 봇의 읽기 권한을 확인하세요.",
			Temporary: forgejoStatus(err) == 0 || forgejoStatus(err) >= 500,
		}
	}
	defaultBranch := strings.TrimSpace(repository.DefaultBranch)
	if defaultBranch == "" || !branchPattern.MatchString(defaultBranch) {
		return repositoryImport{}, repositoryImportError{Message: "저장소 기본 브랜치를 확인할 수 없습니다."}
	}
	revision := strings.ToLower(strings.TrimSpace(requestedRevision))
	if revision != "" && !gitCommitPattern.MatchString(revision) {
		return repositoryImport{}, repositoryImportError{Message: "repositoryRevision은 검증 응답이 준 Git commit SHA여야 합니다."}
	}
	if revision == "" {
		revision, err = f.sourceBranchRevision(ctx, coordinates.Owner, coordinates.Repo, defaultBranch)
		revision = strings.ToLower(strings.TrimSpace(revision))
		if err != nil || !gitCommitPattern.MatchString(revision) {
			return repositoryImport{}, repositoryImportError{Message: "저장소 기본 브랜치 commit을 확인하지 못했습니다.", Temporary: true}
		}
	}
	entries, err := f.sourceTree(ctx, coordinates.Owner, coordinates.Repo, revision, maxRepositoryEntries)
	if err != nil {
		message := "저장소 파일 목록을 읽지 못했습니다."
		temporary := true
		if strings.Contains(err.Error(), "자동 탐색 상한") {
			message = err.Error()
			temporary = false
		}
		return repositoryImport{}, repositoryImportError{
			Message: message, Temporary: temporary,
		}
	}
	kind, selected, err := selectRepositoryInput(entries)
	if err != nil {
		return repositoryImport{}, repositoryImportError{Message: err.Error()}
	}
	source := appGroupSource{
		Type: kind, Repository: coordinates.URL, Revision: revision, Path: selected,
	}
	if kind == "compose" {
		document, readErr := f.sourceFile(ctx, coordinates.Owner, coordinates.Repo, selected, revision)
		if readErr != nil {
			return repositoryImport{}, repositoryImportError{Message: "Compose 파일을 읽지 못했습니다.", Temporary: true}
		}
		parsed, parseErr := parseCompose(document)
		if parseErr != nil {
			return repositoryImport{}, repositoryImportError{Message: selected + ": " + parseErr.Error()}
		}
		parsed.Warnings = append(parsed.Warnings,
			fmt.Sprintf("Git %s의 %s@%s에서 Compose를 읽었습니다.", coordinates.URL, selected, revision))
		return repositoryImport{Parsed: parsed, Source: source}, nil
	}

	parsed, renderErr := f.importHelmChart(ctx, coordinates, revision, selected, entries)
	if renderErr != nil {
		return repositoryImport{}, renderErr
	}
	parsed.Warnings = append(parsed.Warnings,
		fmt.Sprintf("Git %s의 %s@%s에서 Helm Chart를 읽었습니다.", coordinates.URL, path.Dir(selected), revision))
	return repositoryImport{Parsed: parsed, Source: source}, nil
}

type fetchedChartFile struct {
	Path    string
	Content string
}

func (f *forgejoClient) fetchChartFiles(
	ctx context.Context,
	coordinates sourceRepositoryCoordinates,
	revision, chartYAML string,
	entries []forgejoTreeEntry,
) ([]fetchedChartFile, error) {
	chartDir := path.Dir(chartYAML)
	if chartDir == "." {
		chartDir = ""
	}
	selected := make([]forgejoTreeEntry, 0)
	total := int64(0)
	for _, entry := range entries {
		inside := chartDir == "" || strings.HasPrefix(entry.Path, chartDir+"/")
		if !inside {
			continue
		}
		if entry.Mode == "120000" || entry.Type == "commit" {
			return nil, repositoryImportError{Message: "Helm Chart 안의 symlink와 Git submodule은 지원하지 않습니다."}
		}
		if entry.Type != "blob" {
			continue
		}
		if entry.Size < 0 || entry.Size > maxChartFileBytes {
			return nil, repositoryImportError{Message: fmt.Sprintf("Helm Chart 파일 %s가 %d KiB 제한을 넘습니다.", entry.Path, maxChartFileBytes>>10)}
		}
		total += entry.Size
		if total > maxChartTotalBytes {
			return nil, repositoryImportError{Message: "Helm Chart 전체 크기가 2 MiB 제한을 넘습니다."}
		}
		selected = append(selected, entry)
	}
	if len(selected) == 0 || len(selected) > maxChartFiles {
		return nil, repositoryImportError{Message: fmt.Sprintf("Helm Chart 파일은 1~%d개여야 합니다.", maxChartFiles)}
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		file fetchedChartFile
		err  error
	}
	jobs := make(chan forgejoTreeEntry)
	results := make(chan result, len(selected))
	workers := min(8, len(selected))
	var wait sync.WaitGroup
	for range workers {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for entry := range jobs {
				content, readErr := f.sourceFile(ctx, coordinates.Owner, coordinates.Repo, entry.Path, revision)
				select {
				case results <- result{file: fetchedChartFile{Path: entry.Path, Content: content}, err: readErr}:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	go func() {
		defer close(jobs)
		for _, entry := range selected {
			select {
			case jobs <- entry:
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() { wait.Wait(); close(results) }()

	files := make([]fetchedChartFile, 0, len(selected))
	actualTotal := 0
	for item := range results {
		if item.err != nil {
			cancel()
			return nil, repositoryImportError{Message: "Helm Chart 파일을 읽지 못했습니다.", Temporary: true}
		}
		if len(item.file.Content) > maxChartFileBytes {
			cancel()
			return nil, repositoryImportError{Message: fmt.Sprintf("Helm Chart 파일 %s가 %d KiB 제한을 넘습니다.", item.file.Path, maxChartFileBytes>>10)}
		}
		actualTotal += len(item.file.Content)
		if actualTotal > maxChartTotalBytes {
			cancel()
			return nil, repositoryImportError{Message: "Helm Chart 전체 크기가 2 MiB 제한을 넘습니다."}
		}
		files = append(files, item.file)
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return files, nil
}

type cappedBuffer struct {
	bytes.Buffer
	Limit int
}

func (b *cappedBuffer) Write(data []byte) (int, error) {
	if b.Len()+len(data) > b.Limit {
		remaining := max(b.Limit-b.Len(), 0)
		if remaining > 0 {
			_, _ = b.Buffer.Write(data[:remaining])
		}
		return remaining, errors.New("출력 크기 제한 초과")
	}
	return b.Buffer.Write(data)
}

func (f *forgejoClient) importHelmChart(
	ctx context.Context,
	coordinates sourceRepositoryCoordinates,
	revision, chartYAML string,
	entries []forgejoTreeEntry,
) (composeFile, error) {
	files, err := f.fetchChartFiles(ctx, coordinates, revision, chartYAML, entries)
	if err != nil {
		return composeFile{}, err
	}
	temporary, err := os.MkdirTemp("", "portal-helm-import-")
	if err != nil {
		return composeFile{}, repositoryImportError{Message: "Helm 임시 작업 공간을 만들지 못했습니다.", Temporary: true}
	}
	defer func() { _ = os.RemoveAll(temporary) }()

	chartDir := path.Dir(chartYAML)
	if chartDir == "." {
		chartDir = ""
	}
	for _, file := range files {
		relative := strings.TrimPrefix(strings.TrimPrefix(file.Path, chartDir), "/")
		clean := filepath.Clean(filepath.FromSlash(relative))
		if clean == "." || clean == ".." || filepath.IsAbs(clean) || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return composeFile{}, repositoryImportError{Message: "Helm Chart에 안전하지 않은 파일 경로가 있습니다."}
		}
		target := filepath.Join(temporary, "chart", clean)
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return composeFile{}, repositoryImportError{Message: "Helm 임시 디렉터리를 만들지 못했습니다.", Temporary: true}
		}
		if err := os.WriteFile(target, []byte(file.Content), 0o600); err != nil {
			return composeFile{}, repositoryImportError{Message: "Helm Chart 파일을 준비하지 못했습니다.", Temporary: true}
		}
	}

	select {
	case helmRenderSlots <- struct{}{}:
		defer func() { <-helmRenderSlots }()
	case <-ctx.Done():
		return composeFile{}, repositoryImportError{Message: "Helm 렌더 대기 중 요청이 취소되었습니다.", Temporary: true}
	}
	renderContext, cancel := context.WithTimeout(ctx, helmRenderTimeout)
	defer cancel()
	command := exec.CommandContext(renderContext, configured("PORTAL_HELM_BIN", "helm"),
		"template", helmReleaseName, filepath.Join(temporary, "chart"),
		"--namespace", "portal-import", "--no-hooks", "--skip-tests", "--skip-crds")
	command.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + temporary,
		"HELM_CACHE_HOME=" + filepath.Join(temporary, "cache"),
		"HELM_CONFIG_HOME=" + filepath.Join(temporary, "config"),
		"HELM_DATA_HOME=" + filepath.Join(temporary, "data"),
		"KUBECONFIG=" + filepath.Join(temporary, "no-kubeconfig"),
	}
	stdout := &cappedBuffer{Limit: maxHelmOutputBytes}
	stderr := &cappedBuffer{Limit: 16 << 10}
	command.Stdout = stdout
	command.Stderr = stderr
	if err := command.Run(); err != nil {
		if errors.Is(renderContext.Err(), context.DeadlineExceeded) {
			return composeFile{}, repositoryImportError{Message: "Helm 렌더가 8초 제한을 넘었습니다."}
		}
		if errors.Is(err, exec.ErrNotFound) {
			return composeFile{}, repositoryImportError{Message: "Portal에 Helm 실행기가 준비되지 않았습니다.", Temporary: true}
		}
		return composeFile{}, repositoryImportError{Message: "Helm Chart를 기본 values로 렌더링하지 못했습니다."}
	}
	parsed, parseErr := parseHelmManifests(stdout.Bytes())
	if parseErr != nil {
		return composeFile{}, repositoryImportError{Message: parseErr.Error()}
	}
	return parsed, nil
}

type helmIntOrString struct {
	Int    int
	String string
	Set    bool
}

func (value *helmIntOrString) UnmarshalYAML(node *yaml.Node) error {
	value.Set = true
	if node.Tag == "!!int" {
		parsed, err := strconv.Atoi(node.Value)
		if err != nil {
			return err
		}
		value.Int = parsed
		return nil
	}
	value.String = node.Value
	return nil
}

type helmManifest struct {
	Kind     string `yaml:"kind"`
	Metadata struct {
		Name        string            `yaml:"name"`
		Labels      map[string]string `yaml:"labels"`
		Annotations map[string]string `yaml:"annotations"`
	} `yaml:"metadata"`
	Spec struct {
		Replicas *int `yaml:"replicas"`
		// Service selector는 {label: value}지만 Deployment selector는 표준적으로
		// {matchLabels: {...}}다. 같은 필드를 string map으로 읽으면 정상 Deployment가
		// YAML decode 단계에서 실패하므로 원형을 보존하고 Service일 때만 좁혀 읽는다.
		Selector map[string]any `yaml:"selector"`
		Ports    []struct {
			Name       string          `yaml:"name"`
			Port       int             `yaml:"port"`
			TargetPort helmIntOrString `yaml:"targetPort"`
			Protocol   string          `yaml:"protocol"`
		} `yaml:"ports"`
		Template struct {
			Metadata struct {
				Labels map[string]string `yaml:"labels"`
			} `yaml:"metadata"`
			Spec struct {
				HostNetwork        bool             `yaml:"hostNetwork"`
				HostPID            bool             `yaml:"hostPID"`
				HostIPC            bool             `yaml:"hostIPC"`
				ServiceAccountName string           `yaml:"serviceAccountName"`
				InitContainers     []map[string]any `yaml:"initContainers"`
				Volumes            []map[string]any `yaml:"volumes"`
				Containers         []struct {
					Name         string           `yaml:"name"`
					Image        string           `yaml:"image"`
					Command      []string         `yaml:"command"`
					Args         []string         `yaml:"args"`
					EnvFrom      []map[string]any `yaml:"envFrom"`
					VolumeMounts []map[string]any `yaml:"volumeMounts"`
					Ports        []struct {
						Name          string `yaml:"name"`
						ContainerPort int    `yaml:"containerPort"`
						Protocol      string `yaml:"protocol"`
					} `yaml:"ports"`
					Env []struct {
						Name      string         `yaml:"name"`
						Value     string         `yaml:"value"`
						ValueFrom map[string]any `yaml:"valueFrom"`
					} `yaml:"env"`
					SecurityContext map[string]any `yaml:"securityContext"`
				} `yaml:"containers"`
			} `yaml:"spec"`
		} `yaml:"template"`
	} `yaml:"spec"`
}

func parseHelmManifests(document []byte) (composeFile, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(document))
	objects := make([]helmManifest, 0)
	ignoredKinds := make(map[string]struct{})
	documentNumber := 0
	for {
		var object helmManifest
		err := decoder.Decode(&object)
		if errors.Is(err, io.EOF) {
			break
		}
		documentNumber++
		if err != nil {
			return composeFile{}, fmt.Errorf("Helm 렌더 결과의 %d번째 YAML 문서를 해석하지 못했습니다: %v", documentNumber, err)
		}
		if object.Kind == "" {
			continue
		}
		switch object.Kind {
		case "Deployment", "Service":
			objects = append(objects, object)
		case "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod", "ReplicaSet", "ReplicationController":
			return composeFile{}, fmt.Errorf("Helm Chart의 %s workload는 app-profile로 안전하게 변환할 수 없습니다.", object.Kind)
		default:
			ignoredKinds[object.Kind] = struct{}{}
		}
	}

	services := make([]helmManifest, 0)
	workloads := make([]helmManifest, 0)
	for _, object := range objects {
		if object.Kind == "Service" {
			services = append(services, object)
		} else {
			workloads = append(workloads, object)
		}
	}
	if len(workloads) == 0 {
		return composeFile{}, errors.New("Helm Chart에서 Deployment를 찾지 못했습니다.")
	}
	if len(workloads) > maxGroupServices {
		return composeFile{}, fmt.Errorf("Helm Chart의 Deployment는 최대 %d개까지 변환할 수 있습니다.", maxGroupServices)
	}

	parsed := composeFile{Services: make([]composeService, 0, len(workloads)), Warnings: []string{}}
	seen := make(map[string]struct{}, len(workloads))
	for _, workload := range workloads {
		service, err := helmWorkloadService(workload, services)
		if err != nil {
			return composeFile{}, err
		}
		if _, duplicate := seen[service.Name]; duplicate {
			return composeFile{}, fmt.Errorf("Helm Chart에서 변환한 앱 이름 %s가 중복됩니다.", service.Name)
		}
		seen[service.Name] = struct{}{}
		parsed.Services = append(parsed.Services, service)
		if service.Port == 0 {
			parsed.Warnings = append(parsed.Warnings, service.Name+": 연결된 Service가 없어 worker로 변환합니다.")
		}
	}
	sort.Slice(parsed.Services, func(i, j int) bool { return parsed.Services[i].Name < parsed.Services[j].Name })
	if len(ignoredKinds) > 0 {
		kinds := make([]string, 0, len(ignoredKinds))
		for kind := range ignoredKinds {
			kinds = append(kinds, kind)
		}
		sort.Strings(kinds)
		parsed.Warnings = append(parsed.Warnings,
			"Chart의 다음 리소스는 적용하지 않고 app-profile이 다시 생성합니다: "+strings.Join(kinds, ", "))
	}
	return parsed, nil
}

func helmWorkloadService(workload helmManifest, services []helmManifest) (composeService, error) {
	rawName := strings.ToLower(strings.TrimSpace(workload.Metadata.Name))
	name := strings.TrimPrefix(rawName, helmReleaseName+"-")
	if len(name) > 40 || !appNamePattern.MatchString(name) || reservedAppName(name) {
		return composeService{}, fmt.Errorf("Helm Deployment %s를 40자 이하의 허용된 앱 이름으로 변환할 수 없습니다.", workload.Metadata.Name)
	}
	pod := workload.Spec.Template.Spec
	if pod.HostNetwork || pod.HostPID || pod.HostIPC {
		return composeService{}, fmt.Errorf("Helm Deployment %s의 host namespace 설정은 지원하지 않습니다.", workload.Metadata.Name)
	}
	if pod.ServiceAccountName != "" && pod.ServiceAccountName != "default" {
		return composeService{}, fmt.Errorf("Helm Deployment %s의 ServiceAccount/RBAC 의존은 지원하지 않습니다.", workload.Metadata.Name)
	}
	if len(pod.InitContainers) > 0 || len(pod.Volumes) > 0 {
		return composeService{}, fmt.Errorf("Helm Deployment %s의 initContainer/volume은 지원하지 않습니다.", workload.Metadata.Name)
	}
	if len(pod.Containers) != 1 {
		return composeService{}, fmt.Errorf("Helm Deployment %s는 컨테이너가 정확히 하나여야 합니다.", workload.Metadata.Name)
	}
	container := pod.Containers[0]
	if len(container.Command) > 0 || len(container.Args) > 0 || len(container.EnvFrom) > 0 || len(container.VolumeMounts) > 0 {
		return composeService{}, fmt.Errorf("Helm Deployment %s의 command/args/envFrom/volumeMount는 app-profile로 보존할 수 없습니다.", workload.Metadata.Name)
	}
	if privileged, ok := container.SecurityContext["privileged"].(bool); ok && privileged {
		return composeService{}, fmt.Errorf("Helm Deployment %s의 privileged 컨테이너는 지원하지 않습니다.", workload.Metadata.Name)
	}
	result := composeService{Name: name, Image: strings.TrimSpace(container.Image), Config: map[string]string{}}
	if workload.Spec.Replicas != nil {
		if *workload.Spec.Replicas < 1 {
			return composeService{}, fmt.Errorf("Helm Deployment %s의 replicas는 1 이상이어야 합니다.", workload.Metadata.Name)
		}
		result.Replicas = *workload.Spec.Replicas
	}
	if result.Image == "" {
		return composeService{}, fmt.Errorf("Helm Deployment %s에 컨테이너 image가 없습니다.", workload.Metadata.Name)
	}
	for _, item := range container.Env {
		if !envKeyPattern.MatchString(item.Name) || len(item.Name) > 128 {
			return composeService{}, fmt.Errorf("Helm Deployment %s의 env key %s 형식이 올바르지 않습니다.", workload.Metadata.Name, item.Name)
		}
		if len(item.ValueFrom) > 0 || sensitiveEnvKeyPattern.MatchString(item.Name) {
			return composeService{}, fmt.Errorf("Helm Deployment %s의 Secret/valueFrom 환경변수 %s는 자동 import하지 않습니다. OpenBao key로 별도 선언하세요.", workload.Metadata.Name, item.Name)
		}
		if len(item.Value) > maxAppEnvValueBytes {
			return composeService{}, fmt.Errorf("Helm Deployment %s의 환경변수 %s가 너무 깁니다.", workload.Metadata.Name, item.Name)
		}
		result.Config[item.Name] = item.Value
	}
	if len(result.Config) > maxAppEnvVars {
		return composeService{}, fmt.Errorf("Helm Deployment %s의 환경변수는 최대 %d개까지 지원합니다.", workload.Metadata.Name, maxAppEnvVars)
	}

	matching := make([]helmManifest, 0, 1)
	for _, candidate := range services {
		if selectorMatches(candidate.Spec.Selector, workload.Spec.Template.Metadata.Labels) {
			matching = append(matching, candidate)
		}
	}
	if len(matching) > 1 {
		return composeService{}, fmt.Errorf("Helm Deployment %s에 Service가 여러 개 연결되어 포트를 자동 선택할 수 없습니다.", workload.Metadata.Name)
	}
	if len(matching) == 0 {
		result.Port = 0
		return result, nil
	}
	service := matching[0]
	if len(service.Spec.Ports) != 1 {
		return composeService{}, fmt.Errorf("Helm Service %s는 TCP 포트가 정확히 하나여야 합니다.", service.Metadata.Name)
	}
	servicePort := service.Spec.Ports[0]
	if servicePort.Protocol != "" && !strings.EqualFold(servicePort.Protocol, "TCP") {
		return composeService{}, fmt.Errorf("Helm Service %s의 UDP/SCTP 포트는 지원하지 않습니다.", service.Metadata.Name)
	}
	result.Port = servicePort.Port
	if servicePort.TargetPort.Set && servicePort.TargetPort.Int > 0 {
		result.Port = servicePort.TargetPort.Int
	} else if servicePort.TargetPort.String != "" {
		result.Port = 0
		for _, port := range container.Ports {
			if port.Name == servicePort.TargetPort.String {
				result.Port = port.ContainerPort
				break
			}
		}
		if result.Port == 0 {
			return composeService{}, fmt.Errorf("Helm Service %s의 named targetPort %s를 컨테이너에서 찾지 못했습니다.", service.Metadata.Name, servicePort.TargetPort.String)
		}
	}
	if result.Port < 1 || result.Port > 65535 {
		return composeService{}, fmt.Errorf("Helm Service %s의 targetPort가 1~65535 범위가 아닙니다.", service.Metadata.Name)
	}
	return result, nil
}

func selectorMatches(selector map[string]any, labels map[string]string) bool {
	if len(selector) == 0 || len(labels) == 0 {
		return false
	}
	for key, rawValue := range selector {
		value, ok := rawValue.(string)
		if !ok {
			return false
		}
		if labels[key] != value {
			return false
		}
	}
	return true
}
