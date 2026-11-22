#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { buildWasmBundle } from './build-wasm.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const bundlePath = join(__dirname, 'dist/console.mjs');

if (!existsSync(bundlePath) || process.env.REBUILD_WASM === '1') {
  await buildWasmBundle({ quiet: true });
}

const { hello } = await import(pathToFileURL(bundlePath).href);
const name = process.argv[2] ?? 'Node.js 26 (WASM)';
hello(name);
