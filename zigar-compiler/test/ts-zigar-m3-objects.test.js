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
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m3-objects');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-objects-wasm-${process.pid}`);
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

describe('ts-zigar M3.2a Live Runtime Roundtrip: Plain Options Structs vs Handle Classes & Stateful Interfaces (WASM)', function () {
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

  for (const target of [
    { label: 'wasm32', memory64: false },
    { label: 'wasm64', memory64: true },
  ]) {
    describe(`Target: ${target.label}`, function () {
      let mod;

      before(async function () {
        const targetDir = join(TEST_ROOT, target.label);
        await mkdir(targetDir, { recursive: true });
        await copyFile(join(SAMPLE_DIR, 'm3-objects-esm.mjs'), join(targetDir, 'm3-objects-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-objects-cjs.cjs'), join(targetDir, 'm3-objects-cjs.cjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-objects-def.mjs'), join(targetDir, 'm3-objects-def.mjs'));
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
            if (spec === 'm3-objects-esm') return new URL('./m3-objects-esm.mjs', consumerFileUrl).href;
            if (spec === 'm3-objects-cjs') return new URL('./m3-objects-cjs.cjs', consumerFileUrl).href;
            if (spec === 'm3-objects-def') return new URL('./m3-objects-def.mjs', consumerFileUrl).href;
            return (spec.startsWith('./') || spec.startsWith('../'))
              ? new URL(spec, consumerFileUrl).href
              : spec;
          },
        });

        expect(result.jsModules).to.have.members([ 'm3-objects-esm', 'm3-objects-cjs', 'm3-objects-def' ]);
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
