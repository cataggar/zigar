import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { copyFile, cp, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { transpile } from '../dist/transpiler.js';
import { runTs } from '../src/index.js';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m3-functions');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-functions-wasm-${process.pid}`);
const BUILD_DIR = join(TEST_ROOT, 'zig-build');
const CACHE_DIR = join(TEST_ROOT, 'zig-cache');

function rewriteRuntimeImports(code) {
  return code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${RUNTIME_DIST_URL}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${RUNTIME_DIST_URL}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${RUNTIME_DIST_URL}$2"`);
}

async function generateBindings(esmPath, cjsPath, outDir) {
  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm');
  const cliArgs = [
    '-t', esmPath,
    '-t', cjsPath,
    '-m', 'm3-functions-esm',
    '-m', 'm3-functions-cjs',
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

describe('ts-zigar M3.3a Live Runtime Roundtrip: Overloads, Variadics, Callbacks, this & Type Predicates (WASM)', function () {
  this.timeout(240_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(
      join(SAMPLE_DIR, 'm3-functions-esm.d.mts'),
      join(SAMPLE_DIR, 'm3-functions-cjs.d.cts'),
      generatedMasterDir,
    );
  });

  after(function () {
    if (existsSync(TEST_ROOT)) {
      rmSync(TEST_ROOT, { recursive: true, force: true });
    }
  });

  for (const target of [
    { label: 'wasm32', memory64: false },
    { label: 'wasm64', memory64: true },
  ]) {
    describe(`Target: ${target.label}`, function () {
      let mod;

      before(async function () {
        const targetDir = join(TEST_ROOT, target.label);
        await mkdir(targetDir, { recursive: true });
        await copyFile(join(SAMPLE_DIR, 'm3-functions-esm.mjs'), join(targetDir, 'm3-functions-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-functions-cjs.cjs'), join(targetDir, 'm3-functions-cjs.cjs'));
        await copyFile(join(SAMPLE_DIR, 'consumer.zig'), join(targetDir, 'consumer.zig'));
        await cp(generatedMasterDir, join(targetDir, 'generated'), { recursive: true });

        const consumerZigPath = join(targetDir, 'consumer.zig');
        const consumerFileUrl = pathToFileURL(consumerZigPath).href;
        const result = await transpile(consumerZigPath, {
          nodeCompat: false,
          embedWASM: true,
          topLevelAwait: true,
          stripWASM: true,
          optimize: 'ReleaseSmall',
          memory64: target.memory64,
          buildDir: BUILD_DIR,
          cacheDir: CACHE_DIR,
          jsModuleResolver: (spec) => {
            if (spec === 'm3-functions-esm') return new URL('./m3-functions-esm.mjs', consumerFileUrl).href;
            if (spec === 'm3-functions-cjs') return new URL('./m3-functions-cjs.cjs', consumerFileUrl).href;
            return (spec.startsWith('./') || spec.startsWith('../'))
              ? new URL(spec, consumerFileUrl).href
              : spec;
          },
        });

        expect(result.jsModules).to.have.members([
          'm3-functions-esm',
          'm3-functions-cjs',
        ]);
        const runnerMjs = join(targetDir, `runner-${target.label}.mjs`);
        await writeFile(runnerMjs, rewriteRuntimeImports(result.code), 'utf-8');
        mod = await import(pathToFileURL(runnerMjs).href);
      });

      afterEach(function () {
        if (mod) {
          expect(Number(mod.activeHandles())).to.equal(0);
          expect(Number(mod.activeCallbacks())).to.equal(0);
          expect(Number(mod.liveZigAllocs())).to.equal(0);
          expect(Boolean(mod.hasPendingCapturedError())).to.be.false;
        }
      });

      it('deduplicates subsumed overloads and dispatches Buf.from, readFile, and CJS callableToolkit', function () {
        expect(mod.exerciseSmartOverloadsAndCjs().string).to.equal(
          'reads=bin6|zig-50|ENOENT:missing.txt|zig-50',
        );
      });

      it('dispatches MiniEmitter ctor + literal .on overloads with reusable js.Closure callbacks', function () {
        expect(mod.exerciseEmitterLiteralOverloadsAndReusableClosures().string).to.equal(
          '[open]<a><b>[close]',
        );
      });

      it('packs variadic rest parameters via tuple, single arg, empty tuple, and *Slice companions', function () {
        expect(mod.exerciseVariadicRestParameters().string).to.equal(
          'log[3]=string:host,number:8080,boolean:true|sums=70,7,0,60',
        );
      });

      it('bridges bare fn, closure, deferred onceClosure, !T callback errors, and HOF Callables', function () {
        expect(mod.exerciseCallbacksAndHigherOrderCallables().string).to.equal(
          'tick:ready|HTTP#204|121',
        );
      });

      it('binds explicit this: T vs this: void on standalone functions and stateless/stateful callbacks', function () {
        expect(mod.exerciseExplicitThisParameters().string).to.equal(
          'inc=15|void=42|cls=45|st=37|box=59',
        );
      });

      it('narrows values and propagates assertion errors for is / asserts / this type predicates', function () {
        expect(mod.exerciseTypePredicatesAndNarrowing().string).to.equal(
          'eval=42|sent=[tok7]>ping',
        );
      });
    });
  }
});
