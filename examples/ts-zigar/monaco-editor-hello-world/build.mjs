#!/usr/bin/env node
/**
 * Build & dev driver for `examples/ts-zigar/monaco-editor-hello-world`.
 *
 * Ensures shared `../monaco-editor` Zig 0.17 bindings are generated, links workspace
 * packages + Vite/JSDOM under `/d`-isolated caches, and runs Vite (`build`, `dev`, or `preview`).
 */

import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, symlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  ensureIsolatedCacheEnv,
  ensureMonacoBindings,
  ensureWorkspaceLinks,
  REPO_ROOT,
  resolveOrInstallMonacoEditor,
} from '../monaco-editor/generate.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export const APP_DIR = __dirname;
export const DIST_DIR = join(__dirname, 'dist');

function linkIfMissing(linkPath, targetPath) {
  if (existsSync(linkPath) || !existsSync(targetPath)) return;
  mkdirSync(dirname(linkPath), { recursive: true });
  try {
    symlinkSync(targetPath, linkPath, 'dir');
  } catch (err) {
    if (err && err.code !== 'EEXIST') throw err;
  }
}

export function ensureViteDeps() {
  const { cacheRoot, npmCache } = ensureIsolatedCacheEnv('monaco-editor-hello-world');
  ensureWorkspaceLinks();
  const monacoDir = resolveOrInstallMonacoEditor();

  const localNm = join(APP_DIR, 'node_modules');
  mkdirSync(localNm, { recursive: true });

  linkIfMissing(join(localNm, 'monaco-editor'), monacoDir);
  linkIfMissing(join(localNm, 'rollup-plugin-zigar'), join(REPO_ROOT, 'rollup-plugin-zigar'));
  linkIfMissing(join(localNm, 'zigar-compiler'), join(REPO_ROOT, 'zigar-compiler'));
  linkIfMissing(join(localNm, 'zigar-runtime'), join(REPO_ROOT, 'zigar-runtime'));
  linkIfMissing(join(localNm, 'node-zigar'), join(REPO_ROOT, 'node-zigar'));

  const cacheViteRoot = join(cacheRoot, 'ts-zigar/vite-deps');
  const sharedViteCaches = [
    process.env.TS_ZIGAR_VITE_DEPS_DIR,
    join(cacheViteRoot, 'node_modules'),
    join(cacheRoot, 'vite-deps/node_modules'),
    resolve(REPO_ROOT, '../.cache/vite-deps/node_modules'),
    join(REPO_ROOT, 'rollup-plugin-zigar/node_modules'),
  ].filter(Boolean);

  for (const nmDir of sharedViteCaches) {
    if (existsSync(join(nmDir, 'vite/package.json'))) {
      linkIfMissing(join(localNm, 'vite'), join(nmDir, 'vite'));
    }
    if (existsSync(join(nmDir, 'jsdom/package.json'))) {
      linkIfMissing(join(localNm, 'jsdom'), join(nmDir, 'jsdom'));
    }
  }

  if (!existsSync(join(localNm, 'vite/package.json')) || !existsSync(join(localNm, 'jsdom/package.json'))) {
    mkdirSync(cacheViteRoot, { recursive: true });
    if (!existsSync(join(cacheViteRoot, 'package.json'))) {
      execFileSync('npm', [ 'init', '-y' ], {
        cwd: cacheViteRoot,
        env: process.env,
        stdio: 'ignore',
      });
    }
    execFileSync(
      'npm',
      [ 'install', '--no-audit', '--no-fund', '--no-package-lock', '--cache', npmCache, 'vite@^7.3.5', 'jsdom@^29.0.1' ],
      {
        cwd: cacheViteRoot,
        env: process.env,
        stdio: 'inherit',
      },
    );
    linkIfMissing(join(localNm, 'vite'), join(cacheViteRoot, 'node_modules/vite'));
    linkIfMissing(join(localNm, 'jsdom'), join(cacheViteRoot, 'node_modules/jsdom'));
  }

  return localNm;
}

export async function buildViteApp({ quiet = false } = {}) {
  ensureIsolatedCacheEnv('monaco-editor-hello-world');
  await ensureMonacoBindings({ quiet: true });
  const localNm = ensureViteDeps();

  rmSync(DIST_DIR, { recursive: true, force: true });

  const viteEntryUrl = pathToFileURL(join(localNm, 'vite/dist/node/index.js')).href;
  const { build } = await import(viteEntryUrl);
  await build({
    configFile: join(APP_DIR, 'vite.config.js'),
    logLevel: quiet ? 'warn' : 'info',
  });

  return DIST_DIR;
}

async function runViteCli(subcommand) {
  ensureIsolatedCacheEnv('monaco-editor-hello-world');
  await ensureMonacoBindings({ quiet: true });
  const localNm = ensureViteDeps();
  const viteBin = join(localNm, 'vite/bin/vite.js');
  const child = spawn(process.execPath, [ viteBin, subcommand, '--config', join(APP_DIR, 'vite.config.js') ], {
    cwd: APP_DIR,
    env: process.env,
    stdio: 'inherit',
  });
  child.on('exit', (code) => process.exit(code ?? 0));
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
  if (process.argv.includes('--dev')) {
    await runViteCli('');
  } else if (process.argv.includes('--preview')) {
    if (!existsSync(join(DIST_DIR, 'index.html'))) {
      await buildViteApp();
    }
    await runViteCli('preview');
  } else {
    const quiet = process.argv.includes('--quiet');
    await buildViteApp({ quiet });
  }
}
