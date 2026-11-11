import { expect, use } from 'chai';
import chaiAsPromised from 'chai-as-promised';
import { mkdirSync, rmSync } from 'fs';
import { writeFile } from 'fs/promises';
import { dirname, join, parse, resolve } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

use(chaiAsPromised);

import { transpile } from '../src/transpilation.js';

describe('Transpilation', function() {
  this.timeout(0);
  const getSamplePath = (name) => {
    const url = new URL(`./zig-samples/basic/${name}.zig`, import.meta.url);
    return fileURLToPath(url);
  };
  const saveWASM = async (path, data) => {
    const { name } = parse(path);
    const url = new URL(`./wasm-samples/${name}.wasm`, import.meta.url);
    const wasmPath = fileURLToPath(url);
    await writeFile(wasmPath, data);
    return `readFile("${name}.wasm")`;
  };
  describe('transpile', function() {
    it('should transpile zig source code containing no methods', async function() {
      const path = getSamplePath('integers');
      const options = { optimize: 'Debug' };
      const { code } = await transpile(path, options);
      expect(code).to.be.a('string');
      expect(code).to.contain('integers');
    })
    it('should transpile zig source code containing a method', async function() {
      const path = getSamplePath('simple');
      const options = {
        optimize: 'ReleaseSmall',
        embedWASM: false,
        wasmLoader: saveWASM,
      };
      const { code } = await transpile(path, options);
      expect(code).to.be.a('string');
      expect(code).to.contain('"add"');
    })
    it('should transpile zig source code accessing the file system', async function() {
      const path = getSamplePath('read-file');
      const options = {
        optimize: 'ReleaseSmall',
        embedWASM: false,
        wasmLoader: saveWASM,
      };
      const { code } = await transpile(path, options);
      expect(code).to.contain('"readFile"');
    })
    it('should strip out unnecessary code when stripWASM is specified', async function() {
      const path = getSamplePath('simple');
      const options1 = { optimize: 'Debug' };
      const options2 = { optimize: 'Debug', stripWASM: true };
      const { code: before } = await transpile(path, options1);
      const { code: after } = await transpile(path, options2);
      expect(after.length).to.be.below(before.length);
    })
    it('should default to strip WASM when optimize is not Debug', async function() {
      const path = getSamplePath('simple');
      const options1 = { optimize: 'ReleaseSmall', stripWASM: false };
      const options2 = { optimize: 'ReleaseSmall' };
      const { code: before } = await transpile(path, options1);
      const { code: after } = await transpile(path, options2);
      expect(after.length).to.be.below(before.length);
    })
    it('should call wasmLoader when embedWASM is false', async function() {
      const path = getSamplePath('simple');
      let srcPath, wasmDV;
      const wasmLoader = (path, dv) => {
        srcPath = path;
        wasmDV = dv;
        return `loadWASM()`;
      };
      const options = { optimize: 'Debug', embedWASM: false, wasmLoader };
      const { code } = await transpile(path, options);
      expect(srcPath).to.equal(path);
      expect(wasmDV).to.be.instanceOf(DataView);
      expect(code).to.contain(`loadWASM()`);
    })
    it('should throw when embedWASM is false and wasmLoader is not provided', async function() {
      const path = getSamplePath('integers');
      const options = { optimize: 'Debug', embedWASM: false };
      await expect(transpile(path, options)).to.eventually.be.rejected;
    })
    it('should transpile zig source code involving function pointer', async function() {
      const path = getSamplePath('fn-pointer');
      const options = {
        optimize: 'ReleaseSmall',
        stripWASM: false,
        embedWASM: false,
        wasmLoader: saveWASM,
      };
      const { code } = await transpile(path, options);
      expect(code).to.contain('"call"');
    })
    it('should transpile zig source code spawning thread', async function() {
      const path = getSamplePath('thread');
      const options = {
        optimize: 'ReleaseSmall',
        stripWASM: false,
        embedWASM: false,
        wasmLoader: saveWASM,
        multithreaded: true,
      };
      const { code } = await transpile(path, options);
      expect(code).to.contain('"spawn"');
    })
    it('should transpile zig source code involving atomic operations', async function() {
      const path = getSamplePath('atomic');
      const options = {
        optimize: 'ReleaseSmall',
        stripWASM: true,
        embedWASM: false,
        wasmLoader: saveWASM,
        multithreaded: true,
      };
      const { code } = await transpile(path, options);
      expect(code).to.contain('"wait"');
    })
    it('should create JS code compatible with Node.js', async function() {
      const path = getSamplePath('thread');
      const options = {
        optimize: 'ReleaseSmall',
        stripWASM: false,
        embedWASM: false,
        wasmLoader: saveWASM,
        multithreaded: true,
        nodeCompat: true,
      };
      const { code } = await transpile(path, options);
      expect(code).to.contain('"spawn"');
    })
    it('should transpile pure-Zig WASM module using wazig build-exe', async function() {
      const path = getSamplePath('console');
      const { code, sourcePaths } = await transpile(path, { optimize: 'ReleaseSmall', useWazig: true });
      expect(code).to.contain('"hello"');
      expect(sourcePaths.some(p => p.includes('console.zig'))).to.be.true;
    })
    it('should transpile WASM module with relative sibling import and C header using wazig', async function() {
      const printPath = fileURLToPath(new URL('./zig-samples/c-import/print.zig', import.meta.url));
      const { code: printCode, sourcePaths } = await transpile(printPath, { optimize: 'ReleaseSmall', useWazig: true });
      expect(printCode).to.contain('"printZig"');
      expect(printCode).to.contain('"printC"');
      expect(sourcePaths.some(p => p.includes('print.zig'))).to.be.true;
      expect(sourcePaths.some(p => p.includes('hello.zig'))).to.be.true;
      expect(sourcePaths.some(p => p.includes('build.extra.h'))).to.be.true;
      const cPtrPath = fileURLToPath(new URL('./integration/function-calling/return-c-pointer.zig', import.meta.url));
      const prevDev = process.env.DEV;
      delete process.env.DEV;
      try {
        const { code: cPtrCode } = await transpile(cPtrPath, { optimize: 'ReleaseSmall', useWazig: true });
        expect(cPtrCode).to.contain('"getString"');
        expect(cPtrCode).to.contain('"getPointer"');
      } finally {
        if (prevDev !== undefined) process.env.DEV = prevDev;
      }
    })
    it('should transpile WASM module with useLibc enabled using wazig', async function() {
      const dupePath = fileURLToPath(new URL('./zig-samples/c-allocator/dupe.zig', import.meta.url));
      const { code } = await transpile(dupePath, { optimize: 'ReleaseSmall', useLibc: true, useWazig: true });
      expect(code).to.contain('"dupe"');
    })
    it('should include useJSPI and continuationStackSize in moduleOptions when specified', async function() {
      const path = getSamplePath('simple');
      const options = {
        optimize: 'ReleaseSmall',
        embedWASM: false,
        wasmLoader: () => 'loadWASM()',
        useWazig: true,
        useJSPI: true,
        continuationStackSize: 131072,
      };
      const { code } = await transpile(path, options);
      expect(code).to.contain('"useJSPI":true');
      expect(code).to.contain('"continuationStackSize":131072');
      expect(code).to.contain('"syncFunctions":[');

      const { code: allCode } = await transpile(path, { ...options, useJSPI: 'all' });
      expect(allCode).to.contain('"useJSPI":"all"');
      expect(allCode).to.not.contain('"syncFunctions"');
    })
    it('should execute pure exports synchronously and callback exports across 16 concurrent JSPI fibers when useJSPI is true', async function() {
      if (typeof WebAssembly.Suspending !== 'function' || typeof WebAssembly.promising !== 'function') {
        this.skip();
      }
      const __dirname = dirname(fileURLToPath(import.meta.url));
      const servicePath = fileURLToPath(new URL('./zig-samples/wit-zigar/service.zig', import.meta.url));
      const runtimeSrcDir = resolve(__dirname, '../../zigar-runtime/src');
      const tmpBase = process.env.TMPDIR || resolve(__dirname, '../../.cache/tmp');
      const outDir = join(tmpBase, `transpile-selective-jspi-${process.pid}`);
      mkdirSync(outDir, { recursive: true });
      let serviceMod, listMod;
      try {
        const loadTranspiled = async (useJSPI, tag) => {
          const { code } = await transpile(servicePath, {
            optimize: 'ReleaseSmall',
            embedWASM: true,
            stripWASM: true,
            useWazig: true,
            useJSPI,
            continuationStackSize: 8192,
            buildDir: join(outDir, `build-${tag}`),
          });
          const resolvedCode = code
            .replace(
              /from\s+["']zigar-runtime["']/g,
              `from ${JSON.stringify(pathToFileURL(join(runtimeSrcDir, 'index.js')).href)}`,
            )
            .replace(
              /import\s+["']zigar-runtime\/([^"']+)["']/g,
              (_, subPath) => `import ${JSON.stringify(pathToFileURL(join(runtimeSrcDir, subPath)).href)}`,
            );
          const mjsPath = join(outDir, `service-${tag}-${Date.now()}.mjs`);
          await writeFile(mjsPath, resolvedCode, 'utf8');
          return import(pathToFileURL(mjsPath).href);
        };

        serviceMod = await loadTranspiled(true, 'auto');
        // Pure Zig exports return synchronously (NOT instanceof Promise), while `await` still works
        const syncMagic = serviceMod.getZigarAbiMagic();
        expect(syncMagic).to.not.be.an.instanceOf(Promise);
        expect(syncMagic).to.equal(0x5241475a);

        const syncRect = serviceMod.transformRect(
          { origin: { x: 2, y: 3 }, size: { x: 4, y: 5 } },
          1,
          -1,
          2,
        );
        expect(syncRect).to.not.be.an.instanceOf(Promise);
        expect(syncRect.origin.x).to.equal(3);
        expect(syncRect.origin.y).to.equal(2);
        expect(syncRect.size.x).to.equal(8);
        expect(syncRect.size.y).to.equal(10);

        const awaitedRect = await serviceMod.transformRect(
          { origin: { x: 2, y: 3 }, size: { x: 4, y: 5 } },
          1,
          -1,
          2,
        );
        expect(awaitedRect.origin.x).to.equal(3);

        // Callback/suspending export returns a Promise and suspends/resumes across 16 concurrent JSPI fibers
        serviceMod.resetConcurrencyStats();
        const hostCallback = async (taskSeq, delayMs) => {
          // Reentrantly call a synchronous Zig export while inside an active JSPI callback
          expect(serviceMod.getZigarAbiMagic()).to.equal(0x5241475a);
          await new Promise(r => setTimeout(r, delayMs));
          expect(serviceMod.getZigarAbiMagic()).to.equal(0x5241475a);
          return ((taskSeq & 0xff) << 16) | (taskSeq * 3);
        };
        const promises = Array.from({ length: 16 }, (_, idx) => {
          const delayMs = 5 + ((15 - idx) % 5) * 4;
          return serviceMod.asyncComputeWithHost(
            { origin: { x: idx, y: idx * 2 }, size: { x: 10, y: 20 } },
            delayMs,
            hostCallback,
          );
        });
        for (const p of promises) {
          expect(p).to.be.an.instanceOf(Promise);
        }
        const reports = await Promise.all(promises);
        expect(reports).to.have.lengthOf(16);
        const spSet = new Set(reports.map(r => r.sp_before));
        expect(spSet.size).to.equal(16);
        expect(serviceMod.getPeakConcurrent()).to.equal(16);

        // Explicit string[] mode: listed pure export returns Promise while unlisted pure export stays sync
        listMod = await loadTranspiled([ 'transformRect', 'asyncComputeWithHost' ], 'list');
        expect(listMod.getZigarAbiMagic()).to.equal(0x5241475a);
        const forcedAsyncRect = listMod.transformRect(
          { origin: { x: 1, y: 2 }, size: { x: 3, y: 4 } },
          0,
          0,
          1,
        );
        expect(forcedAsyncRect).to.be.an.instanceOf(Promise);
        expect((await forcedAsyncRect).size.y).to.equal(4);
      } finally {
        await serviceMod?.__zigar?.abandon();
        await listMod?.__zigar?.abandon();
        rmSync(outDir, { recursive: true, force: true });
      }
    })

  })
})
