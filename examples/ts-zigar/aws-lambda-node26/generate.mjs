#!/usr/bin/env node
/**
 * Reproducible `@types/aws-lambda` + `@types/node@26` -> Zig 0.17 binding generator (`zigar ts`)
 * for AWS Lambda `nodejs26.x` (Amazon Linux 2023) & AWS Elastic Beanstalk Node.js 26.
 */

import { execFile, execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import {
  computeGeneratorFingerprint,
  ensureIsolatedCacheEnv,
  ensureWorkspaceLinks,
  isNativeBinFresh,
  REPO_ROOT,
  resolveComponentWasm,
} from '../node/generate.mjs';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export const LAMBDA_PKG_DIR = __dirname;
export const GENERATED_DIR = join(LAMBDA_PKG_DIR, 'generated');
const STAMP_PATH = join(GENERATED_DIR, '.stamp.json');

export function resolveOrInstallAwsLambdaTypes() {
  const { cacheRoot, npmCache } = ensureIsolatedCacheEnv('aws-lambda-node26');
  const nmCandidates = [
    process.env.TS_ZIGAR_TYPES_AWS_LAMBDA_NM,
    process.env.TS_ZIGAR_CACHE_DIR && join(process.env.TS_ZIGAR_CACHE_DIR, 'types-aws-lambda/node_modules'),
    join(LAMBDA_PKG_DIR, 'node_modules'),
    join(cacheRoot, 'ts-zigar/types-aws-lambda/node_modules'),
    resolve(REPO_ROOT, '../.cache/ts-zigar/types-aws-lambda/node_modules'),
  ].filter(Boolean);

  for (const nm of nmCandidates) {
    const lambdaDir = join(nm, '@types/aws-lambda');
    const nodeDir = join(nm, '@types/node');
    if (existsSync(join(lambdaDir, 'package.json')) && existsSync(join(nodeDir, 'package.json'))) {
      return {
        typesAwsLambdaDir: resolve(lambdaDir),
        typesNodeDir: resolve(nodeDir),
      };
    }
  }

  execFileSync('npm', [ 'install', '--no-audit', '--no-fund', '--cache', npmCache ], {
    cwd: LAMBDA_PKG_DIR,
    env: process.env,
    stdio: 'inherit',
  });

  const lambdaDir = join(LAMBDA_PKG_DIR, 'node_modules/@types/aws-lambda');
  const nodeDir = join(LAMBDA_PKG_DIR, 'node_modules/@types/node');
  if (!existsSync(join(lambdaDir, 'package.json')) || !existsSync(join(nodeDir, 'package.json'))) {
    throw new Error('Failed to locate or install @types/aws-lambda and @types/node@26');
  }
  return { typesAwsLambdaDir: lambdaDir, typesNodeDir: nodeDir };
}

export async function ensureLambdaBindings({ force = false, quiet = false } = {}) {
  const { buildDir } = ensureIsolatedCacheEnv('aws-lambda-node26');
  ensureWorkspaceLinks();

  const { typesAwsLambdaDir, typesNodeDir } = resolveOrInstallAwsLambdaTypes();
  const lambdaPkg = JSON.parse(readFileSync(join(typesAwsLambdaDir, 'package.json'), 'utf8'));
  const nodePkg = JSON.parse(readFileSync(join(typesNodeDir, 'package.json'), 'utf8'));
  const typesAwsLambdaVersion = lambdaPkg.version || 'unknown';
  const typesNodeVersion = nodePkg.version || 'unknown';
  const generatorHash = computeGeneratorFingerprint();

  const cliArgs = [
    '-t', typesAwsLambdaDir,
    '-t', typesNodeDir,
    '-s', 'node:=',
    '-d', GENERATED_DIR,
  ];

  if (
    !force
    && existsSync(STAMP_PATH)
    && existsSync(join(GENERATED_DIR, 'root.zig'))
    && existsSync(join(GENERATED_DIR, 'aws_lambda/handler.zig'))
    && existsSync(join(GENERATED_DIR, 'aws_lambda/trigger/api_gateway_proxy.zig'))
    && existsSync(join(GENERATED_DIR, 'crypto.zig'))
  ) {
    try {
      const saved = JSON.parse(readFileSync(STAMP_PATH, 'utf8'));
      if (
        saved.typesAwsLambdaVersion === typesAwsLambdaVersion
        && saved.typesNodeVersion === typesNodeVersion
        && saved.stripSpec === 'node:='
        && saved.generatorHash === generatorHash
      ) {
        return {
          generatedDir: GENERATED_DIR,
          typesAwsLambdaVersion,
          typesNodeVersion,
          cached: true,
        };
      }
    } catch {}
  }

  rmSync(GENERATED_DIR, { recursive: true, force: true });
  mkdirSync(GENERATED_DIR, { recursive: true });

  const nativeBin = join(REPO_ROOT, 'ts-zigar/zig-out/bin/ts-zigar');
  const componentWasm = resolveComponentWasm();

  if (isNativeBinFresh(nativeBin) && componentWasm) {
    await execFileAsync(nativeBin, [ '--component', componentWasm, ...cliArgs ], {
      cwd: REPO_ROOT,
      env: process.env,
    });
  } else {
    const { runTs } = await import('../../../zigar-compiler/src/index.js');
    const res = await runTs(cliArgs, { silent: quiet, buildDir });
    const code = typeof res === 'object' && res !== null ? res.code : res;
    if (code !== 0) {
      throw new Error(`zigar ts exited with code ${code}: ${res?.stderr || ''}`);
    }
  }

  writeFileSync(
    STAMP_PATH,
    JSON.stringify(
      { typesAwsLambdaVersion, typesNodeVersion, stripSpec: 'node:=', generatorHash },
      null,
      2,
    ) + '\n',
    'utf8',
  );

  if (!quiet) {
    console.log(
      `Generated @types/aws-lambda@${typesAwsLambdaVersion} + @types/node@${typesNodeVersion} Zig bindings in ${GENERATED_DIR}`,
    );
  }
  return {
    generatedDir: GENERATED_DIR,
    typesAwsLambdaVersion,
    typesNodeVersion,
    cached: false,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
  const force = process.argv.includes('--force');
  const quiet = process.argv.includes('--quiet');
  await ensureLambdaBindings({ force, quiet });
}
