#!/usr/bin/env node
/**
 * Compiles `src/lib.zig` to WebAssembly (`wasm32-wasi`) via `zigar-compiler`
 * (`compile` + `createEnvironment` + `instantiateComponentHost`) and executes
 * the exact same Zig TypeScript 7.1 compiler pipeline inside Node.js 26 across
 * separate WebAssembly linear memories.
 */

import { mkdirSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import '../../../zigar-runtime/dist/mixins.js';
import { createEnvironment } from '../../../zigar-runtime/dist/index.js';
import { compile, instantiateComponentHost } from '../../../zigar-compiler/dist/index.js';
import { extractLimits } from '../../../zigar-compiler/src/wasm-decoding.js';
import { buildComponent } from '../../../ts-zigar/component/build-component.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, '../../..');

export function resolveComponentWasmPath() {
  if (process.env.TS_ZIGAR_COMPONENT_PATH) {
    return resolve(process.env.TS_ZIGAR_COMPONENT_PATH);
  }
  if (process.env.TS_ZIGAR_COMPONENT_WASM) {
    return resolve(process.env.TS_ZIGAR_COMPONENT_WASM);
  }
  return join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm');
}

export function ensureIsolatedCacheEnv() {
  const cacheRoot = join(REPO_ROOT, '.cache');
  const zigLocal = process.env.ZIG_LOCAL_CACHE_DIR || join(cacheRoot, 'zig-local');
  const zigGlobal = process.env.ZIG_GLOBAL_CACHE_DIR || join(cacheRoot, 'zig-global');
  const xdgCache = process.env.XDG_CACHE_HOME || join(cacheRoot, 'xdg');
  const tmpDir = (!process.env.TMPDIR || process.env.TMPDIR.startsWith('/tmp') || process.env.TMPDIR.startsWith('/var/tmp'))
    ? join(cacheRoot, 'tmp')
    : process.env.TMPDIR;
  const buildDir = join(cacheRoot, 'examples/ts-compiler-component-hello-world/wasm-build');

  for (const dir of [ zigLocal, zigGlobal, xdgCache, tmpDir, buildDir ]) {
    mkdirSync(dir, { recursive: true });
  }
  process.env.ZIG_LOCAL_CACHE_DIR = zigLocal;
  process.env.ZIG_GLOBAL_CACHE_DIR = zigGlobal;
  process.env.XDG_CACHE_HOME = xdgCache;
  process.env.TMPDIR = tmpDir;

  return { cacheRoot, buildDir };
}

export async function runWasmShowcase() {
  const { buildDir } = ensureIsolatedCacheEnv();

  // 1. Build `typescript-compiler.component.wasm` automatically if missing/stale
  const componentWasmPath = buildComponent({
    outputPath: resolveComponentWasmPath(),
  });

  // 2. Instantiate the TypeScript 7.1 Go WASM Component in Node.js 26
  const tsGuest = instantiateComponentHost(componentWasmPath);

  try {
    // 3. Compile `src/lib.zig` to `wasm32-wasi` via `zigar-compiler`
    //    (`src/build.extra.zig` automatically runs `wit-zigar` on `typescript.wit`)
    const srcPath = join(__dirname, 'src/lib.zig');
    const { outputPath } = await compile(srcPath, null, {
      platform: 'wasi',
      arch: 'wasm32',
      isWASM: true,
      optimize: 'ReleaseSafe',
      buildDir,
    });

    // 4. Instantiate compiled Zig WASM inside `zigar-runtime`'s `createEnvironment()`
    const wasmBytes = await readFile(outputPath);
    const limits = extractLimits(
      new DataView(wasmBytes.buffer, wasmBytes.byteOffset, wasmBytes.byteLength),
    );
    const env = createEnvironment();
    env.loadModule(wasmBytes, {
      memoryInitial: limits.memoryInitial !== undefined ? Number(limits.memoryInitial) : undefined,
      memoryMax: limits.memoryMax !== undefined ? Number(limits.memoryMax) : undefined,
      tableInitial: limits.tableInitial !== undefined ? Number(limits.tableInitial) : undefined,
    });
    await env.initPromise;
    env.acquireStructures();
    const zigLib = env.getRootModule();

    try {
      // 5. Execute `runWasmDemo` across separate WASM linear memories
      const raw = zigLib.runWasmDemo(tsGuest.instanceId);
      const summary = {
        compilerVersion: raw.compiler_version.string,
        syntacticDiagnosticCount: Number(raw.syntactic_diagnostic_count),
        semanticDiagnosticCount: Number(raw.semantic_diagnostic_count),
        inferredExpressionType: raw.inferred_expression_type.string,
        exportedSymbols: Array.from(raw.exported_symbols, (sym) => ({
          name: sym.name.string,
          typeText: sym.type_text.string,
        })),
        emittedDeclarations: Array.from(raw.emitted_declarations, (decl) => ({
          fileName: decl.file_name.string,
          contents: decl.contents.string,
        })),
        transpiledJs: raw.transpiled_js.string,
        brokenDiagnosticCount: Number(raw.broken_diagnostic_count),
        brokenDiagnostic: {
          code: Number(raw.broken_diagnostic.code),
          fileName: raw.broken_diagnostic.file_name.string,
          line: Number(raw.broken_diagnostic.line),
          column: Number(raw.broken_diagnostic.column),
          message: raw.broken_diagnostic.message.string,
        },
        liveResourcesAfterDrop: Number(raw.live_resources_after_drop),
        hostLiveResourcesBeforeDispose: tsGuest.liveResourceCount(),
      };
      return summary;
    } finally {
      env.abandonModule();
    }
  } finally {
    tsGuest.dispose();
  }
}

function formatShowcaseOutput(summary) {
  const lines = [
    '=== TypeScript 7.1 Go WASM Component Showcase (WASM Zig in Node.js 26) ===',
    `Compiler version: ${summary.compilerVersion}`,
    `Valid program diagnostics: ${summary.syntacticDiagnosticCount} syntactic, ${summary.semanticDiagnosticCount} semantic`,
    '',
    '--- Checker Inspection (/app/index.ts) ---',
    `summarizeBatch type: ${summary.inferredExpressionType}`,
    `Exported symbols (${summary.exportedSymbols.length}):`,
    ...summary.exportedSymbols.map((s) => `  - ${s.name}: ${s.typeText}`),
    '',
    `--- Emitted Declarations (${summary.emittedDeclarations.length} files) ---`,
    ...summary.emittedDeclarations.map((d) => `[${d.fileName}]\n${d.contents}`),
    '--- Transpiled JavaScript (/app/index.ts) ---',
    summary.transpiledJs,
    `--- Intentional Type Error Check (/app/broken.ts, ${summary.brokenDiagnosticCount} diagnostic) ---`,
    `TS${summary.brokenDiagnostic.code} at ${summary.brokenDiagnostic.fileName}:${summary.brokenDiagnostic.line}:${summary.brokenDiagnostic.column} - ${summary.brokenDiagnostic.message}`,
    '',
    `Live WIT resources after cleanup: ${summary.liveResourcesAfterDrop}`,
  ];
  return lines.join('\n');
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
  const summary = await runWasmShowcase();
  console.log(formatShowcaseOutput(summary));
}
