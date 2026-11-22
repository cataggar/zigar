import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { copyFile, cp, mkdir, writeFile } from 'node:fs/promises';
import { createRequire, register } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { runTs } from '../../zigar-compiler/src/index.js';
import '../dist/index.cjs';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
const SAMPLE_DIR = resolve(REPO_ROOT, 'zigar-compiler/test/zig-samples/js-value/ts-m3-functions');
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-functions-node-${process.pid}`);
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

describe('ts-zigar M3.3a Live Runtime Roundtrip: Overloads, Variadics, Callbacks, this & Type Predicates (node-zigar Native)', function () {
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

  for (const loaderMode of [ 'esm', 'cjs' ]) {
    describe(`Loader mode: ${loaderMode.toUpperCase()}`, function () {
      let mod;

      before(async function () {
        const targetDir = join(TEST_ROOT, loaderMode);
        await mkdir(targetDir, { recursive: true });
        await copyFile(join(SAMPLE_DIR, 'm3-functions-esm.mjs'), join(targetDir, 'm3-functions-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-functions-cjs.cjs'), join(targetDir, 'm3-functions-cjs.cjs'));

        const esmPkgDir = join(targetDir, 'node_modules', 'm3-functions-esm');
        await mkdir(esmPkgDir, { recursive: true });
        await writeFile(
          join(esmPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-functions-esm', version: '1.0.0', type: 'module', main: './index.mjs' }),
          'utf-8',
        );
        await writeFile(
          join(esmPkgDir, 'index.mjs'),
          `export * from '../../m3-functions-esm.mjs';\n`,
          'utf-8',
        );

        const cjsPkgDir = join(targetDir, 'node_modules', 'm3-functions-cjs');
        await mkdir(cjsPkgDir, { recursive: true });
        await writeFile(
          join(cjsPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-functions-cjs', version: '1.0.0', main: 'index.cjs' }),
          'utf-8',
        );
        await writeFile(
          join(cjsPkgDir, 'index.cjs'),
          `'use strict';\nmodule.exports = require('../../m3-functions-cjs.cjs');\n`,
          'utf-8',
        );

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

      it('auto-boxes Zig values into Any overload parameters and coerces narrow runtime integers to f64', function () {
        expect(mod.exerciseAnyOverloadAutoBoxingAndNarrowIntCoercion().string).to.equal(
          'end:string:Hello, World!|end:string:end:strin|end:boolean:true|bind:127.0.0.1:8080|end:object:null|end:boolean:true|end:object:null|end:object:{"count":77}|end:object:null|nested:string:nested-ok',
        );
      });
    });
  }
});
