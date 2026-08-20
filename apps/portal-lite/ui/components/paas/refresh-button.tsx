"use client";

import { RefreshCw } from "lucide-react";
import { useRouter } from "next/navigation";
import { useTransition } from "react";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

export function RefreshButton({
  label,
  withLabel = false,
  variant = "outline",
}: {
  label: string;
  withLabel?: boolean;
  variant?: "outline" | "ghost";
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  return (
    <Button
      type="button"
      variant={variant}
      size={withLabel ? "sm" : "icon"}
      aria-label={label}
      aria-busy={pending}
      disabled={pending}
      onClick={() => startTransition(() => router.refresh())}
    >
      <RefreshCw
        className={cn("size-4", pending && "animate-spin")}
        aria-hidden
      />
      {withLabel ? label : null}
    </Button>
  );
}
