import { StatusPill } from "@/components/paas/status-pill";
import type {
  ApprovalStatus,
  SecurityReviewStatus,
  StatusTone,
} from "@/types/domain";

export interface ReviewStatusLabels {
  approval: string;
  security: string;
  approvalPending: string;
  approvalApproved: string;
  approvalRejected: string;
  securityPending: string;
  securityPassed: string;
  securityRejected: string;
}

const APPROVAL_TONE: Record<ApprovalStatus, StatusTone> = {
  pending: "warn",
  approved: "ok",
  rejected: "error",
};

const SECURITY_TONE: Record<SecurityReviewStatus, StatusTone> = {
  pending: "warn",
  passed: "ok",
  rejected: "error",
};

export function approvalLabel(
  status: ApprovalStatus,
  labels: ReviewStatusLabels,
): string {
  if (status === "approved") return labels.approvalApproved;
  if (status === "rejected") return labels.approvalRejected;
  return labels.approvalPending;
}

export function securityReviewLabel(
  status: SecurityReviewStatus,
  labels: ReviewStatusLabels,
): string {
  if (status === "passed") return labels.securityPassed;
  if (status === "rejected") return labels.securityRejected;
  return labels.securityPending;
}

/** 파이프라인 상태와 섞지 않고 승인·보안 검토를 한 쌍으로 표시한다. */
export function ReviewStatus({
  approval,
  security,
  labels,
}: {
  approval: ApprovalStatus;
  security: SecurityReviewStatus;
  labels: ReviewStatusLabels;
}) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <span className="text-xs text-muted-foreground">{labels.approval}</span>
      <StatusPill tone={APPROVAL_TONE[approval]} dot>
        {approvalLabel(approval, labels)}
      </StatusPill>
      <span className="text-xs text-muted-foreground">{labels.security}</span>
      <StatusPill tone={SECURITY_TONE[security]} dot>
        {securityReviewLabel(security, labels)}
      </StatusPill>
    </div>
  );
}

export function approvalTone(status: ApprovalStatus): StatusTone {
  return APPROVAL_TONE[status];
}

export function securityReviewTone(status: SecurityReviewStatus): StatusTone {
  return SECURITY_TONE[status];
}
