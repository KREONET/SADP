"use client";

import * as React from "react";
import {
  CheckCircle2,
  ChevronDown,
  ChevronUp,
  GitPullRequest,
} from "lucide-react";
import { useRouter } from "next/navigation";

import { RelativeTime } from "@/components/paas/relative-time";
import { StatusPill } from "@/components/paas/status-pill";
import { Button } from "@/components/ui/button";
import { TableCell, TableRow } from "@/components/ui/table";
import { cn } from "@/lib/utils";
import type {
  DeploymentRequest,
  DeploymentResult,
  DeploymentStatus,
} from "@/types/domain";

/** STATUS 컬럼 pill. 파랑 계열은 secondary(코드/정보 박스) 토큰을 그대로 쓴다. */
const statusStyle: Record<
  DeploymentStatus,
  { className: string; dot?: boolean; icon?: typeof CheckCircle2 }
> = {
  Ready: { className: "bg-status-ok-soft text-status-ok-strong", dot: true },
  "MR Created": {
    className: "bg-secondary text-brand-900",
    icon: GitPullRequest,
  },
  Validated: { className: "bg-secondary text-brand-900", icon: CheckCircle2 },
};

/** RESULT 컬럼은 pill 이 아니라 컬러 텍스트다. 라벨은 사전에서 가져온다. */
const resultStyle: Record<DeploymentResult, string> = {
  Success: "font-semibold text-status-ok-strong",
  Pending: "text-muted-foreground",
  Failed: "font-semibold text-destructive",
  Deleted: "font-semibold text-muted-foreground",
};

const resultLabelKey: Record<
  DeploymentResult,
  "resultSuccess" | "resultPending" | "resultFailed" | "resultDeleted"
> = {
  Success: "resultSuccess",
  Pending: "resultPending",
  Failed: "resultFailed",
  Deleted: "resultDeleted",
};

/**
 * 서버 컴포넌트에서 이미 해석한 문구만 넘겨받는다. 이 컴포넌트는 client 라
 * `getI18n()` 을 직접 부를 수 없다.
 */
export interface DeploymentRequestRowLabels {
  emptyRequests: string;
  resultSuccess: string;
  resultPending: string;
  resultFailed: string;
  resultDeleted: string;
  showAll: string;
  showFewer: string;
}

/**
 * 배포 요청 테이블 본문.
 *
 * 대시보드는 최근 몇 건만 보여 주고 나머지는 "자세히 보기" 로 접어 둔다. 접힘 상태는
 * 순수 client 상태라 펼칠 때 추가 요청이 없다. 행 자체는 서버에서 이미 렌더되므로
 * `verify-portal-auth.sh` 의 HTML grep 도 그대로 동작한다.
 */
export function DeploymentRequestRows({
  requests,
  initialVisible,
  labels,
}: {
  requests: DeploymentRequest[];
  /** 접힌 상태에서 보여 줄 행 수. 0 이하면 접지 않는다. */
  initialVisible: number;
  labels: DeploymentRequestRowLabels;
}) {
	const router = useRouter();
  const [expanded, setExpanded] = React.useState(false);
	const hasPendingRequest = requests.some((request) => request.result === "Pending");

	// 서버 컴포넌트의 데이터를 직접 복제하지 않고, 진행 중인 요청이 있을 때만
	// 5초마다 새 서버 렌더를 받아 상태가 완료/실패 즉시 화면에 반영되게 한다.
	React.useEffect(() => {
		if (!hasPendingRequest) return;
		const timer = window.setInterval(() => router.refresh(), 5_000);
		return () => window.clearInterval(timer);
	}, [hasPendingRequest, router]);
  const collapsible = initialVisible > 0 && requests.length > initialVisible;
  const visible =
    collapsible && !expanded ? requests.slice(0, initialVisible) : requests;
  const hiddenCount = requests.length - initialVisible;

  if (requests.length === 0) {
    return (
      <TableRow className="border-b border-border">
        <TableCell
          colSpan={5}
          className="px-5 py-10 text-center text-muted-foreground"
        >
          {labels.emptyRequests}
        </TableCell>
      </TableRow>
    );
  }

  return (
    <>
      {visible.map((request) => {
        const status = statusStyle[request.status];
        const resultClassName = resultStyle[request.result];
        const resultLabel = labels[resultLabelKey[request.result]];
        const Icon = status.icon;

        return (
          <TableRow key={request.id} className="border-b border-border">
            <TableCell className="px-5 py-4 font-mono text-xs text-foreground">
              {request.requestId}
            </TableCell>
            <TableCell className="px-5 py-4 text-foreground">
              {request.application}
            </TableCell>
            <TableCell className="px-5 py-4">
              <StatusPill className={status.className} dot={status.dot}>
                {Icon ? <Icon className="size-3.5" aria-hidden /> : null}
                {request.status}
              </StatusPill>
            </TableCell>
            <TableCell className={cn("px-5 py-4", resultClassName)}>
              {resultLabel}
            </TableCell>
            <TableCell className="px-5 py-4 text-muted-foreground">
              <RelativeTime iso={request.date} />
            </TableCell>
          </TableRow>
        );
      })}

      {collapsible ? (
        <TableRow className="hover:bg-transparent">
          <TableCell colSpan={5} className="p-0">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              aria-expanded={expanded}
              data-testid="deployment-requests-toggle"
              onClick={() => setExpanded((previous) => !previous)}
              className="h-11 w-full rounded-none text-sm font-medium text-muted-foreground hover:text-brand-900"
            >
              {expanded ? (
                <>
                  {labels.showFewer}
                  <ChevronUp className="size-4" aria-hidden />
                </>
              ) : (
                <>
                  {labels.showAll}
                  <span className="text-xs">(+{hiddenCount})</span>
                  <ChevronDown className="size-4" aria-hidden />
                </>
              )}
            </Button>
          </TableCell>
        </TableRow>
      ) : null}
    </>
  );
}
