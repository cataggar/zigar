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
const SAMPLE_DIR = resolve(REPO_ROOT, 'zigar-compiler/test/zig-samples/js-value/ts-m3-objects');
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-objects-node-${process.pid}`);
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
    '-m', 'm3-objects-esm',
    '-m', 'm3-objects-cjs',
    '-m', 'm3-objects-def',
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

describe('ts-zigar M3.2a Live Runtime Roundtrip: Plain Options Structs vs Handle Classes & Stateful Interfaces (node-zigar Native)', function () {
  this.timeout(240_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(join(SAMPLE_DIR, 'm3-objects-esm.d.mts'), generatedMasterDir);
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
        await copyFile(join(SAMPLE_DIR, 'm3-objects-esm.mjs'), join(targetDir, 'm3-objects-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-objects-cjs.cjs'), join(targetDir, 'm3-objects-cjs.cjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-objects-def.mjs'), join(targetDir, 'm3-objects-def.mjs'));

        const esmPkgDir = join(targetDir, 'node_modules', 'm3-objects-esm');
        await mkdir(esmPkgDir, { recursive: true });
        await writeFile(
          join(esmPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-objects-esm', version: '1.0.0', type: 'module', main: './index.mjs' }),
          'utf-8',
        );
        await writeFile(
          join(esmPkgDir, 'index.mjs'),
          `export * from '../../m3-objects-esm.mjs';\n`,
          'utf-8',
        );

        const cjsPkgDir = join(targetDir, 'node_modules', 'm3-objects-cjs');
        await mkdir(cjsPkgDir, { recursive: true });
        await writeFile(
          join(cjsPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-objects-cjs', version: '1.0.0', main: 'index.cjs' }),
          'utf-8',
        );
        await writeFile(
          join(cjsPkgDir, 'index.cjs'),
          `'use strict';\nmodule.exports = require('../../m3-objects-cjs.cjs');\n`,
          'utf-8',
        );

        const defPkgDir = join(targetDir, 'node_modules', 'm3-objects-def');
        await mkdir(defPkgDir, { recursive: true });
        await writeFile(
          join(defPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-objects-def', version: '1.0.0', type: 'module', main: './index.mjs' }),
          'utf-8',
        );
        await writeFile(
          join(defPkgDir, 'index.mjs'),
          `export { default } from '../../m3-objects-def.mjs';\n`,
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
          expect(Number(mod.liveZigAllocs())).to.equal(0);
          expect(Boolean(mod.hasPendingCapturedError())).to.equal(false);
        }
      });

      it('roundtrips plain options structs with omitted optionals, inherited fields, and cyclic LinkedNode toJsRef/fromJsRefAlloc', function () {
        expect(mod.exercisePlainOptionsAndCyclicStructs().string).to.equal('plain-options-and-cyclic-ok');
      });

      it('exercises abstract & derived classes, overloaded init, divergent/WO/RO/nominal accessors, static members, and instanceof guard', function () {
        expect(mod.exerciseClassesInheritanceAndAccessors().string).to.equal('classes-inheritance-and-accessors-ok');
      });

      it('roundtrips export default class, CJS export = class (.ref() collision safety), and interface + declare var companion constructors', function () {
        expect(mod.exerciseDefaultCjsAndCompanionConstructors().string).to.equal('default-cjs-and-companion-ctors-ok');
      });

      it('validates stateful duck-typed handles without premature getter side effects and invokes callable/constructable interfaces', function () {
        expect(mod.exerciseStatefulDuckHandlesAndCallableInterfaces().string).to.equal('stateful-duck-and-callable-handles-ok');
      });
    });
  }
});
