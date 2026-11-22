import { realpathSync } from 'node:fs';
import { dirname, join, posix, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import zigar from 'rollup-plugin-zigar';
import { defineConfig } from 'vite';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '../../..');
const cacheRoot = join(repoRoot, '.cache/examples/monaco-editor-hello-world');
const monacoPkgRoot = resolve(dirname(realpathSync(fileURLToPath(import.meta.resolve('monaco-editor')))), '../..');

const WORKER_SPECS = {
  'editor.worker': 'monaco-editor/editor/editor.worker.js',
  'ts.worker': 'monaco-editor/language/typescript/ts.worker.js',
};

const workerPaths = Object.fromEntries(
  Object.entries(WORKER_SPECS).map(([ name, spec ]) => [
    name,
    realpathSync(fileURLToPath(import.meta.resolve(spec))),
  ]),
);

const allowedFsRoots = Array.from(new Set([
  __dirname,
  realpathSync(__dirname),
  resolve(__dirname, '../monaco-editor'),
  realpathSync(resolve(__dirname, '../monaco-editor')),
  realpathSync(join(repoRoot, 'zigar-runtime')),
  realpathSync(join(repoRoot, 'zigar-compiler')),
  cacheRoot,
  monacoPkgRoot,
  ...Object.values(workerPaths).map((workerFile) => dirname(workerFile)),
]));

function monacoWorkerDevPlugin() {
  return {
    name: 'monaco-worker-dev-routes',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const cleanUrl = (req.url || '').split('?')[0];
        const match = /^\/([a-z]+\.worker)\.js$/.exec(cleanUrl);
        if (match && workerPaths[match[1]]) {
          const fsUrl = posix.join('/@fs', workerPaths[match[1]].replace(/\\/g, '/'));
          res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
          res.end(`import ${JSON.stringify(fsUrl)};\n`);
          return;
        }
        next();
      });
    },
  };
}

export default defineConfig({
  root: __dirname,
  base: './',
  cacheDir: join(cacheRoot, 'vite-cache'),
  plugins: [
    monacoWorkerDevPlugin(),
    zigar({
      optimize: 'ReleaseSmall',
      topLevelAwait: true,
      stripWASM: true,
      buildDir: join(cacheRoot, 'rollup-build'),
      cacheDir: join(cacheRoot, 'rollup-cache'),
    }),
  ],
  optimizeDeps: {
    exclude: [ 'monaco-editor' ],
  },
  server: {
    fs: {
      allow: allowedFsRoots,
    },
  },
  worker: {
    format: 'es',
    rollupOptions: {
      output: {
        entryFileNames: '[name].js',
        chunkFileNames: 'assets/[name]-[hash].js',
      },
    },
  },
  build: {
    target: 'es2022',
    outDir: join(__dirname, 'dist'),
    emptyOutDir: true,
    assetsInlineLimit: 0,
    rollupOptions: {
      input: {
        index: resolve(__dirname, 'index.html'),
        'editor.worker': workerPaths['editor.worker'],
      },
      output: {
        entryFileNames: (chunkInfo) =>
          chunkInfo.name.endsWith('.worker') ? '[name].js' : 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
});
