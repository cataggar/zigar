import { app } from '@azure/functions';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const appRoot = join(__dirname, '..');
const loaderPath = join(appRoot, 'dist/native/azure-func.mjs');
const builderPath = join(appRoot, 'build-native.mjs');

if (!existsSync(loaderPath) || process.env.REBUILD_NATIVE === '1') {
  if (!existsSync(builderPath)) {
    throw new Error(
      `Missing prebuilt native bundle at ${loaderPath}. Run "npm run build:native" before Zip Deploy.`,
    );
  }
  const { buildNativeBundle } = await import(pathToFileURL(builderPath).href);
  await buildNativeBundle({ quiet: true });
}

const addon = await import(pathToFileURL(loaderPath).href);

let startupPromise = null;
let started = false;

export async function ensureStarted() {
  if (started) return;
  if (!startupPromise) {
    startupPromise = Promise.resolve(addon.startup(1)).then(
      () => {
        started = true;
        startupPromise = null;
      },
      (err) => {
        startupPromise = null;
        throw err;
      },
    );
  }
  await startupPromise;
}

export async function helloHandler(request, context) {
  await ensureStarted();
  const res = await addon.invokeHttp(request, context);
  return res?.$ ?? res;
}

export function register() {
  addon.registerHttpTriggers(helloHandler);
  app.hook.appTerminate(() => shutdown());
}

export async function shutdown() {
  if (startupPromise) {
    try {
      await startupPromise;
    } catch {}
  }
  if (started) {
    await addon.shutdown();
    started = false;
  }
}

process.once('SIGTERM', () => {
  shutdown()
    .catch(() => {})
    .finally(() => {
      if (process.listenerCount('SIGTERM') === 0) {
        process.kill(process.pid, 'SIGTERM');
      }
    });
});

// Register HTTP triggers at module import time when loaded by the Azure Functions v4 worker
// (`"main": "functions-native/*.mjs"`).
register();

export const activeAllocCount = () => addon.activeAllocCount();
export const activeAllocBytes = () => addon.activeAllocBytes();
export const activeJsHandleCount = () => addon.activeJsHandleCount();
export const activeJsCallbackCount = () => addon.activeJsCallbackCount();
