import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import { tmpdir } from 'node:os';
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
  throw new Error('Timed out waiting for GAE Zig HTTP server to bind an ephemeral port');
}

function saveAndSetEnv(overrides) {
  const saved = new Map();
  for (const [ k, v ] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  return () => {
    for (const [ k, v ] of saved.entries()) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  };
}

async function verifyGaeServiceLifecycle(mod) {
  assert.equal(Number(mod.activeHandles()), 0);
  assert.equal(Number(mod.activeCallbacks()), 0);
  assert.equal(Number(mod.liveZigAllocs()), 0);

  const rawLogs = [];
  const origLog = globalThis.console.log;
  globalThis.console.log = (...args) => {
    rawLogs.push(args.join(' '));
  };

  const restoreEnv = saveAndSetEnv({
    PORT: '0',
    HOST: '0.0.0.0',
    GAE_SERVICE: 'zig-api',
    GAE_VERSION: '20260401t120000',
    GAE_INSTANCE: '00c61b117c9f',
    GOOGLE_CLOUD_PROJECT: 'zigar-cloud-demo',
  });

  try {
    const requestedPort = mod.start();
    assert.equal(requestedPort, 0);

    const port = await waitForBoundPort(mod);
    assert.ok(port > 0 && port <= 65535);

    const startupEntry = rawLogs.map((l) => JSON.parse(l)).find((e) => e.event === 'server_listening');
    assert.ok(startupEntry, `Expected structured server_listening log, got: ${JSON.stringify(rawLogs)}`);
    assert.equal(startupEntry.severity, 'INFO');
    assert.equal(startupEntry['logging.googleapis.com/severity'], 'INFO');
    assert.equal(startupEntry.host, '0.0.0.0');
    assert.equal(startupEntry.port, port);
    assert.equal(startupEntry.service, 'zig-api');

    // 1. GAE warmup request (`/_ah/warmup`)
    const warmupRes = await fetch(`http://127.0.0.1:${port}/_ah/warmup`);
    assert.equal(warmupRes.status, 200);
    assert.equal(warmupRes.headers.get('content-type'), 'application/json; charset=utf-8');
    assert.equal(warmupRes.headers.get('x-appengine-service'), 'zig-api');
    const warmupJson = await warmupRes.json();
    assert.deepEqual(warmupJson, {
      status: 'warmed',
      warmupCount: 1,
      service: 'zig-api',
    });

    // 2. Readiness probe (`/healthz`) + `HEAD /healthz`
    const healthRes = await fetch(`http://127.0.0.1:${port}/healthz`);
    assert.equal(healthRes.status, 200);
    assert.deepEqual(await healthRes.json(), {
      status: 'healthy',
      ready: true,
      service: 'zig-api',
    });

    const headRes = await fetch(`http://127.0.0.1:${port}/healthz`, { method: 'HEAD' });
    assert.equal(headRes.status, 200);
    assert.equal(await headRes.text(), '');

    // 3. Primary service route (`/`) with Google Cloud Trace correlation header
    const traceHeader = '105445aa7843bc8bf206b12000100000/1234567890;o=1';
    const rootRes = await fetch(`http://127.0.0.1:${port}/?region=us-central1`, {
      headers: {
        'x-cloud-trace-context': traceHeader,
        'user-agent': 'GoogleHC/1.0',
      },
    });
    assert.equal(rootRes.status, 200);
    assert.equal(rootRes.headers.get('x-cloud-trace-id'), '105445aa7843bc8bf206b12000100000');
    const rootJson = await rootRes.json();
    assert.equal(rootJson.status, 'ok');
    assert.equal(rootJson.platform, 'google-app-engine');
    assert.equal(rootJson.runtime, 'nodejs26');
    assert.ok(rootJson.nodeVersion.startsWith('v26.'), `Expected Node v26.x, got ${rootJson.nodeVersion}`);
    assert.equal(rootJson.service, 'zig-api');
    assert.equal(rootJson.version, '20260401t120000');
    assert.equal(rootJson.instance, '00c61b117c9f');
    assert.equal(rootJson.project, 'zigar-cloud-demo');
    assert.equal(rootJson.warmupCount, 1);
    assert.equal(rootJson.traceId, '105445aa7843bc8bf206b12000100000');

    // 4. Unknown path -> 404 + unsupported method -> 405
    const missingRes = await fetch(`http://127.0.0.1:${port}/missing/path?x=1`);
    assert.equal(missingRes.status, 404);
    assert.deepEqual(await missingRes.json(), {
      error: 'Not Found',
      path: '/missing/path',
    });

    const methodRes = await fetch(`http://127.0.0.1:${port}/healthz`, { method: 'POST' });
    assert.equal(methodRes.status, 405);
    assert.equal(methodRes.headers.get('allow'), 'GET, HEAD');

    assert.equal(Number(mod.requestCount()), 6);
    assert.equal(Number(mod.warmupCount()), 1);

    // 5. Graceful drain: an active mid-flight HTTP connection must finish cleanly (not reset)
    // when `beginShutdown()` runs, and `isClosed()` becomes true once that response completes.
    const partialSock = net.createConnection({ host: '127.0.0.1', port });
    await once(partialSock, 'connect');
    partialSock.write('GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n');
    await delay(25);

    mod.beginShutdown();
    assert.equal(mod.isClosed(), false, 'Expected server to stay open while active connection drains');

    let rawHttpReply = '';
    partialSock.setEncoding('utf8');
    partialSock.on('data', (chunk) => { rawHttpReply += chunk; });
    partialSock.write('Connection: close\r\n\r\n');
    await once(partialSock, 'close');
    assert.match(rawHttpReply, /^HTTP\/1\.1 200 OK\r\n/);
    assert.match(rawHttpReply, /"status":"healthy"/);

    const drainDeadline = Date.now() + 3_000;
    while (!mod.isClosed() && Date.now() < drainDeadline) {
      await delay(10);
    }
    assert.equal(mod.isClosed(), true);
  } finally {
    try {
      mod.finishShutdown(true);
    } finally {
      globalThis.console.log = origLog;
      restoreEnv();
    }
  }

  // Verify every stdout log line is valid structured Google Cloud Logging JSON
  const entries = rawLogs.map((l) => JSON.parse(l));
  const tracedReqLog = entries.find((e) => e.httpRequest?.requestUrl === '/?region=us-central1');
  assert.ok(tracedReqLog, 'Expected structured httpRequest log entry for /?region=us-central1');
  assert.equal(tracedReqLog['logging.googleapis.com/severity'], 'INFO');
  assert.equal(tracedReqLog.httpRequest.requestMethod, 'GET');
  assert.equal(tracedReqLog.httpRequest.status, 200);
  assert.equal(tracedReqLog.httpRequest.userAgent, 'GoogleHC/1.0');
  assert.equal(
    tracedReqLog['logging.googleapis.com/trace'],
    'projects/zigar-cloud-demo/traces/105445aa7843bc8bf206b12000100000',
  );
  assert.equal(tracedReqLog['logging.googleapis.com/spanId'], '00000000499602d2');
  assert.equal(tracedReqLog['logging.googleapis.com/trace_sampled'], true);

  const notFoundLog = entries.find((e) => e.httpRequest?.requestUrl === '/missing/path?x=1');
  assert.ok(notFoundLog);
  assert.equal(notFoundLog['logging.googleapis.com/severity'], 'WARNING');
  assert.equal(notFoundLog.httpRequest.status, 404);

  const stoppingLog = entries.find((e) => e.event === 'server_stopping');
  assert.ok(stoppingLog, 'Expected structured server_stopping log on shutdown()');

  assert.equal(Number(mod.boundPort()), 0);
  assert.equal(Number(mod.requestCount()), 0);
  assert.equal(Number(mod.warmupCount()), 0);
  assert.equal(Number(mod.activeHandles()), 0);
  assert.equal(Number(mod.activeCallbacks()), 0);
  assert.equal(Number(mod.liveZigAllocs()), 0);
}

describe('gcloud-appengine-node26 (WASM + native node-zigar)', () => {
  it('ships valid app.yaml and .gcloudignore targeting runtime: nodejs26 with prebuilt dist/', () => {
    const appYaml = readFileSync(join(EXAMPLE_DIR, 'app.yaml'), 'utf8');
    assert.match(appYaml, /^runtime:\s*nodejs26\b/m);
    assert.match(appYaml, /^entrypoint:\s*node run-wasm\.mjs\b/m);
    assert.match(appYaml, /-\s*warmup\b/);

    const gcloudIgnorePath = join(EXAMPLE_DIR, '.gcloudignore');
    assert.ok(existsSync(gcloudIgnorePath), 'Expected .gcloudignore in app root');
    const gcloudIgnore = readFileSync(gcloudIgnorePath, 'utf8');
    assert.doesNotMatch(gcloudIgnore, /^\s*dist\/?\s*$/m, '.gcloudignore must NOT exclude dist/');
    assert.match(gcloudIgnore, /^src\/$/m);
    assert.match(gcloudIgnore, /^test\/$/m);
  });

  it('builds a tree-shaken WASM bundle importing only node:http, serves GAE routes + structured Cloud Logging, and shuts down leak-free', async () => {
    ensureIsolatedCacheEnv('gcloud-appengine-node26');
    await ensureNodeBindings({ quiet: true });

    const bundlePath = await buildWasmBundle({ quiet: true });
    const bundleSource = readFileSync(bundlePath, 'utf8');
    const assetsDir = join(dirname(bundlePath), 'assets');
    const wasmFiles = readdirSync(assetsDir).filter((f) => f.endsWith('.wasm'));
    assert.equal(wasmFiles.length, 1);
    const wasmBytes = statSync(join(assetsDir, wasmFiles[0])).size;
    assert.ok(wasmBytes > 0 && wasmBytes < 256 * 1024, `Expected stripped WASM < 256 KiB, got ${wasmBytes}`);

    const nodeImports = [ ...bundleSource.matchAll(/\bfrom\s*["'](node:[^"']+)["']/g) ].map((m) => m[1]);
    assert.deepEqual(nodeImports, [ 'node:http' ]);

    const mod = await import(`${pathToFileURL(bundlePath).href}?t=${Date.now()}`);
    await verifyGaeServiceLifecycle(mod);

    // Verify forced shutdown (`finishShutdown(true)`) while a slow client holds a partial-header
    // socket detaches `close_closure` cleanly before Node emits asynchronous `'close'`!
    {
      const restoreForcedEnv = saveAndSetEnv({ PORT: '0', HOST: '127.0.0.1' });
      const origForcedLog = globalThis.console.log;
      globalThis.console.log = () => {};
      const uncaught = [];
      const onUncaught = (err) => { uncaught.push(err); };
      process.on('uncaughtException', onUncaught);
      let hungSock = null;
      try {
        mod.start();
        const deadline = Date.now() + 3_000;
        while (mod.boundPort() === 0 && Date.now() < deadline) {
          await delay(5);
        }
        const forcedPort = mod.boundPort();
        assert.ok(forcedPort > 0);
        hungSock = net.createConnection({ host: '127.0.0.1', port: forcedPort });
        await once(hungSock, 'connect');
        hungSock.write('GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n');
        await delay(25);

        mod.beginShutdown();
        assert.equal(mod.isClosed(), false, 'Expected server to still be open before forced shutdown');
        mod.finishShutdown(true);
        await once(hungSock, 'close');
        await delay(50);

        assert.deepEqual(uncaught, [], 'Expected zero uncaught exceptions after forced finishShutdown(true)');
        assert.equal(Number(mod.activeHandles()), 0);
        assert.equal(Number(mod.activeCallbacks()), 0);
        assert.equal(Number(mod.liveZigAllocs()), 0);
      } finally {
        process.off('uncaughtException', onUncaught);
        hungSock?.destroy();
        globalThis.console.log = origForcedLog;
        restoreForcedEnv();
      }
    }

    // Verify synchronous `start()` failure (`srv.listen` throw) cleans up state once with zero leaks
    const origListen = http.Server.prototype.listen;
    http.Server.prototype.listen = function throwingListen() {
      throw new Error('synthetic synchronous listen failure');
    };
    try {
      assert.throws(() => mod.start());
      assert.equal(Number(mod.activeHandles()), 0);
      assert.equal(Number(mod.activeCallbacks()), 0);
      assert.equal(Number(mod.liveZigAllocs()), 0);
    } finally {
      http.Server.prototype.listen = origListen;
    }

    // Verify EADDRINUSE handling logs ERROR JSON and cleans up without leaked handles or Zig allocations
    const blocker = net.createServer();
    await new Promise((res) => blocker.listen(0, '0.0.0.0', res));
    const busyPort = blocker.address().port;
    const restoreEnv = saveAndSetEnv({ PORT: String(busyPort), HOST: '0.0.0.0' });
    const errLogs = [];
    const origLog = globalThis.console.log;
    globalThis.console.log = (...args) => { errLogs.push(args.join(' ')); };
    try {
      mod.start();
      const deadline = Date.now() + 3_000;
      while (!mod.hadError() && Date.now() < deadline) {
        await delay(10);
      }
      assert.equal(mod.hadError(), true);
      const parsedErrLogs = errLogs.map((l) => JSON.parse(l));
      const serverErrEntry = parsedErrLogs.find((e) => e.event === 'server_error');
      assert.ok(serverErrEntry, 'Expected structured ERROR server_error log on EADDRINUSE');
      assert.equal(serverErrEntry['logging.googleapis.com/severity'], 'ERROR');
      mod.shutdown();
      assert.equal(Number(mod.activeHandles()), 0);
      assert.equal(Number(mod.activeCallbacks()), 0);
      assert.equal(Number(mod.liveZigAllocs()), 0);
    } finally {
      globalThis.console.log = origLog;
      restoreEnv();
      await new Promise((res) => blocker.close(res));
    }
  });

  it('serves GAE endpoints natively via node-zigar with zero leaked handles, callbacks, or Zig allocations', async () => {
    ensureIsolatedCacheEnv('gcloud-appengine-node26');
    await ensureNodeBindings({ quiet: true });

    const mod = await loadNativeZigModule(new URL('../src/gae_server.zig', import.meta.url).href);
    await verifyGaeServiceLifecycle(mod);
  });

  for (const [ label, scriptName ] of [
    [ 'WASM entrypoint (run-wasm.mjs)', 'run-wasm.mjs' ],
    [ 'native entrypoint (run-native.mjs)', 'run-native.mjs' ],
  ]) {
    it(`starts ${label} on 0.0.0.0:$PORT, responds to /_ah/warmup + /healthz, and drains cleanly on SIGTERM`, async () => {
      const child = spawn(process.execPath, [ join(EXAMPLE_DIR, scriptName) ], {
        cwd: EXAMPLE_DIR,
        env: {
          ...process.env,
          PORT: '0',
          GAE_SERVICE: 'cli-test',
          GOOGLE_CLOUD_PROJECT: 'cli-project',
          ...(scriptName === 'run-wasm.mjs' ? { REBUILD_WASM: '1' } : {}),
        },
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
        let port = 0;
        while (Date.now() < deadline) {
          for (const line of stdout.split('\n')) {
            if (!line.trim()) continue;
            try {
              const parsed = JSON.parse(line);
              if (parsed.event === 'server_listening' && parsed.port > 0) {
                port = Number(parsed.port);
                break;
              }
            } catch {}
          }
          if (port > 0) break;
          if (child.exitCode !== null) {
            throw new Error(`${scriptName} exited early (${child.exitCode}): ${stderr}`);
          }
          await delay(20);
        }
        assert.ok(port > 0, `Timed out waiting for server_listening JSON log; stdout=${stdout}; stderr=${stderr}`);

        const warmupRes = await fetch(`http://127.0.0.1:${port}/_ah/warmup`);
        assert.equal(warmupRes.status, 200);
        assert.equal((await warmupRes.json()).status, 'warmed');

        const healthRes = await fetch(`http://127.0.0.1:${port}/healthz`);
        assert.equal(healthRes.status, 200);
        assert.equal((await healthRes.json()).ready, true);

        child.kill('SIGTERM');
        const [ exitCode, signal ] = await Promise.race([
          once(child, 'exit'),
          delay(10_000).then(() => {
            throw new Error(`${scriptName} hung after SIGTERM instead of draining cleanly`);
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

  it('boots standalone in an isolated gcloud-deployed directory containing only app.yaml, package.json, run-wasm.mjs, and dist/', async () => {
    ensureIsolatedCacheEnv('gcloud-appengine-node26');
    if (!existsSync(join(EXAMPLE_DIR, 'dist/gae_server.mjs'))) {
      await ensureNodeBindings({ quiet: true });
      await buildWasmBundle({ quiet: true });
    }
    const isolatedDir = mkdtempSync(join(tmpdir(), 'gae-deploy-isolated-'));
    try {
      for (const rel of [ 'app.yaml', 'package.json', 'run-wasm.mjs', 'dist' ]) {
        cpSync(join(EXAMPLE_DIR, rel), join(isolatedDir, rel), { recursive: true });
      }

      const child = spawn(process.execPath, [ join(isolatedDir, 'run-wasm.mjs') ], {
        cwd: isolatedDir,
        env: {
          ...process.env,
          PORT: '0',
          GAE_SERVICE: 'deployed-zig',
          GOOGLE_CLOUD_PROJECT: 'prod-gae-project',
        },
        stdio: [ 'ignore', 'pipe', 'pipe' ],
      });

      let stdout = '';
      let stderr = '';
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });

      try {
        const deadline = Date.now() + 10_000;
        let port = 0;
        while (Date.now() < deadline) {
          for (const line of stdout.split('\n')) {
            if (!line.trim()) continue;
            try {
              const parsed = JSON.parse(line);
              if (parsed.event === 'server_listening' && parsed.port > 0) {
                port = Number(parsed.port);
                break;
              }
            } catch {}
          }
          if (port > 0) break;
          if (child.exitCode !== null) {
            throw new Error(`Isolated run-wasm.mjs exited early (${child.exitCode}): ${stderr}`);
          }
          await delay(20);
        }
        assert.ok(port > 0, `Isolated GAE bundle failed to listen; stdout=${stdout}; stderr=${stderr}`);

        const rootRes = await fetch(`http://127.0.0.1:${port}/`);
        assert.equal(rootRes.status, 200);
        const rootJson = await rootRes.json();
        assert.equal(rootJson.service, 'deployed-zig');
        assert.equal(rootJson.project, 'prod-gae-project');

        child.kill('SIGTERM');
        const [ exitCode, signal ] = await Promise.race([
          once(child, 'exit'),
          delay(10_000).then(() => {
            throw new Error('Isolated run-wasm.mjs hung after SIGTERM');
          }),
        ]);
        assert.equal(signal, null);
        assert.equal(exitCode, 0);
      } finally {
        if (child.exitCode === null) {
          child.kill('SIGKILL');
        }
      }
    } finally {
      rmSync(isolatedDir, { recursive: true, force: true });
    }
  });
});
