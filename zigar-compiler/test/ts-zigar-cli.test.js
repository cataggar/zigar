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
});
