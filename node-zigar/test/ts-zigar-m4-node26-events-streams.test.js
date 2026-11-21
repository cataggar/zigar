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
const SAMPLE_DIR = resolve(REPO_ROOT, 'zigar-compiler/test/zig-samples/js-value/ts-m4-node26-events-streams');
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m4-node26-events-streams-node-${process.pid}`);
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

describe('ts-zigar M4.1b Live Runtime Roundtrip: @types/node@26 events (typed EventEmitter), stream, stream/consumers, stream/promises, and stream/web (node-zigar Native)', function () {
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

  for (const loaderMode of [ 'esm', 'cjs' ]) {
    describe(`Loader mode: ${loaderMode.toUpperCase()}`, function () {
      let mod;
      let started = false;

      before(async function () {
        const targetDir = join(TEST_ROOT, loaderMode);
        await mkdir(targetDir, { recursive: true });
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
        await mod.startup(1);
        started = true;
      });

      after(async function () {
        if (mod && started) {
          await mod.shutdown();
          started = false;
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

      it('roundtrips main-thread typed EventEmitter(MyEvents), addAbortListener Symbol.dispose, PassThrough, and Readable.toWeb/fromWeb', function () {
        expect(mod.exerciseSyncEventsAndStreams().string).to.equal('sync-events-streams-ok');
        expect(mod.probeSyncStreamConsumersHostUnavailable()).to.equal(true);
      });

      it('roundtrips events.once/on, stream.Readable asyncIterator, stream/consumers, stream/promises pipeline + PipelineResult, and stream/web on WorkQueue', async function () {
        const res = await mod.runAsyncEventsAndStreams();
        expect(res.string).to.equal('async-events-streams-ok');
      });
    });
  }
});
