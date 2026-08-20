import type { Metadata } from "next";
import Link from "next/link";
import { Info, LayoutGrid, Settings } from "lucide-react";

import { AppFooter } from "@/components/paas/app-footer";
import { ServiceCatalogView } from "@/components/paas/service-catalog-view";
import { Button } from "@/components/ui/button";
import { getI18n } from "@/lib/i18n/server";
import { getServiceCatalog } from "@/lib/paas-api";
import { paasIdentity, requirePaasRole } from "@/lib/require-session";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return { title: dict.services.metaTitle };
}

export default async function ServicesPage() {
  const { dict } = await getI18n();
  // realm/client 역할을 합쳐 카탈로그의 roles 제한과 대조한다.
  // auth() 를 직접 부르지 않고 공용 게이트를 쓴다. layout 이 이미 세션을 보장하고,
  // 개발 우회(devBypassSession)까지 같은 경로로 적용되어 화면마다 어긋나지 않는다.
  const { roles: userRoles } = paasIdentity(
    await requirePaasRole("deployments:read"),
  );
  const { services: serviceCatalog } = await getServiceCatalog(userRoles);

  return (
    <>
      {/* 콘텐츠 폭 전체를 덮는 배너 헤더 */}
      <div className="border-b border-border bg-secondary">
        <div className="mx-auto flex w-full max-w-[1200px] flex-wrap items-center justify-between gap-4 px-6 py-6">
          <div className="flex items-center gap-4">
            <LayoutGrid
              className="size-7 text-brand-900"
              strokeWidth={2.5}
              aria-hidden
            />
            <h1 className="text-3xl font-bold tracking-tight text-brand-900">
              {dict.services.title}
            </h1>
          </div>

          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="icon"
              aria-label={dict.services.catalogInfo}
            >
              <Info className="size-5" aria-hidden />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              aria-label={dict.services.catalogSettings}
            >
              <Settings className="size-5" aria-hidden />
            </Button>
            <Button asChild>
              <Link href="/new-app/1">{dict.services.addService}</Link>
            </Button>
          </div>
        </div>
      </div>

      <main className="mx-auto w-full max-w-[1200px] flex-1 px-6 py-8">
        <ServiceCatalogView services={serviceCatalog} />
      </main>
      <AppFooter />
    </>
  );
}
