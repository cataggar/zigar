#!/usr/bin/env node

import { runTs } from '../dist/index.js';

try {
  const { code } = await runTs(process.argv.slice(2));
  if (code) {
    process.exit(code);
  }
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
