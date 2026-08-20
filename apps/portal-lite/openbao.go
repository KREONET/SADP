package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type openBaoClient struct {
	baseURL *url.URL
	http    *http.Client
	jwtPath string
	role    string
	mu      sync.Mutex
	token   string
	expires time.Time
}

const (
	openBaoWorkloadPolicy       = "portal-workload-secret-reader"
	openBaoRegistryPolicy       = "portal-registry-pull-reader"
	openBaoZoneRole             = "portal-zone-app-eso"
	openBaoGroupRole            = "portal-group-app-eso"
	openBaoGroupRegistryRole    = "portal-group-registry-eso"
	openBaoKubernetesAudience   = "vault"
	openBaoRegistryRequiredKey  = "dockerconfigjson"
	openBaoGroupNamespaceLabel  = "platform.example.io/app-group"
	openBaoReadResponseMaxBytes = 1 << 20
)

var (
	openBaoPolicyBlockPattern            = regexp.MustCompile(`(?s)path\s+"([^"]+)"\s*\{([^{}]*)\}`)
	openBaoReadBodyPattern               = regexp.MustCompile(`^\s*capabilities\s*=\s*\[\s*"read"\s*\]\s*$`)
	openBaoLegacyMetadataReadBodyPattern = regexp.MustCompile(
		`^\s*capabilities\s*=\s*\[\s*"read"\s*(,\s*"list"\s*)?\]\s*$`)
)

type openBaoHTTPError struct {
	Method string
	Path   string
	Status int
}

func (e *openBaoHTTPError) Error() string {
	return fmt.Sprintf("OpenBao %s %s HTTP %d", e.Method, e.Path, e.Status)
}

func openBaoStatus(err error) int {
	var apiError *openBaoHTTPError
	if errors.As(err, &apiError) {
		return apiError.Status
	}
	return 0
}

func newOpenBaoClient(address, caPath, jwtPath, role string) (*openBaoClient, error) {
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return nil, errors.New("PORTAL_OPENBAO_ADDR는 올바른 https URL이어야 합니다")
	}
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("OpenBao CA 읽기: %w", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("OpenBao CA 인증서 해석 실패")
	}
	return &openBaoClient{
		baseURL: parsed, jwtPath: jwtPath, role: role,
		http: &http.Client{Timeout: 8 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}},
	}, nil
}

func (c *openBaoClient) login(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Before(c.expires) {
		return c.token, nil
	}
	jwt, err := os.ReadFile(c.jwtPath)
	if err != nil {
		return "", fmt.Errorf("service account token 읽기: %w", err)
	}
	payload, _ := json.Marshal(map[string]string{"role": c.role, "jwt": strings.TrimSpace(string(jwt))})
	request, _ := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL.JoinPath("v1/auth/kubernetes/login").String(), bytes.NewReader(payload))
	request.Header.Set("Content-Type", "application/json")
	response, err := c.http.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("OpenBao login HTTP %d", response.StatusCode)
	}
	var result struct {
		Auth struct {
			ClientToken   string `json:"client_token"`
			LeaseDuration int    `json:"lease_duration"`
		} `json:"auth"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil || result.Auth.ClientToken == "" {
		return "", errors.New("OpenBao login 응답에 token이 없습니다")
	}
	c.token = result.Auth.ClientToken
	ttl := time.Duration(result.Auth.LeaseDuration) * time.Second
	if ttl <= time.Minute {
		ttl = 5 * time.Minute
	}
	c.expires = time.Now().Add(ttl - 30*time.Second)
	return c.token, nil
}

// do는 토큰을 붙여 한 번 호출한다. 404는 delete를 멱등하게 만들려고 성공으로 본다.
func (c *openBaoClient) do(ctx context.Context, method, apiPath string, payload any) error {
	return c.doWithContentType(ctx, method, apiPath, payload, "application/json")
}

func (c *openBaoClient) doWithContentType(ctx context.Context, method, apiPath string, payload any, contentType string) error {
	token, err := c.login(ctx)
	if err != nil {
		return err
	}
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		body = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, c.baseURL.JoinPath(apiPath).String(), body)
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", contentType)
	request.Header.Set("X-Vault-Token", token)
	response, err := c.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if method == http.MethodDelete && response.StatusCode == http.StatusNotFound {
		return nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return &openBaoHTTPError{Method: method, Path: apiPath, Status: response.StatusCode}
	}
	return nil
}

// getJSON은 readiness에 필요한 구조만 읽는다. 호출자는 Secret 값이 없는 policy,
// role, KV metadata/subkeys endpoint만 넘겨야 한다. 응답 본문은 오류에 포함하지 않는다.
func (c *openBaoClient) getJSON(ctx context.Context, apiPath string, query url.Values, target any) error {
	token, err := c.login(ctx)
	if err != nil {
		return err
	}
	endpoint := c.baseURL.JoinPath(apiPath)
	endpoint.RawQuery = query.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-Vault-Token", token)
	response, err := c.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return &openBaoHTTPError{Method: http.MethodGet, Path: apiPath, Status: response.StatusCode}
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, openBaoReadResponseMaxBytes))
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("OpenBao GET %s 응답 해석 실패", apiPath)
	}
	return nil
}

func (c *openBaoClient) put(ctx context.Context, path string, values map[string]string) error {
	rawPath := path
	path, err := normalizeOpenBaoRemotePath(path)
	if err != nil {
		return fmt.Errorf("OpenBao Secret 경로가 올바르지 않음: %q", rawPath)
	}
	apiPath := "v1/kv/data/" + path
	payload := map[string]any{"data": values}
	// KV v2 merge PATCH는 제출하지 않은 기존 key를 보존한다. Secret 경로가 없을 때만
	// POST로 새 문서를 만들어, 재배포가 다른 key를 통째로 지우지 않게 한다.
	err = c.doWithContentType(ctx, http.MethodPatch, apiPath, payload, "application/merge-patch+json")
	if openBaoStatus(err) == http.StatusNotFound {
		return c.do(ctx, http.MethodPost, apiPath, payload)
	}
	return err
}

// 구버전 신청 기록의 Generated.OpenBaoPath는 UI용 mount 접두사까지 포함한
// kv/apps/... 형식이었다. OpenBao KV v2 API는 mount 이후 경로만 받으므로 resume/delete
// 시 한 번만 걷어낸다. 신규 경로와 그 외 입력은 그대로 엄격 검증한다.
func normalizeOpenBaoRemotePath(value string) (string, error) {
	if strings.HasPrefix(value, "kv/apps/") {
		value = strings.TrimPrefix(value, "kv/")
	}
	if !validOpenBaoRemotePath(value) {
		return "", errors.New("invalid OpenBao remote path")
	}
	return value, nil
}

// esoAccessNames는 Chart가 기대하는 고정 role, ServiceAccount, KV 경로를 한곳에서
// 만든다. role은 bootstrap이 한 번 설치한다. 포털이 요청마다 policy/role을 쓰게 하면
// role 이름을 제한해도 임의 policy 본문으로 OpenBao 관리자 권한을 만들 수 있다.
func esoAccessNames(profile normalizedProfile) (role, serviceAccount, secretPath string, err error) {
	for _, part := range []string{profile.App.Project, profile.App.Environment, profile.App.Name} {
		if !appNamePattern.MatchString(part) {
			return "", "", "", fmt.Errorf("OpenBao 이름에 쓸 수 없는 값: %q", part)
		}
	}
	if openbaoZoneAppRole != openBaoZoneRole || openbaoGroupAppRole != openBaoGroupRole {
		return "", "", "", errors.New("Portal OpenBao workload role 설정이 플랫폼 고정 role 계약과 다름")
	}
	role = openBaoZoneRole
	serviceAccount = "eso-" + profile.App.Name
	if profile.App.Group != "" {
		if !appNamePattern.MatchString(profile.App.Group) {
			return "", "", "", fmt.Errorf("OpenBao 그룹 이름에 쓸 수 없는 값: %q", profile.App.Group)
		}
		role = openBaoGroupRole
		serviceAccount = typedDNSName("eso-sa-a-", profile.App.Name, canonicalAppID(profile))
	}
	secretPath = fmt.Sprintf("apps/%s/%s/workloads/%s/%s", profile.App.Project,
		profile.App.Environment, profile.namespace(), serviceAccount)
	return role, serviceAccount, secretPath, nil
}

type esoAccessContract struct {
	Role           string
	ServiceAccount string
	SecretPath     string
	Legacy         bool
}

// resolveESOAccessContract는 저장된 신청 경로를 현재 canonical 계약 또는 기존 단일 앱
// exact 계약 중 하나에만 결합한다. PVC 레코드가 변조되거나 두 계약을 섞으면 OpenBao
// preflight와 삭제 어느 쪽에서도 임의 경로를 만질 수 없다.
func resolveESOAccessContract(profile normalizedProfile, storedPath string) (esoAccessContract, error) {
	role, serviceAccount, canonicalPath, err := esoAccessNames(profile)
	if err != nil {
		return esoAccessContract{}, err
	}
	if storedPath == "" {
		storedPath = canonicalPath
	}
	remotePath, err := normalizeOpenBaoRemotePath(storedPath)
	if err != nil {
		return esoAccessContract{}, err
	}
	if remotePath == canonicalPath {
		return esoAccessContract{Role: role, ServiceAccount: serviceAccount, SecretPath: remotePath}, nil
	}
	if profile.App.Group != "" {
		return esoAccessContract{}, errors.New("AppGroup은 기존 단일 앱 OpenBao 경로를 사용할 수 없음")
	}
	legacyPath := fmt.Sprintf("apps/%s/%s/%s", profile.App.Project,
		profile.App.Environment, profile.App.Name)
	if remotePath != legacyPath {
		return esoAccessContract{}, fmt.Errorf("저장된 OpenBao 경로가 앱 identity와 다름: %q", remotePath)
	}
	return esoAccessContract{
		Role:           fmt.Sprintf("eso-%s-%s-%s", profile.App.Project, profile.App.Environment, profile.App.Name),
		ServiceAccount: serviceAccount,
		SecretPath:     remotePath,
		Legacy:         true,
	}, nil
}

func groupRegistryAccessNames(group appGroup) (role, serviceAccount string, err error) {
	for _, part := range []string{group.Project, group.Environment, group.Name} {
		if !appNamePattern.MatchString(part) {
			return "", "", fmt.Errorf("OpenBao AppGroup 이름에 쓸 수 없는 값: %q", part)
		}
	}
	if openbaoGroupRegistryRole != openBaoGroupRegistryRole {
		return "", "", errors.New("Portal OpenBao registry role 설정이 플랫폼 고정 role 계약과 다름")
	}
	return openBaoGroupRegistryRole, "eso-registry", nil
}

func validOpenBaoRemotePath(value string) bool {
	if value == "" || strings.HasPrefix(value, "/") || strings.HasSuffix(value, "/") || strings.Contains(value, "..") {
		return false
	}
	for _, part := range strings.Split(value, "/") {
		if !appNamePattern.MatchString(part) {
			return false
		}
	}
	return true
}

type openBaoACLPolicyResponse struct {
	Data struct {
		Name   string `json:"name"`
		Policy string `json:"policy"`
		Rules  string `json:"rules"`
	} `json:"data"`
}

type openBaoStringList []string

func (values *openBaoStringList) UnmarshalJSON(encoded []byte) error {
	var list []string
	if err := json.Unmarshal(encoded, &list); err == nil {
		*values = list
		return nil
	}
	var joined string
	if err := json.Unmarshal(encoded, &joined); err != nil {
		return err
	}
	if strings.TrimSpace(joined) == "" {
		*values = []string{}
		return nil
	}
	for _, value := range strings.Split(joined, ",") {
		list = append(list, strings.TrimSpace(value))
	}
	*values = list
	return nil
}

type openBaoKubernetesRoleResponse struct {
	Data struct {
		BoundServiceAccountNames      openBaoStringList `json:"bound_service_account_names"`
		BoundServiceAccountNamespaces openBaoStringList `json:"bound_service_account_namespaces"`
		NamespaceSelector             json.RawMessage   `json:"bound_service_account_namespace_selector"`
		Audience                      string            `json:"audience"`
		TokenPolicies                 openBaoStringList `json:"token_policies"`
		Policies                      openBaoStringList `json:"policies"`
	} `json:"data"`
}

type openBaoKubernetesRoleContract struct {
	ServiceAccounts   []string
	Namespaces        []string
	NamespaceSelector string
	Policy            string
}

type openBaoKVMetadataResponse struct {
	Data struct {
		CurrentVersion int `json:"current_version"`
		Versions       map[string]struct {
			DeletionTime string `json:"deletion_time"`
			Destroyed    bool   `json:"destroyed"`
		} `json:"versions"`
	} `json:"data"`
}

type openBaoKVSubkeysResponse struct {
	Subkeys map[string]json.RawMessage `json:"subkeys"`
	Data    struct {
		Subkeys map[string]json.RawMessage `json:"subkeys"`
	} `json:"data"`
}

func exactStrings(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	counts := make(map[string]int, len(want))
	for _, value := range want {
		counts[value]++
	}
	for _, value := range got {
		counts[value]--
		if counts[value] < 0 {
			return false
		}
	}
	for _, count := range counts {
		if count != 0 {
			return false
		}
	}
	return true
}

func canonicalJSON(raw json.RawMessage) (string, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) || bytes.Equal(trimmed, []byte(`""`)) {
		return "", nil
	}
	if trimmed[0] == '"' {
		var encoded string
		if err := json.Unmarshal(trimmed, &encoded); err != nil {
			return "", err
		}
		trimmed = bytes.TrimSpace([]byte(encoded))
		if len(trimmed) == 0 {
			return "", nil
		}
	}
	var value any
	if err := json.Unmarshal(trimmed, &value); err != nil {
		return "", err
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}

func (c *openBaoClient) requireKubernetesRole(ctx context.Context, role, description string,
	expected openBaoKubernetesRoleContract) error {
	var response openBaoKubernetesRoleResponse
	if err := c.getJSON(ctx, "v1/auth/kubernetes/role/"+role, nil, &response); err != nil {
		return fmt.Errorf("%s 확인 실패: %w", description, err)
	}
	selector, err := canonicalJSON(response.Data.NamespaceSelector)
	if err != nil {
		return fmt.Errorf("%s Namespace selector 해석 실패", description)
	}
	policies := []string(response.Data.TokenPolicies)
	if policies == nil {
		policies = []string(response.Data.Policies)
	} else if response.Data.Policies != nil && !exactStrings([]string(response.Data.Policies), policies) {
		return fmt.Errorf("%s 의 policies/token_policies 응답이 서로 다름", description)
	}
	if !exactStrings([]string(response.Data.BoundServiceAccountNames), expected.ServiceAccounts) ||
		!exactStrings([]string(response.Data.BoundServiceAccountNamespaces), expected.Namespaces) ||
		selector != expected.NamespaceSelector ||
		response.Data.Audience != openBaoKubernetesAudience ||
		!exactStrings(policies, []string{expected.Policy}) {
		return fmt.Errorf("%s 가 플랫폼 SA/Namespace/audience/policy 계약과 다름", description)
	}
	return nil
}

func readOnlyPolicyPaths(policy string) ([]string, error) {
	matches := openBaoPolicyBlockPattern.FindAllStringSubmatch(policy, -1)
	if len(matches) == 0 || strings.TrimSpace(openBaoPolicyBlockPattern.ReplaceAllString(policy, "")) != "" {
		return nil, errors.New("policy path block 이외의 규칙이 있음")
	}
	paths := make([]string, 0, len(matches))
	for _, match := range matches {
		if !openBaoReadBodyPattern.MatchString(match[2]) {
			return nil, errors.New("read 이외 capability가 있음")
		}
		paths = append(paths, match[1])
	}
	return paths, nil
}

func (c *openBaoClient) readACLPolicy(ctx context.Context, name, description string) ([]string, error) {
	var response openBaoACLPolicyResponse
	if err := c.getJSON(ctx, "v1/sys/policies/acl/"+name, nil, &response); err != nil {
		return nil, fmt.Errorf("%s 확인 실패: %w", description, err)
	}
	policy := response.Data.Policy
	if policy == "" {
		policy = response.Data.Rules
	}
	paths, err := readOnlyPolicyPaths(policy)
	if err != nil {
		return nil, fmt.Errorf("%s 가 read-only exact-path 계약과 다름", description)
	}
	return paths, nil
}

func (c *openBaoClient) requireRegistryPolicy(ctx context.Context, remotePath string) error {
	paths, err := c.readACLPolicy(ctx, openBaoRegistryPolicy, "고정 registry ESO policy")
	if err != nil {
		return err
	}
	want := []string{"kv/data/" + remotePath, "kv/metadata/" + remotePath}
	if !exactStrings(paths, want) {
		return errors.New("고정 registry ESO policy가 registry exact path 계약과 다름")
	}
	return nil
}

func (c *openBaoClient) requireWorkloadPolicy(ctx context.Context, profile normalizedProfile) error {
	paths, err := c.readACLPolicy(ctx, openBaoWorkloadPolicy, "고정 workload ESO policy")
	if err != nil {
		return err
	}
	if len(paths) != 2 {
		return errors.New("고정 workload ESO policy가 workload exact path 계약과 다름")
	}
	prefix := fmt.Sprintf("apps/%s/%s/workloads/", profile.App.Project, profile.App.Environment)
	pathPattern := regexp.MustCompile(`^kv/(data|metadata)/` + regexp.QuoteMeta(prefix) +
		`\{\{identity\.entity\.aliases\.([A-Za-z0-9_-]+)\.metadata\.service_account_namespace\}\}/` +
		`\{\{identity\.entity\.aliases\.([A-Za-z0-9_-]+)\.metadata\.service_account_name\}\}$`)
	kinds := map[string]bool{}
	accessor := ""
	for _, path := range paths {
		match := pathPattern.FindStringSubmatch(path)
		if match == nil || match[2] != match[3] || kinds[match[1]] || (accessor != "" && accessor != match[2]) {
			return errors.New("고정 workload ESO policy가 workload exact path 계약과 다름")
		}
		kinds[match[1]] = true
		accessor = match[2]
	}
	if !kinds["data"] || !kinds["metadata"] {
		return errors.New("고정 workload ESO policy가 workload exact path 계약과 다름")
	}
	return nil
}

func (c *openBaoClient) requireLegacyWorkloadPolicy(ctx context.Context,
	contract esoAccessContract) error {
	var response openBaoACLPolicyResponse
	if err := c.getJSON(ctx, "v1/sys/policies/acl/"+contract.Role, nil, &response); err != nil {
		return fmt.Errorf("기존 단일 앱 ESO policy 확인 실패: %w", err)
	}
	policy := response.Data.Policy
	if policy == "" {
		policy = response.Data.Rules
	}
	matches := openBaoPolicyBlockPattern.FindAllStringSubmatch(policy, -1)
	if len(matches) != 2 || strings.TrimSpace(openBaoPolicyBlockPattern.ReplaceAllString(policy, "")) != "" {
		return errors.New("기존 단일 앱 ESO policy가 exact read-only 계약과 다름")
	}
	wantData := "kv/data/" + contract.SecretPath
	wantMetadata := "kv/metadata/" + contract.SecretPath
	seen := map[string]bool{}
	for _, match := range matches {
		switch match[1] {
		case wantData:
			if !openBaoReadBodyPattern.MatchString(match[2]) {
				return errors.New("기존 단일 앱 ESO data policy가 read-only 계약과 다름")
			}
		case wantMetadata:
			// 예전 bootstrap은 metadata list를 함께 줬다. data 쓰기 권한은 계속 금지한다.
			if !openBaoLegacyMetadataReadBodyPattern.MatchString(match[2]) {
				return errors.New("기존 단일 앱 ESO metadata policy가 read-only 계약과 다름")
			}
		default:
			return errors.New("기존 단일 앱 ESO policy에 다른 경로가 있음")
		}
		if seen[match[1]] {
			return errors.New("기존 단일 앱 ESO policy에 중복 경로가 있음")
		}
		seen[match[1]] = true
	}
	if !seen[wantData] || !seen[wantMetadata] {
		return errors.New("기존 단일 앱 ESO policy의 exact 경로가 누락됨")
	}
	return nil
}

// requireLiveKVVersion은 metadata만 읽어 최신 버전이 지금 파괴/삭제된 상태인지
// 확인한다. future deletion_time은 아직 읽을 수 있으므로 그 시각 전까지 live로 본다.
func (c *openBaoClient) requireLiveKVVersion(ctx context.Context, remotePath, description string) (int, error) {
	var response openBaoKVMetadataResponse
	if err := c.getJSON(ctx, "v1/kv/metadata/"+remotePath, nil, &response); err != nil {
		return 0, fmt.Errorf("%s 확인 실패: %w", description, err)
	}
	if response.Data.CurrentVersion <= 0 {
		return 0, fmt.Errorf("%s 최신 버전이 없음", description)
	}
	version, ok := response.Data.Versions[strconv.Itoa(response.Data.CurrentVersion)]
	if !ok || version.Destroyed {
		return 0, fmt.Errorf("%s 최신 버전이 파괴되었거나 metadata에 없음", description)
	}
	if deletionTime := strings.TrimSpace(version.DeletionTime); deletionTime != "" {
		deletedAt, err := time.Parse(time.RFC3339Nano, deletionTime)
		if err != nil || !deletedAt.After(time.Now()) {
			return 0, fmt.Errorf("%s 최신 버전이 삭제되었거나 deletion_time이 올바르지 않음", description)
		}
	}
	return response.Data.CurrentVersion, nil
}

// requireKVSubkeys는 OpenBao KV v2 subkeys endpoint로 key 구조만 확인한다. 실제
// Secret 값은 Portal process, 로그, HTTP 오류 어디에도 전달되지 않는다.
func (c *openBaoClient) requireKVSubkeys(ctx context.Context, remotePath string, version int,
	requiredKeys []string, description string) error {
	var response openBaoKVSubkeysResponse
	query := url.Values{"version": []string{strconv.Itoa(version)}}
	if err := c.getJSON(ctx, "v1/kv/subkeys/"+remotePath, query, &response); err != nil {
		return fmt.Errorf("%s key 구조 확인 실패: %w", description, err)
	}
	subkeys := response.Subkeys
	// OpenBao 2.6 API는 subkeys를 최상위에 돌려준다. 일부 호환 구현은 일반 logical
	// response처럼 data 아래에 감싸므로 양쪽을 읽되, 값 endpoint로 fallback하지 않는다.
	if subkeys == nil {
		subkeys = response.Data.Subkeys
	}
	for _, requiredKey := range requiredKeys {
		leaf, ok := subkeys[requiredKey]
		if !ok || !bytes.Equal(bytes.TrimSpace(leaf), []byte("null")) {
			return fmt.Errorf("%s 에 필수 property %q 가 없음", description, requiredKey)
		}
	}
	return nil
}

func requiredWorkloadSecretKeys(profile normalizedProfile) []string {
	seen := make(map[string]struct{}, len(profile.Configuration.SecretKeys)+1)
	for _, key := range profile.Configuration.SecretKeys {
		seen[key] = struct{}{}
	}
	if profile.authMode() == authOIDC {
		seen["OIDC_CLIENT_SECRET"] = struct{}{}
	}
	keys := make([]string, 0, len(seen))
	for key := range seen {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func (c *openBaoClient) grantGroupRegistryAccess(ctx context.Context, group appGroup, remotePath string) error {
	role, serviceAccount, err := groupRegistryAccessNames(group)
	if err != nil {
		return err
	}
	if !validOpenBaoRemotePath(remotePath) {
		return fmt.Errorf("OpenBao registry pull 경로가 올바르지 않음: %q", remotePath)
	}
	if err := c.requireRegistryPolicy(ctx, remotePath); err != nil {
		return err
	}
	selector := fmt.Sprintf(`{"matchLabels":{"%s":"true"}}`, openBaoGroupNamespaceLabel)
	if err := c.requireKubernetesRole(ctx, role, "고정 AppGroup registry ESO role",
		openBaoKubernetesRoleContract{
			ServiceAccounts: []string{serviceAccount}, NamespaceSelector: selector,
			Policy: openBaoRegistryPolicy,
		}); err != nil {
		return err
	}
	version, err := c.requireLiveKVVersion(ctx, remotePath, "registry pull Secret seed")
	if err != nil {
		return err
	}
	return c.requireKVSubkeys(ctx, remotePath, version, []string{openBaoRegistryRequiredKey},
		"registry pull Secret seed")
}

func (c *openBaoClient) revokeGroupRegistryAccess(ctx context.Context, group appGroup) error {
	// registry role/policy는 모든 AppGroup이 함께 쓰는 bootstrap 자원이다. 그룹 하나를
	// 삭제할 때 지우면 다른 그룹의 image pull까지 끊기므로 회수할 동적 자원이 없다.
	_, _, err := groupRegistryAccessNames(group)
	return err
}

// grantESOAccess는 고정 templated policy/role과 앱 KV seed가 준비됐는지 확인한다.
// 실제 policy는 인증한 SA의 namespace/name metadata로 자기 경로 하나만 계산한다.
func (c *openBaoClient) grantESOAccess(ctx context.Context, profile normalizedProfile, namespace string) error {
	return c.grantESOAccessAt(ctx, profile, namespace, "")
}

func (c *openBaoClient) grantESOAccessAt(ctx context.Context, profile normalizedProfile,
	namespace, storedPath string) error {
	contract, err := resolveESOAccessContract(profile, storedPath)
	if err != nil {
		return err
	}
	if namespace != profile.namespace() {
		return fmt.Errorf("OpenBao ESO Namespace=%s 는 profile Namespace=%s 와 다름", namespace, profile.namespace())
	}
	if contract.Legacy {
		if err := c.requireLegacyWorkloadPolicy(ctx, contract); err != nil {
			return err
		}
		if err := c.requireKubernetesRole(ctx, contract.Role, "기존 단일 앱 ESO role",
			openBaoKubernetesRoleContract{
				ServiceAccounts: []string{contract.ServiceAccount}, Namespaces: []string{namespace},
				Policy: contract.Role,
			}); err != nil {
			return err
		}
	} else {
		if err := c.requireWorkloadPolicy(ctx, profile); err != nil {
			return err
		}
		expectedRole := openBaoKubernetesRoleContract{
			ServiceAccounts: []string{"*"}, Policy: openBaoWorkloadPolicy,
		}
		if profile.App.Group == "" {
			expectedRole.Namespaces = []string{namespace}
		} else {
			expectedRole.NamespaceSelector = fmt.Sprintf(`{"matchLabels":{"%s":"true"}}`, openBaoGroupNamespaceLabel)
		}
		if err := c.requireKubernetesRole(ctx, contract.Role, "고정 workload ESO role", expectedRole); err != nil {
			return err
		}
	}
	version, err := c.requireLiveKVVersion(ctx, contract.SecretPath, "앱 Secret seed")
	if err != nil {
		return err
	}
	return c.requireKVSubkeys(ctx, contract.SecretPath, version, requiredWorkloadSecretKeys(profile),
		"앱 Secret seed")
}

// revokeESOAccess는 shared policy/role을 건드리지 않고 앱 KV metadata를 통째로 지운다.
// KV v2 data 버전만 지우면 이름 재사용 시 이전 값이 되살아날 수 있어 metadata endpoint를
// 삭제해야 한다. 이 작업이 성공하기 전에는 ownership claim을 해제하지 않는다.
func (c *openBaoClient) revokeESOAccess(ctx context.Context, profile normalizedProfile) error {
	return c.revokeESOAccessAt(ctx, profile, "")
}

func (c *openBaoClient) revokeESOAccessAt(ctx context.Context, profile normalizedProfile,
	storedPath string) error {
	contract, err := resolveESOAccessContract(profile, storedPath)
	if err != nil {
		return err
	}
	return c.do(ctx, http.MethodDelete, "v1/kv/metadata/"+contract.SecretPath, nil)
}
