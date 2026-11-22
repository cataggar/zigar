#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { buildWasmBundle } from './build-wasm.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const bundlePath = join(__dirname, 'dist/server.mjs');

if (!existsSync(bundlePath) || process.env.REBUILD_WASM === '1') {
  await buildWasmBundle({ quiet: true });
}

const { start, shutdown } = await import(pathToFileURL(bundlePath).href);
start();

const handleSignal = () => {
  try {
    shutdown();
  } finally {
    process.off('SIGINT', handleSignal);
    process.off('SIGTERM', handleSignal);
  }
};
process.on('SIGINT', handleSignal);
process.on('SIGTERM', handleSignal);
