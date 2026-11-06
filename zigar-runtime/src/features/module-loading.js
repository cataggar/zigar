import { PosixError } from '../constants.js';
import { mixin } from '../environment.js';
import { decodeText, defineProperty, defineValue, empty, isPromise } from '../utils.js';

const WA = WebAssembly;

export default mixin({
  init() {
    this.abandoned = false;
    this.destructors = [];
    if (process.env.TARGET === 'wasm') {
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
      this.useJSPI = false;
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
  ...(process.env.TARGET === 'wasm' ? {
    imports: {
      initialize: { argType: '' },
    },
    exports: {
      displayPanic: { argType: 'ii' },
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
        case 's': return this.valueMap.get(arg);
        case 'i': return arg;
        case 'b': return !!arg;
      }
    },
    toWebAssembly(type, arg) {
      switch (type) {
        case 'v':
        case 's': return this.getObjectIndex(arg);
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
      return (this.useJSPI && name === 'handleJscall') ? this.wrapSuspending(wrapper) : wrapper;
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
        const savedSp = spGlobal ? spGlobal.value : 0;
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
            spGlobal.value = cont ? cont.parentSp : this.initialStackPointer;
          }
          this.activeContinuation = cont ? cont.parentContinuation : null;
          if (cont) {
            cont.parentContinuation = null;
            cont.parentSp = this.initialStackPointer;
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
              cont.parentSp = spGlobal ? spGlobal.value : this.initialStackPointer;
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
      const size = (this.continuationStackSize + 15) & ~15;
      const address = this.allocateScratchMemory(size, 16);
      if (!address) {
        throw new Error('Out of memory');
      }
      if (this.memory && address + 4 <= this.memory.buffer.byteLength) {
        const dv = new DataView(this.memory.buffer, address, 4);
        dv.setUint32(0, 0xdeadbeef, true);
      }
      return { address, size };
    },
    freeContinuationStack(stack) {
      if (this.memory && stack.address + 4 <= this.memory.buffer.byteLength) {
        const dv = new DataView(this.memory.buffer, stack.address, 4);
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
      const prevCont = this.activeContinuation;
      if (prevCont && spGlobal) {
        prevCont.sp = spGlobal.value;
      }
      const stack = (spGlobal && this.allocateScratchMemory) ? this.allocateContinuationStack() : null;
      const stackTop = stack ? stack.address + stack.size : 0;
      let finished = false;
      const cont = {
        stack,
        sp: stackTop,
        parentSp: spGlobal ? spGlobal.value : 0,
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
      for (const [ name, { argType, returnType, alias } ] of Object.entries(this.exports)) {
        const fn = this[alias ?? name];
        if (fn) {
          imports[`_${name}`] = this.exportFunction(fn, argType, returnType, name);
        }
      }
      return imports;
    },
    importFunctions(exports) {
      if (!this.memory) {
        this.memory = exports.memory;
      }
      if (exports.__stack_pointer) {
        this.stackPointerGlobal = exports.__stack_pointer;
        this.initialStackPointer = exports.__stack_pointer.value;
        if (!this.options?.continuationStackSize && this.initialStackPointer > 0) {
          this.continuationStackSize = (this.initialStackPointer + 15) & ~15;
        }
      }
      for (const [ name, { argType, returnType } ] of Object.entries(this.imports)) {
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
        for (const { address, size } of this.continuationStackPool) {
          exports.freeScratchMemory?.(address, size, 16);
        }
        this.continuationStackPool.length = 0;
        this.activeContinuation = null;
        this.suspendedContinuationCount = 0;
      });
    },
    async instantiateWebAssembly(source, options) {
      const {
        memoryInitial,
        memoryMax,
        tableInitial,
        multithreaded,
        useJSPI = false,
        continuationStackSize,
      } = this.options = options;
      this.useJSPI = Boolean(useJSPI && typeof WA.Suspending === 'function' && typeof WA.promising === 'function');
      if (continuationStackSize) {
        this.continuationStackSize = (continuationStackSize + 15) & ~15;
      }
      const res = await source;
      const suffix = (res[Symbol.toStringTag] === 'Response') ? /* c8 ignore next */ 'Streaming' : '';
      const f = WA['compile' + suffix];
      const executable = this.executable = await f(res);
      const functions = this.exportFunctions();
      const env = {}, wasi = {}, wasiPreview = {};
      const exports = this.exportedModules = { env, wasi, wasi_snapshot_preview1: wasiPreview };
      for (const { module, name, kind } of WA.Module.imports(executable)) {
        if (kind === 'function') {
          if (module === 'env') {
            env[name] = functions[name] ?? /* c8 ignore next */ empty;
          } else if (module === 'wasi_snapshot_preview1') {
            wasiPreview[name] = this.getWASIHandler(name);
            if (name === 'fd_write') {
              wasiPreview[`${name}_stderr`] = this.getWASIHandler(`${name}_stderr`);
            }
          } else if (module === 'wasi') {
            wasi[name] = this.getThreadHandler?.(name) ?? /* c8 ignore next */ empty;
          }
        }
      }
      debugger;
      if (memoryInitial) {
        this.memory = env.memory = new WA.Memory({
          initial: memoryInitial,
          maximum: memoryMax,
          shared: multithreaded,
        });
      }
      if (tableInitial) {
        this.table = env.__indirect_function_table = new WA.Table({
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
      const fn = (...args) => {
        const callArgs = (this.activeContinuation && method && args.length < method.length)
        ? [ ...args, true ]
        : args;
        const result = handler?.(...callArgs) ?? PosixError.ENOTSUP;
        const onResult = (result) => {
          if (result === PosixError.ENOTSUP || result === PosixError.ENOTCAPABLE) {
            // the handler has is either missing or has declined to deal with it, 
            // try with the method from the programmer supplied WASI interface
            if (result === PosixError.ENOTSUP) {
              const custom = this.customWASI?.wasiImport?.[name];
              if (custom) {
                return custom(...args);
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
      return (this.useJSPI && name !== 'proc_exit') ? this.wrapSuspending(fn) : fn;
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
            return (name === 'exports') ? exportsPlusMemory : /* c8 ignore next */ inst[name];
          }
        });
        wasi.initialize?.(instanceProxy);
      }
    },
    displayPanic(address, len) {
      const array = new Uint8Array(this.memory.buffer, address, len);
      const msg = decodeText(array);
      console.error(`Zig panic: ${msg}`);
    },
  } : process.env.TARGET === 'node' ? {
    imports: {
      loadModule: {},
    },

    exportFunctions() {
      const imports = {};
      for (const [ name, attributes ] of Object.entries(this.exports)) {
        const { 
          async: canReturnPromise = false,
        } = attributes;
        let fn = this[name];
        if (fn) {
          if (canReturnPromise) {
            fn = this.addPromiseHandling(fn);
          }
          imports[name] = fn.bind(this);
        }
      }
      return imports;
    },
    addPromiseHandling(fn) {
      const futexIndex = fn.length - 1;
      return function(...args) {
        const futexHandle = args[futexIndex];
        const canWait = !!futexHandle;
        // replace futexHandle with canWait in the argument list
        args[futexIndex] = canWait;
        const result = fn.call(this, ...args);
        if (canWait) {
          if (isPromise(result)) {
            result.then(result => this.finalizeAsyncCall(futexHandle, result));
          } else {
            this.finalizeAsyncCall(futexHandle, result);
          }
        } else {
          return result;
        }
        return PosixError.NONE;
      }
    },
    importFunctions(exports) {
      for (const [ name ] of Object.entries(this.imports)) {
        const fn = exports[name];
        if (fn) {
          defineProperty(this, name, defineValue(fn));
          this.destructors.push(() => this[name] = throwError);
        }
      }
    },
  /* c8 ignore next */
  } : undefined),
  /* c8 ignore start */
  ...(process.env.DEV ? {
    diagModuleLoading() {
      const targetSpecific = (process.env.TARGET === 'wasm') ? [
        `Value count: ${this.valueMap.size}`,
        `WASM memory: ${this.memory?.buffer?.byteLength}`,
        `WASM table: ${this.table?.length}`,
      ] : [];
      this.showDiagnostics('Module loading', [
        `Abandoned: ${this.abandoned}`,
        ...targetSpecific,
      ]);
    }
  } : undefined),
  /* c8 ignore end */
});

const throwError = () => { throw new Error(`Module was abandoned`) };
