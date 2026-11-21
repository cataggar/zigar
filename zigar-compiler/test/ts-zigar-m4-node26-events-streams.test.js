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
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m4-node26-events-streams');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m4-node26-events-streams-wasm-${process.pid}`);
const BUILD_DIR = join(TEST_ROOT, 'zig-build');
const CACHE_DIR = join(TEST_ROOT, 'zig-cache');

function resolveTypesNode26Dir() {
  const candidates = [
    process.env.TS_ZIGAR_TYPES_NODE26_DIR,
    process.env.TS_ZIGAR_CACHE_DIR && join(process.env.TS_ZIGAR_CACHE_DIR, 'types-node26/node_modules/@types/node'),
    join(REPO_ROOT, '.cache/ts-zigar/types-node26/node_modules/@types/node'),
    join(REPO_ROOT, '.cache/types-node26/node_modules/@types/node'),
  ].filter(Boolean);
  for (const cand of candidates) {
    if (existsSync(join(cand, 'package.json'))) return cand;
  }
  return null;
}

function rewriteRuntimeImports(code) {
  return code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${RUNTIME_DIST_URL}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${RUNTIME_DIST_URL}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${RUNTIME_DIST_URL}$2"`);
}

async function generateBindings(typesNodeDir, outDir) {
  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm');
  const cliArgs = [
    '-t', typesNodeDir,
    '-m', 'globals',
    '-m', 'node:buffer',
    '-m', 'node:events',
    '-m', 'node:stream',
    '-m', 'node:stream/consumers',
    '-m', 'node:stream/promises',
    '-m', 'node:stream/web',
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

describe('ts-zigar M4.1b Live Runtime Roundtrip: @types/node@26 events (typed EventEmitter), stream, stream/consumers, stream/promises, and stream/web (WASM)', function () {
  this.timeout(300_000);

  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    const typesNodeDir = resolveTypesNode26Dir();
    if (!typesNodeDir || !process.version.startsWith('v26.')) {
      this.skip();
      return;
    }
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(typesNodeDir, generatedMasterDir);
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
          jsModuleResolver: (spec) => (
            (spec.startsWith('./') || spec.startsWith('../'))
              ? new URL(spec, consumerFileUrl).href
              : spec
          ),
        });

        for (const modSpec of result.jsModules) {
          expect(modSpec.startsWith('node:')).to.equal(true, `expected canonical node:* specifier, got ${modSpec}`);
        }
        expect(result.jsModules).to.include.members([
          'node:events',
          'node:stream',
          'node:stream/consumers',
        ]);
        if (target.useJSPI) {
          expect(result.jsModules).to.include.members([
            'node:stream/promises',
            'node:stream/web',
          ]);
        }

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

      it('roundtrips typed EventEmitter(MyEvents), addAbortListener Symbol.dispose, PassThrough, and Readable.toWeb/fromWeb', async function () {
        const res = await mod.exerciseSyncEventsAndStreams();
        expect(res.string).to.equal('sync-events-streams-ok');
      });

      if (target.useJSPI) {
        it('roundtrips events.once/on, stream.Readable asyncIterator, stream/consumers, stream/promises pipeline + PipelineResult, and stream/web via JSPI', async function () {
          const res = await mod.runAsyncEventsAndStreams();
          expect(res.string).to.equal('async-events-streams-ok');
        });
      } else {
        it('returns HostUnavailable on auto-awaited stream/consumers.text without JSPI while preserving textPromise leak-free', function () {
          expect(mod.probeSyncStreamConsumersHostUnavailable()).to.equal(true);
        });
      }
    });
  }
});
