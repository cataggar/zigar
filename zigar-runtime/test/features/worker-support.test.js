import { expect } from 'chai';
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { Worker as NodeThreadWorker } from 'node:worker_threads';
import { defineEnvironment } from '../../src/environment.js';
import '../../src/mixins.js';
import { capture, delay } from '../test-utils.js';

const Env = defineEnvironment();

function uleb(n) {
  const out = [];
  do {
    let byte = n & 0x7f;
    n >>>= 7;
    if (n !== 0) byte |= 0x80;
    out.push(byte);
  } while (n !== 0);
  return out;
}

function sleb(n) {
  const out = [];
  let more = true;
  while (more) {
    let byte = n & 0x7f;
    n >>= 7;
    if ((n === 0 && (byte & 0x40) === 0) || (n === -1 && (byte & 0x40) !== 0)) {
      more = false;
    } else {
      byte |= 0x80;
    }
    out.push(byte);
  }
  return out;
}

function encodeStr(s) {
  const bytes = Buffer.from(s, 'utf8');
  return [ ...uleb(bytes.length), ...bytes ];
}

function section(id, payload) {
  return [ id, ...uleb(payload.length), ...payload ];
}

function buildThreadModule(importDefs, bodyInstructions) {
  const types = [
    [ 0x60, 0x02, 0x7f, 0x7f, 0x00 ],                   // 0: (i32, i32) -> ()
    [ 0x60, 0x01, 0x7f, 0x01, 0x7f ],                   // 1: (i32) -> (i32)
    [ 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f ], // 2: (i32, i32, i32, i32) -> (i32)
  ];
  const typePayload = [ ...uleb(types.length), ...types.flat() ];
  const imports = [
    [ ...encodeStr('env'), ...encodeStr('memory'), 0x02, 0x03, 0x01, 0x04 ],
    ...importDefs.map(({ name, type }) => [
      ...encodeStr('wasi_snapshot_preview1'),
      ...encodeStr(name),
      0x00,
      type,
    ]),
  ];
  const importPayload = [ ...uleb(imports.length), ...imports.flat() ];
  const funcPayload = [ 0x01, 0x00 ];
  const exportPayload = [ 0x01, ...encodeStr('wasi_thread_start'), 0x00, ...uleb(importDefs.length) ];
  const funcBody = [ 0x00, ...bodyInstructions, 0x0b ];
  const codePayload = [ 0x01, ...uleb(funcBody.length), ...funcBody ];
  const bytes = new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...section(1, typePayload),
    ...section(2, importPayload),
    ...section(3, funcPayload),
    ...section(7, exportPayload),
    ...section(10, codePayload),
  ]);
  return new WebAssembly.Module(bytes);
}

function buildThreadModule64(importDefs, bodyInstructions, { table64 = false } = {}) {
  const types = [
    [ 0x60, 0x02, 0x7f, 0x7e, 0x00 ],                   // 0: (i32, i64) -> ()
    [ 0x60, 0x01, 0x7e, 0x01, 0x7f ],                   // 1: (i64) -> (i32)
    [ 0x60, 0x04, 0x7f, 0x7e, 0x7e, 0x7e, 0x01, 0x7f ], // 2: (i32, i64, i64, i64) -> (i32)
    [ 0x60, 0x01, 0x7f, 0x01, 0x7e ],                   // 3: (i32) -> (i64)
  ];
  const typePayload = [ ...uleb(types.length), ...types.flat() ];
  const imports = [
    // memory64 shared: limits flags = 0x07 (has_max | shared | is_64), initial=1, max=4
    [ ...encodeStr('env'), ...encodeStr('memory'), 0x02, 0x07, 0x01, 0x04 ],
    ...(table64 ? [
      [ ...encodeStr('env'), ...encodeStr('__indirect_function_table'), 0x01, 0x70, 0x04, 0x04 ],
    ] : []),
    ...importDefs.map(({ module = 'wasi_snapshot_preview1', name, type }) => [
      ...encodeStr(module),
      ...encodeStr(name),
      0x00,
      type,
    ]),
  ];
  const importPayload = [ ...uleb(imports.length), ...imports.flat() ];
  const funcPayload = [ 0x01, 0x00 ];
  const exportPayload = [ 0x01, ...encodeStr('wasi_thread_start'), 0x00, ...uleb(importDefs.length) ];
  const funcBody = [ 0x00, ...bodyInstructions, 0x0b ];
  const codePayload = [ 0x01, ...uleb(funcBody.length), ...funcBody ];
  const bytes = new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...section(1, typePayload),
    ...section(2, importPayload),
    ...section(3, funcPayload),
    ...section(7, exportPayload),
    ...section(10, codePayload),
  ]);
  return new WebAssembly.Module(bytes);
}

if (process.env.TARGET === 'wasm') {
  describe('Feature: worker-support', function() {
    describe('spawnThread', function() {
      it('should spawn a thread', async function() {
        const env = new Env();
        const url = new URL('./wasm-samples/thread.wasm', import.meta.url);
        const buffer = await readFile(fileURLToPath(url));
        await env.loadModule(buffer, {
          memoryInitial: 256,
          memoryMax: 1024,
          tableInitial: 17,
          multithreaded: true,
        });
        env.acquireStructures();
        const { spawn } = env.useStructures();
        const [ line ] = await capture(async () => {
          const result = spawn();
          expect(result).to.equal(123);
          await delay(500);
        });
        expect(line).to.equal('Hello!');
      })
      it('should reuse a single per-worker futex across sequential host calls and stderr writes', async function() {
        const env = new Env();
        await delay(0);
        const memory = new WebAssembly.Memory({ initial: 1, maximum: 4, shared: true });
        const dv = new DataView(memory.buffer);
        // Place "err!" at 0x40 and an iovec { ptr: 0x40, len: 4 } at 0x50
        new Uint8Array(memory.buffer, 0x40, 4).set(Buffer.from('err!'));
        dv.setUint32(0x50, 0x40, true);
        dv.setUint32(0x54, 4, true);

        const executable = buildThreadModule([
          { name: 'host_op', type: 1 },
          { name: 'fd_write', type: 2 },
        ], [
          // [taddr + 0] = host_op(10)
          0x20, 0x01, 0x41, ...sleb(10), 0x10, 0x00, 0x36, 0x02, 0x00,
          // [taddr + 4] = fd_write(2, 0x50, 1, 0x58)
          0x20, 0x01, 0x41, ...sleb(2), 0x41, ...sleb(0x50), 0x41, ...sleb(1), 0x41, ...sleb(0x58), 0x10, 0x01, 0x36, 0x02, 0x04,
          // [taddr + 8] = host_op(20)
          0x20, 0x01, 0x41, ...sleb(20), 0x10, 0x00, 0x36, 0x02, 0x08,
          // [taddr + 12] = host_op(30)
          0x20, 0x01, 0x41, ...sleb(30), 0x10, 0x00, 0x36, 0x02, 0x0c,
        ]);
        const stderrChunks = [];
        env.executable = executable;
        env.memory = memory;
        env.options = {};
        env.exportedModules = {
          wasi_snapshot_preview1: {
            host_op: (x) => x * 10 + 1,
            fd_write_stderr: (bytes) => {
              stderrChunks.push(Buffer.from(bytes).toString('utf8'));
              return 0;
            },
          },
        };

        const worker = env.createWorker();
        const initialFutex = worker.callFutex;
        expect(initialFutex).to.be.an.instanceOf(Int32Array);
        expect(initialFutex.buffer).to.be.an.instanceOf(SharedArrayBuffer);
        expect(initialFutex.byteLength).to.equal(8);

        const callMessages = [];
        const done = new Promise((resolve) => {
          worker.on('message', (msg) => {
            if (msg.type === 'call') {
              callMessages.push(msg);
            } else if (msg.type === 'done') {
              resolve();
            }
          });
        });

        worker.run(1, 0x100);
        await done;

        expect(callMessages).to.have.lengthOf(4);
        expect(callMessages.map(m => m.callId)).to.deep.equal([ 1, 2, 3, 4 ]);
        for (const msg of callMessages) {
          expect(msg).to.not.have.property('futex');
        }
        expect(worker.callFutex).to.equal(initialFutex);
        expect(stderrChunks).to.deep.equal([ 'err!' ]);
        expect(dv.getUint32(0x58, true)).to.equal(4);
        expect(dv.getInt32(0x100, true)).to.equal(101);
        expect(dv.getInt32(0x104, true)).to.equal(0);
        expect(dv.getInt32(0x108, true)).to.equal(201);
        expect(dv.getInt32(0x10c, true)).to.equal(301);
      })
      it('should ignore late main-thread replies for timed-out calls without clobbering subsequent calls', async function() {
        const env = new Env();
        await delay(0);
        const memory = new WebAssembly.Memory({ initial: 1, maximum: 4, shared: true });
        const dv = new DataView(memory.buffer);
        const executable = buildThreadModule([
          { name: 'async_op', type: 1 },
        ], [
          // [taddr + 0] = async_op(1)
          0x20, 0x01, 0x41, ...sleb(1), 0x10, 0x00, 0x36, 0x02, 0x00,
          // [taddr + 4] = async_op(2)
          0x20, 0x01, 0x41, ...sleb(2), 0x10, 0x00, 0x36, 0x02, 0x04,
        ]);

        let resolveCall1, resolveCall2;
        let notifyCall2Arrived;
        const call2Arrived = new Promise(r => { notifyCall2Arrived = r; });
        env.executable = executable;
        env.memory = memory;
        env.options = {};
        env.exportedModules = {
          wasi_snapshot_preview1: {
            async_op: (step) => {
              if (step === 1) {
                return new Promise(r => { resolveCall1 = r; });
              }
              notifyCall2Arrived();
              return new Promise(r => { resolveCall2 = r; });
            },
          },
        };

        // Part 1: End-to-end WASM worker where callId 1 expires (-3) and resolves late during callId 2
        const worker = env.createWorker();
        const done = new Promise((resolve) => {
          worker.on('message', (msg) => {
            if (msg.type === 'done') resolve();
          });
        });
        worker.run(1, 0x100);
        while (Atomics.load(worker.callFutex, 0) !== 1) {
          await delay(1);
        }
        // Simulate worker timeout CAS on callId 1 (1 -> -3) so worker advances to callId 2
        Atomics.store(worker.callFutex, 1, 0);
        expect(Atomics.compareExchange(worker.callFutex, 0, 1, -3)).to.equal(1);
        Atomics.notify(worker.callFutex, 0, 1);

        await call2Arrived;
        expect(Atomics.load(worker.callFutex, 0)).to.equal(2);

        // Late completion for expired callId 1 arrives while callId 2 is waiting
        resolveCall1(999999);
        await delay(5);
        expect(Atomics.load(worker.callFutex, 0)).to.equal(2);
        expect(Atomics.load(worker.callFutex, 1)).to.not.equal(999999);

        // Now complete callId 2 and fire another stale signal for callId 1
        resolveCall2(4242);
        worker.signal(1, -1, 888888);
        await done;

        expect(dv.getInt32(0x100, true)).to.equal(0);
        expect(dv.getInt32(0x104, true)).to.equal(4242);

        // Part 2: Real Atomics.wait timeout (10ms) + boundary CAS race against worker.signal
        const worker2 = env.createWorker();
        const futex2 = worker2.callFutex;
        const helperCode = `
          const { parentPort, workerData: futex } = require('node:worker_threads');
          let nextCallId = 0;
          const beginCall = () => {
            nextCallId = (nextCallId === 0x7fffffff) ? 1 : nextCallId + 1;
            Atomics.store(futex, 0, nextCallId);
            return nextCallId;
          };
          const wait = (callId, timeout) => {
            const res = Atomics.wait(futex, 0, callId, timeout);
            let state;
            if (res === 'timed-out') {
              const prev = Atomics.compareExchange(futex, 0, callId, -3);
              if (prev === callId) return 0;
              state = prev;
            } else {
              state = Atomics.load(futex, 0);
            }
            return Atomics.load(futex, 1);
          };
          const c1 = beginCall();
          const r1 = wait(c1, 10); // genuinely times out after 10ms
          const c2 = beginCall();
          parentPort.postMessage({ readyForCall2: c2 });
          const r2 = wait(c2, 2000);
          parentPort.postMessage({ results: [ r1, r2 ] });
        `;
        const helper = new NodeThreadWorker(helperCode, { eval: true, workerData: futex2 });
        const helperResults = await new Promise((resolve, reject) => {
          helper.on('error', reject);
          helper.on('message', (msg) => {
            if (msg.readyForCall2) {
              // Late reply to genuinely timed-out callId 1 must be ignored
              worker2.signal(1, -1, 777777);
              // Valid reply to callId 2 must succeed
              worker2.signal(2, -1, 12345);
            } else if (msg.results) {
              resolve(msg.results);
            }
          });
        });
        await helper.terminate();
        // Verify legacy customFutex fallback when callId is undefined
        const legacyFutex = new Int32Array(new SharedArrayBuffer(8));
        worker2.signal(undefined, 1, 555, legacyFutex);
        expect(Atomics.load(legacyFutex, 0)).to.equal(1);
        expect(Atomics.load(legacyFutex, 1)).to.equal(555);
        worker2.end(true);
        expect(helperResults).to.deep.equal([ 0, 12345 ]);
      })
      it('should exit cleanly on deferred thread cancellation (-2) and run cleanup on the reused worker', async function() {
        const env = new Env();
        await delay(0);
        const memory = new WebAssembly.Memory({ initial: 1, maximum: 4, shared: true });
        const dv = new DataView(memory.buffer);
        const executable = buildThreadModule([
          { name: 'first_op', type: 1 },
          { name: 'second_op', type: 1 },
          { name: 'cleanup_op', type: 1 },
        ], [
          // if (taddr == 0x100) {
          0x20, 0x01, 0x41, ...sleb(0x100), 0x46, 0x04, 0x40,
            // [0x100] = first_op(tid)
            0x41, ...sleb(0x100), 0x20, 0x00, 0x10, 0x00, 0x36, 0x02, 0x00,
            // [0x104] = second_op(tid) -- canceled here with -2!
            0x41, ...sleb(0x104), 0x20, 0x00, 0x10, 0x01, 0x36, 0x02, 0x00,
            // [0x108] = 999 (unreachable)
            0x41, ...sleb(0x108), 0x41, ...sleb(999), 0x36, 0x02, 0x00,
          // } else {
          0x05,
            // [taddr] = cleanup_op(tid)
            0x20, 0x01, 0x20, 0x00, 0x10, 0x02, 0x36, 0x02, 0x00,
          // }
          0x0b,
        ]);

        let secondOpCalled = false;
        env.executable = executable;
        env.memory = memory;
        env.options = {};
        env.exportedModules = {
          wasi_snapshot_preview1: {
            first_op: (tid) => {
              // Schedule deferred cancellation with cleanup address 0x200
              env.cancelThread(tid, 0x200, false);
              return 111;
            },
            second_op: () => {
              secondOpCalled = true;
              return 222;
            },
            cleanup_op: () => 777,
          },
        };

        const tid = env.spawnThread(0x100);
        const spawnedWorker = env.workers[0];
        const spawnedFutex = spawnedWorker.callFutex;
        while (env.workers.length > 0) {
          await delay(5);
        }

        expect(secondOpCalled).to.be.false;
        expect(dv.getInt32(0x100, true)).to.equal(111);
        expect(dv.getInt32(0x104, true)).to.equal(0);
        expect(dv.getInt32(0x108, true)).to.equal(0);
        expect(dv.getInt32(0x200, true)).to.equal(777);
        expect(spawnedWorker.callFutex).to.equal(spawnedFutex);
      })
      it('should support memory64 stderr fd_write, table64, BigInt taddr, and 64-bit thread-address', async function() {
        const env = new Env();
        await delay(0);
        const memory = new WebAssembly.Memory({ initial: 1n, maximum: 4n, shared: true, address: 'i64' });
        const dv = new DataView(memory.buffer);
        // Place "wasm" at 0x40 and "64!" at 0x48; two 16-byte ciovec_t entries at 0x50..0x70
        new Uint8Array(memory.buffer, 0x40, 4).set(Buffer.from('wasm'));
        new Uint8Array(memory.buffer, 0x48, 3).set(Buffer.from('64!'));
        dv.setBigUint64(0x50, 0x40n, true);
        dv.setBigUint64(0x58, 4n, true);
        dv.setBigUint64(0x60, 0x48n, true);
        dv.setBigUint64(0x68, 3n, true);
        dv.setUint32(0x74, 0xdeadbeef, true);
        dv.setUint32(0x7c, 0xdeadbeef, true);

        const executable = buildThreadModule64([
          { module: 'wasi', name: 'thread-address', type: 3 },
          { name: 'fd_write', type: 2 },
        ], [
          // i64 [taddr + 0] = thread-address(tid)
          0x20, 0x01, 0x20, 0x00, 0x10, 0x00, 0x37, 0x03, 0x00,
          // i32 [taddr + 8] = fd_write(2, 0x50n, 2n, 0x70n)  -- workerMain 64-bit stderr fast-path
          0x20, 0x01, 0x41, ...sleb(2), 0x42, ...sleb(0x50), 0x42, ...sleb(2), 0x42, ...sleb(0x70), 0x10, 0x01, 0x36, 0x02, 0x08,
          // i32 [taddr + 12] = fd_write(1, 0x50n, 2n, 0x78n) -- forwarded BigInt host call
          0x20, 0x01, 0x41, ...sleb(1), 0x42, ...sleb(0x50), 0x42, ...sleb(2), 0x42, ...sleb(0x78), 0x10, 0x01, 0x36, 0x02, 0x0c,
        ], { table64: true });

        const stderrChunks = [];
        const stdoutLines = [];
        env.executable = executable;
        env.memory = memory;
        env.memory64 = true;
        env.table64 = true;
        env.options = { tableInitial: 4 };
        env.redirectStream('stdout', env.convertWriter(stdoutLines));
        env.exportedModules = {
          wasi: {
            'thread-address': env.getThreadHandler('thread-address'),
          },
          wasi_snapshot_preview1: {
            fd_write: env.fdWrite.bind(env),
            fd_write_stderr: (bytes) => {
              stderrChunks.push(Buffer.from(bytes).toString('utf8'));
              return 0;
            },
          },
        };

        const spawn = env.getThreadHandler('thread-spawn');
        const tid = spawn(0x100n);
        expect(env.getThreadAddress(tid)).to.equal(0x100n);
        while (env.workers.length > 0) {
          await delay(5);
        }

        expect(stderrChunks).to.deep.equal([ 'wasm64!' ]);
        expect(Buffer.from(stdoutLines[0]).toString('utf8')).to.equal('wasm64!');
        expect(dv.getBigUint64(0x70, true)).to.equal(7n);
        expect(dv.getBigUint64(0x78, true)).to.equal(7n);
        expect(dv.getBigUint64(0x100, true)).to.equal(0x100n);
        expect(dv.getInt32(0x108, true)).to.equal(0);
        expect(dv.getInt32(0x10c, true)).to.equal(0);
      })
      it('should handle deferred thread cancellation with BigInt taddr on memory64', async function() {
        const env = new Env();
        await delay(0);
        const memory = new WebAssembly.Memory({ initial: 1n, maximum: 4n, shared: true, address: 'i64' });
        const dv = new DataView(memory.buffer);
        const executable = buildThreadModule64([
          { name: 'first_op', type: 1 },
          { name: 'second_op', type: 1 },
          { name: 'cleanup_op', type: 1 },
        ], [
          // if (taddr == 0x100n) {
          0x20, 0x01, 0x42, ...sleb(0x100), 0x51, 0x04, 0x40,
            // [0x100n] = first_op(taddr)
            0x42, ...sleb(0x100), 0x20, 0x01, 0x10, 0x00, 0x36, 0x02, 0x00,
            // [0x104n] = second_op(taddr) -- canceled here with -2!
            0x42, ...sleb(0x104), 0x20, 0x01, 0x10, 0x01, 0x36, 0x02, 0x00,
          // } else {
          0x05,
            // [taddr] = cleanup_op(taddr)
            0x20, 0x01, 0x20, 0x01, 0x10, 0x02, 0x36, 0x02, 0x00,
          // }
          0x0b,
        ]);

        let secondOpCalled = false;
        let currentTid;
        env.executable = executable;
        env.memory = memory;
        env.memory64 = true;
        env.options = {};
        env.exportedModules = {
          wasi_snapshot_preview1: {
            first_op: (taddr) => {
              expect(taddr).to.equal(0x100n);
              env.cancelThread(currentTid, 0x200n, false);
              return 111;
            },
            second_op: () => {
              secondOpCalled = true;
              return 222;
            },
            cleanup_op: (taddr) => {
              expect(taddr).to.equal(0x200n);
              return 777;
            },
          },
        };

        const worker = env.createWorker();
        currentTid = 1;
        worker.run(1, 0x100n);
        while (env.workers.length > 0) {
          await delay(5);
        }

        expect(secondOpCalled).to.be.false;
        expect(dv.getInt32(0x100, true)).to.equal(111);
        expect(dv.getInt32(0x104, true)).to.equal(0);
        expect(dv.getInt32(0x200, true)).to.equal(777);
      })
    })
  })
}
