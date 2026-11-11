import { expect } from 'chai';
import { readFile } from 'fs/promises';
import 'mocha-skip-if';
import { fileURLToPath } from 'url';
import { defineEnvironment } from '../../src/environment.js';
import '../../src/mixins.js';
import { usize } from '../../src/utils.js';

const Env = defineEnvironment();

if (process.env.TARGET === 'wasm') {
  describe('Feature: thunk-allocation', function() {
    describe('addJsThunkSource', function() {
      it('should add a new instance of the WebAssembly module', async function() {
        const wasmPath = absolute('./wasm-samples/fn-pointer.wasm');
        const binary = await readFile(wasmPath);
        const env = new Env();
        await env.loadModule(binary, {
          memoryInitial: 1024,
          tableInitial: 100,
          multithreaded: false,
        });
        const source = env.addJsThunkSource();
        expect(source.createJsThunk).to.be.a('function');
        expect(source.destroyJsThunk).to.be.a('function');
      })
    })
    describe('allocateJsThunk', function() {
      it('should allocate a JavaScript thunk', async function() {
        const wasmPath = absolute('./wasm-samples/fn-pointer.wasm');
        const binary = await readFile(wasmPath);
        const env = new Env();
        await env.loadModule(binary, {
          tableInitial: 100,
          multithreaded: false,
        });
        env.acquireStructures();
        const { Fn } = env.useStructures();
        let thunkControllerAddress;
        let fnId;
        env.createJsThunk = function(address, id) {
          thunkControllerAddress = address;
          fnId = id;
          return usize(100);
        };
        new Fn(() => {});
        const thunkAddress1 = env.allocateJsThunk(thunkControllerAddress, fnId);
        expect(thunkAddress1).to.equal(100);
        const thunkAddress2 = env.allocateJsThunk(thunkControllerAddress, fnId + 1);
        expect(thunkAddress2).to.be.above(100);
      })
    })
    describe('freeJsThunk', function() {
      it('should free a JavaScript thunk', async function() {
        const wasmPath = absolute('./wasm-samples/fn-pointer.wasm');
        const binary = await readFile(wasmPath);
        const env = new Env();
        await env.loadModule(binary, {
          tableInitial: 100,
          multithreaded: false,
        });
        env.acquireStructures();
        const { Fn } = env.useStructures();
        let thunkControllerAddress;
        let fnId;
        env.createJsThunk = function(address, id) {
          thunkControllerAddress = address;
          fnId = id;
          return usize(100);
        };
        new Fn(() => {});
        const thunkAddress1 = env.allocateJsThunk(thunkControllerAddress, fnId);
        const thunkAddress2 = env.allocateJsThunk(thunkControllerAddress, fnId + 1);
        const freedFnId1 = env.freeJsThunk(thunkControllerAddress, thunkAddress1);
        const freedFnId2 = env.freeJsThunk(thunkControllerAddress, thunkAddress2);
        expect(freedFnId1).to.equal(fnId);
        expect(freedFnId2).to.equal(fnId + 1);
      })
    })
    describe('findJsThunk', function() {
      it('should find the id of a thunk by address', async function() {
        const wasmPath = absolute('./wasm-samples/fn-pointer.wasm');
        const binary = await readFile(wasmPath);
        const env = new Env();
        await env.loadModule(binary, {
          tableInitial: 100,
          multithreaded: false,
        });
        env.acquireStructures();
        const { Fn } = env.useStructures();
        let thunkControllerAddress;
        let fnId;
        env.import
        env.createJsThunk = function(address, id) {
          thunkControllerAddress = address;
          fnId = id;
          return usize(100);
        };
        new Fn(() => {});
        const thunkAddress1 = env.allocateJsThunk(thunkControllerAddress, fnId);
        const thunkAddress2 = env.allocateJsThunk(thunkControllerAddress, fnId + 1);
        const foundFnId1 = env.findJsThunk(thunkControllerAddress, thunkAddress1);
        const foundFnId2 = env.findJsThunk(thunkControllerAddress, thunkAddress2);
        expect(foundFnId1).to.equal(fnId);
        expect(foundFnId2).to.equal(fnId + 1);
      })
    })
    describe('memory64 + table64 thunk allocation', function() {
      it('should allocate, grow, identify, and free JS thunks in a 64-bit WebAssembly.Table', async function() {
        const str = (s) => [ s.length, ...Buffer.from(s) ];
        const section = (id, payload) => [ id, payload.length, ...payload ];
        const types = [
          0x03,
          0x60, 0x00, 0x00,                   // 0: () -> ()
          0x60, 0x02, 0x7e, 0x7e, 0x01, 0x7e, // 1: (i64, i64) -> i64
          0x60, 0x00, 0x01, 0x7e,             // 2: () -> i64
        ];
        const imports = [
          0x02,
          ...str('env'), ...str('memory'), 0x02, 0x05, 0x01, 0x02,
          ...str('env'), ...str('__indirect_function_table'), 0x01, 0x70, 0x04, 0x04,
        ];
        const funcs = [ 0x06, 0x00, 0x01, 0x01, 0x01, 0x02, 0x02 ];
        const globals = [
          0x02,
          0x7e, 0x01, 0x42, 0x00, 0x0b, // slot 0 fnId
          0x7e, 0x01, 0x42, 0x00, 0x0b, // slot 1 fnId
        ];
        const exports = [
          0x04,
          ...str('initialize'), 0x00, 0x00,
          ...str('createJsThunk'), 0x00, 0x01,
          ...str('destroyJsThunk'), 0x00, 0x02,
          ...str('identifyJsThunk'), 0x00, 0x03,
        ];
        const elems = [
          0x01,
          0x00, 0x42, 0x02, 0x0b, 0x02, 0x04, 0x05,
        ];
        const bInit = [ 0x00, 0x0b ];
        const bCreate = [
          0x00,
          0x23, 0x00, 0x50, 0x04, 0x40,
          0x20, 0x01, 0x24, 0x00, 0x42, 0x02, 0x0f,
          0x0b,
          0x23, 0x01, 0x50, 0x04, 0x40,
          0x20, 0x01, 0x24, 0x01, 0x42, 0x03, 0x0f,
          0x0b,
          0x42, 0x00, 0x0b,
        ];
        const bDestroy = [
          0x01, 0x01, 0x7e,
          0x20, 0x01, 0x42, 0x02, 0x51, 0x04, 0x40,
          0x23, 0x00, 0x21, 0x02, 0x42, 0x00, 0x24, 0x00, 0x20, 0x02, 0x0f,
          0x0b,
          0x20, 0x01, 0x42, 0x03, 0x51, 0x04, 0x40,
          0x23, 0x01, 0x21, 0x02, 0x42, 0x00, 0x24, 0x01, 0x20, 0x02, 0x0f,
          0x0b,
          0x42, 0x00, 0x0b,
        ];
        const bIdent = [
          0x00,
          0x20, 0x01, 0x42, 0x02, 0x51, 0x04, 0x40, 0x23, 0x00, 0x0f, 0x0b,
          0x20, 0x01, 0x42, 0x03, 0x51, 0x04, 0x40, 0x23, 0x01, 0x0f, 0x0b,
          0x42, 0x00, 0x0b,
        ];
        const bThunk0 = [ 0x00, 0x23, 0x00, 0x0b ];
        const bThunk1 = [ 0x00, 0x23, 0x01, 0x0b ];
        const code = [
          0x06,
          bInit.length, ...bInit,
          bCreate.length, ...bCreate,
          bDestroy.length, ...bDestroy,
          bIdent.length, ...bIdent,
          bThunk0.length, ...bThunk0,
          bThunk1.length, ...bThunk1,
        ];
        const wasmThunk64 = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          ...section(1, types),
          ...section(2, imports),
          ...section(3, funcs),
          ...section(6, globals),
          ...section(7, exports),
          ...section(9, elems),
          ...section(10, code),
        ]);

        const env = new Env();
        await env.loadModule(wasmThunk64, {
          memoryInitial: 1,
          memoryMax: 2,
          tableInitial: 4,
          memory64: true,
          table64: true,
          multithreaded: false,
        });
        expect(env.memory64).to.be.true;
        expect(env.table64).to.be.true;
        expect(env.table.length).to.equal(4n);

        const ctrl = 0x1000n;
        const addr1 = env.allocateJsThunk(ctrl, 101);
        const addr2 = env.allocateJsThunk(ctrl, 102);
        // 3rd thunk exhausts first source (2 slots) -> spawns 2nd source!
        const addr3 = env.allocateJsThunk(ctrl, 103);
        expect(typeof addr1).to.equal('bigint');
        expect(typeof addr2).to.equal('bigint');
        expect(typeof addr3).to.equal('bigint');
        expect(env.table.length).to.equal(12n);
        expect(env.thunkSources).to.have.lengthOf(2);

        expect(env.table.get(addr1)()).to.equal(101n);
        expect(env.table.get(addr2)()).to.equal(102n);
        expect(env.table.get(addr3)()).to.equal(103n);

        expect(env.findJsThunk(ctrl, addr1)).to.equal(101);
        expect(env.freeJsThunk(ctrl, addr2)).to.equal(102);
        expect(env.freeJsThunk(ctrl, addr3)).to.equal(103);
        expect(env.thunkSources).to.have.lengthOf(1);
      })
    })
  })
}

function absolute(relpath) {
  return fileURLToPath(new URL(relpath, import.meta.url));
}
