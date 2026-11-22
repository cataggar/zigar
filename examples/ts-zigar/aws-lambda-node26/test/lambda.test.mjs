import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { isBuiltin } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildNativeBundle } from '../build-native.mjs';
import { buildWasmBundle } from '../build-wasm.mjs';

const exampleDir = dirname(dirname(fileURLToPath(import.meta.url)));

function makeEvent({
  method = 'GET',
  rawPath = '/',
  rawQueryString = '',
  queryStringParameters,
  headers = {},
  body,
  isBase64Encoded = false,
  apiRequestId = 'apigw-req-001',
} = {}) {
  return {
    version: '2.0',
    routeKey: `${method} ${rawPath}`,
    rawPath,
    rawQueryString,
    headers: {
      host: 'abc123.execute-api.us-east-1.amazonaws.com',
      'user-agent': 'ts-zigar-lambda-test/1.0',
      ...headers,
    },
    ...(queryStringParameters ? { queryStringParameters } : {}),
    requestContext: {
      accountId: '123456789012',
      apiId: 'abc123',
      domainName: 'abc123.execute-api.us-east-1.amazonaws.com',
      domainPrefix: 'abc123',
      http: {
        method,
        path: rawPath,
        protocol: 'HTTP/1.1',
        sourceIp: '203.0.113.42',
        userAgent: 'ts-zigar-lambda-test/1.0',
      },
      requestId: apiRequestId,
      routeKey: `${method} ${rawPath}`,
      stage: '$default',
      time: '15/Apr/2026:12:00:00 +0000',
      timeEpoch: 1776254400000,
    },
    ...(body !== undefined ? { body } : {}),
    isBase64Encoded,
  };
}

function makeContext({
  awsRequestId = '8f7e6d5c-4b3a-2918-0716-253443526170',
  functionName = 'ts-zigar-aws-lambda-node26',
  functionVersion = '$LATEST',
  memoryLimitInMB = '256',
  remainingMs = 14850,
} = {}) {
  return {
    callbackWaitsForEmptyEventLoop: true,
    functionName,
    functionVersion,
    invokedFunctionArn: `arn:aws:lambda:us-east-1:123456789012:function:${functionName}`,
    memoryLimitInMB,
    awsRequestId,
    logGroupName: `/aws/lambda/${functionName}`,
    logStreamName: '2026/04/15/[$LATEST]abcdef0123456789',
    getRemainingTimeInMillis: () => remainingMs,
    done: () => {},
    fail: () => {},
    succeed: () => {},
  };
}

async function verifyLambdaModule(mod, expectedBackend) {
  const baselineHandles = mod.activeJsHandleCount();
  const baselineCallbacks = mod.activeJsCallbackCount();
  const baselineAllocs = mod.activeAllocCount();

  // 1. GET /healthz
  {
    const res = await mod.handler(
      makeEvent({ method: 'GET', rawPath: '/healthz' }),
      makeContext({ awsRequestId: 'req-health-1', remainingMs: 12345 }),
    );
    assert.equal(res.statusCode, 200);
    assert.equal(res.isBase64Encoded, false);
    assert.equal(res.headers['x-aws-request-id'], 'req-health-1');
    const body = JSON.parse(res.body);
    assert.equal(body.status, 'ok');
    assert.equal(body.awsRequestId, 'req-health-1');
    assert.equal(body.remainingTimeMs, 12345);
  }

  // 2. GET / with query parameter + X-Amzn-Trace-Id header
  {
    const traceHeader = 'Root=1-67fe1234-abcdef012345678912345678;Parent=53995c3f42cd8ad8;Sampled=1';
    const res = await mod.handler(
      makeEvent({
        method: 'GET',
        rawPath: '/',
        rawQueryString: 'name=Lambda26',
        queryStringParameters: { name: 'Lambda26' },
        headers: { 'x-amzn-trace-id': traceHeader },
      }),
      makeContext({ awsRequestId: 'req-root-2' }),
    );
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers['x-aws-request-id'], 'req-root-2');
    assert.equal(res.headers['x-amzn-trace-id'], traceHeader);
    assert.deepEqual(res.cookies, ['zigar-request=req-root-2; Path=/; HttpOnly; SameSite=Lax']);
    const body = JSON.parse(res.body);
    assert.equal(body.runtime, 'nodejs26.x');
    assert.equal(body.backend, expectedBackend);
    assert.equal(body.greeting, 'Hello, Lambda26, from Zig on AWS Lambda nodejs26.x!');
    assert.equal(body.sha256, createHash('sha256').update('Lambda26').digest('hex'));
  }

  // 3. POST /digest with base64-encoded binary payload (API Gateway HTTP API v2 binary mode)
  {
    const rawBytes = Buffer.from([0x00, 0xff, 0x7a, 0x69, 0x67, 0x61, 0x72, 0x26]);
    const res = await mod.handler(
      makeEvent({
        method: 'POST',
        rawPath: '/digest',
        body: rawBytes.toString('base64'),
        isBase64Encoded: true,
      }),
      makeContext({ awsRequestId: 'req-b64-3' }),
    );
    assert.equal(res.statusCode, 200);
    const body = JSON.parse(res.body);
    assert.equal(body.payloadBytes, rawBytes.length);
    assert.equal(body.sha256, createHash('sha256').update(rawBytes).digest('hex'));
  }

  // 4. POST /digest with missing body -> 400
  {
    const res = await mod.handler(
      makeEvent({ method: 'POST', rawPath: '/digest' }),
      makeContext({ awsRequestId: 'req-bad-4' }),
    );
    assert.equal(res.statusCode, 400);
    const body = JSON.parse(res.body);
    assert.equal(body.error, 'missing_body');
  }

  // 5. Unknown route -> 404
  {
    const res = await mod.handler(
      makeEvent({ method: 'GET', rawPath: '/does-not-exist' }),
      makeContext({ awsRequestId: 'req-404-5' }),
    );
    assert.equal(res.statusCode, 404);
    const body = JSON.parse(res.body);
    assert.equal(body.error, 'not_found');
  }

  // 6. Concurrent invocations (verifies JSPI / WorkQueue suspension safety + zero leaks)
  {
    const payloads = Array.from({ length: 8 }, (_, idx) => `concurrent-lambda-payload-${idx}`);
    const results = await Promise.all(
      payloads.map((text, idx) =>
        mod.handler(
          makeEvent({ method: 'POST', rawPath: '/digest', body: text }),
          makeContext({ awsRequestId: `req-conc-${idx}` }),
        ),
      ),
    );
    for (let idx = 0; idx < payloads.length; idx++) {
      assert.equal(results[idx].statusCode, 200);
      const parsed = JSON.parse(results[idx].body);
      assert.equal(parsed.awsRequestId, `req-conc-${idx}`);
      assert.equal(parsed.sha256, createHash('sha256').update(payloads[idx]).digest('hex'));
    }
  }

  // 7. Error-path rejections (malformed event + malformed context) with descriptive errors and zero leaks
  await assert.rejects(
    () => mod.handler({ invalid: true }, makeContext({ awsRequestId: 'req-err-event' })),
    /Invalid lambda event/i,
  );
  await assert.rejects(
    () => mod.handler(makeEvent({ method: 'GET', rawPath: '/healthz' }), { awsRequestId: 'missing-fields' }),
    /Invalid lambda context/i,
  );

  assert.equal(mod.activeJsHandleCount(), baselineHandles, 'zero leaked JS handles across invocations');
  assert.equal(mod.activeJsCallbackCount(), baselineCallbacks, 'zero leaked JS callbacks across invocations');
  assert.equal(mod.activeAllocCount(), baselineAllocs, 'zero leaked Zig allocations across invocations');
}

describe('aws-lambda-node26', () => {
  it('builds stripped JSPI WASM bundle with minimal Node.js 26 builtin imports', async () => {
    const info = await buildWasmBundle({ quiet: true });
    assert.ok(info.wasmFiles.length >= 1, 'expected stripped .wasm artifact in dist/');
    assert.ok(
      info.totalWasmBytes > 0 && info.totalWasmBytes < 256 * 1024,
      `expected stripped WASM < 256 KiB, got ${info.totalWasmBytes} bytes`,
    );

    const bundlePath = resolve(exampleDir, 'dist/lambda.mjs');
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
      assert.ok(isBuiltin(spec), `expected only Node.js builtin imports in dist/lambda.mjs, got ${spec}`);
    }
    const tsZigarImports = [...new Set(staticImports.filter((spec) => spec.startsWith('node:')))].sort();
    assert.deepEqual(tsZigarImports, ['node:console', 'node:crypto', 'node:timers/promises']);
  });

  it('executes AWS Lambda nodejs26.x WASM JSPI handler with WebCrypto SHA-256 and zero leaks', async () => {
    const wasmMod = await import('../index.mjs');
    await verifyLambdaModule(wasmMod, 'wasm-jspi');
  });

  it('emits structured CloudWatch JSON telemetry when AWS_LAMBDA_LOG_FORMAT=JSON', () => {
    const probeScript = `
      import { handler } from './index.mjs';
      const event = ${JSON.stringify(
        makeEvent({
          method: 'GET',
          rawPath: '/healthz',
          headers: { 'x-amzn-trace-id': 'Root=1-67fe1234-00112233445566778899aabb' },
        }),
      )};
      const context = {
        callbackWaitsForEmptyEventLoop: true,
        functionName: 'ts-zigar-aws-lambda-node26',
        functionVersion: '$LATEST',
        invokedFunctionArn: 'arn:aws:lambda:us-east-1:123456789012:function:ts-zigar-aws-lambda-node26',
        memoryLimitInMB: '256',
        awsRequestId: 'cw-json-req-99',
        logGroupName: '/aws/lambda/ts-zigar-aws-lambda-node26',
        logStreamName: '2026/04/15/[$LATEST]00112233',
        getRemainingTimeInMillis: () => 9500,
        done() {},
        fail() {},
        succeed() {},
      };
      const res = await handler(event, context);
      if (res.statusCode !== 200) process.exit(2);
    `;
    const proc = spawnSync(process.execPath, ['--input-type=module', '-e', probeScript], {
      cwd: exampleDir,
      env: { ...process.env, AWS_LAMBDA_LOG_FORMAT: 'JSON' },
      encoding: 'utf8',
    });
    assert.equal(proc.status, 0, proc.stderr);
    const lines = proc.stdout.trim().split('\n').filter(Boolean);
    assert.equal(lines.length, 1);
    const entry = JSON.parse(lines[0]);
    assert.equal(entry.level, 'INFO');
    assert.equal(entry.requestId, 'cw-json-req-99');
    assert.equal(entry.traceId, 'Root=1-67fe1234-00112233445566778899aabb');
    assert.equal(entry.method, 'GET');
    assert.equal(entry.path, '/healthz');
    assert.equal(entry.statusCode, 200);
  });

  it('executes standalone native node-zigar WorkQueue handler with identical behavior, clean CloudWatch JSON stdout, and zero leaks', async () => {
    await buildNativeBundle({ quiet: true });
    const nativeMod = await import('../index-native.mjs');
    try {
      await verifyLambdaModule(nativeMod, 'node-zigar-native');
    } finally {
      await nativeMod.shutdown();
    }

    // Verify native entrypoint emits pure 1-line CloudWatch JSON with zero build progress on stdout
    // even when copied to an isolated container/EB directory outside the monorepo!
    const isolatedDir = mkdtempSync(join(tmpdir(), 'lambda-native-isolated-'));
    try {
      cpSync(join(exampleDir, 'package.json'), join(isolatedDir, 'package.json'));
      cpSync(join(exampleDir, 'index-native.mjs'), join(isolatedDir, 'index-native.mjs'));
      cpSync(join(exampleDir, 'dist/native'), join(isolatedDir, 'dist/native'), { recursive: true });

      const probeScript = `
        import { handler, shutdown } from './index-native.mjs';
        const event = ${JSON.stringify(
          makeEvent({
            method: 'GET',
            rawPath: '/healthz',
            headers: { 'x-amzn-trace-id': 'Root=1-67fe1234-native0011223344556677' },
          }),
        )};
        const context = {
          callbackWaitsForEmptyEventLoop: true,
          functionName: 'ts-zigar-aws-lambda-node26',
          functionVersion: '$LATEST',
          invokedFunctionArn: 'arn:aws:lambda:us-east-1:123456789012:function:ts-zigar-aws-lambda-node26',
          memoryLimitInMB: '256',
          awsRequestId: 'cw-native-req-1',
          logGroupName: '/aws/lambda/ts-zigar-aws-lambda-node26',
          logStreamName: '2026/04/15/[$LATEST]native01',
          getRemainingTimeInMillis: () => 8500,
          done() {},
          fail() {},
          succeed() {},
        };
        const res = await handler(event, context);
        await shutdown();
        if (res.statusCode !== 200) process.exit(2);
      `;
      const proc = spawnSync(process.execPath, ['--input-type=module', '-e', probeScript], {
        cwd: isolatedDir,
        env: { ...process.env, AWS_LAMBDA_LOG_FORMAT: 'JSON' },
        encoding: 'utf8',
      });
      assert.equal(proc.status, 0, proc.stderr);
      const lines = proc.stdout.trim().split('\n').filter(Boolean);
      assert.equal(lines.length, 1, `Expected 1 pure JSON line on stdout, got: ${JSON.stringify(proc.stdout)}`);
      const entry = JSON.parse(lines[0]);
      assert.equal(entry.level, 'INFO');
      assert.equal(entry.requestId, 'cw-native-req-1');
      assert.equal(entry.traceId, 'Root=1-67fe1234-native0011223344556677');
      assert.equal(entry.statusCode, 200);
    } finally {
      rmSync(isolatedDir, { recursive: true, force: true });
    }
  });
});
