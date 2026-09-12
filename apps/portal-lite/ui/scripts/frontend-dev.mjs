#!/usr/bin/env node

// 실제 Portal API 없이도 목록·상세·생성·상태 변경 화면을 함께 확인하기 위한 개발 전용 진입점이다.
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const uiRoot = resolve(scriptDirectory, "..");
if (process.env.NODE_ENV === "production") {
  console.error("[FAIL] 목 API는 개발 환경에서만 실행할 수 있습니다.");
  process.exit(1);
}

const apiOrigin = "http://127.0.0.1:8081";
const jsonHeaders = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};

const isoDaysAgo = (days, hours = 0) =>
  new Date(Date.now() - (days * 24 + hours) * 60 * 60 * 1000).toISOString();

const catalog = {
  environment: "development",
  baseDomain: "apps.example.test",
  forgejoConnected: true,
  submissionEnabled: true,
  projects: ["research", "data-platform", "sandbox"],
  resourcePresets: {
    small: {
      requests: { cpu: "100m", memory: "128Mi" },
      limits: { cpu: "500m", memory: "512Mi" },
    },
    medium: {
      requests: { cpu: "500m", memory: "512Mi" },
      limits: { cpu: "1", memory: "1Gi" },
    },
    large: {
      requests: { cpu: "1", memory: "1Gi" },
      limits: { cpu: "2", memory: "2Gi" },
    },
  },
  userQuota: { cpu: "8", memory: "16Gi" },
  maxReplicas: 5,
  zone: { id: "dev-zone", label: "development" },
  autoApprove: true,
  appGroups: { enabled: true, namespacePrefix: "app-", maxServices: 8 },
  services: [
    {
      id: "forgejo",
      name: "Forgejo",
      description: "소스 코드와 GitOps 변경 요청을 관리합니다.",
      url: "https://git.example.test",
      access: "sso",
      roles: ["developer", "platform-admin"],
      status: "available",
    },
    {
      id: "argocd",
      name: "Argo CD",
      description: "애플리케이션 배포 및 동기화 상태를 확인합니다.",
      url: "https://argocd.example.test",
      access: "sso",
      roles: ["developer", "platform-admin"],
      status: "available",
    },
    {
      id: "rancher",
      name: "Rancher",
      description: "클러스터와 워크로드를 관리합니다.",
      url: "https://rancher.example.test",
      access: "admin",
      roles: ["platform-admin"],
      status: "available",
    },
    {
      id: "docs",
      name: "개발자 문서",
      description: "플랫폼 사용법과 배포 가이드를 확인합니다.",
      url: "https://docs.example.test",
      access: "public",
      status: "available",
    },
  ],
};

let requests = [
  {
    id: "req-sample-running",
    state: "deployed",
    createdAt: isoDaysAgo(12),
    updatedAt: isoDaysAgo(1, 2),
    requester: "frontend-dev",
    message: "샘플 애플리케이션이 정상 배포되었습니다.",
    pullRequest: {
      number: 42,
      url: "https://git.example.test/platform/apps/pulls/42",
      branch: "deploy/sample-web",
      state: "merged",
    },
    profile: {
      app: { name: "sample-web", project: "research", environment: "development" },
      source: {
        repository: "https://git.example.test/research/sample-web.git",
        revision: "main",
        dockerfile: "Dockerfile",
      },
      service: {
        enabled: true,
        port: 3000,
        healthPath: "/healthz",
        internalAddress: "http://sample-web.development.svc.cluster.local:3000",
      },
      exposure: { mode: "external", host: "sample-web.apps.example.test" },
      authentication: { mode: "oidc" },
      networkPolicy: { egressMode: "web" },
      replicas: 2,
    },
    generated: { image: "registry.example.test/research/sample-web:dev" },
    security: {
      outcome: "passed",
      blockedSeverities: ["CRITICAL", "HIGH"],
      sourceCommit: "0123456789abcdef",
      findings: [],
      findingsTruncated: false,
    },
  },
  {
    id: "req-sample-api",
    state: "stopped",
    createdAt: isoDaysAgo(8),
    updatedAt: isoDaysAgo(2),
    requester: "frontend-dev",
    desiredRuntimeState: "stopped",
    profile: {
      app: { name: "sample-api", project: "data-platform", environment: "development" },
      source: {
        repository: "https://git.example.test/data-platform/sample-api.git",
        revision: "develop",
        dockerfile: "deploy/Dockerfile",
      },
      service: {
        enabled: true,
        port: 8080,
        healthPath: "/health",
        internalAddress: "http://sample-api.development.svc.cluster.local:8080",
      },
      exposure: { mode: "internal" },
      authentication: { mode: "none" },
      networkPolicy: { egressMode: "blocked" },
      replicas: 1,
    },
  },
  {
    id: "req-sample-worker",
    state: "pr_open",
    createdAt: isoDaysAgo(0, 3),
    updatedAt: isoDaysAgo(0, 2),
    requester: "frontend-dev",
    message: "GitOps 변경 검토를 기다리고 있습니다.",
    profile: {
      app: {
        name: "event-worker",
        project: "sandbox",
        environment: "development",
        group: "analytics",
      },
      source: {
        repository: "https://git.example.test/sandbox/analytics.git",
        revision: "main",
        dockerfile: "worker/Dockerfile",
      },
      service: { enabled: false },
      exposure: { mode: "internal" },
      authentication: { mode: "none" },
      networkPolicy: { egressMode: "custom" },
      replicas: 1,
    },
  },
];

function send(response, status, body, contentType = jsonHeaders["content-type"]) {
  response.writeHead(status, { ...jsonHeaders, "content-type": contentType });
  response.end(JSON.stringify(body));
}

function problem(response, status, title, detail) {
  send(response, status, { type: "about:blank", title, status, detail }, "application/problem+json");
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 64 * 1024) throw Object.assign(new Error("request body too large"), { status: 413 });
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function requesterOf(request) {
  return String(request.headers["x-portal-user"] ?? "frontend-dev").trim();
}

function visibleRequests(request) {
  const requester = requesterOf(request);
  return requests.filter((item) => item.requester === requester);
}

function composeServiceNames(compose) {
  const lines = String(compose ?? "").split(/\r?\n/u);
  const names = [];
  let inServices = false;
  for (const line of lines) {
    if (/^services:\s*(?:#.*)?$/u.test(line)) {
      inServices = true;
      continue;
    }
    if (!inServices) continue;
    if (/^[^\s#]/u.test(line)) break;
    const match = line.match(/^ {2}([a-zA-Z0-9][a-zA-Z0-9_-]*):\s*(?:#.*)?$/u);
    if (match) names.push(match[1]);
  }
  return names;
}

function appGroupPlan(input) {
  const group = String(input.group || "sample-group");
  const serviceInputs = Array.isArray(input.services) ? input.services : [];
  const names = [...new Set([
    ...composeServiceNames(input.compose),
    ...serviceInputs.map((item) => item?.name).filter(Boolean),
  ])];
  const effectiveNames = names.length > 0 ? names : ["web", "api"];
  return {
    group: { name: group, namespace: `app-${group}` },
    source: input.repository
      ? { type: "git", repository: input.repository, revision: input.repositoryRevision || "main" }
      : { type: "compose" },
    warnings: ["개발용 목 API가 만든 미리보기이며 클러스터에는 반영되지 않습니다."],
    services: effectiveNames.map((name, index) => {
      const override = serviceInputs.find((item) => item?.name === name) ?? {};
      const mode = override.exposure?.mode ?? (index === 0 ? "external" : "internal");
      return {
        profile: {
          app: { name },
          service: { enabled: true, port: index === 0 ? 3000 : 8080 },
          exposure: {
            mode,
            ...(mode === "external" ? { host: `${name}.apps.example.test` } : {}),
          },
          authentication: { mode: override.authentication?.mode ?? "none" },
          networkPolicy: { egressMode: override.networkPolicy?.egressMode ?? "blocked" },
          source: { image: `registry.example.test/sandbox/${name}:dev` },
        },
      };
    }),
  };
}

async function handle(request, response) {
  const url = new URL(request.url ?? "/", apiOrigin);
  const path = url.pathname;

  if (request.method === "GET" && (path === "/api/v1/health" || path === "/healthz")) {
    return send(response, 200, { status: "ok" });
  }
  if (request.method === "GET" && path === "/api/v1/catalog") {
    return send(response, 200, catalog);
  }
  if (request.method === "GET" && path === "/api/v1/quota-usage") {
    return send(response, 200, {
      requester: requesterOf(request),
      limit: { cpu: "8", memory: "16Gi" },
      limitCpuMilli: 8000,
      limitMemoryBytes: 16 * 1024 ** 3,
      used: { cpu: "2.4", memory: "6.5Gi" },
      usedCpuMilli: 2400,
      usedMemoryBytes: Math.round(6.5 * 1024 ** 3),
      applications: visibleRequests(request).length,
      pods: 4,
    });
  }
  if (request.method === "GET" && path === "/api/v1/deployment-requests") {
    const limit = Math.max(0, Number(url.searchParams.get("limit")) || requests.length);
    const items = visibleRequests(request).slice(0, limit);
    return send(response, 200, { items, count: items.length, limit, requester: requesterOf(request) });
  }

  const detailMatch = path.match(/^\/api\/v1\/deployment-requests\/([^/]+)$/u);
  if (detailMatch && request.method === "GET") {
    const item = visibleRequests(request).find(({ id }) => id === decodeURIComponent(detailMatch[1]));
    return item
      ? send(response, 200, item)
      : problem(response, 404, "신청 없음", "해당 샘플 배포 신청을 찾을 수 없습니다.");
  }

  if (path === "/api/v1/deployment-requests" && request.method === "POST") {
    const input = await readJson(request);
    const now = new Date().toISOString();
    const id = `req-dev-${randomUUID()}`;
    const host = input.exposure?.mode === "external"
      ? `${input.appName}.apps.example.test`
      : "";
    const created = {
      id,
      state: "pr_open",
      createdAt: now,
      updatedAt: now,
      requester: requesterOf(request),
      message: "개발용 목 API가 배포 신청을 만들었습니다.",
      profile: {
        app: {
          name: input.appName,
          project: input.project,
          environment: input.environment,
          ...(input.group ? { group: input.group } : {}),
        },
        source: {
          repository: input.gitRepository,
          revision: input.branch,
          dockerfile: input.dockerfile,
        },
        service: {
          enabled: true,
          port: input.containerPort,
          internalAddress: `http://${input.appName}.development.svc.cluster.local:${input.containerPort}`,
        },
        exposure: { mode: input.exposure?.mode, ...(host ? { host } : {}) },
        authentication: input.authentication,
        networkPolicy: input.networkPolicy,
        replicas: input.replicas,
      },
    };
    requests = [created, ...requests];
    return send(response, 201, created);
  }

  if (detailMatch && request.method === "DELETE") {
    const id = decodeURIComponent(detailMatch[1]);
    const index = requests.findIndex((item) => item.id === id && item.requester === requesterOf(request));
    if (index < 0) return problem(response, 404, "신청 없음", "삭제할 샘플 신청이 없습니다.");
    requests[index] = { ...requests[index], state: "deleting", updatedAt: new Date().toISOString() };
    return send(response, 200, requests[index]);
  }

  const runtimeMatch = path.match(/^\/api\/v1\/deployment-requests\/([^/]+)\/runtime-state$/u);
  if (runtimeMatch && request.method === "PUT") {
    const input = await readJson(request);
    const id = decodeURIComponent(runtimeMatch[1]);
    const index = requests.findIndex((item) => item.id === id && item.requester === requesterOf(request));
    if (index < 0) return problem(response, 404, "신청 없음", "변경할 샘플 신청이 없습니다.");
    if (!["stopped", "running"].includes(input.state)) {
      return problem(response, 422, "상태 오류", "running 또는 stopped 상태가 필요합니다.");
    }
    const desiredRuntimeState = input.state;
    requests[index] = {
      ...requests[index],
      state: desiredRuntimeState === "stopped" ? "stopped" : "deployed",
      desiredRuntimeState,
      updatedAt: new Date().toISOString(),
    };
    return send(response, 200, requests[index]);
  }

  if (path === "/api/v1/app-groups/validate" && request.method === "POST") {
    return send(response, 200, appGroupPlan(await readJson(request)));
  }
  if (path === "/api/v1/app-groups" && request.method === "POST") {
    const input = await readJson(request);
    const plan = appGroupPlan(input);
    return send(response, 201, {
      group: plan.group,
      count: plan.services.length,
    });
  }

  return problem(response, 404, "목 API 경로 없음", `${request.method} ${path} 응답이 없습니다.`);
}

const server = createServer((request, response) => {
  handle(request, response).catch((error) => {
    console.error("[mock-api] 요청 처리 실패:", error instanceof Error ? error.message : error);
    if (!response.headersSent) problem(response, error.status ?? (error instanceof SyntaxError ? 400 : 500), "목 API 오류", "샘플 요청을 처리하지 못했습니다.");
    else response.end();
  });
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.error(`[FAIL] ${apiOrigin} 포트를 이미 사용 중입니다.`);
  } else {
    console.error("[FAIL] 목 API를 시작할 수 없습니다:", error.message);
  }
  process.exit(1);
});

server.listen(8081, "127.0.0.1", () => {
  console.log(`[frontend-dev] 샘플 Portal API: ${apiOrigin}`);
  console.log("[frontend-dev] 로그인 사용자: frontend-dev");

  const child = spawn(
    process.execPath,
    [resolve(scriptDirectory, "with-root-build-env.mjs"), process.execPath,
      resolve(uiRoot, "node_modules/next/dist/bin/next"), "dev",
      "--hostname", "127.0.0.1", ...process.argv.slice(2)],
    {
      cwd: uiRoot,
      detached: process.platform !== "win32",
      env: {
        ...process.env,
        NODE_ENV: "development",
        AUTH_TRUST_HOST: "true",
        // Auth.js가 우회 세션 판정 전에 provider 설정을 검사하므로 실제 자격증명이 아닌 로컬 전용 값을 준다.
        AUTH_SECRET: "frontend-dev-only-not-a-deployment-secret",
        AUTH_OIDC_ID: "frontend-dev",
        AUTH_OIDC_SECRET: "frontend-dev-only-not-a-client-secret",
        AUTH_OIDC_ISSUER: "https://sso.example.test/realms/frontend-dev",
        PAAS_DEV_AUTH_BYPASS: "true",
        PAAS_DEV_USER: "frontend-dev",
        PAAS_DEV_ROLES: "platform-admin,developer,viewer,deployments:read,deployments:write",
      },
      stdio: "inherit",
    },
  );

  const shutdown = (signal) => {
    // 래퍼와 Next 자식까지 종료해야 재실행할 때 포트가 남지 않는다.
    try {
      if (process.platform !== "win32") process.kill(-child.pid, signal);
      else child.kill(signal);
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
    server.close();
    server.closeAllConnections();
  };
  process.once("SIGINT", () => shutdown("SIGINT"));
  process.once("SIGTERM", () => shutdown("SIGTERM"));
  child.once("error", (error) => {
    console.error(`[FAIL] Next 개발 서버를 시작할 수 없습니다: ${error.message}`);
    server.close(() => process.exit(127));
  });
  child.once("exit", (code, signal) => {
    server.close(() => {
      process.exit(code ?? (signal === "SIGINT" ? 130 : 143));
    });
  });
});
