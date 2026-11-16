import NodeResolve from '@rollup/plugin-node-resolve';
import { expect } from 'chai';
import { readFile } from 'fs/promises';
import 'mocha-skip-if';
import { tmpdir } from 'os';
import { dirname, join, relative, resolve } from 'path';
import { rollup } from 'rollup';
import { fileURLToPath, pathToFileURL } from 'url';
import { createServer } from 'vite';
import Zigar from '../dist/index.js';

describe('Loader', function() {
  this.timeout(0);
  describe('Options', function() {
    const path = absolute('../../zigar-compiler/test/zig-samples/basic/console.zig');
    it('should generate code with embedded WASM by default', async function() {
      const code = await transpile(path, { embedWASM: true });
      expect(code).to.contain('atob');
    })
    it('should generate code that uses fetch when embedWASM is false', async function() {
      const code = await transpile(path, { embedWASM: false, nodeCompat: false });
      expect(code).to.contain('fetch');
    })
    it('should generate code that uses readFile when embedWASM is false and nodeCompat is true', async function() {
      const code = await transpile(path, { embedWASM: false, nodeCompat: true });
      expect(code).to.contain('readFile');
    })
    it('should fail when useReadFile is specified', async function() {
      let error;
      try {
        await transpile(path, { embedWASM: false, useReadFile: true });
      } catch (err) {
        error = err;
      }
      expect(error).to.be.an('Error');
    })
    it('should default to ReleaseSmall where NODE_ENV is production', async function() {
      const code1 = await transpile(path, { embedWASM: true });
      process.env.NODE_ENV = 'production';
      try {
        const code2 = await transpile(path, { embedWASM: true });
        expect(code2.length).to.be.below(code1.length);
      } finally {
        delete process.env.NODE_ENV;
      }
    })
    it('should fail when unknown options are present', async function() {
      let error;
      try {
        const code = await transpile(path, { turkey: true });
      } catch (err) {
        error = err;
      }
      expect(error).to.be.an('error').with.property('message').that.contains('turkey');
    })
    it('should fail when optimize option is incorrect', async function() {
      let error;
      try {
        const code = await transpile(path, { optimize: 'Donut' });
      } catch (err) {
        error = err;
      }
      expect(error).to.be.an('error').with.property('message').that.contains('ReleaseFast');
    })
    it('should serve transcoded files through Vite', async function() {
      const host = 'localhost';
      const port = 10001;
      const server = await createServer({
        root: absolute('./example'),
        server: { host, port, watch: null },
        plugins: [
          Zigar({}),
          NodeResolve({
            modulePaths: [ absolute(`../node_modules`) ],
          }),
        ],
        optimizeDeps: {
          include: [],
        },
      });
      await server.listen();
      const rootJsReq = await fetch(`http://${host}:${port}/test.js`);
      const rootJsText = await rootJsReq.text();
      const jsURI = /from "(.*?)"/.exec(rootJsText)?.[1];
      expect(jsURI).to.be.a('string');
      const jsReq = await fetch(`http://${host}:${port}${jsURI}`);
      const jsText = await jsReq.text();
      const wasmURI = /url = "(.*?\.wasm.*?)"/.exec(jsText)?.[1];
      expect(wasmURI).to.be.a('string');
      const wasmReq = await fetch(`http://${host}:${port}${wasmURI}`);
      const wasmBlob = await wasmReq.blob();
      expect(wasmBlob).to.be.a('blob');
      expect(wasmBlob.size).to.be.at.least(100000);
      server.close();
    })
  })

  describe('ES Module Imports & Comptime Tree-Shaking', function() {
    const treeshakeZig = absolute('../../zigar-compiler/test/zig-samples/js-value/module-imports/treeshake-app.zig');
    const parityZig = absolute('../../zigar-compiler/test/zig-samples/js-value/module-imports/module-parity.zig');

    it('should tree-shake 49 unreferenced js.Module declarations and emit only node:path in Rollup bundle', async function() {
      const outDir = join(tmpdir(), 'rollup-esmod-treeshake');
      const jsPath = join(outDir, 'treeshake-bundle.mjs');
      const bundle = await rollup({
        input: treeshakeZig,
        external: (id) => id.startsWith('node:'),
        plugins: [
          Zigar({ embedWASM: true, optimize: 'ReleaseSmall' }),
          NodeResolve({
            modulePaths: [ absolute(`../node_modules`) ],
          }),
        ],
      });
      try {
        await bundle.write({ file: jsPath, format: 'esm' });
      } finally {
        await bundle.close();
      }
      const code = await readFile(jsPath, 'utf-8');
      expect(code).to.match(/import\s+\*\s+as\s+\w+\s+from\s+['"]node:path['"]/);
      for (let i = 1; i <= 49; i++) {
        const pkg = `pkg-${String(i).padStart(2, '0')}`;
        expect(code).to.not.include(pkg);
      }
      expect(code).to.not.include('unused-mod');
      expect(code).to.not.include('unused-public-mod');
      expect(code).to.not.include('unused-2');

      const mod = await import(pathToFileURL(jsPath).href);
      expect(mod.joinPaths('alpha', 'beta').string).to.equal('alpha/beta');
      expect(Number(mod.activeHandles())).to.equal(0);
    })

    it('should statically bundle multi-export ESM and interoperate with CJS export = callable/class modules', async function() {
      const outDir = join(tmpdir(), 'rollup-esmod-parity');
      const jsPath = join(outDir, 'parity-bundle.mjs');
      const bundle = await rollup({
        input: parityZig,
        external: (id) => id.startsWith('node:'),
        plugins: [
          {
            name: 'external-cjs',
            resolveId(source, importer) {
              if (source.endsWith('.cjs') && importer) {
                let rel = relative(outDir, resolve(dirname(importer), source)).replace(/\\/g, '/');
                if (!rel.startsWith('.')) rel = './' + rel;
                return { id: rel, external: true };
              }
              return null;
            },
          },
          Zigar({ embedWASM: true, optimize: 'ReleaseSmall' }),
          NodeResolve({
            modulePaths: [ absolute(`../node_modules`) ],
          }),
        ],
      });
      try {
        await bundle.write({
          file: jsPath,
          format: 'esm',
        });
      } finally {
        await bundle.close();
      }
      const code = await readFile(jsPath, 'utf-8');
      // ./esm-helper.mjs is bundled inline into the Rollup output (not left as an external import)
      expect(code).to.not.match(/from\s+['"][^'"]*esm-helper\.mjs['"]/);
      expect(code).to.include('esm-default:');
      expect(code).to.not.include('unused-parity-mod');
      for (let i = 1; i <= 49; i++) {
        expect(code).to.not.include(`pkg-${String(i).padStart(2, '0')}`);
      }

      const mod = await import(pathToFileURL(jsPath).href);
      expect(mod.exerciseNodeBuiltins().string).to.equal(
        'item.zig|p/item.zig|https://example.org/docs/spec?v=2|file:',
      );
      expect(mod.exerciseLocalEsm('rollup').string).to.equal(
        'v17=v17|zig<->esm|esm-default:rollup|esm-default:handle',
      );
      expect(mod.exerciseLocalCjsExportEquals(4, 23).string).to.equal(
        '423|cjs-static-extra|cjs-static-extra:ok|708|cjs-ctor-tag|155',
      );
      expect(mod.exerciseNamespaceShadowMutation().string).to.equal(
        '1:100|set_err|1:100|del=false:has=true:def=100|only=77=77|del_only=true:has_only=false',
      );
      expect(mod.exerciseNamedCjs().string).to.equal(
        '1|2=2|42->43|del=true:has=false:def_has=false|restored=1',
      );
      expect(mod.exerciseFalsyEsm().string).to.equal(
        'z=0|b=false|null=true|undef=true|set_err=true:def=100:del=false',
      );
      expect(Number(mod.activeHandles())).to.equal(0);

      // Also verify Rollup multi-chunk code splitting with dynamicJsImports: true!
      const dynChunkDir = join(tmpdir(), 'rollup-esmod-dyn-chunks');
      const dynBundle = await rollup({
        input: parityZig,
        external: (id) => id.startsWith('node:'),
        plugins: [
          {
            name: 'external-cjs',
            resolveId(source, importer) {
              if (source.endsWith('.cjs') && importer) {
                let rel = relative(dynChunkDir, resolve(dirname(importer), source)).replace(/\\/g, '/');
                if (!rel.startsWith('.')) rel = './' + rel;
                return { id: rel, external: true };
              }
              return null;
            },
          },
          Zigar({ embedWASM: true, optimize: 'ReleaseSmall', dynamicJsImports: true }),
          NodeResolve({
            modulePaths: [ absolute(`../node_modules`) ],
          }),
        ],
      });
      try {
        await dynBundle.write({
          dir: dynChunkDir,
          entryFileNames: 'entry.mjs',
          format: 'esm',
        });
      } finally {
        await dynBundle.close();
      }
      const dynEntryMod = await import(pathToFileURL(join(dynChunkDir, 'entry.mjs')).href);
      expect(dynEntryMod.exerciseNamespaceShadowMutation().string).to.equal(
        '1:100|set_err|1:100|del=false:has=true:def=100|only=77=77|del_only=true:has_only=false',
      );
      expect(dynEntryMod.exerciseNamedCjs().string).to.equal(
        '1|2=2|42->43|del=true:has=false:def_has=false|restored=1',
      );
      expect(dynEntryMod.exerciseFalsyEsm().string).to.equal(
        'z=0|b=false|null=true|undef=true|set_err=true:def=100:del=false',
      );
      expect(Number(dynEntryMod.activeHandles())).to.equal(0);
    })
  })
})

async function transpile(path, options = {}) {
  const hash = await sha1(path);
  const jsPath = join(tmpdir(), 'rollup-test', `${hash}.mjs`);
  const inputOptions = {
    input: path,
    plugins: [
      Zigar(options),
      NodeResolve({
        modulePaths: [ absolute(`../node_modules`) ],
      }),
    ],
  };
  const outputOptions = {
    file: jsPath,
    format: 'esm',
  };
  const bundle = await rollup(inputOptions);
  try {
    await bundle.write(outputOptions);
  } finally {
    await bundle.close();
  }
  const code = await readFile(jsPath, 'utf-8');
  return code;
}

async function sha1(text) {
  const { createHash } = await import('crypto');
  const hash = createHash('sha1');
  hash.update(text);
  return hash.digest('hex');
}

function absolute(relPath) {
  return fileURLToPath(new URL(relPath, import.meta.url));
}
