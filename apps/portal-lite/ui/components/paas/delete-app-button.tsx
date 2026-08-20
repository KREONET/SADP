"use client";

import { LoaderCircle, Trash2 } from "lucide-react";
import { useRouter } from "next/navigation";
import * as React from "react";
import { useTransition } from "react";

import { deleteMyApplication } from "@/app/(paas)/my-apps/[id]/actions";
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

interface DeleteLabels {
  button: string;
  title: string;
  description: string;
  confirm: string;
  cancel: string;
  pending: string;
  success: string;
  failed: string;
}

export function DeleteAppButton({
  requestId,
  appName,
  labels,
}: {
  requestId: string;
  appName: string;
  labels: DeleteLabels;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  // 실패 사유를 토스트로 내보내지 않는다. 플랫폼 CSP 가 style-src 에 'unsafe-inline' 을
  // 주지 않아 sonner 의 인라인 위치 지정이 차단되고, 토스트가 화면 아래에 흘러 붙는다.
  const [failure, setFailure] = React.useState<string | null>(null);

  function remove() {
    startTransition(async () => {
      const result = await deleteMyApplication(requestId);
      if (!result.ok) {
        setFailure(result.reason);
        return;
      }
      setFailure(null);
      router.push("/my-apps");
      router.refresh();
    });
  }

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
          <Button variant="destructive" disabled={pending}>
            {pending ? (
              <LoaderCircle className="size-4 animate-spin" aria-hidden />
            ) : (
              <Trash2 className="size-4" aria-hidden />
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
              variant="destructive"
              disabled={pending}
              onClick={remove}
            >
              {labels.confirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
