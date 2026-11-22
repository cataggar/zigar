import nodeResolve from '@rollup/plugin-node-resolve';
import { isBuiltin } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import zigar from 'rollup-plugin-zigar';

const __dirname = dirname(fileURLToPath(import.meta.url));

export default {
  input: join(__dirname, 'src/index.mjs'),
  external: (id) => isBuiltin(id),
  output: {
    file: join(__dirname, 'dist/lambda.mjs'),
    format: 'esm',
  },
  plugins: [
    zigar({
      optimize: 'ReleaseSmall',
      useJSPI: true,
      nodeCompat: true,
      embedWASM: false,
      topLevelAwait: true,
      stripWASM: true,
      buildDir: join(__dirname, '.cache/rollup-build'),
      cacheDir: join(__dirname, '.cache/rollup-cache'),
    }),
    nodeResolve(),
  ],
};
