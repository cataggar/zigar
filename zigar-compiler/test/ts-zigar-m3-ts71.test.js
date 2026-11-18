import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { copyFile, cp, mkdir, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { transpile } from '../dist/transpiler.js';
import { runTs } from '../src/index.js';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
const SAMPLE_DIR = resolve(__dirname, './zig-samples/js-value/ts-m3-ts71');
const RUNTIME_DIST_URL = pathToFileURL(resolve(REPO_ROOT, 'zigar-runtime/dist') + '/').href;
const TMP_BASE = process.env.TMPDIR || join(REPO_ROOT, '.cache', 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-m3-ts71-wasm-${process.pid}`);
const BUILD_DIR = join(TEST_ROOT, 'zig-build');
const CACHE_DIR = join(TEST_ROOT, 'zig-cache');
const REQUIRE_TS71 = /^(1|true|yes)$/i.test(process.env.TS_ZIGAR_REQUIRE_TS71 ?? '');

function resolveStagedTs71Pkg() {
  const fromEnv = process.env.TS_ZIGAR_TYPESCRIPT_PKG?.trim();
  const fromCache = process.env.TS_ZIGAR_CACHE_DIR?.trim();
  const candidates = [
    ...(fromEnv ? [resolve(fromEnv), resolve(fromEnv, 'node_modules/typescript')] : []),
    ...(fromCache ? [resolve(fromCache, 'typescript-71-pkg/node_modules/typescript')] : []),
    resolve(REPO_ROOT, 'ts-zigar/component/dist/typescript-71-pkg/node_modules/typescript'),
    resolve(REPO_ROOT, '.cache/ts-zigar/typescript-71-pkg/node_modules/typescript'),
    resolve(REPO_ROOT, '../.cache/ts-zigar/typescript-71-pkg/node_modules/typescript'),
  ];
  for (const cand of candidates) {
    if (existsSync(join(cand, 'package.json'))) return cand;
  }
  return null;
}

async function verifyGeneratedRuntimeTargets(generatedDir, tsPkgDir) {
  const tsReq = createRequire(join(tsPkgDir, 'package.json'));
  const zigFiles = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.zig')) zigFiles.push(full);
    }
  };
  walk(generatedDir);

  const targetRe = /\.\{\s*\.module\s*=\s*"((?:\\.|[^"\\])*)"(?:\s*,\s*\.ns_path\s*=\s*&\.{\s*([^}]*)\s*\})?\s*,\s*\.name\s*=\s*"((?:\\.|[^"\\])*)"\s*\}/g;
  const modCache = new Map();
  let totalTargets = 0;
  const invalidTargets = [];

  for (const zigFile of zigFiles) {
    const src = readFileSync(zigFile, 'utf8');
    let match;
    while ((match = targetRe.exec(src)) !== null) {
      totalTargets += 1;
      const modSpec = JSON.parse(`"${match[1]}"`);
      const nsPath = match[2]
        ? [...match[2].matchAll(/"((?:\\.|[^"\\])*)"/g)].map((m) => JSON.parse(`"${m[1]}"`))
        : [];
      const exportName = JSON.parse(`"${match[3]}"`);
      try {
        if (!modCache.has(modSpec)) {
          const resolvedPath = tsReq.resolve(modSpec);
          modCache.set(modSpec, await import(pathToFileURL(resolvedPath).href));
        }
        let cur = modCache.get(modSpec);
        for (const seg of nsPath) cur = cur?.[seg];
        if (cur == null || (!(exportName in Object(cur)) && cur[exportName] === undefined)) {
          invalidTargets.push({
            file: relative(generatedDir, zigFile),
            module: modSpec,
            nsPath,
            name: exportName,
          });
        }
      } catch (err) {
        invalidTargets.push({
          file: relative(generatedDir, zigFile),
          module: modSpec,
          nsPath,
          name: exportName,
          error: err.code || err.message,
        });
      }
    }
  }

  return { zigFileCount: zigFiles.length, totalTargets, invalidTargets };
}

function rewriteRuntimeImports(code) {
  return code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${RUNTIME_DIST_URL}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${RUNTIME_DIST_URL}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${RUNTIME_DIST_URL}$2"`);
}

async function generateBindings(tsPkgDir, outDir) {
  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm');
  const cliArgs = ['-t', tsPkgDir, '-d', outDir];
  if (existsSync(nativeBin) && existsSync(componentWasm)) {
    await execFileAsync(nativeBin, ['--component', componentWasm, ...cliArgs], {
      cwd: REPO_ROOT,
      env: process.env,
    });
    return;
  }
  const code = await runTs(cliArgs, { silent: true, buildDir: BUILD_DIR });
  expect(code).to.equal(0);
}

describe('ts-zigar M3.4a Torture Test: TypeScript 7.1 Sync Compiler & Type Checker Live Roundtrip (WASM)', function () {
  this.timeout(300_000);

  const tsPkgDir = resolveStagedTs71Pkg();
  const generatedMasterDir = join(TEST_ROOT, 'generated-master');

  before(async function () {
    if (!tsPkgDir) {
      if (REQUIRE_TS71) {
        throw new Error(
          'TS_ZIGAR_REQUIRE_TS71 is set, but staged TypeScript 7.1 package was not found. Run: node ts-zigar/component/build-typescript-pkg.mjs',
        );
      }
      this.skip();
      return;
    }
    await mkdir(BUILD_DIR, { recursive: true });
    await mkdir(CACHE_DIR, { recursive: true });
    await generateBindings(tsPkgDir, generatedMasterDir);
  });

  it('resolves 100% of emitted .module and .name runtime targets across all generated TypeScript 7.1 .zig files in Node.js', async function () {
    if (!tsPkgDir) this.skip();
    const report = await verifyGeneratedRuntimeTargets(generatedMasterDir, tsPkgDir);
    expect(report.zigFileCount).to.be.at.least(85);
    expect(report.totalTargets).to.be.at.least(1500);
    expect(report.invalidTargets).to.deep.equal([]);
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
        if (!tsPkgDir) {
          this.skip();
          return;
        }
        const tsReq = createRequire(join(tsPkgDir, 'package.json'));
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
          buildDir: BUILD_DIR,
          cacheDir: CACHE_DIR,
          jsModuleResolver: (spec) => {
            if (spec === 'typescript' || spec.startsWith('typescript/')) {
              return pathToFileURL(tsReq.resolve(spec)).href;
            }
            return (spec.startsWith('./') || spec.startsWith('../'))
              ? new URL(spec, consumerFileUrl).href
              : spec;
          },
        });

        expect(result.jsModules).to.include.members([
          'typescript/sync',
          'typescript/fs',
          'typescript/ast/is',
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

      it('spawns TypeScript 7.1 sync API from Zig, parses virtual project, iterates NodeArray, checks types, and disposes cleanly', function () {
        expect(mod.checkInMemoryTypeScriptProgram().string).to.equal(
          'answer=42|summary={ readonly total: 42; }|stmts=3',
        );
      });
    });
  }
});
