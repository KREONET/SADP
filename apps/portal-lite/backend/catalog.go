package main

import (
	"net/http"
	"sync"
)

type resourcePreset struct {
	Requests map[string]string `json:"requests"`
	Limits   map[string]string `json:"limits"`
}

type catalogService struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	URL         string   `json:"url"`
	Access      string   `json:"access"`
	Roles       []string `json:"roles,omitempty"`
	Status      string   `json:"status"`
}

type catalogTemplate struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Exposure    string `json:"exposure"`
	Description string `json:"description"`
	ValuesFile  string `json:"valuesFile"`
}

// catalogZone은 사용자 워크로드가 올라가는 단일 Zone이다.
// Zone ID는 곧 네임스페이스지만 화면에는 Zone 이름만 노출한다.
type catalogZone struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

type catalogResponse struct {
	APIVersion         string                    `json:"apiVersion"`
	Zone               catalogZone               `json:"zone"`
	AutoApprove        bool                      `json:"autoApprove"`
	Environment        string                    `json:"environment"`
	BaseDomain         string                    `json:"baseDomain"`
	ForgejoConnected   bool                      `json:"forgejoConnected"`
	SubmissionEnabled  bool                      `json:"submissionEnabled"`
	Services           []catalogService          `json:"services"`
	Templates          []catalogTemplate         `json:"templates"`
	Projects           []string                  `json:"projects"`
	ResourcePresets    map[string]resourcePreset `json:"resourcePresets"`
	UserQuota          userQuota                 `json:"userQuota"`
	MaxReplicas        int                       `json:"maxReplicas"`
	OpenAPISpec        string                    `json:"openapiSpec"`
	SecretInputAllowed bool                      `json:"secretInputAllowed"`
	// AppGroup(Compose 다중 앱) 관련 값. 화면이 Namespace 이름과 상한을 만들어 내지 않도록
	// 서버가 내려 준다.
	AppGroups catalogAppGroups `json:"appGroups"`
}

// catalogAppGroups는 다중 앱 화면이 알아야 하는 규칙이다.
type catalogAppGroups struct {
	Enabled bool `json:"enabled"`
	// Namespace 접두사. 화면 미리보기(app-<group>)가 실제와 같아야 한다.
	NamespacePrefix string `json:"namespacePrefix"`
	MaxServices     int    `json:"maxServices"`
	// 선택 가능한 값들. 화면이 하드코딩하면 서버가 규칙을 바꿔도 따라오지 않는다.
	ExposureModes []string `json:"exposureModes"`
	AuthModes     []string `json:"authenticationModes"`
	EgressModes   []string `json:"egressModes"`
}

func catalog() catalogResponse {
	return catalogResponse{
		APIVersion:         "v1",
		Zone:               catalogZone{ID: zoneID, Label: zoneLabel},
		AutoApprove:        autoApprove,
		Environment:        appEnvironment,
		BaseDomain:         baseDomain,
		ForgejoConnected:   false,
		SubmissionEnabled:  false,
		SecretInputAllowed: false,
		OpenAPISpec:        "/api/v1/openapi.yaml",
		Services: []catalogService{
			{ID: "hello", Name: "공개 샘플", Description: "로그인 없이 바로 접근하는 public 서비스", URL: "https://hello." + baseDomain, Access: "public", Status: "available"},
			{ID: "secure-demo", Name: "SSO 보호 샘플", Description: "외부 OIDC 로그인을 통과한 사용자만 접근", URL: "https://secure-demo." + baseDomain, Access: "sso", Status: "available"},
			{ID: "rancher", Name: "Rancher", Description: "클러스터·노드·프로젝트 관리", URL: "https://rancher." + baseDomain, Access: "admin", Roles: []string{"platform-admin", "app-admin"}, Status: "available"},
			{ID: "openbao", Name: "OpenBao", Description: "승인된 앱 경로의 Secret 관리", URL: "https://openbao." + baseDomain, Access: "sso", Roles: []string{"platform-admin", "app-admin"}, Status: "available"},
		},
		Templates: []catalogTemplate{
			{ID: "web-public-v2", Name: "로그인 없는 공개 웹", Exposure: "public", Description: "HTTPS URL로 누구나 접근", ValuesFile: "apps/_template/values-public.yaml"},
			{ID: "web-oidc-v2", Name: "외부 OIDC 보호 웹", Exposure: "oidc", Description: "Envoy가 로그인 완료 후에만 upstream 연결", ValuesFile: "apps/_template/values-sso.yaml"},
		},
		ResourcePresets: map[string]resourcePreset{
			"small":  {Requests: map[string]string{"cpu": "100m", "memory": "128Mi"}, Limits: map[string]string{"cpu": "500m", "memory": "512Mi"}},
			"medium": {Requests: map[string]string{"cpu": "250m", "memory": "512Mi"}, Limits: map[string]string{"cpu": "1", "memory": "1Gi"}},
		},
		Projects:    allowedProjects,
		UserQuota:   configuredUserQuota,
		MaxReplicas: maxAppReplicas,
		AppGroups: catalogAppGroups{
			Enabled:         true,
			NamespacePrefix: groupNamespacePrefix,
			MaxServices:     maxGroupServices,
			ExposureModes:   []string{exposureExternal, exposureInternal},
			AuthModes:       []string{authNone, authOIDC},
			EgressModes:     []string{egressBlocked, egressWeb, egressCustom},
		},
	}
}

// catalogProbeTargets는 카탈로그 서비스 ID를 실제 Service 좌표에 잇는다.
// 여기에 없는 ID는 상태를 건드리지 않고 정적 값을 유지한다.
func catalogProbeTargets() map[string]serviceRef {
	return map[string]serviceRef{
		"hello":       {Namespace: workloadNamespace, Name: "hello"},
		"secure-demo": {Namespace: workloadNamespace, Name: "secure-demo"},
		"rancher":     {Namespace: rancherNamespace, Name: "rancher"},
		// openbao-active는 봉인 해제된 active Pod만 엔드포인트로 잡히므로 상태 신호가 정확하다.
		"openbao": {Namespace: openbaoNamespace, Name: "openbao-active"},
	}
}

// handleCatalog은 정적 카탈로그에 현재 Forgejo 연동 여부와(가능하면) 실제 서비스
// 상태를 덧입혀 돌려준다. UI는 두 플래그를 보고 신청 버튼을 열지 말지 결정한다.
func (api *apiServer) handleCatalog(w http.ResponseWriter, r *http.Request) {
	response := catalog()
	enabled := api.submissionEnabled()
	response.ForgejoConnected = enabled
	response.SubmissionEnabled = enabled
	response.SecretInputAllowed = enabled && api.openbao != nil
	response.AppGroups.Enabled = enabled && api.openbao != nil && registryPullRemotePath != "" && len(allowedProjects) > 0
	if response.AppGroups.Enabled {
		probeGroup := newAppGroup("readiness", allowedProjects[0], appEnvironment)
		if err := api.openbao.grantGroupRegistryAccess(r.Context(), probeGroup, registryPullRemotePath); err != nil {
			response.AppGroups.Enabled = false
		}
	}
	api.applyLiveStatus(r, response.Services)
	writeJSON(w, http.StatusOK, response)
}

// applyLiveStatus는 프로브가 있을 때만 상태를 덮어쓴다. 프로브가 없으면
// (클러스터 밖·권한 없음) 정적 카탈로그와 완전히 같은 응답이 유지된다.
func (api *apiServer) applyLiveStatus(r *http.Request, services []catalogService) {
	if api == nil || api.prober == nil {
		return
	}
	targets := catalogProbeTargets()
	var waitGroup sync.WaitGroup
	for index := range services {
		ref, ok := targets[services[index].ID]
		if !ok {
			continue
		}
		waitGroup.Add(1)
		go func(index int, ref serviceRef) {
			defer waitGroup.Done()
			if status := api.prober.status(r.Context(), ref); status != "" {
				services[index].Status = status
			}
		}(index, ref)
	}
	waitGroup.Wait()
}
