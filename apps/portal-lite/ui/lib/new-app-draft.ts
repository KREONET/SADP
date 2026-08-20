import { checkUserQuota } from "@/lib/quota";
import { GIT_REPO_PLACEHOLDER } from "@/lib/site-config";
import { EMPTY_DRAFT, WIZARD_LAST_STEP } from "@/lib/wizard";
import type { NewAppDraft, WizardOptions } from "@/types/domain";
import {
  isSafeAllowedCidr,
  missingOpenBaoKeys,
} from "./new-app-draft-policy";
import { migrateStoredDraft } from "./new-app-draft-migration";

export { migrateStoredDraft } from "./new-app-draft-migration";
export {
  draftFieldForApiError,
  isSafeAllowedCidr,
  missingOpenBaoKeys,
} from "./new-app-draft-policy";

/*
 * 검증 규칙은 서버(apps/portal-lite/app_profile.go validateInput)를 그대로 옮긴 것이다.
 * UI에서 통과한 값이 서버에서 거부되면 사용자는 이유를 알 수 없으므로 패턴·상한을
 * 서버와 같은 문자로 유지한다. 규칙을 바꿀 때는 양쪽을 함께 고친다.
 */

/** 새로고침 대비 임시 저장 키. 계획 생성/취소 시 지운다. */
export const DRAFT_STORAGE_KEY = "sadp:new-app-draft";

/** 제출 재시도용 멱등 키 보관 자리. 초안과 수명을 같이한다. */
export const IDEMPOTENCY_STORAGE_KEY = "sadp:new-app-idempotency";

/** DNS-1123 라벨. 서버 appNamePattern과 동일. */
export const APP_NAME_PATTERN = /^[a-z]([-a-z0-9]*[a-z0-9])?$/;

/** 서버 branchPattern과 동일. */
export const BRANCH_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/;

export type DraftErrors = Partial<Record<keyof NewAppDraft, string>>;

export function isValidStep(step: number): boolean {
  return Number.isInteger(step) && step >= 1 && step <= WIZARD_LAST_STEP;
}

export function loadDraft(): NewAppDraft {
  if (typeof window === "undefined") return EMPTY_DRAFT;
  try {
    const raw = window.sessionStorage.getItem(DRAFT_STORAGE_KEY);
    if (!raw) return EMPTY_DRAFT;
    const migrated = migrateStoredDraft(JSON.parse(raw) as unknown);
    // 구형 secret 분류의 값이 sessionStorage에 남아 있을 수 있다. 메모리에는 이번
    // 제출을 위해 유지하되, 저장본은 현재 OpenBao 마스킹 규칙으로 즉시 다시 쓴다.
    saveDraft(migrated);
    return migrated;
  } catch {
    return EMPTY_DRAFT;
  }
}

export function saveDraft(draft: NewAppDraft): void {
  if (typeof window === "undefined") return;
  try {
    // Secret은 페이지 이동 동안 메모리에만 유지한다. sessionStorage에 남기면 로그아웃이나
    // 브라우저 종료 전까지 같은 origin의 스크립트가 값을 다시 읽을 수 있다.
    const safeDraft = {
      ...draft,
      envVars: draft.envVars.map((item) =>
        item.classification === "openbao" ? { ...item, value: "" } : item,
      ),
    };
    window.sessionStorage.setItem(DRAFT_STORAGE_KEY, JSON.stringify(safeDraft));
  } catch {
    /* 저장 실패는 무시한다 — 위저드 진행을 막지 않는다. */
  }
}

function removeStoredDraft(): void {
  if (typeof window === "undefined") return;
  try {
    window.sessionStorage.removeItem(DRAFT_STORAGE_KEY);
  } catch {
    /* noop */
  }
}

/* ---------------------------- 초안 외부 스토어 ---------------------------- */
/*
 * 스텝을 옮겨도(= 라우트가 바뀌어도) 값이 유지돼야 하므로 컴포넌트 밖에 둔다.
 * useSyncExternalStore 로 읽어야 hydration 시 서버 스냅샷(EMPTY_DRAFT)과
 * 클라이언트 스냅샷(sessionStorage)이 어긋나지 않는다.
 */

let cached: NewAppDraft | null = null;
const listeners = new Set<() => void>();

export function subscribeDraft(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function getDraftSnapshot(): NewAppDraft {
  cached ??= loadDraft();
  return cached;
}

export function getServerDraftSnapshot(): NewAppDraft {
  return EMPTY_DRAFT;
}

export function setDraft(next: NewAppDraft): void {
  cached = next;
  saveDraft(next);
  listeners.forEach((listener) => listener());
}

/** 계획 생성/취소 후 초안을 비운다. */
export function clearDraft(): void {
  removeStoredDraft();
  try {
    window?.sessionStorage.removeItem(IDEMPOTENCY_STORAGE_KEY);
  } catch {
    /* noop */
  }
  cached = EMPTY_DRAFT;
  listeners.forEach((listener) => listener());
}

/**
 * 이 초안의 멱등 키. 한 번 만들면 초안이 지워질 때까지 같은 값을 돌려준다.
 *
 * 제출이 타임아웃이나 네트워크 오류로 끝난 경우 서버는 이미 신청을 만들었을 수
 * 있다. 재시도에 새 키를 쓰면 PR 이 두 개 생기므로, 키는 "초안 1개 = 신청 1건"
 * 단위로 고정한다.
 */
export function getIdempotencyKey(): string {
  if (typeof window === "undefined") return "";
  try {
    const existing = window.sessionStorage.getItem(IDEMPOTENCY_STORAGE_KEY);
    if (existing) return existing;
    const created = crypto.randomUUID();
    window.sessionStorage.setItem(IDEMPOTENCY_STORAGE_KEY, created);
    return created;
  } catch {
    /* 저장을 못 하면 이번 시도에만 쓰는 키로 진행한다(재시도 시 새 키). */
    return crypto.randomUUID();
  }
}

/** 숫자 문자열(정수, 1 이상) 검사. */
function isPositiveInt(value: string): boolean {
  return /^\d+$/.test(value) && Number(value) >= 1;
}

/** 검증 메시지 사전 (로케일별로 주입한다). */
export type DraftErrorMessages =
  (typeof import("@/lib/i18n/messages/new-app"))["ko"]["errors"];

/** 서버 cleanDockerfile 규칙: 저장소 안의 상대 경로여야 하고 파일명은 Dockerfile로 시작한다. */
function isSafeDockerfilePath(value: string): boolean {
  if (!value || value.length > 200) return false;
  if (value.startsWith("/") || value.includes("\\")) return false;
  const segments = value.split("/");
  if (segments.some((part) => part === "" || part === "." || part === "..")) {
    return false;
  }
  return segments[segments.length - 1].startsWith("Dockerfile");
}

/** 서버 parseRequestURI + 스킴/자격증명/질의 검사와 같은 판단. */
function isSafeHttpsRepository(value: string): boolean {
  if (value.length > 300) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  return (
    parsed.protocol === "https:" &&
    parsed.host !== "" &&
    parsed.username === "" &&
    parsed.password === "" &&
    parsed.search === "" &&
    parsed.hash === ""
  );
}

/** 스텝별 필수 입력 검증. 통과하면 빈 객체. */
export function validateStep(
  step: number,
  draft: NewAppDraft,
  msg: DraftErrorMessages,
  options: WizardOptions,
): DraftErrors {
  const errors: DraftErrors = {};

  // 마지막 검토 URL로 직접 들어오거나 이전 단계 뒤 새로고침을 해도 전체 초안을 다시
  // 검증한다. Step 5가 빈 검증 단계면 필수 입력과 Secret 재입력을 우회할 수 있다.
  const finalReview = step === WIZARD_LAST_STEP;

  if (step === 1 || finalReview) {
    const name = draft.name.trim();
    if (!name) {
      errors.name = msg.nameRequired;
    } else if (name.length > 40 || !APP_NAME_PATTERN.test(name)) {
      errors.name = msg.namePattern;
    }
    if (!draft.project) {
      errors.project = msg.projectRequired;
    } else if (
      options.projects.length > 0 &&
      !options.projects.includes(draft.project)
    ) {
      errors.project = msg.projectNotAllowed.replace(
        "{allowed}",
        options.projects.join(", "),
      );
    }
  }

  if (step === 2 || finalReview) {
    const repository = draft.repositoryUrl.trim();
    if (!repository) {
      errors.repositoryUrl = msg.repositoryUrlRequired;
    } else if (!isSafeHttpsRepository(repository)) {
      errors.repositoryUrl = msg.repositoryUrlPattern.replace(
        "{https}",
        GIT_REPO_PLACEHOLDER,
      );
    }

    const branch = draft.branch.trim();
    if (!branch) {
      errors.branch = msg.branchRequired;
    } else if (
      !BRANCH_PATTERN.test(branch) ||
      branch.includes("..") ||
      branch.includes("//") ||
      branch.includes("@{")
    ) {
      errors.branch = msg.branchPattern;
    }

    const dockerfile = draft.dockerfilePath.trim();
    if (!dockerfile) {
      errors.dockerfilePath = msg.dockerfilePathRequired;
    } else if (!isSafeDockerfilePath(dockerfile)) {
      errors.dockerfilePath = msg.dockerfilePathPattern;
    }
  }

  if (step === 3 || finalReview) {
    if (!isPositiveInt(draft.port) || Number(draft.port) > 65535) {
      errors.port = msg.portRange;
    }

    const preset = options.presets.find((item) => item.id === draft.resourceSize);
    if (!preset) {
      errors.resourceSize = msg.resourceSizeRequired.replace(
        "{allowed}",
        options.presets.map((item) => item.id).join(", "),
      );
    }

    if (
      !isPositiveInt(draft.replicas) ||
      Number(draft.replicas) > options.maxReplicas
    ) {
      errors.replicas = msg.replicasRange.replace(
        "{max}",
        String(options.maxReplicas),
      );
    } else if (preset) {
      // 상한 초과는 서버가 최종 판단하지만, 여기서 미리 막아야 "UI는 통과했는데
      // 신청이 거부되는" 상황이 없다. 계산 규칙은 lib/quota.ts가 서버와 공유한다.
      const quota = checkUserQuota(
        preset.limitCpu,
        preset.limitMemory,
        draft.replicas,
        options.quota,
      );
      if (quota.cpuOver) {
        errors.replicas = msg.cpuQuotaExceeded
          .replace("{limit}", options.quota.cpu)
          .replace("{used}", quota.usedCpu);
      } else if (quota.memoryOver) {
        errors.replicas = msg.memoryQuotaExceeded
          .replace("{limit}", options.quota.memory)
          .replace("{used}", quota.usedMemory);
      }
    }
  }

  if (step === 4 || finalReview) {
    if (draft.exposureMode !== "external" && draft.exposureMode !== "internal") {
      errors.exposureMode = msg.exposureRequired;
    }
    // SecurityPolicy는 HTTPRoute를 대상으로 한다. 내부 전용 앱에는 붙일 대상이 없어
    // 서버가 422로 거부한다. 화면에서 먼저 막아 마지막 단계에서야 알게 되는 일을 없앤다.
    if (draft.authMode === "oidc" && draft.exposureMode !== "external") {
      errors.authMode = msg.authInternalNotAllowed;
    }
    if (!["blocked", "web", "custom"].includes(draft.egressMode)) {
      errors.egressMode = msg.egressRequired;
    }
    if (draft.egressMode === "custom") {
      if (draft.allowedCidrs.length === 0) {
        errors.allowedCidrs = msg.allowedCidrsRequired;
      } else {
        const invalid = draft.allowedCidrs.find(
          (item) => !isSafeAllowedCidr(item.cidr) || !isPortInRange(item.port),
        );
        if (invalid) errors.allowedCidrs = msg.allowedCidrsPattern;
      }
    }
  }

  if (finalReview) {
    const missingKeys = missingOpenBaoKeys(draft);
    if (missingKeys.length > 0) {
      errors.envVars = msg.openBaoValueRequired.replace(
        "{keys}",
        missingKeys.join(", "),
      );
    }
  }

  return errors;
}

function isPortInRange(value: string): boolean {
  return isPositiveInt(value) && Number(value) <= 65535;
}
