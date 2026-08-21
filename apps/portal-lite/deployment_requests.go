package main

// 배포 요청 API. 요청을 PVC에 먼저 기록(202)하고, Forgejo Pull Request 생성은
// 백그라운드 워커가 이어받는다. Forgejo 미설정 시에는 기존과 같이 503을 돌려준다.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	maxIdempotencyKeyLength = 128
	maxRequesterLength      = 128
	// Next.js route handler(서버 사이드)만 도달할 수 있는 loopback 전용 헤더다.
	// Go API는 127.0.0.1에만 바인딩하므로 외부에서 이 헤더를 위조할 수 없다.
	requesterHeader = "X-Portal-User"
)

type apiServer struct {
	store   *store
	forgejo *forgejoClient
	openbao *openBaoClient
	appMu   sync.Mutex
	// prober는 클러스터 안에서만 생성된다. nil이면 카탈로그 상태는 정적 값을 쓴다.
	prober *statusProber
}

// submissionEnabled는 Forgejo 연동이 갖춰졌을 때만 참이다.
func (api *apiServer) submissionEnabled() bool {
	return api != nil && api.store != nil && api.forgejo != nil
}

func newRequestID() (string, error) {
	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

// safeHeaderValue는 헤더 값에서 제어문자를 걸러내고 길이를 제한한다.
func safeHeaderValue(value string, limit int) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > limit {
		return ""
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return ""
		}
	}
	return value
}

// scopedRequester는 포털의 서버 사이드 세션이 전달한 신원만 신뢰한다.
// query fallback은 브라우저가 남의 이름을 직접 넣을 수 있으므로 두지 않는다.
func scopedRequester(r *http.Request) (string, bool) {
	header := strings.TrimSpace(r.Header.Get(requesterHeader))
	if header == "" {
		return "", false
	}
	value := safeHeaderValue(header, maxRequesterLength)
	if value == "" {
		return "", false
	}
	return value, true
}

func writeInvalidRequester(w http.ResponseWriter) {
	writeProblem(w, http.StatusBadRequest,
		"urn:sadp:portal:problem:invalid-requester", "요청자 신원을 확인할 수 없음",
		requesterHeader+" 헤더는 필수이며 "+strconv.Itoa(maxRequesterLength)+"자 이하여야 합니다.", nil)
}

// validatedIdempotencyKey는 로그 색인에 그대로 들어갈 키를 제한한다. AppGroup은
// 서비스 여러 건을 한 요청으로 복원해야 하므로 키 생략을 허용하지 않는다.
func validatedIdempotencyKey(r *http.Request, required bool) (string, bool) {
	raw := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if raw == "" {
		return "", !required
	}
	if safeHeaderValue(raw, maxIdempotencyKeyLength) == "" {
		return "", false
	}
	for _, character := range raw {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || strings.ContainsRune("._:-", character) {
			continue
		}
		return "", false
	}
	return raw, true
}

func writeInvalidIdempotencyKey(w http.ResponseWriter, required bool) {
	detail := "Idempotency-Key는 영문자, 숫자, 점, 밑줄, 콜론, 하이픈만 포함하고 " +
		strconv.Itoa(maxIdempotencyKeyLength) + "자 이하여야 합니다."
	if required {
		detail = "배포 생성에는 Idempotency-Key 헤더가 필요합니다. " + detail
	}
	writeProblem(w, http.StatusBadRequest,
		"urn:sadp:portal:problem:invalid-idempotency-key", "멱등 키가 올바르지 않음", detail, nil)
}

func writeForgejoUnavailable(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "86400")
	writeProblem(w, http.StatusServiceUnavailable,
		"urn:sadp:portal:problem:forgejo-not-configured", "배포 요청 기능 비활성",
		"플랫폼 공용 Forgejo 봇 자격증명(FORGEJO_BOT_TOKEN)이 준비되지 않았습니다. 관리자에게 Portal 런타임 연동을 요청하세요.", nil)
}

func writeOpenBaoContractUnavailable(w http.ResponseWriter, profile normalizedProfile) {
	title := "앱 Secret 계약 준비 안 됨"
	detail := "앱의 canonical OpenBao 경로와 ExternalSecret key가 준비되지 않았습니다. 플랫폼 관리자에게 시드를 요청하세요."
	if profile.authMode() == authOIDC {
		title = "OIDC 인증 준비 안 됨"
		detail = "Keycloak client ID, /oauth2/callback, 허용 그룹과 OpenBao OIDC client secret 계약을 관리자가 준비해야 합니다."
	}
	writeProblem(w, http.StatusServiceUnavailable,
		"urn:sadp:portal:problem:openbao-contract-unavailable", title, detail, nil)
}

// readProfileBody는 본문 원본과 파싱 결과를 함께 돌려준다.
// 원본은 Idempotency-Key 재요청이 같은 내용인지 비교하는 지문 계산에 쓴다.
func readProfileBody(w http.ResponseWriter, r *http.Request) (appProfileInput, []byte, bool) {
	var input appProfileInput

	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeProblem(w, http.StatusUnsupportedMediaType,
			"urn:sadp:portal:problem:unsupported-media-type", "지원하지 않는 본문 형식",
			"Content-Type은 application/json이어야 합니다.", nil)
		return input, nil, false
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeProblem(w, http.StatusRequestEntityTooLarge,
				"urn:sadp:portal:problem:payload-too-large", "요청 본문 제한 초과",
				"JSON 요청은 64 KiB 이하여야 합니다.", nil)
			return input, nil, false
		}
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "요청 본문 읽기 실패",
			"요청을 다시 보내세요.", nil)
		return input, nil, false
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "JSON 요청 해석 실패",
			"알 수 없는 필드 없이 하나의 올바른 JSON 객체를 보내세요.", nil)
		return input, nil, false
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-json", "JSON 요청 해석 실패",
			"요청 본문에는 JSON 객체 하나만 허용합니다.", nil)
		return input, nil, false
	}
	return input, raw, true
}

// hashProfileInput은 멱등 비교에 Secret 값 자체나 그 단순 SHA를 남기지 않는다. PVC를
// 읽은 공격자가 짧은 비밀번호 후보를 offline 대입할 수 있기 때문이다. OpenBao 쓰기가
// 끝난 요청은 재전송 값을 다시 쓰지 않고 기존 결과만 반환하며, pending 재시도에서는
// 앞선 쓰기가 성공하지 않았으므로 같은 비-Secret 프로필의 값을 다시 받는 것이 안전하다.
func hashProfileInput(input appProfileInput) string {
	redacted := input
	// exposureInput.MarshalJSON은 의도적으로 새 객체 형태만 내보내므로 Legacy 값은
	// 그대로 marshal하면 public과 oidc가 모두 빈 mode로 축약된다. 멱등 지문을 만들기
	// 전에 두 형식을 같은 의미 축으로 정규화해 인증 정책 변경을 replay로 오인하지 않는다.
	exposure, authentication := resolveAccess(&redacted)
	redacted.Exposure = exposureInput{Mode: exposure}
	redacted.Authentication = authenticationInput{Mode: authentication}
	redacted.EnvVars = append([]envVarInput(nil), input.EnvVars...)
	for index := range redacted.EnvVars {
		if redacted.EnvVars[index].Classification == "openbao" {
			redacted.EnvVars[index].Value = ""
		}
	}
	encoded, _ := json.Marshal(redacted)
	return hashBody(encoded)
}

func (api *apiServer) handleCreateDeploymentRequest(w http.ResponseWriter, r *http.Request) {
	requester, valid := scopedRequester(r)
	if !valid {
		writeInvalidRequester(w)
		return
	}
	if !api.submissionEnabled() {
		writeForgejoUnavailable(w)
		return
	}

	input, raw, ok := readProfileBody(w, r)
	if !ok {
		return
	}
	if validationErrors := validateInput(&input); len(validationErrors) > 0 {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:validation-error", "AppProfile 검증 실패",
			"입력 필드를 수정한 뒤 다시 요청하세요.", validationErrors)
		return
	}

	_ = raw // 원본은 크기/단일 JSON 검증에 사용했고, 지문은 정규화·redact한 입력으로 만든다.
	bodyHash := hashProfileInput(input)
	idempotencyKey, valid := validatedIdempotencyKey(r, false)
	if !valid {
		writeInvalidIdempotencyKey(w, false)
		return
	}
	hasSecretValues := false
	for _, item := range input.EnvVars {
		if item.Classification == "openbao" {
			hasSecretValues = true
			break
		}
	}
	if hasSecretValues && idempotencyKey == "" {
		writeProblem(w, http.StatusBadRequest,
			"urn:sadp:portal:problem:invalid-idempotency-key", "Secret 신청 멱등 키 누락",
			"OpenBao Secret 값을 포함한 배포에는 Idempotency-Key 헤더가 필요합니다.", nil)
		return
	}
	result := validationResult(input, true)
	// 앱 이름 소유권 확인부터 Secret 저장과 신청 기록까지 한 임계구역으로 묶는다.
	// 동시에 온 두 사용자가 같은 OpenBao 경로를 선점하는 경쟁을 막는다.
	api.appMu.Lock()
	defer api.appMu.Unlock()

	// 같은 키로 다시 들어온 요청은 새 PR을 만들지 않고 이전 결과를 그대로 돌려준다.
	// 요청자 확인도 함께 해야 다른 사용자가 키와 본문을 추측해 신청 내용을 읽지 못한다.
	if idempotencyKey != "" {
		if existing, storedHash, found := api.store.findByIdempotency(idempotencyKey); found {
			if storedHash != bodyHash || existing.Requester != requester {
				writeProblem(w, http.StatusConflict,
					"urn:sadp:portal:problem:idempotency-conflict", "Idempotency-Key 재사용",
					"같은 Idempotency-Key로 다른 요청이나 요청자의 내용을 보낼 수 없습니다.", nil)
				return
			}
			if existing.SecretWritePending {
				secrets := make(map[string]string)
				for _, item := range input.EnvVars {
					if item.Classification == "openbao" {
						secrets[item.Key] = item.Value
					}
				}
				if len(secrets) == 0 || api.openbao == nil {
					writeProblem(w, http.StatusServiceUnavailable,
						"urn:sadp:portal:problem:openbao-unavailable", "Secret 저장 재시도 실패",
						"같은 신청의 Secret 값을 다시 입력한 뒤 재시도하세요.", nil)
					return
				}
				if err := api.openbao.put(r.Context(), existing.Generated.OpenBaoPath, secrets); err != nil {
					w.Header().Set("Location", "/api/v1/deployment-requests/"+existing.ID)
					writeProblem(w, http.StatusBadGateway,
						"urn:sadp:portal:problem:openbao-write-failed", "Secret 저장 실패",
						"OpenBao에 Secret을 저장하지 못했습니다. 같은 요청으로 다시 시도하세요.", nil)
					return
				}
				if err := api.openbao.grantESOAccessAt(r.Context(), existing.Profile,
					existing.Profile.namespace(), existing.Generated.OpenBaoPath); err != nil {
					writeOpenBaoContractUnavailable(w, existing.Profile)
					return
				}
				existing.SecretWritePending = false
				existing.State = stateReceived
				existing.FailedFromState = ""
				existing.Message = ""
				if err := api.store.update(existing); err != nil {
					writeProblem(w, http.StatusInternalServerError,
						"urn:sadp:portal:problem:storage-unavailable", "Secret 상태 저장 실패",
						"같은 요청으로 다시 시도하세요.", nil)
					return
				}
			}
			if existing.State == stateReceived {
				if err := api.forgejo.enqueue(existing.ID); err != nil {
					w.Header().Set("Retry-After", "60")
					writeProblem(w, http.StatusServiceUnavailable,
						"urn:sadp:portal:problem:queue-full", "처리 대기열 포화",
						"요청은 안전하게 저장되었습니다. 같은 Idempotency-Key로 다시 시도하세요.", nil)
					return
				}
			}
			w.Header().Set("Location", "/api/v1/deployment-requests/"+existing.ID)
			writeJSON(w, http.StatusOK, existing)
			return
		}
	}
	if claim, exists := api.store.appClaim(result.Profile.App.Project, result.Profile.App.Environment,
		result.Profile.App.Group, result.Profile.App.Name); exists && claim.Requester != requester {
		writeProblem(w, http.StatusConflict,
			"urn:sadp:portal:problem:app-name-owned", "이미 사용 중인 앱 이름",
			"다른 사용자, 프로젝트 또는 AppGroup이 사용 중인 앱 이름입니다. 다른 이름을 선택하세요.", nil)
		return
	}
	if result.Profile.Exposure.Host != "" {
		if reservedPlatformHost(result.Profile.Exposure.Host) {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:host-reserved", "플랫폼 예약 도메인",
				"플랫폼 서비스가 사용하는 외부 도메인입니다. 앱 또는 AppGroup 이름을 바꾸세요.", nil)
			return
		}
		if existing, exists := api.store.hostClaim(result.Profile.Exposure.Host); exists &&
			!sameAppIdentity(existing.Profile, result.Profile) {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:host-owned", "이미 사용 중인 외부 도메인",
				"다른 앱이 같은 외부 도메인을 사용합니다. 앱 또는 AppGroup 이름을 바꾸세요.", nil)
			return
		}
	}
	if result.Profile.App.Group != "" {
		group := newAppGroup(result.Profile.App.Group, result.Profile.App.Project, result.Profile.App.Environment)
		claim, groupAlreadyClaimed := api.store.groupClaim(group.Name)
		if groupAlreadyClaimed &&
			(claim.Requester != requester || claim.Project != group.Project || claim.Environment != group.Environment) {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:app-group-owned", "이미 사용 중인 AppGroup",
				"다른 사용자, 프로젝트 또는 환경이 사용 중인 AppGroup 이름입니다.", nil)
			return
		}
		// Compose 전용 endpoint뿐 아니라 호환 AppProfile의 group 입력도 Namespace
		// bootstrap을 만든다. 새 store claim인데 같은 app-<group> Namespace가 이미 있으면
		// 운영자 리소스를 포털 소유로 채택해 label/quota/default-deny를 덮게 되므로,
		// 저장 전에 같은 fail-close 검사를 적용한다.
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
		if api.store.groupDeletionInProgress(result.Profile.App.Group) {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:app-group-deleting", "AppGroup 삭제 진행 중",
				"AppGroup 삭제와 정리가 끝난 뒤 다시 신청하세요.", nil)
			return
		}
	}
	if quotaErrors := projectedQuotaErrors(api.store, requester, []normalizedProfile{result.Profile}); len(quotaErrors) > 0 {
		writeProblem(w, http.StatusUnprocessableEntity,
			"urn:sadp:portal:problem:quota-exceeded", "사용자 자원 상한 초과",
			"기존 애플리케이션 사용량을 포함하면 사용자 자원 상한을 넘습니다.", quotaErrors)
		return
	}
	if profileNeedsESO(result.Profile) && api.openbao == nil {
		writeProblem(w, http.StatusServiceUnavailable,
			"urn:sadp:portal:problem:openbao-unavailable", "Secret 저장 기능 비활성",
			"OpenBao 연결을 확인한 뒤 다시 시도하세요.", nil)
		return
	}
	if result.Profile.Source.Image == "" && api.forgejo.builder != nil {
		if err := api.forgejo.builder.requireBuildCredential(r.Context()); err != nil {
			writeProblem(w, http.StatusServiceUnavailable,
				"urn:sadp:portal:problem:build-credential-unavailable", "이미지 빌드 준비 안 됨",
				"별도의 registry push credential을 설치한 뒤 다시 시도하세요.", nil)
			return
		}
	}
	secrets := make(map[string]string)
	for _, item := range input.EnvVars {
		if item.Classification == "openbao" {
			secrets[item.Key] = item.Value
		}
	}
	usesPullSecret := result.Profile.Source.Image == ""
	if result.Profile.Source.Image != "" {
		repository, _, _ := splitPrebuiltImage(result.Profile.Source.Image)
		usesPullSecret = prebuiltImageUsesPullSecret(repository)
	}
	if usesPullSecret && result.Profile.App.Group == "" && api.forgejo.builder != nil {
		if err := api.forgejo.builder.requireRegistryPullCredential(r.Context(), result.Profile.namespace()); err != nil {
			writeProblem(w, http.StatusServiceUnavailable,
				"urn:sadp:portal:problem:registry-pull-unavailable", "Registry pull 인증 준비 안 됨",
				"플랫폼 Registry pull ExternalSecret이 아직 동기화되지 않았습니다. 관리자에게 Zone 자격증명 준비를 요청하세요.", nil)
			return
		}
	}
	if result.Profile.App.Group != "" {
		group, _ := groupOf(result.Profile)
		if registryPullRemotePath == "" ||
			api.openbao.grantGroupRegistryAccess(r.Context(), group, registryPullRemotePath) != nil {
			writeProblem(w, http.StatusServiceUnavailable,
				"urn:sadp:portal:problem:registry-pull-unavailable", "Registry pull 인증 준비 안 됨",
				"AppGroup용 OpenBao Registry pull 계약이 준비되지 않았습니다. 플랫폼 관리자에게 문의하세요.", nil)
			return
		}
	}
	// 사용자가 새 runtime 값을 보내지 않는 OIDC/사전 시드 앱은 durable 신청을 만들기
	// 전에 path·role·key를 모두 확인한다. runtime 값이 있으면 안전하게 쓴 직후 같은 검사를 한다.
	if profileNeedsAppESO(result.Profile) && len(secrets) == 0 {
		if err := api.openbao.grantESOAccessAt(r.Context(), result.Profile,
			result.Profile.namespace(), result.Generated.OpenBaoPath); err != nil {
			writeOpenBaoContractUnavailable(w, result.Profile)
			return
		}
	}
	id, err := newRequestID()
	if err != nil {
		writeProblem(w, http.StatusInternalServerError,
			"urn:sadp:portal:problem:internal", "요청 식별자 생성 실패",
			"잠시 후 다시 시도하세요.", nil)
		return
	}
	now := time.Now().UTC()
	request := deploymentRequest{
		ID:                 id,
		State:              stateReceived,
		CreatedAt:          now,
		UpdatedAt:          now,
		Requester:          requester,
		Profile:            result.Profile,
		Generated:          result.Generated,
		SecretWritePending: len(secrets) > 0,
	}

	if err := api.store.create(request, idempotencyKey, bodyHash); err != nil {
		if errors.Is(err, errArtifactClaimed) {
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:artifact-claimed", "배포 대상이 이미 사용 중",
				"같은 앱 이름의 GitOps 경로 또는 Kubernetes 리소스를 다른 배포가 사용 중입니다.", nil)
			return
		}
		writeProblem(w, http.StatusInternalServerError,
			"urn:sadp:portal:problem:storage-unavailable", "요청 저장 실패",
			"저장소에 기록하지 못했습니다. 플랫폼 관리자에게 문의하세요.", nil)
		return
	}
	if request.SecretWritePending {
		if err := api.openbao.put(r.Context(), result.Generated.OpenBaoPath, secrets); err != nil {
			request.State = stateFailed
			request.FailedFromState = stateReceived
			request.Message = "OpenBao Secret 저장에 실패했습니다. 같은 신청으로 다시 시도하세요."
			_ = api.store.update(request)
			w.Header().Set("Location", "/api/v1/deployment-requests/"+id)
			writeProblem(w, http.StatusBadGateway,
				"urn:sadp:portal:problem:openbao-write-failed", "Secret 저장 실패",
				"요청은 안전하게 저장됐습니다. 같은 Idempotency-Key와 Secret 값으로 다시 시도하세요.", nil)
			return
		}
		request.SecretWritePending = false
		if err := api.openbao.grantESOAccessAt(r.Context(), result.Profile,
			result.Profile.namespace(), result.Generated.OpenBaoPath); err != nil {
			request.State = stateFailed
			request.FailedFromState = stateReceived
			request.Message = "앱 Secret 계약 검증에 실패했습니다. 플랫폼 관리자에게 문의하세요."
			_ = api.store.update(request)
			w.Header().Set("Location", "/api/v1/deployment-requests/"+id)
			writeOpenBaoContractUnavailable(w, result.Profile)
			return
		}
		if err := api.store.update(request); err != nil {
			writeProblem(w, http.StatusInternalServerError,
				"urn:sadp:portal:problem:storage-unavailable", "Secret 상태 저장 실패",
				"같은 요청으로 다시 시도하세요.", nil)
			return
		}
	}

	// 저장이 끝난 뒤에만 워커에 넘긴다. 큐가 가득 차도 요청 기록은 남는다.
	if err := api.forgejo.enqueue(id); err != nil {
		// durable received 상태를 보존해야 같은 Idempotency-Key 재시도와 재시작이
		// queue 전달만 복구할 수 있다. failed로 바꾸면 멱등 replay가 고립된다.
		w.Header().Set("Retry-After", "60")
		writeProblem(w, http.StatusServiceUnavailable,
			"urn:sadp:portal:problem:queue-full", "처리 대기열 포화",
			"현재 처리 중인 요청이 많습니다. 잠시 후 다시 시도하세요.", nil)
		return
	}

	w.Header().Set("Location", "/api/v1/deployment-requests/"+id)
	writeJSON(w, http.StatusAccepted, request)
}

// 조회 경로는 Forgejo 연동 여부와 무관하게 저장소를 그대로 읽는다.
// 연동 전에는 저장된 요청이 없어 빈 목록이 나갈 뿐이고, 신청(POST)만 503이다.
func (api *apiServer) handleGetDeploymentRequest(w http.ResponseWriter, r *http.Request) {
	requester, valid := scopedRequester(r)
	if !valid {
		writeInvalidRequester(w)
		return
	}
	request, ok := api.store.get(r.PathValue("requestID"))
	if !ok {
		writeProblem(w, http.StatusNotFound,
			"urn:sadp:portal:problem:not-found", "요청을 찾을 수 없음",
			"요청 ID를 확인하세요.", nil)
		return
	}
	// 다른 사용자의 ID를 알아도 존재 여부까지 노출하지 않는다.
	if request.Requester != requester {
		writeProblem(w, http.StatusNotFound,
			"urn:sadp:portal:problem:not-found", "요청을 찾을 수 없음",
			"요청 ID를 확인하세요.", nil)
		return
	}
	request = api.reconcileDeploymentRequest(r.Context(), request)
	writeJSON(w, http.StatusOK, request)
}

// reconcileDeploymentRequest는 저장된 상태와 실제 클러스터 상태가 어긋난 경우 조회
// 요청 안에서 한 번만 보정한다. 긴 파이프라인 timeout 직후 Ready/삭제가 완료되어도
// 사용자가 다음 새로고침에서 수 분을 더 기다리지 않게 한다.
func (api *apiServer) reconcileDeploymentRequest(ctx context.Context, request deploymentRequest) deploymentRequest {
	if api == nil || api.store == nil || api.forgejo == nil || api.forgejo.builder == nil {
		return request
	}
	if request.DeletionRequested {
		// Deployment가 사라진 것만으로 삭제를 완료 처리하지 않는다. AppGroup Namespace,
		// registry SecretStore, OpenBao ESO role까지 worker가 순서대로 정리해야 한다.
		return request
	}
	if lifecycleFailure(request) {
		lifecycleState := request.FailedFromState
		// worker가 실패를 기록하고 끝난 뒤 실제 클러스터가 늦게 수렴한 경우만
		// 보정한다. 실행 중인 worker 상태를 먼저 terminal로 바꾸면 사용자가 start/delete를
		// 시작한 뒤 이전 worker snapshot이 그 새 상태를 덮는 경쟁이 생긴다.
		if !request.RuntimeApplicationSynced && request.RuntimeDesiredRevision != "" {
			synced, err := api.forgejo.runtimeApplicationSynced(ctx, request, request.RuntimeDesiredRevision)
			if err != nil || !synced {
				return request
			}
			replacement := request
			replacement.RuntimeApplicationSynced = true
			updated, applied, err := api.store.updateIfCurrent(request, replacement)
			if err != nil {
				return request
			}
			if !applied {
				return updated
			}
			request = updated
		}
		if !request.RuntimeApplicationSynced {
			return request
		}
		converged := false
		if lifecycleState == stateStopping {
			converged, _ = api.forgejo.builder.deploymentStopped(ctx, request)
		} else {
			converged, _ = api.forgejo.builder.deploymentReady(ctx, request, request.Generated.Image)
		}
		if converged {
			replacement := request
			replacement.State = runtimeTerminalState(requestRuntimeState(request))
			replacement.FailedFromState = ""
			replacement.Message = ""
			updated, applied, err := api.store.updateIfCurrent(request, replacement)
			if err == nil {
				if applied {
					request = updated
				} else {
					return updated
				}
			}
		}
		return request
	}
	if request.State == stateFailed {
		// 같은 image를 쓰는 재배포에서는 이전 Deployment가 이미 Ready일 수 있다.
		// target revision을 Argo가 관찰했다는 증거 없이는 노출/SSO 정책 적용 성공으로 승격하지 않는다.
		if !request.ApplicationSynced && request.DesiredRevision != "" {
			synced, err := api.forgejo.builder.applicationRevisionSynced(ctx, request, request.DesiredRevision)
			if err != nil || !synced {
				return request
			}
			replacement := request
			replacement.ApplicationSynced = true
			updated, applied, err := api.store.updateIfCurrent(request, replacement)
			if err != nil {
				return request
			}
			if !applied {
				return updated
			}
			request = updated
		}
		if request.State == stateFailed && !request.ApplicationSynced {
			return request
		}
		if ready, err := api.forgejo.builder.deploymentReady(ctx, request, request.Generated.Image); err == nil && ready {
			replacement := request
			replacement.State = stateDeployed
			replacement.Message = ""
			updated, applied, updateErr := api.store.updateIfCurrent(request, replacement)
			if updateErr == nil {
				if applied {
					request = updated
				} else {
					return updated
				}
			}
		}
	}
	return request
}

// handleDeleteDeploymentRequest는 로그인 사용자가 현재 소유한 최신 앱만 삭제 queue에 넣는다.
// 원본 source repository와 registry image 이력은 건드리지 않고 GitOps/Zone 리소스만 정리한다.
func (api *apiServer) handleDeleteDeploymentRequest(w http.ResponseWriter, r *http.Request) {
	requester, valid := scopedRequester(r)
	if !valid {
		writeInvalidRequester(w)
		return
	}
	if !api.submissionEnabled() {
		writeForgejoUnavailable(w)
		return
	}
	// 생성 handler와 삭제 전환을 같은 잠금으로 직렬화한다. AppGroup 마지막 앱 판정 뒤
	// 새 서비스가 들어와 Namespace를 함께 잃는 경쟁을 store의 deletion flag와 같이 막는다.
	api.appMu.Lock()
	defer api.appMu.Unlock()
	request, enqueue, err := api.store.beginDelete(r.PathValue("requestID"), requester)
	if err != nil {
		switch {
		case errors.Is(err, errDeleteNotFound):
			writeProblem(w, http.StatusNotFound,
				"urn:sadp:portal:problem:not-found", "앱을 찾을 수 없음",
				"삭제할 앱을 찾을 수 없습니다.", nil)
		case errors.Is(err, errDeleteStale):
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:stale-request", "최신 앱 요청이 아님",
				"내 애플리케이션 목록을 새로고침한 뒤 최신 항목에서 삭제하세요.", nil)
		case errors.Is(err, errDeleteInProgress):
			writeProblem(w, http.StatusConflict,
				"urn:sadp:portal:problem:deployment-in-progress", "배포 진행 중",
				"빌드 또는 배포가 끝난 뒤 삭제하세요.", nil)
		default:
			writeProblem(w, http.StatusInternalServerError,
				"urn:sadp:portal:problem:storage-unavailable", "삭제 상태 저장 실패",
				"잠시 후 다시 시도하세요.", nil)
		}
		return
	}
	if enqueue {
		if err := api.forgejo.enqueue(request.ID); err != nil {
			replacement := request
			replacement.FailedFromState = request.State
			replacement.State = stateFailed
			replacement.Message = "삭제 처리 대기열이 가득 찼습니다. 잠시 후 다시 시도하세요."
			if updated, applied, updateErr := api.store.updateIfCurrent(request, replacement); updateErr == nil && applied {
				request = updated
			} else {
				request = replacement
			}
			w.Header().Set("Retry-After", "60")
			writeProblem(w, http.StatusServiceUnavailable,
				"urn:sadp:portal:problem:queue-full", "처리 대기열 포화",
				request.Message, nil)
			return
		}
	}
	status := http.StatusAccepted
	if request.State == stateDeleted {
		status = http.StatusOK
	}
	writeJSON(w, status, request)
}

type deploymentRequestList struct {
	Items     []deploymentRequest `json:"items"`
	Count     int                 `json:"count"`
	Limit     int                 `json:"limit"`
	Requester string              `json:"requester,omitempty"`
}

func (api *apiServer) handleListDeploymentRequests(w http.ResponseWriter, r *http.Request) {
	requester, ok := scopedRequester(r)
	if !ok {
		writeInvalidRequester(w)
		return
	}
	limit := maxRequestList
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > maxRequestList {
			writeProblem(w, http.StatusBadRequest,
				"urn:sadp:portal:problem:invalid-query", "limit 값이 올바르지 않음",
				"limit은 1 이상 "+strconv.Itoa(maxRequestList)+" 이하의 정수여야 합니다.", nil)
			return
		}
		limit = parsed
	}
	items := api.store.list(limit, requester)
	for index := range items {
		items[index] = api.reconcileDeploymentRequest(r.Context(), items[index])
	}
	writeJSON(w, http.StatusOK, deploymentRequestList{
		Items:     items,
		Count:     len(items),
		Limit:     limit,
		Requester: requester,
	})
}

// quotaUsageResponse는 대시보드 "내 자원 사용량" 막대가 쓰는 값이다.
// 막대와 위저드 검증이 다른 숫자를 보면 안 되므로 상한·사용량 계산은
// 모두 quota.go의 같은 함수를 거친다.
type quotaUsageResponse struct {
	Requester        string    `json:"requester,omitempty"`
	Limit            userQuota `json:"limit"`
	LimitCPUMilli    int64     `json:"limitCpuMilli"`
	LimitMemoryBytes int64     `json:"limitMemoryBytes"`
	Used             userQuota `json:"used"`
	UsedCPUMilli     int64     `json:"usedCpuMilli"`
	UsedMemoryBytes  int64     `json:"usedMemoryBytes"`
	// 사용량에 포함된 앱 수와 Pod 수. 같은 앱을 여러 번 신청하면 최신 신청만 센다.
	Applications int `json:"applications"`
	Pods         int `json:"pods"`
}

// quotaUsageFor는 requester의 신청 중 실제 desired state 또는 예약을 합산한다.
// merge 뒤 실패는 리소스가 남을 수 있으므로 제외하지 않고, merge 전 실패만 앞선
// 성공 기록을 계속 찾는다. store.list는 최신순이다.
func quotaUsageFor(requests []deploymentRequest) (cpuMilli int64, memoryBytes int64, apps int, pods int) {
	seen := make(map[string]bool, len(requests))
	for _, request := range requests {
		key := request.Profile.App.Project + "/" + request.Profile.App.Environment + "/" +
			request.Profile.App.Group + "/" + request.Profile.App.Name
		if seen[key] {
			continue
		}
		if request.State == stateDeleted {
			seen[key] = true
			continue
		}
		if request.State == stateFailed && !failedRequestMayOwnResources(request) {
			continue
		}
		seen[key] = true
		usedCPU, usedMemory, err := quotaUsage(request.Profile.Resources, request.Profile.Replicas)
		if err != nil {
			// 저장된 프리셋 표기가 깨진 경우다. 합계를 부풀리기보다 건너뛰고
			// 로그로 남긴다(막대가 조용히 틀리는 것보다 낫다).
			log.Printf("자원 사용량 합산에서 제외한 신청 request=%s: %v", request.ID, err)
			continue
		}
		cpuMilli += usedCPU
		memoryBytes += usedMemory
		apps++
		pods += max(request.Profile.Replicas, 1)
	}
	return cpuMilli, memoryBytes, apps, pods
}

// projectedQuotaErrors는 기존 활성 identity를 이번 계획으로 대체한 뒤의 총량을 본다.
// 새 요청 하나만 검증하면 여러 AppGroup으로 사용자당 CPU/메모리 상한을 우회할 수 있다.
func projectedQuotaErrors(requestStore *store, requester string, planned []normalizedProfile) []fieldError {
	projected := make(map[string]normalizedProfile)
	if requestStore != nil {
		for _, profile := range requestStore.liveProfiles(requester) {
			projected[appIdentity(profile)] = profile
		}
	}
	plannedGroups := make(map[string]struct{})
	for _, profile := range planned {
		projected[appIdentity(profile)] = profile
		if profile.App.Group != "" {
			plannedGroups[profile.App.Group] = struct{}{}
		}
	}
	var cpuMilli, memoryBytes int64
	groupPods := make(map[string]int)
	for _, profile := range projected {
		cpu, memory, err := quotaUsage(profile.Resources, max(profile.Replicas, 1))
		if err != nil {
			return []fieldError{{Field: "resourceSize", Message: "저장된 자원 사용량을 계산할 수 없습니다. 플랫폼 관리자에게 문의하세요."}}
		}
		cpuMilli += cpu
		memoryBytes += memory
		if profile.App.Group != "" {
			groupPods[profile.App.Group] += max(profile.Replicas, 1)
		}
	}
	limitCPU, cpuErr := parseCPUMilli(configuredUserQuota.CPU)
	limitMemory, memoryErr := parseMemoryBytes(configuredUserQuota.Memory)
	if cpuErr != nil || memoryErr != nil {
		return []fieldError{{Field: "resourceSize", Message: "사용자 자원 상한 설정을 해석할 수 없습니다. 플랫폼 관리자에게 문의하세요."}}
	}
	errors := make([]fieldError, 0, 3)
	if cpuMilli > limitCPU {
		errors = append(errors, fieldError{
			Field: "resourceSize", Message: fmt.Sprintf("기존 앱을 포함한 CPU %s가 사용자당 상한 %s를 넘습니다.", formatCPUMilli(cpuMilli), configuredUserQuota.CPU),
		})
	}
	if memoryBytes > limitMemory {
		errors = append(errors, fieldError{
			Field: "resourceSize", Message: fmt.Sprintf("기존 앱을 포함한 메모리 %s가 사용자당 상한 %s를 넘습니다.", formatMemoryBytes(memoryBytes), configuredUserQuota.Memory),
		})
	}
	for group := range plannedGroups {
		if groupPods[group] > maxAppReplicas {
			errors = append(errors, fieldError{
				Field: "services", Message: fmt.Sprintf("기존 앱을 포함한 AppGroup %s의 Pod 수 %d가 Namespace 상한 %d를 넘습니다.", group, groupPods[group], maxAppReplicas),
			})
		}
	}
	return errors
}

func (api *apiServer) handleQuotaUsage(w http.ResponseWriter, r *http.Request) {
	requester, ok := scopedRequester(r)
	if !ok {
		writeInvalidRequester(w)
		return
	}

	limitCPU, cpuErr := parseCPUMilli(configuredUserQuota.CPU)
	limitMemory, memoryErr := parseMemoryBytes(configuredUserQuota.Memory)
	if cpuErr != nil || memoryErr != nil {
		// 상한 설정 자체가 잘못된 상태다. 0을 내려 "무제한"처럼 보이게 하지 않는다.
		writeProblem(w, http.StatusInternalServerError,
			"urn:sadp:portal:problem:internal", "자원 상한 설정 오류",
			"PORTAL_USER_QUOTA_CPU / PORTAL_USER_QUOTA_MEMORY 값을 확인하세요.", nil)
		return
	}

	// 상한(3 CPU / 5Gi)보다 신청이 많을 수 없으므로 목록 상한까지만 읽으면 충분하다.
	usedCPU, usedMemory, apps, pods := quotaUsageFor(api.store.list(maxRequestList, requester))
	writeJSON(w, http.StatusOK, quotaUsageResponse{
		Requester:        requester,
		Limit:            configuredUserQuota,
		LimitCPUMilli:    limitCPU,
		LimitMemoryBytes: limitMemory,
		Used:             userQuota{CPU: formatCPUMilli(usedCPU), Memory: formatMemoryBytes(usedMemory)},
		UsedCPUMilli:     usedCPU,
		UsedMemoryBytes:  usedMemory,
		Applications:     apps,
		Pods:             pods,
	})
}
