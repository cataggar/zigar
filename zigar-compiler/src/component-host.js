import { closeSync, readFileSync, readSync, writeSync } from 'node:fs';
import { WASI } from 'node:wasi';

const textDecoder = new TextDecoder('utf-8');
const textEncoder = new TextEncoder();

// CoreVal tags shared across WasmExternBackend, ZigarCallbacksBackend, and --rpc-stdio:
//   0 = void, 1 = i32, 2 = i64, 3 = f32, 4 = f64
export const CORE_VAL_VOID = 0;
export const CORE_VAL_I32 = 1;
export const CORE_VAL_I64 = 2;
export const CORE_VAL_F32 = 3;
export const CORE_VAL_F64 = 4;

export const COMPONENT_HOST_REGISTRY_SYMBOL = Symbol.for('zigar.componentHosts');

/**
 * Shared per-process registry mapping numeric `instanceId` -> live `ComponentHost`
 * so `zigar-runtime` WASM modules can invoke `instantiateComponentHost(...)` instances
 * via `extern "zigar:component-host"` (`WasmExternBackend`) without custom loader glue.
 */
export function getComponentHostRegistry() {
  let reg = globalThis[COMPONENT_HOST_REGISTRY_SYMBOL];
  if (!reg) {
    reg = {
      nextId: 1,
      hosts: new Map(),
    };
    Object.defineProperty(globalThis, COMPONENT_HOST_REGISTRY_SYMBOL, {
      value: reg,
      configurable: true,
      enumerable: false,
      writable: false,
    });
  }
  return reg;
}

// Binary RPC opcodes for native Zig <-> Node 26 V8 WebAssembly stdio bridge
const OP_ALLOC = 0x01;
const OP_WRITE = 0x02;
const OP_ALLOC_WRITE = 0x03;
const OP_READ = 0x04;
const OP_MEM_SIZE = 0x05;
const OP_CALL_CORE = 0x06;
const OP_POST_RETURN = 0x07;
const OP_RESOURCE_NEW = 0x08;
const OP_RESOURCE_REP = 0x09;
const OP_RESOURCE_DROP = 0x0a;
const OP_LIVE_RESOURCES = 0x0b;
const OP_SHUTDOWN = 0xff;

const RPC_MAGIC = [0x5a, 0x43, 0x48, 0x31]; // "ZCH1"

/**
 * Convert a signed 32-bit Wasm linear-memory pointer/offset into an unsigned
 * 32-bit JS integer (`0 .. 0xffff_ffff`), preventing negative-offset `RangeError`
 * when guest linear memory grows past 2 GiB (`0x8000_0000`, `nodejs/node#62671`).
 */
export function toUnsignedPtr(ptr) {
  return Number(ptr) >>> 0;
}

/**
 * Create a bounds-checked `Uint8Array` view over `buffer` using unsigned 32-bit
 * pointer and length conversion safe across `>= 2 GiB` (`0x8000_0000+`) offsets.
 */
export function sliceMemoryU8(buffer, ptr, len) {
  const start = toUnsignedPtr(ptr);
  const byteLength = toUnsignedPtr(len);
  if (start + byteLength > buffer.byteLength) {
    throw new RangeError(
      `Guest memory access out of bounds: offset=${start} len=${byteLength} size=${buffer.byteLength}`,
    );
  }
  return new Uint8Array(buffer, start, byteLength);
}

/**
 * Wrap a `wasi_snapshot_preview1` import object so every numeric Wasm `i32`
 * pointer/size argument is converted to unsigned `u32` (`>>> 0`) before invoking
 * Node's native WASI implementation, preserving `BigInt` `i64` parameters.
 */
export function wrapWasiImportsUnsigned(rawWasi) {
  const wrapped = {};
  for (const [name, fn] of Object.entries(rawWasi)) {
    if (typeof fn === 'function') {
      wrapped[name] = (...args) =>
        fn(...args.map((arg) => (typeof arg === 'number' ? arg >>> 0 : arg)));
    } else {
      wrapped[name] = fn;
    }
  }
  if (typeof wrapped.fd_write === 'function' && !wrapped['fd_write [v2]']) {
    wrapped['fd_write [v2]'] = wrapped.fd_write;
  }
  if (!wrapped.adapter_monotonic_clock_set_paused) {
    wrapped.adapter_monotonic_clock_set_paused = () => {};
  }
  return wrapped;
}

function readULEB128(bytes, state) {
  let result = 0;
  let shift = 0;
  while (true) {
    if (state.pos >= bytes.length) {
      throw new Error('Unexpected EOF reading LEB128');
    }
    const byte = bytes[state.pos++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) {
      return result >>> 0;
    }
    shift += 7;
  }
}

function readSLEB128(bytes, state) {
  let result = 0;
  let shift = 0;
  let byte;
  do {
    if (state.pos >= bytes.length) {
      throw new Error('Unexpected EOF reading signed LEB128');
    }
    byte = bytes[state.pos++];
    result |= (byte & 0x7f) << shift;
    shift += 7;
  } while (byte & 0x80);
  if (shift < 32 && (byte & 0x40) !== 0) {
    result |= (~0 << shift);
  }
  return result;
}

function readRawName(bytes, state) {
  const len = readULEB128(bytes, state);
  if (state.pos + len > bytes.length) {
    throw new Error('Unexpected EOF reading name');
  }
  const str = textDecoder.decode(bytes.subarray(state.pos, state.pos + len));
  state.pos += len;
  return str;
}

function readExternName(bytes, state) {
  const prefix = bytes[state.pos++];
  if (prefix > 0x02) {
    throw new Error(`Unsupported component externname prefix: 0x${prefix.toString(16)}`);
  }
  const name = readRawName(bytes, state);
  if (prefix === 0x02) {
    const attrCount = readULEB128(bytes, state);
    for (let i = 0; i < attrCount; i++) {
      state.pos++; // attr tag
      readRawName(bytes, state);
    }
  }
  return name;
}

function skipValType(bytes, state) {
  const raw = readSLEB128(bytes, state);
  if (raw < 0) {
    const tag = (raw + 0x80) & 0xff;
    // own (0x69) or borrow (0x68) carry a type index
    if (tag === 0x69 || tag === 0x68) {
      readULEB128(bytes, state);
    }
  }
}

function skipExternDesc(bytes, state) {
  const tag = bytes[state.pos++];
  switch (tag) {
    case 0x00: // core module: 0x11 <u32>
      state.pos++;
      readULEB128(bytes, state);
      break;
    case 0x01: // func: <u32>
    case 0x04: // component: <u32>
    case 0x05: // instance: <u32>
      readULEB128(bytes, state);
      break;
    case 0x02: // value: <valtype>
      skipValType(bytes, state);
      break;
    case 0x03: { // type: bound
      const boundTag = bytes[state.pos++];
      if (boundTag === 0x00) {
        readULEB128(bytes, state);
      }
      break;
    }
    default:
      throw new Error(`Unknown externdesc tag: 0x${tag.toString(16)}`);
  }
}

/**
 * Unpack a WebAssembly Component binary (`\0asm\x0d\x00\x01\x00`), extracting its
 * embedded core Wasm modules, core instance wiring plan, and top-level export names.
 */
export function unpackComponent(componentSource) {
  const bytes = componentSource instanceof Uint8Array
    ? componentSource
    : new Uint8Array(componentSource);

  if (bytes.byteLength < 8) {
    throw new Error('Component binary too short');
  }
  const expectedPreamble = [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
  for (let i = 0; i < 8; i++) {
    if (bytes[i] !== expectedPreamble[i]) {
      throw new Error(`Invalid WebAssembly Component preamble at byte ${i}`);
    }
  }

  const coreModules = [];
  const coreInstances = [];
  const componentExports = [];
  const state = { pos: 8 };

  while (state.pos < bytes.byteLength) {
    const sectionId = bytes[state.pos++];
    const sectionSize = readULEB128(bytes, state);
    const sectionEnd = state.pos + sectionSize;
    if (sectionEnd > bytes.byteLength) {
      throw new Error('Component section exceeds binary length');
    }

    if (sectionId === 1) {
      // Core module section
      coreModules.push(bytes.subarray(state.pos, sectionEnd));
    } else if (sectionId === 2) {
      // Core instance section
      const inner = { pos: state.pos };
      const count = readULEB128(bytes, inner);
      for (let i = 0; i < count; i++) {
        const kindTag = bytes[inner.pos++];
        if (kindTag === 0x00) {
          const moduleIndex = readULEB128(bytes, inner);
          const argCount = readULEB128(bytes, inner);
          const args = [];
          for (let j = 0; j < argCount; j++) {
            const name = readRawName(bytes, inner);
            inner.pos++; // 0x12 instance sort
            const instanceIndex = readULEB128(bytes, inner);
            args.push({ name, instanceIndex });
          }
          coreInstances.push({ kind: 'instantiate', moduleIndex, args });
        } else if (kindTag === 0x01) {
          const expCount = readULEB128(bytes, inner);
          const exports = [];
          for (let j = 0; j < expCount; j++) {
            const name = readRawName(bytes, inner);
            const sort = bytes[inner.pos++];
            const index = readULEB128(bytes, inner);
            exports.push({ name, sort, index });
          }
          coreInstances.push({ kind: 'exports', exports });
        } else {
          throw new Error(`Invalid core instance tag: 0x${kindTag.toString(16)}`);
        }
      }
    } else if (sectionId === 11) {
      // Component export section
      const inner = { pos: state.pos };
      const count = readULEB128(bytes, inner);
      for (let i = 0; i < count; i++) {
        const exportName = readExternName(bytes, inner);
        const sort = bytes[inner.pos++];
        if (sort === 0x00) {
          inner.pos++; // core sub-sort
        }
        readULEB128(bytes, inner); // sort idx
        const hasDesc = bytes[inner.pos++];
        if (hasDesc === 0x01) {
          skipExternDesc(bytes, inner);
        }
        componentExports.push(exportName);
      }
    }

    state.pos = sectionEnd;
  }

  return {
    coreModules,
    coreInstances,
    componentExports,
  };
}

/**
 * Unified host handle table tracking live WIT resources (`own<T>` / `borrow<T>`)
 * across all exported interfaces of a component instance.
 */
export class HostResourceTable {
  #nextHandle = 1;
  #entries = new Map();
  #dtors = new Map();
  mutationEpoch = 0;

  bindDtor(iface, resourceName, dtorFn) {
    if (typeof dtorFn !== 'function') return;
    if (iface) {
      this.#dtors.set(`${iface}#${resourceName}`, dtorFn);
    }
    if (!this.#dtors.has(resourceName)) {
      this.#dtors.set(resourceName, dtorFn);
    }
  }

  insert(iface, resourceName, rep) {
    const handle = this.#nextHandle++;
    this.#entries.set(handle, {
      iface: iface || '',
      resourceName,
      rep: toUnsignedPtr(rep),
    });
    this.mutationEpoch = (this.mutationEpoch + 1) >>> 0;
    return handle;
  }

  rep(iface, resourceName, handle) {
    const h = handle | 0;
    const entry = this.#entries.get(h);
    if (!entry) {
      throw new Error(`Invalid or dropped resource handle: ${h} (${resourceName || 'unknown'})`);
    }
    if (resourceName && entry.resourceName !== resourceName) {
      throw new Error(
        `Resource handle type mismatch for handle ${h}: expected '${resourceName}', found '${entry.resourceName}'`,
      );
    }
    return entry.rep | 0;
  }

  has(handle) {
    return this.#entries.has(handle | 0);
  }

  drop(iface, resourceName, handle) {
    const h = handle | 0;
    const entry = this.#entries.get(h);
    if (!entry) {
      throw new Error(`Double-drop or invalid resource handle: ${h} (${resourceName || 'unknown'})`);
    }
    if (resourceName && entry.resourceName !== resourceName) {
      throw new Error(
        `Resource handle type mismatch on drop for handle ${h}: expected '${resourceName}', found '${entry.resourceName}'`,
      );
    }
    this.#entries.delete(h);
    this.mutationEpoch = (this.mutationEpoch + 1) >>> 0;
    const dtor = this.#dtors.get(`${entry.iface}#${entry.resourceName}`) ??
      this.#dtors.get(entry.resourceName);
    if (dtor) {
      dtor(entry.rep | 0);
    }
  }

  get liveCount() {
    return this.#entries.size;
  }
}

function createResourceImportModule(resourceTable, ifaceName) {
  const cache = new Map();
  return new Proxy(
    {},
    {
      get(_target, prop) {
        if (typeof prop !== 'string') return undefined;
        let fn = cache.get(prop);
        if (fn) return fn;
        if (prop.startsWith('[resource-new]')) {
          const resName = prop.slice('[resource-new]'.length);
          fn = (rep) => resourceTable.insert(ifaceName, resName, rep);
        } else if (prop.startsWith('[resource-rep]')) {
          const resName = prop.slice('[resource-rep]'.length);
          fn = (handle) => resourceTable.rep(ifaceName, resName, handle);
        } else if (prop.startsWith('[resource-drop]')) {
          const resName = prop.slice('[resource-drop]'.length);
          fn = (handle) => resourceTable.drop(ifaceName, resName, handle);
        }
        if (fn) cache.set(prop, fn);
        return fn;
      },
    },
  );
}

const f32ScratchBuf = new ArrayBuffer(8);
const f32ScratchDV = new DataView(f32ScratchBuf);

function coreValToJsArg(tag, bitsBigInt) {
  switch (tag) {
    case CORE_VAL_I32:
      return Number(BigInt.asIntN(32, bitsBigInt));
    case CORE_VAL_I64:
      return BigInt.asIntN(64, bitsBigInt);
    case CORE_VAL_F32:
      f32ScratchDV.setUint32(0, Number(bitsBigInt & 0xffff_ffffn) >>> 0, true);
      return f32ScratchDV.getFloat32(0, true);
    case CORE_VAL_F64:
      f32ScratchDV.setBigUint64(0, BigInt.asUintN(64, bitsBigInt), true);
      return f32ScratchDV.getFloat64(0, true);
    default:
      throw new Error(`Invalid CoreVal tag: ${tag}`);
  }
}

function jsRetToCoreVal(raw, expectedRetTag) {
  if (expectedRetTag === CORE_VAL_VOID || raw === undefined) {
    return { tag: CORE_VAL_VOID, bits: 0n };
  }
  if (expectedRetTag === CORE_VAL_I64 || typeof raw === 'bigint') {
    return { tag: CORE_VAL_I64, bits: BigInt.asUintN(64, BigInt(raw)) };
  }
  if (expectedRetTag === CORE_VAL_F32) {
    f32ScratchDV.setFloat32(0, Number(raw), true);
    return { tag: CORE_VAL_F32, bits: BigInt(f32ScratchDV.getUint32(0, true)) };
  }
  if (expectedRetTag === CORE_VAL_F64) {
    f32ScratchDV.setFloat64(0, Number(raw), true);
    return { tag: CORE_VAL_F64, bits: f32ScratchDV.getBigUint64(0, true) };
  }
  return { tag: CORE_VAL_I32, bits: BigInt(Number(raw) >>> 0) };
}

/**
 * Instantiate a WebAssembly Component (`.component.wasm` produced by `componentize-go`
 * or WASI P1 reactor adapters) in Node.js 26 / V8 WebAssembly with:
 *   - Unsigned `>>> 0` WASI P1 pointer wrapping (`>= 2 GiB` linear memory safe),
 *   - Automatic `[export]<iface>` `[resource-new]` / `[resource-rep]` / `[resource-drop]`
 *     and `<iface>#[dtor]<res>` wiring,
 *   - Cross-memory Canonical ABI host primitives (`alloc`, `read`, `write`, `callCore`,
 *     `callPostReturn`, `createWasmImports`, `createZigarCallbacks`).
 */
export function instantiateComponentHost(wasmSourceOrPath, options = {}) {
  let componentBytes;
  if (typeof wasmSourceOrPath === 'string' || wasmSourceOrPath instanceof URL) {
    componentBytes = readFileSync(wasmSourceOrPath);
  } else if (wasmSourceOrPath instanceof Uint8Array) {
    componentBytes = wasmSourceOrPath;
  } else if (wasmSourceOrPath instanceof ArrayBuffer || ArrayBuffer.isView(wasmSourceOrPath)) {
    componentBytes = wasmSourceOrPath instanceof ArrayBuffer
      ? new Uint8Array(wasmSourceOrPath)
      : new Uint8Array(
        wasmSourceOrPath.buffer,
        wasmSourceOrPath.byteOffset,
        wasmSourceOrPath.byteLength,
      );
  } else {
    throw new TypeError('Expected file path, URL, Uint8Array, or ArrayBuffer for wasmSourceOrPath');
  }

  const unpacked = unpackComponent(componentBytes);
  if (unpacked.coreModules.length === 0) {
    throw new Error('Component contains no embedded core Wasm modules');
  }

  const compiledModules = unpacked.coreModules.map((bytes) => new WebAssembly.Module(bytes));

  // Locate primary guest reactor module (exports `memory` and `cabi_realloc` or `_initialize`)
  let primaryModuleIndex = 0;
  for (let i = 0; i < compiledModules.length; i++) {
    const exps = WebAssembly.Module.exports(compiledModules[i]);
    const hasMem = exps.some((e) => e.kind === 'memory' && e.name === 'memory');
    const hasReallocOrInit = exps.some(
      (e) => e.kind === 'function' && (e.name === 'cabi_realloc' || e.name === '_initialize'),
    );
    if (hasMem && hasReallocOrInit) {
      primaryModuleIndex = i;
      break;
    }
  }

  const wasiOptions = {
    version: 'preview1',
    ...(options.rpcStdio ? { stdout: 2, stderr: 2 } : {}),
    ...(options.wasiOptions || {}),
  };
  const wasi = new WASI(wasiOptions);
  const wrappedWasi = wrapWasiImportsUnsigned(wasi.wasiImport);
  const resourceTable = new HostResourceTable();

  const primaryMod = compiledModules[primaryModuleIndex];
  const importObject = { ...(options.imports || {}) };
  let usesWasi = false;

  // Check if helper table/shim modules exist in `coreInstances` for indirect imports
  const helperExportsByModule = new Map();
  for (let i = 0; i < compiledModules.length; i++) {
    if (i === primaryModuleIndex) continue;
    const modImports = WebAssembly.Module.imports(compiledModules[i]);
    if (modImports.length === 0) {
      const helperInstance = new WebAssembly.Instance(compiledModules[i], {});
      helperExportsByModule.set(i, helperInstance.exports);
    }
  }

  for (const imp of WebAssembly.Module.imports(primaryMod)) {
    if (imp.module === 'wasi_snapshot_preview1') {
      usesWasi = true;
      importObject.wasi_snapshot_preview1 = wrappedWasi;
    } else if (imp.module.startsWith('[export]')) {
      const ifaceName = imp.module.slice('[export]'.length);
      if (!importObject[imp.module]) {
        importObject[imp.module] = createResourceImportModule(resourceTable, ifaceName);
      }
    } else if (!importObject[imp.module]) {
      // Resolve from any zero-import helper table/shim module (e.g. `""` `$imports`)
      for (const helperExps of helperExportsByModule.values()) {
        if (imp.name in helperExps) {
          importObject[imp.module] ??= {};
          importObject[imp.module][imp.name] = helperExps[imp.name];
        }
      }
    }
  }

  const instance = new WebAssembly.Instance(primaryMod, importObject);
  const exp = instance.exports;

  // Bind all exported resource destructors (`<iface>#[dtor]<res>` or `[dtor]<res>`)
  for (const [expName, expVal] of Object.entries(exp)) {
    if (typeof expVal !== 'function') continue;
    const dtorIdx = expName.indexOf('#[dtor]');
    if (dtorIdx !== -1) {
      const iface = expName.slice(0, dtorIdx);
      const resName = expName.slice(dtorIdx + '#[dtor]'.length);
      resourceTable.bindDtor(iface, resName, expVal);
    } else if (expName.startsWith('[dtor]')) {
      const resName = expName.slice('[dtor]'.length);
      resourceTable.bindDtor('', resName, expVal);
    }
  }

  if (usesWasi && typeof exp._initialize === 'function') {
    wasi.initialize(instance);
  } else if (typeof exp._initialize === 'function') {
    exp._initialize();
  }

  const registry = getComponentHostRegistry();
  const instanceId = (
    options.instanceId !== undefined
      ? options.instanceId
      : options.register === false
        ? 0
        : registry.nextId++
  ) >>> 0;

  const host = {
    instanceId,
    unpacked,
    instance,
    exports: exp,
    resourceTable,

    dispose() {
      registry.hosts.delete(instanceId);
    },

    close() {
      registry.hosts.delete(instanceId);
    },

    get memory() {
      return exp.memory;
    },

    memoryByteLength() {
      return exp.memory.buffer.byteLength;
    },

    alloc(reallocExportName = 'cabi_realloc', align = 1, byteLen = 0) {
      const a = align >>> 0;
      const len = byteLen >>> 0;
      if (a === 0 || (a & (a - 1)) !== 0) {
        throw new Error(`Invalid Canonical ABI alignment: ${a}`);
      }
      if (len === 0) {
        return a;
      }
      const reallocFn = exp[reallocExportName || 'cabi_realloc'];
      if (typeof reallocFn !== 'function') {
        throw new Error(`Missing guest realloc export: ${reallocExportName}`);
      }
      const ptr = toUnsignedPtr(reallocFn(0, 0, a, len));
      if (a > 1 && (ptr % a) !== 0) {
        throw new Error(`Unaligned pointer returned by ${reallocExportName}: 0x${ptr.toString(16)} (align ${a})`);
      }
      if (ptr + len > exp.memory.buffer.byteLength) {
        throw new RangeError(
          `Pointer returned by ${reallocExportName} out of bounds: ptr=${ptr} len=${len} mem=${exp.memory.buffer.byteLength}`,
        );
      }
      return ptr;
    },

    write(guestAddr, srcBytes) {
      if (srcBytes.byteLength === 0) {
        const addr = toUnsignedPtr(guestAddr);
        if (addr > exp.memory.buffer.byteLength) {
          throw new RangeError(`Write address out of bounds: ${addr} > ${exp.memory.buffer.byteLength}`);
        }
        return;
      }
      sliceMemoryU8(exp.memory.buffer, guestAddr, srcBytes.byteLength).set(srcBytes);
    },

    allocAndWrite(reallocExportName, align, srcBytes) {
      const ptr = this.alloc(reallocExportName, align, srcBytes.byteLength);
      if (srcBytes.byteLength > 0) {
        sliceMemoryU8(exp.memory.buffer, ptr, srcBytes.byteLength).set(srcBytes);
      }
      return ptr;
    },

    read(guestAddr, byteLen) {
      return sliceMemoryU8(exp.memory.buffer, guestAddr, byteLen);
    },

    readCopy(guestAddr, byteLen) {
      return sliceMemoryU8(exp.memory.buffer, guestAddr, byteLen).slice();
    },

    callCore(exportName, params = [], expectedRetTag = CORE_VAL_VOID) {
      const fn = exp[exportName];
      if (typeof fn !== 'function') {
        throw new Error(`Missing guest core export: ${exportName}`);
      }
      const jsArgs = new Array(params.length);
      for (let i = 0; i < params.length; i++) {
        jsArgs[i] = coreValToJsArg(params[i].tag, BigInt(params[i].bits));
      }
      const raw = fn(...jsArgs);
      return jsRetToCoreVal(raw, expectedRetTag);
    },

    callPostReturn(postExportName, valTag, valBits) {
      const fn = exp[postExportName];
      if (typeof fn !== 'function') {
        throw new Error(`Missing guest post-return export: ${postExportName}`);
      }
      if (valTag === CORE_VAL_VOID) {
        fn();
      } else {
        fn(coreValToJsArg(valTag, BigInt(valBits)));
      }
    },

    resourceNew(iface, resourceName, rep) {
      return resourceTable.insert(iface, resourceName, rep);
    },

    resourceRep(iface, resourceName, handle) {
      return resourceTable.rep(iface, resourceName, handle);
    },

    resourceDrop(iface, resourceName, handle) {
      resourceTable.drop(iface, resourceName, handle);
    },

    liveResourceCount() {
      return resourceTable.liveCount;
    },

    /**
     * Create `"zigar:component-host"` WebAssembly imports connecting a WASM-compiled
     * Zig module (`WasmExternBackend` in `wit-zigar/src/component_host.zig`) directly
     * to this component instance in V8 with zero serialization overhead.
     *
     * @param {() => WebAssembly.Memory} getCallerMemory Returns the Zig caller's `WebAssembly.Memory`
     */
    createWasmImports(getCallerMemory) {
      return createComponentHostWasmImports(
        new Map([
          [1, host],
          [instanceId, host],
        ]),
        getCallerMemory,
      );
    },

    /**
     * Create JS callback functions matching `ZigarCallbacks` in
     * `wit-zigar/src/component_host.zig` so any `zigar` module (WASM via `zigar-compiler`
     * or native via `node-zigar`) can drive this component instance directly.
     */
    createZigarCallbacks() {
      const toU8 = (val) => {
        if (val instanceof Uint8Array) return val;
        if (val?.typedArray instanceof Uint8Array) return val.typedArray;
        if (val?.dataView instanceof DataView) {
          return new Uint8Array(val.dataView.buffer, val.dataView.byteOffset, val.dataView.byteLength);
        }
        if (ArrayBuffer.isView(val)) {
          return new Uint8Array(val.buffer, val.byteOffset, val.byteLength);
        }
        if (val instanceof ArrayBuffer) return new Uint8Array(val);
        if (typeof val === 'string') return textEncoder.encode(val);
        return Uint8Array.from(val ?? []);
      };
      const toStr = (val) => {
        if (typeof val === 'string') return val;
        if (typeof val?.string === 'string') return val.string;
        return textDecoder.decode(toU8(val));
      };
      return {
        alloc: (reallocNameBytes, alignBytes, byteLen) => {
          try {
            return BigInt(host.alloc(toStr(reallocNameBytes), Number(alignBytes) >>> 0, Number(byteLen) >>> 0));
          } catch {
            return -1n;
          }
        },
        write: (guestAddr, dataBytes) => {
          try {
            host.write(Number(guestAddr) >>> 0, toU8(dataBytes));
            return true;
          } catch {
            return false;
          }
        },
        read_chunk: (guestAddr, byteLen) => {
          const data = new Uint8Array(4096);
          try {
            const n = Math.min(Number(byteLen) >>> 0, 4096);
            const view = host.read(Number(guestAddr) >>> 0, n);
            data.set(view);
            return { status: 1, len: n, data };
          } catch {
            return { status: 0, len: 0, data };
          }
        },
        memory_size: () => BigInt(host.memoryByteLength()),
        call_core: (exportNameBytes, encodedParams, expectedRetTag) => {
          try {
            const name = toStr(exportNameBytes);
            const paramBytes = toU8(encodedParams);
            const dv = new DataView(paramBytes.buffer, paramBytes.byteOffset, paramBytes.byteLength);
            const count = (paramBytes.byteLength / 16) >>> 0;
            const params = new Array(count);
            for (let i = 0; i < count; i++) {
              const tag = dv.getUint32(i * 16, true);
              const bits = dv.getBigUint64(i * 16 + 8, true);
              params[i] = { tag, bits };
            }
            const res = host.callCore(name, params, Number(expectedRetTag) >>> 0);
            return {
              status: 1,
              tag: res.tag >>> 0,
              bits: res.bits,
            };
          } catch {
            return { status: 0, tag: 0, bits: 0n };
          }
        },
        call_post_return: (exportNameBytes, valTag, valBits) => {
          try {
            host.callPostReturn(toStr(exportNameBytes), Number(valTag) >>> 0, BigInt(valBits));
            return true;
          } catch {
            return false;
          }
        },
        resource_new: (ifaceBytes, resBytes, rep) => {
          return host.resourceNew(toStr(ifaceBytes), toStr(resBytes), Number(rep) | 0);
        },
        resource_rep: (ifaceBytes, resBytes, handle) => {
          try {
            const rep = host.resourceRep(toStr(ifaceBytes), toStr(resBytes), Number(handle) | 0);
            return BigInt(rep >>> 0);
          } catch {
            return -1n;
          }
        },
        resource_drop: (ifaceBytes, resBytes, handle) => {
          try {
            host.resourceDrop(toStr(ifaceBytes), toStr(resBytes), Number(handle) | 0);
            return true;
          } catch {
            return false;
          }
        },
        live_resource_count: () => host.liveResourceCount() >>> 0,
      };
    },
  };

  if (options.register !== false) {
    registry.hosts.set(instanceId, host);
  }

  return host;
}

/**
 * Build `"zigar:component-host"` WebAssembly import bindings for one or more
 * `ComponentHost` instances keyed by numeric `instId` (defaults to the shared
 * `getComponentHostRegistry().hosts` map when `hostsById` is null/undefined).
 */
export function createComponentHostWasmImports(hostsById, getCallerMemory) {
  const sourceMapOrObj = hostsById ?? getComponentHostRegistry().hosts;
  const resolveHost = (instId) => {
    const id = instId >>> 0;
    const h = sourceMapOrObj instanceof Map ? sourceMapOrObj.get(id) : sourceMapOrObj[id];
    if (!h) {
      throw new Error(`Unknown component host instance id: ${id}`);
    }
    return h;
  };

  const callerBytes = (ptr, len) => {
    const mem = getCallerMemory();
    return sliceMemoryU8(mem.buffer, ptr, len);
  };

  const callerStr = (ptr, len) => textDecoder.decode(callerBytes(ptr, len));

  return {
    'zigar:component-host': {
      // Returns status (0 = ok, non-zero = error); writes u32 guest addr to out_addr_ptr
      alloc(instId, reallocPtr, reallocLen, alignBytes, byteLen, outAddrPtr) {
        try {
          const h = resolveHost(instId);
          const reallocName = callerStr(reallocPtr, reallocLen);
          const addr = h.alloc(reallocName, alignBytes >>> 0, byteLen >>> 0);
          const mem = getCallerMemory();
          new DataView(mem.buffer, toUnsignedPtr(outAddrPtr), 4).setUint32(0, addr >>> 0, true);
          return 0;
        } catch {
          return 1;
        }
      },

      write(instId, guestAddr, srcPtr, byteLen) {
        try {
          const h = resolveHost(instId);
          const src = callerBytes(srcPtr, byteLen);
          h.write(guestAddr >>> 0, src);
          return 0;
        } catch {
          return 1;
        }
      },

      read(instId, guestAddr, dstPtr, byteLen) {
        try {
          const h = resolveHost(instId);
          const src = h.read(guestAddr >>> 0, byteLen >>> 0);
          const dst = callerBytes(dstPtr, byteLen);
          dst.set(src);
          return 0;
        } catch {
          return 1;
        }
      },

      memory_size(instId) {
        const h = resolveHost(instId);
        return BigInt(h.memoryByteLength());
      },

      // params_ptr: `params_count` entries of 16 bytes `[tag: u32, pad: u32, bits: u64]`
      // result_ptr: 16 bytes `[tag: u32, pad: u32, bits: u64]`
      call_core(instId, expPtr, expLen, paramsPtr, paramsCount, expectedRetTag, resultPtr) {
        try {
          const h = resolveHost(instId);
          const expName = callerStr(expPtr, expLen);
          const count = paramsCount >>> 0;
          const params = new Array(count);
          if (count > 0) {
            const mem = getCallerMemory();
            const dv = new DataView(mem.buffer, toUnsignedPtr(paramsPtr), count * 16);
            for (let i = 0; i < count; i++) {
              params[i] = {
                tag: dv.getUint32(i * 16, true),
                bits: dv.getBigUint64(i * 16 + 8, true),
              };
            }
          }
          const res = h.callCore(expName, params, expectedRetTag >>> 0);
          const mem = getCallerMemory();
          const resDV = new DataView(mem.buffer, toUnsignedPtr(resultPtr), 16);
          resDV.setUint32(0, res.tag >>> 0, true);
          resDV.setUint32(4, 0, true);
          resDV.setBigUint64(8, res.bits, true);
          return 0;
        } catch {
          return 1;
        }
      },

      call_post_return(instId, expPtr, expLen, valTag, valBits) {
        try {
          const h = resolveHost(instId);
          const expName = callerStr(expPtr, expLen);
          h.callPostReturn(expName, valTag >>> 0, BigInt.asUintN(64, BigInt(valBits)));
          return 0;
        } catch {
          return 1;
        }
      },

      resource_new(instId, ifacePtr, ifaceLen, resPtr, resLen, rep) {
        try {
          const h = resolveHost(instId);
          return h.resourceNew(callerStr(ifacePtr, ifaceLen), callerStr(resPtr, resLen), rep | 0);
        } catch {
          return -1;
        }
      },

      resource_rep(instId, ifacePtr, ifaceLen, resPtr, resLen, handle, outRepPtr) {
        try {
          const h = resolveHost(instId);
          const rep = h.resourceRep(callerStr(ifacePtr, ifaceLen), callerStr(resPtr, resLen), handle | 0);
          const mem = getCallerMemory();
          new DataView(mem.buffer, toUnsignedPtr(outRepPtr), 4).setInt32(0, rep | 0, true);
          return 0;
        } catch {
          return 1;
        }
      },

      resource_drop(instId, ifacePtr, ifaceLen, resPtr, resLen, handle) {
        try {
          const h = resolveHost(instId);
          h.resourceDrop(callerStr(ifacePtr, ifaceLen), callerStr(resPtr, resLen), handle | 0);
          return 0;
        } catch {
          return 1;
        }
      },

      live_resource_count(instId) {
        const h = resolveHost(instId);
        return h.liveResourceCount() >>> 0;
      },
    },
  };
}

// ── Binary-Framed Stdio RPC Worker (`--rpc-stdio <component.wasm>`) ─────────

function readExactSync(fd, targetBuf, length) {
  let offset = 0;
  while (offset < length) {
    let n = 0;
    try {
      n = readSync(fd, targetBuf, offset, length - offset, null);
    } catch (err) {
      if (err && (err.code === 'EAGAIN' || err.code === 'EINTR')) {
        continue;
      }
      throw err;
    }
    if (n === 0) {
      if (offset === 0) return false;
      throw new Error('Unexpected EOF on component-host RPC stdin');
    }
    offset += n;
  }
  return true;
}

function writeAllSync(fd, buf, offset, length) {
  let pos = offset;
  const end = offset + length;
  while (pos < end) {
    try {
      const n = writeSync(fd, buf, pos, end - pos);
      pos += n;
    } catch (err) {
      if (err && (err.code === 'EAGAIN' || err.code === 'EINTR')) {
        continue;
      }
      throw err;
    }
  }
}

export function runComponentHostRpcStdio(wasmPath) {
  const handshake = new Uint8Array(16);
  const handshakeDV = new DataView(handshake.buffer);
  handshake.set(RPC_MAGIC, 0);

  let host;
  try {
    host = instantiateComponentHost(wasmPath, { rpcStdio: true });
  } catch (err) {
    const msg = textEncoder.encode(err instanceof Error ? err.message : String(err));
    handshakeDV.setUint32(4, 1, true);
    handshakeDV.setBigUint64(8, BigInt(msg.byteLength), true);
    writeAllSync(1, handshake, 0, 16);
    if (msg.byteLength > 0) {
      writeAllSync(1, msg, 0, msg.byteLength);
    }
    process.exit(1);
  }

  handshakeDV.setUint32(4, 0, true);
  handshakeDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
  writeAllSync(1, handshake, 0, 16);

  const reqHeader = new Uint8Array(8);
  const reqHeaderDV = new DataView(reqHeader.buffer);
  let payloadBuf = new Uint8Array(65536);

  const respFixed = new Uint8Array(32);
  const respFixedDV = new DataView(respFixed.buffer);

  const sendOk = (valTag, flags, payloadBytes, payloadLen) => {
    respFixed[0] = 0;
    respFixed[1] = valTag & 0xff;
    respFixedDV.setUint16(2, flags & 0xffff, true);
    respFixedDV.setUint32(4, payloadLen >>> 0, true);
    if (payloadLen === 0) {
      writeAllSync(1, respFixed, 0, 8);
    } else if (payloadBytes === respFixed) {
      writeAllSync(1, respFixed, 0, 8 + payloadLen);
    } else {
      writeAllSync(1, respFixed, 0, 8);
      writeAllSync(1, payloadBytes, 0, payloadLen);
    }
  };

  const sendErr = (code, err) => {
    const msg = textEncoder.encode(err instanceof Error ? err.message : String(err));
    respFixed[0] = code & 0xff;
    respFixed[1] = 0;
    respFixedDV.setUint16(2, 0, true);
    respFixedDV.setUint32(4, msg.byteLength >>> 0, true);
    writeAllSync(1, respFixed, 0, 8);
    if (msg.byteLength > 0) {
      writeAllSync(1, msg, 0, msg.byteLength);
    }
  };

  while (readExactSync(0, reqHeader, 8)) {
    const opcode = reqHeader[0];
    const reqFlags = reqHeader[1];
    const payloadLen = reqHeaderDV.getUint32(4, true);

    if (payloadLen > payloadBuf.byteLength) {
      let nextCap = payloadBuf.byteLength;
      while (nextCap < payloadLen) nextCap *= 2;
      payloadBuf = new Uint8Array(nextCap);
    }
    if (payloadLen > 0) {
      if (!readExactSync(0, payloadBuf, payloadLen)) break;
    }
    const payload = payloadBuf.subarray(0, payloadLen);
    const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);

    try {
      switch (opcode) {
        case OP_ALLOC: {
          const align = dv.getUint32(0, true);
          const byteLen = dv.getUint32(4, true);
          const reallocName = textDecoder.decode(payload.subarray(8, payloadLen));
          const addr = host.alloc(reallocName, align, byteLen);
          respFixedDV.setUint32(8, addr >>> 0, true);
          respFixedDV.setBigUint64(12, BigInt(host.memoryByteLength()), true);
          sendOk(0, 0, respFixed, 12);
          break;
        }
        case OP_WRITE: {
          const guestAddr = dv.getUint32(0, true);
          host.write(guestAddr, payload.subarray(4, payloadLen));
          sendOk(0, 0, respFixed, 0);
          break;
        }
        case OP_ALLOC_WRITE: {
          const align = dv.getUint32(0, true);
          const nameLen = dv.getUint16(4, true);
          const reallocName = textDecoder.decode(payload.subarray(8, 8 + nameLen));
          const data = payload.subarray(8 + nameLen, payloadLen);
          const addr = host.allocAndWrite(reallocName, align, data);
          respFixedDV.setUint32(8, addr >>> 0, true);
          respFixedDV.setBigUint64(12, BigInt(host.memoryByteLength()), true);
          sendOk(0, 0, respFixed, 12);
          break;
        }
        case OP_READ: {
          const guestAddr = dv.getUint32(0, true);
          const byteLen = dv.getUint32(4, true);
          const view = host.read(guestAddr, byteLen);
          respFixed[0] = 0;
          respFixed[1] = 0;
          respFixedDV.setUint16(2, 0, true);
          respFixedDV.setUint32(4, (8 + view.byteLength) >>> 0, true);
          respFixedDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
          writeAllSync(1, respFixed, 0, 16);
          if (view.byteLength > 0) {
            writeAllSync(1, view, 0, view.byteLength);
          }
          break;
        }
        case OP_MEM_SIZE: {
          respFixedDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
          sendOk(0, 0, respFixed, 8);
          break;
        }
        case OP_CALL_CORE: {
          const nameLen = dv.getUint16(0, true);
          const paramCount = dv.getUint16(2, true);
          const exportName = textDecoder.decode(payload.subarray(4, 4 + nameLen));
          const paramsOffset = 4 + nameLen;
          const params = new Array(paramCount);
          for (let i = 0; i < paramCount; i++) {
            const base = paramsOffset + i * 12;
            const tag = payload[base];
            const bits = dv.getBigUint64(base + 4, true);
            params[i] = { tag, bits };
          }
          const epochBefore = host.resourceTable.mutationEpoch;
          const res = host.callCore(exportName, params, reqFlags);
          const epochAfter = host.resourceTable.mutationEpoch;
          const outFlags = epochBefore !== epochAfter ? 1 : 0;
          respFixedDV.setBigUint64(8, res.bits, true);
          respFixedDV.setBigUint64(16, BigInt(host.memoryByteLength()), true);
          respFixedDV.setUint32(24, host.liveResourceCount() >>> 0, true);
          sendOk(res.tag, outFlags, respFixed, 20);
          break;
        }
        case OP_POST_RETURN: {
          const valTag = payload[0];
          const valBits = dv.getBigUint64(4, true);
          const postExportName = textDecoder.decode(payload.subarray(12, payloadLen));
          const epochBefore = host.resourceTable.mutationEpoch;
          host.callPostReturn(postExportName, valTag, valBits);
          const epochAfter = host.resourceTable.mutationEpoch;
          const outFlags = epochBefore !== epochAfter ? 1 : 0;
          respFixedDV.setBigUint64(8, BigInt(host.memoryByteLength()), true);
          respFixedDV.setUint32(16, host.liveResourceCount() >>> 0, true);
          sendOk(0, outFlags, respFixed, 12);
          break;
        }
        case OP_RESOURCE_NEW: {
          const rep = dv.getInt32(0, true);
          const ifaceLen = dv.getUint16(4, true);
          const resLen = dv.getUint16(6, true);
          const iface = textDecoder.decode(payload.subarray(8, 8 + ifaceLen));
          const resName = textDecoder.decode(payload.subarray(8 + ifaceLen, 8 + ifaceLen + resLen));
          const handle = host.resourceNew(iface, resName, rep);
          respFixedDV.setInt32(8, handle | 0, true);
          respFixedDV.setUint32(12, host.liveResourceCount() >>> 0, true);
          sendOk(0, 1, respFixed, 8);
          break;
        }
        case OP_RESOURCE_REP: {
          const handle = dv.getInt32(0, true);
          const ifaceLen = dv.getUint16(4, true);
          const resLen = dv.getUint16(6, true);
          const iface = textDecoder.decode(payload.subarray(8, 8 + ifaceLen));
          const resName = textDecoder.decode(payload.subarray(8 + ifaceLen, 8 + ifaceLen + resLen));
          const rep = host.resourceRep(iface, resName, handle);
          respFixedDV.setInt32(8, rep | 0, true);
          sendOk(0, 0, respFixed, 4);
          break;
        }
        case OP_RESOURCE_DROP: {
          const handle = dv.getInt32(0, true);
          const ifaceLen = dv.getUint16(4, true);
          const resLen = dv.getUint16(6, true);
          const iface = textDecoder.decode(payload.subarray(8, 8 + ifaceLen));
          const resName = textDecoder.decode(payload.subarray(8 + ifaceLen, 8 + ifaceLen + resLen));
          host.resourceDrop(iface, resName, handle);
          respFixedDV.setUint32(8, host.liveResourceCount() >>> 0, true);
          sendOk(0, 1, respFixed, 4);
          break;
        }
        case OP_LIVE_RESOURCES: {
          respFixedDV.setUint32(8, host.liveResourceCount() >>> 0, true);
          sendOk(0, 0, respFixed, 4);
          break;
        }
        case OP_SHUTDOWN: {
          sendOk(0, 0, respFixed, 0);
          try {
            closeSync(0);
          } catch {}
          return;
        }
        default:
          throw new Error(`Unknown RPC opcode: 0x${opcode.toString(16)}`);
      }
    } catch (err) {
      sendErr(1, err);
    }
  }
}

if (
  typeof process !== 'undefined' &&
  Array.isArray(process.argv) &&
  (process.argv[1] === '--rpc-stdio' ||
    (typeof process.argv[1] === 'string' &&
      (process.argv[1].endsWith('component-host.js') ||
        process.argv[1].endsWith('node_rpc_worker.mjs'))))
) {
  const rpcIdx = process.argv.indexOf('--rpc-stdio');
  if (rpcIdx !== -1 && rpcIdx + 1 < process.argv.length) {
    runComponentHostRpcStdio(process.argv[rpcIdx + 1]);
  }
}
