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
const SAMPLE_DIR = resolve(REPO_ROOT, 'zigar-compiler/test/zig-samples/js-value/ts-m3-heritage');
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-heritage-node-${process.pid}`);
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
    '-m', 'm3-heritage-esm',
    '-m', 'm3-heritage-base',
    '-m', 'm3-heritage-cjs',
    '-m', 'm3-heritage-def',
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

describe('ts-zigar M3.2b Live Runtime Roundtrip: Inheritance, Intersections, Index Signatures & Declaration Merging (node-zigar Native)', function () {
  this.timeout(240_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(join(SAMPLE_DIR, 'm3-heritage-esm.d.mts'), generatedMasterDir);
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
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-base.mjs'), join(targetDir, 'm3-heritage-base.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-cjs.cjs'), join(targetDir, 'm3-heritage-cjs.cjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-def.mjs'), join(targetDir, 'm3-heritage-def.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-esm.mjs'), join(targetDir, 'm3-heritage-esm.mjs'));

        const basePkgDir = join(targetDir, 'node_modules', 'm3-heritage-base');
        await mkdir(basePkgDir, { recursive: true });
        await writeFile(
          join(basePkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-heritage-base', version: '1.0.0', type: 'module', main: './index.mjs' }),
          'utf-8',
        );
        await writeFile(
          join(basePkgDir, 'index.mjs'),
          `export * from '../../m3-heritage-base.mjs';\n`,
          'utf-8',
        );

        const esmPkgDir = join(targetDir, 'node_modules', 'm3-heritage-esm');
        await mkdir(esmPkgDir, { recursive: true });
        await writeFile(
          join(esmPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-heritage-esm', version: '1.0.0', type: 'module', main: './index.mjs' }),
          'utf-8',
        );
        await writeFile(
          join(esmPkgDir, 'index.mjs'),
          `export * from '../../m3-heritage-esm.mjs';\n`,
          'utf-8',
        );

        const cjsPkgDir = join(targetDir, 'node_modules', 'm3-heritage-cjs');
        await mkdir(cjsPkgDir, { recursive: true });
        await writeFile(
          join(cjsPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-heritage-cjs', version: '1.0.0', main: 'index.cjs' }),
          'utf-8',
        );
        await writeFile(
          join(cjsPkgDir, 'index.cjs'),
          `'use strict';\nmodule.exports = require('../../m3-heritage-cjs.cjs');\n`,
          'utf-8',
        );

        const defPkgDir = join(targetDir, 'node_modules', 'm3-heritage-def');
        await mkdir(defPkgDir, { recursive: true });
        await writeFile(
          join(defPkgDir, 'package.json'),
          JSON.stringify({ name: 'm3-heritage-def', version: '1.0.0', type: 'module', main: './index.mjs' }),
          'utf-8',
        );
        await writeFile(
          join(defPkgDir, 'index.mjs'),
          `export { default } from '../../m3-heritage-def.mjs';\n`,
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

      it('exercises multi-level class inheritance, implements, borrowed .as upcast, .clone, and non-invoking .tryAs downcast', function () {
        expect(mod.exerciseClassHeritageUpcastCloneAndDowncast().string).to.equal('class-heritage-upcast-clone-downcast-ok');
      });

      it('exercises diamond multiple interface inheritance overloads and value-struct .as(Base) projection with inline enums', function () {
        expect(mod.exerciseDiamondInterfacesAndValueStructProjection().string).to.equal('diamond-interfaces-and-value-projection-ok');
      });

      it('exercises noreturn intersections, branded primitives, distributed tagged unions, and recursive .bases handle guards', function () {
        expect(mod.exerciseIntersectionsBrandsUnionsAndRecursiveGuards().string).to.equal('intersections-brands-unions-and-guards-ok');
      });

      it('exercises string/number/template/enum/symbol index signatures, HeaderBag.init(), and collision-safe CollidingDict', function () {
        expect(mod.exerciseIndexSignaturesAndCollisionSafeDicts().string).to.equal('index-signatures-and-collision-safe-dicts-ok');
      });

      it('exercises declaration merging across interfaces, classes, namespaces, $, _, default exports, enums, and declare module', function () {
        expect(mod.exerciseDeclarationMergingAndAugmentations().string).to.equal('declaration-merging-and-augmentations-ok');
      });
    });
  }
});
