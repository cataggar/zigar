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
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m3-generics');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-generics-wasm-${process.pid}`);
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

describe('ts-zigar M3.3b Live Runtime Roundtrip: Generics, Constraints, Defaults, Type Operators & Utility Types (WASM)', function () {
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

  for (const target of [
    { label: 'wasm32', memory64: false },
    { label: 'wasm64', memory64: true },
  ]) {
    describe(`Target: ${target.label}`, function () {
      let mod;

      before(async function () {
        const targetDir = join(TEST_ROOT, target.label);
        await mkdir(targetDir, { recursive: true });
        await copyFile(join(SAMPLE_DIR, 'm3-generics-esm.mjs'), join(targetDir, 'm3-generics-esm.mjs'));
        await copyFile(join(SAMPLE_DIR, 'm3-generics-cjs.cjs'), join(targetDir, 'm3-generics-cjs.cjs'));
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
            if (spec === 'm3-generics-esm') return new URL('./m3-generics-esm.mjs', consumerFileUrl).href;
            if (spec === 'm3-generics-cjs') return new URL('./m3-generics-cjs.cjs', consumerFileUrl).href;
            return (spec.startsWith('./') || spec.startsWith('../'))
              ? new URL(spec, consumerFileUrl).href
              : spec;
          },
        });

        expect(result.jsModules).to.have.members([
          'm3-generics-esm',
          'm3-generics-cjs',
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
