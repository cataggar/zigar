import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { existsSync, mkdirSync, rmSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { runTs } from '../src/index.js';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
const WORKTREE_CACHE_DIR = join(REPO_ROOT, '.cache');
const TMP_BASE = process.env.TMPDIR || join(WORKTREE_CACHE_DIR, 'tmp');
const TEST_ROOT = join(TMP_BASE, `ts-zigar-cli-test-${process.pid}`);
const BUILD_DIR = join(TEST_ROOT, 'zigar-build');

const CLI_ENTRIES = [
  {
    pkg: 'zigar-compiler',
    cliPath: join(REPO_ROOT, 'zigar-compiler/bin/cli.js'),
    ts2zigPath: join(REPO_ROOT, 'zigar-compiler/bin/ts2zig.js'),
    pkgJsonPath: join(REPO_ROOT, 'zigar-compiler/package.json'),
  },
  {
    pkg: 'node-zigar',
    cliPath: join(REPO_ROOT, 'node-zigar/bin/cli.js'),
    ts2zigPath: join(REPO_ROOT, 'node-zigar/bin/ts2zig.js'),
    pkgJsonPath: join(REPO_ROOT, 'node-zigar/package.json'),
  },
  {
    pkg: 'bun-zigar',
    cliPath: join(REPO_ROOT, 'bun-zigar/bin/cli.js'),
    ts2zigPath: join(REPO_ROOT, 'bun-zigar/bin/ts2zig.js'),
    pkgJsonPath: join(REPO_ROOT, 'bun-zigar/package.json'),
  },
  {
    pkg: 'rollup-plugin-zigar',
    cliPath: join(REPO_ROOT, 'rollup-plugin-zigar/bin/cli.js'),
    ts2zigPath: join(REPO_ROOT, 'rollup-plugin-zigar/bin/ts2zig.js'),
    pkgJsonPath: join(REPO_ROOT, 'rollup-plugin-zigar/package.json'),
  },
  {
    pkg: 'zigar-loader',
    cliPath: join(REPO_ROOT, 'zigar-loader/bin/cli.js'),
    ts2zigPath: join(REPO_ROOT, 'zigar-loader/bin/ts2zig.js'),
    pkgJsonPath: join(REPO_ROOT, 'zigar-loader/package.json'),
  },
];

async function runNodeCli(scriptPath, cliArgs, extraEnv = {}) {
  try {
    const { stdout, stderr } = await execFileAsync(
      process.execPath,
      [ scriptPath, ...cliArgs ],
      {
        cwd: REPO_ROOT,
        env: {
          ...process.env,
          ZIGAR_CACHE_DIR: BUILD_DIR,
          ...extraEnv,
        },
      },
    );
    return { code: 0, stdout, stderr };
  } catch (err) {
    return {
      code: typeof err.code === 'number' ? err.code : 1,
      stdout: err.stdout ?? '',
      stderr: err.stderr ?? '',
    };
  }
}

describe('ts-zigar CLI, zigar ts, and ts2zig integration (Issue #44)', function () {
  this.timeout(240_000);

  before(function () {
    mkdirSync(TEST_ROOT, { recursive: true });
    mkdirSync(BUILD_DIR, { recursive: true });
  });

  after(function () {
    if (existsSync(TEST_ROOT)) {
      rmSync(TEST_ROOT, { recursive: true, force: true });
    }
  });

  it('wires bin.zigar and bin.ts2zig in package.json across zigar-compiler, node-zigar, and bun-zigar', async function () {
    for (const entry of CLI_ENTRIES) {
      const pkgJson = JSON.parse(await readFile(entry.pkgJsonPath, 'utf-8'));
      expect(pkgJson.bin).to.be.an('object');
      expect(pkgJson.bin.zigar).to.be.a('string');
      expect(pkgJson.bin.ts2zig).to.be.a('string');
      expect(existsSync(entry.cliPath)).to.equal(true, `missing ${entry.cliPath}`);
      expect(existsSync(entry.ts2zigPath)).to.equal(true, `missing ${entry.ts2zigPath}`);
    }
  });

  it('lists ts subcommand in top-level help and runs zigar ts --help & ts2zig --help across all packages', async function () {
    // Warm up cached ts-zigar.wasm build once before spawning 6 CLI processes
    const warm = await runTs([ '--help' ], { silent: true, buildDir: BUILD_DIR });
    expect(warm.code).to.equal(0);
    expect(warm.stdout).to.include('--types');
    expect(warm.stdout).to.include('--out-dir');
    expect(warm.stdout).to.include('--module');
    expect(warm.stdout).to.include('--substitute');

    for (const entry of CLI_ENTRIES) {
      const topHelp = await runNodeCli(entry.cliPath, [ 'help' ]);
      expect(topHelp.code).to.equal(0, `${entry.pkg} cli.js help failed: ${topHelp.stderr}`);
      expect(topHelp.stdout).to.include('ts [args]');

      const tsHelp = await runNodeCli(entry.cliPath, [ 'ts', '--help' ]);
      expect(tsHelp.code).to.equal(0, `${entry.pkg} cli.js ts --help failed: ${tsHelp.stderr}`);
      expect(tsHelp.stdout).to.include('-t, --types');
      expect(tsHelp.stdout).to.include('-d, --out-dir');
      expect(tsHelp.stdout).to.include('-m, --module');
      expect(tsHelp.stdout).to.include('-s, --substitute');
      expect(tsHelp.stdout).to.include('--component');

      const aliasHelp = await runNodeCli(entry.ts2zigPath, [ '--help' ]);
      expect(aliasHelp.code).to.equal(0, `${entry.pkg} ts2zig.js --help failed: ${aliasHelp.stderr}`);
      expect(aliasHelp.stdout).to.include('-t, --types');
      expect(aliasHelp.stdout).to.include('-d, --out-dir');

      const aliasVer = await runNodeCli(entry.ts2zigPath, [ '--version' ]);
      expect(aliasVer.code).to.equal(0);
      expect(aliasVer.stdout).to.include('ts-zigar');
    }
  });

  it('returns non-zero exit codes with clear diagnostics on invalid flags, missing args, or malformed -s', async function () {
    const missingArgs = await runTs([], { silent: true, buildDir: BUILD_DIR });
    expect(missingArgs.code).to.not.equal(0);
    expect(missingArgs.stderr).to.include('--types');

    const unknownFlag = await runTs([ '--unknown-flag' ], { silent: true, buildDir: BUILD_DIR });
    expect(unknownFlag.code).to.not.equal(0);
    expect(unknownFlag.stderr).to.include('--unknown-flag');

    const badSub = await runNodeCli(CLI_ENTRIES[0].ts2zigPath, [
      '-t', 'foo.d.ts',
      '-d', join(TEST_ROOT, 'unused-out'),
      '-s', 'missing_equals_sign',
    ]);
    expect(badSub.code).to.not.equal(0);
    expect(badSub.stderr).to.include('substitute');

    const missingComp = await runTs([
      '-t', 'foo.d.ts',
      '-d', join(TEST_ROOT, 'unused-out'),
      '--component', join(TEST_ROOT, 'does-not-exist.component.wasm'),
    ], { silent: true, buildDir: BUILD_DIR });
    expect(missingComp.code).to.not.equal(0);
    expect(missingComp.stderr).to.include('does-not-exist.component.wasm');
  });

  it('emits AST-validated, compilable Zig 0.17 modules via runTs, cli.js ts, and ts2zig.js', async function () {
    const fixtureDir = join(TEST_ROOT, 'pkg-fixture');
    mkdirSync(fixtureDir, { recursive: true });

    await writeFile(
      join(fixtureDir, 'package.json'),
      JSON.stringify({
        name: '@demo/net-kit',
        version: '1.0.0',
        types: './index.d.ts',
      }, null, 2),
      'utf-8',
    );

    await writeFile(
      join(fixtureDir, 'peer.d.ts'),
      [
        'import type { ServerNode } from "./index";',
        '/** Peer endpoint with CRLF docs.\r\n * @deprecated Use ServerNode directly.\r\n */',
        'export interface PeerInfo {',
        '  readonly id: string;',
        '  type: number;',
        '  owner?: ServerNode;',
        '}',
        '',
      ].join('\r\n'),
      'utf-8',
    );

    await writeFile(
      join(fixtureDir, 'ambient.d.ts'),
      [
        'declare module "node:http" {',
        '  export interface RequestOptions {',
        '    method?: string;',
        '    timeout?: number;',
        '  }',
        '  export function request(url: string, opts?: RequestOptions): void;',
        '}',
        '',
      ].join('\r\n'),
      'utf-8',
    );

    await writeFile(
      join(fixtureDir, 'index.d.ts'),
      [
        '/// <reference path="./ambient.d.ts" />',
        'import type { PeerInfo } from "./peer";',
        '/** Primary server node.\r\n * @param port Port number\r\n */',
        'export interface ServerNode {',
        '  error?: string;',
        '  u8: number;',
        '  peer?: PeerInfo;',
        '}',
        'export enum Mode {',
        '  Fast = 0,',
        '  Safe = 1,',
        '}',
        'export declare function test(node: ServerNode, suspend?: boolean): Promise<PeerInfo>;',
        'export declare namespace internal {',
        '  export function ping(target: string): boolean;',
        '}',
        '',
      ].join('\r\n'),
      'utf-8',
    );

    // 1. Programmatic `runTs` on package directory with `-s` substitution
    const outRunTs = join(TEST_ROOT, 'out-runts');
    const res1 = await runTs(
      [ '-t', fixtureDir, '-d', outRunTs, '-s', 'index=net_kit', '-s', 'node:http=http' ],
      { silent: true, buildDir: BUILD_DIR },
    );
    expect(res1.code).to.equal(0, `runTs failed:\n${res1.stderr}`);
    expect(existsSync(join(outRunTs, 'root.zig'))).to.equal(true);
    expect(existsSync(join(outRunTs, 'net_kit.zig'))).to.equal(true);
    expect(existsSync(join(outRunTs, 'peer.zig'))).to.equal(true);
    expect(existsSync(join(outRunTs, 'http.zig'))).to.equal(true);

    const netKitZig = await readFile(join(outRunTs, 'net_kit.zig'), 'utf-8');
    expect(netKitZig).to.not.include('usingnamespace');
    expect(netKitZig).to.not.include('\r');
    expect(netKitZig).to.include('@"error"');
    expect(netKitZig).to.include('u8: f64');
    expect(netKitZig).to.include('@"test"');
    expect(netKitZig).to.include('@"suspend"');

    // Verify `zig ast-check` and `zig test` pass on generated `root.zig`!
    await execFileAsync('zig', [ 'ast-check', join(outRunTs, 'root.zig') ], {
      cwd: REPO_ROOT,
      env: process.env,
    });
    await execFileAsync('zig', [ 'test', join(outRunTs, 'root.zig') ], {
      cwd: REPO_ROOT,
      env: process.env,
    });

    // 2. `cli.js ts` subprocess invocation
    const outCliTs = join(TEST_ROOT, 'out-cli-ts');
    const res2 = await runNodeCli(CLI_ENTRIES[0].cliPath, [
      'ts',
      '-t', join(fixtureDir, 'index.d.ts'),
      '-d', outCliTs,
    ]);
    expect(res2.code).to.equal(0, `cli.js ts failed:\n${res2.stderr}`);
    expect(existsSync(join(outCliTs, 'root.zig'))).to.equal(true);
    await execFileAsync('zig', [ 'ast-check', join(outCliTs, 'root.zig') ], {
      cwd: REPO_ROOT,
      env: process.env,
    });

    // 3. `node-zigar/bin/ts2zig.js` subprocess invocation with `-m` filtering & `-s` substitution
    const outAlias = join(TEST_ROOT, 'out-ts2zig');
    const res3 = await runNodeCli(CLI_ENTRIES[1].ts2zigPath, [
      '-t', fixtureDir,
      '-d', outAlias,
      '-m', 'node:http',
      '-s', 'node:http=http',
    ]);
    expect(res3.code).to.equal(0, `node-zigar ts2zig.js failed:\n${res3.stderr}`);
    expect(existsSync(join(outAlias, 'root.zig'))).to.equal(true);
    expect(existsSync(join(outAlias, 'http.zig'))).to.equal(true);
    expect(existsSync(join(outAlias, 'index.zig'))).to.equal(false);
    await execFileAsync('zig', [ 'ast-check', join(outAlias, 'root.zig') ], {
      cwd: REPO_ROOT,
      env: process.env,
    });
    await execFileAsync('zig', [ 'test', join(outAlias, 'root.zig') ], {
      cwd: REPO_ROOT,
      env: process.env,
    });
  });

  it('packs zigar-compiler with Go adapter sources and executes ts2zig from an isolated node_modules install without polluting node_modules', async function () {
    const packDir = join(TEST_ROOT, 'npm-pack-out');
    const installRoot = join(TEST_ROOT, 'isolated-consumer');
    const pkgDest = join(installRoot, 'node_modules/zigar-compiler');
    const isolatedCache = join(TEST_ROOT, 'isolated-zigar-cache');
    const outPacked = join(TEST_ROOT, 'out-packed');
    mkdirSync(packDir, { recursive: true });
    mkdirSync(pkgDest, { recursive: true });
    mkdirSync(isolatedCache, { recursive: true });

    const { stdout: packStdout } = await execFileAsync(
      'npm',
      [ 'pack', '--pack-destination', packDir ],
      {
        cwd: join(REPO_ROOT, 'zigar-compiler'),
        env: {
          ...process.env,
          NPM_CONFIG_CACHE: process.env.NPM_CONFIG_CACHE || join(WORKTREE_CACHE_DIR, 'npm'),
        },
      },
    );
    const tgzName = packStdout.trim().split(/\r?\n/).pop();
    const tgzPath = join(packDir, tgzName);
    expect(existsSync(tgzPath)).to.equal(true, `missing packed tarball ${tgzPath}`);

    await execFileAsync('tar', [ '-xzf', tgzPath, '--strip-components=1', '-C', pkgDest ], {
      cwd: installRoot,
      env: process.env,
    });

    // Verify all ts-zigar + wit-zigar + Go component adapter sources are packed
    expect(existsSync(join(pkgDest, 'zig/wit-zigar/src/main.zig'))).to.equal(true);
    expect(existsSync(join(pkgDest, 'zig/ts-zigar/src/main.zig'))).to.equal(true);
    expect(existsSync(join(pkgDest, 'zig/ts-zigar/wit/typescript.wit'))).to.equal(true);
    expect(existsSync(join(pkgDest, 'zig/ts-zigar/component/build-component.mjs'))).to.equal(true);
    expect(existsSync(join(pkgDest, 'zig/ts-zigar/component/adapter/cmd/zigar-ts-component/main.go'))).to.equal(true);
    expect(existsSync(join(pkgDest, 'zig/ts-zigar/component/adapter/extractor/extractor.go'))).to.equal(true);
    expect(existsSync(join(pkgDest, 'zig/ts-zigar/component/adapter/compiler/program.go'))).to.equal(true);

    // Ensure postpack cleaned up temporary staged directories in the source repo
    expect(existsSync(join(REPO_ROOT, 'zigar-compiler/zig/ts-zigar'))).to.equal(false);
    expect(existsSync(join(REPO_ROOT, 'zigar-compiler/zig/wit-zigar'))).to.equal(false);

    // Write a standalone .d.ts in `installRoot` and run packed `bin/ts2zig.js`
    const standaloneDts = join(installRoot, 'hello.d.ts');
    await writeFile(standaloneDts, 'export declare function greet(name: string): string;\n', 'utf-8');

    const componentFallbackCandidates = [
      process.env.TS_ZIGAR_COMPONENT_PATH,
      process.env.TS_ZIGAR_COMPONENT_WASM,
      join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm'),
      join(REPO_ROOT, '.cache/ts-zigar/typescript-compiler.component.wasm'),
      resolve(REPO_ROOT, '../.cache/ts-zigar/typescript-compiler.component.wasm'),
    ].filter(Boolean);
    const existingComponent = componentFallbackCandidates.find((p) => existsSync(p));

    const packedRes = await execFileAsync(
      process.execPath,
      [ join(pkgDest, 'bin/ts2zig.js'), '-t', standaloneDts, '-d', outPacked ],
      {
        cwd: installRoot,
        env: {
          ...process.env,
          ZIGAR_CACHE_DIR: isolatedCache,
          ...(existingComponent && !existsSync(join(pkgDest, 'zig/ts-zigar/component/dist/typescript-compiler.component.wasm'))
            ? { TS_ZIGAR_COMPONENT_PATH: existingComponent }
            : {}),
        },
      },
    );
    expect(existsSync(join(outPacked, 'root.zig'))).to.equal(true, packedRes.stderr);
    expect(existsSync(join(pkgDest, 'zig/.cache'))).to.equal(false);
    await execFileAsync('zig', [ 'ast-check', join(outPacked, 'root.zig') ], {
      cwd: installRoot,
      env: process.env,
    });

    // Verify content-addressed component cache isolation across in-place package upgrades without TS_ZIGAR_COMPONENT_PATH
    expect(Boolean(existingComponent)).to.equal(true, 'expected built typescript-compiler.component.wasm for upgrade test');
    const upgradeRoot = join(TEST_ROOT, 'upgrade-consumer');
    const upgradePkg = join(upgradeRoot, 'node_modules/zigar-compiler');
    const upgradeCache = join(TEST_ROOT, 'upgrade-shared-cache');
    const buildLogPath = join(TEST_ROOT, 'component-build-invocations.jsonl');
    mkdirSync(upgradePkg, { recursive: true });
    mkdirSync(upgradeCache, { recursive: true });

    await execFileAsync('tar', [ '-xzf', tgzPath, '--strip-components=1', '-C', upgradePkg ], {
      cwd: upgradeRoot,
      env: process.env,
    });
    rmSync(join(upgradePkg, 'zig/ts-zigar/component/dist'), { recursive: true, force: true });

    await writeFile(
      join(upgradePkg, 'zig/ts-zigar/component/build-component.mjs'),
      [
        'import { appendFileSync, copyFileSync, mkdirSync } from "node:fs";',
        'import { dirname } from "node:path";',
        'const args = process.argv.slice(2);',
        'const outIdx = args.indexOf("-o");',
        'const targetOut = outIdx >= 0 ? args[outIdx + 1] : "";',
        'mkdirSync(dirname(targetOut), { recursive: true });',
        `copyFileSync(${JSON.stringify(existingComponent)}, targetOut);`,
        `appendFileSync(${JSON.stringify(buildLogPath)}, JSON.stringify({ targetOut, cacheDir: process.env.TS_ZIGAR_CACHE_DIR }) + "\\n");`,
      ].join('\n'),
      'utf-8',
    );

    const cleanUpgradeEnv = { ...process.env, ZIGAR_CACHE_DIR: upgradeCache };
    delete cleanUpgradeEnv.TS_ZIGAR_COMPONENT_PATH;
    delete cleanUpgradeEnv.TS_ZIGAR_COMPONENT_WASM;
    delete cleanUpgradeEnv.TS_ZIGAR_CACHE_DIR;

    // Run 1 (v1 cold): builds into content-addressed directory under ZIGAR_CACHE_DIR
    const outV1a = join(TEST_ROOT, 'out-upgrade-v1a');
    await execFileAsync(process.execPath, [ join(upgradePkg, 'bin/ts2zig.js'), '-t', standaloneDts, '-d', outV1a ], {
      cwd: upgradeRoot,
      env: cleanUpgradeEnv,
    });
    let invocations = (await readFile(buildLogPath, 'utf-8')).trim().split('\n').map((l) => JSON.parse(l));
    expect(invocations).to.have.lengthOf(1);
    expect(invocations[0].targetOut.startsWith(join(upgradeCache, 'ts-zigar-component-'))).to.equal(true);
    expect(invocations[0].targetOut.includes('node_modules')).to.equal(false);
    expect(invocations[0].cacheDir).to.equal(join(upgradeCache, 'ts-zigar'));

    // Run 2 (v1 warm): hits cached component without invoking build-component.mjs
    const outV1b = join(TEST_ROOT, 'out-upgrade-v1b');
    await execFileAsync(process.execPath, [ join(upgradePkg, 'bin/ts2zig.js'), '-t', standaloneDts, '-d', outV1b ], {
      cwd: upgradeRoot,
      env: cleanUpgradeEnv,
    });
    invocations = (await readFile(buildLogPath, 'utf-8')).trim().split('\n').map((l) => JSON.parse(l));
    expect(invocations).to.have.lengthOf(1);

    // Corrupt v1 cached component & simulate in-place `npm update zigar-compiler` changing Go adapter source
    await writeFile(invocations[0].targetOut, 'corrupted-stale-v1-wasm', 'utf-8');
    const extractorGoPath = join(upgradePkg, 'zig/ts-zigar/component/adapter/extractor/extractor.go');
    await writeFile(extractorGoPath, (await readFile(extractorGoPath, 'utf-8')) + '\n// v2 adapter change\n', 'utf-8');

    // Run 3 (v2 after upgrade): must NOT load stale v1 component; builds under a new content hash
    const outV2 = join(TEST_ROOT, 'out-upgrade-v2');
    await execFileAsync(process.execPath, [ join(upgradePkg, 'bin/ts2zig.js'), '-t', standaloneDts, '-d', outV2 ], {
      cwd: upgradeRoot,
      env: cleanUpgradeEnv,
    });
    invocations = (await readFile(buildLogPath, 'utf-8')).trim().split('\n').map((l) => JSON.parse(l));
    expect(invocations).to.have.lengthOf(2);
    expect(invocations[1].targetOut).to.not.equal(invocations[0].targetOut);
    expect(existsSync(join(upgradePkg, 'zig/.cache'))).to.equal(false);
    await execFileAsync('zig', [ 'ast-check', join(outV2, 'root.zig') ], {
      cwd: upgradeRoot,
      env: process.env,
    });
  });
});
