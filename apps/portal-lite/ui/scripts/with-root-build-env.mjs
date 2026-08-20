#!/usr/bin/env node
// 로컬 npm dev/build에서 저장소 루트의 공개 UI 환경만 상속한다.
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const uiRoot = resolve(scriptDirectory, "..");
const repositoryRoot = resolve(uiRoot, "../../..");
const envFile = process.env.PORTAL_UI_ROOT_ENV_FILE || resolve(repositoryRoot, ".env");
const allowedKeys = JSON.parse(
  readFileSync(resolve(scriptDirectory, "portal-ui-public-env-keys.json"), "utf8"),
);
const allowedKeySet = new Set(allowedKeys);
const [command, ...args] = process.argv.slice(2);

function fail(message) {
  console.error(`[FAIL] Portal UI 빌드 환경: ${message}`);
  process.exit(2);
}

function loadPublicEnv(path) {
  const raw = readFileSync(path);
  if (raw.length > 64 * 1024) fail("빌드 환경파일은 64 KiB를 넘을 수 없음");
  const text = raw.toString("utf8");
  const parsed = new Map();

  for (const [index, rawLine] of text.split(/\r?\n/u).entries()) {
    let line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("export ")) line = line.slice(7).trim();
    const separator = line.indexOf("=");
    const key = separator >= 0 ? line.slice(0, separator).trim() : "";
    let value = separator >= 0 ? line.slice(separator + 1).trim() : "";
    if (!/^[A-Z][A-Z0-9_]*$/u.test(key)) {
      fail(`line ${index + 1}: UPPER_CASE_KEY=value 형식이 필요함`);
    }
    if (parsed.has(key)) fail(`line ${index + 1}: 중복 key ${key}`);
    if (value.startsWith("\"") || value.startsWith("'")) {
      if (value.length < 2 || value.at(-1) !== value[0]) {
        fail(`line ${index + 1}: ${key} 따옴표가 닫히지 않음`);
      }
      value = value.slice(1, -1);
    }
    if (value.includes("\0") || value.includes("\r") || value.includes("\n")) {
      fail(`line ${index + 1}: ${key}에 제어 문자가 있음`);
    }
    if (value.length > 2048) fail(`line ${index + 1}: ${key} 값이 너무 김`);
    parsed.set(key, value);
  }

  const unknownPublic = [...parsed.keys()]
    .filter((key) => key.startsWith("NEXT_PUBLIC_") && !allowedKeySet.has(key))
    .sort();
  if (unknownPublic.length > 0) {
    fail(`허용되지 않은 Portal UI 공개 변수: ${unknownPublic.join(", ")}`);
  }
  for (const key of allowedKeys) {
    if (!parsed.has(key)) continue;
    const value = parsed.get(key);
    if (value.includes("$") || value.includes("`")) {
      fail(`${key}에는 변수/명령 치환 문자를 쓸 수 없음`);
    }
    process.env[key] = value;
  }
}

if (!command) fail("실행할 Portal UI 명령이 없음");

// Docker frontend에는 루트 .env가 복사되지 않는다. 그 경우 Dockerfile이 만든
// .env.production.local을 Next가 직접 읽으므로 래퍼는 아무 값도 추가하지 않는다.
if (existsSync(envFile)) loadPublicEnv(envFile);

const child = spawn(command, args, {
  cwd: uiRoot,
  env: process.env,
  stdio: "inherit",
});
child.on("error", (error) => {
  console.error(`[FAIL] Portal UI 명령을 실행할 수 없음: ${error.message}`);
  process.exit(127);
});
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
