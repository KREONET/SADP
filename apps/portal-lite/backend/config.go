package main

import (
	"os"
	"strconv"
	"strings"
)

const (
	serviceName       = "portal-lite"
	serviceVersion    = "0.4.0-gitops"
	defaultBaseDomain = "sadp.example.invalid"
	maxJSONBody       = 64 << 10

	// 배포 요청 상태를 보관할 PVC 마운트 경로.
	defaultStateDir = "/data"
	// 목록 조회 1회에 돌려줄 최대 건수.
	maxRequestList = 50
)

var (
	baseDomain     = configured("PLATFORM_BASE_DOMAIN", defaultBaseDomain)
	appEnvironment = configured("APP_ENV", "beta")
	stateDir       = configured("PORTAL_STATE_DIR", defaultStateDir)
	// Forgejo Actions가 이미지를 push할 registry 접두사. 비면 템플릿 placeholder를 쓴다.
	registryBase = configured("PORTAL_OCI_REGISTRY_BASE", "registry.example.invalid/group/project")

	// 카탈로그 상태 프로브가 볼 네임스페이스. 설치 스크립트가 site.env 값으로 채운다.
	workloadNamespace = configured("PORTAL_WORKLOAD_NAMESPACE", "research-beta")
	rancherNamespace  = configured("PORTAL_RANCHER_NAMESPACE", "cattle-system")
	openbaoNamespace  = configured("PORTAL_OPENBAO_NAMESPACE", "openbao")
	openbaoAddress    = configured("PORTAL_OPENBAO_ADDR", "https://openbao.openbao.svc.cluster.local:8200")
	openbaoCACert     = configured("PORTAL_OPENBAO_CACERT", "/var/run/openbao/ca.crt")
	openbaoJWTPath    = configured("PORTAL_OPENBAO_JWT_PATH", "/var/run/openbao/token")
	openbaoWriterRole = configured("PORTAL_OPENBAO_WRITER_ROLE", "portal-app-secret-writer")
	// ESO가 로그인할 역할은 포털이 요청마다 만들지 않는다. bootstrap이 설치한 고정
	// 역할만 참조해야 침해된 포털이 임의 policy 본문이나 token_policies를 만들 수 없다.
	openbaoZoneAppRole       = configured("PORTAL_OPENBAO_ZONE_APP_ROLE", "portal-zone-app-eso")
	openbaoGroupAppRole      = configured("PORTAL_OPENBAO_GROUP_APP_ROLE", "portal-group-app-eso")
	openbaoGroupRegistryRole = configured("PORTAL_OPENBAO_GROUP_REGISTRY_ROLE", "portal-group-registry-eso")

	// 신청 위자드가 고를 수 있고 서버가 허용하는 프로젝트 목록.
	// UI 목데이터 대신 이 값이 카탈로그로 내려가 단일 출처가 된다.
	allowedProjects = parseCommaList(configured("PORTAL_ALLOWED_PROJECTS", "research"))

	// ---------------------------------------------------------------- Zone
	// 이 플랫폼은 사용자 워크로드를 앱마다 쪼개지 않고 Zone 하나에 모은다.
	// Zone ID가 곧 Kubernetes 네임스페이스다. 사용자에게 "네임스페이스"라는 말을
	// 노출하지 않고 Zone 이름만 보여 준다(운영 개념을 하나로 줄이기 위함).
	zoneID    = configured("PORTAL_ZONE_ID", workloadNamespace)
	zoneLabel = configured("PORTAL_ZONE_LABEL", "연구 Zone")

	// ------------------------------------------------------- AppGroup(Stack)
	// 서로 연관된 앱 여러 개는 Zone을 공유하지 않고 전용 Namespace 하나를 쓴다.
	// 접두사는 charts/app-group의 group.namespacePrefix, Argo AppProject의
	// destination(app-*)과 반드시 같아야 한다. 셋이 어긋나면 Argo가 sync를 거부한다.
	groupNamespacePrefix = configured("PORTAL_APP_GROUP_NAMESPACE_PREFIX", "app-")
	// AppGroup의 Argo Application이 속할 프로젝트. platform-prod는 ResourceQuota를
	// 막고 있어서 Namespace bootstrap을 넣을 수 없다.
	groupArgoProject = configured("PORTAL_APP_GROUP_ARGO_PROJECT", "app-groups")
	// Compose 하나가 만들 수 있는 앱 수. 사용자 쿼터(Pod 수)보다 크면 의미가 없다.
	maxGroupServices = min(configuredInt("PORTAL_APP_GROUP_MAX_SERVICES", maxAppReplicas), maxAppReplicas)
	// Compose named volume은 사용자가 용량/StorageClass를 고르지 않는다. 사이트 계약을
	// Portal 런타임에 투영한 이 두 값만 values로 쓸 수 있어 임의 PVC 요청을 막는다.
	appGroupVolumeSize         = configured("PORTAL_APP_GROUP_VOLUME_SIZE", "")
	appGroupVolumeStorageClass = configured("PORTAL_APP_GROUP_VOLUME_STORAGE_CLASS", "")

	// ------------------------------------------------------------ 자동 승인
	// 승인자가 따로 없는 셀프서비스 모드. PR을 만든 뒤 포털이 스스로 승인(merge)하고
	// 이미지를 빌드해 배포까지 끌고 간다. false면 사람이 PR을 머지할 때까지 멈춘다.
	autoApprove = configured("PORTAL_AUTO_APPROVE", "true") == "true"

	// 빌드 Job이 뜨는 네임스페이스. 기본은 Zone과 같은 곳으로, egress 정책과
	// push 자격증명을 한 벌만 유지한다.
	buildNamespace = configured("PORTAL_BUILD_NAMESPACE", zoneID)
	// 사설 저장소를 clone할 때 kaniko가 쓰는 계정과 토큰 출처.
	buildGitUsername  = configured("PORTAL_BUILD_GIT_USERNAME", "sadp-build-bot")
	buildGitSecret    = configured("PORTAL_BUILD_GIT_SECRET", "portal-lite-auth")
	buildGitSecretKey = configured("PORTAL_BUILD_GIT_SECRET_KEY", "FORGEJO_BOT_TOKEN")
	// kaniko 실행기 이미지. 노드는 레지스트리를 직접 당길 수 있다.
	buildImage = configured("PORTAL_BUILD_IMAGE", "gcr.io/kaniko-project/executor:v1.23.2")
	// 빌드 Job이 레지스트리에 push할 때 쓰는 docker config secret 이름.
	buildPushSecret    = configured("PORTAL_BUILD_DOCKER_CONFIG_NAME", "forgejo-registry-push")
	buildPushSecretKey = configured("PORTAL_BUILD_DOCKER_CONFIG_KEY", ".dockerconfigjson")
	// 배포되는 앱 Pod가 이미지를 pull할 때 쓰는 별도 read-only Secret.
	registryPullSecret = configured("PORTAL_APP_IMAGE_PULL_NAME", "forgejo-registry-pull")
	// AppGroup Namespace의 pull Secret은 이 OpenBao KV v2 경로를 ESO로 읽는다.
	// 빈 값이면 그룹 생성 API를 닫아 Secret 없는 Namespace를 만들지 않는다.
	registryPullRemotePath = configured("PORTAL_REGISTRY_PULL_REMOTE_PATH", "")
	// bootstrap이 감시하는 Argo CD Application 경로와 프로젝트.
	argoNamespace            = configured("PORTAL_ARGO_NAMESPACE", "devtroncd")
	argoProject              = configured("PORTAL_ARGO_PROJECT", "platform-prod")
	argoBootstrapApplication = configured("PORTAL_ARGO_BOOTSTRAP_APPLICATION", "platform-bootstrap")
	// 빌드 파드가 사내망 밖으로 나갈 때 거치는 정방향 프록시(Squid).
	buildHTTPProxy = configured("PORTAL_BUILD_HTTPS_PROXY", configured("HTTPS_PROXY", ""))
	buildNoProxy   = configured("PORTAL_BUILD_NO_PROXY", configured("NO_PROXY", "localhost,127.0.0.1,.svc,.cluster.local"))
	// 빌드 1회 제한 시간(초).
	buildTimeoutSeconds = configuredInt("PORTAL_BUILD_TIMEOUT_SECONDS", 900)
	// 배포 완료(파드 Ready) 확인 제한 시간(초).
	rolloutTimeoutSeconds = configuredInt("PORTAL_ROLLOUT_TIMEOUT_SECONDS", 600)
	// 등록한 같은 Forgejo source branch의 새 commit을 확인하는 주기다. webhook에 외부
	// callback 권한을 더하지 않고 기존 read token만 쓰므로 짧은 polling으로 제한한다.
	sourcePollIntervalSeconds = configuredInt("PORTAL_SOURCE_POLL_INTERVAL_SECONDS", 60)
	// Forgejo required checks가 끝날 때까지 자동 병합을 기다리는 상한이다. checks를
	// 우회해 즉시 main에 넣지 않으며, 실패/정체 시 요청을 명시적으로 실패시킨다.
	mergeTimeoutSeconds = configuredInt("PORTAL_MERGE_TIMEOUT_SECONDS", 900)
	// 삭제 완료 확인 제한 시간(초). rollout보다 짧게 잡는다. PR 처리는 순차 큐라
	// 여기서 오래 붙잡으면 뒤에 쌓인 다른 사용자의 배포까지 그만큼 늦어진다.
	deleteTimeoutSeconds = configuredInt("PORTAL_DELETE_TIMEOUT_SECONDS", 180)
)

// zoneNamespace는 Zone이 올라가는 실제 네임스페이스다. Zone ID와 동일하지만
// 호출부에서 의도를 분명히 하려고 이름을 따로 둔다.
func zoneNamespace() string { return zoneID }

// groupNamespace는 AppGroup 전용 Namespace 이름이다.
// charts/app-group이 만드는 이름과 반드시 같아야 하므로 계산식은 여기 한 곳에만 둔다.
func groupNamespace(group string) string { return groupNamespacePrefix + group }

func configuredInt(name string, fallback int) int {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func configured(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

// parseCommaList는 "a, b ,,c" 형태를 중복 없는 ["a","b","c"]로 정리한다.
func parseCommaList(raw string) []string {
	seen := make(map[string]struct{})
	values := make([]string, 0)
	for _, part := range strings.Split(raw, ",") {
		item := strings.TrimSpace(part)
		if item == "" {
			continue
		}
		if _, duplicated := seen[item]; duplicated {
			continue
		}
		seen[item] = struct{}{}
		values = append(values, item)
	}
	return values
}

// allowsProject는 카탈로그가 내려준 목록에 있는 프로젝트만 통과시킨다.
func allowsProject(candidate string) bool {
	for _, project := range allowedProjects {
		if project == candidate {
			return true
		}
	}
	return false
}
