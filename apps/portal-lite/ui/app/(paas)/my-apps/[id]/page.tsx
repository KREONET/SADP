import { ArrowLeft, ExternalLink } from "lucide-react";
import Link from "next/link";

import { ApplicationRuntimeButton } from "@/components/paas/application-runtime-button";
import { AppFooter } from "@/components/paas/app-footer";
import { DeleteAppButton } from "@/components/paas/delete-app-button";
import { MonoKeyValueBox } from "@/components/paas/mono-kv-box";
import { PageHeader } from "@/components/paas/page-header";
import { RefreshButton } from "@/components/paas/refresh-button";
import { RelativeTime } from "@/components/paas/relative-time";
import { StatusPill } from "@/components/paas/status-pill";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { runtimeActionForRequestState } from "@/lib/application-runtime";
import { getI18n } from "@/lib/i18n/server";
import { getApplicationDetail } from "@/lib/paas-api";
import { hasPortalApiRole } from "@/lib/portal-api-bff";
import { paasIdentity, requirePaasRole } from "@/lib/require-session";
import type { ApplicationStatus, StatusTone } from "@/types/domain";

const TONE_BY_STATUS: Record<ApplicationStatus, StatusTone> = {
  RUNNING: "ok",
  PENDING: "warn",
  FAILED: "error",
  STOPPED: "idle",
};

export default async function ApplicationDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const [{ id }, { dict }, session] = await Promise.all([
    params,
    getI18n(),
    requirePaasRole("deployments:read"),
  ]);
  const { requester, roles } = paasIdentity(session);
  const { application } = await getApplicationDetail(id, requester);
  const t = dict.myApps.detail;
  const canWrite = hasPortalApiRole(roles, "deployments:write");
  const runtimeAction =
    application && canWrite
      ? runtimeActionForRequestState(
          application.pipelineState,
          application.desiredRuntimeState,
          application.failedFromState,
        )
      : null;
  const retryingRuntime = application?.pipelineState === "failed";

  return (
    <>
      <main className="mx-auto w-full max-w-[1200px] flex-1 space-y-8 px-6 py-10">
        <PageHeader
          eyebrow={t.eyebrow}
          title={application?.name ?? t.unavailableTitle}
          description={
            application ? (
              <span className="font-mono">{application.requestId}</span>
            ) : (
              t.unavailableDescription
            )
          }
          actions={
            <>
              <Button variant="outline" asChild>
                <Link href="/my-apps">
                  <ArrowLeft className="size-4" aria-hidden />
                  {dict.common.actions.back}
                </Link>
              </Button>
              <RefreshButton label={dict.common.actions.refresh} />
              {application && runtimeAction ? (
                <ApplicationRuntimeButton
                  requestId={application.requestId}
                  action={runtimeAction}
                  labels={
                    runtimeAction === "stop"
                      ? {
                          button: retryingRuntime
                            ? t.retryStopApplication
                            : t.stopApplication,
                          title: t.stopTitle,
                          description: t.stopDescription,
                          confirm: t.stopConfirm,
                          cancel: dict.common.actions.cancel,
                          pending: t.stopPending,
                          failed: t.stopFailed,
                        }
                      : {
                          button: retryingRuntime
                            ? t.retryResumeApplication
                            : t.resumeApplication,
                          title: t.resumeTitle,
                          description: t.resumeDescription,
                          confirm: t.resumeConfirm,
                          cancel: dict.common.actions.cancel,
                          pending: t.resumePending,
                          failed: t.resumeFailed,
                        }
                  }
                />
              ) : null}
              {application &&
              canWrite &&
              ["deployed", "stopped", "failed"].includes(
                application.pipelineState,
              ) ? (
                <DeleteAppButton
                  requestId={application.requestId}
                  appName={application.name}
                  labels={{
                    button: t.deleteApplication,
                    title: t.deleteTitle,
                    description: t.deleteDescription,
                    confirm: t.deleteConfirm,
                    cancel: t.deleteCancel,
                    pending: t.deletePending,
                    success: t.deleteSuccess,
                    failed: t.deleteFailed,
                  }}
                />
              ) : null}
            </>
          }
        />

        {application ? (
          <div className="grid gap-6 lg:grid-cols-2">
            <Card>
              <CardHeader className="flex-row items-center justify-between">
                <CardTitle>{t.pipeline}</CardTitle>
                <StatusPill tone={TONE_BY_STATUS[application.status]} dot>
                  {application.pipelineState}
                </StatusPill>
              </CardHeader>
              <CardContent className="space-y-4">
                <MonoKeyValueBox
                  rows={[
                    { label: t.requestId, value: application.requestId },
                    { label: t.state, value: application.pipelineState },
                    { label: t.zone, value: application.zone },
                    {
                      label: t.createdAt,
                      value: new Date(application.createdAt).toISOString(),
                    },
                    {
                      label: t.updatedAt,
                      value: new Date(application.lastDeployedAt).toISOString(),
                    },
                    { label: t.image, value: application.image ?? "-" },
                    { label: t.replicas, value: application.replicas ?? "-" },
                  ]}
                />
                {application.message ? (
                  <p className="rounded-md bg-status-error-soft px-3 py-2 text-sm text-status-error-strong">
                    {application.message}
                  </p>
                ) : null}
                <p className="text-xs text-muted-foreground">
                  <RelativeTime iso={application.lastDeployedAt} />
                </p>
                {application.pullRequest ? (
                  <Button variant="outline" asChild>
                    <a
                      href={application.pullRequest.url}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {t.openPullRequest} #{application.pullRequest.number}
                      <ExternalLink className="size-4" aria-hidden />
                    </a>
                  </Button>
                ) : null}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>{t.configuration}</CardTitle>
              </CardHeader>
              <CardContent className="space-y-4">
                <MonoKeyValueBox
                  rows={[
                    { label: t.repository, value: application.gitRepository },
                    { label: t.revision, value: application.revision },
                    { label: t.dockerfile, value: application.dockerfile },
                    { label: t.port, value: String(application.containerPort) },
                    { label: t.exposure, value: application.exposure },
                    ...(application.internalAddress
                      ? [
                          {
                            label: t.internalAddress,
                            value: application.internalAddress,
                          },
                        ]
                      : []),
                    { label: t.route, value: application.route ?? "-" },
                  ]}
                />
                {application.status === "RUNNING" && application.route ? (
                  <Button asChild>
                    <a href={application.route} target="_blank" rel="noreferrer">
                      {t.openApplication}
                      <ExternalLink className="size-4" aria-hidden />
                    </a>
                  </Button>
                ) : null}
              </CardContent>
            </Card>
          </div>
        ) : null}
      </main>
      <AppFooter />
    </>
  );
}
