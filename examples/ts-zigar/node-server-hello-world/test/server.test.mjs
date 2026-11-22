import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { describe, it } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  ensureIsolatedCacheEnv,
  ensureNodeBindings,
  loadNativeZigModule,
} from '../../node/generate.mjs';
import { buildWasmBundle } from '../build-wasm.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXAMPLE_DIR = join(__dirname, '..');

async function waitForBoundPort(mod, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const port = mod.boundPort();
    if (port > 0) return port;
    await delay(10);
  }
  throw new Error('Timed out waiting for Zig HTTP server to bind an ephemeral port');
}

async function verifyServerLifecycle(mod) {
  assert.equal(Number(mod.activeHandles()), 0);
  assert.equal(Number(mod.activeCallbacks()), 0);

  const logs = [];
  const origLog = globalThis.console.log;
  globalThis.console.log = (...args) => {
    logs.push(args.join(' '));
  };

  const prevPort = process.env.PORT;
  process.env.PORT = '0';

  try {
    const requestedPort = mod.start();
    assert.equal(requestedPort, 0);

    const port = await waitForBoundPort(mod);
    assert.ok(port > 0 && port <= 65535);
    assert.ok(
      logs.some((line) => line === `Server running at http://127.0.0.1:${port}/`),
      `Expected startup banner for port ${port}, got: ${JSON.stringify(logs)}`,
    );

    const res1 = await fetch(`http://127.0.0.1:${port}/hello?from=test`);
    assert.equal(res1.status, 200);
    assert.equal(res1.headers.get('content-type'), 'text/plain; charset=utf-8');
    assert.equal(res1.headers.get('x-request-path'), '/hello?from=test');
    assert.equal(await res1.text(), 'Hello, World!\n');

    const res2 = await fetch(`http://127.0.0.1:${port}/`);
    assert.equal(res2.status, 200);
    assert.equal(res2.headers.get('x-request-path'), '/');
    assert.equal(await res2.text(), 'Hello, World!\n');

    const longPath = `/long/${'a'.repeat(1500)}?q=ok`;
    const res3 = await fetch(`http://127.0.0.1:${port}${longPath}`);
    assert.equal(res3.status, 200);
    assert.equal(res3.headers.get('x-request-path'), longPath);
    assert.equal(await res3.text(), 'Hello, World!\n');

    assert.equal(Number(mod.requestCount()), 3);
  } finally {
    try {
      mod.shutdown();
    } finally {
      globalThis.console.log = origLog;
      if (prevPort === undefined) {
        delete process.env.PORT;
      } else {
        process.env.PORT = prevPort;
      }
    }
  }

  assert.equal(Number(mod.boundPort()), 0);
  assert.equal(Number(mod.requestCount()), 0);
  assert.equal(Number(mod.activeHandles()), 0);
  assert.equal(Number(mod.activeCallbacks()), 0);
}

describe('node-server-hello-world (WASM + native node-zigar)', () => {
  it('builds a tree-shaken WASM bundle importing only node:http, serves HTTP 200, and shuts down with zero leaks', async () => {
    ensureIsolatedCacheEnv('node-server-hello-world');
    await ensureNodeBindings({ quiet: true });

    const bundlePath = await buildWasmBundle({ quiet: true });
    const bundleSource = readFileSync(bundlePath, 'utf8');
    const assetsDir = join(dirname(bundlePath), 'assets');
    const wasmFiles = readdirSync(assetsDir).filter((f) => f.endsWith('.wasm'));
    assert.equal(wasmFiles.length, 1, `Expected 1 .wasm asset, got ${JSON.stringify(wasmFiles)}`);
    const wasmBytes = statSync(join(assetsDir, wasmFiles[0])).size;
    assert.ok(
      wasmBytes > 0 && wasmBytes < 256 * 1024,
      `Expected compact stripped WASM binary (< 256 KiB), got ${wasmBytes} bytes`,
    );
    assert.ok(
      Buffer.byteLength(bundleSource, 'utf8') < 768 * 1024,
      `Expected compact Rollup JS bundle (< 768 KiB), got ${Buffer.byteLength(bundleSource, 'utf8')} bytes`,
    );

    const nodeImports = [ ...bundleSource.matchAll(/\bfrom\s*["'](node:[^"']+)["']/g) ].map((m) => m[1]);
    assert.deepEqual(
      nodeImports,
      [ 'node:http' ],
      `Expected sole built-in import 'node:http', got ${JSON.stringify(nodeImports)}`,
    );

    const mod = await import(`${pathToFileURL(bundlePath).href}?t=${Date.now()}`);
    await verifyServerLifecycle(mod);

    // Verify async listen error (EADDRINUSE) is captured cleanly without crashing or leaking handles
    const blocker = net.createServer();
    await new Promise((res) => blocker.listen(0, '127.0.0.1', res));
    const busyPort = blocker.address().port;
    const prevPort = process.env.PORT;
    process.env.PORT = String(busyPort);
    try {
      mod.start();
      const deadline = Date.now() + 3_000;
      while (!mod.hadError() && Date.now() < deadline) {
        await delay(10);
      }
      assert.equal(mod.hadError(), true, 'Server error listener must record EADDRINUSE');
      mod.shutdown();
      assert.equal(Number(mod.activeHandles()), 0);
      assert.equal(Number(mod.activeCallbacks()), 0);
    } finally {
      if (prevPort === undefined) delete process.env.PORT;
      else process.env.PORT = prevPort;
      await new Promise((res) => blocker.close(res));
    }

    // Verify runtime 'error' emitted AFTER listening still closes the listening socket on shutdown()
    let capturedServer = null;
    const origListen = net.Server.prototype.listen;
    net.Server.prototype.listen = function (...args) {
      capturedServer = this;
      return origListen.apply(this, args);
    };
    const prevEnvPort = process.env.PORT;
    process.env.PORT = '0';
    try {
      mod.start();
      await waitForBoundPort(mod);
      assert.ok(capturedServer && capturedServer.listening, 'Expected live listening http.Server');
      capturedServer.emit('error', new Error('simulated runtime accept error'));
      assert.equal(mod.hadError(), true, 'Runtime error event must set hadError()');
      mod.shutdown();
      assert.equal(capturedServer.listening, false, 'shutdown() must close server even when hadError() is true');
      assert.equal(Number(mod.activeHandles()), 0);
      assert.equal(Number(mod.activeCallbacks()), 0);
    } finally {
      net.Server.prototype.listen = origListen;
      if (prevEnvPort === undefined) delete process.env.PORT;
      else process.env.PORT = prevEnvPort;
    }
  });

  it('serves HTTP 200 natively via node-zigar and shuts down with zero leaked handles or callbacks', async () => {
    ensureIsolatedCacheEnv('node-server-hello-world');
    await ensureNodeBindings({ quiet: true });

    const mod = await loadNativeZigModule(new URL('../src/server.zig', import.meta.url).href);
    await verifyServerLifecycle(mod);
  });

  for (const [ label, scriptName ] of [
    [ 'WASM CLI runner (run-wasm.mjs)', 'run-wasm.mjs' ],
    [ 'native CLI runner (run-native.mjs)', 'run-native.mjs' ],
  ]) {
    it(`starts ${label}, serves HTTP 200, and naturally drains on SIGTERM with exit code 0`, async () => {
      const child = spawn(process.execPath, [ join(EXAMPLE_DIR, scriptName) ], {
        cwd: EXAMPLE_DIR,
        env: { ...process.env, PORT: '0' },
        stdio: [ 'ignore', 'pipe', 'pipe' ],
      });

      let stdout = '';
      let stderr = '';
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });

      try {
        const deadline = Date.now() + 15_000;
        let match = null;
        while (Date.now() < deadline) {
          match = stdout.match(/Server running at http:\/\/127\.0\.0\.1:(\d+)\//);
          if (match) break;
          if (child.exitCode !== null) {
            throw new Error(`${scriptName} exited early (${child.exitCode}): ${stderr}`);
          }
          await delay(20);
        }
        assert.ok(match, `Timed out waiting for startup banner from ${scriptName}; stdout=${stdout}; stderr=${stderr}`);
        const port = Number(match[1]);
        assert.ok(port > 0 && port <= 65535);

        const res = await fetch(`http://127.0.0.1:${port}/cli-check`);
        assert.equal(res.status, 200);
        assert.equal(res.headers.get('x-request-path'), '/cli-check');
        assert.equal(await res.text(), 'Hello, World!\n');

        child.kill('SIGTERM');
        const [ exitCode, signal ] = await Promise.race([
          once(child, 'exit'),
          delay(10_000).then(() => {
            throw new Error(`${scriptName} hung after SIGTERM instead of draining event loop cleanly`);
          }),
        ]);
        assert.equal(signal, null);
        assert.equal(exitCode, 0);
      } finally {
        if (child.exitCode === null) {
          child.kill('SIGKILL');
        }
      }
    });
  }
});
