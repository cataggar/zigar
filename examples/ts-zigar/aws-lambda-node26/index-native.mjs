import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const loaderPath = join(__dirname, 'dist/native/lambda.mjs');

if (!existsSync(loaderPath) || process.env.REBUILD_NATIVE === '1') {
  const { buildNativeBundle } = await import('./build-native.mjs');
  await buildNativeBundle({ quiet: true });
}

const addon = await import(pathToFileURL(loaderPath).href);

let started = false;

export async function ensureStarted() {
  if (!started) {
    await addon.startup(1);
    started = true;
  }
}

export async function handler(event, context) {
  await ensureStarted();
  const res = await addon.invoke(event, context);
  return res?.$ ?? res;
}

export async function shutdown() {
  if (started) {
    await addon.shutdown();
    started = false;
  }
}

export const activeAllocCount = () => addon.activeAllocCount();
export const activeJsHandleCount = () => addon.activeJsHandleCount();
export const activeJsCallbackCount = () => addon.activeJsCallbackCount();

