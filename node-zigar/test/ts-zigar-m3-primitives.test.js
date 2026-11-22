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
const SAMPLE_DIR = resolve(REPO_ROOT, 'zigar-compiler/test/zig-samples/js-value/ts-m3-primitives');
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-node-${process.pid}`);
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

async function generateBindings(fixturePath, outDir) {
  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm');
  const cliArgs = [
    '-t', fixturePath,
    '-m', './m3-esm.mjs',
    '-m', './m3-cjs.cjs',
    '-m', 'globals',
    '-s', './m3-esm.mjs=m3_esm',
    '-s', './m3-cjs.cjs=m3_cjs',
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

function installGlobalFixtures() {
  globalThis.__m3GlobalLabel = 'seed-global';
  globalThis.__m3GlobalUndef = 'seed-undef';
  globalThis.__m3GlobalNull = 'seed-null';
  globalThis.__m3GlobalCompute = function __m3GlobalCompute(name, bonus = 10) {
    return [ `${globalThis.__m3GlobalLabel}:${name}:${arguments.length}`, bonus ];
  };
  globalThis.__m3GlobalBox = {
    count: 0,
    step(by = 1) {
      globalThis.__m3GlobalBox.count += by;
      return globalThis.__m3GlobalBox.count;
    },
  };
}

function cleanupGlobalFixtures() {
  delete globalThis.__m3GlobalLabel;
  delete globalThis.__m3GlobalUndef;
  delete globalThis.__m3GlobalNull;
  delete globalThis.__m3GlobalCompute;
  delete globalThis.__m3GlobalBox;
}

describe('ts-zigar M3.1a Live Runtime Roundtrip: Primitives, Optionals, BigInt, Symbol, Binary Views & Tuples (node-zigar Native)', function () {
  this.timeout(240_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(join(SAMPLE_DIR, 'fixture.d.ts'), generatedMasterDir);
  });

  after(function () {
    cleanupGlobalFixtures();
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
        await copyFile(join(SAMPLE_DIR, 'm3-esm.mjs'), join(targetDir, 'm3-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-cjs.cjs'), join(targetDir, 'm3-cjs.cjs'));
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

      beforeEach(function () {
        installGlobalFixtures();
      });

      afterEach(function () {
        if (mod) {
          expect(Number(mod.activeHandles())).to.equal(0);
          expect(Number(mod.liveZigAllocs())).to.equal(0);
          expect(Boolean(mod.hasPendingCapturedError())).to.equal(false);
        }
      });

      it('roundtrips void, never (throwing), bool, f64, i64, BigInt (>64-bit & >128-bit), String, Symbol, and intrinsics', function () {
        const out = mod.exercisePrimitives().string;
        expect(out).to.equal(
          'void=20|never=never-error:boom|str=6:4:hi🚀|ultra=1000000000000000000000000000000000000000000',
        );
      });

      it('distinguishes trailing optional argc defaults, T|null vs T|undefined, inbound nullish, and Nullable(f64)', function () {
        const out = mod.exerciseOptionalsAndNullable().string;
        expect(out).to.equal(
          '1:hi!!|2:hi??|3:hi!!!|null|undefined|null|is-undefined,is-null,is-value:42.5',
        );
      });

      it('roundtrips ReadonlyArray/T[], fixed/optional/labeled/trailing/leading/middle variadic tuples, and cleans up malformed tuple errors', function () {
        const out = mod.exerciseArraysAndTuples().string;
        expect(out).to.equal('tuples-and-arrays-ok');
      });

      it('mutates Buffer, TypedArrays, ArrayBuffer, SharedArrayBuffer, and DataView in-place across JS and Zig', function () {
        const out = mod.exerciseBinaryViews().string;
        expect(out).to.equal('buf0=15|u8=ab|i32=-42|f64=2.75|i64=4000|sab=60|dv=beef');
      });

      it('interoperates across GlobalTarget get/set, nested namespaces, export default, export = CJS, and declare global', function () {
        const out = mod.exerciseGlobalsNamespacesExports().string;
        expect(out).to.equal('[2]boot#201|ns:4:hits=102|cjs:v2');
        expect(globalThis.__m3GlobalLabel).to.equal('zig-mutated-global');
        expect(globalThis.__m3GlobalBox.count).to.equal(58);
      });

      it('preserves exact JS null vs undefined vs omitted properties across interfaces, anon_structs, tuples, slices, rest args, and globals', function () {
        const out = mod.exerciseNullishFidelity().string;
        expect(out).to.equal(
          'u:[number:5,undefined,number:9]|n:[number:5,null,number:9]|nested:undefined|null|cjs:undefined|null',
        );
        expect('__m3GlobalUndef' in globalThis).to.equal(true);
        expect(globalThis.__m3GlobalUndef).to.equal(undefined);
        expect('__m3GlobalNull' in globalThis).to.equal(true);
        expect(globalThis.__m3GlobalNull).to.equal(null);
      });
    });
  }
});
