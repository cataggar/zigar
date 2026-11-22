#!/usr/bin/env node
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { ensureIsolatedCacheEnv, ensureWorkspaceLinks } from '../node/generate.mjs';
import { ensureAzureFunctionsBindings } from './generate.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '../../..');
const require = createRequire(import.meta.url);

export async function buildNativeBundle({ quiet = false } = {}) {
  const { buildDir, cacheDir } = ensureIsolatedCacheEnv('azure-functions-node26');
  ensureWorkspaceLinks();
  await ensureAzureFunctionsBindings({ quiet: true });

  const nativeDir = join(__dirname, 'dist/native');
  rmSync(nativeDir, { recursive: true, force: true });
  mkdirSync(nativeDir, { recursive: true });

  const zigarCompiler = await import(
    pathToFileURL(join(REPO_ROOT, 'zigar-compiler/dist/index.js')).href
  );
  const nodeZigarAddon = await import(
    pathToFileURL(join(REPO_ROOT, 'node-zigar-addon/dist/index.cjs')).href
  );

  const platform = zigarCompiler.getPlatform();
  const arch = zigarCompiler.getArch();
  const srcPath = join(__dirname, 'src/azure_func.zig');
  const modDir = join(nativeDir, 'azure-func.zigar');
  const addonDir = join(nativeDir, 'node-zigar-addon');
  const loaderPath = join(nativeDir, 'azure-func.mjs');
  const configPath = join(__dirname, 'node-zigar.config.json');

  const { outputPath: addonPath } = await nodeZigarAddon.buildAddon(addonDir, {
    recompileAddon: true,
    optimizeAddon: 'ReleaseSmall',
    platform,
    arch,
  });

  const { outputPath: modulePath } = await zigarCompiler.compile(srcPath, modDir, {
    optimize: 'ReleaseSmall',
    multithreaded: true,
    platform,
    arch,
    buildDir,
    cacheDir,
    configPath,
  });

  const { createEnvironment } = require(addonPath);
  const env = createEnvironment();
  env.loadModule(modulePath);
  env.acquireStructures({ optimize: 'ReleaseSmall', multithreaded: true });
  const definition = env.exportStructures();

  const { code } = zigarCompiler.generateCode(definition, {
    standaloneLoader: {
      addonDir: relative(nativeDir, dirname(addonPath)) || '.',
      moduleDir: relative(nativeDir, dirname(modulePath)) || '.',
      type: 'esm',
    },
  });
  writeFileSync(loaderPath, code, 'utf8');

  if (!quiet) {
    console.log(`Built Azure Functions standalone native bundle: ${loaderPath} (${platform}/${arch})`);
  }
  return { loaderPath, addonPath, modulePath, platform, arch };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await buildNativeBundle({ quiet: process.argv.includes('--quiet') });
}
