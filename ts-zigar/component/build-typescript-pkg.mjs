#!/usr/bin/env node
/**
 * Reproducible staged builder for TypeScript 7.1's published npm package layout
 * (`node_modules/typescript` + `node_modules/@typescript/typescript-<os>-<arch>`),
 * built directly from the pinned `microsoft/TypeScript` commit used by
 * `build-component.mjs` without mutating the cached upstream checkout.
 *
 * Produces:
 *   - `<outDir>/node_modules/typescript` (`dist/*.d.ts`, `dist/*.js`, `enums/*.d.ts`, `package.json`)
 *   - `<outDir>/node_modules/@typescript/typescript-<platform>-<arch>/lib/tsc` (native Go API server)
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { TYPESCRIPT_PINNED_COMMIT, TYPESCRIPT_REPO_URL } from "./build-component.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const tsZigarDir = path.resolve(__dirname, "..");
const repoRoot = path.resolve(tsZigarDir, "..");

function resolveCacheDir() {
  const fromEnv = process.env.TS_ZIGAR_CACHE_DIR?.trim();
  if (fromEnv) return path.resolve(fromEnv);
  const siblingWorktreeCache = path.resolve(repoRoot, "..", ".cache", "ts-zigar");
  if (fs.existsSync(siblingWorktreeCache)) return siblingWorktreeCache;
  return path.join(repoRoot, ".cache", "ts-zigar");
}

function resolveDefaultOutRoot(cacheDir) {
  const fromEnv = process.env.TS_ZIGAR_TYPESCRIPT_PKG?.trim();
  if (fromEnv) {
    const resolved = path.resolve(fromEnv);
    const norm = resolved.replace(/\\/g, "/").replace(/\/+$/, "");
    if (norm.endsWith("/node_modules/typescript")) {
      return path.resolve(resolved, "../..");
    }
    return resolved;
  }
  return path.join(cacheDir, "typescript-71-pkg");
}

function buildIsolatedEnv(cacheDir) {
  const localCacheRoot = path.join(repoRoot, ".cache");
  const env = { ...process.env };
  if (!env.GOCACHE) env.GOCACHE = path.join(localCacheRoot, "go-build");
  if (!env.GOMODCACHE) env.GOMODCACHE = path.join(localCacheRoot, "go-mod");
  if (!env.GOPATH) env.GOPATH = path.join(localCacheRoot, "gopath");
  if (!env.GOENV) env.GOENV = path.join(localCacheRoot, "go-env");
  if (!env.NPM_CONFIG_CACHE) env.NPM_CONFIG_CACHE = path.join(localCacheRoot, "npm");
  if (!env.TMPDIR || env.TMPDIR.startsWith("/tmp") || env.TMPDIR.startsWith("/var/tmp")) {
    env.TMPDIR = path.join(localCacheRoot, "tmp");
  }
  env.TS_ZIGAR_CACHE_DIR = cacheDir;
  for (const dir of [env.GOCACHE, env.GOMODCACHE, env.GOPATH, path.dirname(env.GOENV), env.NPM_CONFIG_CACHE, env.TMPDIR, cacheDir]) {
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

function ensureUpstreamCheckout(cacheDir, env) {
  const checkoutDir = path.join(cacheDir, `microsoft-typescript-${TYPESCRIPT_PINNED_COMMIT}`);
  const tscGoMod = path.join(checkoutDir, "tsc", "go.mod");
  if (fs.existsSync(tscGoMod)) {
    try {
      const head = run("git", ["rev-parse", "HEAD"], { cwd: checkoutDir, env, capture: true }).trim();
      if (head === TYPESCRIPT_PINNED_COMMIT) return checkoutDir;
    } catch {
      // Re-fetch below.
    }
  }
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
  return checkoutDir;
}

function ensureTypesNode(cacheDir, env) {
  const typesNodeRoot = path.join(cacheDir, "types-node26");
  const typesNodePkg = path.join(typesNodeRoot, "node_modules", "@types", "node", "package.json");
  if (fs.existsSync(typesNodePkg)) {
    return path.join(typesNodeRoot, "node_modules");
  }
  fs.mkdirSync(typesNodeRoot, { recursive: true });
  fs.writeFileSync(
    path.join(typesNodeRoot, "package.json"),
    JSON.stringify({ name: "ts-zigar-types-node-cache", private: true }, null, 2) + "\n",
  );
  run("npm", ["install", "--no-audit", "--no-fund", "@types/node@26"], { cwd: typesNodeRoot, env });
  return path.join(typesNodeRoot, "node_modules");
}

function stripConditionsFromValue(value) {
  if (value == null || typeof value !== "object") return value;
  delete value["@typescript/source"];
  for (const key of Object.keys(value)) {
    value[key] = stripConditionsFromValue(value[key]);
  }
  const keys = Object.keys(value);
  if (keys.length === 1 && keys[0] === "default") {
    return value["default"];
  }
  return value;
}

function createPublishedPackageJson(rawPkg, platformPkgName, version) {
  const pkg = structuredClone(rawPkg);
  pkg.name = "typescript";
  pkg.version = version;
  delete pkg.private;
  delete pkg.scripts;
  delete pkg.devDependencies;
  for (const field of ["exports", "imports"]) {
    if (pkg[field] != null && typeof pkg[field] === "object") {
      pkg[field] = stripConditionsFromValue(pkg[field]);
    }
  }
  pkg.optionalDependencies = {
    [platformPkgName]: version,
  };
  pkg.gitHead = TYPESCRIPT_PINNED_COMMIT;
  return pkg;
}

export function buildTypeScript71Package(options = {}) {
  const cacheDir = options.cacheDir ?? resolveCacheDir();
  const env = buildIsolatedEnv(cacheDir);
  const outRoot = path.resolve(
    options.outDir ?? resolveDefaultOutRoot(cacheDir),
  );

  const exeSuffix = process.platform === "win32" ? ".exe" : "";
  const platformPkgShort = `typescript-${process.platform}-${process.arch}`;
  const platformPkgName = `@typescript/${platformPkgShort}`;
  const mainPkgDir = path.join(outRoot, "node_modules", "typescript");
  const platformPkgDir = path.join(outRoot, "node_modules", "@typescript", platformPkgShort);
  const tscExe = path.join(platformPkgDir, "lib", `tsc${exeSuffix}`);
  const stampFile = path.join(outRoot, ".stamp");
  const expectedStamp = `${TYPESCRIPT_PINNED_COMMIT}:${process.platform}:${process.arch}:v1`;

  if (
    !options.force &&
    fs.existsSync(stampFile) &&
    fs.readFileSync(stampFile, "utf8").trim() === expectedStamp &&
    fs.existsSync(path.join(mainPkgDir, "dist", "api", "sync", "api.d.ts")) &&
    fs.existsSync(tscExe)
  ) {
    return { outRoot, mainPkgDir, platformPkgDir, tscExe };
  }

  const upstreamDir = ensureUpstreamCheckout(cacheDir, env);
  const typesNodeModules = ensureTypesNode(cacheDir, env);
  const version = "7.1.0-dev";

  // 1. Build native Go `tsc` binary (with embedded `lib.*.d.ts`) into `@typescript/typescript-<os>-<arch>/lib/tsc`.
  fs.mkdirSync(path.join(platformPkgDir, "lib"), { recursive: true });
  fs.writeFileSync(
    path.join(platformPkgDir, "package.json"),
    JSON.stringify(
      {
        name: platformPkgName,
        version,
        os: [process.platform],
        cpu: [process.arch],
      },
      null,
      2,
    ) + "\n",
  );
  console.log(`[ts-zigar] Building TypeScript 7.1 native server (${tscExe})...`);
  run("go", ["build", "-trimpath", "-ldflags=-s -w", "-o", tscExe, "./cmd/tsc"], {
    cwd: path.join(upstreamDir, "tsc"),
    env,
  });

  // 2. Stage `packages/typescript` into an isolated temp workspace, link `@types/node`, and run `tsc -p tsconfig.json`.
  const stageBuildDir = path.join(outRoot, ".stage-build");
  fs.rmSync(stageBuildDir, { recursive: true, force: true });
  const stagePkgDir = path.join(stageBuildDir, "packages", "typescript");
  fs.mkdirSync(path.dirname(stagePkgDir), { recursive: true });
  fs.cpSync(path.join(upstreamDir, "packages", "typescript"), stagePkgDir, { recursive: true });
  fs.symlinkSync(
    typesNodeModules,
    path.join(stageBuildDir, "node_modules"),
    process.platform === "win32" ? "junction" : "dir",
  );

  console.log(`[ts-zigar] Emitting TypeScript 7.1 JS + .d.ts declarations into ${mainPkgDir}...`);
  run(tscExe, ["-p", path.join(stagePkgDir, "tsconfig.json"), "--noCheck"], {
    cwd: stagePkgDir,
    env,
  });

  // 3. Assemble published `node_modules/typescript` layout (`bin`, `lib`, `schemas`, `dist`, `enums`, `vendor`, `package.json`).
  fs.rmSync(mainPkgDir, { recursive: true, force: true });
  fs.mkdirSync(mainPkgDir, { recursive: true });
  for (const sub of ["bin", "lib", "schemas", "dist", "enums", "vendor"]) {
    const srcSub = path.join(stagePkgDir, sub);
    if (fs.existsSync(srcSub)) {
      fs.cpSync(srcSub, path.join(mainPkgDir, sub), { recursive: true });
    }
  }
  const rawPkgJson = JSON.parse(fs.readFileSync(path.join(stagePkgDir, "package.json"), "utf8"));
  const pubPkgJson = createPublishedPackageJson(rawPkgJson, platformPkgName, version);
  fs.writeFileSync(path.join(mainPkgDir, "package.json"), JSON.stringify(pubPkgJson, null, 4) + "\n");

  fs.rmSync(stageBuildDir, { recursive: true, force: true });
  fs.writeFileSync(stampFile, expectedStamp + "\n");
  return { outRoot, mainPkgDir, platformPkgDir, tscExe };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let outDir;
  let force = false;
  for (let i = 0; i < args.length; i++) {
    if ((args[i] === "-o" || args[i] === "--out") && i + 1 < args.length) {
      outDir = args[++i];
    } else if (args[i] === "--force") {
      force = true;
    }
  }
  const built = buildTypeScript71Package({ outDir, force });
  console.log(`[ts-zigar] Staged TypeScript 7.1 package at ${built.mainPkgDir}`);
}
