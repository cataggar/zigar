import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import { registerHooks } from 'node:module';
import { dirname, extname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

import { ensureIsolatedCacheEnv, ensureMonacoBindings, loadNativeZigModule } from '../../monaco-editor/generate.mjs';
import { APP_DIR, DIST_DIR, ensureViteDeps } from '../build.mjs';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));

registerHooks({
  load(url, context, nextLoad) {
    if (url.endsWith('.css') || url.endsWith('.ttf')) {
      return {
        format: 'module',
        shortCircuit: true,
        source: 'export default "";\n',
      };
    }
    return nextLoad(url, context);
  },
});

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.svg': 'image/svg+xml',
};

function unwrapString(val) {
  if (typeof val === 'string') return val;
  if (val && typeof val.string === 'string') return val.string;
  return String(val);
}

function installJsdomGlobals(win) {
  const saved = new Map();
  const added = new Set();

  const rememberAndSet = (key, descriptor) => {
    if (!saved.has(key) && !added.has(key)) {
      if (Object.prototype.hasOwnProperty.call(globalThis, key)) {
        saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
      } else {
        added.add(key);
      }
    }
    Object.defineProperty(globalThis, key, { ...descriptor, configurable: true });
  };

  win.matchMedia = (query) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener() {},
    removeListener() {},
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent() {
      return false;
    },
  });
  win.ResizeObserver = class ResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  win.IntersectionObserver = class IntersectionObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  };
  win.CSS = win.CSS || {};
  win.CSS.supports = () => true;
  win.CSS.escape = (s) => String(s);
  win.document.queryCommandSupported = () => false;
  win.HTMLElement.prototype.getBoundingClientRect = function getBoundingClientRect() {
    return {
      x: 0,
      y: 0,
      top: 0,
      left: 0,
      right: 960,
      bottom: 640,
      width: 960,
      height: 640,
      toJSON() {},
    };
  };
  win.HTMLCanvasElement.prototype.getContext = function getContext() {
    return {
      font: '',
      fillStyle: '#000',
      fillRect() {},
      clearRect() {},
      fillText() {},
      measureText(text) {
        return { width: String(text ?? '').length * 8 };
      },
      getImageData() {
        return { data: new Uint8ClampedArray(4) };
      },
      putImageData() {},
      scale() {},
      save() {},
      restore() {},
    };
  };

  const spawnedWorkers = [];
  win.Worker = class MockBrowserWorker extends EventTarget {
    constructor(url, options) {
      super();
      this.url = String(url);
      this.options = options ?? null;
      spawnedWorkers.push({ url: this.url, options: this.options });
    }
    postMessage() {}
    terminate() {}
  };

  const activeTimeouts = new Set();
  const activeIntervals = new Set();
  const origSetTimeout = globalThis.setTimeout;
  const origClearTimeout = globalThis.clearTimeout;
  const origSetInterval = globalThis.setInterval;
  const origClearInterval = globalThis.clearInterval;

  const origWinSetInterval = win.setInterval.bind(win);
  const origWinClearInterval = win.clearInterval.bind(win);
  const origWinSetTimeout = win.setTimeout.bind(win);
  const origWinClearTimeout = win.clearTimeout.bind(win);
  const activeWinIntervals = new Set();
  const activeWinTimeouts = new Set();

  win.setInterval = (fn, delay, ...args) => {
    const id = origWinSetInterval(fn, delay, ...args);
    activeWinIntervals.add(id);
    return id;
  };
  win.clearInterval = (id) => {
    activeWinIntervals.delete(id);
    return origWinClearInterval(id);
  };
  win.setTimeout = (fn, delay, ...args) => {
    const id = origWinSetTimeout((...cbArgs) => {
      activeWinTimeouts.delete(id);
      fn(...cbArgs);
    }, delay, ...args);
    activeWinTimeouts.add(id);
    return id;
  };
  win.clearTimeout = (id) => {
    activeWinTimeouts.delete(id);
    return origWinClearTimeout(id);
  };

  rememberAndSet('setTimeout', {
    value: (fn, delay, ...args) => {
      const id = origSetTimeout((...cbArgs) => {
        activeTimeouts.delete(id);
        fn(...cbArgs);
      }, delay, ...args);
      activeTimeouts.add(id);
      return id;
    },
    writable: true,
  });
  rememberAndSet('clearTimeout', {
    value: (id) => {
      activeTimeouts.delete(id);
      return origClearTimeout(id);
    },
    writable: true,
  });
  rememberAndSet('setInterval', {
    value: (fn, delay, ...args) => {
      const id = origSetInterval(fn, delay, ...args);
      activeIntervals.add(id);
      return id;
    },
    writable: true,
  });
  rememberAndSet('clearInterval', {
    value: (id) => {
      activeIntervals.delete(id);
      return origClearInterval(id);
    },
    writable: true,
  });

  for (const fnName of [ 'addEventListener', 'removeEventListener', 'dispatchEvent', 'postMessage' ]) {
    rememberAndSet(fnName, {
      value: win[fnName].bind(win),
      writable: true,
    });
  }

  for (const key of Object.getOwnPropertyNames(win)) {
    if (key === 'undefined' || key === 'globalThis' || key in globalThis) continue;
    const desc = Object.getOwnPropertyDescriptor(win, key);
    if (!desc) continue;
    try {
      rememberAndSet(key, desc);
    } catch {}
  }

  const browserGlobals = [
    'window',
    'self',
    'document',
    'location',
    'CustomEvent',
    'Event',
    'UIEvent',
    'MouseEvent',
    'KeyboardEvent',
    'FocusEvent',
    'MutationObserver',
    'ResizeObserver',
    'IntersectionObserver',
    'CSS',
    'Worker',
    'matchMedia',
    'requestAnimationFrame',
    'cancelAnimationFrame',
    'getComputedStyle',
  ];
  for (const key of browserGlobals) {
    if (win[key] !== undefined) {
      rememberAndSet(key, { value: win[key], writable: true });
    }
  }

  return {
    spawnedWorkers,
    restore() {
      for (const id of activeWinTimeouts) {
        origWinClearTimeout(id);
      }
      activeWinTimeouts.clear();
      for (const id of activeWinIntervals) {
        origWinClearInterval(id);
      }
      activeWinIntervals.clear();
      for (const id of activeTimeouts) {
        origClearTimeout(id);
      }
      activeTimeouts.clear();
      for (const id of activeIntervals) {
        origClearInterval(id);
      }
      activeIntervals.clear();
      for (const key of added) {
        try {
          delete globalThis[key];
        } catch {}
      }
      for (const [ key, desc ] of saved.entries()) {
        try {
          if (desc) {
            Object.defineProperty(globalThis, key, desc);
          }
        } catch {}
      }
    },
  };
}

test('monaco-editor-hello-world: standalone zig build test validates Zig 0.17 AST and Sema', async () => {
  ensureIsolatedCacheEnv('monaco-editor-hello-world');
  await ensureMonacoBindings({ quiet: true });

  const { stderr } = await execFileAsync('zig', [ 'build', 'test', '--summary', 'all' ], {
    cwd: APP_DIR,
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.match(stderr, /Build Summary: .* succeeded/);
});

test('monaco-editor-hello-world: Vite + rollup-plugin-zigar emits tree-shaken browser bundle and mounts Monaco in DOM', async () => {
  const localNm = ensureViteDeps();
  await execFileAsync(process.execPath, [ join(APP_DIR, 'build.mjs'), '--quiet' ], {
    cwd: APP_DIR,
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
  });
  const distDir = DIST_DIR;

  // 1. Verify production dist artifacts: HTML, stripped ReleaseSmall WASM, and deduplicated ESM workers
  assert.ok(existsSync(join(distDir, 'index.html')), 'dist/index.html must exist');
  const expectedWorkers = [
    'editor.worker.js',
    'ts.worker.js',
  ];
  for (const workerFile of expectedWorkers) {
    const full = join(distDir, workerFile);
    assert.ok(existsSync(full), `Expected Vite worker bundle ${workerFile}`);
    assert.ok(statSync(full).size > 64, `Worker bundle ${workerFile} must be non-empty`);
  }
  for (const unusedWorker of [ 'json.worker.js', 'css.worker.js', 'html.worker.js' ]) {
    assert.equal(
      existsSync(join(distDir, unusedWorker)),
      false,
      `Unused language worker ${unusedWorker} must not be emitted in TypeScript-only bundle`,
    );
  }

  const assetsDir = join(distDir, 'assets');
  const assetFiles = readdirSync(assetsDir);
  assert.equal(
    assetFiles.some((f) => f.startsWith('ts.worker') || f.startsWith('editor.worker')),
    false,
    'Worker entry bundles must be emitted once at dist/*.worker.js without duplicate copies in dist/assets/',
  );

  let totalDistBytes = 0;
  const walkSize = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walkSize(full);
      else totalDistBytes += statSync(full).size;
    }
  };
  walkSize(distDir);
  assert.ok(
    totalDistBytes < 13 * 1024 * 1024,
    `Expected deduplicated dist/ bundle (< 13 MiB), got ${totalDistBytes} bytes`,
  );

  const wasmFile = assetFiles.find((f) => f.startsWith('app-') && f.endsWith('.wasm'));
  assert.ok(wasmFile, 'Expected emitted app-<hash>.wasm asset from rollup-plugin-zigar');
  const wasmBytes = readFileSync(join(assetsDir, wasmFile));
  assert.deepEqual(
    Array.from(wasmBytes.subarray(0, 4)),
    [ 0x00, 0x61, 0x73, 0x6d ],
    'Emitted WASM asset must begin with \\0asm header',
  );
  assert.ok(
    wasmBytes.byteLength < 256 * 1024,
    `Expected compact ReleaseSmall WASM (< 256 KiB), got ${wasmBytes.byteLength} bytes`,
  );

  // 2. Verify tree-shaking: unused basic-languages grammars must not be emitted into dist/assets,
  //    and no unbundled Node built-in specifiers remain in browser JS chunks.
  const unusedLanguages = [ 'abap', 'apex', 'azcli', 'bicep', 'cameligo', 'cobol', 'qsharp', 'sparql', 'wgsl' ];
  for (const lang of unusedLanguages) {
    assert.equal(
      assetFiles.some((f) => f.startsWith(`${lang}-`) && f.endsWith('.js')),
      false,
      `Unused Monaco grammar chunk "${lang}" should be tree-shaken out of dist/assets`,
    );
  }
  for (const jsAsset of assetFiles.filter((f) => f.endsWith('.js'))) {
    const src = readFileSync(join(assetsDir, jsAsset), 'utf8');
    assert.doesNotMatch(src, /from\s*["']node:/, `Browser chunk ${jsAsset} must not import node:* builtins`);
  }

  // 3. Serve dist/ over a real loopback HTTP server and mount the production bundle in JSDOM
  const requestedRoutes = [];
  const server = http.createServer((req, res) => {
    const cleanPath = (req.url || '/').split('?')[0];
    requestedRoutes.push(cleanPath);
    const relPath = cleanPath === '/' ? 'index.html' : cleanPath.replace(/^\/+/, '');
    const targetFile = resolve(distDir, relPath);
    if (!targetFile.startsWith(resolve(distDir)) || !existsSync(targetFile) || statSync(targetFile).isDirectory()) {
      res.writeHead(404, { Connection: 'close' });
      res.end('Not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': MIME_TYPES[extname(targetFile)] || 'application/octet-stream',
      Connection: 'close',
    });
    res.end(readFileSync(targetFile));
  });
  server.keepAliveTimeout = 0;

  await new Promise((resolveListen) => server.listen(0, '127.0.0.1', resolveListen));
  const { port } = server.address();
  const baseUrl = `http://127.0.0.1:${port}/`;
  const distFileUrlPrefix = `${pathToFileURL(resolve(distDir)).href}/`;
  const originalFetch = globalThis.fetch;

  const closeHeaders = { connection: 'close' };
  const { JSDOM } = await import(pathToFileURL(join(localNm, 'jsdom/lib/api.js')).href);
  const indexRes = await originalFetch(baseUrl, { headers: closeHeaders });
  assert.equal(indexRes.status, 200);
  const indexHtml = await indexRes.text();
  const scriptMatch = indexHtml.match(/<script[^>]+type="module"[^>]+src="([^"]+)"/);
  assert.ok(scriptMatch, 'dist/index.html must include module entry <script>');
  const entryRel = scriptMatch[1].replace(/^\.\//, '');

  const dom = new JSDOM(indexHtml, { url: baseUrl, pretendToBeVisual: true });
  const envHarness = installJsdomGlobals(dom.window);

  let serverOpen = true;
  const inFlightFetches = new Set();
  globalThis.fetch = async (input, init) => {
    const urlStr = String(input);
    const mergedInit = {
      ...init,
      headers: {
        ...(init?.headers || {}),
        connection: 'close',
      },
    };
    const run = async () => {
      try {
        if (urlStr.startsWith(distFileUrlPrefix)) {
          if (!serverOpen) return new Response('', { status: 204 });
          return await originalFetch(baseUrl + urlStr.slice(distFileUrlPrefix.length), mergedInit);
        }
        if (urlStr.startsWith(baseUrl)) {
          if (!serverOpen) return new Response('', { status: 204 });
          return await originalFetch(input, mergedInit);
        }
        return await originalFetch(input, init);
      } catch (err) {
        if (!serverOpen) return new Response('', { status: 204 });
        throw err;
      }
    };
    const p = run();
    inFlightFetches.add(p);
    try {
      return await p;
    } finally {
      inFlightFetches.delete(p);
    }
  };

  try {
    // Verify all 5 worker endpoints serve HTTP 200 valid JS from dist/
    for (const workerFile of expectedWorkers) {
      const workerRes = await originalFetch(`${baseUrl}${workerFile}`, { headers: closeHeaders });
      assert.equal(workerRes.status, 200, `GET /${workerFile} must return 200`);
      const workerBody = await workerRes.text();
      assert.ok(workerBody.length > 64, `${workerFile} response must be non-empty`);
    }

    // Execute the Vite production entry bundle (instantiates app-*.wasm via HTTP fetch and mounts #container)
    await import(pathToFileURL(join(distDir, entryRel)).href);

    const zigApp = globalThis.__zigarMonacoApp;
    assert.ok(zigApp, 'main.js must expose globalThis.__zigarMonacoApp');
    assert.equal(zigApp.isMounted(), true, 'Editor must be mounted after main.js executes');
    assert.ok(
      requestedRoutes.some((r) => r.startsWith('/assets/app-') && r.endsWith('.wasm')),
      'rollup-plugin-zigar must fetch /assets/app-*.wasm over HTTP',
    );
    assert.equal(
      dom.window.document.querySelectorAll('#container .monaco-editor').length,
      1,
      'Monaco must render .monaco-editor DOM subtree inside #container',
    );

    // Verify initial TypeScript code buffer and live setValue / getValue roundtrip
    const defaultCode = unwrapString(zigApp.default_code);
    assert.match(defaultCode, /Hello world!/);
    assert.equal(unwrapString(zigApp.getValue()), defaultCode);

    const updatedTs = 'export const answer: number = 42;\n';
    zigApp.setValue(updatedTs);
    assert.equal(unwrapString(zigApp.getValue()), updatedTs);

    // Verify MonacoEnvironment.getWorkerUrl Zig closure routing and Worker construction
    const beforeReqs = Number(zigApp.workerUrlRequests());
    assert.equal(unwrapString(zigApp.resolveWorkerUrl('workerMain.js', 'typescript')), './ts.worker.js');
    assert.equal(unwrapString(zigApp.resolveWorkerUrl('workerMain.js', 'javascript')), './ts.worker.js');
    assert.equal(unwrapString(zigApp.resolveWorkerUrl('workerMain.js', 'editorWorkerService')), './editor.worker.js');
    assert.equal(unwrapString(zigApp.resolveWorkerUrl('workerMain.js', 'plaintext')), './editor.worker.js');
    assert.equal(Number(zigApp.workerUrlRequests()), beforeReqs + 4);
    const resolvedTsWorkerUrl = globalThis.MonacoEnvironment.getWorkerUrl('workerMain.js', 'typescript');
    assert.equal(resolvedTsWorkerUrl, './ts.worker.js');
    const mockWorker = new globalThis.Worker(resolvedTsWorkerUrl, { type: 'module', name: 'ts' });
    mockWorker.terminate();
    assert.ok(
      envHarness.spawnedWorkers.some((w) => w.url === './ts.worker.js'),
      'MockBrowserWorker must record worker instantiated from MonacoEnvironment.getWorkerUrl',
    );

    // Verify clean remounting and missing-container error reporting
    const remountCode = 'type Mode = "remounted";\n';
    zigApp.mountWithOptions('container', remountCode, 'typescript', 'vs-dark');
    assert.equal(zigApp.isMounted(), true);
    assert.equal(unwrapString(zigApp.getValue()), remountCode);
    assert.throws(() => zigApp.mount('missing-container-id'), /Container not found|ContainerNotFound/i);

    // Verify bfcache pagehide (persisted === true) keeps editor mounted, while non-persisted pagehide unmounts
    const bfcacheHide = Object.assign(new dom.window.Event('pagehide'), { persisted: true });
    dom.window.dispatchEvent(bfcacheHide);
    assert.equal(zigApp.isMounted(), true, 'bfcache pagehide (persisted: true) must preserve mounted editor');

    const finalHide = Object.assign(new dom.window.Event('pagehide'), { persisted: false });
    dom.window.dispatchEvent(finalHide);
    assert.equal(zigApp.isMounted(), false, 'non-persisted pagehide must unmount editor');
    assert.equal(globalThis.MonacoEnvironment, undefined);
    assert.equal(zigApp.activeHandles(), 0, 'WASM app must release all JsValue handles on unmount');
    assert.equal(zigApp.activeCallbacks(), 0, 'WASM app must release all closures on unmount');
  } finally {
    serverOpen = false;
    await Promise.allSettled([ ...inFlightFetches ]);
    try {
      globalThis.__zigarMonacoApp?.unmount();
    } catch {}
    delete globalThis.__zigarMonacoApp;
    globalThis.fetch = originalFetch;
    envHarness.restore();
    dom.window.close();
    server.closeAllConnections?.();
    await new Promise((resolveClose) => server.close(resolveClose));
  }
});

test('monaco-editor-hello-world: native node-zigar mounts Monaco and releases all handles', async () => {
  const localNm = ensureViteDeps();
  const { JSDOM } = await import(pathToFileURL(join(localNm, 'jsdom/lib/api.js')).href);
  const dom = new JSDOM('<!doctype html><html><body><div id="container"></div></body></html>', {
    url: 'http://127.0.0.1/',
    pretendToBeVisual: true,
  });
  const envHarness = installJsdomGlobals(dom.window);

  try {
    const nativeApp = await loadNativeZigModule(new URL('../src/app.zig', import.meta.url).href);
    assert.equal(nativeApp.isMounted(), false);
    nativeApp.mountWithOptions('container', 'const nativeMode = true;\n', 'typescript', 'vs-dark');
    assert.equal(nativeApp.isMounted(), true);
    assert.equal(unwrapString(nativeApp.getValue()), 'const nativeMode = true;\n');
    assert.equal(unwrapString(nativeApp.resolveWorkerUrl('workerMain.js', 'typescript')), './ts.worker.js');
    nativeApp.unmount();
    assert.equal(nativeApp.isMounted(), false);
    assert.equal(globalThis.MonacoEnvironment, undefined);
    assert.equal(nativeApp.activeHandles(), 0, 'Native node-zigar app must release all JsValue handles on unmount');
    assert.equal(nativeApp.activeCallbacks(), 0, 'Native node-zigar app must release all closures on unmount');
  } finally {
    envHarness.restore();
    dom.window.close();
  }
});

test('monaco-editor-hello-world: Vite dev server serves index.html and worker ESM routes', async () => {
  ensureViteDeps();
  await execFileAsync(process.execPath, [ join(__dirname, 'dev-server-smoke.mjs') ], {
    cwd: APP_DIR,
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
  });
});
