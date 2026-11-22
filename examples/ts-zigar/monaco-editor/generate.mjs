#!/usr/bin/env node
/**
 * Reproducible browser `dom.d.ts` + `monaco-editor` -> Zig 0.17 binding generator (`zigar ts`)
 * shared with `examples/ts-zigar/monaco-editor-hello-world` (mirroring `ts2rs/monaco-editor`).
 */

import { execFile, execFileSync } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { register } from 'node:module';
import { dirname, join, posix, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export const MONACO_PKG_DIR = __dirname;
export const EXAMPLES_ROOT = resolve(__dirname, '..');
export const REPO_ROOT = resolve(__dirname, '../../..');
export const DOM_DTS_PATH = join(MONACO_PKG_DIR, 'dom.d.ts');
export const GENERATED_DIR = join(MONACO_PKG_DIR, 'generated');
const STAMP_PATH = join(GENERATED_DIR, '.stamp.json');
const SUB_RULE = 'monaco-editor=monaco';

export function ensureIsolatedCacheEnv(exampleName = 'monaco-editor') {
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
  const { npmCache } = ensureIsolatedCacheEnv('monaco-editor');
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

function syncSymlinkIfPossible(linkPath, targetPath) {
  if (!existsSync(targetPath)) return false;
  try {
    const st = lstatSync(linkPath);
    if (st.isSymbolicLink()) {
      try {
        if (realpathSync(linkPath) === realpathSync(targetPath)) return true;
      } catch {}
      rmSync(linkPath, { force: true });
    } else {
      return realpathSync(linkPath) === realpathSync(targetPath);
    }
  } catch (err) {
    if (err && err.code !== 'ENOENT') throw err;
  }
  mkdirSync(dirname(linkPath), { recursive: true });
  try {
    symlinkSync(targetPath, linkPath, 'dir');
    return true;
  } catch (err) {
    if (err && err.code !== 'EEXIST') throw err;
    return existsSync(linkPath) && realpathSync(linkPath) === realpathSync(targetPath);
  }
}

function computeDomSubstituteArgs(monacoDir) {
  const domNoExt = resolve(DOM_DTS_PATH).replace(/\\/g, '/').replace(/\.d\.ts$/, '');
  const domDir = posix.dirname(domNoExt);
  const monacoPosix = resolve(monacoDir).replace(/\\/g, '/').replace(/\/+$/, '') || '/';

  let commonLen = 0;
  let lastSlash = 0;
  const maxLen = Math.min(domDir.length, monacoPosix.length);
  while (commonLen < maxLen && domDir[commonLen] === monacoPosix[commonLen]) {
    if (domDir[commonLen] === '/') lastSlash = commonLen;
    commonLen += 1;
  }
  let baseDir;
  if (commonLen === domDir.length && (monacoPosix.length === commonLen || monacoPosix[commonLen] === '/')) {
    baseDir = domDir;
  } else if (commonLen === monacoPosix.length && (domDir.length === commonLen || domDir[commonLen] === '/')) {
    baseDir = monacoPosix;
  } else {
    baseDir = lastSlash === 0 ? '/' : domDir.slice(0, lastSlash);
  }

  const rel = posix.relative(baseDir, domNoExt);
  return rel && rel !== 'dom' ? [ '-s', `${rel}=dom` ] : [];
}

export function resolveOrInstallMonacoEditor() {
  const { cacheRoot, npmCache } = ensureIsolatedCacheEnv('monaco-editor');
  const localLink = join(MONACO_PKG_DIR, 'node_modules/monaco-editor');
  const candidates = [
    process.env.TS_ZIGAR_MONACO_DIR,
    process.env.TS_ZIGAR_CACHE_DIR && join(process.env.TS_ZIGAR_CACHE_DIR, 'monaco-editor/node_modules/monaco-editor'),
    localLink,
    join(cacheRoot, 'ts-zigar/monaco-editor/node_modules/monaco-editor'),
    resolve(REPO_ROOT, '../.cache/ts-zigar/monaco-editor/node_modules/monaco-editor'),
  ].filter(Boolean);

  for (const cand of candidates) {
    if (existsSync(join(cand, 'package.json'))) {
      const resolved = resolve(cand);
      const synced = syncSymlinkIfPossible(localLink, resolved);
      syncSymlinkIfPossible(join(EXAMPLES_ROOT, 'node_modules/monaco-editor'), resolved);
      return synced ? localLink : resolved;
    }
  }

  execFileSync('npm', [ 'install', '--no-audit', '--no-fund', '--no-package-lock', '--cache', npmCache ], {
    cwd: MONACO_PKG_DIR,
    env: process.env,
    stdio: 'inherit',
  });

  if (!existsSync(join(localLink, 'package.json'))) {
    throw new Error('Failed to locate or install monaco-editor');
  }
  linkIfMissing(join(EXAMPLES_ROOT, 'node_modules/monaco-editor'), resolve(localLink));
  return localLink;
}

function resolveComponentWasm() {
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

export async function runZigarTs(cliArgs, { quiet = false, buildDir } = {}) {
  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = resolveComponentWasm();

  if (existsSync(nativeBin) && componentWasm) {
    const { stdout, stderr } = await execFileAsync(
      nativeBin,
      [ '--component', componentWasm, ...cliArgs ],
      {
        cwd: REPO_ROOT,
        env: process.env,
        maxBuffer: 32 * 1024 * 1024,
      },
    );
    return { stdout, stderr };
  }

  const { runTs } = await import('../../../zigar-compiler/src/index.js');
  const res = await runTs(cliArgs, { silent: quiet, buildDir });
  const code = typeof res === 'object' && res !== null ? res.code : res;
  if (code !== 0) {
    throw new Error(`zigar ts exited with code ${code}: ${res?.stderr || ''}`);
  }
  return { stdout: res?.stdout || '', stderr: res?.stderr || '' };
}

export async function ensureMonacoBindings({ force = false, quiet = false, reportFallbacks = false } = {}) {
  const { buildDir } = ensureIsolatedCacheEnv('monaco-editor');
  ensureWorkspaceLinks();

  const monacoDir = resolveOrInstallMonacoEditor();
  const pkgJson = JSON.parse(readFileSync(join(monacoDir, 'package.json'), 'utf8'));
  const monacoVersion = pkgJson.version || 'unknown';
  const domMtimeMs = Math.trunc(statSync(DOM_DTS_PATH).mtimeMs);

  if (
    !force
    && !reportFallbacks
    && existsSync(STAMP_PATH)
    && existsSync(join(GENERATED_DIR, 'root.zig'))
    && existsSync(join(GENERATED_DIR, 'dom.zig'))
  ) {
    try {
      const saved = JSON.parse(readFileSync(STAMP_PATH, 'utf8'));
      if (
        saved.monacoVersion === monacoVersion
        && saved.domMtimeMs === domMtimeMs
        && saved.subRule === SUB_RULE
      ) {
        return { generatedDir: GENERATED_DIR, monacoVersion, cached: true, stderr: '' };
      }
    } catch {}
  }

  rmSync(GENERATED_DIR, { recursive: true, force: true });
  mkdirSync(GENERATED_DIR, { recursive: true });

  const cliArgs = [
    '-t', DOM_DTS_PATH,
    '-t', monacoDir,
    ...computeDomSubstituteArgs(monacoDir),
    '-s', SUB_RULE,
    ...(reportFallbacks ? [ '--report-fallbacks' ] : []),
    '-d', GENERATED_DIR,
  ];
  const { stderr } = await runZigarTs(cliArgs, { quiet, buildDir });

  writeFileSync(
    STAMP_PATH,
    JSON.stringify({ monacoVersion, domMtimeMs, subRule: SUB_RULE }, null, 2) + '\n',
    'utf8',
  );

  if (!quiet) {
    console.log(`Generated dom.d.ts + monaco-editor@${monacoVersion} Zig bindings in ${GENERATED_DIR}`);
  }
  return { generatedDir: GENERATED_DIR, monacoVersion, cached: false, stderr };
}

export async function generateSingleFileMonacoBindings(outDir, { quiet = true } = {}) {
  const { buildDir } = ensureIsolatedCacheEnv('monaco-editor');
  const monacoDir = resolveOrInstallMonacoEditor();
  const monacoDts = join(monacoDir, 'monaco.d.ts');

  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });

  const cliArgs = [
    '-t', DOM_DTS_PATH,
    '-t', monacoDts,
    ...computeDomSubstituteArgs(monacoDir),
    '-s', 'monaco-editor/monaco=monaco',
    '--report-fallbacks',
    '-d', outDir,
  ];
  return await runZigarTs(cliArgs, { quiet, buildDir });
}

let nativeLoaderRegistered = false;

export async function loadNativeZigModule(zigFileUrl) {
  ensureWorkspaceLinks();
  try {
    return await import(zigFileUrl);
  } catch (err) {
    if (!nativeLoaderRegistered && err && err.code === 'ERR_UNKNOWN_FILE_EXTENSION') {
      register('node-zigar', import.meta.url);
      nativeLoaderRegistered = true;
      return await import(zigFileUrl);
    }
    throw err;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
  const force = process.argv.includes('--force');
  const quiet = process.argv.includes('--quiet');
  const reportFallbacks = process.argv.includes('--report-fallbacks');
  await ensureMonacoBindings({ force, quiet, reportFallbacks });
}
