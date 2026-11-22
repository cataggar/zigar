import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { copyFile, cp, mkdir, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { transpile } from '../dist/transpiler.js';
import { runTs } from '../src/index.js';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m4-node26-audit');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m4-node26-audit-wasm-${process.pid}`);
const BUILD_DIR = join(TEST_ROOT, 'zig-build');
const CACHE_DIR = join(TEST_ROOT, 'zig-cache');
const AUDIT_TMP_DIR = join(TEST_ROOT, 'audit-tmp');

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

function resolveComponentWasm() {
  const candidates = [
    process.env.TS_ZIGAR_COMPONENT_WASM,
    process.env.TS_ZIGAR_CACHE_DIR && join(process.env.TS_ZIGAR_CACHE_DIR, 'typescript-compiler.component.wasm'),
    join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm'),
    join(REPO_ROOT, '.cache/ts-zigar/typescript-compiler.component.wasm'),
  ].filter(Boolean);
  for (const cand of candidates) {
    if (existsSync(cand)) return cand;
  }
  return null;
}

function rewriteRuntimeImports(code) {
  return code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${RUNTIME_DIST_URL}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${RUNTIME_DIST_URL}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${RUNTIME_DIST_URL}$2"`);
}

async function generateUnfilteredNode26Bindings(typesNodeDir, outDir) {
  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = resolveComponentWasm();
  // Unfiltered full-package `@types/node@26` sweep with `-s "node:="` short-name prefix stripping.
  const cliArgs = [
    '-t', typesNodeDir,
    '-s', 'node:=',
    '-d', outDir,
  ];
  if (existsSync(nativeBin) && componentWasm) {
    await execFileAsync(nativeBin, [ '--component', componentWasm, ...cliArgs ], {
      cwd: REPO_ROOT,
      env: process.env,
    });
    return;
  }
  const code = await runTs(cliArgs, { silent: true, buildDir: BUILD_DIR });
  expect(code).to.equal(0);
}

describe('ts-zigar M4.2c Adversarial Audit: Unfiltered @types/node@26 tree-shaking, comptime speed, and load/memory safety (WASM)', function () {
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
    await mkdir(AUDIT_TMP_DIR, { recursive: true });
    await generateUnfilteredNode26Bindings(typesNodeDir, generatedMasterDir);

    const allEntries = await readdir(generatedMasterDir, { recursive: true });
    const zigFiles = allEntries.filter((f) => f.endsWith('.zig'));
    expect(zigFiles.length).to.be.at.least(70, 'expected full unfiltered @types/node@26 emission');
  });

  after(function () {
    if (existsSync(TEST_ROOT)) {
      rmSync(TEST_ROOT, { recursive: true, force: true });
    }
  });

  it('tree-shakes JS module imports to only ["node:http"] when compiling a single-module consumer against unfiltered 121-file @types/node@26', async function () {
    const singleDir = join(TEST_ROOT, 'http-only-wasm');
    await mkdir(singleDir, { recursive: true });
    await copyFile(join(SAMPLE_DIR, 'http_only.zig'), join(singleDir, 'http_only.zig'));
    await cp(generatedMasterDir, join(singleDir, 'generated'), { recursive: true });

    const zigPath = join(singleDir, 'http_only.zig');
    const zigFileUrl = pathToFileURL(zigPath).href;
    const result = await transpile(zigPath, {
      nodeCompat: false,
      embedWASM: true,
      topLevelAwait: true,
      stripWASM: true,
      optimize: 'ReleaseSmall',
      memory64: false,
      useJSPI: false,
      buildDir: BUILD_DIR,
      cacheDir: CACHE_DIR,
      jsModuleResolver: (spec) => (
        (spec.startsWith('./') || spec.startsWith('../'))
          ? new URL(spec, zigFileUrl).href
          : spec
      ),
    });

    expect(result.jsModules).to.deep.equal([ 'node:http' ]);
    expect(result.code).to.include('node:http');
    expect(result.code).to.not.include('node:fs');
    expect(result.code).to.not.include('node:sqlite');
    expect(result.code).to.not.include('node:crypto');

    const runnerMjs = join(singleDir, 'runner-http-only.mjs');
    await writeFile(runnerMjs, rewriteRuntimeImports(result.code), 'utf-8');
    const singleMod = await import(pathToFileURL(runnerMjs).href);
    expect(Number(await singleMod.readMaxHeaderSize())).to.be.at.least(8192);
    expect(Number(await singleMod.activeHandles())).to.equal(0);
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
        expect(result.jsModules).to.not.include('node:crypto');
        expect(result.jsModules).to.not.include('node:zlib');

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

      it('roundtrips -s "node:=" http.web_socket ConstructorOf and sqlite SQLTagStore TemplateStringsArray', async function () {
        const res = await mod.exerciseSyncM4Audit();
        expect(res.string).to.equal('sync-m4-audit-ok');
      });

      if (target.useJSPI) {
        it('completes 25-request HTTP loopback + 20-iteration FileHandle.asyncDispose & Readable stream load audit with zero leaks', async function () {
          const res = await mod.runAsyncM4LoadAudit(AUDIT_TMP_DIR);
          expect(res.string).to.equal('async-m4-load-audit-ok');
        });
      }
    });
  }
});
