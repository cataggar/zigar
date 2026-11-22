import nodeResolve from '@rollup/plugin-node-resolve';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import zigar from 'rollup-plugin-zigar';

const __dirname = dirname(fileURLToPath(import.meta.url));

export default {
  input: join(__dirname, 'src/index.mjs'),
  external: [ /^monaco-editor(\/|$)/ ],
  output: {
    file: join(__dirname, 'dist/showcase.mjs'),
    format: 'esm',
  },
  plugins: [
    zigar({
      optimize: 'ReleaseSmall',
      embedWASM: true,
      topLevelAwait: true,
      stripWASM: true,
      buildDir: join(__dirname, '.cache/rollup-build'),
      cacheDir: join(__dirname, '.cache/rollup-cache'),
    }),
    nodeResolve(),
  ],
};
