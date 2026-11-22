import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { registerHooks } from 'node:module';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
  GENERATED_DIR,
  MONACO_PKG_DIR,
  ensureIsolatedCacheEnv,
  ensureMonacoBindings,
  generateSingleFileMonacoBindings,
  loadNativeZigModule,
} from '../generate.mjs';
import { buildWasmBundle } from '../build-wasm.mjs';

const DIST_BUNDLE = path.join(MONACO_PKG_DIR, 'dist', 'showcase.mjs');

// Install a Node.js 26 synchronous module hook that maps `'monaco-editor/editor/editor.api.js'`
// to Microsoft's real `createMonacoBaseAPI()` (`Uri`, `Range`, `Selection`, `Position`, `KeyMod`,
// `KeyCode`, `MarkerSeverity`, etc. — which has zero CSS/DOM top-level imports) combined with
// deterministic `editor` and `languages` host implementations for headless Node testing.
const editorBaseApiUrl = pathToFileURL(
  path.join(
    MONACO_PKG_DIR,
    'node_modules',
    'monaco-editor',
    'esm',
    'vs',
    'editor',
    'common',
    'services',
    'editorBaseApi.js',
  ),
).href;

const VIRTUAL_EDITOR_API_URL = 'virtual-monaco://editor.api.mjs';

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (
      specifier === 'monaco-editor/editor/editor.api.js' ||
      specifier === 'monaco-editor'
    ) {
      return {
        url: VIRTUAL_EDITOR_API_URL,
        shortCircuit: true,
      };
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url === VIRTUAL_EDITOR_API_URL) {
      return {
        format: 'module',
        shortCircuit: true,
        source: `
import { createMonacoBaseAPI } from ${JSON.stringify(editorBaseApiUrl)};

const base = createMonacoBaseAPI();
export const {
  CancellationTokenSource,
  Emitter,
  KeyCode,
  KeyMod,
  MarkerSeverity,
  MarkerTag,
  Position,
  Range,
  Selection,
  SelectionDirection,
  Token,
  Uri,
} = base;

const registeredLanguages = [
  { id: 'plaintext', extensions: ['.txt'], aliases: ['Plain Text'] },
  { id: 'typescript', extensions: ['.ts', '.tsx'], aliases: ['TypeScript', 'ts'] },
];

export const languages = {
  register(lang) {
    registeredLanguages.push({ ...lang });
  },
  getLanguages() {
    return registeredLanguages.slice();
  },
};

export const editor = {
  lastCreatedOptions: null,
  createdCount: 0,
  disposedCount: 0,
  lastWorkerUrl: null,
  create(domElement, options = {}) {
    if (!domElement || typeof domElement !== 'object') {
      throw new TypeError('Expected HTMLElement container');
    }
    editor.createdCount += 1;
    editor.lastCreatedOptions = { ...options, containerId: domElement.id };
    if (globalThis.MonacoEnvironment?.getWorkerUrl) {
      editor.lastWorkerUrl = globalThis.MonacoEnvironment.getWorkerUrl(
        'workerMain.js',
        options.language ?? 'editorWorkerService',
      );
    }
    let currentValue = options.value ?? '';
    let disposed = false;
    const noopDisposable = () => ({ dispose() {} });
    const coreEditor = {
      inComposition: false,
      getValue() {
        return currentValue;
      },
      setValue(next) {
        currentValue = String(next);
      },
      dispose() {
        if (!disposed) {
          disposed = true;
          editor.disposedCount += 1;
        }
      },
    };
    return new Proxy(coreEditor, {
      has() {
        return true;
      },
      get(target, prop, receiver) {
        if (prop in target) {
          return Reflect.get(target, prop, receiver);
        }
        if (typeof prop === 'string') {
          return noopDisposable;
        }
        return undefined;
      },
    });
  },
};
`,
      };
    }
    return nextLoad(url, context);
  },
});

function installBrowserGlobalsMock() {
  class MockHTMLElement {
    constructor(id, tagName = 'DIV', className = '') {
      this.id = id;
      this.tagName = tagName;
      this.className = className;
    }
  }

  const elements = new Map([
    ['container', new MockHTMLElement('container', 'DIV', 'monaco-host')],
  ]);

  const createdWorkers = [];
  class MockWorker {
    constructor(scriptURL, options) {
      this.scriptURL = String(scriptURL);
      this.options = options ?? null;
      this.terminated = false;
      createdWorkers.push(this);
    }
    postMessage() {}
    terminate() {
      this.terminated = true;
    }
  }

  class MockDocument {
    constructor() {
      this.title = 'Monaco Zig Test';
    }
    getElementById(id) {
      return elements.get(String(id)) ?? null;
    }
    createElement(tag) {
      return new MockHTMLElement('', String(tag).toUpperCase(), '');
    }
  }

  class MockWindow {
    static [Symbol.hasInstance](instance) {
      return instance === globalThis;
    }
  }

  globalThis.HTMLElement = MockHTMLElement;
  globalThis.Document = MockDocument;
  globalThis.Window = MockWindow;
  globalThis.Worker = MockWorker;
  globalThis.document = new MockDocument();
  globalThis.window = globalThis;

  return {
    createdWorkers,
    cleanup() {
      delete globalThis.MonacoEnvironment;
      delete globalThis.window;
      delete globalThis.document;
      delete globalThis.Worker;
      delete globalThis.Window;
      delete globalThis.Document;
      delete globalThis.HTMLElement;
    },
  };
}

describe('examples/ts-zigar/monaco-editor (#62 — M5.2a)', () => {
  let browserMock;

  before(() => {
    ensureIsolatedCacheEnv();
    browserMock = installBrowserGlobalsMock();
  });

  after(() => {
    browserMock?.cleanup();
  });

  it('generates modular dom + monaco-editor Zig bindings with zero unresolved_type_ref fallbacks', async () => {
    const { stderr } = await ensureMonacoBindings({ force: true, quiet: true, reportFallbacks: true });
    assert.ok(!stderr.includes('unresolved_type_ref'), `Unexpected unresolved_type_ref in stderr:\n${stderr}`);
    assert.ok(existsSync(path.join(GENERATED_DIR, 'root.zig')));
    assert.ok(existsSync(path.join(GENERATED_DIR, 'dom.zig')));
    assert.ok(existsSync(path.join(GENERATED_DIR, 'monaco', 'esm', 'vs.zig')));
    assert.ok(existsSync(path.join(GENERATED_DIR, 'monaco', 'esm', 'vs', 'editor', 'editor', 'api.zig')));
  });

  it('passes standalone `zig build test` AST + Sema checks on generated dom and monaco modules', () => {
    execFileSync('zig', ['build', 'test', '--summary', 'all'], {
      cwd: MONACO_PKG_DIR,
      env: process.env,
      stdio: 'pipe',
    });
  });

  it('also generates and `zig test`-compiles single-file `monaco-editor/monaco.d.ts` + `dom.d.ts` cleanly', async () => {
    const { tmpDir } = ensureIsolatedCacheEnv('monaco-editor');
    const singleOutDir = mkdtempSync(path.join(tmpDir, 'monaco-single-dts-'));
    try {
      const { stderr } = await generateSingleFileMonacoBindings(singleOutDir, { quiet: true });
      assert.ok(!stderr.includes('unresolved_type_ref'), `Unexpected unresolved_type_ref in single-file stderr:\n${stderr}`);
      const rootZig = path.join(singleOutDir, 'root.zig');
      assert.ok(existsSync(rootZig));
      assert.ok(existsSync(path.join(singleOutDir, 'dom.zig')));
      const rootSrc = readFileSync(rootZig, 'utf8');
      assert.match(rootSrc, /pub const dom = @import\("dom\.zig"\);/);
      assert.match(rootSrc, /pub const monaco = @import\(/);

      execFileSync('zig', ['test', rootZig], {
        cwd: MONACO_PKG_DIR,
        env: process.env,
        stdio: 'pipe',
      });
    } finally {
      rmSync(singleOutDir, { recursive: true, force: true });
    }
  });

  it('bundles `src/showcase.zig` for WASM with static tree-shaken `monaco-editor/editor/editor.api.js` import and runs with 0 leaks', async () => {
    const builtPath = await buildWasmBundle({ quiet: true });
    assert.equal(builtPath, DIST_BUNDLE);
    assert.ok(existsSync(DIST_BUNDLE));

    // Verify Rollup emitted a static ES import ONLY for `monaco-editor/editor/editor.api.js`
    // and did NOT pull in `monaco-editor` barrel language registrations!
    const bundleSrc = readFileSync(DIST_BUNDLE, 'utf8');
    assert.match(bundleSrc, /from\s+['"]monaco-editor\/editor\/editor\.api\.js['"]/);
    assert.doesNotMatch(bundleSrc, /languages\/register\.all/);

    const wasmShowcase = await import(pathToFileURL(DIST_BUNDLE).href);
    const monacoApi = await import('monaco-editor/editor/editor.api.js');

    const initialCode = 'export const greeting: string = "Hello from Monaco!";\n';
    const updatedCode = 'export const greeting: string = "Updated from Zig WASM!";\n';
    const summary = wasmShowcase.runEditorWorkflow('container', initialCode, updatedCode);

    assert.equal(summary.container_id.string, 'container');
    assert.equal(summary.uri_scheme.string, 'file');
    assert.equal(summary.uri_path.string, '/workspace/src/main.ts');
    assert.equal(summary.range_contains_cursor, true);
    assert.equal(summary.selection_text.string, '[1,1 -> 1,14]');
    assert.ok(summary.save_chord > 0);
    assert.equal(summary.error_severity, 8);
    assert.equal(summary.registered_zig_language, true);
    assert.equal(Number(summary.initial_length), initialCode.length);
    assert.equal(summary.final_value.string, updatedCode);
    assert.equal(summary.worker_url_typescript.string, './ts.worker.js');
    assert.ok(Number(summary.worker_url_requests) >= 2);
    assert.equal(Number(summary.worker_factory_requests), 1);
    assert.equal(monacoApi.editor.lastWorkerUrl, './ts.worker.js');
    assert.ok(browserMock.createdWorkers.some((w) => w.scriptURL === './ts.worker.js'));

    wasmShowcase.shutdown();
    assert.equal(globalThis.MonacoEnvironment, undefined);
    assert.equal(wasmShowcase.activeHandles(), 0);
    assert.equal(wasmShowcase.activeCallbacks(), 0);
  });

  it('executes `src/showcase.zig` via native `node-zigar` with identical results and 0 leaked handles/callbacks', async () => {
    const nativeShowcase = await loadNativeZigModule(
      pathToFileURL(path.join(MONACO_PKG_DIR, 'src', 'showcase.zig')).href,
    );

    const initialCode = 'const x = 1;\n';
    const updatedCode = 'const x = 42;\n';
    const summary = nativeShowcase.runEditorWorkflow('container', initialCode, updatedCode);

    assert.equal(summary.container_id.string, 'container');
    assert.equal(summary.uri_scheme.string, 'file');
    assert.equal(summary.uri_path.string, '/workspace/src/main.ts');
    assert.equal(summary.range_contains_cursor, true);
    assert.equal(summary.selection_text.string, '[1,1 -> 1,14]');
    assert.equal(summary.error_severity, 8);
    assert.equal(summary.registered_zig_language, true);
    assert.equal(Number(summary.initial_length), initialCode.length);
    assert.equal(summary.final_value.string, updatedCode);
    assert.equal(summary.worker_url_typescript.string, './ts.worker.js');

    nativeShowcase.shutdown();
    assert.equal(globalThis.MonacoEnvironment, undefined);
    assert.equal(nativeShowcase.activeHandles(), 0);
    assert.equal(nativeShowcase.activeCallbacks(), 0);
  });
});
