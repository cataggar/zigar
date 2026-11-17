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
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m3-heritage');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-heritage-wasm-${process.pid}`);
const BUILD_DIR = join(TEST_ROOT, 'zig-build');
const CACHE_DIR = join(TEST_ROOT, 'zig-cache');

function rewriteRuntimeImports(code) {
  return code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${RUNTIME_DIST_URL}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${RUNTIME_DIST_URL}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${RUNTIME_DIST_URL}$2"`);
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

describe('ts-zigar M3.2b Live Runtime Roundtrip: Inheritance, Intersections, Index Signatures & Declaration Merging (WASM)', function () {
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

  for (const target of [
    { label: 'wasm32', memory64: false },
    { label: 'wasm64', memory64: true },
  ]) {
    describe(`Target: ${target.label}`, function () {
      let mod;

      before(async function () {
        const targetDir = join(TEST_ROOT, target.label);
        await mkdir(targetDir, { recursive: true });
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-base.mjs'), join(targetDir, 'm3-heritage-base.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-cjs.cjs'), join(targetDir, 'm3-heritage-cjs.cjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-def.mjs'), join(targetDir, 'm3-heritage-def.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-heritage-esm.mjs'), join(targetDir, 'm3-heritage-esm.mjs'));
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
            if (spec === 'm3-heritage-esm') return new URL('./m3-heritage-esm.mjs', consumerFileUrl).href;
            if (spec === 'm3-heritage-base') return new URL('./m3-heritage-base.mjs', consumerFileUrl).href;
            if (spec === 'm3-heritage-cjs') return new URL('./m3-heritage-cjs.cjs', consumerFileUrl).href;
            if (spec === 'm3-heritage-def') return new URL('./m3-heritage-def.mjs', consumerFileUrl).href;
            return (spec.startsWith('./') || spec.startsWith('../'))
              ? new URL(spec, consumerFileUrl).href
              : spec;
          },
        });

        expect(result.jsModules).to.have.members([
          'm3-heritage-esm',
          'm3-heritage-base',
          'm3-heritage-cjs',
          'm3-heritage-def',
        ]);
        const runnerMjs = join(targetDir, `runner-${target.label}.mjs`);
        await writeFile(runnerMjs, rewriteRuntimeImports(result.code), 'utf-8');
        mod = await import(pathToFileURL(runnerMjs).href);
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
