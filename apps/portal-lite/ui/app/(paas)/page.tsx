import { Plus } from "lucide-react";
import Link from "next/link";

import { AppFooter } from "@/components/paas/app-footer";
import { DeploymentRequestsTable } from "@/components/paas/deployment-requests-table";
import { PlatformStatusBanner } from "@/components/paas/platform-status-banner";
import { QuickAccessList } from "@/components/paas/quick-access-card";
import { QuotaBar } from "@/components/paas/quota-bar";
import { RefreshButton } from "@/components/paas/refresh-button";
import { SectionHeading } from "@/components/paas/section-heading";
import {
  DeployNewAppCard,
  WorkloadCard,
} from "@/components/paas/workload-card";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { getI18n } from "@/lib/i18n/server";
import { getDashboard } from "@/lib/paas-api";
import { paasIdentity, requirePaasRole } from "@/lib/require-session";

export async function generateMetadata() {
  const { dict } = await getI18n();
  return { title: dict.dashboard.metaTitle };
}

/**
 * 홈(`/`)은 로그인 여부로 갈린다.
 * - 로그인 O → 아래 사용자 대시보드
 * - 로그인 X → 기존 SADP 메인 페이지. 주소는 `/` 그대로이며 proxy.ts가 내부 rewrite한다
 *
 * 비로그인 분기는 (paas)/layout.tsx 의 requirePaasSession() 이 처리한다.
 */
export default async function DashboardPage() {
  const { dict } = await getI18n();
  const t = dict.dashboard;
  // 대시보드는 전부 "내" 데이터다. 세션 없이는 아무것도 조회하지 않는다.
  const { requester, roles } = paasIdentity(
    await requirePaasRole("deployments:read"),
  );
  const {
    deploymentRequests,
    deploymentRequestsSource,
    gitlabIntegration,
    myWorkloads,
    overallStatus,
    platformSummary,
    quickAccess,
    quotas,
    quotaSource,
  } = await getDashboard(requester, roles);

  return (
    <>
      <main className="mx-auto w-full max-w-[1200px] flex-1 space-y-8 px-6 py-10">
        <PlatformStatusBanner
          title={t.platformStatus}
          summary={platformSummary}
          overall={overallStatus}
          gitlab={gitlabIntegration}
        />

        <div className="grid gap-8 xl:grid-cols-[minmax(0,1fr)_300px]">
          {/* 좌측 + 중앙: Quick Access / My Applications / 배포 요청 테이블 */}
          <div className="space-y-8">
            <div className="grid gap-8 lg:grid-cols-[280px_minmax(0,1fr)]">
              <section className="flex flex-col gap-4">
                <SectionHeading title={t.quickAccess} divider />
                <QuickAccessList items={quickAccess} className="flex-1" />
                <Button asChild size="lg" className="h-14 w-full text-base">
                  <Link href="/new-app/1">
                    <Plus className="size-5" aria-hidden />
                    {t.buildNewApp}
                  </Link>
                </Button>
              </section>

              <section className="space-y-4">
                <SectionHeading
                  title={t.myApplications}
                  divider
                  action={
                    <Link
                      href="/my-apps"
                      className="text-sm font-medium text-muted-foreground hover:text-brand-900"
                    >
                      {dict.common.actions.viewAll}
                    </Link>
                  }
                />
                <div className="grid gap-4 sm:grid-cols-2">
                  {myWorkloads.map((workload) => (
                    <WorkloadCard key={workload.id} workload={workload} />
                  ))}
                  <DeployNewAppCard href="/new-app/1" />
                </div>
              </section>
            </div>

            <section className="space-y-4">
              <SectionHeading
                title={t.recentDeploymentRequests}
                action={
                  <RefreshButton
                    label={dict.common.actions.refresh}
                    withLabel
                    variant="ghost"
                  />
                }
              />
              <DeploymentRequestsTable
                requests={deploymentRequests}
                source={deploymentRequestsSource}
              />
            </section>
          </div>

          {/* 우측 사이드: 공지 + 쿼터 */}
          <aside className="space-y-6">
            <Card className="gap-4 p-6">
              <SectionHeading title={t.myQuotaUsage} size="sm" />
              {/* 쿼터 API 가 죽어도 대시보드 전체를 깨뜨리지 않는다. */}
              {quotaSource === "unavailable" ? (
                <p className="text-sm text-muted-foreground">{t.emptyQuota}</p>
              ) : (
                <div className="space-y-4">
                  {quotas.map((metric) => (
                    <QuotaBar key={metric.id} metric={metric} />
                  ))}
                </div>
              )}
            </Card>
          </aside>
        </div>
      </main>

      <AppFooter />
    </>
  );
}
