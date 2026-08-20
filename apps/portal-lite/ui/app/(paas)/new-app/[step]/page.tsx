import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { AppFooter } from "@/components/paas/app-footer";
import { NewAppWizard } from "@/components/paas/new-app-wizard";
import { getI18n } from "@/lib/i18n/server";
import { isValidStep } from "@/lib/new-app-draft";
import { getWizardOptions } from "@/lib/paas-api";
import { requirePaasRole } from "@/lib/require-session";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return {
    title: dict.newApp.metaTitle,
    description: dict.newApp.metaDescription,
  };
}

/*
 * 위저드가 고를 수 있는 값(프로젝트·preset·쿼터·상한)은 카탈로그에서 온다.
 * 정적 생성을 하면 빌드 시점 값이 굳어버리므로 요청마다 서버에서 읽는다.
 */
export default async function NewAppStepPage({
  params,
}: {
  params: Promise<{ step: string }>;
}) {
  const { step } = await params;
  const parsed = Number(step);

  if (!isValidStep(parsed)) notFound();

  await requirePaasRole("deployments:write");
  const options = await getWizardOptions();

  return (
    <>
      <NewAppWizard step={parsed} options={options} />
      <AppFooter />
    </>
  );
}
