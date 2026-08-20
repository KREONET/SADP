import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { AppFooter } from "@/components/paas/app-footer";
import { ComposeStackForm } from "@/components/paas/compose-stack-form";
import { getI18n } from "@/lib/i18n/server";
import { getWizardOptions } from "@/lib/paas-api";
import { requirePaasRole } from "@/lib/require-session";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return {
    title: dict.compose.metaTitle,
    description: dict.compose.metaDescription,
  };
}

/**
 * 다중 앱(Git Compose/Helm 또는 Compose 직접 입력) 신청 화면.
 *
 * 카탈로그가 appGroups.enabled 를 내려줄 때만 연다. 백엔드가 이 기능을 모르는
 * 버전이면 화면만 있고 신청이 422 로 되돌아오는 상태가 되기 때문이다.
 */
export default async function ComposeStackPage() {
  await requirePaasRole("deployments:write");
  const options = await getWizardOptions();
  if (!options.appGroups.enabled) notFound();

  return (
    <>
      <ComposeStackForm options={options} />
      <AppFooter />
    </>
  );
}
