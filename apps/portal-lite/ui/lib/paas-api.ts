import "server-only";

import {
  applicationReplicaSummary,
  applicationStatusFromRequestState,
  isApplicationRuntimeTarget,
  type ApplicationRuntimeTarget,
} from "@/lib/application-runtime";
import {
  deploymentIdentityKey,
  deploymentNamespace,
} from "@/lib/deployment-identity";
import { deploymentRequestPresentation } from "@/lib/deployment-request-state";
import {
  PORTAL_API_ORIGIN,
  portalApiJsonHeaders,
} from "@/lib/portal-api-bff";
import { PLATFORM } from "@/lib/site-config";
import type {
  AdminApprovalDashboard,
  AdminDeploymentRequest,
  AdminMutationResult,
  Application,
  ApprovalDecision,
  ApprovalPolicy,
  ComposePlan,
  ApplicationDetail,
  DeploymentRequest,
  OverallStatus,
  QuickAccessItem,
  QuotaMetric,
  ServiceCatalogItem,
  ServiceStatus,
  ServiceVisibility,
  SystemNotice,
  ResourcePresetOption,
  SecurityReview,
  WizardOptions,
  WorkloadSummary,
} from "@/types/domain";

/**
 * 화면 ↔ 백엔드(Go `apps/portal-lite/backend`) 사이의 유일한 접점.
 *
 * 같은 Pod 안의 Go API 를 고정 loopback origin으로 직접 호출한다. 세션에서 만든
 * X-Portal-User와 OpenBao 입력이 공개 build 변수의 외부 origin으로 나가면 안 된다.
 * 목데이터는 쓰지 않는다. 백엔드가 죽었거나 사용자에게 아무 신청이 없으면
 * 빈 목록과 `source: "unavailable" | "empty"` 를 돌려주고, 화면이 그대로 그린다.
 * "처음 들어온 사용자에게 남의 앱이 보이는" 일을 만들지 않는 것이 이 파일의 계약이다.
 *
 * 사용자별 데이터(`내 애플리케이션`, 대시보드 신청 목록, 쿼터)는 반드시
 * `requester` 를 붙여 호출한다. 백엔드가 그 값으로 필터링한다.
 *
 * 서버 컴포넌트 전용이다(`server-only`). 클라이언트에서 부르면 빌드가 깨진다.
 */
const ENDPOINTS = {
  /** 환경·서비스·Forgejo 연동 상태. Go `GET /api/v1/catalog`. */
  catalog: "/api/v1/catalog",
  /** 배포 신청 이력. Go `GET /api/v1/deployment-requests`. */
  deploymentRequests: "/api/v1/deployment-requests",
  /** 사용자별 쿼터 사용량. Go `GET /api/v1/quota-usage`. */
  quotaUsage: "/api/v1/quota-usage",
  /** Compose 사전검증. Go `POST /api/v1/app-groups/validate`. */
  appGroupValidate: "/api/v1/app-groups/validate",
  /** AppGroup 신청. Go `POST /api/v1/app-groups`. */
  appGroups: "/api/v1/app-groups",
  /** 관리자 전용 전체 승인 현황. */
  adminApprovalDashboard: "/api/v1/admin/approval-dashboard",
} as const;

/**
 * 화면에 보이는 값의 출처.
 * - `api`: 백엔드가 실제로 준 값(0건이어도 이 값이다).
 * - `unavailable`: 백엔드를 못 읽었다. 화면은 "일시적으로 볼 수 없음"을 알려야 한다.
 */
export type DataSource = "api" | "unavailable";

/* --------------------------- Go API 응답(부분) 타입 -------------------------- */

interface CatalogServiceDto {
  id: string;
  name: string;
  description: string;
  url: string;
  access: string;
  roles?: string[];
  status: string;
}

interface CatalogDto {
  environment: string;
  baseDomain: string;
  forgejoConnected: boolean;
  submissionEnabled: boolean;
  services: CatalogServiceDto[];
  /** 위저드가 고를 수 있는 값. 서버가 정하고 화면은 그대로 따른다. */
  projects?: string[];
  resourcePresets?: Record<
    string,
    { requests?: Record<string, string>; limits?: Record<string, string> }
  >;
  userQuota?: { cpu?: string; memory?: string };
  maxReplicas?: number;
  zone?: { id?: string; label?: string };
  autoApprove?: boolean;
  /** 다중 앱(Compose) 화면 규칙. Namespace 접두사를 화면이 만들어 내지 않게 한다. */
  appGroups?: {
    enabled?: boolean;
    namespacePrefix?: string;
    maxServices?: number;
  };
}

/** RFC 7807. Go writeProblem 이 돌려주는 본문. */
interface ProblemDto {
  title?: string;
  detail?: string;
  status?: number;
  errors?: { field: string; message: string }[];
}

interface DeploymentRequestDto {
  id: string;
  state: string;
  createdAt: string;
  updatedAt: string;
  requester?: string;
  message?: string;
  deletionRequested?: boolean;
  desiredRuntimeState?: string;
  failedFromState?: string;
  pullRequest?: { number: number; url: string; branch: string; state: string };
  runtimePullRequest?: {
    number: number;
    url: string;
    branch: string;
    state: string;
  };
  approval?: Partial<ApprovalDecision>;
  securityReview?: Partial<SecurityReview>;
  profile?: {
    app?: { name?: string; project?: string; environment?: string; group?: string };
    source?: { repository?: string; revision?: string; dockerfile?: string };
    service?: {
      enabled?: boolean;
      port?: number;
      healthPath?: string;
      internalAddress?: string;
    };
    exposure?: { mode?: string; type?: string; host?: string };
    authentication?: { mode?: string };
    networkPolicy?: { egressMode?: string };
    replicas?: number;
  };
  generated?: { image?: string };
}

interface DeploymentRequestListDto {
  items: DeploymentRequestDto[];
  count: number;
  limit: number;
  requester?: string;
}

interface QuotaUsageDto {
  requester?: string;
  limit: { cpu: string; memory: string };
  limitCpuMilli: number;
  limitMemoryBytes: number;
  used: { cpu: string; memory: string };
  usedCpuMilli: number;
  usedMemoryBytes: number;
  applications: number;
  pods: number;
}

/** 백엔드 장애를 화면마다 중복해서 찍지 않도록 경로별로 한 번만 남긴다. */
const warned = new Set<string>();

function warnOnce(path: string, reason: unknown) {
  if (warned.has(path)) return;
  warned.add(path);
  console.warn(
    `[paas-api] ${path} 호출 실패 — 빈 값으로 그린다.`,
    reason instanceof Error ? reason.message : reason,
  );
}

/**
 * 백엔드에서 JSON 을 가져온다. 주소가 없거나 호출이 실패하면 `null` 이다.
 * 호출부는 `null` 을 "데이터 없음"이 아니라 "지금은 알 수 없음"으로 다뤄야 한다.
 */
async function fetchJson<T>(
  path: string,
  query: Record<string, string | number | undefined> = {},
  roles: readonly string[] = [],
): Promise<T | null> {
  const url = new URL(`${PORTAL_API_ORIGIN}${path}`);
  for (const [key, value] of Object.entries(query)) {
    // 신원은 URL/access log에 남기지 않고 trusted header에만 싣는다.
    if (key === "requester" || value === undefined || value === "") continue;
    url.searchParams.set(key, String(value));
  }

  // 브라우저 입력이 아니라 인증된 서버 컴포넌트가 계산한 신원만 보낸다.
  const headers: Record<string, string> = { accept: "application/json" };
  const requester = String(query.requester ?? "").trim();
  if (requester) headers["X-Portal-User"] = requester;
  const trustedRoles = [...new Set(roles.map((role) => role.trim()).filter(Boolean))]
    .sort()
    .join(",");
  if (trustedRoles) headers["X-Portal-Roles"] = trustedRoles;

  try {
    const response = await fetch(url, {
      headers,
      // 대시보드/목록은 항상 최신이어야 하므로 캐시하지 않는다.
      cache: "no-store",
      signal: AbortSignal.timeout(5000),
    });

    if (!response.ok) {
      warnOnce(path, `HTTP ${response.status}`);
      return null;
    }

    return (await response.json()) as T;
  } catch (error) {
    warnOnce(path, error);
    return null;
  }
}

function getCatalog(): Promise<CatalogDto | null> {
  return fetchJson<CatalogDto>(ENDPOINTS.catalog);
}

/**
 * 로그인한 사용자의 신청만 가져온다.
 * `requester` 가 비어 있으면 백엔드가 전체를 돌려주므로, 그럴 때는 아예 부르지 않고
 * 빈 목록으로 처리한다. 남의 신청이 내 화면에 새는 경로를 코드로 막는다.
 */
async function listMyRequests(
  requester: string,
  limit?: number,
): Promise<DeploymentRequestListDto | null> {
  if (!requester.trim()) return { items: [], count: 0, limit: limit ?? 0 };
  return fetchJson<DeploymentRequestListDto>(ENDPOINTS.deploymentRequests, {
    requester,
    limit,
  });
}

/* ------------------------------- 매핑 헬퍼 -------------------------------- */

function toDeploymentRequest(dto: DeploymentRequestDto): DeploymentRequest {
  const { status, result } = deploymentRequestPresentation(dto.state);
  return {
    id: dto.id,
    requestId: dto.id,
    application: dto.profile?.app?.name ?? "(unknown)",
    status,
    result,
    approvalStatus: approvalOf(dto).status,
    securityReviewStatus: securityReviewOf(dto).status,
    date: dto.createdAt,
  };
}

function approvalOf(dto: DeploymentRequestDto): ApprovalDecision {
  const status = dto.approval?.status;
  return {
    status:
      status === "approved" || status === "rejected" ? status : "pending",
    decidedBy: dto.approval?.decidedBy?.trim() || undefined,
    decidedAt: dto.approval?.decidedAt?.trim() || undefined,
    automatic: dto.approval?.automatic === true,
    rejectReason: dto.approval?.rejectReason?.trim() || undefined,
  };
}

function securityReviewOf(dto: DeploymentRequestDto): SecurityReview {
  const status = dto.securityReview?.status;
  return {
    status: status === "passed" || status === "rejected" ? status : "pending",
    checkedAt: dto.securityReview?.checkedAt?.trim() || undefined,
    summary: dto.securityReview?.summary?.trim() || undefined,
    findings: (dto.securityReview?.findings ?? []).map((finding) => ({
      package: finding.package,
      cve: finding.cve,
      fixedVersion: finding.fixedVersion,
      message: finding.message,
    })),
  };
}

/**
 * 같은 앱 좌표(project/environment/group/name)로 여러 번 신청했으면 가장 최근 신청
 * 하나만 카드로 만든다. AppGroup이 다르면 서비스 이름이 같아도 서로 다른 앱이다.
 * 목록은 백엔드가 최신순으로 준다.
 */
function toApplications(
  items: DeploymentRequestDto[],
  zoneLabel: string,
  namespacePrefix: string,
): Application[] {
  const byIdentity = new Map<string, Application>();
  const seenIdentities = new Set<string>();

  for (const dto of items) {
    const app = dto.profile?.app;
    const name = app?.name?.trim();
    if (!name) continue;
    const identity = deploymentIdentityKey(app ?? {});
    if (seenIdentities.has(identity)) continue;
    seenIdentities.add(identity);
    // 최신 요청이 삭제 중/완료면 과거 배포 요청 카드가 다시 살아나면 안 된다.
    if (dto.state === "deleting" || dto.state === "deleted") continue;

    const exposureHost = dto.profile?.exposure?.host?.trim();
    const internalAddress = dto.profile?.service?.internalAddress?.trim();
    const replicas = dto.profile?.replicas;

    const group = app?.group?.trim();
    const desiredRuntimeState = dto.desiredRuntimeState?.trim();
    byIdentity.set(identity, {
      id: dto.id,
      name,
      project: app?.project?.trim() || "-",
      group: group || undefined,
      status:
        approvalOf(dto).status === "rejected"
          ? "FAILED"
          : applicationStatusFromRequestState(dto.state),
      approvalStatus: approvalOf(dto).status,
      securityReviewStatus: securityReviewOf(dto).status,
      desiredRuntimeState: isApplicationRuntimeTarget(desiredRuntimeState)
        ? desiredRuntimeState
        : undefined,
      failedFromState: dto.failedFromState?.trim() || undefined,
      cluster: PLATFORM.clusterName,
      zone: deploymentNamespace(app ?? {}, zoneLabel, namespacePrefix),
      route: exposureHost ? `https://${exposureHost}` : undefined,
      internalAddress: internalAddress || undefined,
      replicas: applicationReplicaSummary(dto.state, replicas),
      lastDeployedAt: dto.updatedAt || dto.createdAt,
      lastDeployedBy: dto.requester?.trim() || "-",
    });
  }

  return [...byIdentity.values()];
}

/** 대시보드 카드용 축약형. 노출 방식으로 종류를 나눈다(public=웹, oidc=보호된 API). */
function toWorkloadSummaries(
  items: DeploymentRequestDto[],
  zoneLabel: string,
  namespacePrefix: string,
): WorkloadSummary[] {
  return toApplications(items, zoneLabel, namespacePrefix).map((app) => ({
    id: app.id,
    kind: app.route ? "WEB APP" : "API SERVICE",
    name: app.name,
    status: app.status,
    url: app.route,
    internalAddress: app.internalAddress,
    replicas: app.replicas,
    namespace: app.group ? app.zone : undefined,
  }));
}

/**
 * 좌측 Quick Access. 카탈로그에서 "내가 지금 들어갈 수 있는" 서비스만 뽑는다.
 * 하드코딩 링크를 두지 않으므로, 서비스가 꺼지면 버튼도 같이 사라진다.
 */
function toQuickAccess(
  services: CatalogServiceDto[],
  userRoles: readonly string[],
): QuickAccessItem[] {
  return services
    .filter((service) => {
      if (service.access === "public") return true;
      const required = service.roles ?? [];
      return required.length === 0 || required.some((r) => userRoles.includes(r));
    })
    .slice(0, 4)
    .map((service) => ({
      id: service.id,
      label: service.name,
      href: service.url,
      icon: service.access === "public" ? "globe" : "key",
    }));
}

const VISIBILITIES = new Set<string>(["public", "sso", "admin"]);

function toServiceVisibility(access: string): ServiceVisibility {
  return VISIBILITIES.has(access) ? (access as ServiceVisibility) : "sso";
}

/** 카탈로그 프로브 결과(available/degraded/unknown) → 카드 배지. */
function toServiceStatus(status: string): ServiceStatus {
  return status === "available" ? "Available" : "Degraded";
}

function toServiceCatalogItem(
  dto: CatalogServiceDto,
  environment: string,
  userRoles: readonly string[],
): ServiceCatalogItem {
  const required = dto.roles ?? [];
  // 역할 제한이 없으면 누구나, 있으면 세션 role 과 교집합이 있어야 접근할 수 있다.
  const hasRole = required.length === 0 || required.some((r) => userRoles.includes(r));
  return {
    id: dto.id,
    name: dto.name,
    description: dto.description,
    visibility: toServiceVisibility(dto.access),
    status: toServiceStatus(dto.status),
    roles: required,
    team: environment ? environment.toUpperCase() : "PLATFORM",
    href: dto.url,
    accessible: dto.access === "public" || hasRole,
    manageable: required.length > 0 && hasRole,
  };
}

/** 바이트/밀리코어를 화면 단위(코어, GB)로 옮긴다. 소수 한 자리까지만 쓴다. */
function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

function quotaTone(used: number, total: number): QuotaMetric["tone"] {
  if (total <= 0) return "idle";
  const ratio = used / total;
  if (ratio >= 1) return "error";
  if (ratio >= 0.8) return "warn";
  return "ok";
}

function toQuotaMetrics(dto: QuotaUsageDto): QuotaMetric[] {
  const usedCores = round1(dto.usedCpuMilli / 1000);
  const totalCores = round1(dto.limitCpuMilli / 1000);
  const usedGb = round1(dto.usedMemoryBytes / 1024 ** 3);
  const totalGb = round1(dto.limitMemoryBytes / 1024 ** 3);

  return [
    {
      id: "q-cpu",
      label: "CPU Cores",
      used: usedCores,
      total: totalCores,
      tone: quotaTone(usedCores, totalCores),
    },
    {
      id: "q-mem",
      label: "Memory (GB)",
      used: usedGb,
      total: totalGb,
      tone: quotaTone(usedGb, totalGb),
    },
  ];
}

/* --------------------------------- 화면별 --------------------------------- */

/**
 * 화면 1 `/my-apps` — 내 애플리케이션.
 * 내가 낸 배포 신청에서 만든다. 신청이 없으면 빈 목록이고, 그게 정상이다.
 */
export async function getApplications(requester: string): Promise<{
  applications: Application[];
  source: DataSource;
}> {
  const [list, catalog] = await Promise.all([
    listMyRequests(requester),
    getCatalog(),
  ]);
  if (!list) return { applications: [], source: "unavailable" };
  return {
    applications: toApplications(
      list.items,
      catalog?.zone?.label?.trim() ?? "",
      catalog?.appGroups?.namespacePrefix?.trim() ?? "",
    ),
    source: "api",
  };
}

/** 화면 1 상세 — URL의 요청 ID도 반드시 로그인 사용자 범위로 조회한다. */
export async function getApplicationDetail(
  requestId: string,
  requester: string,
): Promise<{ application: ApplicationDetail | null; source: DataSource }> {
  if (!requestId.trim() || !requester.trim()) {
    return { application: null, source: "unavailable" };
  }

  const [dto, catalog] = await Promise.all([
    fetchJson<DeploymentRequestDto>(
      `${ENDPOINTS.deploymentRequests}/${encodeURIComponent(requestId)}`,
      { requester },
    ),
    getCatalog(),
  ]);
  if (!dto) return { application: null, source: "unavailable" };

  const application = toApplications(
    [dto],
    catalog?.zone?.label?.trim() ?? "",
    catalog?.appGroups?.namespacePrefix?.trim() ?? "",
  )[0];
  if (!application) return { application: null, source: "unavailable" };

  return {
    source: "api",
    application: {
      ...application,
      requestId: dto.id,
      pipelineState: dto.state,
      message: dto.message?.trim() || undefined,
      createdAt: dto.createdAt,
      gitRepository: dto.profile?.source?.repository?.trim() || "-",
      revision: dto.profile?.source?.revision?.trim() || "-",
      dockerfile: dto.profile?.source?.dockerfile?.trim() || "-",
      containerPort: dto.profile?.service?.port ?? 0,
      // 새 구조(mode)가 있으면 그것을 쓰고, 예전에 저장된 신청은 type 으로 읽는다.
      exposure:
        dto.profile?.exposure?.mode?.trim() ||
        dto.profile?.exposure?.type?.trim() ||
        "-",
      image: dto.generated?.image?.trim() || undefined,
      approval: approvalOf(dto),
      securityReview: securityReviewOf(dto),
    },
  };
}

interface AdminApprovalDashboardDto {
  requests: DeploymentRequestDto[];
  policies: ApprovalPolicy[];
  count: number;
}

/** platform-admin 세션만 받을 수 있는 전체 승인 현황과 private PR 좌표다. */
export async function getAdminApprovalDashboard(
  requester: string,
  roles: readonly string[],
): Promise<{ dashboard: AdminApprovalDashboard | null; source: DataSource }> {
  if (!requester.trim()) return { dashboard: null, source: "unavailable" };
  const dto = await fetchJson<AdminApprovalDashboardDto>(
    ENDPOINTS.adminApprovalDashboard,
    { requester },
    roles,
  );
  if (!dto) return { dashboard: null, source: "unavailable" };
  const requests: AdminDeploymentRequest[] = dto.requests.map((item) => ({
    id: item.id,
    requester: item.requester?.trim() || "-",
    application: item.profile?.app?.name?.trim() || "-",
    project: item.profile?.app?.project?.trim() || "-",
    pipelineState: item.state,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
    sourceRepository: item.profile?.source?.repository?.trim() || "-",
    approval: approvalOf(item),
    securityReview: securityReviewOf(item),
    pullRequest: item.pullRequest,
  }));
  return {
    source: "api",
    dashboard: {
      requests,
      policies: dto.policies.map((policy) => ({
        ...policy,
        history: policy.history ?? [],
      })),
      count: dto.count,
    },
  };
}

async function adminMutation(
  path: string,
  method: "POST" | "PUT",
  body: unknown,
  requester: string,
  roles: readonly string[],
): Promise<AdminMutationResult> {
  try {
    const response = await fetch(`${PORTAL_API_ORIGIN}${path}`, {
      method,
      headers: portalApiJsonHeaders(requester, undefined, roles),
      body: JSON.stringify(body),
      cache: "no-store",
      signal: AbortSignal.timeout(15_000),
    });
    if (response.ok) return { ok: true };
    let problem: ProblemDto = {};
    try {
      problem = (await response.json()) as ProblemDto;
    } catch {
      // 상태 코드 fallback을 사용한다.
    }
    return {
      ok: false,
      reason:
        problem.detail?.trim() ||
        problem.title?.trim() ||
        `관리자 요청이 거부되었습니다 (HTTP ${response.status}).`,
    };
  } catch (error) {
    warnOnce(`${method} ${path}`, error);
    return { ok: false, reason: "내부 Portal API에 연결하지 못했습니다." };
  }
}

export function decideDeploymentApproval(
  requestId: string,
  decision: "approved" | "rejected",
  reason: string,
  requester: string,
  roles: readonly string[],
): Promise<AdminMutationResult> {
  return adminMutation(
    `/api/v1/admin/deployment-requests/${encodeURIComponent(requestId)}/decision`,
    "POST",
    { decision, reason },
    requester,
    roles,
  );
}

export function updateAutoApprovalPolicy(
  policyRequester: string,
  enabled: boolean,
  requester: string,
  roles: readonly string[],
): Promise<AdminMutationResult> {
  return adminMutation(
    `/api/v1/admin/approval-policies/${encodeURIComponent(policyRequester)}`,
    "PUT",
    { enabled },
    requester,
    roles,
  );
}

/** 화면 7 `/services` — 서비스 카탈로그. Go `GET /api/v1/catalog` 의 실시간 상태를 쓴다. */
export async function getServiceCatalog(
  userRoles: readonly string[] = [],
): Promise<{ services: ServiceCatalogItem[]; source: DataSource }> {
  const catalog = await getCatalog();
  if (!catalog) return { services: [], source: "unavailable" };
  return {
    services: (catalog.services ?? []).map((service) =>
      toServiceCatalogItem(service, catalog.environment, userRoles),
    ),
    source: "api",
  };
}

export interface DashboardData {
  overallStatus: OverallStatus;
  gitlabIntegration: OverallStatus;
  /** 플랫폼 현황 카드 본문 문단들. */
  platformSummary: string[];
  quickAccess: QuickAccessItem[];
  myWorkloads: WorkloadSummary[];
  /** 공지 백엔드가 아직 없다. 항상 빈 배열이고, 카드가 빈 상태를 그린다. */
  systemNotices: SystemNotice[];
  quotas: QuotaMetric[];
  quotaSource: DataSource;
  deploymentRequests: DeploymentRequest[];
  /** 배포 요청 테이블이 실제 API 응답인지. */
  deploymentRequestsSource: DataSource;
  /** 신청 제출이 열려 있는지(Forgejo 연동 완료 여부). */
  submissionEnabled: boolean;
}

const UNKNOWN_STATUS: OverallStatus = { label: "Unknown", tone: "idle" };

/**
 * 화면 2 `/` — 대시보드.
 * 플랫폼 배너는 카탈로그를, 워크로드·신청 테이블·쿼터는 내 신청과 내 사용량을 읽는다.
 * 어느 하나가 실패해도 나머지는 그대로 그린다.
 */
export async function getDashboard(
  requester: string,
  userRoles: readonly string[] = [],
): Promise<DashboardData> {
  const [catalog, requests, quota] = await Promise.all([
    getCatalog(),
    listMyRequests(requester, 5),
    requester.trim()
      ? fetchJson<QuotaUsageDto>(ENDPOINTS.quotaUsage, { requester })
      : Promise.resolve(null),
  ]);

  const services = catalog?.services ?? [];
  const allAvailable = services.length > 0 && services.every((s) => s.status === "available");

  const overallStatus: OverallStatus = catalog
    ? allAvailable
      ? { label: "Operational", tone: "ok" }
      : { label: "Degraded", tone: "warn" }
    : UNKNOWN_STATUS;

  const gitlabIntegration: OverallStatus = catalog
    ? catalog.forgejoConnected && catalog.submissionEnabled
      ? { label: "Connected", tone: "ok" }
      : { label: "연동 전", tone: "idle" }
    : UNKNOWN_STATUS;

  const platformSummary = catalog
    ? [
        `환경 ${catalog.environment} · 기본 도메인 ${catalog.baseDomain}`,
        catalog.submissionEnabled
          ? "Forgejo 연동이 켜져 있어 배포 신청이 Pull Request 로 이어집니다."
          : "실제 Forgejo 배포 요청은 연동 후 열립니다. 지금은 프로필 검증까지 가능합니다.",
      ]
    : ["플랫폼 상태를 읽지 못했습니다. 잠시 후 새로고침해 주세요."];

  return {
    overallStatus,
    gitlabIntegration,
    platformSummary,
    quickAccess: toQuickAccess(services, userRoles),
    myWorkloads: requests
      ? toWorkloadSummaries(
          requests.items,
          catalog?.zone?.label?.trim() ?? "",
          catalog?.appGroups?.namespacePrefix?.trim() ?? "",
        )
      : [],
    systemNotices: [],
    quotas: quota ? toQuotaMetrics(quota) : [],
    quotaSource: quota ? "api" : "unavailable",
    deploymentRequests: requests ? requests.items.map(toDeploymentRequest) : [],
    deploymentRequestsSource: requests ? "api" : "unavailable",
    submissionEnabled: catalog?.submissionEnabled ?? false,
  };
}

/* ------------------------------ 화면 4-5: 새 앱 ------------------------------ */

/**
 * 위저드가 고를 수 있는 값. 프로젝트·preset·쿼터·상한은 전부 서버가 정한다.
 * 카탈로그를 못 읽으면 목록을 비운 채 `source: "unavailable"` 로 돌려준다.
 * (임의 기본값을 채우면 서버에 없는 값을 고른 채 제출돼 422 로 되돌아온다.)
 */
export async function getWizardOptions(): Promise<WizardOptions> {
  const catalog = await getCatalog();
  if (!catalog) {
    return {
      environment: "",
      baseDomain: PLATFORM.appDomain,
      zoneId: "",
      projects: [],
      presets: [],
      quota: { cpu: "", memory: "" },
      maxReplicas: 1,
      submissionEnabled: false,
      source: "unavailable",
      // 카탈로그를 못 읽으면 다중 앱 화면도 열지 않는다. 접두사를 임의로 채우면
      // 실제 Namespace와 다른 이름을 미리보기로 보여 주게 된다.
      appGroups: { enabled: false, namespacePrefix: "", maxServices: 0 },
    };
  }

  const presets: ResourcePresetOption[] = Object.entries(
    catalog.resourcePresets ?? {},
  ).map(([id, preset]) => ({
    id,
    requestCpu: preset.requests?.cpu ?? "",
    requestMemory: preset.requests?.memory ?? "",
    limitCpu: preset.limits?.cpu ?? "",
    limitMemory: preset.limits?.memory ?? "",
  }));

  return {
    environment: catalog.environment,
    baseDomain: catalog.baseDomain,
    zoneId: catalog.zone?.id?.trim() ?? "",
    projects: catalog.projects ?? [],
    presets,
    quota: {
      cpu: catalog.userQuota?.cpu ?? "",
      memory: catalog.userQuota?.memory ?? "",
    },
    maxReplicas: catalog.maxReplicas && catalog.maxReplicas > 0 ? catalog.maxReplicas : 1,
    submissionEnabled: catalog.submissionEnabled,
    source: "api",
    appGroups: {
      enabled: catalog.appGroups?.enabled ?? false,
      namespacePrefix: catalog.appGroups?.namespacePrefix ?? "app-",
      maxServices: catalog.appGroups?.maxServices ?? 0,
    },
  };
}

/** 위저드가 서버로 보내는 본문. Go `appProfileInput` 과 필드명이 같아야 한다. */
/**
 * 배포 요청에 실어 보내는 환경변수 한 줄.
 *
 * `classification: "openbao"` 값은 TLS 요청으로 포털 API에 전달된다. API는 값을
 * OpenBao에 즉시 저장하고 요청 저장소와 Forgejo 결과에는 key 이름만 남긴다.
 */
export interface AppProfileEnvVarInput {
  key: string;
  value?: string;
  classification: "configmap" | "openbao";
}

/** 같은 AppGroup 안의 앱 연결. 서버가 표준 label selector로 바꾼다. */
export interface AppPeerInput {
  app: string;
  port?: number;
  protocol?: "TCP";
}

/**
 * 앱 하나의 통신 정책. 사용자는 raw NetworkPolicy를 만들지 않는다.
 * egressMode 의미는 Go networkPolicyInput / charts/app-profile 과 같아야 한다.
 */
export interface NetworkPolicyInput {
  egressMode: "blocked" | "web" | "custom";
  allowedApps?: AppPeerInput[];
  allowedCIDRs?: { cidr: string; port: number; protocol?: "TCP" | "UDP" }[];
  ingress?: { allowedApps?: AppPeerInput[] };
}

export interface AppProfileInput {
  appName: string;
  group?: string;
  project: string;
  environment: string;
  gitRepository?: string;
  branch?: string;
  dockerfile?: string;
  image?: string;
  containerPort: number;
  /** 노출과 인증은 별개 축이다. 예전 문자열 형태도 서버가 받지만 화면은 객체만 보낸다. */
  exposure: { mode: "external" | "internal" };
  authentication?: { mode: "none" | "oidc" };
  networkPolicy?: NetworkPolicyInput;
  resourceSize: string;
  replicas: number;
  envVars?: AppProfileEnvVarInput[];
}

export type SubmitResult =
  | { ok: true; id: string; state: string; host: string }
  | { ok: false; reason: string; fieldErrors: Record<string, string> };

/**
 * 배포 신청 제출. `POST /api/v1/deployment-requests`.
 *
 * 실패는 전부 사용자에게 보여줄 문장으로 바꿔서 돌려준다 — 화면이 조용히
 * 성공한 척하면 안 된다. 같은 초안을 두 번 눌러도 PR이 두 개 생기지 않도록
 * 호출부가 만든 `idempotencyKey` 를 그대로 헤더에 싣는다.
 */
export async function submitDeploymentRequest(
  input: AppProfileInput,
  requester: string,
  idempotencyKey: string,
): Promise<SubmitResult> {
  let response: Response;
  try {
    response = await fetch(`${PORTAL_API_ORIGIN}${ENDPOINTS.deploymentRequests}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        "X-Portal-User": requester,
        "Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify(input),
      cache: "no-store",
      signal: AbortSignal.timeout(10000),
    });
  } catch (error) {
    warnOnce(`POST ${ENDPOINTS.deploymentRequests}`, error);
    return {
      ok: false,
      reason: "백엔드에 연결하지 못했습니다.",
      fieldErrors: {},
    };
  }

  if (response.ok) {
    const created = (await response.json()) as DeploymentRequestDto;
    return {
      ok: true,
      id: created.id,
      state: created.state,
      host: created.profile?.exposure?.host ?? "",
    };
  }

  let problem: ProblemDto = {};
  try {
    problem = (await response.json()) as ProblemDto;
  } catch {
    /* 본문이 없거나 JSON이 아니면 상태 코드만으로 설명한다. */
  }

  const fieldErrors: Record<string, string> = {};
  for (const item of problem.errors ?? []) {
    if (item.field) fieldErrors[item.field] = item.message;
  }

  const reason =
    problem.detail?.trim() ||
    problem.title?.trim() ||
    `요청이 거부되었습니다 (HTTP ${response.status}).`;

  return { ok: false, reason, fieldErrors };
}

export type DeleteResult =
  | { ok: true; state: string }
  | { ok: false; reason: string };

/** 로그인 세션에서 얻은 requester를 헤더에 싣는 소유자 제한 삭제 호출. */
export async function deleteDeploymentRequest(
  requestId: string,
  requester: string,
): Promise<DeleteResult> {
  if (!requestId.trim() || !requester.trim()) {
    return { ok: false, reason: "삭제 요청 정보를 확인하지 못했습니다." };
  }
  try {
    const response = await fetch(
      `${PORTAL_API_ORIGIN}${ENDPOINTS.deploymentRequests}/${encodeURIComponent(requestId)}`,
      {
        method: "DELETE",
        headers: { accept: "application/json", "X-Portal-User": requester },
        cache: "no-store",
        signal: AbortSignal.timeout(10000),
      },
    );
    if (response.ok) {
      const deleted = (await response.json()) as DeploymentRequestDto;
      return { ok: true, state: deleted.state };
    }
    let problem: ProblemDto = {};
    try {
      problem = (await response.json()) as ProblemDto;
    } catch {
      // 상태 코드 fallback을 사용한다.
    }
    return {
      ok: false,
      reason:
        problem.detail?.trim() ||
        problem.title?.trim() ||
        `삭제 요청이 거부되었습니다 (HTTP ${response.status}).`,
    };
  } catch (error) {
    warnOnce(`DELETE ${ENDPOINTS.deploymentRequests}`, error);
    return { ok: false, reason: "삭제 API에 연결하지 못했습니다." };
  }
}

export type RuntimeStateResult =
  | { ok: true; state: string }
  | { ok: false; reason: string };

/** Service/PVC는 유지하고 실행 Pod와 외부 경로만 정지하거나 다시 올린다. */
export async function updateDeploymentRuntimeState(
  requestId: string,
  requester: string,
  desiredState: ApplicationRuntimeTarget,
): Promise<RuntimeStateResult> {
  if (
    !requestId.trim() ||
    !requester.trim() ||
    !isApplicationRuntimeTarget(desiredState)
  ) {
    return { ok: false, reason: "실행 상태 변경 요청 정보를 확인하지 못했습니다." };
  }

  const endpoint = `${ENDPOINTS.deploymentRequests}/${encodeURIComponent(requestId)}/runtime-state`;
  try {
    const response = await fetch(`${PORTAL_API_ORIGIN}${endpoint}`, {
      method: "PUT",
      headers: portalApiJsonHeaders(requester),
      body: JSON.stringify({ state: desiredState }),
      cache: "no-store",
      signal: AbortSignal.timeout(10000),
    });
    if (response.ok) {
      const updated = (await response.json()) as DeploymentRequestDto;
      return { ok: true, state: updated.state };
    }

    let problem: ProblemDto = {};
    try {
      problem = (await response.json()) as ProblemDto;
    } catch {
      // 상태 코드 fallback을 사용한다.
    }
    return {
      ok: false,
      reason:
        problem.detail?.trim() ||
        problem.title?.trim() ||
        `실행 상태 변경이 거부되었습니다 (HTTP ${response.status}).`,
    };
  } catch (error) {
    warnOnce(`PUT ${ENDPOINTS.deploymentRequests}/:id/runtime-state`, error);
    return { ok: false, reason: "실행 상태 API에 연결하지 못했습니다." };
  }
}

/* ---------------------------- 다중 앱(Compose) ---------------------------- */

/** Compose 화면이 보내는 본문. Go `appGroupInput` 과 필드명이 같아야 한다. */
export interface AppGroupInput {
  group: string;
  project: string;
  environment: string;
  compose?: string;
  repository?: string;
  repositoryRevision?: string;
  resourceSize: string;
  services?: {
    name: string;
    /** OpenBao remote object의 key 이름만 전송한다. Secret 값은 이 API 모델에 없다. */
    secretKeys?: string[];
    exposure?: { mode: "external" | "internal" };
    authentication?: { mode: "none" | "oidc" };
    networkPolicy?: NetworkPolicyInput;
    replicas?: number;
  }[];
}

interface AppGroupPlanDto {
  group?: { name?: string; namespace?: string };
  source?: { type?: string; repository?: string; revision?: string; path?: string };
  warnings?: string[];
  services?: {
    profile?: {
      app?: { name?: string };
      service?: { enabled?: boolean; port?: number };
      persistence?: { enabled?: boolean; mountPath?: string };
      source?: { image?: string };
      exposure?: { mode?: string; host?: string };
      authentication?: { mode?: string };
      networkPolicy?: { egressMode?: string };
    };
  }[];
}

export type AppGroupValidateResult =
  | { ok: true; plan: ComposePlan }
  | { ok: false; reason: string; fieldErrors: Record<string, string> };

export type AppGroupSubmitResult =
  | { ok: true; group: string; namespace: string; count: number }
  | { ok: false; reason: string; fieldErrors: Record<string, string> };

/** 문제 응답을 화면이 쓸 수 있는 문장과 필드 오류로 바꾼다. */
async function readGroupProblem(
  response: Response,
  endpoint: string,
): Promise<{ reason: string; fieldErrors: Record<string, string> }> {
  let problem: ProblemDto = {};
  try {
    problem = (await response.json()) as ProblemDto;
  } catch {
    /* 본문이 없거나 JSON이 아니면 상태 코드만으로 설명한다. */
  }
  const fieldErrors: Record<string, string> = {};
  for (const item of problem.errors ?? []) {
    if (item?.field) fieldErrors[item.field] = item.message;
  }
  return {
    reason:
      problem.detail?.trim() ||
      problem.title?.trim() ||
      `${endpoint} 요청이 거부되었습니다 (HTTP ${response.status}).`,
    fieldErrors,
  };
}

/** Compose 사전검증. 저장하지 않고 서비스마다 배포 계획만 계산한다. */
export async function validateAppGroup(
  input: AppGroupInput,
  requester: string,
): Promise<AppGroupValidateResult> {
  let response: Response;
  try {
    response = await fetch(`${PORTAL_API_ORIGIN}${ENDPOINTS.appGroupValidate}`, {
      method: "POST",
      headers: portalApiJsonHeaders(requester),
      body: JSON.stringify(input),
      cache: "no-store",
      signal: AbortSignal.timeout(30000),
    });
  } catch (error) {
    warnOnce(`POST ${ENDPOINTS.appGroupValidate}`, error);
    return { ok: false, reason: "백엔드에 연결하지 못했습니다.", fieldErrors: {} };
  }
  if (!response.ok) {
    return { ok: false, ...(await readGroupProblem(response, ENDPOINTS.appGroupValidate)) };
  }
  const dto = (await response.json()) as AppGroupPlanDto;
  return {
    ok: true,
    plan: {
      group: dto.group?.name ?? input.group,
      namespace: dto.group?.namespace ?? "",
      source: {
        type: dto.source?.type ?? (input.repository ? "git" : "compose"),
        repository: dto.source?.repository,
        revision: dto.source?.revision,
        path: dto.source?.path,
      },
      warnings: dto.warnings ?? [],
      services: (dto.services ?? []).map((item) => {
        const profile = item.profile;
        return {
          name: profile?.app?.name ?? "",
          namespace: dto.group?.namespace ?? "",
          port: profile?.service?.port ?? 0,
          serviceEnabled:
            profile?.service?.enabled ?? (profile?.service?.port ?? 0) > 0,
          persistenceMountPath: profile?.persistence?.enabled
            ? profile.persistence.mountPath
            : undefined,
          image: profile?.source?.image || undefined,
          host: profile?.exposure?.host || undefined,
          exposureMode:
            profile?.exposure?.mode === "internal" ? "internal" : "external",
          authMode: profile?.authentication?.mode === "oidc" ? "oidc" : "none",
          egressMode:
            profile?.networkPolicy?.egressMode === "web"
              ? "web"
              : profile?.networkPolicy?.egressMode === "custom"
                ? "custom"
                : "blocked",
        };
      }),
    },
  };
}

/** AppGroup 신청. 서비스 수만큼 배포 요청이 만들어진다. */
export async function submitAppGroup(
  input: AppGroupInput,
  requester: string,
  idempotencyKey: string,
): Promise<AppGroupSubmitResult> {
  let response: Response;
  try {
    response = await fetch(`${PORTAL_API_ORIGIN}${ENDPOINTS.appGroups}`, {
      method: "POST",
      headers: portalApiJsonHeaders(requester, idempotencyKey),
      body: JSON.stringify(input),
      cache: "no-store",
      signal: AbortSignal.timeout(45000),
    });
  } catch (error) {
    warnOnce(`POST ${ENDPOINTS.appGroups}`, error);
    return { ok: false, reason: "백엔드에 연결하지 못했습니다.", fieldErrors: {} };
  }
  if (!response.ok) {
    return { ok: false, ...(await readGroupProblem(response, ENDPOINTS.appGroups)) };
  }
  const created = (await response.json()) as {
    group?: { name?: string; namespace?: string };
    count?: number;
  };
  return {
    ok: true,
    group: created.group?.name ?? input.group,
    namespace: created.group?.namespace ?? "",
    count: created.count ?? 0,
  };
}
