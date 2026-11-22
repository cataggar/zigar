#!/usr/bin/env node

const { execSync } = require('child_process');
const { copyFile } = require('fs/promises');
const { join, resolve } = require('path');

let zigarCompiler;
try {
  zigarCompiler = require('zigar-compiler/cjs');
} catch {
  zigarCompiler = require('../../zigar-compiler/dist/index.cjs');
}
const { test } = zigarCompiler;

async function copyBuildFile() {
  const modPath = findZigarCompiler();
  const srcPath = join(modPath, '../../zig/build.zig');
  const dstPath = join(process.cwd(), 'build.zig');
  await copyFile(srcPath, dstPath);
}

async function copyBuildExtraFile() {
  const modPath = findZigarCompiler();
  const srcPath = join(modPath, 'zig/build.extra.zig');
  const dstPath = join(process.cwd(), 'build.extra.zig');
  await copyFile(srcPath, dstPath);
}

async function patchStandardLibrary() {
  try {
    const modPath = findZigarCompiler();
    const patchPath = join(modPath, 'wasi-thread.patch');
    const zigPath = resolve(findExecutable('zig'), '..');
    const libPath = join(zigPath, 'lib');
    const patchExePath = findExecutable('patch');
    const dryRunCmd = `patch -d "${libPath}" -t -p0 -N --dry-run < "${patchPath}"`;
    const dryRunResult = execSync(dryRunCmd).toString();
    const patchCmd = `patch -d ${JSON.stringify(libPath)} -t -p0 < ${JSON.stringify(patchPath)}`;
    const result = execSync(patchCmd).toString();
    console.log(result);
  } catch (err) {
    const dryRunError = err.stdout?.toString?.() ?? err.message;
    throw new Error(`Operation failed:\n\n${dryRunError}`);
  }
}

function findZigarCompiler() {
  const jsPath = require.resolve('zigar-compiler');
  return resolve(jsPath, '../..');
}

function findExecutable(cmd) {
  let path;
  try {
    if (process.platform === 'win32') {
      path = execSync(`where ${cmd}`).toString().trim();
    } else {
      [ path ] = execSync(`whereis ${cmd}`).toString().replace(/^\w+:\s*/, '').trim().split(/\s+/);
    }
  } catch {}
  if (!path) {
    throw new Error(`Executable not found: ${cmd}`);
  }
  return path;
}

async function runTests(args) {
  let srcPath, extraArgs = [];
  for (const arg of args) {
    if (!srcPath && !arg.startsWith('-')) {
      srcPath = resolve(process.cwd(), arg);
    } else {
      extraArgs.push(arg);
    }
  }  
  const { code } = await test(srcPath, { extraArgs });
  if (code) {
    process.exit(code);
  }
}

async function runWitCommand(args) {
  if (typeof zigarCompiler.runWit !== 'function') {
    throw new Error('Installed zigar-compiler does not export runWit');
  }
  const { code } = await zigarCompiler.runWit(args);
  if (code) {
    process.exit(code);
  }
}

async function runTsCommand(args) {
  if (typeof zigarCompiler.runTs !== 'function') {
    throw new Error('Installed zigar-compiler does not export runTs');
  }
  const { code } = await zigarCompiler.runTs(args);
  if (code) {
    process.exit(code);
  }
}

function printHelp() {
  const lines = [
    'Usage: npx zigar-loader [command]',
    '',
    'Commands:',
    '',
    '  custom        Create a copy of Zigar\'s build.zig in the current folder',
    '  extra         Create a barebone build.extra.zig in the current folder',
    '  patch         Patch Zig\'s standard library to enable thread support',
    '  test <path>   Run a Zig module\'s unit tests',
    '  wit [args]    Generate Zig bindings from WIT or inspect zigar:abi sections',
    '  ts [args]     Generate Zig bindings from TypeScript declarations',
    '',
    '  help          Show this message',
    '',
  ];
  for (const line of lines) {
    console.log(line);
  }
}

(async () => {
  try {
    const cmd = process.argv[2];
    switch (cmd) {
      case 'custom':
        await copyBuildFile();
        break;
      case 'extra':
        await copyBuildExtraFile();
        break;
      case 'patch':
        await patchStandardLibrary();
        break;
      case 'test':
        await runTests(process.argv.slice(3));
        break;
      case 'wit':
        await runWitCommand(process.argv.slice(3));
        break;
      case 'ts':
        await runTsCommand(process.argv.slice(3));
        break;
      case 'help':
      case undefined:
        printHelp();
        break;
      default:
        throw new Error(`Unrecognized command: ${cmd}`);
    }
  } catch (err) {
    console.log(err.message);
    process.exit(1);
  }  
})();
