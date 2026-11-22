#!/usr/bin/env node
import { ensureIsolatedCacheEnv, ensureNodeBindings, loadNativeZigModule } from '../node/generate.mjs';

ensureIsolatedCacheEnv('node-console-hello-world');
await ensureNodeBindings({ quiet: true });

const { hello } = await loadNativeZigModule(new URL('./src/console.zig', import.meta.url).href);
const name = process.argv[2] ?? 'Node.js 26 (native node-zigar)';
hello(name);
