/** 화면 4-5(새 앱 준비 위저드, `/new-app/[step]`) 문구. */

export const ko = {
  metaTitle: "새 앱 준비",
  metaDescription: "입력을 검증하고 배포 신청을 만드는 5단계 위저드.",

  /* 위저드 프레임 */
  headerTitle: "새 앱 준비",
  headerDescription:
    "제출하면 GitOps 저장소에 Pull Request가 만들어집니다. 승인 전까지 클러스터는 바뀌지 않습니다.",
  stepLabel: "Step {step}",
  progressLabel: "전체 {total}단계 중 {step}단계",
  composeHint: "서로 연관된 앱을 함께 배포하려면",
  composeHintLink: "docker-compose로 여러 앱 배포하기",
  cancel: "취소",
  prev: "이전",
  next: "다음 단계",
  createPlan: "신청 제출",
  submitting: "제출 중...",
  toastInvalidTitle: "입력값을 확인하세요.",
  toastInvalidDescription: "필수 항목이 비었거나 형식이 올바르지 않습니다.",
  toastPlanTitle: "신청을 접수했습니다.",
  toastPlanDescription:
    "{name} 배포 신청이 접수되었습니다. Pull Request 링크는 신청 상세에서 확인하세요.",
  toastSubmitFailedTitle: "신청을 접수하지 못했습니다.",
  toastSubmitFailedDescription:
    "{reason} 입력을 고치고 다시 시도하세요. 클러스터는 바뀌지 않았습니다.",
  toastSubmitNetworkReason: "서버에 연결하지 못했습니다.",
  submissionDisabledTitle: "지금은 신청을 받을 수 없습니다.",
  submissionDisabledDescription:
    "플랫폼이 배포 신청 접수를 닫아 두었습니다. 작성한 내용은 이 브라우저에 남아 있습니다.",

  /* 좌측 스테퍼 + 스텝 제목 */
  steps: {
    s1: {
      title: "기본 정보",
      subtitle: "이름, 프로젝트 할당",
      heading: "기본 정보 입력",
    },
    s2: {
      title: "소스 정보",
      subtitle: "Git Repo, Branch",
      heading: "소스 정보",
    },
    s3: {
      title: "실행 조건",
      subtitle: "Port, Resource",
      heading: "실행 조건",
    },
    s4: {
      title: "접근 방식",
      subtitle: "Public or OIDC",
      heading: "접근 방식",
    },
    s5: { title: "검토", subtitle: "설정 확인 후 신청", heading: "검토" },
  },

  /** 카탈로그를 못 읽었을 때. 고를 수 있는 값이 서버 기준이 아님을 알린다. */
  catalogUnavailable:
    "플랫폼 카탈로그를 읽지 못했습니다. 프로젝트·자원 목록이 최신이 아닐 수 있어 신청이 거부될 수 있습니다.",

  /* STEP 1 */
  appName: "앱 이름",
  appNameHelper:
    "소문자로 시작하는 40자 이하의 DNS 이름. 접속 주소와 네임스페이스에 그대로 쓰입니다.",
  project: "담당 프로젝트",
  projectHelper: "플랫폼이 허용한 프로젝트만 선택할 수 있습니다.",
  projectPlaceholder: "프로젝트를 선택하세요",
  environmentLabel: "환경",
  environmentHelper: "현재 API가 허용하는 환경입니다. 변경할 수 없습니다.",

  /* STEP 2 */
  repositorySettings: "Repository Settings",
  sourceMode: "프로그램 입력 방식",
  sourceModeHelper: "Git 소스를 빌드하거나 이미 만들어진 고정 버전 이미지를 선택합니다.",
  sourceGit: "Git 저장소에서 빌드",
  sourceImage: "기존 컨테이너 이미지 사용",
  image: "컨테이너 이미지",
  imageHelper: "고정된 tag 또는 sha256 digest가 필요합니다. Registry 인증은 플랫폼이 제공합니다.",
  repositoryUrl: "Git Repository URL",
  repositoryUrlHelper:
    "자격증명이 없는 https URL만 허용합니다. 플랫폼이 이 주소를 그대로 읽습니다.",
  branch: "Branch",
  branchHelper: "빌드에 사용할 브랜치 또는 태그.",
  dockerfilePath: "Dockerfile Path",
  dockerfilePathHelper:
    "저장소 루트 기준 상대 경로. 파일명은 Dockerfile로 시작해야 합니다.",

  /* STEP 3 */
  runtimeSettings: "Runtime Settings",
  containerPort: "Container Port",
  containerPortHelper: "컨테이너가 리스닝하는 포트 번호.",
  resourceSize: "자원 크기",
  resourceSizeHelper:
    "플랫폼이 정한 preset만 고를 수 있습니다. Request/Limit은 preset이 정합니다.",
  resourceSizeOption: "Request {requestCpu} / {requestMemory} · Limit {limitCpu} / {limitMemory}",
  replicas: "Replicas",
  replicasHelper: "동시에 실행할 파드 개수. 최대 {max}개.",
  quotaHint: "사용자당 상한: CPU {cpu} core · 메모리 {memory}",
  quotaUsagePreview: "이 설정의 소모량: CPU {cpu} · 메모리 {memory}",

  /* STEP 4 */
  accessSettings: "접근과 통신",
  exposureLegend: "외부 접속",
  exposureExternal: "외부 URL 생성",
  exposureExternalDescription: "인터넷에서 접근할 수 있는 HTTPS 주소를 만듭니다.",
  exposureInternal: "내부 앱 전용",
  exposureInternalDescription:
    "외부 주소를 만들지 않습니다. 같은 앱 그룹의 앱만 Service 이름으로 접근합니다.",
  authLegend: "접속 인증",
  authNone: "인증 없음",
  authNoneDescription: "누구나 주소만 알면 접근할 수 있습니다.",
  authOidc: "SSO 로그인 필요",
  authOidcDescription:
    "외부 OIDC 로그인을 통과한 허용 그룹 사용자만 접근합니다.",
  egressLegend: "외부 통신",
  egressBlocked: "차단",
  egressBlockedDescription: "DNS와 명시적으로 연결한 내부 앱만 통신할 수 있습니다.",
  egressWeb: "웹 통신만 허용",
  egressWebDescription:
    "외부 인터넷으로 TCP 80, 443 포트만 사용할 수 있습니다. 내부 네트워크와 다른 포트는 허용하지 않습니다.",
  egressWebNotice: "포트 단위 허용입니다. 특정 도메인만 허용하는 기능이 아닙니다.",
  egressCustom: "사용자 지정",
  egressCustomDescription: "허용할 대역(CIDR)과 포트를 직접 지정합니다.",
  allowedCidrsLegend: "허용할 목적지",
  allowedCidrsHelper:
    "예: 203.0.113.10/32 또는 2001:db8::/64 · 443. IPv4/IPv6 전체 대역(/0)은 지정할 수 없습니다.",
  allowedCidrsAdd: "목적지 추가",
  allowedCidrsRemove: "삭제",
  allowedCidrsCidr: "CIDR",
  allowedCidrsPort: "Port",
  allowedCidrsProtocol: "Protocol",
  hostPreview: "접속 주소",
  hostPreviewHelper:
    "앱 이름과 플랫폼 기본 도메인으로 서버가 만듭니다. 직접 정할 수 없습니다.",
  hostPreviewInternal: "내부 앱 전용이라 외부 주소를 만들지 않습니다.",

  /* STEP 5 */
  reviewHeading: "설정 확인",
  reviewBasics: "기본 정보",
  reviewSourceRuntime: "소스 · 실행",
  reviewAccess: "접근",
  reviewProject: "프로젝트",
  reviewEnvironment: "환경",
  reviewRepository: "Repository",
  reviewBranch: "Branch",
  reviewDockerfile: "Dockerfile",
  reviewImage: "Image",
  reviewPort: "Port",
  reviewResource: "자원",
  reviewReplicas: "Pod 수",
  reviewExposure: "외부 접속",
  reviewAuth: "접속 인증",
  reviewEgress: "외부 통신",
  reviewAllowedCidrs: "허용 목적지",
  reviewHost: "접속 주소",
  reviewEnvHeading: "환경변수",
  reviewEnvConfigMap: "ConfigMap",
  reviewEnvOpenBao: "OpenBao (안전하게 저장)",
  reviewEnvEmpty: "구성 분류기에서 분류한 환경변수가 없습니다.",
  reviewEnvSecretNotice:
    "OpenBao 항목은 제출 시 아래 앱 전용 경로에 저장됩니다. 이후 수정·삭제는 승인된 앱 구성원이 OpenBao에서 합니다.",
  reviewEnvOpenBaoPath: "OpenBao 경로",
  reviewEnvOpenBaoLink: "OpenBao 열기",
  reviewEnvReentry:
    "새로고침 후 저장하지 않은 OpenBao 값이 지워졌습니다. 다음 key의 값을 다시 입력하세요: {keys}",
  reviewEnvReentryLink: "구성 분류기에서 값 다시 입력",
  reviewNotice:
    "제출하면 GitOps 저장소에 Pull Request가 만들어집니다. 승인 전까지 클러스터는 바뀌지 않습니다.",

  /* 검증 메시지 */
  errors: {
    nameRequired: "앱 이름을 입력하세요.",
    namePattern:
      "소문자로 시작하는 40자 이하의 이름이어야 합니다(소문자·숫자·하이픈).",
    projectRequired: "담당 프로젝트를 선택하세요.",
    projectNotAllowed: "현재 허용된 프로젝트는 {allowed}입니다.",
    repositoryUrlRequired: "Git 저장소 URL을 입력하세요.",
    repositoryUrlPattern:
      "자격증명이 포함되지 않은 https URL을 입력하세요(예: {https}).",
    branchRequired: "브랜치를 입력하세요.",
    branchPattern: "안전한 branch 또는 tag 이름을 입력하세요.",
    dockerfilePathRequired: "Dockerfile 경로를 입력하세요.",
    dockerfilePathPattern:
      "저장소 안의 상대 경로여야 하고 파일명은 Dockerfile로 시작해야 합니다.",
    imageRequired: "컨테이너 이미지와 고정 버전을 입력하세요.",
    imagePattern: "registry/name:tag 또는 registry/name@sha256:<digest> 형식으로 입력하세요.",
    imageMutableTag: "latest, main, master, stable 같은 가변 태그 대신 고정 버전이나 digest를 사용하세요.",
    portRange: "1~65535 사이의 포트 번호를 입력하세요.",
    resourceSizeRequired: "자원 크기를 선택하세요(선택 가능: {allowed}).",
    replicasRange: "1~{max} 사이의 정수를 입력하세요.",
    cpuQuotaExceeded:
      "사용자당 CPU 상한 {limit} core를 넘습니다(요청 {used}). 자원 크기나 Pod 수를 줄이세요.",
    memoryQuotaExceeded:
      "사용자당 메모리 상한 {limit}를 넘습니다(요청 {used}). 자원 크기나 Pod 수를 줄이세요.",
    exposureRequired: "외부 접속 방식을 선택하세요.",
    authInternalNotAllowed:
      "SSO 로그인은 외부 URL을 생성하는 앱에서만 사용할 수 있습니다.",
    egressRequired: "외부 통신 범위를 선택하세요.",
    allowedCidrsRequired: "허용할 목적지를 최소 하나 추가하세요.",
    allowedCidrsPattern:
      "IPv4 또는 IPv6 CIDR(예: 203.0.113.10/32, 2001:db8::/64)과 1~65535 포트를 입력하세요. /0 전체 대역은 사용할 수 없습니다.",
    openBaoValueRequired:
      "OpenBao Secret 값은 브라우저에 저장하지 않습니다. 다음 key의 값을 다시 입력하세요: {keys}",
  },
};

export const en: typeof ko = {
  metaTitle: "New App Setup",
  metaDescription:
    "A five-step wizard that validates your input and creates a deployment request.",

  headerTitle: "New App Setup",
  headerDescription:
    "Submitting opens a pull request in the GitOps repository. The cluster is not changed until it is approved.",
  stepLabel: "Step {step}",
  progressLabel: "Step {step} of {total}",
  composeHint: "To deploy related apps together,",
  composeHintLink: "use docker-compose for multiple apps",
  cancel: "Cancel",
  prev: "Back",
  next: "Next step",
  createPlan: "Submit request",
  submitting: "Submitting...",
  toastInvalidTitle: "Please check your input.",
  toastInvalidDescription:
    "A required field is empty or has an invalid format.",
  toastPlanTitle: "Request accepted.",
  toastPlanDescription:
    "The deployment request for {name} was accepted. The pull request link is on the request detail page.",
  toastSubmitFailedTitle: "The request was not accepted.",
  toastSubmitFailedDescription:
    "{reason} Fix the input and try again. The cluster was not changed.",
  toastSubmitNetworkReason: "Could not reach the server.",
  submissionDisabledTitle: "Requests are closed right now.",
  submissionDisabledDescription:
    "The platform is not accepting deployment requests. Your draft stays in this browser.",

  steps: {
    s1: {
      title: "Basics",
      subtitle: "Name, project",
      heading: "Basic information",
    },
    s2: {
      title: "Source",
      subtitle: "Git repo, branch",
      heading: "Source information",
    },
    s3: {
      title: "Runtime",
      subtitle: "Port, resources",
      heading: "Runtime settings",
    },
    s4: {
      title: "Access",
      subtitle: "Public or OIDC",
      heading: "Access control",
    },
    s5: { title: "Review", subtitle: "Confirm and submit", heading: "Review" },
  },

  catalogUnavailable:
    "The platform catalog could not be read. Projects and resource sizes may be stale, so the request could be rejected.",

  appName: "App name",
  appNameHelper:
    "A DNS name starting with a lowercase letter, up to 40 characters. It is used for the URL and the namespace.",
  project: "Project",
  projectHelper: "Only projects allowed by the platform can be selected.",
  projectPlaceholder: "Select a project",
  environmentLabel: "Environment",
  environmentHelper: "The environment the API currently allows. It cannot be changed.",

  repositorySettings: "Repository Settings",
  sourceMode: "Program source",
  sourceModeHelper: "Build Git source or use an existing image pinned to an immutable version.",
  sourceGit: "Build from a Git repository",
  sourceImage: "Use an existing container image",
  image: "Container image",
  imageHelper: "Use a fixed tag or sha256 digest. The platform supplies Registry credentials.",
  repositoryUrl: "Git Repository URL",
  repositoryUrlHelper:
    "Only https URLs without credentials are allowed. The platform reads this address as-is.",
  branch: "Branch",
  branchHelper: "Branch or tag used for the build.",
  dockerfilePath: "Dockerfile Path",
  dockerfilePathHelper:
    "Path relative to the repository root. The file name must start with Dockerfile.",

  runtimeSettings: "Runtime Settings",
  containerPort: "Container Port",
  containerPortHelper: "Port the container listens on.",
  resourceSize: "Resource size",
  resourceSizeHelper:
    "Only platform-defined presets can be chosen. The preset decides requests and limits.",
  resourceSizeOption: "Request {requestCpu} / {requestMemory} · Limit {limitCpu} / {limitMemory}",
  replicas: "Replicas",
  replicasHelper: "Number of pods to run concurrently. Up to {max}.",
  quotaHint: "Per-user cap: CPU {cpu} cores · memory {memory}",
  quotaUsagePreview: "This setting uses: CPU {cpu} · memory {memory}",

  accessSettings: "Access and networking",
  exposureLegend: "External access",
  exposureExternal: "Create a public URL",
  exposureExternalDescription: "Publishes an HTTPS address reachable from the internet.",
  exposureInternal: "Internal apps only",
  exposureInternalDescription:
    "No external address. Only apps in the same app group reach it by Service name.",
  authLegend: "Sign-in",
  authNone: "No authentication",
  authNoneDescription: "Anyone who knows the address can reach it.",
  authOidc: "SSO login required",
  authOidcDescription:
    "Only users in the allowed external OIDC groups can reach it after signing in.",
  egressLegend: "Outbound traffic",
  egressBlocked: "Blocked",
  egressBlockedDescription: "Only DNS and the internal apps you explicitly connect to.",
  egressWeb: "Web traffic only",
  egressWebDescription:
    "Only TCP ports 80 and 443 to the internet. Private networks and other ports stay blocked.",
  egressWebNotice: "This allows ports, not specific domains.",
  egressCustom: "Custom",
  egressCustomDescription: "Pick the destination CIDRs and ports yourself.",
  allowedCidrsLegend: "Allowed destinations",
  allowedCidrsHelper:
    "For example 203.0.113.10/32 or 2001:db8::/64 · 443. An IPv4 or IPv6 /0 route is not allowed here.",
  allowedCidrsAdd: "Add destination",
  allowedCidrsRemove: "Remove",
  allowedCidrsCidr: "CIDR",
  allowedCidrsPort: "Port",
  allowedCidrsProtocol: "Protocol",
  hostPreview: "Address",
  hostPreviewHelper:
    "The server derives it from the app name and the platform base domain. You cannot set it yourself.",
  hostPreviewInternal: "Internal-only apps do not get an external address.",

  /* STEP 5 */
  reviewHeading: "Confirm settings",
  reviewBasics: "Basics",
  reviewSourceRuntime: "Source · Runtime",
  reviewAccess: "Access",
  reviewProject: "Project",
  reviewEnvironment: "Environment",
  reviewRepository: "Repository",
  reviewBranch: "Branch",
  reviewDockerfile: "Dockerfile",
  reviewImage: "Image",
  reviewPort: "Port",
  reviewResource: "Resources",
  reviewReplicas: "Replicas",
  reviewExposure: "External access",
  reviewAuth: "Sign-in",
  reviewEgress: "Outbound traffic",
  reviewAllowedCidrs: "Allowed destinations",
  reviewHost: "Address",
  reviewEnvHeading: "Environment variables",
  reviewEnvConfigMap: "ConfigMap",
  reviewEnvOpenBao: "OpenBao (secure write)",
  reviewEnvEmpty: "No environment variables were classified in the Config Classifier.",
  reviewEnvSecretNotice:
    "OpenBao values are written to the app-specific path on submission. Approved app members can later edit or delete them in OpenBao.",
  reviewEnvOpenBaoPath: "OpenBao path",
  reviewEnvOpenBaoLink: "Open OpenBao",
  reviewEnvReentry:
    "OpenBao values are not stored and were cleared after reload. Re-enter values for: {keys}",
  reviewEnvReentryLink: "Re-enter values in Config Classifier",
  reviewNotice:
    "Submitting opens a pull request in the GitOps repository. The cluster is not changed until it is approved.",

  errors: {
    nameRequired: "Enter an app name.",
    namePattern:
      "Use up to 40 characters starting with a lowercase letter (lowercase, digits, hyphens).",
    projectRequired: "Select a project.",
    projectNotAllowed: "Allowed projects are {allowed}.",
    repositoryUrlRequired: "Enter the Git repository URL.",
    repositoryUrlPattern:
      "Enter an https URL without credentials (e.g. {https}).",
    branchRequired: "Enter a branch.",
    branchPattern: "Enter a safe branch or tag name.",
    dockerfilePathRequired: "Enter the Dockerfile path.",
    dockerfilePathPattern:
      "Use a relative path inside the repository whose file name starts with Dockerfile.",
    imageRequired: "Enter a container image with a fixed version.",
    imagePattern: "Use registry/name:tag or registry/name@sha256:<digest>.",
    imageMutableTag: "Use a fixed version or digest instead of latest, main, master, or stable.",
    portRange: "Enter a port number between 1 and 65535.",
    resourceSizeRequired: "Select a resource size (available: {allowed}).",
    replicasRange: "Enter an integer between 1 and {max}.",
    cpuQuotaExceeded:
      "Exceeds the per-user CPU quota of {limit} cores (requested {used}). Lower the resource size or the pod count.",
    memoryQuotaExceeded:
      "Exceeds the per-user memory quota of {limit} (requested {used}). Lower the resource size or the pod count.",
    exposureRequired: "Choose how the app is reached from outside.",
    authInternalNotAllowed:
      "SSO login is only available for apps that publish a public URL.",
    egressRequired: "Choose the outbound traffic scope.",
    allowedCidrsRequired: "Add at least one allowed destination.",
    allowedCidrsPattern:
      "Enter an IPv4 or IPv6 CIDR (e.g. 203.0.113.10/32 or 2001:db8::/64) and a port between 1 and 65535. A /0 route is not allowed.",
    openBaoValueRequired:
      "OpenBao secret values are not stored in the browser. Re-enter values for: {keys}",
  },
};
