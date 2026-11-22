#!/usr/bin/env node
/**
 * Reproducible `@azure/functions` + `@types/node@26` -> Zig 0.17 binding generator (`zigar ts`)
 * for Azure Functions v4 Programming Model on Node.js 26 Active LTS (`linuxFxVersion: "NODE|26"`)
 * and Azure App Service Linux Node 26 LTS.
 */

import { execFile, execFileSync } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import {
  computeGeneratorFingerprint,
  ensureIsolatedCacheEnv,
  ensureWorkspaceLinks,
  isNativeBinFresh,
  REPO_ROOT,
  resolveComponentWasm,
} from '../node/generate.mjs';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export const AZURE_PKG_DIR = __dirname;
export const GENERATED_DIR = join(AZURE_PKG_DIR, 'generated');
const STAMP_PATH = join(GENERATED_DIR, '.stamp.json');

function ensureLocalAzureRuntimeLink(sourceAzureDir) {
  const localScopeDir = join(AZURE_PKG_DIR, 'node_modules/@azure');
  const localAzureDir = join(localScopeDir, 'functions');
  if (existsSync(join(localAzureDir, 'package.json'))) {
    return;
  }
  try {
    if (lstatSync(localAzureDir)) {
      rmSync(localAzureDir, { recursive: true, force: true });
    }
  } catch {}
  mkdirSync(localScopeDir, { recursive: true });
  symlinkSync(sourceAzureDir, localAzureDir, 'dir');
}

export function resolveOrInstallAzureFunctions() {
  const { cacheRoot, npmCache } = ensureIsolatedCacheEnv('azure-functions-node26');
  const nmCandidates = [
    process.env.TS_ZIGAR_TYPES_AZURE_FUNCTIONS_NM,
    process.env.TS_ZIGAR_CACHE_DIR && join(process.env.TS_ZIGAR_CACHE_DIR, 'types-azure-functions/node_modules'),
    join(AZURE_PKG_DIR, 'node_modules'),
    join(cacheRoot, 'ts-zigar/types-azure-functions/node_modules'),
    resolve(REPO_ROOT, '../.cache/ts-zigar/types-azure-functions/node_modules'),
  ].filter(Boolean);

  for (const nm of nmCandidates) {
    const azureDir = join(nm, '@azure/functions');
    const nodeDir = join(nm, '@types/node');
    if (existsSync(join(azureDir, 'package.json')) && existsSync(join(nodeDir, 'package.json'))) {
      const resolvedAzureDir = resolve(azureDir);
      ensureLocalAzureRuntimeLink(resolvedAzureDir);
      return {
        azureFunctionsDir: resolvedAzureDir,
        typesNodeDir: resolve(nodeDir),
      };
    }
  }

  execFileSync('npm', [ 'install', '--no-audit', '--no-fund', '--cache', npmCache ], {
    cwd: AZURE_PKG_DIR,
    env: process.env,
    stdio: 'inherit',
  });

  const azureDir = join(AZURE_PKG_DIR, 'node_modules/@azure/functions');
  const nodeDir = join(AZURE_PKG_DIR, 'node_modules/@types/node');
  if (!existsSync(join(azureDir, 'package.json')) || !existsSync(join(nodeDir, 'package.json'))) {
    throw new Error('Failed to locate or install @azure/functions and @types/node@26');
  }
  return {
    azureFunctionsDir: resolve(azureDir),
    typesNodeDir: resolve(nodeDir),
  };
}

export async function ensureAzureFunctionsBindings({ force = false, quiet = false } = {}) {
  const { buildDir } = ensureIsolatedCacheEnv('azure-functions-node26');
  ensureWorkspaceLinks();

  const { azureFunctionsDir, typesNodeDir } = resolveOrInstallAzureFunctions();
  const azurePkg = JSON.parse(readFileSync(join(azureFunctionsDir, 'package.json'), 'utf8'));
  const nodePkg = JSON.parse(readFileSync(join(typesNodeDir, 'package.json'), 'utf8'));
  const azureFunctionsVersion = azurePkg.version || 'unknown';
  const typesNodeVersion = nodePkg.version || 'unknown';
  const generatorHash = computeGeneratorFingerprint();

  const cliArgs = [
    '-t', azureFunctionsDir,
    '-t', typesNodeDir,
    '-s', 'node:=',
    '-d', GENERATED_DIR,
  ];

  if (
    !force
    && existsSync(STAMP_PATH)
    && existsSync(join(GENERATED_DIR, 'root.zig'))
    && existsSync(join(GENERATED_DIR, 'azure/functions/types/index.zig'))
    && existsSync(join(GENERATED_DIR, 'azure/functions/types/app.zig'))
    && existsSync(join(GENERATED_DIR, 'azure/functions/types/http.zig'))
    && existsSync(join(GENERATED_DIR, 'crypto.zig'))
  ) {
    try {
      const saved = JSON.parse(readFileSync(STAMP_PATH, 'utf8'));
      if (
        saved.azureFunctionsVersion === azureFunctionsVersion
        && saved.typesNodeVersion === typesNodeVersion
        && saved.stripSpec === 'node:='
        && saved.generatorHash === generatorHash
      ) {
        return {
          generatedDir: GENERATED_DIR,
          azureFunctionsVersion,
          typesNodeVersion,
          cached: true,
        };
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
    JSON.stringify(
      { azureFunctionsVersion, typesNodeVersion, stripSpec: 'node:=', generatorHash },
      null,
      2,
    ) + '\n',
    'utf8',
  );

  if (!quiet) {
    console.log(
      `Generated @azure/functions@${azureFunctionsVersion} + @types/node@${typesNodeVersion} Zig bindings in ${GENERATED_DIR}`,
    );
  }
  return {
    generatedDir: GENERATED_DIR,
    azureFunctionsVersion,
    typesNodeVersion,
    cached: false,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
  const force = process.argv.includes('--force');
  const quiet = process.argv.includes('--quiet');
  await ensureAzureFunctionsBindings({ force, quiet });
}
