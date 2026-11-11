import { PosixError } from '../constants.js';
import { mixin } from '../environment.js';
import { toBufferOffset, decodeText, empty, defineProperty, defineValue, isPromise, safeInt } from '../utils.js';

const WA = WebAssembly;
const ETIMEDOUT = PosixError.ETIMEDOUT ?? 73;

const PURE_SYNC_WASI_IMPORTS = new Set([
  'clock_res_get',
  'clock_time_get',
  'environ_get',
  'environ_sizes_get',
  'random_get',
  'fd_fdstat_get',
  'fd_prestat_get',
  'fd_prestat_dir_name',
]);

const WASI64_BIGINT_ARGS = {
  clock_time_get: 1 << 1,
  fd_advise: (1 << 1) | (1 << 2),
  fd_allocate: (1 << 1) | (1 << 2),
  fd_fdstat_set_rights: (1 << 1) | (1 << 2),
  fd_filestat_set_size: 1 << 1,
  fd_filestat_set_times: (1 << 1) | (1 << 2),
  fd_pread: 1 << 3,
  fd_pwrite: 1 << 3,
  fd_readdir: 1 << 3,
  fd_seek: 1 << 1,
  path_filestat_set_size: 1 << 4,
  path_filestat_set_times: (1 << 4) | (1 << 5),
  path_open: (1 << 5) | (1 << 6),
};

const WASM_IMPORT_SIGNATURES = {
  runThunk: { argType: 'aaa', returnType: 'b' },
  runVariadicThunk: { argType: 'aaaaz', returnType: 'b' },
  createJsThunk: { argType: 'az', returnType: 'a' },
  destroyJsThunk: { argType: 'aa', returnType: 'z' },
  finalizeAsyncCall: { argType: 'ai' },
};

const WASM_EXPORT_SIGNATURES = {
  handleJscall: { argType: 'zazb', returnType: 'i' },
  releaseFunction: { argType: 'z' },
};

var moduleLoading = mixin({
  init() {
    this.abandoned = false;
    this.destructors = [];
    {
      this.nextValueIndex = 1;
      this.valueMap = new Map();
      this.valueIndices = new Map();
      this.options = null;
      this.executable = null;
      this.instance = null;
      this.memory = null;
      this.table = null;
      this.initialTableLength = 0;
      this.exportedFunctions = null;
      this.customWASI = null;
      this.useResizableBuffer = true;
      this.usingResizableBuffer = false;
      this.useJSPI = false;
      this.jspiMode = false;
      this.syncFuncSet = null;
      this.asyncExportSet = null;
      this.pendingFutexTimers = new Set();
      this.continuationStackSize = 65536;
      this.continuationStackPool = [];
      this.activeContinuation = null;
      this.suspendedContinuationCount = 0;
      this.stackPointerGlobal = null;
      this.initialStackPointer = 0;
    }
  },
  abandonModule() {
    if (!this.abandoned) {
      for (const destructor of this.destructors.reverse()) {
        destructor();
      }
      this.abandoned = true;
    }
  },
  ...({
    imports: {
      initialize: { argType: '' },
    },
    exports: {
      displayPanic: { argType: 'az' },
      futexWaitAsync: { argType: 'aii', returnType: 'i' },
    },

    enableResizableMemory(memory) {
      this.usingResizableBuffer = false;
      if (this.useResizableBuffer !== false && typeof memory?.toResizableBuffer === 'function') {
        try {
          memory.toResizableBuffer();
          this.usingResizableBuffer = true;
        } catch {
          this.usingResizableBuffer = false;
        }
      }
    },
    getObjectIndex(object) {
      if (object != null) {
        let index = this.valueIndices.get(object);
        if (index === undefined) {
          index = this.nextValueIndex++;
          this.valueIndices.set(object, index);
          this.valueMap.set(index, object);
        }
        return index;
      } else {
        return 0;
      }
    },
    fromWebAssembly(type, arg) {
      switch (type) {
        case 'v':
        case 's': return this.valueMap.get(Number(arg));
        case 'a': return this.memory64 ? BigInt.asUintN(64, BigInt(arg)) : (Number(arg) >>> 0);
        case 'z': return (typeof arg === 'bigint') ? Number(BigInt.asUintN(64, arg)) : (Number(arg) >>> 0);
        case 'i': return arg;
        case 'b': return !!arg;
      }
    },
    toWebAssembly(type, arg) {
      switch (type) {
        case 'v':
        case 's': {
          const idx = this.getObjectIndex(arg);
          return this.memory64 ? BigInt(idx) : idx;
        }
        case 'a':
        case 'z': return this.memory64 ? BigInt(arg ?? 0) : Number(arg ?? 0);
        case 'i': return arg;
        case 'b': return arg ? 1 : 0;
      }
    },
    exportFunction(fn, argType = '', returnType = '', name) {
      if (!fn) {
        return () => {};
      }
      const wrapper = (...args) => {
        args = args.map((arg, i) => this.fromWebAssembly(argType.charAt(i), arg));
        const retval = fn.apply(this, args);
        return isPromise(retval)
        ? retval.then(v => this.toWebAssembly(returnType, v))
        : this.toWebAssembly(returnType, retval);
      };
      return (this.useJSPI && (name === 'handleJscall' || name === 'futexWaitAsync'))
        ? this.wrapSuspending(wrapper)
        : wrapper;
    },
    importFunction(fn, argType = '', returnType = '') {
      return (...args) => {
        args = args.map((arg, i) => this.toWebAssembly(argType.charAt(i), arg));
        const retval = fn.apply(this, args);
        return isPromise(retval)
        ? retval.then(v => this.fromWebAssembly(returnType, v))
        : this.fromWebAssembly(returnType, retval);
      };
    },
    wrapSuspending(fn) {
      const hasSuspending = typeof WA.Suspending === 'function';
      const wrapper = (...args) => {
        const cont = this.activeContinuation;
        const spGlobal = this.stackPointerGlobal;
        const isSp64 = typeof spGlobal?.value === 'bigint';
        const defaultSp = isSp64 ? BigInt(this.initialStackPointer) : this.initialStackPointer;
        const savedSp = spGlobal ? spGlobal.value : defaultSp;
        if (cont && spGlobal) {
          cont.sp = savedSp;
        }
        let res;
        try {
          res = fn(...args);
        } catch (err) {
          this.activeContinuation = cont;
          if (cont && spGlobal) {
            spGlobal.value = savedSp;
          }
          throw err;
        }
        if (isPromise(res) || (cont && hasSuspending)) {
          if (cont) {
            cont.sp = savedSp;
            if (!cont.suspended) {
              cont.suspended = true;
              this.suspendedContinuationCount++;
            }
          }
          if (spGlobal) {
            spGlobal.value = cont ? cont.parentSp : defaultSp;
          }
          this.activeContinuation = cont ? cont.parentContinuation : null;
          if (cont) {
            cont.parentContinuation = null;
            cont.parentSp = defaultSp;
          }
          const resumeContinuation = () => {
            if (this.activeContinuation && this.activeContinuation !== cont && !this.activeContinuation.suspended) {
              this.activeContinuation.finish?.();
            }
            if (cont) {
              if (cont.suspended) {
                cont.suspended = false;
                this.suspendedContinuationCount--;
              }
              cont.parentSp = spGlobal ? spGlobal.value : defaultSp;
              cont.parentContinuation = null;
              if (spGlobal) {
                spGlobal.value = cont.sp;
              }
            }
            this.activeContinuation = cont;
          };
          const promise = isPromise(res) ? res : Promise.resolve(res);
          return promise.then((val) => {
            resumeContinuation();
            return val;
          }, (err) => {
            resumeContinuation();
            throw err;
          });
        }
        this.activeContinuation = cont;
        if (cont && spGlobal) {
          spGlobal.value = savedSp;
        }
        return res;
      };
      return hasSuspending ? new WA.Suspending(wrapper) : wrapper;
    },
    allocateContinuationStack() {
      if (this.continuationStackPool.length > 0) {
        return this.continuationStackPool.pop();
      }
      const size = (this.continuationStackSize + 15) & -16;
      const address = this.allocateScratchMemory(size, 16);
      if (!address) {
        throw new Error('Out of memory');
      }
      const offset = toBufferOffset(address);
      if (this.memory && offset + 4 <= this.memory.buffer.byteLength) {
        const dv = new DataView(this.memory.buffer, offset, 4);
        dv.setUint32(0, 0xdeadbeef, true);
      }
      return { address, size };
    },
    freeContinuationStack(stack) {
      const offset = toBufferOffset(stack.address);
      if (this.memory && offset + 4 <= this.memory.buffer.byteLength) {
        const dv = new DataView(this.memory.buffer, offset, 4);
        if (dv.getUint32(0, true) !== 0xdeadbeef) {
          this.freeScratchMemory?.(stack.address, stack.size, 16);
          throw new Error('Stack overflow');
        }
      }
      if (this.continuationStackPool.length < 16) {
        this.continuationStackPool.push(stack);
      } else {
        this.freeScratchMemory?.(stack.address, stack.size, 16);
      }
    },
    runWithContinuation(fn) {
      const spGlobal = this.stackPointerGlobal;
      if (!spGlobal && this.suspendedContinuationCount > 0) {
        throw new Error('Concurrent JSPI calls require __stack_pointer export');
      }
      const isSp64 = typeof spGlobal?.value === 'bigint';
      const prevCont = this.activeContinuation;
      if (prevCont && spGlobal) {
        prevCont.sp = spGlobal.value;
      }
      const stack = (spGlobal && this.allocateScratchMemory) ? this.allocateContinuationStack() : null;
      const stackTop = stack
        ? (isSp64 ? BigInt(stack.address) + BigInt(stack.size) : Number(stack.address) + stack.size)
        : (isSp64 ? 0n : 0);
      let finished = false;
      const cont = {
        stack,
        sp: stackTop,
        parentSp: spGlobal ? spGlobal.value : (isSp64 ? 0n : 0),
        parentContinuation: prevCont,
        suspended: false,
        finish: null,
      };
      const finish = cont.finish = () => {
        if (finished) return;
        finished = true;
        if (cont.suspended) {
          cont.suspended = false;
          this.suspendedContinuationCount--;
        }
        let overflowError = null;
        if (stack) {
          try {
            this.freeContinuationStack(stack);
          } catch (err) {
            overflowError = err;
          }
        }
        if (this.activeContinuation === cont) {
          this.activeContinuation = cont.parentContinuation;
          if (spGlobal) {
            spGlobal.value = cont.parentSp;
          }
        }
        if (overflowError) {
          throw overflowError;
        }
      };
      this.activeContinuation = cont;
      if (stack && spGlobal) {
        spGlobal.value = stackTop;
      }
      let res;
      try {
        res = fn();
      } catch (err) {
        finish();
        throw err;
      }
      if (!cont.suspended) {
        finish();
      }
      if (isPromise(res)) {
        return res.then((val) => {
          finish();
          return val;
        }, (err) => {
          finish();
          throw err;
        });
      }
      finish();
      return res;
    },
    exportFunctions() {
      const imports = {};
      for (const [ name, spec ] of Object.entries(this.exports)) {
        const override = WASM_EXPORT_SIGNATURES[name];
        const argType = override?.argType ?? spec.argType;
        const returnType = override?.returnType ?? spec.returnType;
        const fn = this[spec.alias ?? name];
        if (fn) {
          imports[`_${name}`] = this.exportFunction(fn, argType, returnType, name);
        }
      }
      return imports;
    },
    importFunctions(exports) {
      if (!this.memory && exports.memory) {
        this.memory = exports.memory;
        this.enableResizableMemory(this.memory);
      }
      if (!this.table && exports.__indirect_function_table) {
        this.table = exports.__indirect_function_table;
        if (!this.initialTableLength) {
          this.initialTableLength = Number(this.table.length);
        }
        if (this.options?.table64 === undefined && typeof this.table.length === 'bigint') {
          this.table64 = true;
        }
      }
      if (this.options?.memory64 === undefined && !this.memory64 && typeof exports.__stack_pointer?.value === 'bigint') {
        this.memory64 = true;
      }
      if (exports.__stack_pointer) {
        this.stackPointerGlobal = exports.__stack_pointer;
        this.initialStackPointer = exports.__stack_pointer.value;
        const spNum = Number(this.initialStackPointer);
        if (!this.options?.continuationStackSize && spNum > 0) {
          this.continuationStackSize = (spNum + 15) & -16;
        }
      }
      const freeScratch = exports.freeScratchMemory
        ? this.importFunction(exports.freeScratchMemory, 'azi')
        : null;
      for (const [ name, spec ] of Object.entries(this.imports)) {
        const override = WASM_IMPORT_SIGNATURES[name];
        const argType = override?.argType ?? spec.argType;
        const returnType = override?.returnType ?? spec.returnType;
        let fn = exports[name];
        if (fn) {
          if (this.useJSPI && (name === 'runThunk' || name === 'runVariadicThunk') && typeof WA.promising === 'function') {
            defineProperty(this, `${name}Sync`, defineValue(this.importFunction(fn, argType, returnType)));
            this.destructors.push(() => this[`${name}Sync`] = throwError);
            const promisingFn = WA.promising(fn);
            fn = (...args) => this.runWithContinuation(() => promisingFn(...args));
          }
          defineProperty(this, name, defineValue(this.importFunction(fn, argType, returnType)));
          this.destructors.push(() => this[name] = throwError);
        }
      }
      this.destructors.push(() => {
        for (const timer of this.pendingFutexTimers) {
          clearInterval(timer);
        }
        this.pendingFutexTimers.clear();
        for (const { address, size } of this.continuationStackPool) {
          freeScratch?.(address, size, 16);
        }
        this.continuationStackPool.length = 0;
        this.activeContinuation = null;
        this.suspendedContinuationCount = 0;
      });
    },
    async instantiateWebAssembly(source, options = {}) {
      const {
        memoryInitial,
        memoryMax,
        tableInitial,
        multithreaded,
        memory64,
        table64,
        useResizableBuffer = true,
        useJSPI = false,
        continuationStackSize,
        syncFunctions,
        syncTableIndices,
      } = this.options = options;
      this.useResizableBuffer = useResizableBuffer;
      this.usingResizableBuffer = false;
      if (memory64 !== undefined) {
        this.memory64 = Boolean(memory64);
        this.table64 = Boolean(table64 ?? memory64);
      } else if (table64 !== undefined) {
        this.table64 = Boolean(table64);
      }
      const jspiSupported = typeof WA.Suspending === 'function' && typeof WA.promising === 'function';
      this.useJSPI = Boolean(useJSPI && jspiSupported);
      this.jspiMode = !this.useJSPI
        ? false
        : (useJSPI === 'all')
          ? 'all'
          : Array.isArray(useJSPI)
            ? 'list'
            : 'auto';
      const syncList = syncFunctions ?? syncTableIndices;
      this.syncFuncSet = (this.useJSPI && syncList) ? new Set(syncList.map(Number)) : null;
      this.asyncExportSet = (this.useJSPI && Array.isArray(useJSPI)) ? new Set(useJSPI) : null;
      if (continuationStackSize) {
        this.continuationStackSize = (continuationStackSize + 15) & -16;
      }
      const res = await source;
      if (memory64 === undefined) {
        const detected = detectWasm64(res);
        if (detected) {
          if (detected.memory64) {
            this.memory64 = true;
          }
          if (table64 === undefined && detected.table64) {
            this.table64 = true;
          }
        }
      }
      const suffix = (res[Symbol.toStringTag] === 'Response') ? 'Streaming' : '';
      const f = WA['compile' + suffix];
      const executable = this.executable = await f(res);
      const functions = this.exportFunctions();
      const env = {}, wasi = {}, wasiPreview = {};
      const exports = this.exportedModules = { env, wasi, wasi_snapshot_preview1: wasiPreview };
      for (const { module, name, kind } of WA.Module.imports(executable)) {
        if (kind === 'function') {
          if (module === 'env') {
            env[name] = functions[name] ?? empty;
          } else if (module === 'wasi_snapshot_preview1') {
            wasiPreview[name] = this.getWASIHandler(name);
            if (name === 'fd_write') {
              wasiPreview[`${name}_stderr`] = this.getWASIHandler(`${name}_stderr`);
            }
          } else if (module === 'wasi') {
            wasi[name] = this.getThreadHandler?.(name) ?? empty;
          }
        }
      }
      debugger;
      if (memoryInitial) {
        this.memory = env.memory = new WA.Memory(this.memory64 ? {
          initial: BigInt(memoryInitial),
          ...(memoryMax !== undefined ? { maximum: BigInt(memoryMax) } : undefined),
          shared: multithreaded,
          address: 'i64',
        } : {
          initial: memoryInitial,
          maximum: memoryMax,
          shared: multithreaded,
        });
        this.enableResizableMemory(this.memory);
      }
      if (tableInitial) {
        this.table = env.__indirect_function_table = new WA.Table(this.table64 ? {
          initial: BigInt(tableInitial),
          element: 'anyfunc',
          shared: multithreaded,
          address: 'i64',
        } : {
          initial: tableInitial,
          element: 'anyfunc',
          shared: multithreaded,
        });
      }
      this.initialTableLength = tableInitial;
      return WA.instantiate(executable, exports);
    },
    loadModule(source, options) {
      return this.initPromise = (async () => {
        const instance = this.instance = await this.instantiateWebAssembly(source, options);
        this.importFunctions(instance.exports);
        this.initializeCustomWASI();
        this.initialize();
      })();
    },
    getWASIHandler(name) {
      const nameCamelized = name.replace(/_./g, m => m.charAt(1).toUpperCase());
      const method = this[nameCamelized];
      const handler = method?.bind?.(this);
      const eventName = this[nameCamelized + 'Event'];
      const bigIntMask = WASI64_BIGINT_ARGS[name] ?? 0;
      const fn = (...rawArgs) => {
        const handlerArgs = this.memory64
          ? normalizeWASI64Args(rawArgs, bigIntMask)
          : rawArgs;
        const callArgs = (this.activeContinuation && method && handlerArgs.length < method.length)
        ? [ ...handlerArgs, true ]
        : handlerArgs;
        const result = handler?.(...callArgs) ?? PosixError.ENOTSUP;
        const onResult = (result) => {
          if (result === PosixError.ENOTSUP || result === PosixError.ENOTCAPABLE) {
            // the handler has is either missing or has declined to deal with it, 
            // try with the method from the programmer supplied WASI interface
            if (result === PosixError.ENOTSUP) {
              const custom = this.customWASI?.wasiImport?.[name];
              if (custom) {
                return custom(...rawArgs);
              }
            }
            // if we can't fallback onto a custom handler, explain the failure
            if (eventName) {
              console.error(`WASI method '${name}' requires the handling of the '${eventName}' event`);
            }
            return PosixError.ENOTSUP;
          }
          return result;
        };
        return isPromise(result) ? result.then(onResult) : onResult(result);
      };
      const shouldWrap = this.useJSPI && name !== 'proc_exit' && (
        this.jspiMode === 'all' || !!this.customWASI || !PURE_SYNC_WASI_IMPORTS.has(name)
      );
      return shouldWrap ? this.wrapSuspending(fn) : fn;
    },
    futexWaitAsync(address, expected, timeoutNs) {
      if (!this.activeContinuation || typeof Atomics.waitAsync !== 'function' || !(this.memory?.buffer instanceof SharedArrayBuffer)) {
        return PosixError.ENOTSUP;
      }
      const index = (typeof address === 'bigint')
        ? Number(BigInt.asUintN(64, address) >> 2n)
        : (Number(address) >>> 2);
      const timeoutMs = (timeoutNs < 0) ? Infinity : Number(timeoutNs) / 1e6;
      const res = Atomics.waitAsync(new Int32Array(this.memory.buffer), index, Number(expected) | 0, timeoutMs);
      if (!res.async) {
        return (res.value === 'timed-out') ? ETIMEDOUT : PosixError.NONE;
      }
      const keepAlive = setInterval(empty, 0x3fffffff);
      this.pendingFutexTimers.add(keepAlive);
      const clearKeepAlive = () => {
        clearInterval(keepAlive);
        this.pendingFutexTimers.delete(keepAlive);
      };
      return res.value.then((v) => {
        clearKeepAlive();
        return (v === 'timed-out') ? ETIMEDOUT : PosixError.NONE;
      }, (err) => {
        clearKeepAlive();
        throw err;
      });
    },
    setCustomWASI(wasi) {
      this.customWASI = wasi;
      if (this.instance) {
        this.initializeCustomWASI();
      }
    },
    initializeCustomWASI() {
      const wasi = this.customWASI;
      if (wasi) {
        // use a proxy to attach the memory object to the list of exports
        const exportsPlusMemory = { ...this.instance.exports, memory: this.memory };
        const instanceProxy = new Proxy(this.instance, {
          get(inst, name) {
            return (name === 'exports') ? exportsPlusMemory : inst[name];
          }
        });
        wasi.initialize?.(instanceProxy);
      }
    },
    displayPanic(address, len) {
      const array = new Uint8Array(this.memory.buffer, toBufferOffset(address), Number(len));
      const msg = decodeText(array);
      console.error(`Zig panic: ${msg}`);
    },
  } ),
});

const throwError = () => { throw new Error(`Module was abandoned`) };

function normalizeWASI64Args(args, bigIntMask) {
  return args.map((arg, index) => {
    if (typeof arg !== 'bigint' || (bigIntMask & (1 << index))) {
      return arg;
    }
    const u = BigInt.asUintN(64, arg);
    if (u === 0xaaaa_aaaa_aaaa_aaaan) {
      return 0xaaaa_aaaa;
    }
    if (u === 0xffff_ffff_ffff_ffffn) {
      return -1;
    }
    return safeInt(u);
  });
}

function detectWasm64(source) {
  let bytes;
  if (source instanceof ArrayBuffer) {
    bytes = new Uint8Array(source);
  } else if (ArrayBuffer.isView(source)) {
    bytes = new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
  } else {
    return null;
  }
  if (bytes.length < 8 || bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
    return null;
  }
  let pos = 8;
  const readUleb = () => {
    let result = 0, shift = 0;
    while (pos < bytes.length) {
      const byte = bytes[pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) return result >>> 0;
      shift += 7;
    }
    return result >>> 0;
  };
  const skipLeb = () => {
    while (pos < bytes.length && (bytes[pos++] & 0x80) !== 0) {}
  };
  let memory64 = false;
  let table64 = false;
  try {
    while (pos < bytes.length) {
      const sectionId = bytes[pos++];
      const sectionSize = readUleb();
      const sectionEnd = pos + sectionSize;
      if (sectionEnd > bytes.length) break;
      if (sectionId === 2) {
        const count = readUleb();
        for (let i = 0; i < count && pos < sectionEnd; i++) {
          const modLen = readUleb();
          pos += modLen;
          const nameLen = readUleb();
          pos += nameLen;
          const kind = bytes[pos++];
          if (kind === 0) {
            skipLeb();
          } else if (kind === 1) {
            const rt = bytes[pos++];
            if (rt === 0x63 || rt === 0x64) skipLeb();
            const flags = readUleb();
            if (flags & 0x04) table64 = true;
            skipLeb();
            if (flags & 0x01) skipLeb();
          } else if (kind === 2) {
            const flags = readUleb();
            if (flags & 0x04) memory64 = true;
            skipLeb();
            if (flags & 0x01) skipLeb();
          } else if (kind === 3) {
            const vt = bytes[pos++];
            if (vt === 0x63 || vt === 0x64) skipLeb();
            pos += 1;
          } else if (kind === 4) {
            pos += 1;
            skipLeb();
          } else {
            break;
          }
        }
      } else if (sectionId === 4) {
        const count = readUleb();
        if (count > 0 && pos < sectionEnd) {
          const b0 = bytes[pos++];
          if (b0 === 0x40) {
            pos += 1;
            const rt = bytes[pos++];
            if (rt === 0x63 || rt === 0x64) skipLeb();
          } else if (b0 === 0x63 || b0 === 0x64) {
            skipLeb();
          }
          const flags = readUleb();
          if (flags & 0x04) table64 = true;
        }
      } else if (sectionId === 5) {
        const count = readUleb();
        if (count > 0 && pos < sectionEnd) {
          const flags = readUleb();
          if (flags & 0x04) memory64 = true;
        }
      }
      if (sectionId >= 5) break;
      pos = sectionEnd;
    }
  } catch {
  }
  return { memory64, table64 };
}

export { PURE_SYNC_WASI_IMPORTS, WASI64_BIGINT_ARGS, moduleLoading as default };
