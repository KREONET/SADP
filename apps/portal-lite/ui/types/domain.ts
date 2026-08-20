/**
 * 포털 화면 7종이 공유하는 도메인 타입.
 * 화면 컴포넌트는 이 타입만 소비하고, 실제 데이터 출처(mocks -> API)는 mocks/ 에서만 바꾼다.
 */

/* ---------------------------------- 공통 ---------------------------------- */

/** 상태 배지 색 계열. globals 토큰 status.ok / warn / error / idle 과 1:1 대응. */
export type StatusTone = "ok" | "warn" | "error" | "idle";

export interface NavItem {
  label: string;
  href: string;
}

/* ------------------------- 화면 1 · 2: 내 애플리케이션 ------------------------ */

/**
 * 애플리케이션 표시 상태.
 * 포털은 배포 요청 상태로 해석하므로 배포·시작·정지 전환 중에는 PENDING이고,
 * 각 GitOps 전환이 끝난 deployed/stopped에서만 RUNNING/STOPPED가 된다.
 */
export type ApplicationStatus = "RUNNING" | "STOPPED" | "PENDING" | "FAILED";

export interface Application {
  id: string;
  /** 카드 제목. 예: "research-core-api" */
  name: string;
  /** 상단 프로젝트 라벨. 예: "RESEARCH-CORE" */
  project: string;
  /** 비어 있으면 기존 단일 앱, 있으면 AppGroup 서비스다. */
  group?: string;
  status: ApplicationStatus;
  /** stop/start의 서버 저장 목표. runtime 실패 재시도 방향을 추측하지 않게 한다. */
  desiredRuntimeState?: "running" | "stopped";
  /** failed 직전 상태. 일반 배포 실패와 runtime 전환 실패를 구분한다. */
  failedFromState?: string;
  cluster: string;
  /** 사용자가 선택하거나 생성하지 않는 단일 워크로드 Zone. */
  zone: string;
  /** external 앱에 설정된 외부 접속 주소. 정지 중에는 열리지 않을 수 있다. */
  route?: string;
  /** Service가 있는 앱의 클러스터 내부 DNS 주소. ClusterIP처럼 재생성 시 바뀌지 않는다. */
  internalAddress?: string;
  /** 관측 가능한 terminal 상태는 N/N·0/N, 전환 중은 -/N으로 표시한다. */
  replicas?: string;
  /** 절대시간(ISO). 상대 표기는 클라이언트에서 포맷한다. */
  lastDeployedAt: string;
  /** 예: "CI/CD" */
  lastDeployedBy: string;
}

/** `/my-apps/[id]` 신청 상세 화면이 표시하는 배포 파이프라인 정보. */
export interface ApplicationDetail extends Application {
  requestId: string;
  pipelineState: string;
  message?: string;
  createdAt: string;
  gitRepository: string;
  revision: string;
  dockerfile: string;
  containerPort: number;
  exposure: string;
  image?: string;
  pullRequest?: {
    number: number;
    url: string;
    branch: string;
    state: string;
  };
}

/* --------------------------- 화면 2: 대시보드 --------------------------- */

export interface QuickAccessItem {
  id: string;
  label: string;
  href: string;
  /** 좌측 아이콘 키. 실제 아이콘 매핑은 뷰(QuickAccessCard)에서 한다. */
  icon: "globe" | "key";
}

export type WorkloadKind = "WEB APP" | "API SERVICE" | "WORKER";

export interface WorkloadSummary {
  id: string;
  kind: WorkloadKind;
  name: string;
  status: ApplicationStatus | "BETA";
  url?: string;
  /** 같은 클러스터 안의 허용된 앱이 사용하는 Service DNS 주소. */
  internalAddress?: string;
  replicas?: string;
  /** AppGroup 앱을 같은 이름의 다른 그룹 앱과 구분하는 Namespace. */
  namespace?: string;
}

export type NoticeCategory =
  | "Scheduled Maintenance"
  | "Platform Update"
  | "General";

export interface SystemNotice {
  id: string;
  category: NoticeCategory;
  title: string;
  body: string;
}

export interface QuotaMetric {
  id: string;
  label: string;
  used: number;
  total: number;
  unit?: string;
  /** 사용률에 따른 색 계열. 미지정 시 사용률로 자동 계산. */
  tone?: StatusTone;
}

export type DeploymentStatus = "Ready" | "MR Created" | "Validated";
export type DeploymentResult = "Success" | "Pending" | "Failed" | "Deleted";

export interface DeploymentRequest {
  id: string;
  /** 테이블 REQUEST ID 컬럼(모노스페이스) */
  requestId: string;
  application: string;
  status: DeploymentStatus;
  result: DeploymentResult;
  /** 절대시간(ISO) */
  date: string;
}

export interface OverallStatus {
  label: string;
  tone: StatusTone;
}

/* -------------------------- 화면 4·5: 새 앱 만들기 -------------------------- */

export type WizardStepState = "current" | "done" | "todo";

export interface WizardStep {
  /** 1-based */
  step: number;
  title: string;
  subtitle: string;
}

/**
 * 위저드가 모으는 값. Go `POST /api/v1/app-profiles/validate` 의 appProfileInput과
 * 1:1로 대응한다(문자열로 들고 있다가 제출 직전에 숫자로 바꾼다).
 * 서버가 받지 않는 필드는 두지 않는다 — 입력했는데 반영되지 않는 화면을 막는다.
 */
/**
 * 앱이 외부 Gateway를 통해 노출되는지.
 * external = Service + HTTPRoute + 외부 도메인, internal = Service만(내부 앱 전용).
 */
export type ExposureMode = "external" | "internal";

/** 외부에서 들어올 때 SSO 로그인을 요구할지. 노출 방식과 별개 축이다. */
export type AuthenticationMode = "none" | "oidc";

/**
 * 앱이 밖으로 나갈 수 있는 범위.
 * blocked = DNS와 명시적으로 연결한 내부 앱만, web = 인터넷 TCP 80/443,
 * custom = 직접 지정한 CIDR/앱.
 */
export type EgressMode = "blocked" | "web" | "custom";

/** custom 모드에서 직접 지정하는 목적지 한 줄. */
export interface DraftAllowedCidr {
  cidr: string;
  port: string;
  protocol: "TCP" | "UDP";
}

/** 같은 AppGroup 안의 앱 연결 한 줄. raw label 대신 앱 이름으로 고른다. */
export interface DraftAllowedApp {
  app: string;
  port: string;
  /** 앱 간 Service 연결은 현재 NetworkPolicy 계약상 TCP만 지원한다. */
  protocol: "TCP";
}

export interface NewAppDraft {
  /** Step 1 — 기본 정보 (appName, project) */
  name: string;
  project: string;
  /** Step 2 — 소스 (gitRepository, branch, dockerfile) */
  repositoryUrl: string;
  branch: string;
  dockerfilePath: string;
  /** Step 3 — 실행 조건 (containerPort, resourceSize, replicas) */
  port: string;
  resourceSize: string;
  replicas: string;
  /**
   * Step 4 — 외부 접속. host는 appName + baseDomain으로 서버가 만든다.
   * internal이면 host 자체가 만들어지지 않는다.
   */
  exposureMode: ExposureMode;
  /** Step 4 — 접속 인증. external일 때만 의미가 있다(서버도 같은 규칙으로 거부한다). */
  authMode: AuthenticationMode;
  /** Step 4 — 외부 통신 범위. */
  egressMode: EgressMode;
  /** egressMode가 custom일 때만 사용한다. */
  allowedCidrs: DraftAllowedCidr[];
  /**
   * 화면 6(구성 분류기)에서 넘어온 분류 결과.
   *
   * `openbao` 값은 메모리에만 유지되고 sessionStorage 직렬화 시 제거된다. 제출 시
   * 포털 API가 OpenBao에 저장하며 Git과 포털 요청 저장소에는 key만 남는다.
   */
  envVars: DraftEnvVar[];
}

export interface DraftEnvVar {
  key: string;
  value: string;
  classification: "configmap" | "openbao";
}

/** 카탈로그가 정한 preset 하나. 값은 서버가 주는 그대로 보여준다. */
export interface ResourcePresetOption {
  id: string;
  requestCpu: string;
  requestMemory: string;
  limitCpu: string;
  limitMemory: string;
}

/**
 * 위저드가 하드코딩하면 안 되는 값들. `GET /api/v1/catalog`에서 온다.
 * 프로젝트 목록·preset·상한이 서버에서 바뀌면 화면도 같이 바뀌어야 한다.
 */
export interface WizardOptions {
  environment: string;
  baseDomain: string;
  projects: string[];
  presets: ResourcePresetOption[];
  quota: { cpu: string; memory: string };
  maxReplicas: number;
  submissionEnabled: boolean;
  /** 카탈로그를 못 읽었으면 기본값으로 채운 화면임을 알린다. */
  source: "api" | "unavailable";
  /** 다중 앱(Compose) 화면이 쓰는 서버 규칙. 화면이 만들어 내면 실제와 어긋난다. */
  appGroups: AppGroupOptions;
}

export interface AppGroupOptions {
  enabled: boolean;
  /** Namespace 접두사. 미리보기(app-<group>)가 실제 Namespace와 같아야 한다. */
  namespacePrefix: string;
  maxServices: number;
}

/* --------------------------- 다중 앱(Compose) --------------------------- */

/** Compose 업로드 화면이 서비스마다 들고 있는 설정. */
export interface ComposeServiceDraft {
  name: string;
  port: number;
  /** false면 포트를 듣지 않는 worker이며 Service/HTTPRoute/수신 probe가 없다. */
  serviceEnabled: boolean;
  /** Compose named volume이 플랫폼 RWO PVC로 변환되는 mount path. */
  persistenceMountPath?: string;
  /** 이미 만들어진 이미지를 쓰는 서비스면 채워진다(빌드하지 않는다). */
  image?: string;
  exposureMode: ExposureMode;
  authMode: AuthenticationMode;
  egressMode: EgressMode;
  /** custom 외부 통신에서 허용할 CIDR/Port. */
  allowedCidrs: DraftAllowedCidr[];
  /** OpenBao에 관리자가 미리 만든 Secret의 key 이름. 값은 UI가 받지 않는다. */
  secretKeys: string[];
  /** 이 서비스가 접속할 같은 그룹의 앱. */
  allowedApps: DraftAllowedApp[];
  /** 이 서비스에 접속을 허용할 같은 그룹의 앱. */
  ingressApps: DraftAllowedApp[];
}

/** Compose 검증 결과 한 서비스. */
export interface ComposeServicePlan {
  name: string;
  namespace: string;
  exposureMode: ExposureMode;
  authMode: AuthenticationMode;
  egressMode: EgressMode;
  host?: string;
  image?: string;
  port: number;
  serviceEnabled: boolean;
  persistenceMountPath?: string;
}

export interface ComposePlan {
  group: string;
  namespace: string;
  source: {
    type: string;
    repository?: string;
    revision?: string;
    path?: string;
  };
  services: ComposeServicePlan[];
  warnings: string[];
}

/* ------------------------ 화면 5·6: 환경 변수 · 시크릿 ------------------------ */

export type EnvClassification =
  | "configmap"
  | "secret"
  | "openbao"
  | "unclassified";

export interface EnvVar {
  id: string;
  key: string;
  value: string;
  classification: EnvClassification;
}

export interface EnvBucket {
  id: Exclude<EnvClassification, "unclassified">;
  title: string;
  description: string;
}

/* --------------------------- 화면 7: 서비스 카탈로그 --------------------------- */

export type ServiceStatus = "Available" | "Beta" | "Degraded";

/** 카드 좌상단 대문자 라벨이자 VISIBILITY 필터의 단위. */
export type ServiceVisibility = "public" | "sso" | "admin";

export interface ServiceCatalogItem {
  id: string;
  name: string;
  description: string;
  visibility: ServiceVisibility;
  status: ServiceStatus;
  /** 메타 박스 좌측 열. 여러 개면 쉼표로 이어 붙여 렌더한다. */
  roles: string[];
  /** 메타 박스 우측 열. */
  team: string;
  /** Visit(새 탭) / Access / Manage 버튼이 여는 주소. */
  href: string;
  /**
   * 현재 사용자가 이 서비스에 접근 가능한지.
   * false 면 하단 버튼이 `Admin Only 🔒`(disabled) 하나로 대체된다.
   */
  accessible: boolean;
  /** SSO/Available 중 관리 권한이 있는 대상은 primary 가 `Manage` 가 된다. */
  manageable: boolean;
}
