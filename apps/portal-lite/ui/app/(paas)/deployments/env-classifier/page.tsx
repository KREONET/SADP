import type { Metadata } from "next";

import { AppFooter } from "@/components/paas/app-footer";
import { EnvClassifierView } from "@/components/paas/env-classifier-view";
import { PageHeader } from "@/components/paas/page-header";
import { getI18n } from "@/lib/i18n/server";
import { requirePaasRole } from "@/lib/require-session";

export async function generateMetadata(): Promise<Metadata> {
  const { dict } = await getI18n();
  return { title: dict.envClassifier.metaTitle };
}

export default async function EnvClassifierPage() {
  await requirePaasRole("deployments:read");
  const { dict } = await getI18n();

  return (
    <>
      <div className="mx-auto w-full max-w-[1200px] flex-1 space-y-8 px-6 py-10">
        <PageHeader
          eyebrow={dict.envClassifier.eyebrow}
          title={dict.envClassifier.title}
          description={
            <>
              {dict.envClassifier.descriptionLine1}
              <br />
              {dict.envClassifier.descriptionLine2}
            </>
          }
        />

        {/* 순수 클라이언트 도구다. 남의 샘플 키가 아니라 빈 상태에서 시작한다. */}
        <EnvClassifierView />
      </div>

      {/* 개인정보 처리방침 / 이용약관은 /docs 하위 문서였다. 문서 화면을 걷어내면서
          링크 대상이 사라져 함께 제거했다. 외부 URL이 정해지면 extraLinks 로 되돌린다. */}
      <AppFooter />
    </>
  );
}
