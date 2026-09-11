<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# SADP 포털 (portal-lite/ui) — 에이전트 가이드

이 문서는 **다음 AI 에이전트가 이 코드베이스를 건드리기 전에 반드시 읽어야 하는 규칙과 함정**을 정리한 것이다.
추측으로 코드를 짜지 말고, 여기 적힌 제약을 먼저 확인해라.

> 이 문서는 **`ui/` 안쪽만** 다룬다. 저장소 전체 규칙(계약 기반 생성물을 손으로 고치지 말 것,
> Secret 취급, 검증 스크립트, 네트워크 규칙)은 루트의 [`AGENTS.md`](../../../AGENTS.md)에 있다.
> 리포지토리 루트에서 작업을 시작했다면 그쪽을 먼저 읽어라.

---

## 1. 프로젝트 개요

- 위치: `SADP/apps/portal-lite/ui` (모노레포 `SADP` 안의 앱 하나)
- 정체: 사내 Kubernetes 플랫폼(RKE2) 사용자 포털의 프론트엔드
- 스택: **Next.js 16.3.1 (App Router) / React 19.2.8 / TypeScript 6.0.3 / Tailwind CSS v4 / shadcn-ui(new-york) / lucide-react / next-auth 5 beta**
- 경로 alias: `@/*` → 프로젝트 루트 (`tsconfig.json`)
- 패키지 매니저: npm (`package-lock.json` 기준). `node ^22.15.0 || ^24.0.0 || >=26.0.0`

### 명령어

```bash
npm run dev        # 개발 서버
npm run build      # 프로덕션 빌드 (output: "standalone")
npm run lint       # eslint (0 error 유지 필수)
npm run typecheck  # tsc --noEmit (0 error 유지 필수)
npm run test       # vitest (lib/oidc-token.test.ts 포함)
```

- 코드를 고쳤으면 **최소 `npm run typecheck` + `npm run lint` + `npm run build`** 를 통과시키고 끝내라. warning은 남아 있어도 되지만 error는 0이어야 한다.
- `next.config.ts` 에 `output: "standalone"` 이 걸려 있어서 **`next start` 는 동작하지 않는다.** 프로덕션 기동은 `node .next/standalone/server.js` 로 한다 (`.next/static`, `public` 을 standalone 디렉터리로 복사해야 정적 자원이 뜬다).

---

## 2. 디렉터리 구조와 라우트 그룹 (가장 중요)

```
app/
├── layout.tsx                 # 루트. CSS를 import하지 않는다(의도적).
├── globals.css                # 레거시 화면 전용 CSS (Tailwind 아님)
├── api/
│   ├── auth/[...nextauth]/    # next-auth 핸들러
├── (legacy)/                  # 기존 운영 화면 — 건드리지 말 것
│   ├── layout.tsx             #   globals.css 를 여기서만 로드
│   ├── portal/ account/ login/
└── (paas)/                    # 신규 화면 (원래 7개였고 화면3 문서는 제거됨)
    ├── layout.tsx             #   AppHeader + Toaster + force-dynamic
    ├── paas.css               #   Tailwind v4 진입점 + 디자인 토큰
    ├── page.tsx               #   화면2 대시보드 (/)
    ├── admin/                 #   platform-admin 전용 승인 대시보드
    ├── my-apps/               #   화면1
    ├── new-app/[step]/        #   화면4-5 (6-step 위저드)
    ├── deployments/env-classifier/  # 화면6
    └── services/              #   화면7
components/
├── ui/        # shadcn 프리미티브 (직접 손으로 만들지 말고 `npx shadcn@latest add <name>`)
├── paas/      # 신규 화면 도메인 컴포넌트
└── portal.tsx # 레거시
lib/     # site-config, paas-api, format-date, env-parse, new-app-draft, oidc-token,
         # require-session(로그인 게이트 + 개발 우회), i18n/, utils
types/domain.ts  # 화면 전체가 공유하는 도메인 타입 — 여기서 시작해라
디자인파일/       # 확정 스크린샷. 스펙의 최종 근거(화면3 문서는 제거되어 해당 시안은 미사용).
../backend/openapi.yaml  # 백엔드 계약서 SSOT (§5 경고 반드시 읽을 것)
```

### 🔴 `(legacy)` 와 `(paas)` 의 CSS 분리는 의도적이다

루트 `app/layout.tsx` 는 **스타일시트를 import 하지 않는다.**
`(legacy)/layout.tsx` 가 `globals.css` 를, `(paas)/layout.tsx` 가 `paas.css` 를 각각 로드한다.
이유: Tailwind v4 의 preflight(리셋)가 기존 `/portal`·`/account`·`/login` 화면을 망가뜨리기 때문이다.
**루트 레이아웃에 CSS를 올리거나 두 CSS를 합치지 마라. 레거시 화면이 즉시 깨진다.**
`paas.css` 는 `@import "tailwindcss" source(none)` + 명시적 `@source` 로 스캔 범위를 좁혀 놨다.

---

## 3. 디자인 토큰 규칙

토큰은 **`app/(paas)/paas.css` 한 곳**에서만 정의한다 (`:root` HSL 변수 → `@theme inline` 으로 Tailwind 유틸리티 노출).
Tailwind v4 라서 `tailwind.config.ts` 는 없다. 토큰을 늘리려면 `paas.css` 를 고쳐라.

| 용도 | 토큰 | 값 |
|---|---|---|
| 브랜드 딥그린 | `--brand-900` / `--primary` | `#0B3B2E` |
| 브랜드 액센트 | `--brand-accent` / `--accent` | `#036635` |
| 상단 네비 활성 | `--nav-active` | 옐로-그린 `hsl(66 70% 54%)` |
| 페이지 배경 | `--background` | `#FDFBF3` 아이보리 |
| 코드/정보 박스 | `--secondary` | `#EFF6FF` |
| 카드 보더 | `--border` | `#E5E7EB` 1px |
| 상태 | `--status-ok / -warn / -error / -idle` (+ `-soft`, `-strong`) | Running·Beta·Failed·정지 |
| OpenBao 검은 카드 | `--vault*` | 다크모드가 아니라 **의도적으로 검은 카드**. 테마와 무관하게 고정. |

규칙:

- **임의값(arbitrary value) 금지.** `bg-[#0B3B2E]`, `text-[13px]` 처럼 쓰지 말고 토큰/스케일을 써라.
- 라운드: 카드 `12px`(`--radius`), 버튼·인풋 `8px`(`rounded-md`), 배지 `full`.
- 그림자: 거의 없음. **보더 중심**의 플랫 스타일.
- 폰트: 본문 산세리프(한글 포함), **숫자·ID·경로·호스트명·네임스페이스·URL·env key 는 전부 모노스페이스**(`font-mono`).
- 레이아웃: 콘텐츠 최대 폭 `max-w-[1200px]` (`SITE.contentMaxWidth`), 헤더/푸터만 full-width.
- 다크 팔레트(`.dark`)는 **확정 시안이 없어 라이트 토큰에서 파생한 추정치**다. 다크 시안이 나오면 그 블록만 교체하면 된다.

---

## 4. 데이터 흐름 (이 순서를 지켜라)

```
types/domain.ts  →  lib/paas-api.ts  →  서버 컴포넌트(page.tsx)  →  뷰 컴포넌트(components/paas/*)
```

- **`lib/paas-api.ts` 가 화면 ↔ 백엔드의 유일한 접점**이다. `import "server-only"` 가 걸려 있어 클라이언트에서 부르면 빌드가 깨진다.
- 동작: 같은 Pod의 Go API를 고정 loopback `127.0.0.1:8081`로 호출한다. 사용자 신원 헤더와 OpenBao 입력이 외부 origin으로 나가지 않도록 공개 build 변수로 바꿀 수 없다. 호출이 실패하면 `fetchJson` 이 **`null`** 을 돌려주고 `warnOnce` 로 한 번만 경고하며, 화면은 이를 **"지금은 알 수 없음"** 으로 다룬다.
- **목데이터 폴백은 없다.** `mocks/` 디렉터리는 제거되었으니 "백엔드가 죽으면 목으로 그려진다"고 가정하지 마라.
- 페이지는 `async` 서버 컴포넌트에서 `await getX()` 로 데이터를 받아 **뷰 컴포넌트에 props로 내려준다.** 클라이언트 컴포넌트에서 fetch 하지 마라.
- `"use client"` 는 **상태·이벤트·브라우저 API가 필요한 최소 단위**에만 붙인다 (필터/뷰 토글/검색, DnD, Copy 버튼, 위저드 폼, 토스트).
- 새 필드가 필요하면 `types/domain.ts` → `paas-api.ts` → 화면 순으로 확장해라. 화면에서 임의로 데이터를 만들지 마라.

---

## 5. 🔴 백엔드 API 계약

`../backend/openapi.yaml`(OpenAPI 3.1.1)이 유일한 API 계약서다. UI 디렉터리에
복사본을 두면 백엔드 변경과 조용히 어긋나므로 별도 `ui/openapi.yaml`을 만들지 않는다.
현재 구현된 주요 엔드포인트는 다음과 같다.

| 실제 스펙 | 상태 |
|---|---|
| `GET /api/v1/health` | 구현됨 |
| `GET /api/v1/catalog` | 구현됨 (사용자 서비스·앱 템플릿·자원 preset **구성 카탈로그**. K8s 실시간 상태 API가 아니다) |
| `POST /api/v1/app-profiles/validate` | 구현됨 (저장 없이 사전검증, 배포 계획 계산) |
| `GET /api/v1/openapi.yaml` | 구현됨 |
| `GET/POST /api/v1/deployment-requests` | 구현됨(Forgejo/GitOps 연결이 준비되지 않으면 **503 Problem Details**) |
| `GET/DELETE /api/v1/deployment-requests/{requestId}` | 구현됨 |
| `GET /api/v1/admin/approval-dashboard` | 구현됨(`platform-admin` 전용 전체 승인·private PR 조회) |
| `POST /api/v1/admin/deployment-requests/{requestId}/decision` | 구현됨(보안 통과 뒤 승인 또는 사유 필수 반려) |
| `PUT /api/v1/admin/approval-policies/{requester}` | 구현됨(사용자별 자동 승인 예외 감사 이력) |
| `POST /api/v1/app-groups/validate` | 구현됨(Compose 파싱·서비스별 정책 검증) |
| `POST /api/v1/app-groups` | 구현됨(AppGroup 멱등 생성) |
| `GET /api/v1/quota-usage` | 구현됨 |

`lib/paas-api.ts`의 `ENDPOINTS`와 DTO 매핑이 화면 ↔ 백엔드의 단일 접점이다:

```ts
catalog:            "/api/v1/catalog",
deploymentRequests: "/api/v1/deployment-requests",
quotaUsage:         "/api/v1/quota-usage",
appGroupValidate:   "/api/v1/app-groups/validate",
appGroups:          "/api/v1/app-groups",
```

새 API를 추가할 때는 `../backend/openapi.yaml` → Go handler → `paas-api.ts` DTO/매핑 →
`types/domain.ts` 순서로 함께 갱신한다. 화면 코드가 raw API 형태에 의존하게 만들지 마라.

부가 규칙 (스펙 명시):

- 단일 앱 배포 요청의 `Idempotency-Key` 헤더는 하위 호환을 위해 선택이고, AppGroup 생성에서는 필수다. 보낼 때는 1~128자 `^[A-Za-z0-9._:-]+$`를 지킨다. 인증은 외부 OIDC (`deployments:read` / `deployments:write`).
- 요청 본문 64 KiB 제한(413), `application/json` 아니면 415, 의미 검증 실패는 422, 에러는 `application/problem+json`.
- **Secret 실제 값은 어떤 응답에도 실리지 않는다.** 화면6 마스킹 로직(`MASKED_VALUE`)을 우회하지 마라.

---

## 6. 환경변수 — 화면 문자열 하드코딩 금지

버전·카피라이트·Git/SSO 도메인·앱 도메인은 **화면에 절대 하드코딩하지 않는다.** 전부 `lib/site-config.ts` 의 `SITE` / `PLATFORM` 을 거친다.

| 변수 | 쓰이는 곳 |
|---|---|
| `NEXT_PUBLIC_PAAS_VERSION`, `NEXT_PUBLIC_PAAS_COPYRIGHT_YEAR` | `AppFooter` |
| `NEXT_PUBLIC_GIT_BASE_URL`, `NEXT_PUBLIC_GIT_DEFAULT_ORG` | 화면4-5 Step2 저장소 URL placeholder/검증 (`GIT_REPO_PLACEHOLDER`) |
| `NEXT_PUBLIC_PAAS_APP_DOMAIN` | 배포 앱 호스트명 placeholder |
| `AUTH_OIDC_ID/ISSUER/SECRET`, `AUTH_OIDC_TOKEN_ENDPOINT`, `AUTH_SECRET` | 서버 전용. 브라우저로 나가면 안 된다 |
| `PAAS_DEV_AUTH_BYPASS` / `PAAS_DEV_USER` / `PAAS_DEV_ROLES` | **개발 전용 로그인 우회**(아래 §6.1). 배포 values 에 넣으면 `ci-guard.sh` 가 막는다 |

- `NEXT_PUBLIC_` 접두사가 없는 값은 **절대 클라이언트 컴포넌트에서 참조하지 마라.**
- `.env.local` / `.env.development` 는 커밋하지 않는다(`.gitignore` 의 `.env.*`). 로컬 개발용 값은 `.env.development` 에 둔다. (`.env.example` 은 현재 존재하지 않는다.)
- 배포 이미지 빌드는 저장소 루트 `.env`를 직접 source하지 않는다. `scripts/cluster/build-local-images.sh`가
  `scripts/site/portal-ui-build-env.py`의 화이트리스트에 있는 `NEXT_PUBLIC_*`만 로컬 사전검사와
  Docker frontend 단계에 전달한다. 직접 `npm run dev/build`할 때도 package script의
  `scripts/with-root-build-env.mjs`가 같은 파서를 사용한다. `ui/.env.development`는 개발 우회처럼
  루트 공개 빌드값과 별개인 UI 전용 로컬 설정에 사용한다.

### 6.1 개발 전용 로그인 우회

`(paas)` 화면 전체는 `app/(paas)/layout.tsx` 의 `requirePaasSession()` 이 막는다. 외부 OIDC client
자격증명 없이 화면을 보려면 `lib/require-session.ts` 의 `devBypassSession()` 을 쓴다.

**인증을 끄는 코드이므로 두 조건을 모두 만족할 때만 동작한다.**

1. `NODE_ENV === "development"` — `next build` 산출물은 `production` 이라 분기 자체가 죽는다.
2. `PAAS_DEV_AUTH_BYPASS === "true"` — 기본값이 없어 변수를 빠뜨리면 평소대로 로그인 화면으로 간다.

`PAAS_DEV_USER` / `PAAS_DEV_ROLES` 로 가짜 세션의 사용자명과 역할을 바꾼다(역할은 화면2 대시보드와
화면7 카탈로그가 노출을 거를 때 쓴다).

- 이 변수들을 **배포 values 에 넣지 마라.** `scripts/ci-guard.sh` 가 `apps/charts/platform/argocd/contracts/rke`
  의 YAML 에서 `PAAS_DEV_AUTH_BYPASS` 를 찾으면 실패시킨다.
- `(paas)` 화면에서 `auth()` 를 직접 부르지 마라. 우회가 적용되지 않아 layout 은 통과했는데 그 화면만
  역할이 비는 어긋남이 생긴다. 반드시 `requirePaasSession()` / `paasIdentity()` 를 거쳐라.

---

## 7. 🔴 이미 밟은 지뢰들 (같은 실수 반복 금지)

1. **CSP nonce + 정적 프리렌더 = 화면이 스켈레톤에서 멈춤**
   `proxy.ts` 가 요청마다 새 nonce 로 `script-src 'self' 'nonce-…' 'strict-dynamic'` 을 내려준다. 정적 프리렌더된 HTML에는 nonce가 박히지 않아 **모든 스크립트가 차단되고 hydration이 죽는다.**
   → `app/(paas)/layout.tsx` 의 `export const dynamic = "force-dynamic"` 은 이 때문에 있다. **지우지 마라.**

2. **inline `style` 속성 금지**
   `style-src 'self' 'nonce-…'` 라서 인라인 스타일이 차단된다. Progress/QuotaBar 채움 너비를 `style={{width}}` 로 주면 안 된다.
   → `paas.css` 의 `@source inline("w-[{0..100}%]")` 로 0~100% 클래스를 미리 생성해 두고 **클래스로** 폭을 준다.

   **CSP nonce 는 `<style>` 태그에만 적용되고 `style="..."` 속성에는 적용되지 않는다.** 속성 인라인 스타일은 `'unsafe-inline'` 이 있어야 통과하는데 이 플랫폼은 주지 않는다.

2-1. **토스트(sonner)를 쓰지 마라 — 이 CSP 에서 구조적으로 깨진다**
   sonner 는 토스트의 위치·스택·오프셋을 전부 인라인 `style` 속성으로 준다. 그래서 차단되면
   위치를 잃고 **화면 맨 아래에 그대로 흘러 붙는다.** "모달이 안 뜨고 아래에 뜬다"는 제보의 정체가 이것이다.
   `components/ui/sonner.tsx` 자체도 `style={{ "--normal-bg": … }}` 를 넘기므로 테마 변수도 안 먹는다.
   → 알림은 **클래스만 쓰는 인라인 배너**(`new-app-wizard.tsx` 의 `alert` 배너)나
     **AlertDialog**(`env-classifier-view.tsx`)로 띄운다. Radix AlertDialog 는 위치를 전부
     Tailwind 클래스(`fixed top-[50%] left-[50%] translate-…`)로 잡아 영향이 없다.
   → `(paas)/layout.tsx` 에서 `<Toaster />` 를 걷어냈다. **다시 넣지 마라.**

3. **시간 표기 hydration mismatch**
   서버/클라이언트 시각이 달라 mismatch가 난다.
   → 절대 표기는 항상 **UTC**로 계산(`lib/format-date.ts`, `Intl.DateTimeFormat` timeZone UTC), 7일 이내만 상대 표기. 상대 시각의 실시간 갱신은 `components/paas/relative-time.tsx` 가 `useSyncExternalStore` 로 처리한다.
   → `suppressHydrationWarning` 으로 덮지 마라.

4. **`useSearchParams` 는 Suspense 경계 필수**
   안 감싸면 빌드가 깨진다. 화면1 `MyAppsView` 처럼 `<Suspense fallback={...}>` 로 감싸라. 필터/검색 상태는 `useSearchParams` + `router.replace` 로 **URL에 동기화**한다.

5. **위저드(화면4-5) 상태는 `sessionStorage`**
   `lib/new-app-draft.ts`, 키 `sadp:new-app-draft`. `useSyncExternalStore` 로 구독하며 서버 스냅샷은 `EMPTY_DRAFT` 다. 계획 생성/취소 시 삭제한다. 스텝은 `/new-app/[step]` 으로 **URL에 남아야** 새로고침이 살아난다.

6. **next-auth v5 + 리버스 프록시**
   호스트 헤더가 달라 `UntrustedHost` 가 뜨면 `AUTH_TRUST_HOST=true` 를 환경변수로 넣어라 (코드에 `trustHost` 를 박지 말 것).

7. **아이콘/컴포넌트를 손으로 만들지 마라**
   shadcn 프리미티브는 `npx shadcn@latest add <name>`, 아이콘은 `lucide-react`. `components.json` 의 css 경로는 `app/(paas)/paas.css` 로 잡혀 있다.

8. **드래그앤드롭(화면6)은 외부 DnD 라이브러리 없이** HTML5 native DnD 로 구현되어 있다. 새 의존성 추가는 최소화하고, 필요하면 이유부터 밝혀라.

---

## 8. 화면 ↔ 파일 대응표

| # | 라우트 | 페이지 | 핵심 컴포넌트 |
|---|---|---|---|
| 1 | `/my-apps` | `app/(paas)/my-apps/page.tsx` | `my-apps-view`, `app-card`, `status-pill`, `empty-state` |
| 2 | `/` | `app/(paas)/page.tsx` | `platform-status-banner`, `quick-access-card`, `workload-card`, `system-notices-card`, `quota-bar`, `deployment-requests-table` |
| 4-5 | `/new-app/[step]` (1~6) | `app/(paas)/new-app/[step]/page.tsx` | `new-app-wizard`, `new-app-steps`, `wizard-stepper`, `form-field` |
| 6 | `/deployments/env-classifier` | `app/(paas)/deployments/env-classifier/page.tsx` | `env-classifier`, `env-classifier-view`, `mono-kv-box` |
| 7 | `/services` | `app/(paas)/services/page.tsx` | `service-catalog-view`, `service-card` |
| 공통 | — | `(paas)/layout.tsx` | `app-header`(+`paas-nav`), `app-footer`, `page-header`, `section-heading` |

- 헤더는 `(paas)/layout.tsx` 에서 **한 번만** 렌더링한다.
- 푸터는 화면마다 링크 구성이 달라서 **각 page 가 `<AppFooter />` 를 직접** 렌더링한다. (레이아웃으로 올리지 마라.)
- 네비 항목 라벨은 `lib/site-config.ts` 의 `NAV_ITEMS` 에서 관리하며 **스펙 문구 그대로** 유지한다.

---

## 9. 작업 규칙

1. **디자인은 `디자인파일/` 스크린샷이 최종 근거다.** 창의적 재해석 금지. 임의로 필드·섹션·버튼을 추가하거나 빼지 마라.
2. 스펙이 모호하면 **추측하지 말고 먼저 질문**해라.
3. 기존 컨벤션(파일 네이밍 kebab-case, `@/` alias, 한국어 주석, "왜"를 설명하는 주석)을 그대로 따라라.
4. 백엔드 응답 → 도메인 타입 매핑은 `lib/paas-api.ts` **안에서만** 한다. 실제 API 연결 시 한 곳만 고치면 되게 유지해라.
5. 문구는 스크린샷 그대로 유지한다(정식 i18n은 도입하지 않았다).
6. 접근성: `aria-label`, `aria-hidden`, 키보드 대체 경로(특히 화면6 DnD), 모노스페이스 값의 충분한 명암비.
7. 끝내기 전 `typecheck` → `lint` → `build` 를 돌리고, 화면을 실제로 띄워 스크린샷과 대조해라.

## 10. 남은 일

- [ ] 실제 클러스터에서 Compose/AppGroup 생성·삭제 E2E 검수
- [ ] 다크 팔레트 확정 시안 반영 (`paas.css` 의 `.dark` 블록)
- [ ] 프로덕션 기동 스크립트(standalone 복사 단계) 정리

## OIDC 갱신 정합성

- `proxy.ts`는 세션을 사용하지 않는다. `auth()` wrapper를 다시 붙이지 마라. Proxy와
  서버 렌더 코드의 전역 메모리 공유는 런타임 이름이 같아도 보장되지 않는다.
- `auth.ts`의 갱신은 `lib/oidc-refresh-coordinator.ts`를 거친다. refresh token 원문 키,
  await 전 진행 중 등록, 성공 결과 TTL, 맵 상한과 실패 비캐시 규칙을 유지한다.
- RSC의 `auth()`는 회전 cookie를 브라우저에 쓰지 못한다. `SessionCookieSync`의 Auth.js
  session 호출을 제거하면 긴 조회 세션에서 구 token 재사용이 재발한다.
- 병합은 단일 Node 실행 컨텍스트 안에서만 유효하다. replica/worker/isolate를 늘리기 전에
  [OIDC 갱신 감사](../../../docs/portal-oidc-refresh.md)를 다시 확인한다.
