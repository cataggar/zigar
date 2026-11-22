import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync } from 'node:fs';
import Module, { isBuiltin } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildNativeBundle } from '../build-native.mjs';
import { buildWasmBundle } from '../build-wasm.mjs';
import { resolveOrInstallAzureFunctions } from '../generate.mjs';

const exampleDir = dirname(dirname(fileURLToPath(import.meta.url)));

// Install the `@azure/functions-core` host bridge BEFORE `@azure/functions` is first imported
// (`tryGetCoreApiLazy()` in `@azure/functions` caches the module on first lookup).
const coreHost = {
  programmingModel: null,
  functions: new Map(),
  hooks: new Map(),
  systemLogs: [],
  resetRegistrations() {
    this.functions.clear();
  },
  setProgrammingModel(pm) {
    this.programmingModel = pm;
  },
  registerFunction(metadata, handler) {
    this.functions.set(metadata.name, { metadata, handler });
  },
  registerHook(hookName, callback) {
    const list = this.hooks.get(hookName) ?? [];
    list.push(callback);
    this.hooks.set(hookName, list);
    return { dispose() {} };
  },
  log(level, category, message) {
    this.systemLogs.push({ level, category, message });
  },
};

const origLoad = Module._load;
Module._load = function patchedLoad(request, parent, isMain) {
  if (request === '@azure/functions-core') {
    return coreHost;
  }
  return origLoad.call(this, request, parent, isMain);
};

async function invokeRegisteredHttpFunction(
  functionName,
  {
    invocationId = '9a8b7c6d-5e4f-3a2b-1c0d-ef0123456789',
    method = 'GET',
    url = 'https://zigar-func.azurewebsites.net/api/hello',
    headers = {},
    query = {},
    params = {},
    bodyText,
    bodyBytes,
    traceParent,
    traceState = '',
  } = {},
) {
  const reg = coreHost.functions.get(functionName);
  assert.ok(reg, `Expected Azure Function "${functionName}" to be registered by Zig`);
  assert.ok(coreHost.programmingModel, 'Expected @azure/functions ProgrammingModel to be registered');

  const triggerEntry = Object.entries(reg.metadata.bindings).find(([, b]) => b.direction === 'in');
  assert.ok(triggerEntry, `Expected inbound trigger binding on "${functionName}"`);
  const [triggerName] = triggerEntry;

  const userLogs = [];
  const allLogs = [];
  const coreCtx = {
    invocationId,
    metadata: reg.metadata,
    state: 'invocation',
    log(level, category, message) {
      allLogs.push({ level, category, message });
      if (category === 'user') {
        userLogs.push({ level, message });
      }
    },
    request: {
      inputData: [
        {
          name: triggerName,
          data: {
            http: {
              method,
              url,
              headers: {
                host: 'zigar-func.azurewebsites.net',
                'user-agent': 'ts-zigar-azure-functions-test/1.0',
                ...headers,
              },
              query,
              params,
              body:
                bodyBytes !== undefined
                  ? { bytes: bodyBytes }
                  : bodyText !== undefined
                    ? { string: bodyText }
                    : undefined,
            },
          },
        },
      ],
      traceContext: traceParent
        ? { traceParent, traceState, attributes: { 'az.schema': 'v4' } }
        : undefined,
      retryContext: undefined,
      triggerMetadata: {},
    },
  };

  const invModel = coreHost.programmingModel.getInvocationModel(coreCtx);
  const { context, inputs } = await invModel.getArguments();
  const rawResult = await invModel.invokeFunction(context, inputs, reg.handler);
  const rpcResponse = await invModel.getResponse(context, rawResult);

  const systemWarnings = allLogs.filter((entry) => entry.category === 'system' && entry.level === 'warning');
  assert.deepEqual(systemWarnings, [], 'Expected zero unawaited-async system warnings from InvocationModel');

  const httpOut = rpcResponse.returnValue?.http;
  assert.ok(httpOut, 'Expected RPC HTTP returnValue from InvocationModel.getResponse');
  const bodyBuf = httpOut.body?.bytes
    ? Buffer.from(httpOut.body.bytes)
    : Buffer.from(httpOut.body?.string ?? '', 'utf8');

  return {
    statusCode: Number(httpOut.statusCode),
    headers: httpOut.headers,
    cookies: httpOut.cookies,
    bodyText: bodyBuf.toString('utf8'),
    rawResult,
    userLogs,
  };
}

async function verifyAzureFunctionsSuite(mod, expectedBackend) {
  // Verify Zig registered both `hello` and `healthz` HTTP triggers with expected v4 metadata
  assert.ok(coreHost.functions.has('hello'), 'expected `hello` HTTP trigger registered from Zig');
  assert.ok(coreHost.functions.has('healthz'), 'expected `healthz` HTTP trigger registered from Zig');

  const helloMeta = coreHost.functions.get('hello').metadata;
  const helloTrigger = Object.values(helloMeta.bindings).find((b) => b.type === 'httpTrigger');
  assert.ok(helloTrigger);
  assert.deepEqual(helloTrigger.methods, ['GET', 'POST']);
  assert.equal(helloTrigger.authLevel, 'anonymous');
  assert.equal(helloTrigger.route, 'hello/{category?}');
  assert.equal(helloMeta.bindings.$return?.type, 'http');

  const healthMeta = coreHost.functions.get('healthz').metadata;
  const healthTrigger = Object.values(healthMeta.bindings).find((b) => b.type === 'httpTrigger');
  assert.ok(healthTrigger);
  assert.deepEqual(healthTrigger.methods, ['GET']);
  assert.equal(healthTrigger.route, 'healthz');

  const baselineHandles = mod.activeJsHandleCount();
  const baselineCallbacks = mod.activeJsCallbackCount();
  const baselineAllocs = mod.activeAllocCount();
  const baselineBytes = mod.activeAllocBytes();

  // 1. GET /api/healthz via `healthz` trigger + Application Insights structured user telemetry
  {
    const tp = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';
    const res = await invokeRegisteredHttpFunction('healthz', {
      invocationId: 'inv-health-1',
      method: 'GET',
      url: 'https://zigar-func.azurewebsites.net/api/healthz',
      traceParent: tp,
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers['x-ms-invocation-id'], 'inv-health-1');
    assert.equal(res.headers.traceparent, tp);
    const body = JSON.parse(res.bodyText);
    assert.equal(body.status, 'ok');
    assert.equal(body.runtime, 'NODE|26');
    assert.equal(body.functionName, 'healthz');
    assert.equal(body.invocationId, 'inv-health-1');

    assert.equal(res.userLogs.length, 1);
    assert.equal(res.userLogs[0].level, 'information');
    const telemetry = JSON.parse(res.userLogs[0].message);
    assert.equal(telemetry.level, 'INFO');
    assert.equal(telemetry.invocationId, 'inv-health-1');
    assert.equal(telemetry.traceParent, tp);
    assert.equal(telemetry.statusCode, 200);
  }

  // 2. GET /api/hello/cloud?name=Azure26 with route param, query param, Cookie, and SHA-256
  {
    const tp = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';
    const res = await invokeRegisteredHttpFunction('hello', {
      invocationId: 'inv-hello-2',
      method: 'GET',
      url: 'https://zigar-func.azurewebsites.net/api/hello/cloud?name=Azure26',
      query: { name: 'Azure26' },
      params: { category: 'cloud' },
      headers: { 'x-ms-client-request-id': 'client-req-42' },
      traceParent: tp,
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers['x-ms-invocation-id'], 'inv-hello-2');
    assert.equal(res.headers.traceparent, tp);
    assert.equal(res.cookies.length, 1);
    assert.equal(res.cookies[0].name, 'zigar-invocation');
    assert.equal(res.cookies[0].value, 'inv-hello-2');
    assert.equal(res.cookies[0].sameSite, 'lax');
    assert.equal(res.cookies[0].httpOnly?.value, true);

    const body = JSON.parse(res.bodyText);
    assert.equal(body.runtime, 'NODE|26');
    assert.equal(body.backend, expectedBackend);
    assert.equal(body.category, 'cloud');
    assert.equal(body.clientRequestId, 'client-req-42');
    assert.equal(body.greeting, 'Hello, Azure26, from Zig on Azure Functions v4 (Node.js 26)!');
    assert.equal(body.sha256, createHash('sha256').update('Azure26').digest('hex'));
  }

  // 3. POST /api/hello/digest with raw binary payload (verifies HttpRequest.arrayBuffer() + SHA-256)
  {
    const rawBytes = Uint8Array.from([0x00, 0xff, 0x61, 0x7a, 0x75, 0x72, 0x65, 0x26]);
    const res = await invokeRegisteredHttpFunction('hello', {
      invocationId: 'inv-b64-3',
      method: 'POST',
      url: 'https://zigar-func.azurewebsites.net/api/hello/digest',
      params: { category: 'digest' },
      bodyBytes: rawBytes,
    });
    assert.equal(res.statusCode, 200);
    const body = JSON.parse(res.bodyText);
    assert.equal(body.payloadBytes, rawBytes.byteLength);
    assert.equal(body.sha256, createHash('sha256').update(rawBytes).digest('hex'));
  }

  // 4. POST /api/hello/digest with empty body -> 400 + warning user telemetry
  {
    const res = await invokeRegisteredHttpFunction('hello', {
      invocationId: 'inv-empty-4',
      method: 'POST',
      url: 'https://zigar-func.azurewebsites.net/api/hello/digest',
      params: { category: 'digest' },
    });
    assert.equal(res.statusCode, 400);
    const body = JSON.parse(res.bodyText);
    assert.equal(body.error, 'missing_body');
    assert.equal(res.userLogs.length, 1);
    assert.equal(res.userLogs[0].level, 'warning');
  }

  // 5. Disallowed HTTP method -> 405
  {
    const res = await invokeRegisteredHttpFunction('hello', {
      invocationId: 'inv-put-5',
      method: 'PUT',
      url: 'https://zigar-func.azurewebsites.net/api/hello/general',
      params: { category: 'general' },
    });
    assert.equal(res.statusCode, 405);
    const body = JSON.parse(res.bodyText);
    assert.equal(body.error, 'method_not_allowed');
  }

  // 6. Concurrent 8-way invocations (verifies JSPI / WorkQueue suspension safety + zero leaks)
  {
    const payloads = Array.from({ length: 8 }, (_, idx) => `concurrent-azure-payload-${idx}`);
    const results = await Promise.all(
      payloads.map((text, idx) =>
        invokeRegisteredHttpFunction('hello', {
          invocationId: `inv-conc-${idx}`,
          method: 'POST',
          url: 'https://zigar-func.azurewebsites.net/api/hello/digest',
          params: { category: 'digest' },
          bodyText: text,
        }),
      ),
    );
    for (let idx = 0; idx < payloads.length; idx++) {
      assert.equal(results[idx].statusCode, 200);
      const parsed = JSON.parse(results[idx].bodyText);
      assert.equal(parsed.invocationId, `inv-conc-${idx}`);
      assert.equal(parsed.sha256, createHash('sha256').update(payloads[idx]).digest('hex'));
    }
  }

  // 7. Error-path rejections (malformed request + malformed context) with descriptive errors and zero leaks
  const { InvocationContext, HttpRequest } = await import('@azure/functions');
  const validCtx = new InvocationContext({ invocationId: 'inv-err-req', functionName: 'hello' });
  const validReq = new HttpRequest({ method: 'GET', url: 'https://zigar-func.azurewebsites.net/api/hello' });

  await assert.rejects(
    () => mod.helloHandler({ invalid: true }, validCtx),
    /Invalid http request/i,
  );
  await assert.rejects(
    () => mod.helloHandler(validReq, { invocationId: 'missing-context-methods' }),
    /Invalid invocation context/i,
  );

  assert.equal(mod.activeJsHandleCount(), baselineHandles, 'zero leaked JS handles across invocations');
  assert.equal(mod.activeJsCallbackCount(), baselineCallbacks, 'zero leaked JS callbacks across invocations');
  assert.equal(mod.activeAllocCount(), baselineAllocs, 'zero leaked Zig allocations across invocations');
  assert.equal(mod.activeAllocBytes(), baselineBytes, 'zero leaked Zig bytes across invocations');
}

describe('azure-functions-node26', () => {
  it('builds stripped JSPI WASM bundle with only @azure/functions + Node.js 26 builtin imports', async () => {
    const info = await buildWasmBundle({ quiet: true });
    assert.ok(info.wasmFiles.length >= 1, 'expected stripped .wasm artifact in dist/assets/');
    assert.ok(
      info.totalWasmBytes > 0 && info.totalWasmBytes < 256 * 1024,
      `expected stripped WASM < 256 KiB, got ${info.totalWasmBytes} bytes`,
    );

    const bundlePath = resolve(exampleDir, 'dist/azure-func.mjs');
    assert.ok(existsSync(bundlePath));
    assert.ok(statSync(bundlePath).size > 0);

    const bundleText = readFileSync(bundlePath, 'utf8');
    const staticImports = [...bundleText.matchAll(/^\s*import\s+.*?from\s+['"]([^'"]+)['"]/gm)].map(
      (m) => m[1],
    );
    const dynamicImports = [...bundleText.matchAll(/\bimport\(\s*['"]([^'"]+)['"]\s*\)/g)].map(
      (m) => m[1],
    );
    const allImports = [...new Set([...staticImports, ...dynamicImports])].sort();
    for (const spec of allImports) {
      assert.ok(
        isBuiltin(spec) || spec === '@azure/functions',
        `expected only @azure/functions or Node.js builtin imports in dist/azure-func.mjs, got ${spec}`,
      );
    }
    const nonRuntimeBuiltins = [...new Set(staticImports.filter((spec) => spec.startsWith('node:') || spec === '@azure/functions'))].sort();
    assert.deepEqual(nonRuntimeBuiltins, ['@azure/functions', 'node:crypto', 'node:timers/promises', 'node:url']);
  });

  it('registers and executes Azure Functions v4 WASM JSPI triggers through @azure/functions InvocationModel with zero leaks', async () => {
    coreHost.resetRegistrations();
    const wasmMod = await import('../functions/hello.mjs');
    await verifyAzureFunctionsSuite(wasmMod, 'wasm-jspi');
  });

  it('registers and executes standalone native node-zigar WorkQueue triggers and runs cleanly from an isolated Zip Deploy directory', async () => {
    await buildNativeBundle({ quiet: true });
    coreHost.resetRegistrations();
    // Importing `functions-native/hello.mjs` must auto-register triggers and `appTerminate` hook at module top level
    // (matching Azure Functions v4 worker `"main": "functions-native/*.mjs"` discovery).
    const nativeMod = await import('../functions-native/hello.mjs');
    assert.ok(coreHost.hooks.get('appTerminate')?.length >= 1, 'expected appTerminate hook registered');
    try {
      await verifyAzureFunctionsSuite(nativeMod, 'node-zigar-native');
    } finally {
      await nativeMod.shutdown();
    }

    // Verify both WASM (`"main": "functions/*.mjs"`) and standalone Native (`"main": "functions-native/*.mjs"`)
    // auto-register triggers at import time from a completely isolated Zip Deploy directory outside the monorepo!
    const { azureFunctionsDir } = resolveOrInstallAzureFunctions();
    const isolatedDir = mkdtempSync(join(tmpdir(), 'azure-func-isolated-'));
    try {
      cpSync(join(exampleDir, 'host.json'), join(isolatedDir, 'host.json'));
      cpSync(join(exampleDir, 'package.json'), join(isolatedDir, 'package.json'));
      cpSync(join(exampleDir, 'functions'), join(isolatedDir, 'functions'), { recursive: true });
      cpSync(join(exampleDir, 'functions-native'), join(isolatedDir, 'functions-native'), { recursive: true });
      cpSync(join(exampleDir, 'dist'), join(isolatedDir, 'dist'), { recursive: true });
      mkdirSync(join(isolatedDir, 'node_modules/@azure'), { recursive: true });
      symlinkSync(azureFunctionsDir, join(isolatedDir, 'node_modules/@azure/functions'), 'dir');

      const probeScript = `
        import { globSync, readFileSync, rmSync } from 'node:fs';
        import Module from 'node:module';
        import { pathToFileURL } from 'node:url';

        const registered = new Map();
        const orig = Module._load;
        Module._load = function (req, parent, isMain) {
          if (req === '@azure/functions-core') {
            return {
              setProgrammingModel() {},
              registerFunction(meta, handler) { registered.set(meta.name, handler); },
              registerHook() { return { dispose() {} }; },
              log() {},
            };
          }
          return orig.call(this, req, parent, isMain);
        };
        const { HttpRequest, InvocationContext } = await import('@azure/functions');
        const pkg = JSON.parse(readFileSync('./package.json', 'utf8'));

        // 1. Default WASM Zip Deploy discovery via package.json "main" ("functions/*.mjs")
        for (const entry of globSync(pkg.main)) {
          await import(pathToFileURL(entry).href);
        }
        if (!registered.has('hello') || !registered.has('healthz')) process.exit(2);
        const wasmRes = await registered.get('healthz')(
          new HttpRequest({ method: 'GET', url: 'https://isolated.azurewebsites.net/api/healthz' }),
          new InvocationContext({ invocationId: 'iso-wasm-1', functionName: 'healthz' }),
        );
        if (wasmRes.status !== 200) process.exit(3);

        // 2. Native Zip Deploy discovery via "functions-native/*.mjs" (auto-registers on import, zero manual register())
        registered.clear();
        let nativeMod;
        for (const entry of globSync('functions-native/*.mjs')) {
          nativeMod = await import(pathToFileURL(entry).href);
        }
        if (!registered.has('hello') || !registered.has('healthz')) process.exit(4);
        const nativeRes = await registered.get('healthz')(
          new HttpRequest({ method: 'GET', url: 'https://isolated.azurewebsites.net/api/healthz' }),
          new InvocationContext({ invocationId: 'iso-native-1', functionName: 'healthz' }),
        );
        await nativeMod.shutdown();
        if (nativeRes.status !== 200) process.exit(5);

        // 3. Verify clear error message if dist/native is missing in a Zip Deploy package
        rmSync('./dist/native', { recursive: true, force: true });
        let missingBundleErr = '';
        try {
          await import('./functions-native/hello.mjs?missing=1');
        } catch (err) {
          missingBundleErr = String(err?.message || err);
        }
        if (!missingBundleErr.includes('Run "npm run build:native" before Zip Deploy')) {
          process.exit(6);
        }

        console.log(JSON.stringify({ wasmStatus: wasmRes.status, nativeStatus: nativeRes.status }));
      `;
      const proc = spawnSync(process.execPath, ['--input-type=module', '-e', probeScript], {
        cwd: isolatedDir,
        env: process.env,
        encoding: 'utf8',
      });
      assert.equal(proc.status, 0, proc.stderr);
      const summary = JSON.parse(proc.stdout.trim().split('\n').pop());
      assert.deepEqual(summary, { wasmStatus: 200, nativeStatus: 200 });

      // Verify first SIGTERM drains WorkQueue and terminates the worker even with an open event-loop handle
      cpSync(join(exampleDir, 'dist/native'), join(isolatedDir, 'dist/native'), { recursive: true });
      const sigtermScript = `
        import Module from 'node:module';
        const orig = Module._load;
        Module._load = function (req, parent, isMain) {
          if (req === '@azure/functions-core') {
            return {
              setProgrammingModel() {},
              registerFunction() {},
              registerHook() { return { dispose() {} }; },
              log() {},
            };
          }
          return orig.call(this, req, parent, isMain);
        };
        const mod = await import('./functions-native/hello.mjs');
        await mod.ensureStarted();
        setInterval(() => {}, 60_000);
        process.kill(process.pid, 'SIGTERM');
      `;
      const sigProc = spawnSync(process.execPath, ['--input-type=module', '-e', sigtermScript], {
        cwd: isolatedDir,
        env: process.env,
        timeout: 5000,
        killSignal: 'SIGKILL',
        encoding: 'utf8',
      });
      assert.equal(sigProc.error, undefined, `Expected worker to exit cleanly before timeout, got error=${sigProc.error?.message}`);
      assert.equal(sigProc.signal, 'SIGTERM', `Expected worker to exit with SIGTERM, got status=${sigProc.status} signal=${sigProc.signal} stderr=${sigProc.stderr}`);
    } finally {
      rmSync(isolatedDir, { recursive: true, force: true });
    }
  });
});
