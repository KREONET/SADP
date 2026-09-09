"use client";

import {
  Check,
  ExternalLink,
  LoaderCircle,
  ShieldAlert,
  X,
} from "lucide-react";
import { useRouter } from "next/navigation";
import * as React from "react";
import { useTransition } from "react";

import {
  decideAdminDeployment,
  setAdminAutoApprovalPolicy,
} from "@/app/(paas)/admin/actions";
import {
  approvalTone,
  securityReviewTone,
} from "@/components/paas/review-status";
import { StatusPill } from "@/components/paas/status-pill";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import type { Dictionary } from "@/lib/i18n/dictionary";
import type { DataSource } from "@/lib/paas-api";
import type {
  AdminApprovalDashboard,
  AdminDeploymentRequest,
  ApprovalPolicy,
} from "@/types/domain";

type AdminLabels = Dictionary["admin"];

function exactTime(value?: string): string {
  if (!value) return "-";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toISOString();
}

function approvalText(
  request: AdminDeploymentRequest,
  labels: AdminLabels,
): string {
  if (request.approval.status === "approved") return labels.approved;
  if (request.approval.status === "rejected") return labels.rejected;
  return labels.pending;
}

function securityText(
  request: AdminDeploymentRequest,
  labels: AdminLabels,
): string {
  if (request.securityReview.status === "passed") return labels.passed;
  if (request.securityReview.status === "rejected") return labels.rejected;
  return labels.securityPending;
}

function MutationMessage({
  message,
  success = false,
}: {
  message: string | null;
  success?: boolean;
}) {
  if (!message) return null;
  return (
    <p
      role={success ? "status" : "alert"}
      className={
        success
          ? "rounded-md border border-status-ok bg-status-ok-soft px-3 py-2 text-sm text-status-ok-strong"
          : "rounded-md border border-status-error bg-status-error-soft px-3 py-2 text-sm text-status-error-strong"
      }
    >
      {message}
    </p>
  );
}

function RequestActions({
  request,
  labels,
  cancelLabel,
}: {
  request: AdminDeploymentRequest;
  labels: AdminLabels;
  cancelLabel: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [dialogOpen, setDialogOpen] = React.useState(false);
  const [reason, setReason] = React.useState("");
  const [failure, setFailure] = React.useState<string | null>(null);

  function decide(decision: "approved" | "rejected") {
    const normalizedReason = reason.trim();
    if (decision === "rejected" && !normalizedReason) {
      setFailure(labels.rejectReasonRequired);
      return;
    }
    startTransition(async () => {
      const result = await decideAdminDeployment(
        request.id,
        decision,
        normalizedReason,
      );
      if (!result.ok) {
        setFailure(result.reason);
        return;
      }
      setFailure(null);
      setReason("");
      setDialogOpen(false);
      router.refresh();
    });
  }

  if (request.approval.status !== "pending") return null;

  return (
    <div className="space-y-2">
      <MutationMessage message={failure} />
      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          disabled={pending || request.securityReview.status !== "passed"}
          onClick={() => decide("approved")}
        >
          {pending ? (
            <LoaderCircle className="size-4 animate-spin" aria-hidden />
          ) : (
            <Check className="size-4" aria-hidden />
          )}
          {pending ? labels.approving : labels.approve}
        </Button>

        <AlertDialog open={dialogOpen} onOpenChange={setDialogOpen}>
          <AlertDialogTrigger asChild>
            <Button type="button" variant="destructive" disabled={pending}>
              <X className="size-4" aria-hidden />
              {labels.reject}
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>{labels.rejectDialogTitle}</AlertDialogTitle>
              <AlertDialogDescription>
                {labels.rejectDialogDescription}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <div className="space-y-2">
              <Label htmlFor={`reject-reason-${request.id}`}>
                {labels.rejectReasonLabel}
              </Label>
              <Textarea
                id={`reject-reason-${request.id}`}
                value={reason}
                maxLength={2000}
                required
                aria-invalid={failure === labels.rejectReasonRequired}
                placeholder={labels.rejectReasonPlaceholder}
                onChange={(event) => {
                  setReason(event.target.value);
                  if (event.target.value.trim()) setFailure(null);
                }}
              />
              <MutationMessage message={failure} />
            </div>
            <AlertDialogFooter>
              <AlertDialogCancel disabled={pending}>
                {cancelLabel}
              </AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                disabled={pending}
                onClick={(event) => {
                  event.preventDefault();
                  decide("rejected");
                }}
              >
                {pending ? labels.rejecting : labels.reject}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </div>
    </div>
  );
}

function RequestCard({
  request,
  labels,
  cancelLabel,
}: {
  request: AdminDeploymentRequest;
  labels: AdminLabels;
  cancelLabel: string;
}) {
  return (
    <Card data-testid={`admin-request-${request.id}`}>
      <CardHeader className="gap-3">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <CardTitle>{request.application}</CardTitle>
            <p className="mt-1 font-mono text-xs text-muted-foreground">
              {request.project} · {request.id}
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <StatusPill tone="idle" dot>
              {labels.pipeline}: {request.pipelineState}
            </StatusPill>
            <StatusPill tone={approvalTone(request.approval.status)} dot>
              {labels.approval}: {approvalText(request, labels)}
            </StatusPill>
            <StatusPill
              tone={securityReviewTone(request.securityReview.status)}
              dot
            >
              {labels.security}: {securityText(request, labels)}
            </StatusPill>
          </div>
        </div>
      </CardHeader>
      <CardContent className="space-y-5">
        <dl className="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <dt className="text-muted-foreground">{labels.requester}</dt>
            <dd className="font-mono text-foreground">{request.requester}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">{labels.requestedAt}</dt>
            <dd className="font-mono text-foreground">
              {exactTime(request.createdAt)}
            </dd>
          </div>
          <div>
            <dt className="text-muted-foreground">{labels.sourceRepository}</dt>
            <dd className="break-all font-mono text-foreground">
              {request.sourceRepository}
            </dd>
          </div>
          <div>
            <dt className="text-muted-foreground">{labels.decisionBy}</dt>
            <dd className="font-mono text-foreground">
              {request.approval.decidedBy ?? "-"}
            </dd>
          </div>
          <div>
            <dt className="text-muted-foreground">{labels.decisionAt}</dt>
            <dd className="font-mono text-foreground">
              {exactTime(request.approval.decidedAt)}
            </dd>
          </div>
          <div>
            <dt className="text-muted-foreground">{labels.decisionMode}</dt>
            <dd className="text-foreground">
              {request.approval.decidedAt
                ? request.approval.automatic
                  ? labels.automatic
                  : labels.manual
                : "-"}
            </dd>
          </div>
        </dl>

        {request.approval.rejectReason ? (
          <p className="rounded-md border border-status-error bg-status-error-soft px-4 py-3 text-sm text-status-error-strong">
            <span className="font-semibold">{labels.rejectReason}:</span>{" "}
            {request.approval.rejectReason}
          </p>
        ) : null}

        {request.securityReview.findings.length > 0 ? (
          <div className="space-y-2">
            <p className="flex items-center gap-2 text-sm font-semibold">
              <ShieldAlert className="size-4 text-status-error" aria-hidden />
              {labels.findings}
            </p>
            <div className="grid gap-2 md:grid-cols-2">
              {request.securityReview.findings.map((finding, index) => (
                <div
                  key={`${finding.package}-${finding.cve}-${index}`}
                  className="rounded-md border border-status-error/40 bg-status-error-soft p-3 text-sm"
                >
                  <p className="font-mono">
                    {labels.package}: {finding.package}
                  </p>
                  <p className="font-mono">
                    {labels.cve}: {finding.cve}
                  </p>
                  <p className="font-mono">
                    {labels.fixedVersion}: {finding.fixedVersion}
                  </p>
                  <p className="mt-2 text-status-error-strong">
                    {finding.message}
                  </p>
                </div>
              ))}
            </div>
          </div>
        ) : null}

        <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
          {request.pullRequest?.url ? (
            <Button variant="outline" asChild>
              <a href={request.pullRequest.url} target="_blank" rel="noreferrer">
                {labels.openPullRequest} #{request.pullRequest.number}
                <ExternalLink className="size-4" aria-hidden />
              </a>
            </Button>
          ) : (
            <p className="text-sm text-muted-foreground">
              {labels.pullRequestUnavailable}
            </p>
          )}
          <RequestActions
            request={request}
            labels={labels}
            cancelLabel={cancelLabel}
          />
        </div>
      </CardContent>
    </Card>
  );
}

function PolicyCard({
  policy,
  labels,
}: {
  policy: ApprovalPolicy;
  labels: AdminLabels;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [failure, setFailure] = React.useState<string | null>(null);
  const [success, setSuccess] = React.useState<string | null>(null);

  function update() {
    startTransition(async () => {
      const result = await setAdminAutoApprovalPolicy(
        policy.requester,
        !policy.enabled,
      );
      if (!result.ok) {
        setSuccess(null);
        setFailure(result.reason);
        return;
      }
      setFailure(null);
      setSuccess(labels.mutationSuccess);
      router.refresh();
    });
  }

  return (
    <Card>
      <CardContent className="space-y-4 pt-6">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="font-mono font-semibold text-foreground">
              {policy.requester}
            </p>
            <StatusPill tone={policy.enabled ? "ok" : "idle"} dot>
              {policy.enabled ? labels.policyEnabled : labels.policyDisabled}
            </StatusPill>
          </div>
          <Button
            type="button"
            variant={policy.enabled ? "outline" : "default"}
            disabled={pending}
            onClick={update}
          >
            {pending ? (
              <LoaderCircle className="size-4 animate-spin" aria-hidden />
            ) : null}
            {policy.enabled ? labels.disablePolicy : labels.enablePolicy}
          </Button>
        </div>
        <dl className="grid gap-2 text-sm sm:grid-cols-2">
          <div>
            <dt className="text-muted-foreground">{labels.policyUpdatedBy}</dt>
            <dd className="font-mono">{policy.updatedBy ?? "-"}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">{labels.policyUpdatedAt}</dt>
            <dd className="font-mono">{exactTime(policy.updatedAt)}</dd>
          </div>
        </dl>
        {policy.history.length > 0 ? (
          <details className="text-sm">
            <summary className="cursor-pointer font-medium text-brand-900">
              {labels.policyHistory} ({policy.history.length})
            </summary>
            <ul className="mt-2 space-y-1 border-l border-border pl-3">
              {policy.history.map((change, index) => (
                <li key={`${change.changedAt}-${index}`} className="font-mono text-xs">
                  {exactTime(change.changedAt)} · {change.changedBy} ·{" "}
                  {change.enabled ? labels.policyEnabled : labels.policyDisabled}
                </li>
              ))}
            </ul>
          </details>
        ) : null}
        <MutationMessage message={failure} />
        <MutationMessage message={success} success />
      </CardContent>
    </Card>
  );
}

export function AdminApprovalDashboardView({
  dashboard,
  source,
  labels,
  cancelLabel,
}: {
  dashboard: AdminApprovalDashboard | null;
  source: DataSource;
  labels: AdminLabels;
  cancelLabel: string;
}) {
  if (!dashboard) {
    return (
      <Card data-source={source}>
        <CardContent className="space-y-2 py-10 text-center">
          <p className="font-semibold text-foreground">
            {labels.unavailableTitle}
          </p>
          <p className="text-sm text-muted-foreground">
            {labels.unavailableDescription}
          </p>
        </CardContent>
      </Card>
    );
  }

  const counts = {
    pending: dashboard.requests.filter(
      (request) => request.approval.status === "pending",
    ).length,
    approved: dashboard.requests.filter(
      (request) => request.approval.status === "approved",
    ).length,
    rejected: dashboard.requests.filter(
      (request) => request.approval.status === "rejected",
    ).length,
  };

  return (
    <div className="space-y-8" data-source={source}>
      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {[
          [labels.summary.all, dashboard.count],
          [labels.summary.pending, counts.pending],
          [labels.summary.approved, counts.approved],
          [labels.summary.rejected, counts.rejected],
        ].map(([label, value]) => (
          <Card key={String(label)}>
            <CardContent className="space-y-1 pt-6">
              <p className="text-sm text-muted-foreground">{label}</p>
              <p className="font-mono text-3xl font-bold text-brand-900">
                {value}
              </p>
            </CardContent>
          </Card>
        ))}
      </section>

      <section className="space-y-4">
        <div>
          <h2 className="text-xl font-bold text-brand-900">
            {labels.requestsTitle}
          </h2>
          <p className="text-sm text-muted-foreground">
            {labels.requestsDescription}
          </p>
        </div>
        {dashboard.requests.length > 0 ? (
          <div className="space-y-4">
            {dashboard.requests.map((request) => (
              <RequestCard
                key={request.id}
                request={request}
                labels={labels}
                cancelLabel={cancelLabel}
              />
            ))}
          </div>
        ) : (
          <Card>
            <CardContent className="py-10 text-center text-muted-foreground">
              {labels.emptyRequests}
            </CardContent>
          </Card>
        )}
      </section>

      <section className="space-y-4">
        <div>
          <h2 className="text-xl font-bold text-brand-900">
            {labels.policiesTitle}
          </h2>
          <p className="text-sm text-muted-foreground">
            {labels.policiesDescription}
          </p>
        </div>
        {dashboard.policies.length > 0 ? (
          <div className="grid gap-4 lg:grid-cols-2">
            {dashboard.policies.map((policy) => (
              <PolicyCard
                key={policy.requester}
                policy={policy}
                labels={labels}
              />
            ))}
          </div>
        ) : (
          <Card>
            <CardContent className="py-10 text-center text-muted-foreground">
              {labels.emptyPolicies}
            </CardContent>
          </Card>
        )}
      </section>
    </div>
  );
}
