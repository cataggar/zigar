import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  ensureIsolatedCacheEnv,
  ensureNodeBindings,
  loadNativeZigModule,
} from '../../node/generate.mjs';
import { buildWasmBundle } from '../build-wasm.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXAMPLE_DIR = join(__dirname, '..');

async function captureConsoleLog(fn) {
  const calls = [];
  const origLog = globalThis.console.log;
  globalThis.console.log = (...args) => {
    calls.push(args);
  };
  try {
    await fn();
  } finally {
    globalThis.console.log = origLog;
  }
  return calls;
}

describe('node-console-hello-world (WASM + native node-zigar)', () => {
  it('generates @types/node@26 bindings and builds a tree-shaken WASM bundle with zero leaked handles', async () => {
    ensureIsolatedCacheEnv('node-console-hello-world');
    await ensureNodeBindings({ quiet: true });

    const bundlePath = await buildWasmBundle({ quiet: true });
    const bundleSource = readFileSync(bundlePath, 'utf8');

    // `console` and `process` are globals: no unused `node:*` built-in imports should be emitted!
    assert.doesNotMatch(
      bundleSource,
      /from\s+["']node:(?:http|https|fs|net|crypto|sqlite|stream)["']/,
      'Unreferenced node:* modules must be tree-shaken out of the bundle',
    );

    const mod = await import(`${pathToFileURL(bundlePath).href}?t=${Date.now()}`);
    assert.equal(typeof mod.hello, 'function');
    assert.equal(Number(mod.activeHandles()), 0);

    const origArgv = process.argv;
    process.argv = [ origArgv[0], join(EXAMPLE_DIR, 'run-wasm.mjs'), '--flag=demo', 'extra' ];
    let calls;
    try {
      calls = await captureConsoleLog(() => {
        mod.hello('Zigar WASM');
      });
    } finally {
      process.argv = origArgv;
    }

    assert.equal(calls.length, 2);
    assert.deepEqual(calls[0], [ 'Hello, Zigar WASM!' ]);
    assert.deepEqual(calls[1], [
      'args:',
      [ origArgv[0], join(EXAMPLE_DIR, 'run-wasm.mjs'), '--flag=demo', 'extra' ],
    ]);

    assert.equal(Number(mod.activeHandles()), 0);
    assert.equal(Number(mod.activeCallbacks()), 0);
  });

  it('executes src/console.zig natively via node-zigar with identical output and zero leaked handles', async () => {
    ensureIsolatedCacheEnv('node-console-hello-world');
    await ensureNodeBindings({ quiet: true });

    const mod = await loadNativeZigModule(new URL('../src/console.zig', import.meta.url).href);
    assert.equal(typeof mod.hello, 'function');
    assert.equal(Number(mod.activeHandles()), 0);

    const origArgv = process.argv;
    process.argv = [ origArgv[0], join(EXAMPLE_DIR, 'run-native.mjs'), '--mode=native' ];
    let calls;
    try {
      calls = await captureConsoleLog(() => {
        mod.hello('Zigar Native');
      });
    } finally {
      process.argv = origArgv;
    }

    assert.equal(calls.length, 2);
    assert.deepEqual(calls[0], [ 'Hello, Zigar Native!' ]);
    assert.deepEqual(calls[1], [
      'args:',
      [ origArgv[0], join(EXAMPLE_DIR, 'run-native.mjs'), '--mode=native' ],
    ]);

    assert.equal(Number(mod.activeHandles()), 0);
    assert.equal(Number(mod.activeCallbacks()), 0);
  });
});
