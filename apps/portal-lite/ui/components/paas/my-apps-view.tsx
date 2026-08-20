"use client";

import {
  ChevronLeft,
  ChevronRight,
  LayoutGrid,
  List,
  PackageOpen,
  Search,
} from "lucide-react";
import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import * as React from "react";

import { AppCard } from "@/components/paas/app-card";
import { AppGroupCard } from "@/components/paas/app-group-card";
import { EmptyState } from "@/components/paas/empty-state";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { useI18n } from "@/lib/i18n/context";
import {
  filterApplicationList,
  groupApplicationList,
} from "@/lib/application-list";
import { cn } from "@/lib/utils";
import type { DataSource } from "@/lib/paas-api";
import type { Application } from "@/types/domain";

const PAGE_SIZE = 4;

/**
 * 필터/검색/뷰 모드/페이지는 전부 URL 쿼리에 보관한다.
 * 새로고침·뒤로가기·링크 공유에서 동일한 목록이 재현되도록 하기 위함.
 */
export function MyAppsView({
  applications,
  source = "unavailable",
}: {
  applications: Application[];
  /** 실제 API 응답인지 여부. 빈 목록의 사유(신규 사용자 / API 장애)를 가른다. */
  source?: DataSource;
}) {
  const { dict } = useI18n();
  const t = dict.myApps;
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();

  const query = searchParams.get("q") ?? "";
  const project = searchParams.get("project") ?? "all";
  const status = searchParams.get("status") ?? "all";
  const view = searchParams.get("view") === "list" ? "list" : "grid";
  const page = Math.max(1, Number(searchParams.get("page") ?? "1") || 1);

  const setParams = React.useCallback(
    (next: Record<string, string | null>) => {
      const params = new URLSearchParams(searchParams.toString());
      for (const [key, value] of Object.entries(next)) {
        if (value === null || value === "" || value === "all") {
          params.delete(key);
        } else {
          params.set(key, value);
        }
      }
      const qs = params.toString();
      router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
    },
    [pathname, router, searchParams],
  );

  const projects = React.useMemo(
    () => [...new Set(applications.map((app) => app.project))].sort(),
    [applications],
  );

  const listItems = React.useMemo(
    () => groupApplicationList(applications),
    [applications],
  );

  const filtered = React.useMemo(() => {
    return filterApplicationList(listItems, { query, project, status });
  }, [listItems, query, project, status]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const visible = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  return (
    <div className="space-y-6">
      {/* 필터 바 */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <div className="relative w-full sm:max-w-xs">
          <Search
            className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
            aria-hidden
          />
          <Input
            value={query}
            onChange={(event) =>
              setParams({ q: event.target.value, page: null })
            }
            placeholder={t.filters.searchPlaceholder}
            aria-label={t.filters.searchLabel}
            className="pl-9"
          />
        </div>

        <Select
          value={project}
          onValueChange={(value) => setParams({ project: value, page: null })}
        >
          <SelectTrigger
            className="w-full sm:w-48"
            aria-label={t.filters.projectLabel}
          >
            <SelectValue placeholder={t.filters.allProjects} />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">{t.filters.allProjects}</SelectItem>
            {projects.map((name) => (
              <SelectItem key={name} value={name}>
                {name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        <Select
          value={status}
          onValueChange={(value) => setParams({ status: value, page: null })}
        >
          <SelectTrigger
            className="w-full sm:w-40"
            aria-label={t.filters.statusLabel}
          >
            <SelectValue placeholder={t.filters.allStatuses} />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">{t.filters.allStatuses}</SelectItem>
            <SelectItem value="RUNNING">RUNNING</SelectItem>
            <SelectItem value="STOPPED">STOPPED</SelectItem>
            <SelectItem value="PENDING">PENDING</SelectItem>
            <SelectItem value="FAILED">FAILED</SelectItem>
          </SelectContent>
        </Select>

        <ToggleGroup
          type="single"
          value={view}
          onValueChange={(value) => value && setParams({ view: value })}
          variant="outline"
          className="sm:ml-auto"
        >
          <ToggleGroupItem value="grid" aria-label={t.filters.gridView}>
            <LayoutGrid className="size-4" aria-hidden />
          </ToggleGroupItem>
          <ToggleGroupItem value="list" aria-label={t.filters.listView}>
            <List className="size-4" aria-hidden />
          </ToggleGroupItem>
        </ToggleGroup>
      </div>

      {/* 목록 */}
      {visible.length === 0 ? (
        source === "unavailable" ? (
          <EmptyState
            icon={PackageOpen}
            title={t.empty.errorTitle}
            description={t.empty.errorDescription}
          />
        ) : applications.length === 0 ? (
          /* 필터 문제가 아니라 애초에 신청 이력이 없는 신규 사용자. */
          <EmptyState
            icon={PackageOpen}
            title={t.empty.noneTitle}
            description={t.empty.noneDescription}
            action={
              <Button asChild>
                <Link href="/new-app/1">{t.empty.noneAction}</Link>
              </Button>
            }
          />
        ) : (
          <EmptyState
            icon={PackageOpen}
            title={t.empty.title}
            description={t.empty.description}
            action={
              <Button
                variant="outline"
                onClick={() =>
                  setParams({
                    q: null,
                    project: null,
                    status: null,
                    page: null,
                  })
                }
              >
                {t.empty.resetFilters}
              </Button>
            }
          />
        )
      ) : (
        <div
          className={cn(
            "grid gap-5",
            view === "grid" ? "md:grid-cols-2" : "grid-cols-1",
          )}
        >
          {visible.map((item) =>
            item.kind === "group" ? (
              <AppGroupCard key={item.id} group={item} view={view} />
            ) : (
              <AppCard
                key={item.id}
                app={item.application}
                view={view}
              />
            ),
          )}
        </div>
      )}

      {/* 페이지네이션 */}
      <nav
        className="flex items-center justify-end gap-2"
        aria-label={t.pagination.label}
      >
        <Button
          variant="outline"
          size="icon"
          aria-label={t.pagination.previous}
          disabled={currentPage <= 1}
          onClick={() => setParams({ page: String(currentPage - 1) })}
        >
          <ChevronLeft className="size-4" aria-hidden />
        </Button>
        <span className="min-w-8 text-center font-mono text-sm">
          {currentPage}
        </span>
        <Button
          variant="outline"
          size="icon"
          aria-label={t.pagination.next}
          disabled={currentPage >= pageCount}
          onClick={() => setParams({ page: String(currentPage + 1) })}
        >
          <ChevronRight className="size-4" aria-hidden />
        </Button>
      </nav>
    </div>
  );
}
