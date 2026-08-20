/**
 * 포털 전역 상수. 버전/카피라이트 문자열은 화면에 하드코딩하지 않고 여기서만 관리한다.
 * 배포 시 NEXT_PUBLIC_* 로 주입하면 코드 변경 없이 갱신된다.
 */
export const SITE = {
  name: "SADP",
  version: process.env.NEXT_PUBLIC_PAAS_VERSION ?? "v1.5.0-stable",
  copyrightYear: process.env.NEXT_PUBLIC_PAAS_COPYRIGHT_YEAR ?? "2026",
  /** 콘텐츠 최대 폭(px). 전 화면 공통. */
  contentMaxWidth: 1200,
} as const;

/**
 * 환경마다 바뀌는 외부 시스템 주소. 화면에 절대 하드코딩하지 않는다.
 * (사내/개발/운영 클러스터마다 Git·SSO 도메인이 다르다.)
 */
export const PLATFORM = {
  /** Git 저장소 호스트 (화면 4-5 Step 2 placeholder/검증). */
  gitBaseUrl: process.env.NEXT_PUBLIC_GIT_BASE_URL ?? "https://github.com",
  /** 예시 placeholder 에 쓰는 기본 조직명. */
  gitOrg: process.env.NEXT_PUBLIC_GIT_DEFAULT_ORG ?? "organization",
  /** SSO(Keycloak) 도메인 (화면 4-5 Step 4, 화면 7 서비스 카탈로그). */
  ssoBaseUrl:
    process.env.NEXT_PUBLIC_SSO_BASE_URL ?? "https://sso.sadp.example.invalid",
  ssoRealm: process.env.NEXT_PUBLIC_SSO_REALM ?? "sadp",
  /** 앱이 노출될 기본 도메인 (호스트명 placeholder). */
  appDomain:
    process.env.NEXT_PUBLIC_PAAS_APP_DOMAIN ?? "apps.sadp.example.invalid",
  /** 워크로드가 올라가는 클러스터 이름 (애플리케이션 카드 표기용). */
  clusterName: process.env.NEXT_PUBLIC_PAAS_CLUSTER_NAME ?? "sadp-rke2",
} as const;

/**
 * 레거시 소개 화면(`/portal`)이 링크하는 역할별 외부 도구.
 * 테스트베드 기본값을 두되 배포 환경에서는 NEXT_PUBLIC_* 로 덮어쓴다.
 */
export const LEGACY_TOOLS = {
  baoUrl:
    process.env.NEXT_PUBLIC_BAO_BASE_URL ??
    "https://openbao.sadp.example.invalid",
  rancherUrl:
    process.env.NEXT_PUBLIC_RANCHER_BASE_URL ??
    "https://rancher.sadp.example.invalid",
  keycloakUrl:
    process.env.NEXT_PUBLIC_LEGACY_SSO_BASE_URL ??
    "https://sso.sadp.example.invalid",
  apiContractUrl: "/api/v1/openapi.yaml",
} as const;

/** `https://<git-host>/<org>/repository.git` 형태의 입력 예시. */
export const GIT_REPO_PLACEHOLDER = `${PLATFORM.gitBaseUrl}/${PLATFORM.gitOrg}/repository.git`;

/**
 * 링크 구성만 여기서 관리하고, 표시 문구는 로케일별 사전에서 온다.
 * `key` 는 `dict.common.footer` / `dict.common.nav` 의 키와 1:1 로 맞춘다.
 */
// 기존 두 항목(security, apiStatus)은 /docs 앵커를 가리켰다. 문서 화면을 걷어내면서
// 링크 대상이 사라졌으므로 함께 제거했다. 대체 URL이 정해지면 여기에 다시 넣는다.
export const FOOTER_LINKS = [] as const satisfies readonly {
  key: string;
  href: string;
}[];

/** 상단 내비게이션 항목. */
export const NAV_ITEMS = [
  { key: "home", href: "/", match: "/" },
  { key: "services", href: "/services", match: "/services" },
  { key: "myApps", href: "/my-apps", match: "/my-apps" },
  {
    key: "deployments",
    href: "/deployments/env-classifier",
    match: "/deployments",
  },
  { key: "newApp", href: "/new-app/1", match: "/new-app" },
] as const satisfies readonly { key: string; href: string; match: string }[];
