#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const bundlePath = join(__dirname, 'dist/gae_server.mjs');

if (!existsSync(bundlePath) || process.env.REBUILD_WASM === '1') {
  const { buildWasmBundle } = await import('./build-wasm.mjs');
  await buildWasmBundle({ quiet: true });
}

const {
  start,
  boundPort,
  hadError,
  isClosed,
  beginShutdown,
  finishShutdown,
} = await import(pathToFileURL(bundlePath).href);

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

