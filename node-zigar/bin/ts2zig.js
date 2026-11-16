#!/usr/bin/env node

const zigarCompiler = await import('zigar-compiler').catch(
  () => import(new URL('../../zigar-compiler/dist/index.js', import.meta.url))
);

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
