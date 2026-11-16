import assert from 'node:assert/strict';
import { existsSync, mkdirSync, rmSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { getComponentHostRegistry, runWit } from '../../../../zigar-compiler/dist/index.js';
import { ensureIsolatedCacheEnv, runWasmShowcase } from '../run-wasm.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const EXAMPLE_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(EXAMPLE_DIR, '../../..');

test('zigar wit generates Zig 0.17 bindings for zigar:typescript@7.1.0', async () => {
  const { cacheRoot } = ensureIsolatedCacheEnv();
  const witBuildDir = join(cacheRoot, 'examples/ts-compiler-component-hello-world/wit-build');
  const outDir = join(cacheRoot, 'examples/ts-compiler-component-hello-world/wit-test');
  const outFile = join(outDir, 'generated_ts.zig');
  mkdirSync(outDir, { recursive: true });

  try {
    const witPath = join(REPO_ROOT, 'ts-zigar/wit/typescript.wit');
    const res = await runWit(
      [ witPath, '--world', 'typescript-compiler', '-o', outFile ],
      { buildDir: witBuildDir, silent: true },
    );
    assert.equal(res.code, 0);
    assert.equal(existsSync(outFile), true);

    const zigSource = await readFile(outFile, 'utf8');
    assert.match(zigSource, /pub const compiler = struct/);
    assert.match(zigSource, /pub fn bindHost/);
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
});

test('src/lib.zig compiled to WASM via zigar-compiler drives TypeScript 7.1 Go WASM Component in Node.js 26', async () => {
  const summary = await runWasmShowcase();

  // (a) Compiler version
  assert.match(summary.compilerVersion, /^7\.1\./);

  // (b)-(c) Valid multi-file program has 0 syntactic and 0 semantic diagnostics
  assert.equal(summary.syntacticDiagnosticCount, 0);
  assert.equal(summary.semanticDiagnosticCount, 0);

  // (d) Checker inspection (`typeToString` + `resolveModuleExports`)
  assert.match(summary.inferredExpressionType, /ReadonlySample<SensorBatch>/);
  assert.match(summary.inferredExpressionType, /Promise<NumericOutcome<number>>/);
  const exportNames = summary.exportedSymbols.map((s) => s.name);
  assert.ok(exportNames.includes('SensorBatch'));
  assert.ok(exportNames.includes('summarizeBatch'));
  assert.ok(exportNames.includes('formatOutcome'));

  // (e) Emitted `.d.ts` declarations + transpiled JavaScript
  assert.equal(summary.emittedDeclarations.length, 2);
  const mathDts = summary.emittedDeclarations.find((d) => d.fileName === '/app/math.d.ts');
  const indexDts = summary.emittedDeclarations.find((d) => d.fileName === '/app/index.d.ts');
  assert.ok(mathDts);
  assert.ok(indexDts);
  assert.match(mathDts.contents, /NumericOutcome/);
  assert.match(mathDts.contents, /declare function clamp/);
  assert.match(indexDts.contents, /declare function summarizeBatch/);
  assert.match(indexDts.contents, /Promise<NumericOutcome<number>>/);

  assert.match(summary.transpiledJs, /summarizeBatch/);
  assert.match(summary.transpiledJs, /formatOutcome/);
  assert.doesNotMatch(summary.transpiledJs, /interface SensorBatch/);

  // (f) Intentional semantic type error (`TS2322` in `/app/broken.ts`)
  assert.equal(summary.brokenDiagnosticCount, 1);
  assert.equal(summary.brokenDiagnostic.code, 2322);
  assert.equal(summary.brokenDiagnostic.fileName, '/app/broken.ts');
  assert.equal(summary.brokenDiagnostic.line, 3);
  assert.equal(summary.brokenDiagnostic.column, 14);
  assert.equal(
    summary.brokenDiagnostic.message,
    "Type 'string' is not assignable to type 'number'.",
  );

  // (g) All WIT resources dropped and component host unregistered cleanly
  assert.equal(summary.liveResourcesAfterDrop, 0);
  assert.equal(summary.hostLiveResourcesBeforeDispose, 0);
  assert.equal(getComponentHostRegistry().hosts.size, 0);
});
