/**
 * 다중 앱(Docker Compose) 신청 화면 문구.
 *
 * "웹 통신만 허용"처럼 오해하기 쉬운 항목은 무엇이 허용되고 무엇이 아닌지를
 * 문구에 그대로 적는다. 화면에서 애매하게 적으면 사용자는 도메인 단위 허용으로
 * 읽는다(기본 NetworkPolicy 는 포트만 본다).
 */
export const ko = {
  metaTitle: "여러 앱 함께 배포",
  metaDescription:
    "Git 저장소의 Docker Compose 또는 Helm Chart를 읽어 여러 앱을 전용 Namespace 하나에 배포합니다.",

  headerTitle: "여러 앱 함께 배포",
  headerDescription:
    "Git 주소만 입력하면 Docker Compose나 Helm Chart를 자동으로 찾습니다. Compose를 직접 붙여 넣을 수도 있으며, 각 서비스는 기존 플랫폼 보안 정책으로 다시 생성됩니다.",

  groupHeading: "앱 그룹",
  groupName: "앱 그룹 이름",
  groupNameHelper: "이 그룹은 Namespace {namespace} 에 배포됩니다.",
  groupNameHelperEmpty: "소문자 DNS 이름을 입력하세요. 전용 Namespace 이름이 됩니다.",
  project: "프로젝트",
  projectPlaceholder: "프로젝트 선택",
  sourceMode: "입력 방식",
  sourceGit: "Git 주소로 가져오기",
  sourceDirect: "Compose 직접 입력",
  repository: "Git 저장소 주소",
  repositoryPlaceholder: "https://<FORGEJO>/<OWNER>/<REPOSITORY>.git",
  repositoryHelper:
    "기본 브랜치에서 루트의 Compose 또는 Helm Chart를 자동 탐색합니다. 최대 {max}개 앱을 만들며, 후보가 여러 개면 임의로 선택하지 않습니다.",
  composeDocument: "docker-compose 파일",
  composeDocumentHelper:
    "서비스는 최대 {max}개까지 배포합니다. prebuilt image만 허용하고 build/environment는 거부합니다. Secret은 아래 OpenBao key 이름으로만 선언하며 포트 없는 서비스는 worker가 됩니다.",
  resourceSize: "자원 크기",
  resourceSizeHelper: "서비스마다 이 preset을 사용합니다.",
  resourceSizePlaceholder: "자원 크기 선택",
  validate: "앱 구성 확인",
  revalidate: "다시 확인",
  submit: "배포 신청",
  submitted: "신청 완료",
  validateOk: "서비스 {count}개를 확인했습니다. 서비스마다 접근과 통신을 지정하세요.",
  submitOk: "배포 요청 {count}건을 만들었습니다. Namespace {namespace} 에 배포됩니다.",
  validateFailed: "앱 구성 검증 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.",
  submitFailed: "배포 신청 중 오류가 발생했습니다. 같은 내용으로 다시 시도해 주세요.",
  validationDirty: "검증 후 설정이 바뀌었습니다. 다시 확인해야 배포를 신청할 수 있습니다.",
  fieldErrorsHeading: "확인할 입력 항목",
  warningsHeading: "가져오기 안내",

  servicePort: "Port",
  serviceWorker: "Worker (포트 없음)",
  serviceStorage: "영구 저장 경로",
  serviceStorageRwo: "RWO · replica 1 · 앱 삭제 시 데이터 삭제",
  serviceSource: "이미지",
  serviceDns: "내부 주소",
  serviceHost: "접속 주소",

  exposureLegend: "외부 접속",
  exposureExternal: "외부 URL 생성",
  exposureInternal: "내부 앱 전용",
  authLegend: "접속 인증",
  authNone: "인증 없음",
  authOidc: "SSO 로그인 필요",
  authInternalNote: "내부 앱 전용에는 SSO를 사용할 수 없습니다.",
  workerInternalNote: "포트 없는 worker는 내부 전용이며 Service/HTTPRoute/수신 probe가 없습니다.",
  workerIngressNote: "worker는 포트를 듣지 않아 다른 앱의 수신 연결 대상으로 지정할 수 없습니다.",
  egressLegend: "외부 통신",
  egressBlocked: "차단",
  egressWeb: "웹 통신만 허용",
  egressCustom: "사용자 지정",
  egressWebNotice:
    "외부 인터넷으로 TCP 80, 443 포트만 사용할 수 있습니다. 내부 네트워크와 다른 포트는 허용하지 않습니다.",

  allowedCidrsLegend: "허용할 외부 CIDR",
  allowedCidrsHelper:
    "CIDR과 포트를 직접 지정합니다. 인터넷 전체(0.0.0.0/0)는 사용할 수 없습니다.",
  cidrAdd: "CIDR 추가",
  cidrRemove: "CIDR 삭제",
  cidrAddress: "CIDR",
  cidrProtocol: "프로토콜",

  secretKeysLegend: "OpenBao Secret 키 이름",
  secretKeysHelper:
    "Secret 값은 입력하지 않습니다. 관리자가 이 앱의 OpenBao 경로에 미리 만든 key 이름만 추가하세요.",
  secretKeyName: "Secret 키 이름",
  secretKeyAdd: "Secret 키 추가",
  secretKeyRemove: "Secret 키 삭제",

  allowedAppsLegend: "이 앱이 접속할 앱",
  allowedAppsHelper: "선택한 앱의 지정 포트로만 나갈 수 있습니다.",
  ingressAppsLegend: "이 앱에 접속을 허용할 앱",
  ingressAppsHelper: "여기 없는 앱은 같은 그룹이어도 접속할 수 없습니다.",
  peerAdd: "연결 추가",
  peerRemove: "삭제",
  peerApp: "앱",
  peerPort: "Port",
};

export const en: typeof ko = {
  metaTitle: "Deploy multiple apps",
  metaDescription:
    "Reads Docker Compose or a Helm Chart from Git and deploys related apps into one dedicated namespace.",

  headerTitle: "Deploy multiple apps",
  headerDescription:
    "Enter a Git URL to auto-detect Docker Compose or a Helm Chart, or paste Compose directly. Each service is rebuilt with the platform security policy.",

  groupHeading: "App group",
  groupName: "App group name",
  groupNameHelper: "This group deploys into namespace {namespace}.",
  groupNameHelperEmpty:
    "Enter a lowercase DNS name. It becomes the dedicated namespace name.",
  project: "Project",
  projectPlaceholder: "Select a project",
  sourceMode: "Input method",
  sourceGit: "Import from Git URL",
  sourceDirect: "Paste Compose",
  repository: "Git repository URL",
  repositoryPlaceholder: "https://<FORGEJO>/<OWNER>/<REPOSITORY>.git",
  repositoryHelper:
    "Auto-detects a root Compose file or Helm Chart on the default branch. Up to {max} apps. Ambiguous candidates are never selected silently.",
  composeDocument: "docker-compose file",
  composeDocumentHelper:
    "Up to {max} services. Only prebuilt images are accepted; build and environment are rejected. Declare only OpenBao key names below. Portless services become workers.",
  resourceSize: "Resource size",
  resourceSizeHelper: "Every service uses this preset.",
  resourceSizePlaceholder: "Select a resource size",
  validate: "Check app configuration",
  revalidate: "Check again",
  submit: "Submit deployment",
  submitted: "Submitted",
  validateOk: "Found {count} services. Choose access and networking for each one.",
  submitOk: "Created {count} deployment requests. They deploy into namespace {namespace}.",
  validateFailed: "An error occurred while validating the app configuration. Try again shortly.",
  submitFailed: "An error occurred while submitting. Retry with the same settings.",
  validationDirty: "Settings changed after validation. Check them again before submitting.",
  fieldErrorsHeading: "Inputs that need attention",
  warningsHeading: "Import notes",

  servicePort: "Port",
  serviceWorker: "Worker (no port)",
  serviceStorage: "Persistent path",
  serviceStorageRwo: "RWO · 1 replica · data deleted with app",
  serviceSource: "Image",
  serviceDns: "Internal address",
  serviceHost: "Address",

  exposureLegend: "External access",
  exposureExternal: "Create a public URL",
  exposureInternal: "Internal apps only",
  authLegend: "Sign-in",
  authNone: "No authentication",
  authOidc: "SSO login required",
  authInternalNote: "SSO is not available for internal-only apps.",
  workerInternalNote: "A portless worker is internal-only and has no Service, HTTPRoute, or receive probe.",
  workerIngressNote: "A worker listens on no port and cannot be selected as an inbound connection target.",
  egressLegend: "Outbound traffic",
  egressBlocked: "Blocked",
  egressWeb: "Web traffic only",
  egressCustom: "Custom",
  egressWebNotice:
    "Only TCP ports 80 and 443 to the internet. Private networks and other ports stay blocked.",

  allowedCidrsLegend: "Allowed external CIDRs",
  allowedCidrsHelper:
    "Specify a CIDR and port. The catch-all internet CIDR (0.0.0.0/0) is not allowed.",
  cidrAdd: "Add CIDR",
  cidrRemove: "Remove CIDR",
  cidrAddress: "CIDR",
  cidrProtocol: "Protocol",

  secretKeysLegend: "OpenBao Secret key names",
  secretKeysHelper:
    "Do not enter Secret values. Add only key names that an administrator has provisioned in this app's OpenBao path.",
  secretKeyName: "Secret key name",
  secretKeyAdd: "Add Secret key",
  secretKeyRemove: "Remove Secret key",

  allowedAppsLegend: "Apps this app connects to",
  allowedAppsHelper: "Traffic is allowed only to the selected apps on the given port.",
  ingressAppsLegend: "Apps allowed to reach this app",
  ingressAppsHelper: "Apps not listed here cannot reach it, even in the same group.",
  peerAdd: "Add connection",
  peerRemove: "Remove",
  peerApp: "App",
  peerPort: "Port",
};
