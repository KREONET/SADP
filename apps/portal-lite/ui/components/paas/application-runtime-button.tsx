"use client";

import { LoaderCircle, Play, Square } from "lucide-react";
import { useRouter } from "next/navigation";
import * as React from "react";
import { useTransition } from "react";

import { changeMyApplicationRuntimeState } from "@/app/(paas)/my-apps/[id]/actions";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import type { ApplicationRuntimeAction } from "@/lib/application-runtime";

interface ApplicationRuntimeLabels {
  button: string;
  title: string;
  description: string;
  confirm: string;
  cancel: string;
  pending: string;
  failed: string;
}

export function ApplicationRuntimeButton({
  requestId,
  action,
  labels,
}: {
  requestId: string;
  action: ApplicationRuntimeAction;
  labels: ApplicationRuntimeLabels;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [failure, setFailure] = React.useState<string | null>(null);
  const stopping = action === "stop";

  function changeRuntimeState() {
    startTransition(async () => {
      const result = await changeMyApplicationRuntimeState(
        requestId,
        stopping ? "stopped" : "running",
      );
      if (!result.ok) {
        setFailure(result.reason);
        return;
      }
      setFailure(null);
      // API 응답의 stopping/starting 상태를 즉시 다시 읽고 이후 Refresh로 완료를 확인한다.
      router.refresh();
    });
  }

  const Icon = stopping ? Square : Play;

  return (
    <div className="space-y-2">
      {failure ? (
        <p
          role="alert"
          className="rounded-md border border-status-error bg-status-error-soft p-3 text-sm text-status-error-strong"
        >
          <span className="font-semibold">{labels.failed}</span> {failure}
        </p>
      ) : null}
      <AlertDialog>
        <AlertDialogTrigger asChild>
          <Button
            type="button"
            variant={stopping ? "outline" : "default"}
            disabled={pending}
            aria-busy={pending}
          >
            {pending ? (
              <LoaderCircle className="size-4 animate-spin" aria-hidden />
            ) : (
              <Icon className="size-4" aria-hidden />
            )}
            {pending ? labels.pending : labels.button}
          </Button>
        </AlertDialogTrigger>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{labels.title}</AlertDialogTitle>
            <AlertDialogDescription>
              {labels.description}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>
              {labels.cancel}
            </AlertDialogCancel>
            <AlertDialogAction
              variant={stopping ? "destructive" : "default"}
              disabled={pending}
              onClick={changeRuntimeState}
            >
              {labels.confirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

