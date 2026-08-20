import {
  DeploymentRequestRows,
  type DeploymentRequestRowLabels,
} from "@/components/paas/deployment-request-rows";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { getI18n } from "@/lib/i18n/server";
import type { DataSource } from "@/lib/paas-api";
import type { DeploymentRequest } from "@/types/domain";

/** 대시보드에서 접기 전에 보여 줄 기본 행 수. */
export const DEFAULT_VISIBLE_DEPLOYMENT_REQUESTS = 3;

/**
 * 화면 2 하단 Recent Deployment Requests 테이블.
 *
 * `source` 는 백엔드 응답인지 목데이터인지를 `data-source` 로 노출해
 * verify-testbed.sh 가 실제 연동 여부를 확인할 수 있게 한다.
 *
 * 행 렌더링과 접기/펼치기는 client 컴포넌트로 내려보낸다. 여기서 i18n 을 먼저
 * 해석해 문구만 넘기므로 client 번들에 사전 전체가 딸려 가지 않는다.
 */
export async function DeploymentRequestsTable({
  requests,
  source = "unavailable",
  initialVisible = DEFAULT_VISIBLE_DEPLOYMENT_REQUESTS,
}: {
  requests: DeploymentRequest[];
  /** 실제 API 응답인지 여부. E2E 가 data-source 로 목데이터 잔존을 잡는다. */
  source?: DataSource;
  /** 접힌 상태에서 보여 줄 행 수. 0 이하면 전부 펼친 상태로 둔다. */
  initialVisible?: number;
}) {
  const { dict } = await getI18n();
  const t = dict.dashboard;

  const labels: DeploymentRequestRowLabels = {
    emptyRequests: t.emptyRequests,
    resultSuccess: t.resultSuccess,
    resultPending: t.resultPending,
    resultFailed: t.resultFailed,
    resultDeleted: t.resultDeleted,
    showAll: t.showAllRequests,
    showFewer: t.showFewerRequests,
  };

  return (
    <div
      data-source={source}
      data-testid="deployment-requests-table"
      className="overflow-hidden rounded-xl border border-border bg-card"
    >
      <Table>
        <TableHeader>
          <TableRow className="border-b border-border bg-secondary hover:bg-secondary">
            <TableHead className="px-5 py-3.5 text-xs font-semibold tracking-wide text-foreground uppercase">
              {t.colRequestId}
            </TableHead>
            <TableHead className="px-5 py-3.5 text-xs font-semibold tracking-wide text-foreground uppercase">
              {t.colApplication}
            </TableHead>
            <TableHead className="px-5 py-3.5 text-xs font-semibold tracking-wide text-foreground uppercase">
              {t.colStatus}
            </TableHead>
            <TableHead className="px-5 py-3.5 text-xs font-semibold tracking-wide text-foreground uppercase">
              {t.colResult}
            </TableHead>
            <TableHead className="px-5 py-3.5 text-xs font-semibold tracking-wide text-foreground uppercase">
              {t.colDate}
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <DeploymentRequestRows
            requests={requests}
            initialVisible={initialVisible}
            labels={labels}
          />
        </TableBody>
      </Table>
    </div>
  );
}
