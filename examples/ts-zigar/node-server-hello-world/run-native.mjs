#!/usr/bin/env node
import { ensureIsolatedCacheEnv, ensureNodeBindings, loadNativeZigModule } from '../node/generate.mjs';

ensureIsolatedCacheEnv('node-server-hello-world');
await ensureNodeBindings({ quiet: true });

const { start, shutdown } = await loadNativeZigModule(new URL('./src/server.zig', import.meta.url).href);
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
