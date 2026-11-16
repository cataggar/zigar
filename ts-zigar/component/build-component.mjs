#!/usr/bin/env node
/**
 * Reproducible staged builder for `typescript-compiler.component.wasm`
 * (`package zigar:typescript@7.1.0; world typescript-compiler`).
 *
 * Why staging is required:
 *   Upstream `microsoft/TypeScript/tsc` places all Go compiler packages under
 *   `tsc/internal/...`, so Go module visibility rules prohibit importing them
 *   from an external Go module. This script maintains a shallow, commit-pinned
 *   cache of `microsoft/TypeScript`, stages `./tsc` into an isolated build
 *   directory without mutating the cached upstream checkout, generates Go WIT
 *   bindings via `componentize-go`, overlays `ts-zigar/component/adapter/`, and
 *   produces `ts-zigar/component/dist/typescript-compiler.component.wasm`.
 */

import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const TYPESCRIPT_REPO_URL = "https://github.com/microsoft/TypeScript.git";
export const TYPESCRIPT_PINNED_COMMIT = "6bdcb54d23f41bc7098c1f3488ac599c75b852ca";
export const WIT_WORLD = "typescript-compiler";
export const WIT_GO_PKG = "github.com/microsoft/TypeScript/tsc/internal/zigarwit";
export const WIT_RUNTIME_MOD = "go.bytecodealliance.org/pkg";
export const WIT_RUNTIME_VER = "v0.4.1";

const tsZigarDir = path.resolve(__dirname, "..");
const repoRoot = path.resolve(tsZigarDir, "..");
const witDir = path.join(tsZigarDir, "wit");
const adapterDir = path.join(__dirname, "adapter");
const defaultOutputWasm = path.join(__dirname, "dist", "typescript-compiler.component.wasm");

function resolveCacheDir() {
  const fromEnv = process.env.TS_ZIGAR_CACHE_DIR?.trim();
  if (fromEnv) {
    return path.resolve(fromEnv);
  }
  if (fs.existsSync("/d/zigar-worktrees")) {
    return "/d/zigar-worktrees/.cache/ts-zigar";
  }
  const tmpDir = process.env.TMPDIR?.trim();
  if (tmpDir && !tmpDir.startsWith("/tmp") && !tmpDir.startsWith("/var/tmp")) {
    return path.resolve(tmpDir, "ts-zigar-cache");
  }
  return path.join(repoRoot, ".cache", "ts-zigar");
}

function buildIsolatedEnv(cacheDir) {
  const localCacheRoot = path.join(repoRoot, ".cache");
  const env = { ...process.env };

  if (!env.GOCACHE) env.GOCACHE = path.join(localCacheRoot, "go-build");
  if (!env.GOMODCACHE) env.GOMODCACHE = path.join(localCacheRoot, "go-mod");
  if (!env.GOPATH) env.GOPATH = path.join(localCacheRoot, "gopath");
  if (!env.GOENV) env.GOENV = path.join(localCacheRoot, "go-env");
  if (!env.XDG_CACHE_HOME) env.XDG_CACHE_HOME = path.join(localCacheRoot, "xdg");
  if (!env.TMPDIR || env.TMPDIR.startsWith("/tmp") || env.TMPDIR.startsWith("/var/tmp")) {
    env.TMPDIR = path.join(localCacheRoot, "tmp");
  }
  env.TS_ZIGAR_CACHE_DIR = cacheDir;

  for (const dir of [env.GOCACHE, env.GOMODCACHE, env.GOPATH, path.dirname(env.GOENV), env.XDG_CACHE_HOME, env.TMPDIR, cacheDir]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  return env;
}

function run(cmd, args, options = {}) {
  return execFileSync(cmd, args, {
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
    encoding: "utf8",
    ...options,
  });
}

function ensureUpstreamTypeScriptCheckout(cacheDir, env) {
  const checkoutDir = path.join(cacheDir, `microsoft-typescript-${TYPESCRIPT_PINNED_COMMIT}`);
  const tscGoMod = path.join(checkoutDir, "tsc", "go.mod");

  if (fs.existsSync(tscGoMod)) {
    try {
      const head = run("git", ["rev-parse", "HEAD"], {
        cwd: checkoutDir,
        env,
        capture: true,
      }).trim();
      if (head === TYPESCRIPT_PINNED_COMMIT) {
        return checkoutDir;
      }
    } catch {
      // Re-fetch below if checkout is incomplete.
    }
  }

  console.log(`[ts-zigar] Fetching microsoft/TypeScript @ ${TYPESCRIPT_PINNED_COMMIT.slice(0, 12)} into ${checkoutDir}`);
  fs.mkdirSync(checkoutDir, { recursive: true });
  if (!fs.existsSync(path.join(checkoutDir, ".git"))) {
    run("git", ["init", "-q"], { cwd: checkoutDir, env });
  }
  const remotes = run("git", ["remote"], { cwd: checkoutDir, env, capture: true }).split(/\s+/).filter(Boolean);
  if (remotes.includes("origin")) {
    run("git", ["remote", "set-url", "origin", TYPESCRIPT_REPO_URL], { cwd: checkoutDir, env });
  } else {
    run("git", ["remote", "add", "origin", TYPESCRIPT_REPO_URL], { cwd: checkoutDir, env });
  }
  run("git", ["fetch", "--depth", "1", "origin", TYPESCRIPT_PINNED_COMMIT], { cwd: checkoutDir, env });
  run("git", ["checkout", "-q", "--detach", "FETCH_HEAD"], { cwd: checkoutDir, env });

  if (!fs.existsSync(tscGoMod)) {
    throw new Error(`Expected ${tscGoMod} in microsoft/TypeScript @ ${TYPESCRIPT_PINNED_COMMIT}`);
  }
  return checkoutDir;
}

function syncStageTree(upstreamCheckoutDir, stageRootDir) {
  const upstreamTsc = path.join(upstreamCheckoutDir, "tsc");
  const stagedTsc = path.join(stageRootDir, "tsc");
  const markerFile = path.join(stageRootDir, ".upstream-commit");

  const currentMarker = fs.existsSync(markerFile) ? fs.readFileSync(markerFile, "utf8").trim() : "";
  if (currentMarker !== TYPESCRIPT_PINNED_COMMIT || !fs.existsSync(path.join(stagedTsc, "go.mod"))) {
    fs.rmSync(stageRootDir, { recursive: true, force: true });
    fs.mkdirSync(stageRootDir, { recursive: true });
    try {
      fs.cpSync(upstreamTsc, stagedTsc, {
        recursive: true,
        force: true,
        mode: fs.constants.COPYFILE_FICLONE,
      });
    } catch {
      fs.cpSync(upstreamTsc, stagedTsc, { recursive: true, force: true });
    }
    fs.writeFileSync(markerFile, `${TYPESCRIPT_PINNED_COMMIT}\n`, "utf8");
  }

  // Always recreate the generated WIT bindings and adapter overlay cleanly so
  // edits to `ts-zigar/wit/typescript.wit` or `ts-zigar/component/adapter/` take effect.
  const zigarWitDir = path.join(stagedTsc, "internal", "zigarwit");
  const cmdDir = path.join(stagedTsc, "cmd", "zigar-ts-component");
  fs.rmSync(zigarWitDir, { recursive: true, force: true });
  fs.rmSync(cmdDir, { recursive: true, force: true });

  return { stagedTsc, zigarWitDir, cmdDir };
}

function copyGoFiles(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith(".go")) {
      fs.copyFileSync(path.join(srcDir, entry.name), path.join(destDir, entry.name));
    }
  }
}

function ensureWitRuntimeDependency(stagedTsc, env) {
  const goModPath = path.join(stagedTsc, "go.mod");
  const goSumPath = path.join(stagedTsc, "go.sum");
  const goModText = fs.readFileSync(goModPath, "utf8");
  const goSumText = fs.existsSync(goSumPath) ? fs.readFileSync(goSumPath, "utf8") : "";
  if (!goModText.includes(WIT_RUNTIME_MOD) || !goSumText.includes(WIT_RUNTIME_MOD)) {
    run("go", ["get", `${WIT_RUNTIME_MOD}@${WIT_RUNTIME_VER}`], { cwd: stagedTsc, env });
  }
}

function parseCliArgs(argv) {
  let outputPath = defaultOutputWasm;
  let forceRebuild = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-o" || arg === "--output") {
      outputPath = path.resolve(argv[++i]);
    } else if (arg === "--force") {
      forceRebuild = true;
    } else if (arg === "--help" || arg === "-h") {
      console.log("Usage: node build-component.mjs [-o <output.wasm>] [--force]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return { outputPath, forceRebuild };
}

function latestMtimeMs(targetPath) {
  const st = fs.statSync(targetPath);
  if (!st.isDirectory()) return st.mtimeMs;
  let maxMtime = st.mtimeMs;
  for (const entry of fs.readdirSync(targetPath, { withFileTypes: true })) {
    const childMtime = latestMtimeMs(path.join(targetPath, entry.name));
    if (childMtime > maxMtime) maxMtime = childMtime;
  }
  return maxMtime;
}

function isComponentUpToDate(outputPath) {
  if (!fs.existsSync(outputPath)) return false;
  const stampPath = `${outputPath}.stamp`;
  if (!fs.existsSync(stampPath)) return false;
  if (fs.readFileSync(stampPath, "utf8").trim() !== TYPESCRIPT_PINNED_COMMIT) {
    return false;
  }
  const outMtime = fs.statSync(outputPath).mtimeMs;
  const inputsMaxMtime = Math.max(
    latestMtimeMs(__filename),
    latestMtimeMs(witDir),
    latestMtimeMs(adapterDir),
  );
  return outMtime >= inputsMaxMtime;
}

export function buildComponent({ outputPath = defaultOutputWasm, forceRebuild = false } = {}) {
  if (!forceRebuild && isComponentUpToDate(outputPath)) {
    return outputPath;
  }

  const cacheDir = resolveCacheDir();
  const env = buildIsolatedEnv(cacheDir);
  const upstreamCheckoutDir = ensureUpstreamTypeScriptCheckout(cacheDir, env);

  const worktreeHash = crypto.createHash("sha256").update(__dirname).digest("hex").slice(0, 10);
  const stageRootDir = path.join(
    cacheDir,
    `stage-${TYPESCRIPT_PINNED_COMMIT.slice(0, 12)}-${worktreeHash}`,
  );
  if (forceRebuild) {
    fs.rmSync(stageRootDir, { recursive: true, force: true });
  }
  const { stagedTsc, zigarWitDir, cmdDir } = syncStageTree(upstreamCheckoutDir, stageRootDir);

  console.log(`[ts-zigar] Generating Go WIT bindings for world '${WIT_WORLD}'...`);
  run(
    "componentize-go",
    [
      "-d",
      witDir,
      "-w",
      WIT_WORLD,
      "--ignore-toml-files",
      "bindings",
      "--format",
      "--pkg-name",
      WIT_GO_PKG,
      "-o",
      zigarWitDir,
    ],
    { cwd: stagedTsc, env },
  );

  // Overlay our Go adapter implementations onto the generated WIT export packages.
  copyGoFiles(
    path.join(adapterDir, "cmd", "zigar-ts-component"),
    cmdDir,
  );
  copyGoFiles(
    path.join(adapterDir, "compiler"),
    path.join(zigarWitDir, "exports", "export_zigar_typescript_compiler"),
  );
  copyGoFiles(
    path.join(adapterDir, "extractor"),
    path.join(zigarWitDir, "exports", "export_zigar_typescript_extractor"),
  );

  ensureWitRuntimeDependency(stagedTsc, env);

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  console.log(`[ts-zigar] Building WASM Component -> ${outputPath}`);
  run(
    "componentize-go",
    [
      "-d",
      witDir,
      "-w",
      WIT_WORLD,
      "--ignore-toml-files",
      "build",
      "-o",
      outputPath,
    ],
    { cwd: cmdDir, env },
  );

  fs.writeFileSync(`${outputPath}.stamp`, `${TYPESCRIPT_PINNED_COMMIT}\n`, "utf8");
  const stat = fs.statSync(outputPath);
  console.log(`[ts-zigar] Built ${outputPath} (${(stat.size / (1024 * 1024)).toFixed(2)} MiB)`);
  return outputPath;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  const opts = parseCliArgs(process.argv.slice(2));
  buildComponent(opts);
}
