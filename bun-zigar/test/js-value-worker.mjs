import { parentPort, workerData } from 'node:worker_threads';
import { pathToFileURL } from 'node:url';
import '../dist/index.js';

const sampleURL = new URL('../../node-zigar/test/zig-samples/js-value/handles.zig', import.meta.url).href;

if (process.argv.includes('--panic-off-thread')) {
  global.__test_options = {
    optimize: 'ReleaseSafe',
    recompile: false,
    quiet: true,
  };
  const pMod = await import(sampleURL);
  pMod.triggerOffThreadPanic({ panicTest: true });
  process.exit(0);
}

global.__test_options = {
  optimize: 'ReleaseSafe',
  recompile: false,
  quiet: true,
};
const wMod = await import(workerData?.samplePath ? pathToFileURL(workerData.samplePath).href : sampleURL);
const workerObj = { owner: 'bun-worker-thread' };
const workerRawBits = wMod.inspectRawHandle(workerObj);

const liveWorkerObj = { liveInWorkerSlot8: true };
const clonedInWorker = wMod.identityObject(liveWorkerObj);
if (clonedInWorker !== liveWorkerObj) {
  throw new Error('worker identity failed');
}

let typeofErr = null;
try {
  wMod.inspectRawBitsTypeof(workerData.mainRawBits);
} catch (err) {
  typeofErr = err.message;
}

let releaseErr = null;
try {
  wMod.releaseRawBits(workerData.mainRawBits);
} catch (err) {
  releaseErr = err.message;
}

parentPort.postMessage({
  workerRawBits,
  workerRealmTag: (workerRawBits >>> 14) & 0x3F,
  typeofErr,
  releaseErr,
  workerActiveCount: Number(wMod.activeCount()),
});
