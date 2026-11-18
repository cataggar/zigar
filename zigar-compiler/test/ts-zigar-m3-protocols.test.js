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
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m3-protocols');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-protocols-wasm-${process.pid}`);
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
    '-m', 'm3-protocols-esm',
    '-m', 'm3-protocols-cjs',
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

describe('ts-zigar M3.3c Live Runtime Roundtrip: Promise<T> Auto-Await, *Promise, Iterable/AsyncIterable & Disposable Protocols (WASM)', function () {
  this.timeout(240_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(
      join(SAMPLE_DIR, 'm3-protocols-esm.d.mts'),
      join(SAMPLE_DIR, 'm3-protocols-cjs.d.cts'),
      generatedMasterDir,
    );
  });

  after(function () {
    if (existsSync(TEST_ROOT)) {
      rmSync(TEST_ROOT, { recursive: true, force: true });
    }
  });

  for (const target of [
    { label: 'wasm32-jspi', memory64: false, useJSPI: true },
    { label: 'wasm64-jspi', memory64: true, useJSPI: true },
    { label: 'wasm32-sync', memory64: false, useJSPI: false },
  ]) {
    describe(`Target: ${target.label}`, function () {
      let mod;

      before(async function () {
        const targetDir = join(TEST_ROOT, target.label);
        await mkdir(targetDir, { recursive: true });
        await copyFile(join(SAMPLE_DIR, 'm3-protocols-esm.mjs'), join(targetDir, 'm3-protocols-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-protocols-cjs.cjs'), join(targetDir, 'm3-protocols-cjs.cjs'));
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
          useJSPI: target.useJSPI,
          buildDir: BUILD_DIR,
          cacheDir: CACHE_DIR,
          jsModuleResolver: (spec) => {
            if (spec === 'm3-protocols-esm') return new URL('./m3-protocols-esm.mjs', consumerFileUrl).href;
            if (spec === 'm3-protocols-cjs') return new URL('./m3-protocols-cjs.cjs', consumerFileUrl).href;
            return (spec.startsWith('./') || spec.startsWith('../'))
              ? new URL(spec, consumerFileUrl).href
              : spec;
          },
        });

        expect(result.jsModules).to.have.members([
          'm3-protocols-esm',
          'm3-protocols-cjs',
        ]);
        const runnerMjs = join(targetDir, `runner-${target.label}.mjs`);
        await writeFile(runnerMjs, rewriteRuntimeImports(result.code), 'utf-8');
        mod = await import(pathToFileURL(runnerMjs).href);
      });

      afterEach(async function () {
        if (mod) {
          expect(Number(await mod.activeHandles())).to.equal(0);
          expect(Number(await mod.activeCallbacks())).to.equal(0);
          expect(Number(await mod.liveZigAllocs())).to.equal(0);
          expect(Boolean(await mod.hasPendingCapturedError())).to.be.false;
        }
      });

      it('roundtrips positional Iterable<T>, Generator<T> early close, [Symbol.iterator], and [Symbol.dispose] / nodejs.dispose', async function () {
        const res = await mod.exerciseSyncProtocols();
        expect(res.string).to.equal('sync-protocols-ok');
      });

      if (target.useJSPI) {
        it('auto-awaits Promise<T>, fans out *Promise with js.promiseAllAlloc, and captures rejections via JSPI', async function () {
          const res = await mod.runAsyncPromises();
          expect(res.string).to.equal('async-promises-ok');
        });

        it('roundtrips AsyncIterable<T>, AsyncGenerator<T> close, [Symbol.asyncIterator], and [Symbol.asyncDispose] / nodejs.asyncDispose', async function () {
          const res = await mod.runAsyncIterablesAndDisposal();
          expect(res.string).to.equal('async-iterables-and-disposal-ok');
        });
      } else {
        it('returns HostUnavailable on auto-awaited Promise<T> without JSPI while preserving *Promise handles leak-free', function () {
          expect(mod.probeSyncAwaitHostUnavailable()).to.equal(true);
        });
      }
    });
  }
});
