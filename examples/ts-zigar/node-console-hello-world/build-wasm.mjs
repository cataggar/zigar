#!/usr/bin/env node
import { rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ensureIsolatedCacheEnv, ensureNodeBindings, ensureWorkspaceLinks } from '../node/generate.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

export async function buildWasmBundle({ quiet = false } = {}) {
  ensureIsolatedCacheEnv('node-console-hello-world');
  ensureWorkspaceLinks();
  await ensureNodeBindings({ quiet: true });

  const distDir = join(__dirname, 'dist');
  rmSync(distDir, { recursive: true, force: true });

  const { rollup } = await import('rollup');
  const { default: config } = await import('./rollup.config.mjs');

  const bundle = await rollup({
    ...config,
    onwarn(warning, warn) {
      if (!quiet) warn(warning);
    },
  });
  try {
    await bundle.write(config.output);
  } finally {
    await bundle.close();
  }

  return join(distDir, 'console.mjs');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const outPath = await buildWasmBundle({ quiet: process.argv.includes('--quiet') });
  if (!process.argv.includes('--quiet')) {
    console.log(`Built WASM bundle: ${outPath}`);
  }
}
