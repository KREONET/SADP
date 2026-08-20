"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowLeft, ArrowRight, Loader2 } from "lucide-react";

import { submitNewApp } from "@/app/(paas)/new-app/actions";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { PageHeader } from "@/components/paas/page-header";
import { WizardStepper } from "@/components/paas/wizard-stepper";
import {
  StepAccess,
  StepBasics,
  StepReview,
  StepRuntime,
  StepSource,
  type StepBodyProps,
} from "@/components/paas/new-app-steps";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { WIZARD_LAST_STEP } from "@/lib/wizard";
import { useI18n } from "@/lib/i18n/context";
import type { Dictionary } from "@/lib/i18n/dictionary";
import {
  clearDraft,
  getDraftSnapshot,
  getIdempotencyKey,
  getServerDraftSnapshot,
  setDraft,
  subscribeDraft,
  validateStep,
  type DraftErrors,
} from "@/lib/new-app-draft";
import type { NewAppDraft, WizardOptions } from "@/types/domain";

const STEP_BODIES: Record<number, React.ComponentType<StepBodyProps>> = {
  1: StepBasics,
  2: StepSource,
  3: StepRuntime,
  4: StepAccess,
  5: StepReview,
};

/** 스텝 번호(1..N)를 사전의 steps 키(s1..sN)로 바꾼다. */
const stepKey = (n: number) =>
  `s${n}` as keyof Dictionary["newApp"]["steps"];

export function NewAppWizard({
  step,
  options,
}: {
  step: number;
  /** 서버 컴포넌트가 카탈로그에서 읽어 넘긴 선택지. */
  options: WizardOptions;
}) {
  const router = useRouter();
  const { dict } = useI18n();
  const t = dict.newApp;
  const wizardSteps = React.useMemo(
    () =>
      Array.from({ length: WIZARD_LAST_STEP }, (_, index) => ({
        step: index + 1,
        title: t.steps[stepKey(index + 1)].title,
        subtitle: t.steps[stepKey(index + 1)].subtitle,
      })),
    [t],
  );
  const draft = React.useSyncExternalStore(
    subscribeDraft,
    getDraftSnapshot,
    getServerDraftSnapshot,
  );
  // "다음 단계"를 누른 스텝에서만 검증 결과를 노출한다(스텝이 바뀌면 자동 해제).
  const [submittedStep, setSubmittedStep] = React.useState<number | null>(null);
  // 알림을 토스트로 띄우지 않는 이유: 플랫폼 CSP 가 style-src 에 'unsafe-inline' 을 주지
  // 않는데, sonner 는 위치·스택을 인라인 style 속성으로 준다. 그래서 토스트는 위치를
  // 잃고 화면 아래에 그대로 흘러 붙는다. 배너와 모달은 클래스만 쓰므로 영향이 없다.
  const [alert, setAlert] = React.useState<{
    title: string;
    description: string;
  } | null>(null);
  const [submittedRequestId, setSubmittedRequestId] = React.useState<
    string | null
  >(null);
  // 서버가 되돌려준 필드 오류. 값을 고치면 지워야 하므로 별도로 들고 있는다.
  const [serverErrors, setServerErrors] = React.useState<DraftErrors>({});
  const [pending, setPending] = React.useState(false);

  const update = React.useCallback(
    <K extends keyof NewAppDraft>(key: K, value: NewAppDraft[K]) => {
      setDraft({ ...getDraftSnapshot(), [key]: value });
      setServerErrors((prev) => {
        if (!(key in prev)) return prev;
        const next = { ...prev };
        delete next[key];
        return next;
      });
    },
    [],
  );

  const errors: DraftErrors = {
    ...(submittedStep === step
      ? validateStep(step, draft, t.errors, options)
      : {}),
    ...serverErrors,
  };

  function goTo(next: number) {
    router.push(`/new-app/${next}`);
  }

  /**
   * 마지막 단계 제출.
   *
   * 여기서 낙관적으로 성공 토스트를 띄우면 안 된다 — 신청이 실제로 만들어졌는지는
   * 서버 액션 결과로만 알 수 있고, 실패하면 사용자가 고칠 수 있게 초안을 남겨야 한다.
   */
  async function handleSubmit() {
    setPending(true);
    try {
      const result = await submitNewApp(draft, getIdempotencyKey());

      if (!result.ok) {
        setServerErrors(result.fieldErrors);
        setAlert({
          title: t.toastSubmitFailedTitle,
          description: t.toastSubmitFailedDescription.replace(
            "{reason}",
            result.reason,
          ),
        });
        return;
      }

      // 신청은 이미 만들어졌다. 같은 초안으로 다시 제출해 PR 이 두 개 생기지 않도록
      // 먼저 지우고, 이동은 사용자가 확인을 누른 뒤에 한다.
      clearDraft();
      setAlert(null);
      setSubmittedRequestId(result.id);
    } catch {
      // 서버 액션 자체가 실패(네트워크 끊김, 세션 만료 리다이렉트 등)한 경우.
      setAlert({
        title: t.toastSubmitFailedTitle,
        description: t.toastSubmitFailedDescription.replace(
          "{reason}",
          t.toastSubmitNetworkReason,
        ),
      });
    } finally {
      setPending(false);
    }
  }

  function handleNext() {
    const nextErrors = validateStep(step, draft, t.errors, options);
    setSubmittedStep(step);

    if (Object.keys(nextErrors).length > 0) {
      setAlert({
        title: t.toastInvalidTitle,
        description: t.toastInvalidDescription,
      });
      return;
    }
    setAlert(null);

    if (step === WIZARD_LAST_STEP) {
      void handleSubmit();
      return;
    }

    goTo(step + 1);
  }

  function handleCancel() {
    clearDraft();
    router.push("/my-apps");
  }

  const Body = STEP_BODIES[step];
  const progress = Math.round((step / WIZARD_LAST_STEP) * 100);
  const lastStep = step === WIZARD_LAST_STEP;
  // 카탈로그를 못 읽었거나 신청이 닫힌 동안에는 제출 버튼을 눌러도 실패만 한다.
  const submitBlocked = lastStep && !options.submissionEnabled;

  return (
    <main className="mx-auto w-full max-w-[1200px] flex-1 space-y-8 px-6 py-10">
      <PageHeader title={t.headerTitle} description={t.headerDescription} />

      {/*
        이 위저드는 앱 하나를 만든다. 서로 연관된 앱 여러 개는 Compose 화면에서
        한 번에 신청한다(전용 Namespace와 앱 사이 통신 규칙이 함께 생긴다).
      */}
      {step === 1 && options.appGroups.enabled ? (
        <p className="rounded-md border border-border bg-secondary/60 p-4 text-sm text-muted-foreground">
          {t.composeHint}{" "}
          <Link
            href="/new-app/compose"
            className="font-semibold text-brand-accent underline underline-offset-4"
          >
            {t.composeHintLink}
          </Link>
        </p>
      ) : null}

      <div className="grid gap-6 lg:grid-cols-[280px_minmax(0,1fr)] lg:items-start">
        <Card className="lg:sticky lg:top-6">
          <CardContent className="py-2">
            <WizardStepper steps={wizardSteps} current={step} />
          </CardContent>
        </Card>

        <Card>
          <CardContent className="space-y-6 py-2">
            <div className="flex items-start justify-between gap-6 border-b border-border pb-5">
              <div className="space-y-1.5">
                <p className="text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase">
                  {t.stepLabel.replace("{step}", String(step))}
                </p>
                <h2 className="text-2xl font-bold text-brand-900">
                  {t.steps[stepKey(step)].heading}
                </h2>
              </div>
              <div className="hidden w-24 shrink-0 pt-2 sm:block">
                <Progress
                  value={progress}
                  aria-label={t.progressLabel
                    .replace("{step}", String(step))
                    .replace("{total}", String(WIZARD_LAST_STEP))}
                />
              </div>
            </div>

            {options.source === "unavailable" ? (
              <p className="rounded-md border border-status-warn-border bg-status-warn-soft p-4 text-sm text-status-warn-strong">
                {t.catalogUnavailable}
              </p>
            ) : null}

            {submitBlocked ? (
              <p className="rounded-md border border-status-warn-border bg-status-warn-soft p-4 text-sm text-status-warn-strong">
                {t.submissionDisabledDescription}
              </p>
            ) : null}

            {alert ? (
              <div
                role="alert"
                className="rounded-md border border-status-error bg-status-error-soft p-4 text-sm text-status-error-strong"
              >
                <p className="font-semibold">{alert.title}</p>
                <p className="mt-1">{alert.description}</p>
              </div>
            ) : null}

            <Body
              draft={draft}
              errors={errors}
              options={options}
              update={update}
            />

            <div className="flex items-center justify-between gap-3 border-t border-border pt-5">
              <Button
                type="button"
                variant="outline"
                onClick={handleCancel}
                disabled={pending}
              >
                {t.cancel}
              </Button>

              <div className="flex items-center gap-2">
                {step > 1 ? (
                  <Button
                    type="button"
                    variant="secondary"
                    onClick={() => goTo(step - 1)}
                    disabled={pending}
                  >
                    <ArrowLeft className="size-4" aria-hidden />
                    {t.prev}
                  </Button>
                ) : null}
                <Button
                  type="button"
                  onClick={handleNext}
                  disabled={pending || submitBlocked}
                >
                  {pending ? (
                    <Loader2 className="size-4 animate-spin" aria-hidden />
                  ) : null}
                  {lastStep ? t.createPlan : t.next}
                  {pending ? null : (
                    <ArrowRight className="size-4" aria-hidden />
                  )}
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>

      {/*
        성공 알림도 토스트가 아니라 모달이다. 이 화면은 확인 직후 /my-apps 로 넘어가므로
        토스트였다면 이동과 함께 사라져 무엇이 만들어졌는지 확인할 틈이 없다.
      */}
      <AlertDialog
        open={submittedRequestId !== null}
        onOpenChange={(open) => {
          if (!open) setSubmittedRequestId(null);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.toastPlanTitle}</AlertDialogTitle>
            <AlertDialogDescription>
              {t.toastPlanDescription.replace("{name}", draft.name)}
            </AlertDialogDescription>
          </AlertDialogHeader>
          {submittedRequestId ? (
            <p className="font-mono text-sm text-muted-foreground">
              {submittedRequestId}
            </p>
          ) : null}
          <AlertDialogFooter>
            <AlertDialogAction
              onClick={() => {
                setSubmittedRequestId(null);
                router.push("/my-apps");
                router.refresh();
              }}
            >
              {t.next}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </main>
  );
}
