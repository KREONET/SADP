package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	appNamePattern = regexp.MustCompile(`^[a-z]([-a-z0-9]*[a-z0-9])?$`)
	branchPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$`)
	envKeyPattern  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	// charts/app-profile/templates/configmap.yaml 과 scripts/ci-guard.sh 가 쓰는 것과
	// 같은 목록이다. 세 곳이 어긋나면 포털은 통과시키고 Helm 렌더에서 실패한다.
	sensitiveEnvKeyPattern = regexp.MustCompile(`(?i)PASSWORD|PASSWD|TOKEN|SECRET|PRIVATE_KEY|CREDENTIAL|API_KEY|ACCESS_KEY|DATABASE_URL|DB_URL|DSN|CONNECTION_STRING|AUTHORIZATION|BEARER`)
)

const (
	maxAppEnvVars       = 100
	maxAppEnvValueBytes = 4096

	exposureExternal = "external"
	exposureInternal = "internal"
	authNone         = "none"
	authOIDC         = "oidc"

	egressBlocked = "blocked"
	egressWeb     = "web"
	egressCustom  = "custom"

	workloadService = "service"
	workloadWorker  = "worker"

	// 앱 하나가 열 수 있는 연결 수 상한. 정책이 수백 줄로 불어나면 사람이 검토할 수 없다.
	maxNetworkPeers = 20
)

var reservedAppNames = map[string]struct{}{
	"hello":       {},
	"portal-lite": {},
	"secure-demo": {},
}

var reservedPlatformHostLabels = map[string]struct{}{
	"hello": {}, "secure-demo": {}, "portal": {}, "rancher": {}, "openbao": {}, "sso": {},
}

func reservedPlatformHost(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	suffix := "." + strings.ToLower(strings.TrimSuffix(baseDomain, "."))
	if !strings.HasSuffix(host, suffix) {
		return false
	}
	label := strings.TrimSuffix(host, suffix)
	if strings.Contains(label, ".") {
		return false
	}
	_, reserved := reservedPlatformHostLabels[label]
	return reserved
}

// reservedAppName은 포털이 관리하지 않는 정적 앱과 AppGroup Application 경로를
// 보호한다. group-* 앱을 허용하면 argocd/applications/group-<name>-<env>.yaml에서
// Namespace bootstrap 파일과 충돌할 수 있다.
func reservedAppName(name string) bool {
	if _, reserved := reservedAppNames[name]; reserved {
		return true
	}
	// aa-/ag-는 AppGroup의 hashed app/bootstrap Application 파일명, ga-는 AppGroup 외부
	// host label의 종류 prefix다. 단일 앱이 이 이름을 선점하면 typed 이름도 다시 충돌한다.
	return strings.HasPrefix(name, "group-") || strings.HasPrefix(name, "aa-") ||
		strings.HasPrefix(name, "ag-") || strings.HasPrefix(name, "ga-") ||
		strings.HasPrefix(name, "_") || strings.HasPrefix(name, ".")
}

// prebuiltImagePattern은 Compose가 지정한 기존 이미지다. tag 또는 digest가 반드시 있어야 한다.
// latest 계열 가변 태그는 별도로 거부한다(같은 값이 다른 내용을 가리키면 재현이 안 된다).
var (
	prebuiltImagePattern = regexp.MustCompile(
		`^[a-z0-9][a-z0-9._/-]{0,199}(:[A-Za-z0-9._-]{1,128}|@sha256:[a-f0-9]{64})$`)
	mutableImageTags = map[string]bool{"latest": true, "main": true, "master": true, "stable": true}
)

type appProfileInput struct {
	AppName string `json:"appName"`
	// Group은 AppGroup(Stack) 이름이다. 비면 기존 단일 앱 배포와 완전히 같다.
	Group         string `json:"group,omitempty"`
	Project       string `json:"project"`
	Environment   string `json:"environment"`
	GitRepository string `json:"gitRepository"`
	Branch        string `json:"branch"`
	Dockerfile    string `json:"dockerfile"`
	ContainerPort int    `json:"containerPort"`
	// Exposure는 예전 문자열("public"/"oidc")과 새 객체({"mode":"external"})를 모두 받는다.
	Exposure exposureInput `json:"exposure"`
	// Authentication은 노출과 분리된 인증 축이다. 비면 Exposure의 예전 값에서 유도한다.
	Authentication authenticationInput `json:"authentication,omitempty"`
	NetworkPolicy  networkPolicyInput  `json:"networkPolicy,omitempty"`
	ResourceSize   string              `json:"resourceSize"`
	// 생략하면 1로 본다. 사용자 쿼터는 preset이 아니라 preset×replicas로 소모된다.
	Replicas int `json:"replicas,omitempty"`
	// 화면 6(구성 분류기)에서 분류한 환경변수. openbao 값은 요청 중에만 사용한다.
	EnvVars []envVarInput `json:"envVars,omitempty"`
	// DeclaredSecretKeys는 Compose/AppGroup이 값 없이 선언한 OpenBao key다. 외부 단일
	// 앱 JSON에서는 받을 수 없고, AppGroup 서비스의 secretKeys 검증 뒤에만 채운다.
	DeclaredSecretKeys []string `json:"-"`
	// Image는 Compose가 이미 만들어진 이미지를 지정한 경우다(postgres:16 처럼).
	// 값이 있으면 소스 빌드를 하지 않고, 대신 Git 관련 입력을 요구하지 않는다.
	Image string `json:"image,omitempty"`
	// WorkloadMode는 Compose 파서가 포트 없는 백그라운드 worker를 표시하는 내부 필드다.
	// 단일 앱 API가 Service 생성을 임의로 우회하는 새 입력면이 되지 않도록 JSON에는 없다.
	WorkloadMode string `json:"-"`
	// PersistenceMountPath도 검증한 Compose named volume에서만 채운다. size와
	// StorageClass는 사용자 입력이 아니라 플랫폼 계약값을 사용한다.
	PersistenceMountPath string `json:"-"`
}

// exposureInput은 하위호환 때문에 두 가지 JSON 형태를 받는다.
//
//	"exposure": "public"              (예전 위저드)
//	"exposure": {"mode": "external"}  (현재)
//
// 두 형태를 한 필드로 받지 않으면 기존 클라이언트가 400을 맞는다.
type exposureInput struct {
	Mode string `json:"mode"`
	// Legacy는 문자열 형태로 들어왔을 때만 채워진다.
	Legacy string `json:"-"`
}

func (e *exposureInput) UnmarshalJSON(data []byte) error {
	var asString string
	if err := json.Unmarshal(data, &asString); err == nil {
		e.Legacy = strings.TrimSpace(asString)
		e.Mode = ""
		return nil
	}
	var asObject struct {
		Mode string `json:"mode"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&asObject); err != nil {
		return errors.New("exposure는 \"public\"/\"oidc\" 또는 {\"mode\":\"external|internal\"} 이어야 합니다")
	}
	e.Mode = strings.TrimSpace(asObject.Mode)
	e.Legacy = ""
	return nil
}

func (e exposureInput) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Mode string `json:"mode"`
	}{Mode: e.Mode})
}

type authenticationInput struct {
	Mode string `json:"mode"`
}

// networkPolicyInput은 앱 하나의 통신 허용 범위다.
// 사용자가 raw NetworkPolicy YAML이나 label을 적지 않도록 앱 이름·CIDR·포트만 받는다.
type networkPolicyInput struct {
	// blocked | web | custom. 비우면 blocked(가장 좁은 값)로 본다.
	EgressMode   string          `json:"egressMode,omitempty"`
	AllowedApps  []appPeerInput  `json:"allowedApps,omitempty"`
	AllowedCIDRs []cidrPeerInput `json:"allowedCIDRs,omitempty"`
	Ingress      ingressInput    `json:"ingress,omitempty"`
}

type ingressInput struct {
	AllowedApps []appPeerInput `json:"allowedApps,omitempty"`
}

type appPeerInput struct {
	App      string `json:"app"`
	Port     int    `json:"port"`
	Protocol string `json:"protocol,omitempty"`
}

type cidrPeerInput struct {
	CIDR     string `json:"cidr"`
	Port     int    `json:"port"`
	Protocol string `json:"protocol,omitempty"`
}

// envVarInput은 환경변수 한 줄이다.
//
// Classification 이 "openbao" 면 Value 는 배포 요청 처리 중 OpenBao 로만 전달한다.
// 렌더 결과와 저장소에는 key 이름만 남긴다.
type envVarInput struct {
	Key            string `json:"key"`
	Value          string `json:"value,omitempty"`
	Classification string `json:"classification"`
}

type normalizedProfile struct {
	App struct {
		Name string `json:"name"`
		// Group이 있으면 이 앱은 전용 Namespace(app-<group>)에 배포된다.
		Group       string `json:"group,omitempty"`
		Project     string `json:"project"`
		Environment string `json:"environment"`
	} `json:"app"`
	Source struct {
		Repository string `json:"repository"`
		Revision   string `json:"revision"`
		// Commit은 Forgejo에서 확인한 immutable source revision이다. Revision은 사람이
		// 고른 추적 branch이고, 실제 빌드에는 이 commit을 함께 줘 branch 이동 경쟁을 막는다.
		Commit     string `json:"commit,omitempty"`
		Dockerfile string `json:"dockerfile"`
		// Context는 Dockerfile의 COPY/ADD 기준 디렉터리다. Compose build.context를
		// Dockerfile 경로로 흉내 내면 모노레포의 COPY가 저장소 루트를 보게 된다.
		Context string `json:"context,omitempty"`
		// Image가 있으면 빌드하지 않고 이 이미지를 그대로 배포한다(Compose 입력).
		Image string `json:"image,omitempty"`
	} `json:"source"`
	Service struct {
		Enabled         bool   `json:"enabled"`
		Port            int    `json:"port"`
		HealthPath      string `json:"healthPath"`
		InternalAddress string `json:"internalAddress,omitempty"`
	} `json:"service"`
	Persistence struct {
		Enabled      bool   `json:"enabled"`
		MountPath    string `json:"mountPath,omitempty"`
		Size         string `json:"size,omitempty"`
		StorageClass string `json:"storageClass,omitempty"`
	} `json:"persistence"`
	Exposure struct {
		Mode string `json:"mode"`
		// Type은 예전 화면과 이미 저장된 신청 기록을 위해 계속 채운다.
		// public | oidc | internal 로만 나가고, 새 로직은 Mode/Authentication을 본다.
		Type string `json:"type"`
		Host string `json:"host,omitempty"`
	} `json:"exposure"`
	Authentication struct {
		Mode string `json:"mode"`
	} `json:"authentication"`
	NetworkPolicy normalizedNetworkPolicy `json:"networkPolicy"`
	// Configuration은 렌더될 values 의 configuration 블록 원천이다.
	// SecretKeys 에는 이름만 남는다(값은 OpenBao 에 있다).
	Configuration struct {
		Config     map[string]string `json:"config"`
		SecretKeys []string          `json:"secretKeys"`
	} `json:"configuration"`
	Resources resourcePreset `json:"resources"`
	Replicas  int            `json:"replicas"`
	// Quota는 이 프로필이 소모하는 양과 사용자 상한을 같이 돌려준다.
	Quota quotaSummary `json:"quota"`
}

// normalizedNetworkPolicy는 렌더될 values의 networkPolicy 블록 원천이다.
type normalizedNetworkPolicy struct {
	EgressMode   string          `json:"egressMode"`
	AllowedApps  []appPeerInput  `json:"allowedApps,omitempty"`
	AllowedCIDRs []cidrPeerInput `json:"allowedCIDRs,omitempty"`
	Ingress      struct {
		AllowedApps []appPeerInput `json:"allowedApps,omitempty"`
	} `json:"ingress"`
}

// namespace는 이 앱이 배포될 Kubernetes Namespace다.
// AppGroup이 없으면 예전과 같이 사이트 공용 Zone 하나를 쓴다.
func (profile normalizedProfile) namespace() string {
	if profile.App.Group != "" {
		return groupNamespace(profile.App.Group)
	}
	return zoneNamespace()
}

// exposureMode는 이미 저장된(예전 구조) 신청 기록도 읽을 수 있게 한다.
func (profile normalizedProfile) exposureMode() string {
	if profile.Exposure.Mode != "" {
		return profile.Exposure.Mode
	}
	if profile.Exposure.Type == exposureInternal {
		return exposureInternal
	}
	return exposureExternal
}

func (profile normalizedProfile) authMode() string {
	if profile.Authentication.Mode != "" {
		return profile.Authentication.Mode
	}
	if profile.Exposure.Type == "oidc" {
		return authOIDC
	}
	return authNone
}

// serviceEnabled는 enabled 필드가 생기기 전 저장된 요청도 계속 Service로 읽는다.
// 과거 프로필은 port가 항상 1 이상이었고, 새 worker만 port=0이므로 단사적으로 구분된다.
func (profile normalizedProfile) serviceEnabled() bool {
	return profile.Service.Enabled || profile.Service.Port > 0
}

// populateInternalAddress는 ClusterIP 대신 재생성에도 이름이 유지되는 Service DNS를
// 응답 계약에 넣는다. worker는 Service 자체가 없으므로 주소를 만들어 내지 않는다.
func (profile *normalizedProfile) populateInternalAddress() {
	if profile == nil || !profile.serviceEnabled() || profile.Service.Port < 1 {
		if profile != nil {
			profile.Service.InternalAddress = ""
		}
		return
	}
	profile.Service.InternalAddress = fmt.Sprintf("%s.%s.svc:%d",
		profile.App.Name, profile.namespace(), profile.Service.Port)
}

type quotaSummary struct {
	Limit      userQuota `json:"limit"`
	UsedCPU    string    `json:"usedCpu"`
	UsedMemory string    `json:"usedMemory"`
}

type generatedPlan struct {
	ValuesTemplate   string `json:"valuesTemplate"`
	OpenBaoPath      string `json:"openbaoPath"`
	OIDCClientID     string `json:"oidcClientId,omitempty"`
	OIDCCallbackURL  string `json:"oidcCallbackUrl,omitempty"`
	// 빌드가 끝난 뒤 채워지는 최종 이미지 좌표(레지스트리/이름:태그).
	Image             string `json:"image,omitempty"`
	ExpectedAnonymous int    `json:"expectedAnonymousStatus"`
}

type validationResponse struct {
	Valid     bool              `json:"valid"`
	Profile   normalizedProfile `json:"profile"`
	Generated generatedPlan     `json:"generated"`
	NextSteps []string          `json:"nextSteps"`
	Warnings  []string          `json:"warnings"`
}

func validateInput(input *appProfileInput) []fieldError {
	input.AppName = strings.TrimSpace(input.AppName)
	input.Group = strings.TrimSpace(input.Group)
	input.Project = strings.TrimSpace(input.Project)
	input.Environment = strings.TrimSpace(input.Environment)
	input.GitRepository = strings.TrimSpace(input.GitRepository)
	input.Branch = strings.TrimSpace(input.Branch)
	input.Dockerfile = strings.TrimSpace(input.Dockerfile)
	input.Image = strings.TrimSpace(input.Image)
	input.Exposure.Mode = strings.TrimSpace(input.Exposure.Mode)
	input.Exposure.Legacy = strings.TrimSpace(input.Exposure.Legacy)
	input.Authentication.Mode = strings.TrimSpace(input.Authentication.Mode)
	input.NetworkPolicy.EgressMode = strings.TrimSpace(input.NetworkPolicy.EgressMode)
	input.ResourceSize = strings.TrimSpace(input.ResourceSize)
	input.WorkloadMode = strings.TrimSpace(input.WorkloadMode)
	input.PersistenceMountPath = strings.TrimSpace(input.PersistenceMountPath)
	if input.WorkloadMode == "" {
		input.WorkloadMode = workloadService
	}

	validationErrors := make([]fieldError, 0)
	// 제어문자가 남으면 이후 YAML 렌더에서 줄바꿈 주입이 가능하므로 먼저 잘라낸다.
	for _, candidate := range []struct {
		field string
		value string
	}{
		{"appName", input.AppName}, {"group", input.Group}, {"project", input.Project},
		{"environment", input.Environment},
		{"gitRepository", input.GitRepository}, {"branch", input.Branch}, {"dockerfile", input.Dockerfile},
		{"image", input.Image},
		{"exposure", input.Exposure.Mode + input.Exposure.Legacy},
		{"authentication", input.Authentication.Mode},
		{"networkPolicy", input.NetworkPolicy.EgressMode},
		{"resourceSize", input.ResourceSize},
	} {
		if strings.ContainsFunc(candidate.value, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
			validationErrors = append(validationErrors, fieldError{Field: candidate.field, Message: "제어문자는 사용할 수 없습니다."})
		}
	}
	if len(validationErrors) > 0 {
		return validationErrors
	}
	if len(input.AppName) > 40 || !appNamePattern.MatchString(input.AppName) {
		validationErrors = append(validationErrors, fieldError{Field: "appName", Message: "40자 이하의 소문자 DNS 이름을 사용하세요."})
	} else if input.Group == "" && reservedAppName(input.AppName) {
		validationErrors = append(validationErrors, fieldError{Field: "appName", Message: "플랫폼 또는 AppGroup이 예약한 앱 이름은 사용할 수 없습니다."})
	}
	validationErrors = append(validationErrors, validateGroupName(input.Group)...)
	if !allowsProject(input.Project) {
		validationErrors = append(validationErrors, fieldError{Field: "project", Message: "현재 " + appEnvironment + "에서 허용된 프로젝트는 " + strings.Join(allowedProjects, ", ") + "입니다."})
	}
	if input.Environment != appEnvironment {
		validationErrors = append(validationErrors, fieldError{Field: "environment", Message: "현재 API는 " + appEnvironment + " 환경만 허용합니다."})
	}
	validationErrors = append(validationErrors, validateSource(input)...)
	switch input.WorkloadMode {
	case workloadService:
		if input.ContainerPort < 1 || input.ContainerPort > 65535 {
			validationErrors = append(validationErrors, fieldError{Field: "containerPort", Message: "서비스는 1~65535 범위의 포트가 필요합니다."})
		}
	case workloadWorker:
		if input.ContainerPort != 0 {
			validationErrors = append(validationErrors, fieldError{Field: "containerPort", Message: "worker는 리스닝 포트를 선언하지 않습니다."})
		}
		exposure, authentication := resolveAccess(input)
		if exposure != exposureInternal {
			validationErrors = append(validationErrors, fieldError{Field: "exposure", Message: "포트 없는 worker는 internal만 사용할 수 있습니다."})
		}
		if authentication != authNone {
			validationErrors = append(validationErrors, fieldError{Field: "authentication", Message: "포트 없는 worker에는 HTTPRoute/OIDC 인증을 붙일 수 없습니다."})
		}
		if len(input.NetworkPolicy.Ingress.AllowedApps) > 0 {
			validationErrors = append(validationErrors, fieldError{Field: "networkPolicy.ingress.allowedApps", Message: "포트 없는 worker는 수신 연결 대상이 될 수 없습니다."})
		}
	default:
		validationErrors = append(validationErrors, fieldError{Field: "workload", Message: "workload mode는 service 또는 worker여야 합니다."})
	}
	validationErrors = append(validationErrors, validateAccess(input)...)
	validationErrors = append(validationErrors, validateNetworkPolicy(input)...)
	presets := catalog().ResourcePresets
	preset, knownSize := presets[input.ResourceSize]
	if !knownSize {
		validationErrors = append(validationErrors, fieldError{Field: "resourceSize", Message: "small 또는 medium을 선택하세요."})
	}
	if input.Replicas == 0 {
		input.Replicas = 1
	}
	if input.Replicas < 1 || input.Replicas > maxAppReplicas {
		validationErrors = append(validationErrors, fieldError{
			Field:   "replicas",
			Message: fmt.Sprintf("1~%d 사이의 Pod 수를 입력하세요.", maxAppReplicas),
		})
	} else if knownSize {
		validationErrors = append(validationErrors, quotaErrors(preset, input.Replicas)...)
	}
	if input.PersistenceMountPath != "" {
		if input.Group == "" {
			validationErrors = append(validationErrors, fieldError{Field: "persistence", Message: "Compose named volume은 AppGroup에서만 사용할 수 있습니다."})
		}
		if input.Replicas != 1 {
			validationErrors = append(validationErrors, fieldError{Field: "replicas", Message: "ReadWriteOnce named volume을 쓰는 서비스는 replica가 1이어야 합니다."})
		}
		if appGroupVolumeSize == "" || appGroupVolumeStorageClass == "" {
			validationErrors = append(validationErrors, fieldError{Field: "persistence", Message: "플랫폼 AppGroup 저장소 계약이 준비되지 않았습니다."})
		}
	}
	validationErrors = append(validationErrors, validateEnvVars(input)...)
	return validationErrors
}

// validateGroupName은 AppGroup 이름과 그 이름으로 만들 Namespace 길이를 검사한다.
// 빈 값은 "AppGroup 없음"이므로 통과다.
func validateGroupName(group string) []fieldError {
	if group == "" {
		return nil
	}
	if len(group) > maxGroupNameLength || !appNamePattern.MatchString(group) {
		return []fieldError{{
			Field:   "group",
			Message: fmt.Sprintf("%d자 이하의 소문자 DNS 이름을 사용하세요.", maxGroupNameLength),
		}}
	}
	// Namespace 이름은 63자 제한이다. 여기서 막지 않으면 Argo sync 단계에서야 드러난다.
	if len(groupNamespace(group)) > 63 {
		return []fieldError{{Field: "group", Message: "앱 그룹 이름이 너무 길어 네임스페이스를 만들 수 없습니다."}}
	}
	return nil
}

// validateSource는 "소스에서 빌드" 와 "이미 만들어진 이미지" 중 하나만 오게 한다.
// Compose 로 들어온 postgres/redis 같은 서비스는 빌드할 소스가 없다.
func validateSource(input *appProfileInput) []fieldError {
	if input.Image != "" {
		sourceErrors := make([]fieldError, 0, 2)
		if input.GitRepository != "" || input.Branch != "" || input.Dockerfile != "" {
			sourceErrors = append(sourceErrors, fieldError{
				Field:   "image",
				Message: "이미지를 지정하면 Git 저장소/브랜치/Dockerfile은 비워야 합니다.",
			})
		}
		if !prebuiltImagePattern.MatchString(input.Image) {
			sourceErrors = append(sourceErrors, fieldError{
				Field:   "image",
				Message: "registry/name:tag 또는 registry/name@sha256:... 형식으로 입력하세요.",
			})
			return sourceErrors
		}
		_, reference, _ := splitPrebuiltImage(input.Image)
		if mutableImageTags[strings.ToLower(reference)] {
			sourceErrors = append(sourceErrors, fieldError{
				Field:   "image",
				Message: reference + " 처럼 바뀌는 태그는 쓸 수 없습니다. 고정된 버전이나 digest를 지정하세요.",
			})
		}
		return sourceErrors
	}

	sourceErrors := make([]fieldError, 0, 3)
	parsedRepository, err := url.ParseRequestURI(input.GitRepository)
	if err != nil || len(input.GitRepository) > 300 || parsedRepository.Scheme != "https" || parsedRepository.Host == "" || parsedRepository.User != nil || parsedRepository.RawQuery != "" || parsedRepository.Fragment != "" {
		sourceErrors = append(sourceErrors, fieldError{Field: "gitRepository", Message: "자격증명이 포함되지 않은 https Git URL을 사용하세요."})
	}
	if !branchPattern.MatchString(input.Branch) || strings.Contains(input.Branch, "..") || strings.Contains(input.Branch, "//") || strings.Contains(input.Branch, "@{") {
		sourceErrors = append(sourceErrors, fieldError{Field: "branch", Message: "안전한 Git branch 또는 tag 이름을 입력하세요."})
	}
	cleanDockerfile := path.Clean(input.Dockerfile)
	if input.Dockerfile == "" || len(input.Dockerfile) > 200 || strings.HasPrefix(input.Dockerfile, "/") || cleanDockerfile != input.Dockerfile || strings.HasPrefix(cleanDockerfile, "../") || !strings.HasPrefix(path.Base(cleanDockerfile), "Dockerfile") {
		sourceErrors = append(sourceErrors, fieldError{Field: "dockerfile", Message: "저장소 안의 상대 Dockerfile 경로를 입력하세요."})
	}
	return sourceErrors
}

// cleanSourceSubpath는 저장소 안의 상대 경로만 허용한다. build context와 Dockerfile
// 모두 같은 경계를 써야 kaniko가 clone한 저장소 밖을 읽으려는 입력이 생기지 않는다.
func cleanSourceSubpath(value string, allowDot bool) (string, bool) {
	value = strings.TrimSpace(value)
	if allowDot && (value == "" || value == ".") {
		return ".", true
	}
	value = strings.TrimPrefix(value, "./")
	cleaned := path.Clean(value)
	if value == "" || len(value) > 200 || strings.HasPrefix(value, "/") || cleaned != value ||
		cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", false
	}
	return cleaned, true
}

// resolveAccess는 노출과 인증을 각각 결정한다.
// 새 필드가 비어 있으면 예전 exposure 문자열에서 유도한다(public/oidc 둘 다 외부 노출이다).
func resolveAccess(input *appProfileInput) (string, string) {
	exposure := input.Exposure.Mode
	authentication := input.Authentication.Mode
	if exposure == "" {
		switch input.Exposure.Legacy {
		case "public":
			exposure = exposureExternal
			if authentication == "" {
				authentication = authNone
			}
		case "oidc":
			exposure = exposureExternal
			if authentication == "" {
				authentication = authOIDC
			}
		case "":
			// 아무것도 지정되지 않았다. validateAccess가 선택을 요구한다.
		default:
			// 알 수 없는 예전 값(office-oidc 등)은 external로 해석하지 않는다.
			// 그대로 넘겨서 validateAccess가 거부하게 한다.
			exposure = input.Exposure.Legacy
		}
	}
	// 새 형식으로 노출만 지정했으면 인증은 명시하지 않은 것으로 보고 none 이다.
	if authentication == "" && exposure != "" {
		authentication = authNone
	}
	return exposure, authentication
}

func validateAccess(input *appProfileInput) []fieldError {
	exposure, authentication := resolveAccess(input)
	accessErrors := make([]fieldError, 0, 2)
	// 폐기된 단일 값과 새 인증 축을 함께 보낼 때 의미가 다르면 조용히 한쪽을
	// 우선하지 않는다. 특히 legacy oidc + none을 받아들이면 기존 SSO가 해제된다.
	if legacy := input.Exposure.Legacy; legacy != "" && input.Authentication.Mode != "" {
		legacyAuthentication := ""
		switch legacy {
		case "public":
			legacyAuthentication = authNone
		case "oidc":
			legacyAuthentication = authOIDC
		}
		if legacyAuthentication != "" && input.Authentication.Mode != legacyAuthentication {
			accessErrors = append(accessErrors, fieldError{
				Field:   "authentication",
				Message: "기존 exposure 값과 authentication.mode가 서로 충돌합니다. 새 구조만 사용하세요.",
			})
		}
	}
	switch exposure {
	case exposureExternal, exposureInternal:
	case "":
		accessErrors = append(accessErrors, fieldError{
			Field: "exposure", Message: "외부 URL 생성(external) 또는 내부 앱 전용(internal)을 선택하세요.",
		})
	default:
		accessErrors = append(accessErrors, fieldError{
			Field: "exposure", Message: "exposure.mode는 external 또는 internal이어야 합니다.",
		})
	}
	switch authentication {
	case authNone, authOIDC:
	default:
		accessErrors = append(accessErrors, fieldError{
			Field: "authentication", Message: "authentication.mode는 none 또는 oidc여야 합니다.",
		})
	}
	// SecurityPolicy는 HTTPRoute를 대상으로 한다. 내부 전용 앱에는 붙일 대상이 없다.
	if authentication == authOIDC && exposure == exposureInternal {
		accessErrors = append(accessErrors, fieldError{
			Field:   "authentication",
			Message: "authentication.mode=oidc 는 exposure.mode=external 에서만 사용할 수 있습니다.",
		})
	}
	return accessErrors
}

// validateNetworkPolicy는 앱별 통신 정책을 검사한다.
// 기본값은 blocked다 — 아무것도 적지 않은 앱이 인터넷으로 나갈 수 있으면 안 된다.
func validateNetworkPolicy(input *appProfileInput) []fieldError {
	policy := &input.NetworkPolicy
	if policy.EgressMode == "" {
		policy.EgressMode = egressBlocked
	}
	policyErrors := make([]fieldError, 0)
	switch policy.EgressMode {
	case egressBlocked, egressWeb, egressCustom:
	default:
		policyErrors = append(policyErrors, fieldError{
			Field: "networkPolicy.egressMode", Message: "egressMode는 blocked, web, custom 중 하나여야 합니다.",
		})
	}
	if policy.EgressMode != egressCustom && len(policy.AllowedCIDRs) > 0 {
		policyErrors = append(policyErrors, fieldError{
			Field:   "networkPolicy.allowedCIDRs",
			Message: "CIDR을 직접 지정하려면 외부 통신을 '사용자 지정'으로 선택하세요.",
		})
	}
	if len(policy.AllowedApps)+len(policy.AllowedCIDRs)+len(policy.Ingress.AllowedApps) > maxNetworkPeers {
		policyErrors = append(policyErrors, fieldError{
			Field:   "networkPolicy",
			Message: fmt.Sprintf("허용 규칙은 최대 %d개까지 등록할 수 있습니다.", maxNetworkPeers),
		})
		return policyErrors
	}
	policyErrors = append(policyErrors, validateAppPeers("networkPolicy.allowedApps", input, policy.AllowedApps, true)...)
	policyErrors = append(policyErrors, validateAppPeers("networkPolicy.ingress.allowedApps", input, policy.Ingress.AllowedApps, false)...)
	for index := range policy.AllowedCIDRs {
		peer := &policy.AllowedCIDRs[index]
		peer.CIDR = strings.TrimSpace(peer.CIDR)
		peer.Protocol = normalizeProtocol(peer.Protocol)
		field := fmt.Sprintf("networkPolicy.allowedCIDRs[%d]", index)
		if _, network, err := net.ParseCIDR(peer.CIDR); err != nil {
			policyErrors = append(policyErrors, fieldError{Field: field, Message: "10.0.0.5/32 형식의 CIDR을 입력하세요."})
		} else if network.String() == "0.0.0.0/0" || network.String() == "::/0" {
			// 전체 인터넷을 열려면 web 모드를 써야 한다. custom 으로 0.0.0.0/0 을 여는 것은
			// "특정 목적지만 허용" 이라는 이 모드의 의미를 무너뜨린다.
			policyErrors = append(policyErrors, fieldError{
				Field: field, Message: "0.0.0.0/0 전체 허용은 사용할 수 없습니다. 필요한 대역만 지정하세요.",
			})
		} else {
			// Kubernetes ipBlock은 network address 형태를 기대한다. host bit가 든 입력을
			// API 단계에서 정규화해 Argo sync 때 뒤늦게 거부되지 않게 한다.
			peer.CIDR = network.String()
		}
		if peer.Port < 1 || peer.Port > 65535 {
			policyErrors = append(policyErrors, fieldError{Field: field, Message: "1~65535 범위의 포트를 입력하세요."})
		}
		if peer.Protocol == "" {
			policyErrors = append(policyErrors, fieldError{Field: field, Message: "protocol은 TCP 또는 UDP여야 합니다."})
		}
	}
	return policyErrors
}

func validateAppPeers(field string, input *appProfileInput, peers []appPeerInput, requirePort bool) []fieldError {
	if len(peers) == 0 {
		return nil
	}
	// 앱 이름 selector는 같은 Namespace 안에서만 뜻이 있다. AppGroup이 없으면
	// 사이트 공용 Zone을 가리키게 되어 남의 앱을 여는 규칙이 된다.
	if input.Group == "" {
		return []fieldError{{
			Field:   field,
			Message: "앱 사이 연결은 같은 앱 그룹(AppGroup) 안에서만 지정할 수 있습니다.",
		}}
	}
	peerErrors := make([]fieldError, 0)
	seen := make(map[string]struct{}, len(peers))
	for index := range peers {
		peer := &peers[index]
		peer.App = strings.TrimSpace(peer.App)
		peer.Protocol = normalizeProtocol(peer.Protocol)
		itemField := fmt.Sprintf("%s[%d]", field, index)
		if len(peer.App) > 40 || !appNamePattern.MatchString(peer.App) {
			peerErrors = append(peerErrors, fieldError{Field: itemField, Message: "연결할 앱 이름을 올바르게 지정하세요."})
			continue
		}
		if peer.App == input.AppName {
			peerErrors = append(peerErrors, fieldError{Field: itemField, Message: "자기 자신은 지정할 수 없습니다."})
			continue
		}
		key := peer.App + "/" + peer.Protocol + "/" + strconv.Itoa(peer.Port)
		if _, duplicated := seen[key]; duplicated {
			peerErrors = append(peerErrors, fieldError{Field: itemField, Message: peer.App + " 연결이 중복되었습니다."})
			continue
		}
		seen[key] = struct{}{}
		if peer.Protocol != "TCP" {
			// app-profile Service는 TCP만 선언한다. UDP NetworkPolicy만 만들어도
			// Service DNS 경로가 열리지 않으므로 지원한다고 오인시키지 않는다.
			peerErrors = append(peerErrors, fieldError{Field: itemField, Message: "앱 간 연결 protocol은 TCP만 지원합니다."})
		}
		if peer.Port == 0 && !requirePort {
			// ingress 는 포트를 비우면 이 앱의 Service 포트를 쓴다.
			continue
		}
		if peer.Port < 1 || peer.Port > 65535 {
			peerErrors = append(peerErrors, fieldError{Field: itemField, Message: "1~65535 범위의 포트를 입력하세요."})
		}
	}
	return peerErrors
}

func normalizeProtocol(value string) string {
	switch strings.ToUpper(strings.TrimSpace(value)) {
	case "", "TCP":
		return "TCP"
	case "UDP":
		return "UDP"
	}
	return ""
}

// validateEnvVars는 화면 6(구성 분류기)이 넘긴 환경변수를 검사한다.
//
// 두 축을 본다. (1) ConfigMap 으로 갈 값이 민감 key 인지, (2) OpenBao 로 분류한 항목에
// 값이 실려 왔는지. 두 번째가 핵심이다. Secret 값이 이 API 를 지나가면 요청 본문과
// 접근 로그, 그리고 렌더된 values 를 담은 Forgejo PR diff 에 그대로 남는다.
func validateEnvVars(input *appProfileInput) []fieldError {
	if len(input.EnvVars) == 0 {
		return nil
	}
	envErrors := make([]fieldError, 0)
	if len(input.EnvVars) > maxAppEnvVars {
		return []fieldError{{
			Field:   "envVars",
			Message: fmt.Sprintf("환경변수는 최대 %d개까지 등록할 수 있습니다.", maxAppEnvVars),
		}}
	}
	seen := make(map[string]struct{}, len(input.EnvVars))
	for index := range input.EnvVars {
		item := &input.EnvVars[index]
		item.Key = strings.TrimSpace(item.Key)
		item.Classification = strings.TrimSpace(item.Classification)
		field := fmt.Sprintf("envVars[%d]", index)

		if !envKeyPattern.MatchString(item.Key) || len(item.Key) > 128 {
			envErrors = append(envErrors, fieldError{Field: field, Message: "환경변수 이름은 영문자/숫자/밑줄만 쓰고 숫자로 시작하지 않습니다."})
			continue
		}
		if _, duplicated := seen[item.Key]; duplicated {
			envErrors = append(envErrors, fieldError{Field: field, Message: item.Key + " 가 중복되었습니다."})
			continue
		}
		seen[item.Key] = struct{}{}

		switch item.Classification {
		case "openbao":
			if item.Value == "" {
				envErrors = append(envErrors, fieldError{
					Field:   field,
					Message: item.Key + " Secret 값을 입력하세요.",
				})
			} else if len(item.Value) > maxAppEnvValueBytes {
				envErrors = append(envErrors, fieldError{Field: field, Message: item.Key + " 값이 너무 큽니다."})
			}
		case "configmap":
			if sensitiveEnvKeyPattern.MatchString(item.Key) {
				envErrors = append(envErrors, fieldError{
					Field:   field,
					Message: item.Key + " 는 민감한 이름이라 ConfigMap 에 넣을 수 없습니다. OpenBao 로 분류하세요.",
				})
				continue
			}
			if sensitiveEnvValue(item.Value) {
				envErrors = append(envErrors, fieldError{
					Field:   field,
					Message: item.Key + " 값에 자격증명 또는 비밀키 형태가 포함되어 ConfigMap 에 넣을 수 없습니다. OpenBao 로 분류하세요.",
				})
				continue
			}
			if len(item.Value) > maxAppEnvValueBytes {
				envErrors = append(envErrors, fieldError{
					Field:   field,
					Message: fmt.Sprintf("%s 값이 %d바이트를 넘습니다.", item.Key, maxAppEnvValueBytes),
				})
				continue
			}
			// 제어문자가 남으면 렌더된 values YAML 에 줄바꿈을 주입할 수 있다.
			if strings.ContainsFunc(item.Value, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
				envErrors = append(envErrors, fieldError{Field: field, Message: item.Key + " 값에 제어문자를 쓸 수 없습니다."})
			}
		default:
			envErrors = append(envErrors, fieldError{
				Field:   field,
				Message: item.Key + " 가 분류되지 않았습니다. ConfigMap 또는 OpenBao 로 분류하세요.",
			})
		}
	}
	return envErrors
}

// 이름만으로 모든 Secret을 판별할 수는 없지만, URI userinfo와 대표적인 비밀키·토큰
// 형태는 이름이 평범해도 Git에 기록되기 전에 막는다. false positive가 나면 사용자는
// 값이 Git을 지나지 않는 OpenBao 분류를 명시해야 한다.
func sensitiveEnvValue(value string) bool {
	trimmed := strings.TrimSpace(value)
	lower := strings.ToLower(trimmed)
	if strings.Contains(lower, "-----begin private key-----") ||
		strings.Contains(lower, "-----begin rsa private key-----") ||
		strings.HasPrefix(lower, "hvs.") || strings.HasPrefix(lower, "ghp_") ||
		strings.HasPrefix(lower, "github_pat_") || strings.HasPrefix(lower, "akia") {
		return true
	}
	parsed, err := url.Parse(trimmed)
	return err == nil && parsed.Scheme != "" && parsed.Host != "" && parsed.User != nil
}

// quotaErrors는 preset×replicas가 사용자 상한을 넘을 때 어느 축이 넘쳤는지 알려준다.
// 사용자가 스스로 고칠 수 있도록 상한과 현재 소모량을 함께 적는다.
func quotaErrors(preset resourcePreset, replicas int) []fieldError {
	cpuOver, memoryOver, err := exceedsUserQuota(preset, replicas)
	if err != nil {
		return []fieldError{{Field: "resourceSize", Message: "자원 상한 설정을 해석할 수 없습니다. 플랫폼 관리자에게 문의하세요."}}
	}
	usedCPU, usedMemory, _ := quotaUsage(preset, replicas)
	quotaFieldErrors := make([]fieldError, 0, 2)
	if cpuOver {
		quotaFieldErrors = append(quotaFieldErrors, fieldError{
			Field: "replicas",
			Message: fmt.Sprintf("사용자당 CPU 상한 %s를 넘습니다(요청 %s = %s × %d Pod).",
				configuredUserQuota.CPU, formatCPUMilli(usedCPU), preset.Limits["cpu"], replicas),
		})
	}
	if memoryOver {
		quotaFieldErrors = append(quotaFieldErrors, fieldError{
			Field: "replicas",
			Message: fmt.Sprintf("사용자당 메모리 상한 %s를 넘습니다(요청 %s = %s × %d Pod).",
				configuredUserQuota.Memory, formatMemoryBytes(usedMemory), preset.Limits["memory"], replicas),
		})
	}
	return quotaFieldErrors
}

// validationResult는 입력을 정규화하고 생성 계획을 만든다.
// submissionEnabled는 Forgejo 연동 여부로, 안내 문구만 달라진다.
func validationResult(input appProfileInput, submissionEnabled bool) validationResponse {
	presets := catalog().ResourcePresets
	exposure, authentication := resolveAccess(&input)
	profile := normalizedProfile{Resources: presets[input.ResourceSize]}
	profile.App.Name = input.AppName
	profile.App.Group = input.Group
	profile.App.Project = input.Project
	profile.App.Environment = input.Environment
	profile.Source.Repository = input.GitRepository
	profile.Source.Revision = input.Branch
	profile.Source.Dockerfile = input.Dockerfile
	// Compose build는 받지 않는다. 기존 단일 앱 source build는 저장소 루트 context를
	// 계속 사용해 임의 context가 build credential 경계 안으로 들어오지 않게 한다.
	profile.Source.Context = "."
	profile.Source.Image = input.Image
	profile.Service.Enabled = input.WorkloadMode != workloadWorker
	profile.Service.Port = input.ContainerPort
	profile.Service.HealthPath = "/healthz"
	profile.populateInternalAddress()
	if input.PersistenceMountPath != "" {
		profile.Persistence.Enabled = true
		profile.Persistence.MountPath = input.PersistenceMountPath
		profile.Persistence.Size = appGroupVolumeSize
		profile.Persistence.StorageClass = appGroupVolumeStorageClass
	}
	profile.Exposure.Mode = exposure
	profile.Exposure.Type = compatExposureType(exposure, authentication)
	// 내부 전용 앱은 외부 도메인을 갖지 않는다. AppGroup host는 app-group을 단순 연결하면
	// 서로 다른 tuple이 같은 label이 되므로 canonical identity hash를 항상 포함한다.
	if exposure == exposureExternal {
		profile.Exposure.Host = externalHostLabel(profile) + "." + baseDomain
	}
	profile.Authentication.Mode = authentication
	profile.NetworkPolicy = normalizedNetworkPolicy{
		EgressMode:   input.NetworkPolicy.EgressMode,
		AllowedApps:  input.NetworkPolicy.AllowedApps,
		AllowedCIDRs: input.NetworkPolicy.AllowedCIDRs,
	}
	if profile.NetworkPolicy.EgressMode == "" {
		profile.NetworkPolicy.EgressMode = egressBlocked
	}
	profile.NetworkPolicy.Ingress.AllowedApps = input.NetworkPolicy.Ingress.AllowedApps
	profile.Replicas = max(input.Replicas, 1)
	profile.Configuration.Config = map[string]string{}
	profile.Configuration.SecretKeys = []string{}
	for _, item := range input.EnvVars {
		if item.Classification == "openbao" {
			profile.Configuration.SecretKeys = append(profile.Configuration.SecretKeys, item.Key)
			continue
		}
		profile.Configuration.Config[item.Key] = item.Value
	}
	profile.Configuration.SecretKeys = append(profile.Configuration.SecretKeys, input.DeclaredSecretKeys...)
	// PR diff 가 입력 순서에 흔들리지 않게 고정한다.
	sort.Strings(profile.Configuration.SecretKeys)
	usedCPU, usedMemory, _ := quotaUsage(profile.Resources, profile.Replicas)
	profile.Quota = quotaSummary{
		Limit:      configuredUserQuota,
		UsedCPU:    formatCPUMilli(usedCPU),
		UsedMemory: formatMemoryBytes(usedMemory),
	}

	// OpenBao templated policy가 Kubernetes 인증 alias의 Namespace/ServiceAccount를
	// 그대로 경로에 넣는다. 사람이 '-'로 조합한 group/app 경로보다 이 물리 identity가
	// 단사이고, shared role 하나로도 다른 앱 Secret을 읽을 수 없다.
	_, _, openBaoPath, pathErr := esoAccessNames(profile)
	if pathErr != nil {
		// validateInput을 통과한 profile에서는 도달하지 않는다. 계획을 비워 두면 이후
		// put/assert가 fail-closed 하며, invalid path를 Git에 쓰지 않는다.
		openBaoPath = ""
	}
	generated := generatedPlan{
		ValuesTemplate:    "apps/_template/values-public.yaml",
		OpenBaoPath:       openBaoPath,
		ExpectedAnonymous: http.StatusOK,
	}
	nextSteps := []string{
		"생성할 values와 Argo CD Application을 Forgejo Pull Request로 검토합니다.",
		"main 병합 후 Forgejo Actions가 commit SHA 이미지 tag를 OCI Registry에 push합니다.",
		"GitOps 배포 PR을 승인하고 Argo CD Synced/Healthy를 확인합니다.",
	}
	if input.Image != "" {
		generated.Image = input.Image
		nextSteps = []string{
			"생성할 values와 Argo CD Application을 Forgejo Pull Request로 검토합니다.",
			"지정한 이미지를 그대로 사용하므로 소스 빌드는 하지 않습니다.",
			"GitOps 배포 PR을 승인하고 Argo CD Synced/Healthy를 확인합니다.",
		}
	}
	if exposure == exposureInternal {
		generated.ValuesTemplate = "apps/_template/values-internal.yaml"
		// 내부 전용 앱은 외부 경로가 없다. 익명 접근 기대값 자체가 성립하지 않는다.
		generated.ExpectedAnonymous = 0
	}
	if authentication == authOIDC {
		generated.ValuesTemplate = "apps/_template/values-sso.yaml"
		generated.OIDCClientID = oidcClientID(profile)
		generated.OIDCCallbackURL = "https://" + profile.Exposure.Host + "/oauth2/callback"
		generated.ExpectedAnonymous = http.StatusFound
		nextSteps = append([]string{"외부 IdP에 confidential OIDC client를 등록하고 OpenBao OIDC_CLIENT_SECRET을 관리자가 준비합니다."}, nextSteps...)
	}
	if input.Group != "" {
		nextSteps = append([]string{
			fmt.Sprintf("앱 그룹 %s 전용 Namespace(%s)와 기본 차단 정책을 함께 만듭니다.",
				input.Group, groupNamespace(input.Group)),
		}, nextSteps...)
	}
	warnings := []string{"Secret 실제 값은 이 API로 보내지 말고 OpenBao UI에서 입력하세요."}
	if !submissionEnabled {
		warnings = append([]string{
			"현재 테스트베드는 Forgejo 미연동 상태이므로 사전검증만 수행하며 배포 요청은 저장하지 않습니다.",
		}, warnings...)
	}
	return validationResponse{
		Valid: true, Profile: profile, Generated: generated, NextSteps: nextSteps,
		Warnings: warnings,
	}
}

// compatExposureType은 예전 exposure.type 문자열을 계속 채워 준다.
// 이미 저장된 신청 기록과 화면이 이 값을 읽고 있어서, 새 구조만 남기면
// 목록에 "공개 범위"가 빈칸으로 나온다.
func compatExposureType(exposure, authentication string) string {
	if exposure == exposureInternal {
		return exposureInternal
	}
	if authentication == authOIDC {
		return "oidc"
	}
	return "public"
}

func (api *apiServer) handleAppProfileValidation(w http.ResponseWriter, r *http.Request) {
	input, ok := decodeAppProfile(w, r)
	if !ok {
		return
	}
	if validationErrors := validateInput(&input); len(validationErrors) > 0 {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "AppProfile 검증 실패",
			"입력 필드를 수정한 뒤 다시 요청하세요.", validationErrors)
		return
	}
	writeJSON(w, http.StatusOK, validationResult(input, api.submissionEnabled()))
}
