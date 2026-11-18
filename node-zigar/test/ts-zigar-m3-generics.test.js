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
const SAMPLE_DIR = resolve(REPO_ROOT, 'zigar-compiler/test/zig-samples/js-value/ts-m3-generics');
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-generics-node-${process.pid}`);
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
    '-m', 'm3-generics-esm',
    '-m', 'm3-generics-cjs',
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

describe('ts-zigar M3.3b Live Runtime Roundtrip: Generics, Constraints, Defaults, Type Operators & Utility Types (node-zigar Native)', function () {
  this.timeout(240_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(
      join(SAMPLE_DIR, 'm3-generics-esm.d.mts'),
      join(SAMPLE_DIR, 'm3-generics-cjs.d.cts'),
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
        await copyFile(join(SAMPLE_DIR, 'm3-generics-esm.mjs'), join(targetDir, 'm3-generics-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-generics-cjs.cjs'), join(targetDir, 'm3-generics-cjs.cjs'));

        const esmPkgDir = join(targetDir, 'node_modules', 'm3-generics-esm');
        await mkdir(esmPkgDir, { recursive: true });
        await writeFile(
          join(esmPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-generics-esm', version: '1.0.0', type: 'module', main: './index.mjs' }),
          'utf-8',
        );
        await writeFile(
          join(esmPkgDir, 'index.mjs'),
          `export * from '../../m3-generics-esm.mjs';\n`,
          'utf-8',
        );

        const cjsPkgDir = join(targetDir, 'node_modules', 'm3-generics-cjs');
        await mkdir(cjsPkgDir, { recursive: true });
        await writeFile(
          join(cjsPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-generics-cjs', version: '1.0.0', main: 'index.cjs' }),
          'utf-8',
        );
        await writeFile(
          join(cjsPkgDir, 'index.cjs'),
          `'use strict';\nmodule.exports = require('../../m3-generics-cjs.cjs');\n`,
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

      it('roundtrips explicit, *Default, *Infer, .from_default, const T [3]f64, and NoInfer<T> generic functions', function () {
        expect(mod.exerciseGenericFunctionsConstAndNoInfer().string).to.equal(
          'def=hello|inf=-9,zig|env=auto:default|arr=120|fb=4,99',
        );
      });

      it('enforces structural/keyof constraints, wire-name T[K] indexed access, generic overloads, and CJS export =', function () {
        expect(mod.exerciseConstraintsKeyofAndGenericOverloads().string).to.equal(
          'U#77|name=Ada|ov=item#77,str:plain|cjs=cjs-ok@314/2',
        );
      });

      it('instantiates GenericStore<K, V>, *Default, *With, and generic method transformGet<R> with Zig closures', function () {
        expect(mod.exerciseGenericHandleClassAndMethods().string).to.equal(
          'users[1]:Grace@primary|score=95|hits=12|flag=true',
        );
      });

      it('transforms Partial, Required, Readonly, Pick, Omit, EnumRecord, js.Record, NonNullable, Awaited, typeof & open mapped types', function () {
        expect(mod.exerciseUtilityTypesAndOpenMappedConditional().string).to.equal(
          'Linus2#3@edge.internal:443|ro=42|verbs=26|dyn=100|txt=[solid]|meta=v2@1|ep=root->api.zigar.dev:9443(tls)|nul:ok|rec:ok|dir=north!,south!|flags=opt-ok',
        );
        expect(mod.acceptUserFlags({ id: true, display_name: true, host_name: false })).to.equal(true);
      });
    });
  }
});
