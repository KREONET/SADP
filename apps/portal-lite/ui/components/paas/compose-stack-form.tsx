"use client";

import * as React from "react";
import { Boxes, Link2, Loader2, ShieldCheck } from "lucide-react";

import {
  submitComposeStack,
  validateComposeStack,
  type ComposeFormInput,
} from "@/app/(paas)/new-app/compose/actions";
import { FormField } from "@/components/paas/form-field";
import { MonoKeyValueBox } from "@/components/paas/mono-kv-box";
import { PageHeader } from "@/components/paas/page-header";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import {
  composeFormSnapshot,
  reconcileComposeServices,
} from "@/lib/compose-stack-draft";
import { useI18n } from "@/lib/i18n/context";
import type {
  ComposePlan,
  ComposeServiceDraft,
  DraftAllowedCidr,
  EgressMode,
  ExposureMode,
  WizardOptions,
} from "@/types/domain";

/**
 * 다중 앱(Git Compose/Helm 또는 Compose 직접 입력) 신청 화면.
 *
 * Compose 는 입력 형식으로만 쓴다. 여기서 하는 일은 두 가지다.
 *  1. 서버에 Compose 를 보내 서비스 목록을 받아 온다(파싱과 검증은 전부 서버가 한다).
 *  2. 서비스마다 Compose 에 없는 개념 — 외부 노출, 인증, 외부 통신, 앱 사이 연결 — 을 고른다.
 *
 * 화면이 Compose 를 직접 해석하지 않는 이유는, 화면과 서버가 다르게 읽으면
 * "보이는 것과 배포되는 것"이 갈라지기 때문이다.
 */
export function ComposeStackForm({ options }: { options: WizardOptions }) {
  const { dict } = useI18n();
  const t = dict.compose;

  const [group, setGroup] = React.useState("");
  const [project, setProject] = React.useState(options.projects[0] ?? "");
  const [sourceMode, setSourceMode] = React.useState<"git" | "compose">("git");
  const [repository, setRepository] = React.useState("");
  const [repositoryRevision, setRepositoryRevision] = React.useState("");
  const [compose, setCompose] = React.useState("");
  const [resourceSize, setResourceSize] = React.useState(
    options.presets[0]?.id ?? "",
  );
  const [services, setServices] = React.useState<ComposeServiceDraft[]>([]);
  const [plan, setPlan] = React.useState<ComposePlan | null>(null);
  const [message, setMessage] = React.useState<{
    tone: "error" | "ok";
    text: string;
  } | null>(null);
  const [fieldErrors, setFieldErrors] = React.useState<Record<string, string>>({});
  const [pending, setPending] = React.useState(false);
  const [validatedSnapshot, setValidatedSnapshot] = React.useState<string | null>(
    null,
  );
  const [submitted, setSubmitted] = React.useState(false);
  const idempotency = React.useRef<{ snapshot: string; key: string } | null>(null);

  const namespacePreview =
    group.trim() && options.appGroups.namespacePrefix
      ? `${options.appGroups.namespacePrefix}${group.trim()}`
      : "";

  function form(): ComposeFormInput {
    return {
      group,
      project,
      sourceMode,
      repository,
      repositoryRevision,
      compose,
      resourceSize,
      services,
    };
  }

  const currentSnapshot = composeFormSnapshot(form());
  const planIsCurrent =
    plan !== null && validatedSnapshot !== null && validatedSnapshot === currentSnapshot;

  function updateService(name: string, patch: Partial<ComposeServiceDraft>) {
    setServices((previous) =>
      previous.map((item) => (item.name === name ? { ...item, ...patch } : item)),
    );
  }

  async function onValidate() {
    if (submitted) return;
    setPending(true);
    setMessage(null);
    setFieldErrors({});
    setValidatedSnapshot(null);
    // 재검증을 누른 시점의 기본 브랜치를 새로 읽고, 그 결과 commit을 두 번째 검증과
    // 실제 제출에 고정한다. 검증 뒤 branch가 움직여도 보지 않은 Chart가 배포되지 않는다.
    const candidate = {
      ...form(),
      ...(sourceMode === "git" ? { repositoryRevision: "" } : {}),
    };
    try {
      // 먼저 override 없이 Compose의 현재 서비스 목록을 구한다. 이전 검증의 서비스가
      // 남은 채 Compose에서 삭제되었어도 "없는 서비스" 오류에 갇히지 않게 한다.
      const discovery = await validateComposeStack({ ...candidate, services: [] });
      if (!discovery.ok) {
        setPlan(null);
        setFieldErrors(discovery.fieldErrors);
        setMessage({ tone: "error", text: discovery.reason });
        return;
      }
      const nextServices = reconcileComposeServices(services, discovery.plan);
      const normalized = {
        ...candidate,
        repositoryRevision:
          candidate.sourceMode === "git"
            ? (discovery.plan.source.revision ?? "")
            : "",
        services: nextServices,
      };
      setServices(nextServices);
      setRepositoryRevision(normalized.repositoryRevision);
      // 두 번째 검증은 서비스별 정책까지 포함한다. 파싱만 성공한 상태를 제출 가능한
      // 계획으로 착각하지 않도록 이 결과가 성공해야 snapshot을 승인한다.
      const result = await validateComposeStack(normalized);
      if (!result.ok) {
        setPlan(discovery.plan);
        setFieldErrors(result.fieldErrors);
        setMessage({ tone: "error", text: result.reason });
        return;
      }
      setPlan(result.plan);
      setValidatedSnapshot(composeFormSnapshot(normalized));
      setMessage({
        tone: "ok",
        text: t.validateOk.replace("{count}", String(result.plan.services.length)),
      });
    } catch {
      setPlan(null);
      setMessage({ tone: "error", text: t.validateFailed });
    } finally {
      setPending(false);
    }
  }

  async function onSubmit() {
    if (submitted || !planIsCurrent) {
      if (!submitted) setMessage({ tone: "error", text: t.validationDirty });
      return;
    }
    setPending(true);
    setMessage(null);
    setFieldErrors({});
    try {
      const candidate = form();
      const snapshot = composeFormSnapshot(candidate);
      if (!idempotency.current || idempotency.current.snapshot !== snapshot) {
        idempotency.current = { snapshot, key: crypto.randomUUID() };
      }
      const result = await submitComposeStack(candidate, idempotency.current.key);
      if (!result.ok) {
        setFieldErrors(result.fieldErrors);
        setMessage({ tone: "error", text: result.reason });
        return;
      }
      setSubmitted(true);
      setMessage({
        tone: "ok",
        text: t.submitOk
          .replace("{count}", String(result.count))
          .replace("{namespace}", result.namespace),
      });
    } catch {
      setMessage({ tone: "error", text: t.submitFailed });
    } finally {
      setPending(false);
    }
  }

  const otherServices = (name: string) =>
    services.filter((item) => item.name !== name && item.serviceEnabled);

  return (
    <div className="mx-auto w-full max-w-[1200px] space-y-6 px-4 py-8">
      <PageHeader title={t.headerTitle} description={t.headerDescription} />

      {message ? (
        <p
          role={message.tone === "error" ? "alert" : "status"}
          className={
            message.tone === "error"
              ? "rounded-md border border-status-error bg-status-error-soft p-4 text-sm text-status-error-strong"
              : "rounded-md border border-status-ok bg-status-ok-soft p-4 text-sm text-status-ok-strong"
          }
        >
          {message.text}
        </p>
      ) : null}

      {Object.keys(fieldErrors).length > 0 ? (
        <section
          role="alert"
          aria-labelledby="compose-error-summary"
          className="space-y-2 rounded-md border border-status-error bg-status-error-soft p-4 text-sm text-status-error-strong"
        >
          <h2 id="compose-error-summary" className="font-semibold">
            {t.fieldErrorsHeading}
          </h2>
          <ul className="list-disc space-y-1 pl-5">
            {Object.entries(fieldErrors).map(([field, error]) => (
              <li key={field}>
                <span className="font-mono">{field}</span>: {error}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <Card>
        <CardContent className="space-y-6 pt-6">
          <h3 className="flex items-center gap-2 border-b border-border pb-3 text-lg font-bold text-brand-900 [&_svg]:size-5">
            <Boxes aria-hidden />
            {t.groupHeading}
          </h3>

          <FormField
            id="group-name"
            label={t.groupName}
            required
            error={fieldErrors.group}
            helper={
              namespacePreview
                ? t.groupNameHelper.replace("{namespace}", namespacePreview)
                : t.groupNameHelperEmpty
            }
          >
            <Input
              id="group-name"
              value={group}
              onChange={(event) => setGroup(event.target.value)}
              placeholder="mobility-platform"
              maxLength={40}
              className="font-mono"
              spellCheck={false}
            />
          </FormField>

          <FormField id="group-project" label={t.project} required error={fieldErrors.project}>
            <Select value={project} onValueChange={setProject}>
              <SelectTrigger id="group-project" className="w-full">
                <SelectValue placeholder={t.projectPlaceholder} />
              </SelectTrigger>
              <SelectContent>
                {options.projects.map((item) => (
                  <SelectItem key={item} value={item}>
                    {item}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </FormField>

          <fieldset className="space-y-3">
            <legend className="text-sm font-medium text-foreground">{t.sourceMode}</legend>
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                variant={sourceMode === "git" ? "default" : "outline"}
                aria-pressed={sourceMode === "git"}
                onClick={() => setSourceMode("git")}
                disabled={submitted}
              >
                {t.sourceGit}
              </Button>
              <Button
                type="button"
                variant={sourceMode === "compose" ? "default" : "outline"}
                aria-pressed={sourceMode === "compose"}
                onClick={() => {
                  setSourceMode("compose");
                  setRepositoryRevision("");
                }}
                disabled={submitted}
              >
                {t.sourceDirect}
              </Button>
            </div>
          </fieldset>

          {sourceMode === "git" ? (
            <FormField
              id="source-repository"
              label={t.repository}
              required
              error={fieldErrors.repository}
              helper={t.repositoryHelper.replace(
                "{max}",
                String(options.appGroups.maxServices),
              )}
            >
              <Input
                id="source-repository"
                type="url"
                value={repository}
                onChange={(event) => {
                  setRepository(event.target.value);
                  setRepositoryRevision("");
                }}
                className="font-mono"
                spellCheck={false}
                placeholder={t.repositoryPlaceholder}
              />
            </FormField>
          ) : (
            <FormField
              id="compose-document"
              label={t.composeDocument}
              required
              error={fieldErrors.compose ?? fieldErrors["compose.services"]}
              helper={t.composeDocumentHelper.replace(
                "{max}",
                String(options.appGroups.maxServices),
              )}
            >
              <Textarea
                id="compose-document"
                value={compose}
                onChange={(event) => setCompose(event.target.value)}
                rows={14}
                className="font-mono text-sm"
                spellCheck={false}
                placeholder={"services:\n  api:\n    image: registry.example/api:1.2.3\n    expose:\n      - 8080"}
              />
            </FormField>
          )}

          <FormField
            id="group-resource"
            label={t.resourceSize}
            required
            error={fieldErrors.resourceSize}
            helper={t.resourceSizeHelper}
          >
            <Select value={resourceSize} onValueChange={setResourceSize}>
              <SelectTrigger id="group-resource" className="w-full">
                <SelectValue placeholder={t.resourceSizePlaceholder} />
              </SelectTrigger>
              <SelectContent>
                {options.presets.map((item) => (
                  <SelectItem key={item.id} value={item.id}>
                    {item.id}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </FormField>

          <Button type="button" onClick={onValidate} disabled={pending || submitted}>
            {pending ? <Loader2 className="size-4 animate-spin" aria-hidden /> : null}
            {t.validate}
          </Button>
        </CardContent>
      </Card>

      {plan && planIsCurrent && plan.warnings.length > 0 ? (
        <Card>
          <CardContent className="space-y-2 pt-6">
            <h3 className="text-sm font-bold text-brand-900">{t.warningsHeading}</h3>
            <ul className="list-disc space-y-1 pl-5 text-sm text-muted-foreground">
              {plan.warnings.map((warning) => (
                <li key={warning}>{warning}</li>
              ))}
            </ul>
          </CardContent>
        </Card>
      ) : null}

      {plan && !planIsCurrent && !submitted ? (
        <p
          role="status"
          className="rounded-md border border-status-warn bg-status-warn-soft p-4 text-sm text-status-warn-strong"
        >
          {t.validationDirty}
        </p>
      ) : null}

      {services.map((service) => {
        const planned = planIsCurrent
          ? plan.services.find((item) => item.name === service.name)
          : undefined;
        return (
          <Card key={service.name}>
            <CardContent className="space-y-6 pt-6">
              <h3 className="flex items-center gap-2 border-b border-border pb-3 text-lg font-bold text-brand-900 [&_svg]:size-5">
                <ShieldCheck aria-hidden />
                <span className="font-mono">{service.name}</span>
              </h3>

              <MonoKeyValueBox
                variant="inline"
                tone="muted"
                rows={[
                  {
                    label: t.servicePort,
                    value: service.serviceEnabled ? String(service.port) : t.serviceWorker,
                  },
                  {
                    label: t.serviceSource,
                    value: service.image ?? "-",
                  },
                  ...(service.serviceEnabled
                    ? [{ label: t.serviceDns, value: `${service.name}:${service.port}` }]
                    : []),
                  ...(service.persistenceMountPath
                    ? [
                        {
                          label: t.serviceStorage,
                          value: `${service.persistenceMountPath} (${t.serviceStorageRwo})`,
                        },
                      ]
                    : []),
                ]}
              />

              <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
                <FormField
                  id={`${service.name}-exposure`}
                  label={t.exposureLegend}
                  error={fieldErrors[`services.${service.name}.exposure`]}
                >
                  <Select
                    value={service.exposureMode}
                    onValueChange={(next) =>
                      updateService(service.name, {
                        exposureMode: next as ExposureMode,
                        // 내부 전용으로 바꾸면 SSO 는 붙일 대상이 없다.
                        ...(next === "internal" ? { authMode: "none" as const } : {}),
                      })
                    }
                    disabled={!service.serviceEnabled}
                  >
                    <SelectTrigger id={`${service.name}-exposure`}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="external">{t.exposureExternal}</SelectItem>
                      <SelectItem value="internal">{t.exposureInternal}</SelectItem>
                    </SelectContent>
                  </Select>
                </FormField>

                <FormField
                  id={`${service.name}-auth`}
                  label={t.authLegend}
                  error={fieldErrors[`services.${service.name}.authentication`]}
                  helper={
                    !service.serviceEnabled
                      ? t.workerInternalNote
                      : service.exposureMode === "internal"
                        ? t.authInternalNote
                        : undefined
                  }
                >
                  <Select
                    value={service.authMode}
                    onValueChange={(next) =>
                      updateService(service.name, { authMode: next as "none" | "oidc" })
                    }
                    disabled={
                      !service.serviceEnabled || service.exposureMode === "internal"
                    }
                  >
                    <SelectTrigger id={`${service.name}-auth`}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="none">{t.authNone}</SelectItem>
                      <SelectItem value="oidc">{t.authOidc}</SelectItem>
                    </SelectContent>
                  </Select>
                </FormField>

                <FormField
                  id={`${service.name}-egress`}
                  label={t.egressLegend}
                  error={fieldErrors[`services.${service.name}.networkPolicy.egressMode`]}
                  helper={service.egressMode === "web" ? t.egressWebNotice : undefined}
                >
                  <Select
                    value={service.egressMode}
                    onValueChange={(next) => {
                      const mode = next as EgressMode;
                      updateService(service.name, {
                        egressMode: mode,
                        ...(mode === "custom" && service.allowedCidrs.length === 0
                          ? {
                              allowedCidrs: [
                                { cidr: "", port: "", protocol: "TCP" as const },
                              ],
                            }
                          : {}),
                      });
                    }}
                  >
                    <SelectTrigger id={`${service.name}-egress`}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="blocked">{t.egressBlocked}</SelectItem>
                      <SelectItem value="web">{t.egressWeb}</SelectItem>
                      <SelectItem value="custom">{t.egressCustom}</SelectItem>
                    </SelectContent>
                  </Select>
                </FormField>
              </div>

              {service.egressMode === "custom" ? (
                <CidrPicker
                  idPrefix={`${service.name}-cidr`}
                  legend={t.allowedCidrsLegend}
                  helper={t.allowedCidrsHelper}
                  addLabel={t.cidrAdd}
                  removeLabel={t.cidrRemove}
                  cidrLabel={t.cidrAddress}
                  portLabel={t.peerPort}
                  protocolLabel={t.cidrProtocol}
                  rows={service.allowedCidrs}
                  error={firstFieldError(
                    fieldErrors,
                    `services.${service.name}.networkPolicy.allowedCIDRs`,
                  )}
                  onChange={(next) =>
                    updateService(service.name, { allowedCidrs: next })
                  }
                />
              ) : null}

              {planned?.host ? (
                <MonoKeyValueBox
                  variant="inline"
                  rows={[{ label: t.serviceHost, value: `https://${planned.host}` }]}
                />
              ) : null}

              <SecretKeyPicker
                idPrefix={`${service.name}-secret-key`}
                legend={t.secretKeysLegend}
                helper={t.secretKeysHelper}
                keyLabel={t.secretKeyName}
                addLabel={t.secretKeyAdd}
                removeLabel={t.secretKeyRemove}
                keys={service.secretKeys}
                error={firstFieldError(
                  fieldErrors,
                  `services.${service.name}.secretKeys`,
                )}
                onChange={(next) =>
                  updateService(service.name, { secretKeys: next })
                }
              />

              {/* 같은 그룹의 다른 앱과의 연결. 이름을 고르게 해서 raw label 을 쓰지 않는다. */}
              <PeerPicker
                idPrefix={`${service.name}-egress-peer`}
                legend={t.allowedAppsLegend}
                helper={t.allowedAppsHelper}
                addLabel={t.peerAdd}
                removeLabel={t.peerRemove}
                portLabel={t.peerPort}
                appLabel={t.peerApp}
                candidates={otherServices(service.name)}
                portForApp={(app) =>
                  String(services.find((item) => item.name === app)?.port ?? "")
                }
                peers={service.allowedApps}
                error={firstFieldError(
                  fieldErrors,
                  `services.${service.name}.networkPolicy.allowedApps`,
                )}
                onChange={(next) => updateService(service.name, { allowedApps: next })}
              />
              {service.serviceEnabled ? (
              <PeerPicker
                idPrefix={`${service.name}-ingress-peer`}
                legend={t.ingressAppsLegend}
                helper={t.ingressAppsHelper}
                addLabel={t.peerAdd}
                removeLabel={t.peerRemove}
                portLabel={t.peerPort}
                appLabel={t.peerApp}
                candidates={otherServices(service.name)}
                // ingress 포트는 출발 앱의 포트가 아니라 현재(목적지) 앱의 Service 포트다.
                portForApp={() => String(service.port)}
                peers={service.ingressApps}
                error={firstFieldError(
                  fieldErrors,
                  `services.${service.name}.networkPolicy.ingress.allowedApps`,
                )}
                onChange={(next) => updateService(service.name, { ingressApps: next })}
              />
              ) : (
                <p className="rounded-md border border-border bg-secondary p-3 text-sm text-muted-foreground">
                  {t.workerIngressNote}
                </p>
              )}
            </CardContent>
          </Card>
        );
      })}

      {services.length > 0 ? (
        <div className="flex items-center justify-end gap-3">
          <Button
            type="button"
            variant="outline"
            onClick={onValidate}
            disabled={pending || submitted}
          >
            {t.revalidate}
          </Button>
          <Button
            type="button"
            onClick={onSubmit}
            disabled={
              pending || submitted || !planIsCurrent || !options.submissionEnabled
            }
          >
            {pending ? <Loader2 className="size-4 animate-spin" aria-hidden /> : null}
            {submitted ? t.submitted : t.submit}
          </Button>
        </div>
      ) : null}
    </div>
  );
}

/** OpenBao에 사전 생성된 Secret key의 이름만 받는다. 값 입력란은 의도적으로 없다. */
function SecretKeyPicker({
  idPrefix,
  legend,
  helper,
  keyLabel,
  addLabel,
  removeLabel,
  keys,
  error,
  onChange,
}: {
  idPrefix: string;
  legend: string;
  helper: string;
  keyLabel: string;
  addLabel: string;
  removeLabel: string;
  keys: string[];
  error?: string;
  onChange: (next: string[]) => void;
}) {
  return (
    <fieldset className="space-y-3">
      <legend className="text-sm font-semibold text-foreground">{legend}</legend>
      <p className="text-sm text-muted-foreground">{helper}</p>
      {keys.map((key, index) => (
        <div
          key={index}
          className="grid grid-cols-1 gap-3 rounded-md border border-border p-3 sm:grid-cols-[1fr_auto]"
        >
          <Input
            id={`${idPrefix}-${index}`}
            aria-label={keyLabel}
            value={key}
            onChange={(event) =>
              onChange(
                keys.map((item, position) =>
                  position === index ? event.target.value : item,
                ),
              )
            }
            placeholder="DATABASE_PASSWORD"
            autoComplete="off"
            className="font-mono"
            spellCheck={false}
          />
          <button
            type="button"
            className="rounded-md border border-border px-3 py-2 text-sm text-muted-foreground hover:bg-secondary"
            aria-label={`${removeLabel}: ${key || keyLabel}`}
            onClick={() => onChange(keys.filter((_, position) => position !== index))}
          >
            {removeLabel}
          </button>
        </div>
      ))}
      <button
        type="button"
        className="rounded-md border border-border px-3 py-2 text-sm font-semibold text-brand-900 hover:bg-secondary"
        onClick={() => onChange([...keys, ""])}
      >
        {addLabel}
      </button>
      {error ? <p className="text-sm text-status-error-strong">{error}</p> : null}
    </fieldset>
  );
}

/** 정확한 필드 키가 아니어도 배열 행 아래 오류를 가장 가까운 입력 묶음에 보여 준다. */
function firstFieldError(
  fieldErrors: Readonly<Record<string, string>>,
  prefix: string,
): string | undefined {
  return Object.entries(fieldErrors).find(
    ([field]) => field === prefix || field.startsWith(`${prefix}[`) || field.startsWith(`${prefix}.`),
  )?.[1];
}

/** custom 모드의 외부 CIDR 목적지 목록. raw NetworkPolicy YAML은 받지 않는다. */
function CidrPicker({
  idPrefix,
  legend,
  helper,
  addLabel,
  removeLabel,
  cidrLabel,
  portLabel,
  protocolLabel,
  rows,
  error,
  onChange,
}: {
  idPrefix: string;
  legend: string;
  helper: string;
  addLabel: string;
  removeLabel: string;
  cidrLabel: string;
  portLabel: string;
  protocolLabel: string;
  rows: DraftAllowedCidr[];
  error?: string;
  onChange: (next: DraftAllowedCidr[]) => void;
}) {
  function update(index: number, patch: Partial<DraftAllowedCidr>) {
    onChange(
      rows.map((item, position) =>
        position === index ? { ...item, ...patch } : item,
      ),
    );
  }

  return (
    <fieldset className="space-y-3">
      <legend className="text-sm font-semibold text-foreground">{legend}</legend>
      <p className="text-sm text-muted-foreground">{helper}</p>
      {rows.map((row, index) => (
        <div
          key={index}
          className="grid grid-cols-1 gap-3 rounded-md border border-border p-3 sm:grid-cols-[2fr_1fr_1fr_auto]"
        >
          <Input
            id={`${idPrefix}-${index}-cidr`}
            aria-label={cidrLabel}
            value={row.cidr}
            onChange={(event) => update(index, { cidr: event.target.value })}
            placeholder="203.0.113.10/32"
            className="font-mono"
            spellCheck={false}
          />
          <Input
            id={`${idPrefix}-${index}-port`}
            aria-label={portLabel}
            value={row.port}
            onChange={(event) => update(index, { port: event.target.value })}
            placeholder="443"
            inputMode="numeric"
            className="font-mono"
          />
          <Select
            value={row.protocol}
            onValueChange={(next) =>
              update(index, { protocol: next as DraftAllowedCidr["protocol"] })
            }
          >
            <SelectTrigger
              id={`${idPrefix}-${index}-protocol`}
              aria-label={protocolLabel}
            >
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
            aria-label={`${removeLabel}: ${row.cidr || cidrLabel}`}
            onClick={() => onChange(rows.filter((_, position) => position !== index))}
          >
            {removeLabel}
          </button>
        </div>
      ))}
      <button
        type="button"
        className="rounded-md border border-border px-3 py-2 text-sm font-semibold text-brand-900 hover:bg-secondary"
        onClick={() =>
          onChange([...rows, { cidr: "", port: "", protocol: "TCP" }])
        }
      >
        {addLabel}
      </button>
      {error ? <p className="text-sm text-status-error-strong">{error}</p> : null}
    </fieldset>
  );
}

/** 같은 그룹 안의 앱을 고르는 목록. 사용자가 label 이나 selector 를 적지 않게 한다. */
function PeerPicker({
  idPrefix,
  legend,
  helper,
  addLabel,
  removeLabel,
  appLabel,
  portLabel,
  candidates,
  portForApp,
  peers,
  error,
  onChange,
}: {
  idPrefix: string;
  legend: string;
  helper: string;
  addLabel: string;
  removeLabel: string;
  appLabel: string;
  portLabel: string;
  candidates: ComposeServiceDraft[];
  portForApp: (app: string) => string;
  peers: ComposeServiceDraft["allowedApps"];
  error?: string;
  onChange: (next: ComposeServiceDraft["allowedApps"]) => void;
}) {
  if (candidates.length === 0) return null;
  return (
    <fieldset className="space-y-3">
      <legend className="mb-1 flex items-center gap-2 text-sm font-semibold text-foreground [&_svg]:size-4">
        <Link2 aria-hidden />
        {legend}
      </legend>
      <p className="text-sm text-muted-foreground">{helper}</p>
      {peers.map((peer, index) => (
        <div
          key={index}
          className="grid grid-cols-1 gap-3 rounded-md border border-border p-3 sm:grid-cols-[2fr_1fr_auto]"
        >
          <Select
            value={peer.app}
            onValueChange={(next) =>
              onChange(
                peers.map((item, position) =>
                  position === index
                    ? { ...item, app: next, port: portForApp(next) }
                    : item,
                ),
              )
            }
          >
            <SelectTrigger id={`${idPrefix}-${index}`} aria-label={appLabel}>
              <SelectValue placeholder={appLabel} />
            </SelectTrigger>
            <SelectContent>
              {candidates.map((candidate) => (
                <SelectItem key={candidate.name} value={candidate.name}>
                  {candidate.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Input
            aria-label={portLabel}
            value={peer.port}
            onChange={(event) =>
              onChange(
                peers.map((item, position) =>
                  position === index ? { ...item, port: event.target.value } : item,
                ),
              )
            }
            placeholder={portForApp(peer.app)}
            inputMode="numeric"
            className="font-mono"
          />
          <button
            type="button"
            className="rounded-md border border-border px-3 py-2 text-sm text-muted-foreground hover:bg-secondary"
            aria-label={`${removeLabel}: ${peer.app || appLabel}`}
            onClick={() => onChange(peers.filter((_, position) => position !== index))}
          >
            {removeLabel}
          </button>
        </div>
      ))}
      <button
        type="button"
        className="rounded-md border border-border px-3 py-2 text-sm font-semibold text-brand-900 hover:bg-secondary"
        onClick={() =>
          onChange([
            ...peers,
            {
              app: candidates[0]?.name ?? "",
              port: portForApp(candidates[0]?.name ?? ""),
              protocol: "TCP" as const,
            },
          ])
        }
      >
        {addLabel}
      </button>
      {error ? <p className="text-sm text-status-error-strong">{error}</p> : null}
    </fieldset>
  );
}
