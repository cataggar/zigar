import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, rmSync } from 'node:fs';
import { copyFile, cp, mkdir, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire, register } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { runTs } from '../../zigar-compiler/src/index.js';
import '../dist/index.cjs';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
const SAMPLE_DIR = resolve(REPO_ROOT, 'zigar-compiler/test/zig-samples/js-value/ts-m4-node26-core');
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m4-node26-core-node-${process.pid}`);
const BUILD_DIR = join(TEST_ROOT, 'zig-build');
const CACHE_DIR = join(TEST_ROOT, 'zig-cache');

let esmLoaderEnsured = false;

async function importZigEsm(zigUrl) {
  try {
    return await import(zigUrl);
  } catch (err) {
    if (!esmLoaderEnsured && err && err.code === 'ERR_UNKNOWN_FILE_EXTENSION') {
      register(new URL('../dist/index.js', import.meta.url));
      esmLoaderEnsured = true;
      return await import(zigUrl);
    }
    throw err;
  }
}

function resolveTypesNode26Dir() {
  const candidates = [
    process.env.TS_ZIGAR_TYPES_NODE26_DIR,
    join(REPO_ROOT, '.cache/ts-zigar/types-node26/node_modules/@types/node'),
    join(REPO_ROOT, '.cache/types-node26/node_modules/@types/node'),
  ].filter(Boolean);
  for (const cand of candidates) {
    if (existsSync(join(cand, 'package.json'))) return cand;
  }
  return null;
}

function startLocalHttpAndWsServer() {
  const sockets = new Set();
  let wsGateOpen = true;
  const gatedUpgrades = [];
  const flushUpgrade = ({ accept, socket }) => {
    if (socket.destroyed) return;
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
  };
  const server = createServer((req, res) => {
    if (req.url?.includes('ws_gate=prepare')) {
      wsGateOpen = false;
    } else if (req.url?.includes('ws_gate=release')) {
      wsGateOpen = true;
      while (gatedUpgrades.length > 0) {
        flushUpgrade(gatedUpgrades.shift());
      }
    }
    res.writeHead(200, {
      'content-type': 'text/plain; charset=utf-8',
      'x-zigar-m4': 'node26-http',
    });
    res.end(`hello-from-node26-fetch:${req.url}`);
  });
  server.on('connection', (s) => {
    sockets.add(s);
    s.on('close', () => sockets.delete(s));
  });
  server.on('upgrade', (req, socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    const key = req.headers['sec-websocket-key'];
    const accept = createHash('sha1')
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest('base64');
    if (wsGateOpen) {
      flushUpgrade({ accept, socket });
    } else {
      gatedUpgrades.push({ accept, socket });
    }
    let buf = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      buf = Buffer.concat([ buf, chunk ]);
      while (buf.length >= 2) {
        const opcode = buf[0] & 0x0f;
        const masked = (buf[1] & 0x80) !== 0;
        const payloadLen = buf[1] & 0x7f;
        const headerLen = 2 + (masked ? 4 : 0);
        if (buf.length < headerLen + payloadLen) break;
        const payload = Buffer.from(buf.subarray(headerLen, headerLen + payloadLen));
        if (masked) {
          const mask = buf.subarray(2, 6);
          for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
        }
        buf = buf.subarray(headerLen + payloadLen);
        if (opcode === 0x1) {
          const reply = Buffer.from(`echo:${payload.toString('utf8')}`, 'utf8');
          socket.write(Buffer.concat([ Buffer.from([ 0x81, reply.length ]), reply ]));
        } else if (opcode === 0x8) {
          socket.end(Buffer.from([ 0x88, 0x02, 0x03, 0xe8 ]));
          return;
        }
      }
    });
  });

  return new Promise((resolvePromise, rejectPromise) => {
    server.once('error', rejectPromise);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolvePromise({
        httpUrl: `http://127.0.0.1:${port}/ping?from=zig`,
        wsUrl: `ws://127.0.0.1:${port}/ws`,
        close: () => new Promise((done) => {
          for (const s of sockets) s.destroy();
          server.close(() => done());
        }),
      });
    });
  });
}

async function generateBindings(typesNodeDir, outDir) {
  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm');
  const cliArgs = [
    '-t', typesNodeDir,
    '-m', 'globals',
    '-m', 'node:buffer',
    '-m', 'fs',
    '-m', 'node:events',
    '-m', 'node:path',
    '-d', outDir,
  ];
  if (existsSync(nativeBin) && existsSync(componentWasm)) {
    await execFileAsync(nativeBin, [ '--component', componentWasm, ...cliArgs ], {
      cwd: REPO_ROOT,
      env: process.env,
    });
    return;
  }
  const code = await runTs(cliArgs, { silent: true, buildDir: BUILD_DIR });
  expect(code).to.equal(0);
}

describe('ts-zigar M4.1a Live Runtime Roundtrip: @types/node@26 node:* specifiers, globals (console, process, fetch, WebSocket), and zero-copy Buffer (node-zigar Native)', function () {
  this.timeout(300_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');
  let srv;
  let probeFilePath;

  before(async function () {
    const typesNodeDir = resolveTypesNode26Dir();
    if (!typesNodeDir || !process.version.startsWith('v26.')) {
      this.skip();
      return;
    }
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    probeFilePath = join(TEST_ROOT, 'probe.txt');
    await writeFile(probeFilePath, 'ok', 'utf-8');
    srv = await startLocalHttpAndWsServer();
    process.env.TS_ZIGAR_M4_HOST = 'node26-ok';
    process.env.TS_ZIGAR_M4_HTTP_URL = srv.httpUrl;
    process.env.TS_ZIGAR_M4_WS_URL = srv.wsUrl;
    await generateBindings(typesNodeDir, generatedMasterDir);
  });

  after(async function () {
    delete process.env.TS_ZIGAR_M4_HOST;
    delete process.env.TS_ZIGAR_M4_ZIG_ENV;
    delete process.env.TS_ZIGAR_M4_HTTP_URL;
    delete process.env.TS_ZIGAR_M4_WS_URL;
    if (srv) await srv.close();
    if (existsSync(TEST_ROOT)) {
      rmSync(TEST_ROOT, { recursive: true, force: true });
    }
  });

  for (const loaderMode of [ 'esm', 'cjs' ]) {
    describe(`Loader mode: ${loaderMode.toUpperCase()}`, function () {
      let mod;
      let started = false;

      before(async function () {
        const targetDir = join(TEST_ROOT, loaderMode);
        await mkdir(targetDir, { recursive: true });
        await copyFile(join(SAMPLE_DIR, 'consumer.zig'), join(targetDir, 'consumer.zig'));
        await cp(generatedMasterDir, join(targetDir, 'generated'), { recursive: true });
        await writeFile(
          join(targetDir, 'node-zigar.config.json'),
          JSON.stringify({
            optimize: 'ReleaseSafe',
            buildDir: BUILD_DIR,
            cacheDir: CACHE_DIR,
            quiet: true,
          }, null, 2),
          'utf-8',
        );

        const consumerZigPath = join(targetDir, 'consumer.zig');
        if (loaderMode === 'esm') {
          const zigUrl = `${pathToFileURL(consumerZigPath).href}?optimize=ReleaseSafe&quiet=1`;
          mod = await importZigEsm(zigUrl);
        } else {
          const req = createRequire(pathToFileURL(join(targetDir, 'entry.cjs')).href);
          mod = req('./consumer.zig?optimize=ReleaseSafe&quiet=1');
        }
        await mod.startup(1);
        started = true;
      });

      after(async function () {
        if (mod && started) {
          await mod.shutdown();
          started = false;
        }
      });

      afterEach(function () {
        if (mod) {
          expect(Number(mod.activeHandles())).to.equal(0);
          expect(Number(mod.activeCallbacks())).to.equal(0);
          expect(Number(mod.liveZigAllocs())).to.equal(0);
          expect(Boolean(mod.hasPendingCapturedError())).to.be.false;
        }
      });

      it('roundtrips main-thread process, console, zero-copy Buffer.subarray, URL, TextEncoder/TextDecoder, AbortController, crypto, and node:* modules', function () {
        delete process.env.TS_ZIGAR_M4_ZIG_ENV;
        const logged = [];
        const origLog = console.log;
        console.log = (...args) => { logged.push(args.join(' ')); };
        try {
          expect(mod.exerciseSyncNode26Core(probeFilePath).string).to.equal('sync-node26-core-ok');
        } finally {
          console.log = origLog;
        }
        expect(logged).to.include('zigar-m4-console-ok');
        expect(process.env.TS_ZIGAR_M4_ZIG_ENV).to.equal('written-by-zig');
        expect(mod.probeSyncFetchHostUnavailable()).to.equal(true);
      });

      it('roundtrips live globals.fetch (Response.text/bytes) and globals.WebSocket against a Node.js 26 server on WorkQueue', async function () {
        const res = await mod.runAsyncFetchAndWebSocket();
        expect(res.string).to.equal('async-fetch-ws-ok');
      });
    });
  }
});
