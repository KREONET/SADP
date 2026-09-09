import type { Metadata } from "next";

import { AppFooter } from "@/components/paas/app-footer";
import { AdminApprovalDashboardView } from "@/components/paas/admin-approval-dashboard";
import { PageHeader } from "@/components/paas/page-header";
import { RefreshButton } from "@/components/paas/refresh-button";
import { getI18n } from "@/lib/i18n/server";
import { getAdminApprovalDashboard } from "@/lib/paas-api";
import { paasIdentity, requirePortalAdmin } from "@/lib/require-session";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return { title: dict.admin.metaTitle };
}

export default async function AdminPage() {
  const [session, { dict }] = await Promise.all([
    requirePortalAdmin(),
    getI18n(),
  ]);
  const { requester, roles } = paasIdentity(session);
  const { dashboard, source } = await getAdminApprovalDashboard(
    requester,
    roles,
  );

  return (
    <>
      <main className="mx-auto w-full max-w-[1200px] flex-1 space-y-8 px-6 py-10">
        <PageHeader
          eyebrow={dict.admin.eyebrow}
          title={dict.admin.title}
          description={dict.admin.description}
          actions={
            <RefreshButton label={dict.common.actions.refresh} withLabel />
          }
        />
        <AdminApprovalDashboardView
          dashboard={dashboard}
          source={source}
          labels={dict.admin}
          cancelLabel={dict.common.actions.cancel}
        />
      </main>
      <AppFooter />
    </>
  );
}
