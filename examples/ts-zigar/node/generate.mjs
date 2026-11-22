#!/usr/bin/env node
/**
 * Reproducible `@types/node@26` -> Zig 0.17 binding generator (`zigar ts`)
 * shared across `examples/ts-zigar/node-*` examples (mirroring `ts2rs/node`).
 */

import { execFile, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { registerHooks } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export const NODE_PKG_DIR = __dirname;
export const EXAMPLES_ROOT = resolve(__dirname, '..');
export const REPO_ROOT = resolve(__dirname, '../../..');
export const GENERATED_DIR = join(NODE_PKG_DIR, 'generated');
const STAMP_PATH = join(GENERATED_DIR, '.stamp.json');

export function ensureIsolatedCacheEnv(exampleName = 'node') {
  const cacheRoot = join(REPO_ROOT, '.cache');
  const zigLocal = process.env.ZIG_LOCAL_CACHE_DIR || join(cacheRoot, 'zig-local');
  const zigGlobal = process.env.ZIG_GLOBAL_CACHE_DIR || join(cacheRoot, 'zig-global');
  const xdgCache = process.env.XDG_CACHE_HOME || join(cacheRoot, 'xdg');
  const npmCache = process.env.NPM_CONFIG_CACHE || join(cacheRoot, 'npm');
  const tmpDir = (!process.env.TMPDIR || process.env.TMPDIR.startsWith('/tmp') || process.env.TMPDIR.startsWith('/var/tmp'))
    ? join(cacheRoot, 'tmp')
    : process.env.TMPDIR;
  const exampleRoot = join(cacheRoot, 'examples', exampleName);
  const buildDir = join(exampleRoot, 'zig-build');
  const zigarCacheDir = join(exampleRoot, 'zig-cache');

  for (const dir of [ zigLocal, zigGlobal, xdgCache, npmCache, tmpDir, buildDir, zigarCacheDir ]) {
    mkdirSync(dir, { recursive: true });
  }

  process.env.ZIG_LOCAL_CACHE_DIR = zigLocal;
  process.env.ZIG_GLOBAL_CACHE_DIR = zigGlobal;
  process.env.XDG_CACHE_HOME = xdgCache;
  process.env.NPM_CONFIG_CACHE = npmCache;
  process.env.TMPDIR = tmpDir;

  return { cacheRoot, buildDir, zigarCacheDir, npmCache, tmpDir };
}

function linkIfMissing(linkPath, targetPath) {
  if (existsSync(linkPath) || !existsSync(targetPath)) return;
  mkdirSync(dirname(linkPath), { recursive: true });
  try {
    symlinkSync(targetPath, linkPath, 'dir');
  } catch (err) {
    if (err && err.code !== 'EEXIST') throw err;
  }
}

export function ensureWorkspaceLinks() {
  const { npmCache } = ensureIsolatedCacheEnv('node');
  if (!existsSync(join(REPO_ROOT, 'zigar-compiler/node_modules/rollup'))) {
    execFileSync('npm', [ 'install', '--no-audit', '--no-fund', '--no-package-lock', '--ignore-scripts', '--prefer-offline', '--cache', npmCache ], {
      cwd: join(REPO_ROOT, 'zigar-compiler'),
      env: process.env,
      stdio: 'ignore',
    });
  }
  if (!existsSync(join(REPO_ROOT, 'node-zigar-addon/node_modules/node-api-headers'))) {
    execFileSync('npm', [ 'install', '--no-audit', '--no-fund', '--no-package-lock', '--ignore-scripts', '--prefer-offline', '--cache', npmCache ], {
      cwd: join(REPO_ROOT, 'node-zigar-addon'),
      env: process.env,
      stdio: 'ignore',
    });
  }

  const examplesNm = join(EXAMPLES_ROOT, 'node_modules');
  mkdirSync(examplesNm, { recursive: true });

  linkIfMissing(join(examplesNm, 'zigar-runtime'), join(REPO_ROOT, 'zigar-runtime'));
  linkIfMissing(join(examplesNm, 'zigar-compiler'), join(REPO_ROOT, 'zigar-compiler'));
  linkIfMissing(join(examplesNm, 'node-zigar'), join(REPO_ROOT, 'node-zigar'));
  linkIfMissing(join(examplesNm, 'node-zigar-addon'), join(REPO_ROOT, 'node-zigar-addon'));
  linkIfMissing(join(examplesNm, 'rollup-plugin-zigar'), join(REPO_ROOT, 'rollup-plugin-zigar'));

  const compilerNm = join(REPO_ROOT, 'zigar-compiler/node_modules');
  linkIfMissing(join(examplesNm, 'rollup'), join(compilerNm, 'rollup'));
  linkIfMissing(join(examplesNm, '@rollup/plugin-node-resolve'), join(compilerNm, '@rollup/plugin-node-resolve'));

  linkIfMissing(join(REPO_ROOT, 'rollup-plugin-zigar/node_modules/zigar-compiler'), join(REPO_ROOT, 'zigar-compiler'));
  linkIfMissing(join(REPO_ROOT, 'rollup-plugin-zigar/node_modules/zigar-runtime'), join(REPO_ROOT, 'zigar-runtime'));
  linkIfMissing(join(REPO_ROOT, 'node-zigar/node_modules/zigar-compiler'), join(REPO_ROOT, 'zigar-compiler'));
  linkIfMissing(join(REPO_ROOT, 'node-zigar/node_modules/node-zigar-addon'), join(REPO_ROOT, 'node-zigar-addon'));
}

export function resolveOrInstallTypesNode26() {
  const { cacheRoot, npmCache } = ensureIsolatedCacheEnv('node');
  const candidates = [
    process.env.TS_ZIGAR_TYPES_NODE26_DIR,
    process.env.TS_ZIGAR_CACHE_DIR && join(process.env.TS_ZIGAR_CACHE_DIR, 'types-node26/node_modules/@types/node'),
    join(NODE_PKG_DIR, 'node_modules/@types/node'),
    join(cacheRoot, 'ts-zigar/types-node26/node_modules/@types/node'),
    join(cacheRoot, 'types-node26/node_modules/@types/node'),
    resolve(REPO_ROOT, '../.cache/ts-zigar/types-node26/node_modules/@types/node'),
  ].filter(Boolean);

  for (const cand of candidates) {
    if (existsSync(join(cand, 'package.json'))) {
      return resolve(cand);
    }
  }

  execFileSync('npm', [ 'install', '--no-audit', '--no-fund', '--cache', npmCache ], {
    cwd: NODE_PKG_DIR,
    env: process.env,
    stdio: 'inherit',
  });

  const installed = join(NODE_PKG_DIR, 'node_modules/@types/node');
  if (!existsSync(join(installed, 'package.json'))) {
    throw new Error('Failed to locate or install @types/node@26');
  }
  return installed;
}

export function resolveComponentWasm() {
  const candidates = [
    process.env.TS_ZIGAR_COMPONENT_PATH,
    process.env.TS_ZIGAR_COMPONENT_WASM,
    process.env.TS_ZIGAR_CACHE_DIR && join(process.env.TS_ZIGAR_CACHE_DIR, 'typescript-compiler.component.wasm'),
    join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm'),
    join(REPO_ROOT, '.cache/ts-zigar/typescript-compiler.component.wasm'),
    resolve(REPO_ROOT, '../.cache/ts-zigar/typescript-compiler.component.wasm'),
  ].filter(Boolean);

  for (const cand of candidates) {
    if (existsSync(cand)) {
      return resolve(cand);
    }
  }
  return null;
}

function listGeneratorSourcePaths() {
  const rels = [ 'ts-zigar/build.zig', 'ts-zigar/wit/typescript.wit' ];
  const srcDir = join(REPO_ROOT, 'ts-zigar/src');
  if (existsSync(srcDir)) {
    for (const f of readdirSync(srcDir).filter((name) => name.endsWith('.zig')).sort()) {
      rels.push(`ts-zigar/src/${f}`);
    }
  }
  const adapterDir = join(REPO_ROOT, 'ts-zigar/component/adapter');
  if (existsSync(adapterDir)) {
    for (const f of readdirSync(adapterDir).filter((name) => name.endsWith('.go')).sort()) {
      rels.push(`ts-zigar/component/adapter/${f}`);
    }
  }
  return rels;
}

export function computeGeneratorFingerprint() {
  const hash = createHash('sha256');
  for (const rel of listGeneratorSourcePaths()) {
    const p = join(REPO_ROOT, rel);
    if (existsSync(p)) {
      hash.update(rel);
      hash.update(readFileSync(p));
    }
  }
  const componentWasm = resolveComponentWasm();
  if (componentWasm && existsSync(componentWasm)) {
    const st = statSync(componentWasm);
    hash.update(`component:${st.size}:${Math.trunc(st.mtimeMs)}`);
  }
  return hash.digest('hex').slice(0, 16);
}

export function isNativeBinFresh(nativeBin) {
  if (!existsSync(nativeBin)) return false;
  const binMtime = statSync(nativeBin).mtimeMs;
  for (const rel of listGeneratorSourcePaths()) {
    if (rel.endsWith('.go')) continue;
    const p = join(REPO_ROOT, rel);
    if (existsSync(p) && statSync(p).mtimeMs > binMtime) return false;
  }
  return true;
}

export async function ensureNodeBindings({ force = false, quiet = false } = {}) {
  const { buildDir } = ensureIsolatedCacheEnv('node');
  ensureWorkspaceLinks();

  const typesNodeDir = resolveOrInstallTypesNode26();
  const pkgJson = JSON.parse(readFileSync(join(typesNodeDir, 'package.json'), 'utf8'));
  const typesNodeVersion = pkgJson.version || 'unknown';
  const generatorHash = computeGeneratorFingerprint();
  const cliArgs = [ '-t', typesNodeDir, '-s', 'node:=', '-d', GENERATED_DIR ];

  if (
    !force
    && existsSync(STAMP_PATH)
    && existsSync(join(GENERATED_DIR, 'root.zig'))
    && existsSync(join(GENERATED_DIR, 'globals.zig'))
    && existsSync(join(GENERATED_DIR, 'http.zig'))
  ) {
    try {
      const saved = JSON.parse(readFileSync(STAMP_PATH, 'utf8'));
      if (
        saved.typesNodeVersion === typesNodeVersion
        && saved.stripSpec === 'node:='
        && saved.generatorHash === generatorHash
      ) {
        return { generatedDir: GENERATED_DIR, typesNodeVersion, cached: true };
      }
    } catch {}
  }

  rmSync(GENERATED_DIR, { recursive: true, force: true });
  mkdirSync(GENERATED_DIR, { recursive: true });

  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = resolveComponentWasm();

  if (isNativeBinFresh(nativeBin) && componentWasm) {
    await execFileAsync(nativeBin, [ '--component', componentWasm, ...cliArgs ], {
      cwd: REPO_ROOT,
      env: process.env,
    });
  } else {
    const { runTs } = await import('../../../zigar-compiler/src/index.js');
    const res = await runTs(cliArgs, { silent: quiet, buildDir });
    const code = typeof res === 'object' && res !== null ? res.code : res;
    if (code !== 0) {
      throw new Error(`zigar ts exited with code ${code}: ${res?.stderr || ''}`);
    }
  }

  writeFileSync(
    STAMP_PATH,
    JSON.stringify({ typesNodeVersion, stripSpec: 'node:=', generatorHash }, null, 2) + '\n',
    'utf8',
  );

  if (!quiet) {
    console.log(`Generated @types/node@${typesNodeVersion} Zig bindings in ${GENERATED_DIR}`);
  }
  return { generatedDir: GENERATED_DIR, typesNodeVersion, cached: false };
}

let nativeHooksRegistered = false;
const compiledZigSources = new Map();

export async function loadNativeZigModule(zigFileUrl) {
  ensureWorkspaceLinks();
  const resolvedUrl = new URL(zigFileUrl, import.meta.url).href;
  if (!compiledZigSources.has(resolvedUrl)) {
    const nodeZigar = await import(pathToFileURL(join(REPO_ROOT, 'node-zigar/dist/index.js')).href);
    const loaded = await nodeZigar.load(resolvedUrl, {}, () => {
      throw new Error(`Unexpected fallback load for ${resolvedUrl}`);
    });
    compiledZigSources.set(resolvedUrl, loaded.source);
  }
  if (!nativeHooksRegistered) {
    registerHooks({
      resolve(specifier, context, nextResolve) {
        if (!/\.(zig|zigar)(\?|$)/.test(specifier)) {
          return nextResolve(specifier, context);
        }
        return {
          format: 'module',
          shortCircuit: true,
          url: new URL(specifier, context.parentURL).href,
        };
      },
      load(url, context, nextLoad) {
        const src = compiledZigSources.get(url);
        if (src !== undefined) {
          return { format: 'module', shortCircuit: true, source: src };
        }
        return nextLoad(url, context);
      },
    });
    nativeHooksRegistered = true;
  }
  return await import(resolvedUrl);
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
  const force = process.argv.includes('--force');
  const quiet = process.argv.includes('--quiet');
  await ensureNodeBindings({ force, quiet });
}
