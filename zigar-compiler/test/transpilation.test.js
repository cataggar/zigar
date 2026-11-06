import { expect, use } from 'chai';
import chaiAsPromised from 'chai-as-promised';
import { parse } from 'path';
import { fileURLToPath } from 'url';

use(chaiAsPromised);

import { writeFile } from 'fs/promises';
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
    })

  })
})
