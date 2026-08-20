"use client";

import * as React from "react";
import Link from "next/link";
import {
  Cpu,
  ExternalLink,
  FileCode2,
  GitBranch,
  Globe,
  Link2,
  ShieldCheck,
} from "lucide-react";

import { FormField } from "@/components/paas/form-field";
import { MonoKeyValueBox } from "@/components/paas/mono-kv-box";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useI18n } from "@/lib/i18n/context";
import { checkUserQuota } from "@/lib/quota";
import { GIT_REPO_PLACEHOLDER } from "@/lib/site-config";
import {
  missingOpenBaoKeys,
  type DraftErrors,
} from "@/lib/new-app-draft";
import type {
  DraftAllowedCidr,
  NewAppDraft,
  WizardOptions,
} from "@/types/domain";

/**
 * 스텝 본문 공통 props.
 *
 * `options`는 카탈로그(`GET /api/v1/catalog`)에서 온 값이다. 프로젝트·preset·
 * 쿼터·replicas 상한을 화면에서 하드코딩하지 않는 이유는 하나다 — 서버가
 * 허용하지 않는 값을 고를 수 있게 두면 사용자는 마지막 단계에서야 422를 본다.
 */
export interface StepBodyProps {
  draft: NewAppDraft;
  errors: DraftErrors;
  options: WizardOptions;
  update: <K extends keyof NewAppDraft>(key: K, value: NewAppDraft[K]) => void;
}

/** 스텝 안의 소제목 (아이콘 + 제목 + 하단 보더). */
function SubHeading({
  icon,
  children,
}: {
  icon: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <h3 className="flex items-center gap-2 border-b border-border pb-3 text-lg font-bold text-brand-900 [&_svg]:size-5">
      {icon}
      {children}
    </h3>
  );
}

/**
 * 앱 이름 + 기본 도메인으로 만드는 접속 주소.
 * 서버(app_profile.go)가 `<appName>.<baseDomain>`으로 만들기 때문에 미리보기도
 * 같은 규칙을 쓴다. 이름이 아직 비었으면 미리보기를 만들지 않는다.
 */
function previewHost(name: string, baseDomain: string): string {
  const trimmed = name.trim();
  if (!trimmed || !baseDomain) return "";
  return `${trimmed}.${baseDomain}`;
}

/* --------------------------- STEP 1 · 기본 정보 입력 --------------------------- */

export function StepBasics({ draft, errors, options, update }: StepBodyProps) {
  const { dict } = useI18n();
  const t = dict.newApp;

  return (
    <div className="space-y-6">
      <FormField
        id="app-name"
        label={t.appName}
        required
        error={errors.name}
        helper={t.appNameHelper}
      >
        <Input
          id="app-name"
          value={draft.name}
          onChange={(event) => update("name", event.target.value)}
          placeholder="my-service-app"
          maxLength={40}
          autoComplete="off"
          spellCheck={false}
          className="font-mono"
          aria-invalid={Boolean(errors.name)}
        />
      </FormField>

      <FormField
        id="app-project"
        label={t.project}
        required
        error={errors.project}
        helper={t.projectHelper}
      >
        <Select
          value={draft.project}
          onValueChange={(value) => update("project", value)}
        >
          <SelectTrigger id="app-project" className="w-full">
            <SelectValue placeholder={t.projectPlaceholder} />
          </SelectTrigger>
          <SelectContent>
            {options.projects.map((project) => (
              <SelectItem key={project} value={project}>
                {project}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FormField>

      {/* 환경은 서버가 정한다. 고를 수 있는 것처럼 보이면 안 되므로 읽기 전용이다. */}
      <FormField
        id="app-environment"
        label={t.environmentLabel}
        helper={t.environmentHelper}
      >
        <Input
          id="app-environment"
          value={options.environment}
          readOnly
          disabled
          className="font-mono"
        />
      </FormField>
    </div>
  );
}

/* ---------------------------- STEP 2 · 소스 정보 ---------------------------- */

export function StepSource({ draft, errors, update }: StepBodyProps) {
  const { dict } = useI18n();
  const t = dict.newApp;

  return (
    <div className="space-y-6">
      <SubHeading icon={<Link2 aria-hidden />}>{t.repositorySettings}</SubHeading>

      <FormField
        id="repository-url"
        label={t.repositoryUrl}
        required
        error={errors.repositoryUrl}
        helper={t.repositoryUrlHelper}
      >
        <Input
          id="repository-url"
          value={draft.repositoryUrl}
          onChange={(event) => update("repositoryUrl", event.target.value)}
          placeholder={GIT_REPO_PLACEHOLDER}
          autoComplete="off"
          spellCheck={false}
          inputMode="url"
          className="font-mono"
          aria-invalid={Boolean(errors.repositoryUrl)}
        />
      </FormField>

      <div className="grid gap-6 sm:grid-cols-2">
        <FormField
          id="repository-branch"
          label={t.branch}
          required
          error={errors.branch}
          helper={t.branchHelper}
        >
          <Input
            id="repository-branch"
            value={draft.branch}
            onChange={(event) => update("branch", event.target.value)}
            placeholder="main"
            autoComplete="off"
            spellCheck={false}
            className="font-mono"
            aria-invalid={Boolean(errors.branch)}
          />
        </FormField>

        <FormField
          id="dockerfile-path"
          label={t.dockerfilePath}
          required
          error={errors.dockerfilePath}
          helper={t.dockerfilePathHelper}
        >
          <Input
            id="dockerfile-path"
            value={draft.dockerfilePath}
            onChange={(event) => update("dockerfilePath", event.target.value)}
            placeholder="Dockerfile"
            autoComplete="off"
            spellCheck={false}
            className="font-mono"
            aria-invalid={Boolean(errors.dockerfilePath)}
          />
        </FormField>
      </div>
    </div>
  );
}

/* ---------------------------- STEP 3 · 실행 조건 ---------------------------- */

export function StepRuntime({ draft, errors, options, update }: StepBodyProps) {
  const { dict } = useI18n();
  const t = dict.newApp;

  const preset = options.presets.find((item) => item.id === draft.resourceSize);
  // 선택한 preset × replicas가 상한에서 얼마를 쓰는지 즉시 보여준다.
  // 계산 규칙은 서버(quota.go)와 같은 lib/quota.ts를 쓴다.
  const usage = preset
    ? checkUserQuota(
        preset.limitCpu,
        preset.limitMemory,
        draft.replicas,
        options.quota,
      )
    : null;

  return (
    <div className="space-y-6">
      <SubHeading icon={<Cpu aria-hidden />}>{t.runtimeSettings}</SubHeading>

      <div className="grid gap-6 sm:grid-cols-2">
        <FormField
          id="container-port"
          label={t.containerPort}
          required
          error={errors.port}
          helper={t.containerPortHelper}
        >
          <Input
            id="container-port"
            value={draft.port}
            onChange={(event) => update("port", event.target.value)}
            inputMode="numeric"
            placeholder="8080"
            autoComplete="off"
            className="font-mono"
            aria-invalid={Boolean(errors.port)}
          />
        </FormField>

        <FormField
          id="app-replicas"
          label={t.replicas}
          required
          error={errors.replicas}
          helper={t.replicasHelper.replace("{max}", String(options.maxReplicas))}
        >
          <Input
            id="app-replicas"
            value={draft.replicas}
            onChange={(event) => update("replicas", event.target.value)}
            inputMode="numeric"
            placeholder="1"
            autoComplete="off"
            className="font-mono"
            aria-invalid={Boolean(errors.replicas)}
          />
        </FormField>
      </div>

      <FormField
        id="resource-size"
        label={t.resourceSize}
        required
        error={errors.resourceSize}
        helper={t.resourceSizeHelper}
      >
        <Select
          value={draft.resourceSize}
          onValueChange={(value) => update("resourceSize", value)}
        >
          <SelectTrigger id="resource-size" className="w-full">
            <SelectValue placeholder={t.resourceSize} />
          </SelectTrigger>
          <SelectContent>
            {options.presets.map((item) => (
              <SelectItem key={item.id} value={item.id}>
                <span className="font-mono">{item.id}</span>
                <span className="ml-2 text-muted-foreground">
                  {t.resourceSizeOption
                    .replace("{requestCpu}", item.requestCpu)
                    .replace("{requestMemory}", item.requestMemory)
                    .replace("{limitCpu}", item.limitCpu)
                    .replace("{limitMemory}", item.limitMemory)}
                </span>
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FormField>

      <MonoKeyValueBox
        variant="inline"
        tone="muted"
        rows={[
          {
            label: t.quotaHint
              .replace("{cpu}", options.quota.cpu)
              .replace("{memory}", options.quota.memory),
            value:
              usage && usage.usedCpu && usage.usedMemory
                ? t.quotaUsagePreview
                    .replace("{cpu}", usage.usedCpu)
                    .replace("{memory}", usage.usedMemory)
                : "-",
          },
        ]}
      />
    </div>
  );
}

/* ------------------------- STEP 4 · 접근 방식과 외부 통신 ------------------------- */

/**
 * 라디오 카드 한 묶음.
 *
 * 노출·인증·외부 통신은 서로 독립된 설정이라 같은 모양으로 나란히 보여 준다.
 * 하나로 합친 목록("Public / OIDC")은 "외부에 열되 로그인은 없다"와 "내부 전용"을
 * 구분하지 못해서 나눴다.
 */
function RadioCardGroup<T extends string>({
  name,
  legend,
  value,
  options,
  error,
  onChange,
}: {
  name: string;
  legend: string;
  value: T;
  options: { value: T; title: string; description: string }[];
  error?: string;
  onChange: (next: T) => void;
}) {
  return (
    <fieldset className="space-y-3">
      <legend className="mb-2 text-sm font-semibold text-foreground">{legend}</legend>
      {options.map((option) => (
        <Label
          key={option.value}
          htmlFor={`${name}-${option.value}`}
          className="flex cursor-pointer items-start gap-3 rounded-md border border-border p-4 transition-colors hover:bg-secondary/60 has-[:checked]:border-brand-900 has-[:checked]:bg-secondary"
        >
          <input
            id={`${name}-${option.value}`}
            type="radio"
            name={name}
            value={option.value}
            checked={value === option.value}
            onChange={() => onChange(option.value)}
            className="mt-1 size-4 accent-brand-900"
          />
          <span className="space-y-1">
            <span className="block text-sm font-semibold text-foreground">
              {option.title}
            </span>
            <span className="block text-sm text-muted-foreground">
              {option.description}
            </span>
          </span>
        </Label>
      ))}
      {error ? <p className="text-sm text-status-error-strong">{error}</p> : null}
    </fieldset>
  );
}

export function StepAccess({ draft, errors, options, update }: StepBodyProps) {
  const { dict } = useI18n();
  const t = dict.newApp;
  const external = draft.exposureMode === "external";
  const host = external ? previewHost(draft.name, options.baseDomain) : "";

  function updateCidr(index: number, patch: Partial<DraftAllowedCidr>) {
    update(
      "allowedCidrs",
      draft.allowedCidrs.map((item, position) =>
        position === index ? { ...item, ...patch } : item,
      ),
    );
  }

  return (
    <div className="space-y-8">
      <SubHeading icon={<ShieldCheck aria-hidden />}>{t.accessSettings}</SubHeading>

      <RadioCardGroup
        name="exposure-mode"
        legend={t.exposureLegend}
        value={draft.exposureMode}
        error={errors.exposureMode}
        onChange={(next) => {
          update("exposureMode", next);
          // 내부 전용으로 바꾸면 SSO는 붙일 대상(HTTPRoute)이 없다. 값이 남아 있으면
          // 화면에는 "SSO 필요"인데 서버가 거부하는 상태가 된다.
          if (next === "internal") update("authMode", "none");
        }}
        options={[
          {
            value: "external",
            title: t.exposureExternal,
            description: t.exposureExternalDescription,
          },
          {
            value: "internal",
            title: t.exposureInternal,
            description: t.exposureInternalDescription,
          },
        ]}
      />

      {/* 인증은 외부 URL이 있을 때만 고를 수 있다. */}
      {external ? (
        <RadioCardGroup
          name="auth-mode"
          legend={t.authLegend}
          value={draft.authMode}
          error={errors.authMode}
          onChange={(next) => update("authMode", next)}
          options={[
            { value: "none", title: t.authNone, description: t.authNoneDescription },
            { value: "oidc", title: t.authOidc, description: t.authOidcDescription },
          ]}
        />
      ) : null}

      <div className="space-y-3">
        <RadioCardGroup
          name="egress-mode"
          legend={t.egressLegend}
          value={draft.egressMode}
          error={errors.egressMode}
          onChange={(next) => {
            update("egressMode", next);
            if (next !== "custom") update("allowedCidrs", []);
            if (next === "custom" && draft.allowedCidrs.length === 0) {
              update("allowedCidrs", [{ cidr: "", port: "", protocol: "TCP" }]);
            }
          }}
          options={[
            {
              value: "blocked",
              title: t.egressBlocked,
              description: t.egressBlockedDescription,
            },
            { value: "web", title: t.egressWeb, description: t.egressWebDescription },
            {
              value: "custom",
              title: t.egressCustom,
              description: t.egressCustomDescription,
            },
          ]}
        />
        {/*
          "웹 통신만 허용"을 도메인 허용으로 오해하지 않게 못 박는다. 기본
          NetworkPolicy 는 FQDN 을 볼 수 없고 포트만 본다.
        */}
        {draft.egressMode === "web" ? (
          <p className="rounded-md border border-border bg-secondary/60 p-3 text-sm text-muted-foreground">
            {t.egressWebNotice}
          </p>
        ) : null}
      </div>

      {draft.egressMode === "custom" ? (
        <fieldset className="space-y-3">
          <legend className="mb-2 text-sm font-semibold text-foreground">
            {t.allowedCidrsLegend}
          </legend>
          <p className="text-sm text-muted-foreground">{t.allowedCidrsHelper}</p>
          {draft.allowedCidrs.map((item, index) => (
            <div
              key={index}
              className="grid grid-cols-1 gap-3 rounded-md border border-border p-3 sm:grid-cols-[2fr_1fr_1fr_auto]"
            >
              <Input
                aria-label={t.allowedCidrsCidr}
                value={item.cidr}
                onChange={(event) => updateCidr(index, { cidr: event.target.value })}
                placeholder="203.0.113.10/32"
                className="font-mono"
                spellCheck={false}
              />
              <Input
                aria-label={t.allowedCidrsPort}
                value={item.port}
                onChange={(event) => updateCidr(index, { port: event.target.value })}
                placeholder="443"
                inputMode="numeric"
                className="font-mono"
              />
              <Select
                value={item.protocol}
                onValueChange={(next) =>
                  updateCidr(index, { protocol: next as DraftAllowedCidr["protocol"] })
                }
              >
                <SelectTrigger aria-label={t.allowedCidrsProtocol}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="TCP">TCP</SelectItem>
                  <SelectItem value="UDP">UDP</SelectItem>
                </SelectContent>
              </Select>
              <button
                type="button"
                className="rounded-md border border-border px-3 py-2 text-sm text-muted-foreground hover:bg-secondary"
                onClick={() =>
                  update(
                    "allowedCidrs",
                    draft.allowedCidrs.filter((_, position) => position !== index),
                  )
                }
              >
                {t.allowedCidrsRemove}
              </button>
            </div>
          ))}
          <button
            type="button"
            className="rounded-md border border-border px-3 py-2 text-sm font-semibold text-brand-900 hover:bg-secondary"
            onClick={() =>
              update("allowedCidrs", [
                ...draft.allowedCidrs,
                { cidr: "", port: "", protocol: "TCP" as const },
              ])
            }
          >
            {t.allowedCidrsAdd}
          </button>
          {errors.allowedCidrs ? (
            <p className="text-sm text-status-error-strong">{errors.allowedCidrs}</p>
          ) : null}
        </fieldset>
      ) : null}

      <FormField
        id="host-preview"
        label={t.hostPreview}
        helper={external ? t.hostPreviewHelper : t.hostPreviewInternal}
      >
        <Input
          id="host-preview"
          value={host ? `https://${host}` : ""}
          readOnly
          disabled
          className="font-mono"
        />
      </FormField>
    </div>
  );
}

/* ------------------------------ STEP 5 · 검토 ------------------------------ */

export function StepReview({ draft, errors, options }: StepBodyProps) {
  const { dict } = useI18n();
  const t = dict.newApp;

  const preset = options.presets.find((item) => item.id === draft.resourceSize);
  const host = previewHost(draft.name, options.baseDomain);
  const missingSecretKeys = missingOpenBaoKeys(draft);

  return (
    <div className="space-y-6">
      <SubHeading icon={<Globe aria-hidden />}>{t.reviewHeading}</SubHeading>

      <section className="space-y-3">
        <h4 className="flex items-center gap-2 text-sm font-bold text-brand-900 [&_svg]:size-4">
          <FileCode2 aria-hidden />
          {t.reviewBasics}
        </h4>
        <MonoKeyValueBox
          rows={[
            { label: t.appName, value: draft.name || "-" },
            { label: t.reviewProject, value: draft.project || "-" },
            { label: t.reviewEnvironment, value: options.environment || "-" },
          ]}
        />
      </section>

      <section className="space-y-3">
        <h4 className="flex items-center gap-2 text-sm font-bold text-brand-900 [&_svg]:size-4">
          <GitBranch aria-hidden />
          {t.reviewSourceRuntime}
        </h4>
        <MonoKeyValueBox
          rows={[
            { label: t.reviewRepository, value: draft.repositoryUrl || "-" },
            { label: t.reviewBranch, value: draft.branch || "-" },
            { label: t.reviewDockerfile, value: draft.dockerfilePath || "-" },
            { label: t.reviewPort, value: draft.port || "-" },
            {
              label: t.reviewResource,
              value: preset
                ? `${preset.id} · ${t.resourceSizeOption
                    .replace("{requestCpu}", preset.requestCpu)
                    .replace("{requestMemory}", preset.requestMemory)
                    .replace("{limitCpu}", preset.limitCpu)
                    .replace("{limitMemory}", preset.limitMemory)}`
                : draft.resourceSize || "-",
            },
            { label: t.reviewReplicas, value: draft.replicas || "-" },
          ]}
        />
      </section>

      <section className="space-y-3">
        <h4 className="flex items-center gap-2 text-sm font-bold text-brand-900 [&_svg]:size-4">
          <ShieldCheck aria-hidden />
          {t.reviewAccess}
        </h4>
        {/* 노출·인증·외부 통신을 각각 보여 준다. 하나로 뭉치면 무엇이 열려 있는지 알 수 없다. */}
        <MonoKeyValueBox
          rows={[
            {
              label: t.reviewExposure,
              value:
                draft.exposureMode === "internal"
                  ? t.exposureInternal
                  : t.exposureExternal,
            },
            {
              label: t.reviewAuth,
              value:
                draft.exposureMode === "external" && draft.authMode === "oidc"
                  ? t.authOidc
                  : t.authNone,
            },
            {
              label: t.reviewEgress,
              value:
                draft.egressMode === "web"
                  ? t.egressWeb
                  : draft.egressMode === "custom"
                    ? t.egressCustom
                    : t.egressBlocked,
            },
            ...(draft.egressMode === "custom"
              ? [
                  {
                    label: t.reviewAllowedCidrs,
                    value:
                      draft.allowedCidrs
                        .map((item) => `${item.cidr} · ${item.protocol}/${item.port}`)
                        .join(", ") || "-",
                  },
                ]
              : []),
            {
              label: t.reviewHost,
              value: draft.exposureMode === "internal" ? "-" : host ? `https://${host}` : "-",
            },
          ]}
        />
      </section>

      {/*
        구성 분류기에서 넘어온 값이 실제로 신청에 실리는지 여기서 보이지 않으면,
        분류만 해 두고 반영됐다고 믿은 채 제출하게 된다.
      */}
      <section className="space-y-3">
        <h4 className="flex items-center gap-2 text-sm font-bold text-brand-900 [&_svg]:size-4">
          <FileCode2 aria-hidden />
          {t.reviewEnvHeading}
        </h4>
        {draft.envVars.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t.reviewEnvEmpty}</p>
        ) : (
          <>
            <MonoKeyValueBox
              rows={[
                {
                  label: t.reviewEnvConfigMap,
                  value:
                    draft.envVars
                      .filter((item) => item.classification === "configmap")
                      .map((item) => item.key)
                      .join(", ") || "-",
                },
                {
                  label: t.reviewEnvOpenBao,
                  value:
                    draft.envVars
                      .filter((item) => item.classification === "openbao")
                      .map((item) => item.key)
                      .join(", ") || "-",
                },
              ]}
            />
            {draft.envVars.some((item) => item.classification === "openbao") ? (
              <div className="space-y-3">
                <p className="text-sm text-muted-foreground">
                  {t.reviewEnvSecretNotice}
                </p>
                {/*
                  포털이 저장할 경로와 이후 OpenBao에서 관리할 경로가 같아야 한다.
                  Chart 의 assertRemotePath 가 이 형식 하나만 허용하므로 그대로 보여 준다.
                  주소는 카탈로그에서 온 baseDomain 으로 만든다. 빌드 시점 기본값에
                  기대면 .env 를 빠뜨린 배포에서 남의 도메인을 가리킨다.
                */}
                <MonoKeyValueBox
                  rows={[
                    {
                      label: t.reviewEnvOpenBaoPath,
                      value: `kv/apps/${draft.project || "-"}/${
                        options.environment || "-"
                      }/${draft.name || "-"}`,
                    },
                  ]}
                />
                {options.baseDomain ? (
                  <a
                    className="inline-flex items-center gap-1 text-sm font-semibold text-brand-accent underline underline-offset-4"
                    href={`https://openbao.${options.baseDomain}`}
                    target="_blank"
                    rel="noreferrer noopener"
                  >
                    {t.reviewEnvOpenBaoLink}
                    <ExternalLink className="size-4" aria-hidden />
                  </a>
                ) : null}
              </div>
            ) : null}
          </>
        )}
        {missingSecretKeys.length > 0 ? (
          <div
            role="alert"
            className="space-y-2 rounded-md border border-status-warn-border bg-status-warn-soft p-4 text-sm text-status-warn-strong"
          >
            <p>
              {errors.envVars ??
                t.reviewEnvReentry.replace("{keys}", missingSecretKeys.join(", "))}
            </p>
            <Link
              href="/deployments/env-classifier"
              className="inline-flex font-semibold underline underline-offset-4"
            >
              {t.reviewEnvReentryLink}
            </Link>
          </div>
        ) : null}
      </section>

      <p className="rounded-md border border-border bg-secondary/60 p-4 text-sm text-muted-foreground">
        {t.reviewNotice}
      </p>
    </div>
  );
}
