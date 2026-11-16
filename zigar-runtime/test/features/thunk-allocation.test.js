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
    describe('multi-source reuse across distinct signatures and custom import namespaces', function() {
      it('should reuse spare thunkSources across multiple controllers (>16 thunks) and stub non-env imports', async function() {
        const str = (s) => [ s.length, ...Buffer.from(s) ];
        const uleb = (n) => {
          const out = [];
          do {
            let b = n & 0x7f;
            n >>>= 7;
            if (n !== 0) b |= 0x80;
            out.push(b);
          } while (n !== 0);
          return out;
        };
        const section = (id, payload) => [ id, ...uleb(payload.length), ...payload ];

        // Build a WASM32 module with:
        // - custom import namespace 'zigar:component-host'.'ping' () -> ()
        // - two controllers (ctrlA = 0x100, ctrlB = 0x200), each with 2 slots per instance!
        const types = [
          0x03,
          0x60, 0x00, 0x00,                   // 0: () -> ()
          0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // 1: (i32, i32) -> i32
          0x60, 0x00, 0x01, 0x7f,             // 2: () -> i32
        ];
        const imports = [
          0x03,
          ...str('env'), ...str('memory'), 0x02, 0x00, 0x01,
          ...str('env'), ...str('__indirect_function_table'), 0x01, 0x70, 0x00, 0x06,
          ...str('zigar:component-host'), ...str('ping'), 0x00, 0x00,
        ];
        // Imported func 0 = ping
        // Local funcs: 1=init, 2=createJsThunk, 3=destroyJsThunk, 4=identifyJsThunk, 5..8=thunks A0,A1,B0,B1
        const funcs = [ 0x08, 0x00, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02 ];
        const globals = [
          0x04,
          0x7f, 0x01, 0x41, 0x00, 0x0b, // global 0: A0
          0x7f, 0x01, 0x41, 0x00, 0x0b, // global 1: A1
          0x7f, 0x01, 0x41, 0x00, 0x0b, // global 2: B0
          0x7f, 0x01, 0x41, 0x00, 0x0b, // global 3: B1
        ];
        const exports = [
          0x04,
          ...str('initialize'), 0x00, 0x01,
          ...str('createJsThunk'), 0x00, 0x02,
          ...str('destroyJsThunk'), 0x00, 0x03,
          ...str('identifyJsThunk'), 0x00, 0x04,
        ];
        // Table slots 2, 3, 4, 5 -> funcs 5, 6, 7, 8
        const elems = [
          0x01,
          0x00, 0x41, 0x02, 0x0b, 0x04, 0x05, 0x06, 0x07, 0x08,
        ];
        const bInit = [ 0x00, 0x0b ];
        // createJsThunk(ctrl, fnId):
        // if ctrl == 0x100 (256 -> 0x80, 0x02): check global 0 (-> slot 2), global 1 (-> slot 3)
        // if ctrl == 0x200 (512 -> 0x80, 0x04): check global 2 (-> slot 4), global 3 (-> slot 5)
        const allocSlot = (globalIdx, tableSlot) => [
          0x23, globalIdx, 0x45, 0x04, 0x40,
          0x20, 0x01, 0x24, globalIdx, 0x41, tableSlot, 0x0f,
          0x0b,
        ];
        const bCreate = [
          0x00,
          0x20, 0x00, 0x41, 0x80, 0x02, 0x46, 0x04, 0x40,
          ...allocSlot(0, 2),
          ...allocSlot(1, 3),
          0x41, 0x00, 0x0f,
          0x0b,
          0x20, 0x00, 0x41, 0x80, 0x04, 0x46, 0x04, 0x40,
          ...allocSlot(2, 4),
          ...allocSlot(3, 5),
          0x41, 0x00, 0x0f,
          0x0b,
          0x41, 0x00, 0x0b,
        ];
        const freeSlot = (globalIdx, tableSlot) => [
          0x20, 0x01, 0x41, tableSlot, 0x46, 0x04, 0x40,
          0x23, globalIdx, 0x21, 0x02, 0x41, 0x00, 0x24, globalIdx, 0x20, 0x02, 0x0f,
          0x0b,
        ];
        const bDestroy = [
          0x01, 0x01, 0x7f,
          ...freeSlot(0, 2),
          ...freeSlot(1, 3),
          ...freeSlot(2, 4),
          ...freeSlot(3, 5),
          0x41, 0x00, 0x0b,
        ];
        const identSlot = (globalIdx, tableSlot) => [
          0x20, 0x01, 0x41, tableSlot, 0x46, 0x04, 0x40,
          0x23, globalIdx, 0x0f,
          0x0b,
        ];
        const bIdent = [
          0x00,
          ...identSlot(0, 2),
          ...identSlot(1, 3),
          ...identSlot(2, 4),
          ...identSlot(3, 5),
          0x41, 0x00, 0x0b,
        ];
        const bThunk0 = [ 0x00, 0x23, 0x00, 0x0b ];
        const bThunk1 = [ 0x00, 0x23, 0x01, 0x0b ];
        const bThunk2 = [ 0x00, 0x23, 0x02, 0x0b ];
        const bThunk3 = [ 0x00, 0x23, 0x03, 0x0b ];
        const bodies = [ bInit, bCreate, bDestroy, bIdent, bThunk0, bThunk1, bThunk2, bThunk3 ];
        const codePayload = [ bodies.length ];
        for (const b of bodies) {
          codePayload.push(...uleb(b.length), ...b);
        }
        const wasmMulti = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          ...section(1, types),
          ...section(2, imports),
          ...section(3, funcs),
          ...section(6, globals),
          ...section(7, exports),
          ...section(9, elems),
          ...section(10, codePayload),
        ]);

        const env = new Env();
        await env.loadModule(wasmMulti, {
          memoryInitial: 1,
          tableInitial: 6,
          multithreaded: false,
          wasmImports: {
            'zigar:component-host': { ping() {} },
          },
        });

        const ctrlA = 0x100;
        const ctrlB = 0x200;

        // Allocate 20 thunks for ctrlA (spawns 10 thunkSources since 2 slots/source)
        const addrsA = [];
        for (let i = 1; i <= 20; i++) {
          addrsA.push(env.allocateJsThunk(ctrlA, 1000 + i));
        }
        expect(env.thunkSources).to.have.lengthOf(10);

        // Allocate 20 thunks for ctrlB — must reuse all 10 existing thunkSources without spawning an 11th!
        const addrsB = [];
        for (let i = 1; i <= 20; i++) {
          addrsB.push(env.allocateJsThunk(ctrlB, 2000 + i));
        }
        expect(env.thunkSources).to.have.lengthOf(10);

        for (let i = 0; i < 20; i++) {
          expect(env.table.get(addrsA[i])()).to.equal(1001 + i);
          expect(env.table.get(addrsB[i])()).to.equal(2001 + i);
        }

        // Identify first pair (findJsThunk must NOT clear table entry or corrupt secondary source tracking)
        expect(env.findJsThunk(ctrlA, addrsA[0])).to.equal(1001);
        expect(env.findJsThunk(ctrlB, addrsB[0])).to.equal(2001);
        expect(env.table.get(addrsA[0])).to.be.a('function');
        expect(env.table.get(addrsB[0])).to.be.a('function');

        // Free remaining 19 pairs -> 8 thunkSources drained completely, leaving only the 2 holding A[0] and B[0]
        for (let i = 1; i < 20; i++) {
          expect(env.freeJsThunk(ctrlA, addrsA[i])).to.equal(1001 + i);
          expect(env.freeJsThunk(ctrlB, addrsB[i])).to.equal(2001 + i);
        }
        expect(env.thunkSources).to.have.lengthOf(2);

        // Free A[0] and B[0] -> all secondary thunkSources must now drain cleanly to 0!
        expect(env.freeJsThunk(ctrlA, addrsA[0])).to.equal(1001);
        expect(env.freeJsThunk(ctrlB, addrsB[0])).to.equal(2001);
        expect(env.thunkSources).to.have.lengthOf(0);
      })
    })
    describe('secondary WASM thunk forwarding (17+ live JS functions)', function() {
      it('should invoke 24+ distinct live JS functions via secondary WASM instances and reclaim slots on release', async function() {
        const wasmPath = absolute('./wasm-samples/fn-pointer.wasm');
        const binary = await readFile(wasmPath);
        const env = new Env();
        await env.loadModule(binary, {
          tableInitial: 100,
          multithreaded: false,
        });
        env.acquireStructures();
        const { call } = env.useStructures();
        const fns = [];
        const results = [];
        for (let i = 0; i < 24; i++) {
          const offset = (i + 1) * 100;
          fns.push(() => {
            results.push(offset + 7);
          });
        }
        // Pass all 24 distinct live functions; 17..24 overflow primary 16-slot pool into secondary WASM instance!
        for (let i = 0; i < 24; i++) {
          call(fns[i]);
        }
        expect(env.thunkSources.length).to.be.at.least(1);
        expect(results).to.have.lengthOf(24);
        for (let i = 0; i < 24; i++) {
          expect(results[i]).to.equal((i + 1) * 100 + 7);
        }
        // Release all 24 functions via freeFunction (exercises identifyJsThunk -> findJsThunk -> destroyJsThunk -> freeJsThunk)
        for (const fn of fns) {
          env.freeFunction(fn);
        }
        expect(env.thunkSources).to.have.lengthOf(0);

        // Allocate and invoke 20 fresh functions afterwards to verify clean reuse
        const secondWave = [];
        const secondResults = [];
        for (let i = 0; i < 20; i++) {
          const val = 5000 + i;
          const fn = () => {
            secondResults.push(val);
          };
          secondWave.push(fn);
          call(fn);
        }
        expect(secondResults).to.have.lengthOf(20);
        for (let i = 0; i < 20; i++) {
          expect(secondResults[i]).to.equal(5000 + i);
        }
        for (const fn of secondWave) {
          env.freeFunction(fn);
        }
        expect(env.thunkSources).to.have.lengthOf(0);
      })
    })
    describe('primary-instance dynamic WASM trampolines', function() {
      it('should synthesize, invoke, identify, and pool WASM32 dynamic trampolines without secondary instances', async function() {
        const str = (s) => [ s.length, ...Buffer.from(s) ];
        const section = (id, payload) => [ id, payload.length, ...payload ];
        // Primary module:
        // Types:
        //   0: () -> ()
        //   1: (i32) -> ()      [setPendingDynamicJsThunkId]
        //   2: (i32) -> i32     [getDynamicJsThunk]
        //   3: (i32, i32) -> i32 [ctrlA dynamic_thunk: (x, y) -> pending_id * 1000 + x * 10 + y]
        //   4: (i32) -> i32     [ctrlB dynamic_thunk: (x) -> pending_id * 100 + x]
        const types = [
          0x05,
          0x60, 0x00, 0x00,
          0x60, 0x01, 0x7f, 0x00,
          0x60, 0x01, 0x7f, 0x01, 0x7f,
          0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
          0x60, 0x01, 0x7f, 0x01, 0x7f,
        ];
        const imports = [
          0x02,
          ...str('env'), ...str('memory'), 0x02, 0x00, 0x01,
          ...str('env'), ...str('__indirect_function_table'), 0x01, 0x70, 0x00, 0x10,
        ];
        // Funcs: 0=initialize, 1=setPendingDynamicJsThunkId, 2=getDynamicJsThunk, 3=dynThunkA, 4=dynThunkB
        const funcs = [ 0x05, 0x00, 0x01, 0x02, 0x03, 0x04 ];
        // Global 0: pending_dynamic_js_thunk_id (mut i32) = 0
        const globals = [ 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b ];
        const exports = [
          0x03,
          ...str('initialize'), 0x00, 0x00,
          ...str('setPendingDynamicJsThunkId'), 0x00, 0x01,
          ...str('getDynamicJsThunk'), 0x00, 0x02,
        ];
        // Place dynThunkA at table[11] (tests i32.const 11 = 0x41 0x0b 0x0b!) and dynThunkB at table[12]
        const elems = [ 0x01, 0x00, 0x41, 0x0b, 0x0b, 0x02, 0x03, 0x04 ];
        const bInit = [ 0x00, 0x0b ];
        const bSetId = [ 0x00, 0x20, 0x00, 0x24, 0x00, 0x0b ];
        // getDynamicJsThunk(ctrl): ctrl == 0x100 -> 11; ctrl == 0x200 -> 12; else 0
        const bGetDyn = [
          0x00,
          0x20, 0x00, 0x41, 0x80, 0x02, 0x46, 0x04, 0x40, 0x41, 0x0b, 0x0f, 0x0b,
          0x20, 0x00, 0x41, 0x80, 0x04, 0x46, 0x04, 0x40, 0x41, 0x0c, 0x0f, 0x0b,
          0x41, 0x00, 0x0b,
        ];
        // dynThunkA(x, y): id = global0; global0 = 0; return id * 1000 + x * 10 + y
        const bDynA = [
          0x01, 0x01, 0x7f, // local 2 = id
          0x23, 0x00, 0x21, 0x02,
          0x41, 0x00, 0x24, 0x00,
          0x20, 0x02, 0x41, 0xe8, 0x07, 0x6c,
          0x20, 0x00, 0x41, 0x0a, 0x6c, 0x6a,
          0x20, 0x01, 0x6a,
          0x0b,
        ];
        // dynThunkB(x): id = global0; global0 = 0; return id * 100 + x
        const bDynB = [
          0x01, 0x01, 0x7f, // local 1 = id
          0x23, 0x00, 0x21, 0x01,
          0x41, 0x00, 0x24, 0x00,
          0x20, 0x01, 0x41, 0xe4, 0x00, 0x6c,
          0x20, 0x00, 0x6a,
          0x0b,
        ];
        const bodies = [ bInit, bSetId, bGetDyn, bDynA, bDynB ];
        const codePayload = [ bodies.length ];
        for (const b of bodies) {
          codePayload.push(b.length, ...b);
        }
        const wasmBytes = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          ...section(1, types),
          ...section(2, imports),
          ...section(3, funcs),
          ...section(6, globals),
          ...section(7, exports),
          ...section(9, elems),
          ...section(10, codePayload),
        ]);

        // Load via Response to verify module-loading captures this.wasmBinary from Response too!
        const response = new Response(wasmBytes, { headers: { 'content-type': 'application/wasm' } });
        const env = new Env();
        await env.loadModule(response, {
          memoryInitial: 1,
          tableInitial: 16,
          multithreaded: false,
        });

        const ctrlA = 0x100;
        const ctrlB = 0x200;
        const slotsA = [];
        const slotsB = [];
        for (let i = 1; i <= 12; i++) {
          slotsA.push(env.allocateJsThunk(ctrlA, 10 + i));
          slotsB.push(env.allocateJsThunk(ctrlB, 50 + i));
        }
        // Zero secondary instances!
        expect(env.thunkSources).to.have.lengthOf(0);

        for (let i = 0; i < 12; i++) {
          expect(env.table.get(slotsA[i])(3, 7)).to.equal((11 + i) * 1000 + 37);
          expect(env.table.get(slotsB[i])(9)).to.equal((51 + i) * 100 + 9);
        }

        // Cross-controller isolation in findJsThunk / freeJsThunk
        expect(env.findJsThunk(ctrlA, slotsA[0])).to.equal(11);
        expect(env.findJsThunk(ctrlB, slotsA[0])).to.equal(0);
        expect(env.freeJsThunk(ctrlB, slotsA[0])).to.equal(0);
        expect(env.findJsThunk(ctrlA, 99999)).to.equal(0);
        expect(env.freeJsThunk(ctrlA, 99999)).to.equal(0);

        const tableLenBeforeReuse = env.table.length;
        const firstTrampolineFn = env.table.get(slotsA[0]);

        // Free all 24 dynamic thunks and reallocate 24 with new IDs — must reuse pooled trampolines & slots without growing table!
        for (let i = 0; i < 12; i++) {
          expect(env.freeJsThunk(ctrlA, slotsA[i])).to.equal(11 + i);
          expect(env.freeJsThunk(ctrlB, slotsB[i])).to.equal(51 + i);
          expect(env.table.get(slotsA[i])).to.be.null;
          expect(env.table.get(slotsB[i])).to.be.null;
        }
        const reusedA = [];
        const reusedB = [];
        const seenReusedTrampolines = new Set();
        for (let i = 0; i < 12; i++) {
          const sa = env.allocateJsThunk(ctrlA, 80 + i);
          const sb = env.allocateJsThunk(ctrlB, 90 + i);
          reusedA.push(sa);
          reusedB.push(sb);
          seenReusedTrampolines.add(env.table.get(sa));
        }
        expect(env.table.length).to.equal(tableLenBeforeReuse);
        expect(seenReusedTrampolines.has(firstTrampolineFn)).to.be.true;
        for (let i = 0; i < 12; i++) {
          expect(env.table.get(reusedA[i])(4, 2)).to.equal((80 + i) * 1000 + 42);
          expect(env.table.get(reusedB[i])(6)).to.equal((90 + i) * 100 + 6);
        }
      })

      it('should synthesize and invoke memory64 + table64 dynamic trampolines', async function() {
        const str = (s) => [ s.length, ...Buffer.from(s) ];
        const section = (id, payload) => [ id, payload.length, ...payload ];
        const types = [
          0x04,
          0x60, 0x00, 0x00,
          0x60, 0x01, 0x7e, 0x00,             // (i64) -> ()
          0x60, 0x01, 0x7e, 0x01, 0x7e,       // (i64) -> i64
          0x60, 0x02, 0x7e, 0x7e, 0x01, 0x7e, // (i64, i64) -> i64
        ];
        const imports = [
          0x02,
          ...str('env'), ...str('memory'), 0x02, 0x05, 0x01, 0x02,
          ...str('env'), ...str('__indirect_function_table'), 0x01, 0x70, 0x04, 0x10,
        ];
        const funcs = [ 0x04, 0x00, 0x01, 0x02, 0x03 ];
        const globals = [ 0x01, 0x7e, 0x01, 0x42, 0x00, 0x0b ];
        const exports = [
          0x03,
          ...str('initialize'), 0x00, 0x00,
          ...str('setPendingDynamicJsThunkId'), 0x00, 0x01,
          ...str('getDynamicJsThunk'), 0x00, 0x02,
        ];
        // Active table64 element at offset 11 (i64.const 11 = 0x42 0x0b 0x0b)
        const elems = [ 0x01, 0x00, 0x42, 0x0b, 0x0b, 0x01, 0x03 ];
        const bInit = [ 0x00, 0x0b ];
        const bSetId = [ 0x00, 0x20, 0x00, 0x24, 0x00, 0x0b ];
        const bGetDyn = [ 0x00, 0x42, 0x0b, 0x0b ];
        const bDyn = [
          0x01, 0x01, 0x7e,
          0x23, 0x00, 0x21, 0x02,
          0x42, 0x00, 0x24, 0x00,
          0x20, 0x02, 0x42, 0xe8, 0x07, 0x7e,
          0x20, 0x00, 0x7c,
          0x20, 0x01, 0x7c,
          0x0b,
        ];
        const bodies = [ bInit, bSetId, bGetDyn, bDyn ];
        const codePayload = [ bodies.length ];
        for (const b of bodies) {
          codePayload.push(b.length, ...b);
        }
        const wasm64Bytes = new Uint8Array([
          0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
          ...section(1, types),
          ...section(2, imports),
          ...section(3, funcs),
          ...section(6, globals),
          ...section(7, exports),
          ...section(9, elems),
          ...section(10, codePayload),
        ]);

        const env = new Env();
        await env.loadModule(wasm64Bytes, {
          memoryInitial: 1,
          memoryMax: 2,
          tableInitial: 16,
          multithreaded: false,
        });
        expect(env.memory64).to.be.true;
        expect(env.table64).to.be.true;

        const ctrl = 0x1_0000_0400n;
        const slot1 = env.allocateJsThunk(ctrl, 301n);
        const slot2 = env.allocateJsThunk(ctrl, 302n);
        expect(slot1).to.be.a('bigint');
        expect(slot2).to.be.a('bigint');
        expect(env.thunkSources).to.have.lengthOf(0);
        expect(env.table.get(slot1)(10n, 5n)).to.equal(301015n);
        expect(env.table.get(slot2)(20n, 7n)).to.equal(302027n);
        expect(env.findJsThunk(ctrl, slot1)).to.equal(301);
        expect(env.freeJsThunk(ctrl, slot1)).to.equal(301);
        const slot3 = env.allocateJsThunk(ctrl, 303n);
        expect(slot3).to.equal(slot1);
        expect(env.table.get(slot3)(30n, 9n)).to.equal(303039n);
      })
    })
  })
}

function absolute(relpath) {
  return fileURLToPath(new URL(relpath, import.meta.url));
}
