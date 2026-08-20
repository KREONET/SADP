import type { Metadata } from "next";
import { ArrowLeft, Plus } from "lucide-react";
import Link from "next/link";
import { Suspense } from "react";

import { AppFooter } from "@/components/paas/app-footer";
import { MyAppsView } from "@/components/paas/my-apps-view";
import { PageHeader } from "@/components/paas/page-header";
import { RefreshButton } from "@/components/paas/refresh-button";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { getI18n } from "@/lib/i18n/server";
import { getApplications } from "@/lib/paas-api";
import { paasIdentity, requirePaasRole } from "@/lib/require-session";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return { title: dict.myApps.metaTitle };
}

function ListFallback() {
  return (
    <div className="space-y-6">
      <Skeleton className="h-9 w-full" />
      <div className="grid gap-5 md:grid-cols-2">
        <Skeleton className="h-56 w-full" />
        <Skeleton className="h-56 w-full" />
      </div>
    </div>
  );
}

export default async function MyAppsPage() {
  // 레이아웃이 이미 게이트를 걸었지만, 여기서도 세션을 읽어야 "내" 신청만 조회할 수 있다.
  const { requester } = paasIdentity(await requirePaasRole("deployments:read"));
  const { applications, source } = await getApplications(requester);
  const { dict } = await getI18n();

  return (
    <>
      <main className="mx-auto w-full max-w-[1200px] flex-1 space-y-8 px-6 py-10">
        <PageHeader
          eyebrow={dict.myApps.eyebrow}
          title={dict.myApps.title}
          description={
            <>
              <span className="block">{dict.myApps.descriptionLine1}</span>
              <span className="block">{dict.myApps.descriptionLine2}</span>
            </>
          }
          actions={
            <>
              <Button variant="outline" asChild>
                <Link href="/">
                  <ArrowLeft className="size-4" aria-hidden />
                  {dict.common.actions.back}
                </Link>
              </Button>
              <RefreshButton label={dict.common.actions.refresh} />
              <Button asChild>
                <Link href="/new-app/1">
                  <Plus className="size-4" aria-hidden />
                  {dict.myApps.deployNewApp}
                </Link>
              </Button>
            </>
          }
        />

        {/* useSearchParams 를 쓰므로 Suspense 경계가 필요하다. */}
        <Suspense fallback={<ListFallback />}>
          <MyAppsView applications={applications} source={source} />
        </Suspense>
      </main>
      <AppFooter />
    </>
  );
}
