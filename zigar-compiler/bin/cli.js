#!/usr/bin/env node

import { copyFile } from 'fs/promises';
import { join, resolve } from 'path';
import { fileURLToPath } from 'url';
import { runWit, test } from '../dist/index.js';

async function copyBuildFile() {
  const modPath = findZigarCompiler();
  const srcPath = join(modPath, 'zig/build.zig');
  const dstPath = join(process.cwd(), 'build.zig');
  await copyFile(srcPath, dstPath);
}

async function copyBuildExtraFile() {
  const modPath = findZigarCompiler();
  const srcPath = join(modPath, 'zig/build.extra.zig');
  const dstPath = join(process.cwd(), 'build.extra.zig');
  await copyFile(srcPath, dstPath);
}

function findZigarCompiler() {
  return fileURLToPath(new URL('..', import.meta.url));
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
  const { code } = await runWit(args);
  if (code) {
    process.exit(code);
  }
}

function printHelp() {
  const lines = [
    'Usage: npx zigar [command]',
    '',
    'Commands:',
    '',
    '  custom        Create a copy of Zigar\'s build.zig in the current folder',
    '  extra         Create a barebone build.extra.zig in the current folder',
    '  test <path>   Run a Zig module\'s unit tests',
    '  wit [args]    Generate Zig bindings from WIT or inspect zigar:abi sections',
    '',
    '  help          Show this message',
    '',
  ];
  for (const line of lines) {
    console.log(line);
  }
}

try {
  const cmd = process.argv[2];
  switch (cmd) {
    case 'custom':
      await copyBuildFile();
      break;
    case 'extra':
      await copyBuildExtraFile();
      break;
    case 'test':
      await runTests(process.argv.slice(3));
      break;
    case 'wit':
      await runWitCommand(process.argv.slice(3));
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
