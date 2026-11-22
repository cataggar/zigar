import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
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
    const assetsDir = join(dirname(bundlePath), 'assets');
    const wasmFiles = readdirSync(assetsDir).filter((f) => f.endsWith('.wasm'));
    assert.equal(wasmFiles.length, 1, `Expected 1 .wasm asset, got ${JSON.stringify(wasmFiles)}`);
    const wasmBytes = statSync(join(assetsDir, wasmFiles[0])).size;
    assert.ok(
      wasmBytes > 0 && wasmBytes < 192 * 1024,
      `Expected compact stripped WASM binary (< 192 KiB), got ${wasmBytes} bytes`,
    );
    assert.ok(
      Buffer.byteLength(bundleSource, 'utf8') < 640 * 1024,
      `Expected compact Rollup JS bundle (< 640 KiB), got ${Buffer.byteLength(bundleSource, 'utf8')} bytes`,
    );

    // `console` and `process` are globals: zero static `node:*` imports should be emitted!
    const nodeImports = [ ...bundleSource.matchAll(/\bfrom\s*["'](node:[^"']+)["']/g) ].map((m) => m[1]);
    assert.deepEqual(
      nodeImports,
      [],
      `Unreferenced node:* modules must be tree-shaken out of console.mjs, got ${JSON.stringify(nodeImports)}`,
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
