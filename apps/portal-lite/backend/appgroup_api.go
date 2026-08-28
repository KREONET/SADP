package main

// AppGroup 신청 API.
//
// Compose 문서 하나를 받아 서비스마다 AppProfile 을 만들고, 서비스 수만큼 배포 요청을
// 만든다. 요청 하나하나는 기존 단일 앱의 GitOps 배포 경로를 재사용한다
// (PR -> 병합 -> Argo). Compose build는 credential 경계를 넓히므로 받지 않고,
// 검증된 prebuilt image만 배포한다. 그룹 전용 처리는 두 가지뿐이다.
//
//	1. 첫 PR 에 Namespace bootstrap(charts/app-group) 파일이 함께 들어간다.
//	2. 배포 대상 Namespace 가 Zone 이 아니라 app-<group> 이다.
//
// 여러 앱을 한 트랜잭션으로 배포하지는 않는다. 큐가 순차 처리라 앞의 앱이 실패해도
// 뒤의 앱은 각자 상태를 갖고 남는다. 사용자는 실패한 것만 다시 신청할 수 있다.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

func groupServiceIdempotencyKey(requester, key string, group appGroup, app string) string {
	sum := sha256.Sum256([]byte(requester + "\x00" + key + "\x00" + group.Project + "\x00" +
		group.Environment + "\x00" + group.Name + "\x00" + app))
	return "appgroup:" + hex.EncodeToString(sum[:])
}

func groupServiceBodyHash(groupBodyHash, app string) string {
	return hashBody([]byte(groupBodyHash + "\x00" + app))
}

// appGroupInput은 Compose 업로드 화면이 보내는 요청이다.
type appGroupInput struct {
	Group       string `json:"group"`
	Project     string `json:"project"`
	Environment string `json:"environment"`
	// Compose 문서 원본. build와 environment는 파서가 fail-close하고 prebuilt image만 받는다.
	Compose string `json:"compose,omitempty"`
	// Repository가 있으면 같은 Forgejo의 기본 브랜치에서 Compose 또는 Helm Chart를
	// 자동 탐색한다. Compose와 동시에 받을 수 없고 URL 안의 credential도 거부한다.
	Repository string `json:"repository,omitempty"`
	// RepositoryRevision은 첫 검증이 돌려준 commit SHA다. UI가 다시 보내 검증한
	// Chart와 실제 신청 사이에 기본 브랜치가 움직이는 TOCTOU를 막는다.
	RepositoryRevision string `json:"repositoryRevision,omitempty"`
	// 서비스가 개별 지정하지 않았을 때 쓰는 기본 자원 preset.
	ResourceSize string `json:"resourceSize"`
	// 서비스별 사용자 선택(노출/인증/네트워크). Compose 에는 이런 개념이 없다.
	Services []appGroupServiceInput `json:"services,omitempty"`
}

type appGroupServiceInput struct {
	Name           string              `json:"name"`
	Exposure       exposureInput       `json:"exposure"`
	Authentication authenticationInput `json:"authentication,omitempty"`
	NetworkPolicy  networkPolicyInput  `json:"networkPolicy,omitempty"`
	ResourceSize   string              `json:"resourceSize,omitempty"`
	Replicas       int                 `json:"replicas,omitempty"`
	// Secret 값은 API/Git에 싣지 않고 key 이름만 선언한다. 실제 값은 Generated
	// OpenBao 경로에 관리자가 별도로 넣는다.
	SecretKeys []string `json:"secretKeys,omitempty"`
}

// appGroupPlan은 검증 결과다. 서비스마다 단일 앱과 같은 형태의 계획을 담는다.
type appGroupPlan struct {
	Valid  bool           `json:"valid"`
	Group  appGroup       `json:"group"`
	Source appGroupSource `json:"source"`
	// 서비스마다 단일 앱 신청과 완전히 같은 형태의 계획을 담는다.
	Services []validationResponse `json:"services"`
	Warnings []string             `json:"warnings"`
	// 그룹 전체가 소모하는 자원. 사용자 상한은 앱이 아니라 사람 단위다.
	Quota quotaSummary `json:"quota"`
}

// appGroupCreated는 생성된 배포 요청 목록이다.
type appGroupCreated struct {
	Group    appGroup            `json:"group"`
	Requests []deploymentRequest `json:"requests"`
	Count    int                 `json:"count"`
}

// buildGroupProfiles는 Compose + 사용자 선택을 AppProfile 목록으로 바꾼다.
// 반환된 오류의 Field 는 화면이 어느 서비스의 어느 칸인지 짚을 수 있는 형태다.
func buildGroupProfiles(input *appGroupInput) ([]appProfileInput, []string, []fieldError) {
	parsed, err := parseCompose(input.Compose)
	if err != nil {
		var composeFailure composeError
		if failure, ok := err.(composeError); ok {
			composeFailure = failure
		} else {
			composeFailure = composeError{Field: "compose", Message: err.Error()}
		}
		return nil, nil, []fieldError{{Field: composeFailure.Field, Message: composeFailure.Message}}
	}
	return buildGroupProfilesFromParsed(input, parsed)
}

func buildGroupProfilesFromParsed(input *appGroupInput, parsed composeFile) ([]appProfileInput, []string, []fieldError) {
	input.Group = strings.TrimSpace(input.Group)
	input.Project = strings.TrimSpace(input.Project)
	input.Environment = strings.TrimSpace(input.Environment)
	input.ResourceSize = strings.TrimSpace(input.ResourceSize)

	if groupErrors := validateGroupName(input.Group); len(groupErrors) > 0 {
		return nil, nil, groupErrors
	}
	if input.Group == "" {
		return nil, nil, []fieldError{{Field: "group", Message: "앱 그룹 이름을 입력하세요."}}
	}
	settings := make(map[string]appGroupServiceInput, len(input.Services))
	settingErrors := make([]fieldError, 0)
	for index, service := range input.Services {
		name := strings.ToLower(strings.TrimSpace(service.Name))
		if _, duplicate := settings[name]; duplicate {
			settingErrors = append(settingErrors, fieldError{
				Field: fmt.Sprintf("services[%d].name", index), Message: "같은 서비스 설정을 두 번 보낼 수 없습니다.",
			})
			continue
		}
		service.Name = name
		settings[name] = service
	}
	known := make(map[string]int, len(parsed.Services))
	for _, service := range parsed.Services {
		known[service.Name] = service.Port
	}
	unknownErrors := settingErrors
	for name := range settings {
		if _, found := known[name]; !found {
			unknownErrors = append(unknownErrors, fieldError{
				Field:   "services." + name,
				Message: "Compose 파일에 없는 서비스입니다.",
			})
		}
	}
	if len(unknownErrors) > 0 {
		sort.Slice(unknownErrors, func(i, j int) bool { return unknownErrors[i].Field < unknownErrors[j].Field })
		return nil, parsed.Warnings, unknownErrors
	}

	profiles := make([]appProfileInput, 0, len(parsed.Services))
	profileErrors := make([]fieldError, 0)
	for _, service := range parsed.Services {
		setting := settings[service.Name]
		profile := appProfileInput{
			AppName:        service.Name,
			Group:          input.Group,
			Project:        input.Project,
			Environment:    input.Environment,
			ContainerPort:  service.Port,
			Exposure:       setting.Exposure,
			Authentication: setting.Authentication,
			NetworkPolicy:  setting.NetworkPolicy,
			ResourceSize:   input.ResourceSize,
			Replicas:       setting.Replicas,
		}
		if profile.Replicas == 0 {
			profile.Replicas = service.Replicas
		}
		if service.Port == 0 {
			profile.WorkloadMode = workloadWorker
		} else {
			profile.WorkloadMode = workloadService
		}
		if service.Volume != nil {
			profile.PersistenceMountPath = service.Volume.MountPath
		}
		if setting.ResourceSize != "" {
			profile.ResourceSize = strings.TrimSpace(setting.ResourceSize)
		}
		// 선택이 아예 없는 서비스는 가장 좁은 값으로 둔다. 사용자가 명시하지 않았는데
		// 외부에 열리거나 인터넷으로 나갈 수 있으면 안 된다.
		if profile.Exposure.Mode == "" && profile.Exposure.Legacy == "" {
			profile.Exposure.Mode = exposureInternal
		}
		if profile.NetworkPolicy.EgressMode == "" {
			profile.NetworkPolicy.EgressMode = egressBlocked
		}
		profile.Image = service.Image
		for key, value := range service.Config {
			profile.EnvVars = append(profile.EnvVars, envVarInput{
				Key: key, Value: value, Classification: "configmap",
			})
		}
		sort.Slice(profile.EnvVars, func(i, j int) bool { return profile.EnvVars[i].Key < profile.EnvVars[j].Key })
		declaredSeen := make(map[string]struct{}, len(setting.SecretKeys))
		for index, rawKey := range setting.SecretKeys {
			key := strings.TrimSpace(rawKey)
			field := fmt.Sprintf("services.%s.secretKeys[%d]", service.Name, index)
			if !envKeyPattern.MatchString(key) || len(key) > 128 {
				profileErrors = append(profileErrors, fieldError{
					Field: field, Message: "Secret key는 영문자/숫자/밑줄만 쓰고 숫자로 시작하지 않습니다.",
				})
				continue
			}
			if _, duplicate := declaredSeen[key]; duplicate {
				profileErrors = append(profileErrors, fieldError{Field: field, Message: key + " Secret key가 중복되었습니다."})
				continue
			}
			declaredSeen[key] = struct{}{}
			profile.DeclaredSecretKeys = append(profile.DeclaredSecretKeys, key)
		}
		if len(setting.SecretKeys) > maxAppEnvVars {
			profileErrors = append(profileErrors, fieldError{
				Field:   "services." + service.Name + ".secretKeys",
				Message: fmt.Sprintf("Secret key는 최대 %d개까지 선언할 수 있습니다.", maxAppEnvVars),
			})
		}
		sort.Strings(profile.DeclaredSecretKeys)

		for _, item := range validateInput(&profile) {
			profileErrors = append(profileErrors, fieldError{
				Field:   "services." + service.Name + "." + item.Field,
				Message: item.Message,
			})
		}
		// 앱 사이 연결은 같은 Compose 안의 서비스만 가리킬 수 있다. 이름이 틀리면
		// NetworkPolicy 는 만들어지지만 아무 Pod 도 선택하지 않아 조용히 막힌다.
		profileErrors = append(profileErrors, validateGroupPeers(service.Name, profile, known)...)
		profiles = append(profiles, profile)
	}
	return profiles, parsed.Warnings, profileErrors
}

func (api *apiServer) resolveGroupProfiles(
	ctx context.Context, input *appGroupInput,
) ([]appProfileInput, []string, appGroupSource, []fieldError, error) {
	input.Group = strings.TrimSpace(input.Group)
	input.Project = strings.TrimSpace(input.Project)
	input.Environment = strings.TrimSpace(input.Environment)
	input.ResourceSize = strings.TrimSpace(input.ResourceSize)
	metadataErrors := validateGroupName(input.Group)
	if input.Group == "" {
		metadataErrors = append(metadataErrors, fieldError{Field: "group", Message: "앱 그룹 이름을 입력하세요."})
	}
	if !allowsProject(input.Project) {
		metadataErrors = append(metadataErrors, fieldError{Field: "project", Message: "허용된 프로젝트를 선택하세요."})
	}
	if input.Environment != appEnvironment {
		metadataErrors = append(metadataErrors, fieldError{Field: "environment", Message: "현재 배포 환경을 사용하세요."})
	}
	if _, known := catalog().ResourcePresets[input.ResourceSize]; !known {
		metadataErrors = append(metadataErrors, fieldError{Field: "resourceSize", Message: "허용된 자원 크기를 선택하세요."})
	}
	if len(metadataErrors) > 0 {
		return nil, nil, appGroupSource{}, metadataErrors, nil
	}
	hasCompose := strings.TrimSpace(input.Compose) != ""
	hasRepository := strings.TrimSpace(input.Repository) != ""
	if !hasRepository && strings.TrimSpace(input.RepositoryRevision) != "" {
		return nil, nil, appGroupSource{}, []fieldError{{
			Field: "repositoryRevision", Message: "Git 저장소 주소 없이 revision만 지정할 수 없습니다.",
		}}, nil
	}
	if hasCompose == hasRepository {
		return nil, nil, appGroupSource{}, []fieldError{{
			Field: "repository", Message: "Compose 직접 입력과 Git 저장소 주소 중 하나만 입력하세요.",
		}}, nil
	}
	if hasCompose {
		profiles, warnings, validationErrors := buildGroupProfiles(input)
		return profiles, warnings, appGroupSource{Type: "compose"}, validationErrors, nil
	}
	if api.forgejo == nil {
		return nil, nil, appGroupSource{}, nil, repositoryImportError{
			Message: "Forgejo 연동이 준비되지 않아 Git 저장소를 읽을 수 없습니다.", Temporary: true,
		}
	}
	imported, err := api.forgejo.importRepository(ctx, input.Repository, input.RepositoryRevision)
	if err != nil {
		return nil, nil, appGroupSource{}, nil, err
	}
	profiles, warnings, validationErrors := buildGroupProfilesFromParsed(input, imported.Parsed)
	return profiles, warnings, imported.Source, validationErrors, nil
}

func writeRepositoryImportProblem(w http.ResponseWriter, err error) {
	var importFailure repositoryImportError
	if errors.As(err, &importFailure) && importFailure.Temporary {
		writeProblem(w, http.StatusServiceUnavailable,
			"urn:sadp:portal:problem:repository-unavailable", "Git 저장소 확인 실패",
			importFailure.Message, nil)
		return
	}
	detail := "Git 저장소에서 지원되는 Compose 또는 Helm Chart를 확인하지 못했습니다."
	if err != nil && strings.TrimSpace(err.Error()) != "" {
		detail = err.Error()
	}
	writeProblem(w, http.StatusUnprocessableEntity,
		"urn:sadp:portal:problem:repository-import", "Git 저장소 입력 검증 실패",
		detail, []fieldError{{Field: "repository", Message: detail}})
}

func validateGroupPeers(serviceName string, profile appProfileInput, known map[string]int) []fieldError {
	peerErrors := make([]fieldError, 0)
	checkEgress := func(field string, peers []appPeerInput) {
		for index, peer := range peers {
			targetPort, found := known[peer.App]
			if !found {
				peerErrors = append(peerErrors, fieldError{
					Field:   fmt.Sprintf("services.%s.%s[%d]", serviceName, field, index),
					Message: peer.App + " 서비스가 이 앱 그룹에 없습니다.",
				})
			} else if targetPort == 0 {
				peerErrors = append(peerErrors, fieldError{
					Field:   fmt.Sprintf("services.%s.%s[%d]", serviceName, field, index),
					Message: peer.App + " 는 포트를 듣지 않는 worker라 수신 연결 대상으로 선택할 수 없습니다.",
				})
			} else if peer.Port != targetPort {
				peerErrors = append(peerErrors, fieldError{
					Field:   fmt.Sprintf("services.%s.%s[%d].port", serviceName, field, index),
					Message: fmt.Sprintf("%s 서비스가 듣는 포트 %d를 사용하세요.", peer.App, targetPort),
				})
			}
		}
	}
	checkIngress := func(field string, peers []appPeerInput) {
		for index, peer := range peers {
			if _, found := known[peer.App]; !found {
				peerErrors = append(peerErrors, fieldError{
					Field:   fmt.Sprintf("services.%s.%s[%d]", serviceName, field, index),
					Message: peer.App + " 서비스가 이 앱 그룹에 없습니다.",
				})
			} else if peer.Port != 0 && peer.Port != profile.ContainerPort {
				peerErrors = append(peerErrors, fieldError{
					Field:   fmt.Sprintf("services.%s.%s[%d].port", serviceName, field, index),
					Message: fmt.Sprintf("현재 서비스가 듣는 포트 %d를 사용하세요.", profile.ContainerPort),
				})
			}
		}
	}
	checkEgress("networkPolicy.allowedApps", profile.NetworkPolicy.AllowedApps)
	checkIngress("networkPolicy.ingress.allowedApps", profile.NetworkPolicy.Ingress.AllowedApps)
	return peerErrors
}

// groupQuotaErrors는 그룹 전체 합계를 사용자 상한과 비교한다.
// 앱마다 통과해도 합치면 넘을 수 있다 — 상한은 앱이 아니라 사람 단위다.
func groupQuotaErrors(profiles []appProfileInput) ([]fieldError, quotaSummary) {
	presets := catalog().ResourcePresets
	var totalCPU, totalMemory int64
	totalPods := 0
	for _, profile := range profiles {
		totalPods += max(profile.Replicas, 1)
		preset, known := presets[profile.ResourceSize]
		if !known {
			continue
		}
		cpu, memory, err := quotaUsage(preset, max(profile.Replicas, 1))
		if err != nil {
			continue
		}
		totalCPU += cpu
		totalMemory += memory
	}
	summary := quotaSummary{
		Limit:      configuredUserQuota,
		UsedCPU:    formatCPUMilli(totalCPU),
		UsedMemory: formatMemoryBytes(totalMemory),
	}
	limitCPU, cpuErr := parseCPUMilli(configuredUserQuota.CPU)
	limitMemory, memoryErr := parseMemoryBytes(configuredUserQuota.Memory)
	if cpuErr != nil || memoryErr != nil {
		return []fieldError{{Field: "resourceSize", Message: "자원 상한 설정을 해석할 수 없습니다. 플랫폼 관리자에게 문의하세요."}}, summary
	}
	quotaFieldErrors := make([]fieldError, 0, 2)
	if totalPods > maxAppReplicas {
		quotaFieldErrors = append(quotaFieldErrors, fieldError{
			Field: "services", Message: fmt.Sprintf("앱 그룹 전체 Pod 수 %d가 Namespace 상한 %d를 넘습니다.", totalPods, maxAppReplicas),
		})
	}
	if totalCPU > limitCPU {
		quotaFieldErrors = append(quotaFieldErrors, fieldError{
			Field: "resourceSize",
			Message: fmt.Sprintf("앱 그룹 전체 CPU %s가 사용자당 상한 %s를 넘습니다.",
				summary.UsedCPU, configuredUserQuota.CPU),
		})
	}
	if totalMemory > limitMemory {
		quotaFieldErrors = append(quotaFieldErrors, fieldError{
			Field: "resourceSize",
			Message: fmt.Sprintf("앱 그룹 전체 메모리 %s가 사용자당 상한 %s를 넘습니다.",
				summary.UsedMemory, configuredUserQuota.Memory),
		})
	}
	return quotaFieldErrors, summary
}

// destructivePersistenceChange는 동일 앱의 기존 PVC를 Argo prune으로 잃을 변경만 찾는다.
// AppGroup PVC는 Application 소유 리소스라 enabled를 끄거나 mountPath를 바꾼 values가
// merge되는 순간 삭제/재생성될 수 있다. 이 변경은 일반 재배포가 아니라 명시적 앱 삭제
// 뒤 새 신청으로만 허용해 사용자가 데이터 삭제 경계를 분명히 넘도록 한다.
func destructivePersistenceChange(live, candidate normalizedProfile) (string, bool) {
	if !live.Persistence.Enabled {
		return "", false
	}
	if !candidate.Persistence.Enabled {
		return "기존 영구 저장소 사용을 끄면 해당 PVC 데이터가 삭제됩니다.", true
	}
	if live.Persistence.MountPath != candidate.Persistence.MountPath {
		return fmt.Sprintf("영구 저장 경로를 %s에서 %s(으)로 바꾸면 기존 PVC가 안전하게 연결되지 않습니다.",
			live.Persistence.MountPath, candidate.Persistence.MountPath), true
	}
	return "", false
}

func persistenceChangeErrors(requestStore *store, requester string, profiles []appProfileInput) []fieldError {
	if requestStore == nil {
		return nil
	}
	validationErrors := make([]fieldError, 0)
	for _, profile := range profiles {
		candidate := validationResult(profile, true).Profile
		live, exists := requestStore.liveProfile(requester, candidate)
		if !exists {
			continue
		}
		if reason, destructive := destructivePersistenceChange(live, candidate); destructive {
			validationErrors = append(validationErrors, fieldError{
				Field:   "services." + profile.AppName + ".persistence",
				Message: reason + " 앱 삭제를 명시적으로 완료한 뒤 새로 배포하세요.",
			})
		}
	}
	return validationErrors
}

func (api *apiServer) handleAppGroupValidation(w http.ResponseWriter, r *http.Request) {
	requester, valid := scopedRequester(r)
	if !valid {
		writeInvalidRequester(w)
		return
	}
	input, ok := decodeAppGroup(w, r)
	if !ok {
		return
	}
	profiles, warnings, source, validationErrors, resolveErr := api.resolveGroupProfiles(r.Context(), &input)
	if resolveErr != nil {
		writeRepositoryImportProblem(w, resolveErr)
		return
	}
	if len(validationErrors) == 0 {
		quotaErrors, _ := groupQuotaErrors(profiles)
		validationErrors = append(validationErrors, quotaErrors...)
		validationErrors = append(validationErrors,
			persistenceChangeErrors(api.store, requester, profiles)...)
	}
	if len(validationErrors) > 0 {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "앱 그룹 검증 실패",
			"입력 필드를 수정한 뒤 다시 요청하세요.", validationErrors)
		return
	}
	group := newAppGroup(input.Group, input.Project, input.Environment)
	if api.store != nil {
		if claim, exists := api.store.groupClaim(group.Name); exists &&
			(claim.Requester != requester || claim.Project != group.Project || claim.Environment != group.Environment) {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:app-group-owned", "이미 사용 중인 AppGroup",
				"다른 사용자, 프로젝트 또는 환경이 사용 중인 AppGroup 이름입니다.", nil)
			return
		}
	}
	_, summary := groupQuotaErrors(profiles)
	plan := appGroupPlan{
		Valid:    true,
		Group:    group,
		Source:   source,
		Services: make([]validationResponse, 0, len(profiles)),
		Warnings: warnings,
		Quota:    summary,
	}
	submissionEnabled := api.submissionEnabled()
	for _, profile := range profiles {
		plan.Services = append(plan.Services, validationResult(profile, submissionEnabled))
	}
	writeJSON(w, http.StatusOK, plan)
}

func (api *apiServer) handleCreateAppGroup(w http.ResponseWriter, r *http.Request) {
	requester, valid := scopedRequester(r)
	if !valid {
		writeInvalidRequester(w)
		return
	}
	if !api.submissionEnabled() {
		writeForgejoUnavailable(w)
		return
	}
	idempotencyKey, valid := validatedIdempotencyKey(r, true)
	if !valid {
		writeInvalidIdempotencyKey(w, true)
		return
	}
	input, raw, ok := readAppGroupBody(w, r)
	if !ok {
		return
	}
	profiles, _, source, validationErrors, resolveErr := api.resolveGroupProfiles(r.Context(), &input)
	if resolveErr != nil {
		writeRepositoryImportProblem(w, resolveErr)
		return
	}
	if len(validationErrors) == 0 {
		quotaErrors, _ := groupQuotaErrors(profiles)
		validationErrors = append(validationErrors, quotaErrors...)
	}
	if len(validationErrors) > 0 {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "앱 그룹 검증 실패",
			"입력 필드를 수정한 뒤 다시 요청하세요.", validationErrors)
		return
	}

	group := newAppGroup(input.Group, input.Project, input.Environment)
	// 이름 선점 확인부터 기록까지 한 임계구역으로 묶는다. 그룹 안의 앱 하나라도 남의
	// 것이면 아무것도 만들지 않는다 — 절반만 배포된 스택이 제일 다루기 어렵다.
	api.appMu.Lock()
	defer api.appMu.Unlock()
	claim, groupAlreadyClaimed := api.store.groupClaim(group.Name)
	if groupAlreadyClaimed &&
		(claim.Requester != requester || claim.Project != group.Project || claim.Environment != group.Environment) {
		writeProblem(w, http.StatusConflict,
			"urn:sadp:portal:problem:app-group-owned", "이미 사용 중인 AppGroup",
			"다른 사용자, 프로젝트 또는 환경이 사용 중인 AppGroup 이름입니다.", nil)
		return
	}
	// store에 없는 새 그룹은 같은 이름의 기존 Namespace도 없어야 한다. 그렇지 않으면
	// Argo가 운영자가 만든 Namespace를 포털 소유로 채택해 label/quota를 덮을 수 있다.
	// 클러스터 밖 개발 모드(builder=nil)는 실제 rollout을 수행하지 않으므로 이 검사는
	// in-cluster 자동 배포 경계에서 적용한다.
	if !groupAlreadyClaimed && api.forgejo.builder != nil {
		exists, err := api.forgejo.builder.namespaceExists(r.Context(), group.Namespace)
		if err != nil {
			writeProblem(w, http.StatusServiceUnavailable,
				"urn:sadp:portal:problem:namespace-check-unavailable", "AppGroup Namespace 확인 실패",
				"Kubernetes Namespace를 안전하게 확인할 수 없어 생성하지 않았습니다.", nil)
			return
		}
		if exists {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:namespace-owned", "이미 존재하는 AppGroup Namespace",
				"Portal 기록 밖에서 이미 존재하는 Namespace 이름입니다. 다른 AppGroup 이름을 사용하세요.", nil)
			return
		}
	}
	if api.store.groupDeletionInProgress(group.Name) {
		writeProblem(w, http.StatusConflict,
			"urn:sadp:portal:problem:app-group-deleting", "AppGroup 삭제 진행 중",
			"AppGroup 삭제와 정리가 끝난 뒤 같은 이름을 다시 신청하세요.", nil)
		return
	}
	for _, profile := range profiles {
		if claim, exists := api.store.appClaim(profile.Project, profile.Environment, profile.Group, profile.AppName); exists &&
			claim.Requester != requester {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:app-name-owned", "이미 사용 중인 앱 이름",
				profile.AppName+" 는 다른 사용자가 소유한 앱 이름입니다. Compose의 서비스 이름을 바꾸세요.", nil)
			return
		}
	}
	plannedProfiles := make([]normalizedProfile, 0, len(profiles))
	for _, profile := range profiles {
		normalized := validationResult(profile, true).Profile
		if live, exists := api.store.liveProfile(requester, normalized); exists {
			if reason, destructive := destructivePersistenceChange(live, normalized); destructive {
				writeProblem(w, http.StatusConflict,
					"urn:sadp:portal:problem:persistence-change", "영구 저장소 변경 거부",
					profile.AppName+" 앱: "+reason+" 앱 삭제를 명시적으로 완료한 뒤 새로 배포하세요.", nil)
				return
			}
		}
		if normalized.Exposure.Host != "" {
			if reservedPlatformHost(normalized.Exposure.Host) {
				writeProblem(w, http.StatusConflict,
					"urn:sadp:portal:problem:host-reserved", "플랫폼 예약 도메인",
					profile.AppName+" 서비스의 외부 도메인은 플랫폼 서비스가 사용합니다.", nil)
				return
			}
			if existing, exists := api.store.hostClaim(normalized.Exposure.Host); exists &&
				!sameAppIdentity(existing.Profile, normalized) {
				writeProblem(w, http.StatusConflict,
					"urn:sadp:portal:problem:host-owned", "이미 사용 중인 외부 도메인",
					profile.AppName+" 서비스의 외부 도메인을 다른 앱이 사용합니다.", nil)
				return
			}
		}
		plannedProfiles = append(plannedProfiles, normalized)
	}
	if quotaErrors := projectedQuotaErrors(api.store, requester, plannedProfiles); len(quotaErrors) > 0 {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:quota-exceeded", "사용자 자원 상한 초과",
			"기존 애플리케이션 사용량을 포함하면 사용자 또는 AppGroup 자원 상한을 넘습니다.", quotaErrors)
		return
	}
	if api.openbao == nil || registryPullRemotePath == "" {
		writeProblem(w, http.StatusServiceUnavailable,
			"urn:sadp:portal:problem:openbao-unavailable", "AppGroup Secret 연동 비활성",
			"OpenBao와 AppGroup registry pull 경로 설정을 확인한 뒤 다시 시도하세요.", nil)
		return
	}
	if err := api.openbao.grantGroupRegistryAccess(r.Context(), group, registryPullRemotePath); err != nil {
		writeProblem(w, http.StatusServiceUnavailable,
			"urn:sadp:portal:problem:registry-secret-unavailable", "AppGroup registry 연동 준비 안 됨",
			"고정 OpenBao registry role과 read-only pull credential을 확인한 뒤 다시 시도하세요.", nil)
		return
	}
	now := time.Now().UTC()
	created := appGroupCreated{Group: group, Requests: make([]deploymentRequest, 0, len(profiles))}
	pendingRecords := make([]storeRecord, 0, len(profiles))
	// Git 주소만 같은 요청이어도 기본 브랜치 commit이 바뀌면 내용이 다르다. 해석한
	// revision을 멱등 지문에 포함해 예전 결과를 새 Chart 결과로 오인하지 않는다.
	groupHash := hashBody(append(append([]byte{}, raw...), []byte("\x00"+source.Revision)...))
	newRequests := 0
	for _, profile := range profiles {
		result := validationResult(profile, true)
		derivedKey := groupServiceIdempotencyKey(requester, idempotencyKey, group, profile.AppName)
		bodyHash := groupServiceBodyHash(groupHash, profile.AppName)
		if existing, storedHash, found := api.store.findByIdempotency(derivedKey); found {
			identityMatches := existing.Requester == requester &&
				existing.Profile.App.Project == profile.Project &&
				existing.Profile.App.Environment == profile.Environment &&
				existing.Profile.App.Group == profile.Group && existing.Profile.App.Name == profile.AppName
			if storedHash != bodyHash || !identityMatches {
				writeProblem(w, http.StatusConflict,
					"urn:sadp:portal:problem:idempotency-conflict", "Idempotency-Key 재사용",
					"같은 Idempotency-Key로 다른 AppGroup 내용을 보낼 수 없습니다.", nil)
				return
			}
			created.Requests = append(created.Requests, existing)
			continue
		}
		id, err := newRequestID()
		if err != nil {
			writeProblem(w, http.StatusInternalServerError,
				"urn:sadp:portal:problem:internal", "요청 식별자 생성 실패",
				"잠시 후 다시 시도하세요.", nil)
			return
		}
		request := deploymentRequest{
			ID:        id,
			State:     stateReceived,
			CreatedAt: now,
			UpdatedAt: now,
			Requester: requester,
			Profile:   result.Profile,
			Generated: result.Generated,
		}
		created.Requests = append(created.Requests, request)
		requestCopy := request
		pendingRecords = append(pendingRecords, storeRecord{
			Kind: "create", IdempotencyKey: derivedKey, BodyHash: bodyHash, Request: &requestCopy,
		})
		newRequests++
	}
	// 모든 서비스 요청이 durable해진 뒤에만 하나씩 queue에 보낸다. 재시도는 파생 키로
	// 이미 저장된 서비스와 아직 없는 서비스를 구분해 중단 지점부터 복원한다.
	if err := api.store.createBatch(pendingRecords); err != nil {
		if errors.Is(err, errArtifactClaimed) {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:artifact-claimed", "배포 대상이 이미 사용 중",
				"AppGroup의 GitOps 경로 또는 Kubernetes 리소스를 다른 배포가 사용 중입니다.", nil)
			return
		}
		writeProblem(w, http.StatusInternalServerError,
			"urn:sadp:portal:problem:storage-unavailable", "요청 저장 실패",
			"저장소에 기록하지 못했습니다. 플랫폼 관리자에게 문의하세요.", nil)
		return
	}
	for _, request := range created.Requests {
		if request.State != stateReceived {
			continue
		}
		if err := api.forgejo.enqueue(request.ID); err != nil {
			// received 상태를 보존해야 같은 키 재시도나 프로세스 재시작이 queue 작업을
			// 복원할 수 있다. 영구 실패로 바꾸면 이미 저장된 스택이 고립된다.
			w.Header().Set("Retry-After", "60")
			writeProblem(w, http.StatusServiceUnavailable,
				"urn:sadp:portal:problem:queue-full", "처리 대기열 포화",
				"요청은 안전하게 저장되었습니다. 같은 Idempotency-Key로 다시 시도하세요.", nil)
			return
		}
	}
	created.Count = len(created.Requests)
	w.Header().Set("Location", "/api/v1/deployment-requests?group="+group.Name)
	status := http.StatusAccepted
	if newRequests == 0 {
		status = http.StatusOK
	}
	writeJSON(w, status, created)
}
