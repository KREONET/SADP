"use client";

import { ExternalLink } from "lucide-react";
import Link from "next/link";
import * as React from "react";

import { EnvClassifier } from "@/components/paas/env-classifier";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { useI18n } from "@/lib/i18n/context";
import {
  getDraftSnapshot,
  getServerDraftSnapshot,
  setDraft,
  subscribeDraft,
} from "@/lib/new-app-draft";
import { LEGACY_TOOLS } from "@/lib/site-config";
import type { DraftEnvVar, EnvVar } from "@/types/domain";

interface EnvClassifierViewProps {
  /** 초기 환경변수 목록. 기본은 빈 목록이고, 사용자가 .env 를 올려 채운다. */
  initialVars?: EnvVar[];
}

/** 저장 버튼을 눌렀을 때 사용자에게 확인시킬 내용. */
type SaveResult =
  | { kind: "unclassified"; count: number }
  | { kind: "classified"; configmap: number; openbao: number };

/**
 * 화면 6 의 상호작용 부분.
 *
 * 서버에 저장되는 상태가 없는 로컬 도구다. 사용자가 붙여넣거나 업로드한
 * `.env` 만 분류하며, 시작 상태는 비어 있다.
 */
export function EnvClassifierView({
  initialVars = [],
}: EnvClassifierViewProps) {
  const { dict } = useI18n();
  const t = dict.envClassifier;
  const draft = React.useSyncExternalStore(
    subscribeDraft,
    getDraftSnapshot,
    getServerDraftSnapshot,
  );
  const [editedVars, setEditedVars] = React.useState<EnvVar[] | null>(null);
  // 새로고침 뒤 OpenBao 값은 빈 문자열이지만 key와 분류는 남는다. 분류기에 다시
  // 들어왔을 때 그 행을 복원해 사용자가 Secret 값만 재입력할 수 있게 한다.
  const vars =
    editedVars ??
    (initialVars.length > 0
      ? initialVars
      : draft.envVars.map((item, index) => ({
          id: `draft-${index}-${item.key}`,
          key: item.key,
          value: item.value,
          classification: item.classification,
        })));
  // 결과를 토스트로 내보내면 화면 우하단에 잠깐 떴다 사라진다. 분류 결과는
  // 사용자가 읽고 넘어가야 하는 내용이라 확인을 요구하는 모달로 띄운다.
  const [result, setResult] = React.useState<SaveResult | null>(null);

  function handleSave() {
    const rest = vars.filter((v) => v.classification === "unclassified");
    if (rest.length > 0) {
      setResult({ kind: "unclassified", count: rest.length });
      return;
    }
    const configmap = vars.filter((v) => v.classification === "configmap");
    const openbao = vars.filter((v) => v.classification === "openbao");

    // OpenBao 값은 메모리 초안에만 유지한다. new-app-draft가 sessionStorage에 쓸 때는
    // 값을 지우며, 제출 시 포털 API가 OpenBao에 직접 저장한다.
    const draftEnvVars: DraftEnvVar[] = [
      ...configmap.map((item) => ({
        key: item.key,
        value: item.value,
        classification: "configmap" as const,
      })),
      ...openbao.map((item) => ({
        key: item.key,
        value: item.value,
        classification: "openbao" as const,
      })),
    ];
    setDraft({ ...getDraftSnapshot(), envVars: draftEnvVars });

    setResult({
      kind: "classified",
      configmap: configmap.length,
      openbao: openbao.length,
    });
  }

  const description =
    result === null
      ? ""
      : result.kind === "unclassified"
        ? t.resultUnclassified.replace("{count}", String(result.count))
        : t.resultSummary
            .replace("{configmap}", String(result.configmap))
            .replace("{openbao}", String(result.openbao));

  return (
    <>
      <EnvClassifier
        value={vars}
        onChange={setEditedVars}
        layout="page"
        onSave={handleSave}
      />

      <AlertDialog
        open={result !== null}
        onOpenChange={(open) => {
          if (!open) setResult(null);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {result?.kind === "unclassified"
                ? t.resultUnclassifiedTitle
                : t.resultTitle}
            </AlertDialogTitle>
            <AlertDialogDescription>{description}</AlertDialogDescription>
          </AlertDialogHeader>
          {result?.kind === "classified" ? (
            <div className="space-y-2 text-sm text-muted-foreground">
              <p>
                {result.configmap + result.openbao === 0
                  ? t.resultClearedNote
                  : t.resultSavedNote}
              </p>
              {result.openbao > 0 ? (
                <>
                  <p>{t.resultSecretNote}</p>
                  <a
                    className="inline-flex items-center gap-1 font-semibold text-brand-accent underline underline-offset-4"
                    href={LEGACY_TOOLS.baoUrl}
                    target="_blank"
                    rel="noreferrer noopener"
                  >
                    {t.resultOpenBaoLink}
                    <ExternalLink className="size-4" aria-hidden />
                  </a>
                </>
              ) : null}
            </div>
          ) : null}
          <AlertDialogFooter>
            {result?.kind === "classified" ? (
              <AlertDialogCancel asChild>
                <Link href="/new-app/1">{t.resultGoToWizard}</Link>
              </AlertDialogCancel>
            ) : null}
            <AlertDialogAction onClick={() => setResult(null)}>
              {t.resultClose}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
