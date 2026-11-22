#!/usr/bin/env node

let zigarCompiler;
try {
  zigarCompiler = require('zigar-compiler/cjs');
} catch {
  zigarCompiler = require('../../zigar-compiler/dist/index.cjs');
}

(async () => {
  try {
    if (typeof zigarCompiler.runTs !== 'function') {
      throw new Error('Installed zigar-compiler does not export runTs');
    }
    const { code } = await zigarCompiler.runTs(process.argv.slice(2));
    if (code) {
      process.exit(code);
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
})();
