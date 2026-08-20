"use client";

import * as React from "react";
import {
  ArrowRight,
  Eye,
  EyeOff,
  FileText,
  GripVertical,
  Lock,
  Sparkles,
  Trash2,
  Upload,
  X,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Textarea } from "@/components/ui/textarea";
import { useI18n } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";
import {
  parseEnvText,
  isSensitiveEnvValue,
  isSensitiveKey,
  MASKED_VALUE,
} from "@/lib/env-parse";
import type { EnvClassification, EnvVar } from "@/types/domain";

const DRAG_MIME = "application/x-sadp-env-key";

export interface EnvClassifierProps {
  value: EnvVar[];
  onChange: (next: EnvVar[]) => void;
  /** page = 화면 6 2열 레이아웃, compact = 위저드 5단계 세로 스택 */
  layout?: "page" | "compact";
  /** 하단 저장 버튼. 넘기지 않으면 버튼을 숨긴다. */
  onSave?: () => void;
  saveLabel?: string;
  className?: string;
}

export function EnvClassifier({
  value,
  onChange,
  layout = "page",
  onSave,
  saveLabel,
  className,
}: EnvClassifierProps) {
  const { dict } = useI18n();
  const t = dict.envClassifier;
  const [rawText, setRawText] = React.useState("");
  const [revealed, setRevealed] = React.useState<Record<string, boolean>>({});
  const [dropTarget, setDropTarget] = React.useState<EnvClassification | null>(
    null,
  );
  const fileInputRef = React.useRef<HTMLInputElement>(null);

  const unclassified = value.filter((v) => v.classification === "unclassified");
  const configmap = value.filter((v) => v.classification === "configmap");
  const openbao = value.filter((v) => v.classification === "openbao");

  function move(id: string, classification: EnvClassification) {
    onChange(value.map((v) => (v.id === id ? { ...v, classification } : v)));
  }

  // 버킷의 X 는 미분류로 되돌릴 뿐이라 변수가 목록에 계속 남는다. 잘못 붙여 넣은
  // 값을 화면에서 완전히 빼려면 지우는 수단이 따로 있어야 한다.
  function remove(id: string) {
    onChange(value.filter((v) => v.id !== id));
  }

  function toggleReveal(id: string) {
    setRevealed((prev) => ({ ...prev, [id]: !prev[id] }));
  }

  function handleParse() {
    const parsed = parseEnvText(rawText);
    if (parsed.length === 0) return;

    // 이미 분류해 둔 키의 위치는 보존하고, 값만 갱신한다.
    const byKey = new Map(value.map((v) => [v.key, v]));
    const merged: EnvVar[] = parsed.map((item, index) => {
      const existing = byKey.get(item.key);
      return {
        id: existing?.id ?? `env-${Date.now()}-${index}`,
        key: item.key,
        value: item.value,
        classification: existing?.classification ?? "unclassified",
      };
    });

    const parsedKeys = new Set(parsed.map((p) => p.key));
    const untouched = value.filter((v) => !parsedKeys.has(v.key));
    onChange([...untouched, ...merged]);
  }

  async function handleFile(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file) return;
    setRawText(await file.text());
    event.target.value = "";
  }

  const dropHandlers = (zone: EnvClassification) => ({
    onDragOver: (event: React.DragEvent) => {
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      setDropTarget(zone);
    },
    onDragLeave: () => setDropTarget((prev) => (prev === zone ? null : prev)),
    onDrop: (event: React.DragEvent) => {
      event.preventDefault();
      const id = event.dataTransfer.getData(DRAG_MIME);
      setDropTarget(null);
      if (id) move(id, zone);
    },
  });

  return (
    <div
      className={cn(
        layout === "page"
          ? "grid gap-6 lg:grid-cols-[minmax(0,0.75fr)_minmax(0,1fr)] lg:items-start"
          : "space-y-6",
        className,
      )}
    >
      {/* ---------------------------- 좌: 입력 + 미분류 ---------------------------- */}
      <div className="space-y-6">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between gap-2 space-y-0">
            <CardTitle className="text-lg font-bold text-brand-900">
              {t.rawInputTitle}
            </CardTitle>
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              className="flex items-center gap-1.5 text-xs font-semibold text-brand-900 transition-colors hover:text-brand-accent"
            >
              <Upload className="size-3.5" aria-hidden />
              {t.loadFile}
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept=".env,text/plain"
              className="sr-only"
              onChange={handleFile}
              aria-label={t.fileInputLabel}
            />
          </CardHeader>
          <CardContent className="space-y-4">
            <Textarea
              value={rawText}
              onChange={(event) => setRawText(event.target.value)}
              spellCheck={false}
              aria-label={t.rawTextLabel}
              className="min-h-[9.5rem] resize-y bg-secondary font-mono text-sm leading-relaxed"
              placeholder={t.rawPlaceholder}
            />
            <div className="flex items-center justify-end gap-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => setRawText("")}
              >
                {t.clear}
              </Button>
              <Button type="button" size="sm" onClick={handleParse}>
                <Sparkles className="size-4" aria-hidden />
                {t.parseAndClassify}
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between gap-2 space-y-0">
            <CardTitle className="text-sm font-semibold text-foreground">
              {t.unclassifiedTitle}
            </CardTitle>
            <Badge variant="secondary">
              {t.itemCount.replace("{count}", String(unclassified.length))}
            </Badge>
          </CardHeader>
          <CardContent className="space-y-2">
            {unclassified.length === 0 ? (
              <p className="rounded-md border border-dashed border-border px-3 py-6 text-center text-xs text-muted-foreground">
                {t.allClassified}
              </p>
            ) : (
              unclassified.map((item) => (
                <EnvRow
                  key={item.id}
                  item={item}
                  tone="light"
                  revealed={revealed[item.id] ?? true}
                  onToggleReveal={() => toggleReveal(item.id)}
                  onMove={(zone) => move(item.id, zone)}
                  onDelete={() => remove(item.id)}
                />
              ))
            )}
          </CardContent>
        </Card>
      </div>

      {/* ------------------------------ 우: 분류 버킷 ------------------------------ */}
      <div className="space-y-6">
        <section
          {...dropHandlers("configmap")}
          className={cn(
            "rounded-xl border-2 border-dashed p-5 transition-colors",
            dropTarget === "configmap"
              ? "border-brand-900 bg-secondary/60"
              : "border-border bg-transparent",
          )}
        >
          <div className="flex items-start justify-between gap-2">
            <div>
              <h3 className="flex items-center gap-2 text-lg font-bold text-brand-900">
                <FileText className="size-5" aria-hidden />
                {t.configMapTitle}
              </h3>
              <p className="mt-1 text-xs text-muted-foreground">
                {t.configMapDescription}
              </p>
            </div>
            <Badge variant="secondary">
              {t.itemCount.replace("{count}", String(configmap.length))}
            </Badge>
          </div>

          <div className="mt-4 space-y-2">
            {configmap.map((item) => (
              <EnvRow
                key={item.id}
                item={item}
                tone="light"
                revealed={revealed[item.id] ?? true}
                onToggleReveal={() => toggleReveal(item.id)}
                onMove={(zone) => move(item.id, zone)}
                onRemove={() => move(item.id, "unclassified")}
              />
            ))}
            <DropSlot label={t.dropKeysHere} tone="light" />
          </div>
        </section>

        <section
          {...dropHandlers("openbao")}
          className={cn(
            "rounded-xl bg-brand-900 p-5 text-white ring-2 transition-colors",
            dropTarget === "openbao" ? "ring-brand-accent" : "ring-transparent",
          )}
        >
          <div className="flex items-start justify-between gap-2">
            <div>
              <h3 className="flex items-center gap-2 text-lg font-bold text-white">
                <Lock className="size-5 text-brand-accent" aria-hidden />
                {t.openbaoTitle}
              </h3>
              <p className="mt-1 text-xs text-white/60">
                {t.openbaoDescription}
              </p>
            </div>
            <Badge className="bg-brand-accent text-brand-900">
              {t.itemCount.replace("{count}", String(openbao.length))}
            </Badge>
          </div>

          <div className="mt-4 space-y-2">
            {openbao.map((item) => (
              <EnvRow
                key={item.id}
                item={item}
                tone="dark"
                revealed={revealed[item.id] ?? false}
                onToggleReveal={() => toggleReveal(item.id)}
                onMove={(zone) => move(item.id, zone)}
                onRemove={() => move(item.id, "unclassified")}
              />
            ))}
            <DropSlot label={t.dropSensitiveKeysHere} tone="dark" />
          </div>

          {onSave ? (
            <>
              <div className="mt-5 border-t border-white/15" />
              <div className="mt-4 flex justify-end">
                <Button
                  type="button"
                  onClick={onSave}
                  className="bg-nav-active font-semibold text-brand-900 hover:bg-nav-active/90"
                >
                  {saveLabel ?? t.saveClassifications}
                  <ArrowRight className="size-4" aria-hidden />
                </Button>
              </div>
            </>
          ) : null}
        </section>
      </div>
    </div>
  );
}

/* ------------------------------- 내부 조각들 ------------------------------- */

function DropSlot({ label, tone }: { label: string; tone: "light" | "dark" }) {
  return (
    <p
      className={cn(
        "rounded-md border border-dashed px-3 py-4 text-center text-xs",
        tone === "dark"
          ? "border-white/20 text-white/50"
          : "border-border text-muted-foreground",
      )}
    >
      {label}
    </p>
  );
}

interface EnvRowProps {
  item: EnvVar;
  tone: "light" | "dark";
  revealed: boolean;
  onToggleReveal: () => void;
  onMove: (zone: EnvClassification) => void;
  /** 분류 버킷에서 미분류로 되돌린다. 변수 자체는 남는다. */
  onRemove?: () => void;
  /** 목록에서 변수를 아예 없앤다. 미분류 행에만 준다. */
  onDelete?: () => void;
}

function EnvRow({
  item,
  tone,
  revealed,
  onToggleReveal,
  onMove,
  onRemove,
  onDelete,
}: EnvRowProps) {
  const { dict } = useI18n();
  const t = dict.envClassifier;
  const sensitive = isSensitiveKey(item.key) || isSensitiveEnvValue(item.value);
  const dark = tone === "dark";

  const moveTargets = (
    [
      ["configmap", t.configMapTitle],
      ["openbao", t.openbaoTitle],
      ["unclassified", t.zoneUnclassified],
    ] as [EnvClassification, string][]
  ).filter(([zone]) => zone !== item.classification);

  return (
    <div
      draggable
      onDragStart={(event) => {
        event.dataTransfer.setData(DRAG_MIME, item.id);
        event.dataTransfer.effectAllowed = "move";
      }}
      className={cn(
        "group flex items-center gap-2 rounded-md border px-3 py-2.5",
        dark
          ? "border-white/15 bg-white/5"
          : "border-border bg-background hover:bg-secondary/50",
      )}
    >
      {!dark ? (
        <GripVertical
          className="size-4 shrink-0 cursor-grab text-muted-foreground"
          aria-hidden
        />
      ) : null}

      <p className="min-w-0 flex-1 truncate font-mono text-sm">
        <span
          className={cn(
            "font-semibold",
            sensitive && !dark
              ? "text-status-error-strong"
              : dark
                ? "text-white"
                : "text-foreground",
          )}
        >
          {item.key}
        </span>
        <span className={dark ? "text-white/40" : "text-muted-foreground"}>=</span>
        <span
          className={cn(
            dark ? "tracking-[0.2em] text-white/80" : "text-foreground",
          )}
        >
          {revealed ? item.value : MASKED_VALUE}
        </span>
      </p>

      {/* 드래그 못 하는 사용자를 위한 이동 버튼 — 포커스/호버 시 노출 */}
      <span className="flex shrink-0 items-center gap-1 opacity-0 transition-opacity group-focus-within:opacity-100 group-hover:opacity-100">
        {moveTargets.map(([zone, label]) => (
          <Button
            key={zone}
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => onMove(zone)}
            className={cn(
              "h-6 px-1.5 text-[11px]",
              dark && "text-white/70 hover:bg-white/10 hover:text-white",
            )}
          >
            {t.moveTo.replace("{zone}", label)}
          </Button>
        ))}
      </span>

      <button
        type="button"
        onClick={onToggleReveal}
        aria-label={(revealed ? t.hideValue : t.revealValue).replace(
          "{key}",
          item.key,
        )}
        className={cn(
          "shrink-0 rounded p-1 transition-colors",
          dark
            ? "text-white/60 hover:text-white"
            : "text-muted-foreground hover:text-foreground",
        )}
      >
        {revealed ? (
          <Eye className="size-4" aria-hidden />
        ) : (
          <EyeOff className="size-4" aria-hidden />
        )}
      </button>

      {onRemove ? (
        <button
          type="button"
          onClick={onRemove}
          aria-label={t.unclassify.replace("{key}", item.key)}
          className={cn(
            "shrink-0 rounded p-1 transition-colors",
            dark
              ? "text-white/60 hover:text-white"
              : "text-muted-foreground hover:text-foreground",
          )}
        >
          <X className="size-4" aria-hidden />
        </button>
      ) : null}

      {onDelete ? (
        <button
          type="button"
          onClick={onDelete}
          aria-label={t.deleteVariable.replace("{key}", item.key)}
          className={cn(
            "shrink-0 rounded p-1 transition-colors",
            dark
              ? "text-white/60 hover:text-white"
              : "text-muted-foreground hover:text-status-error",
          )}
        >
          <Trash2 className="size-4" aria-hidden />
        </button>
      ) : null}
    </div>
  );
}
