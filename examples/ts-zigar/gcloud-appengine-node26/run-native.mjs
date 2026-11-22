#!/usr/bin/env node
import { setTimeout as delay } from 'node:timers/promises';
import { ensureIsolatedCacheEnv, ensureNodeBindings, loadNativeZigModule } from '../node/generate.mjs';

ensureIsolatedCacheEnv('gcloud-appengine-node26');
await ensureNodeBindings({ quiet: true });

const {
  start,
  boundPort,
  hadError,
  isClosed,
  beginShutdown,
  finishShutdown,
} = await loadNativeZigModule(new URL('./src/gae_server.zig', import.meta.url).href);

try {
  start();
} catch (err) {
  console.error(JSON.stringify({
    severity: 'ERROR',
    'logging.googleapis.com/severity': 'ERROR',
    event: 'startup_exception',
    message: err instanceof Error ? err.message : String(err),
  }));
  process.exit(1);
}

let shuttingDown = false;

const drainBudgetMs = Number(process.env.GAE_SHUTDOWN_DRAIN_MS ?? 2_500);

async function drainAndExit(exitCode = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  process.off('SIGINT', handleSignal);
  process.off('SIGTERM', handleSignal);
  try {
    beginShutdown();
    const deadline = Date.now() + (Number.isFinite(drainBudgetMs) && drainBudgetMs >= 0 ? drainBudgetMs : 2_500);
    while (!isClosed() && Date.now() < deadline) {
      await delay(10);
    }
    finishShutdown(true);
  } catch {
    exitCode = exitCode || 1;
  }
  if (exitCode !== 0) {
    process.exit(exitCode);
  }
}

function handleSignal() {
  void drainAndExit(0);
}

process.on('SIGINT', handleSignal);
process.on('SIGTERM', handleSignal);

const startupDeadline = Date.now() + 5_000;
while (!shuttingDown && Date.now() < startupDeadline) {
  if (hadError()) {
    await drainAndExit(1);
    break;
  }
  if (boundPort() > 0) {
    break;
  }
  await delay(10);
}

