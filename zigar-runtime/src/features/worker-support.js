import { mixin } from '../environment.js';
import { isPromise, remove } from '../utils.js';

let NodeWorker;

export default mixin({
  init() {
    this.nextThreadId = 1;
    this.workers = [];
    if (process.env.COMPAT === 'node') {
      if (typeof(Worker) !== 'function') {
        import('node:worker_threads').then((m) => NodeWorker = m.Worker);
      }
    }
  },
  getThreadHandler(name) {
    switch (name) {
      case 'thread-spawn':
        /* c8 ignore start */
        if (typeof(window) === 'object' && !window.crossOriginIsolated) {
          console.warn(
            '%cHTML document is not cross-origin isolated %c\n\nWebAssembly multithreading in the browser is only possibly when %cwindow.crossOriginIsolated%c = true. Visit https://developer.mozilla.org/en-US/docs/Web/API/Window/crossOriginIsolated for information on how to enable it.',
            'color: red;font-size: 200%;font-weight:bold', '', 'background-color: lightgrey;font-weight:bold', ''
          );
        }
        /* c8 ignore end */
        return this.spawnThread.bind(this);
      case 'thread-cancel':
        return this.cancelThread.bind(this);
      case 'thread-address':
        return this.getThreadAddress.bind(this);
    }
  },
  spawnThread(taddr) {
    const tid = this.nextThreadId++;
    if (this.nextThreadId === 0x4000_0000) {
      this.nextThreadId = 1;
    }
    const worker = this.createWorker();
    worker.run(tid, this.memory64 ? BigInt(taddr) : taddr);
    return tid;
  },
  cancelThread(tid, taddr, immediate) {
    const id = Number(tid);
    const worker = this.workers.find(w => w.tid === id);
    if (worker) {
      const addr = this.memory64 ? BigInt(taddr) : taddr;
      if (immediate) {
        worker.end(true);
        // create a replacement worker that'll perform the thread clean-up
        const scab = this.createWorker();
        scab.run(id, addr);
      } else {
        // defer termination until thread reaches a cancellation point
        worker.canceled = addr;
      }
    }
  }, 
  getThreadAddress(tid) {
    const id = Number(tid);
    const worker = this.workers.find(w => w.tid === id);
    return this.memory64 ? BigInt(worker.taddr) : worker.taddr;
  },
  createWorker() {
    const sab = new SharedArrayBuffer(this.memory64 ? 16 : 8);
    const callFutex = new Int32Array(sab, 0, 2);
    const callResult64 = this.memory64 ? new BigInt64Array(sab, 8, 1) : null;
    const handler = (msg) => {
      switch (msg.type) {
        case 'call': {
          const { module, name, args, callId, futex } = msg;
          if (worker.canceled === null) {
            const fn = this.exportedModules[module]?.[name];
            // add a true argument to indicate that waiting is possible
            const result = fn?.(...args, true);
            const ok = (callId !== undefined) ? -1 : 1;
            const finish = (value) => worker.signal(callId, ok, value, futex);
            if (isPromise(result)) {
              result.then(finish);
            } else {
              finish(result);
            }
          } else {
            // a deferred cancellation has occurred--tell the worker to bail out from whatever 
            // it's currently doing
            const canceled = (callId !== undefined) ? -2 : 2;
            worker.signal(callId, canceled, 0, futex);
          }
        } break;
        case 'terminate': {
          if (worker.canceled) {
            // run clean-up routine
            worker.run(worker.tid, worker.canceled);
          } else {
            worker.end();
          }
        } break;
        case 'done': {
          worker.end();
        } break;
      }
    };
    /* c8 ignore start */
    let worker;
    if (typeof(Worker) === 'function') {
      // web worker
      const url = getWorkerURL();
      worker = new Worker(url, { name: 'zig' });
      worker.addEventListener('message', evt => handler(evt.data));
    }
    /* c8 ignore end */
    else if (process.env.COMPAT === 'node') {
      // Node.js worker-thread
      const code = getWorkerCode();
      worker = new NodeWorker(code, { eval: true });
      worker.on('message', handler);
    }
    // send WebAssembly start-up data
    const { executable, memory, options, memory64, table64 } = this;
    const workerOptions = { ...options, memory64, table64 };
    worker.callFutex = callFutex;
    worker.canceled = null;
    worker.postMessage({ type: 'start', executable, memory, options: workerOptions, futex: callFutex });
    const storeResult = (target, result) => {
      if (typeof(result) === 'bigint') {
        const res64 = (target === callFutex && callResult64)
          ? callResult64
          : (target.buffer.byteLength >= 16 ? new BigInt64Array(target.buffer, 8, 1) : null);
        if (res64) {
          Atomics.store(res64, 0, BigInt.asIntN(64, result));
        }
        Atomics.store(target, 1, Number(BigInt.asIntN(32, result)));
      } else {
        Atomics.store(target, 1, result | 0);
      }
    };
    worker.signal = (callId, response, result, customFutex) => {
      if (customFutex && callId === undefined) {
        if (Atomics.load(customFutex, 0) === 0) {
          storeResult(customFutex, result);
          Atomics.store(customFutex, 0, response);
          Atomics.notify(customFutex, 0, 1);
        }
        return;
      }
      const target = customFutex ?? callFutex;
      if (Atomics.load(target, 0) === callId) {
        storeResult(target, result);
        if (Atomics.compareExchange(target, 0, callId, response) === callId) {
          Atomics.notify(target, 0, 1);
        }
      }
    };
    worker.run = (tid, taddr) => {
      const addr = this.memory64 ? BigInt(taddr) : taddr;
      worker.tid = tid;
      worker.taddr = addr;
      worker.canceled = null;
      worker.postMessage({ type: 'run', tid, taddr: addr });
    };
    worker.end = (force = false) => {
      if (force) {
        worker.terminate();
      } else {
        worker.postMessage({ type: 'end' });
      }
      remove(this.workers, worker);
    };
    this.workers.push(worker);
    return worker;
  },
  /* c8 ignore start */
  ...(process.env.DEV ? {
    diagWorkerSupport() {
      this.showDiagnostics('Worker support', [
        `Worker count: ${this.workers.length}`,
        `Next thread id: ${this.nextThreadId}`,
      ]);
    }
  } : undefined),
  /* c8 ignore end */
});

function getWorkerCode() {
  const s = workerMain.toString();
  const si = s.indexOf('{') + 1;
  const ei = s.lastIndexOf('}');
  return s.slice(si, ei);
}

let workerURL;

function getWorkerURL() {
  if (!workerURL) {
    const code = getWorkerCode();
    workerURL = URL.createObjectURL(new Blob([ code ], { type: 'text/javascript' }))
  }
  return workerURL;
}

/* c8 ignore start */
function workerMain() {
  // this code must be entirely self-contained; don't call any imported functions
  const WA = WebAssembly;
  let port, instance;
  let nextCallId = 0;

  if (typeof(self) === 'object') {
    // web worker
    self.onmessage = (evt) => process(evt.data);
    port = self;
  } else {
    // Node.js worker-thread
    import(/* webpackIgnore: true */ 'node:worker_threads').then((module) => {
      port = module.parentPort;
      port.on('message', process);
    });
  }

  function process(msg) {
    switch (msg.type) {
      case 'start': {
        let { executable, memory, options, futex } = msg;
        const is64 = Boolean(options?.memory64);
        const sendFutex = !futex;
        futex ??= new Int32Array(new SharedArrayBuffer(is64 ? 16 : 8), 0, 2);
        const result64 = (is64 && futex.buffer.byteLength >= 16)
          ? new BigInt64Array(futex.buffer, 8, 1)
          : null;
        const imports = { 
          env: { memory },
          wasi: {},
          wasi_snapshot_preview1: {},
        };
        const exit = () => { throw new Error('Exit') };
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
            if (prev === callId) {
              return 0;
            }
            state = prev;
          } else {
            state = Atomics.load(futex, 0);
          }
          if (state === -2) {
            // thread was canceled
            exit();
          }
          return Atomics.load(futex, 1);
        };
        for (const { module, name, kind } of WA.Module.imports(executable)) {
          const ns = imports[module];
          if (kind === 'function' && ns) {
            const returnsI64 = is64 && module === 'wasi' && name === 'thread-address';
            ns[name] = (name === 'proc_exit') ? exit : function(...args) {
              if (returnsI64 && result64) {
                Atomics.store(result64, 0, 0n);
              }
              const callId = beginCall();
              const callMsg = { type: 'call', module, name, args, callId };
              if (sendFutex) {
                callMsg.futex = futex;
              }
              port.postMessage(callMsg);
              const res = wait(callId);
              return returnsI64
                ? (result64 ? BigInt.asUintN(64, Atomics.load(result64, 0)) : BigInt(res >>> 0))
                : res;
            };
            if (name === 'fd_write') {
              const write = ns[name];
              ns[name] = function(fd, iovsAddress, iovsCount, writtenAddress) {                
                if (fd === 2) {
                  // get the total length first
                  const dv = new DataView(memory.buffer);
                  const iovsAddr = Number(iovsAddress);
                  const count = Number(iovsCount);
                  const writtenAddr = Number(writtenAddress);
                  const ptrSize = is64 ? 8 : 4;
                  const iovsSize = ptrSize * 2;
                  let total = 0;
                  const ops = [];
                  for (let i = 0, offset = 0; i < count; i++, offset += iovsSize) {
                    const ptr = is64
                      ? Number(dv.getBigUint64(iovsAddr + offset, true))
                      : dv.getUint32(iovsAddr + offset, true);
                    const len = is64
                      ? Number(dv.getBigUint64(iovsAddr + offset + 8, true))
                      : dv.getUint32(iovsAddr + offset + 4, true);
                    ops.push({ ptr, len });
                    total += len;
                  }
                  const array = new Uint8Array(total);
                  // copy vectors into new array
                  let pos = 0;
                  for (const { ptr, len } of ops) {
                    const vector = new Uint8Array(dv.buffer, ptr, len);
                    array.set(vector, pos);
                    pos += len;
                  }
                  const callId = beginCall();
                  const callMsg = { 
                    type: 'call', 
                    module, 
                    name: `${name}_stderr`, 
                    args: [ array ],
                    callId,
                  };
                  if (sendFutex) {
                    callMsg.futex = futex;
                  }
                  port.postMessage(callMsg, [ array.buffer ]);
                  // write the length, assuming the operation will succeed in the main thread
                  if (is64) {
                    dv.setBigUint64(writtenAddr, BigInt(total), true);
                  } else {
                    dv.setUint32(writtenAddr, total, true);
                  }
                  // block for only up to 50ms
                  return wait(callId, 50000);
                } else {
                  return write(fd, iovsAddress, iovsCount, writtenAddress);
                }
              };
            }
          }
        }
        if (options?.tableInitial) {
          imports.env.__indirect_function_table = options.table64
            ? new WA.Table({
                initial: BigInt(options.tableInitial),
                element: 'anyfunc',
                address: 'i64',
              })
            : new WA.Table({
                initial: options.tableInitial,
                element: 'anyfunc',
              });
        }
        instance = new WA.Instance(executable, imports)
      } break;
      case 'run': {
        // catch thread termination exception
        try {
          instance.exports.wasi_thread_start(msg.tid, msg.taddr);
          port.postMessage({ type: 'done' });
        } catch (err) {
          // abnormal exit--clen
          port.postMessage({ type: 'terminate' });
      }
      } break;
      case 'end': {
        port.close();
      } break;
    }
  }
}
/* c8 ignore end */
