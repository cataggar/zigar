#!/usr/bin/env node
import { readdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ensureIsolatedCacheEnv, ensureWorkspaceLinks } from '../node/generate.mjs';
import { ensureLambdaBindings } from './generate.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

export async function buildWasmBundle({ quiet = false } = {}) {
  ensureIsolatedCacheEnv('aws-lambda-node26');
  ensureWorkspaceLinks();
  await ensureLambdaBindings({ quiet: true });

  const distDir = join(__dirname, 'dist');
  rmSync(join(distDir, 'lambda.mjs'), { force: true });
  rmSync(join(distDir, 'assets'), { recursive: true, force: true });

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

  const assetsDir = join(distDir, 'assets');
  const wasmFiles = readdirSync(assetsDir).filter((name) => name.endsWith('.wasm'));
  const totalWasmBytes = wasmFiles.reduce(
    (sum, name) => sum + statSync(join(assetsDir, name)).size,
    0,
  );

  return {
    bundlePath: join(distDir, 'lambda.mjs'),
    wasmFiles,
    totalWasmBytes,
  };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const info = await buildWasmBundle({ quiet: process.argv.includes('--quiet') });
  if (!process.argv.includes('--quiet')) {
    console.log(
      `Built AWS Lambda WASM bundle: ${info.bundlePath} (${info.wasmFiles.length} .wasm, ${info.totalWasmBytes} bytes)`,
    );
  }
}
