import { PosixError } from '../constants.js';
import { mixin } from '../environment.js';
import { empty, toBufferOffset, isPromise, decodeText } from '../utils.js';

const trampolineModuleCache = new Map();

function encodeUleb(value, out) {
  let v = value >>> 0;
  do {
    let byte = v & 0x7f;
    v >>>= 7;
    if (v !== 0) {
      byte |= 0x80;
    }
    out.push(byte);
  } while (v !== 0);
}

function appendSection(out, id, payload) {
  out.push(id);
  encodeUleb(payload.length, out);
  for (let i = 0; i < payload.length; i++) {
    out.push(payload[i]);
  }
}

function bytesToKey(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    s += bytes[i].toString(16).padStart(2, '0');
  }
  return s;
}

function parseWasmTableFuncTypes(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 8) {
    return null;
  }
  if (
    bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d ||
    bytes[4] !== 0x01 || bytes[5] !== 0x00 || bytes[6] !== 0x00 || bytes[7] !== 0x00
  ) {
    return null;
  }
  let pos = 8;
  const readUleb = () => {
    let result = 0;
    let shift = 0;
    while (pos < bytes.length) {
      const byte = bytes[pos++];
      result += (byte & 0x7f) * (2 ** shift);
      if ((byte & 0x80) === 0) break;
      shift += 7;
    }
    return result;
  };
  const readSleb = () => {
    let result = 0n;
    let shift = 0n;
    let byte = 0;
    while (pos < bytes.length) {
      byte = bytes[pos++];
      result |= BigInt(byte & 0x7f) << shift;
      shift += 7n;
      if ((byte & 0x80) === 0) break;
    }
    if (shift < 64n && (byte & 0x40) !== 0) {
      result |= (~0n) << shift;
    }
    return Number(result);
  };
  const skipValType = () => {
    const vt = bytes[pos++];
    if (vt === 0x63 || vt === 0x64) {
      readSleb();
    }
  };
  const skipLimits = () => {
    const flags = readUleb();
    readUleb();
    if (flags & 0x01) {
      readUleb();
    }
  };
  const readConstOffsetExpr = () => {
    let offset = null;
    while (pos < bytes.length) {
      const op = bytes[pos++];
      if (op === 0x0b) {
        break;
      } else if (op === 0x41 || op === 0x42) {
        offset = readSleb();
      } else if (op === 0x23) {
        offset = null;
        readUleb();
      } else {
        offset = null;
      }
    }
    return offset;
  };
  const readElemExprFuncIdx = () => {
    let fnIdx = null;
    const op = bytes[pos++];
    if (op === 0xd2) {
      fnIdx = readUleb();
    } else if (op === 0xd0) {
      skipValType();
    }
    while (pos < bytes.length) {
      if (bytes[pos++] === 0x0b) break;
    }
    return fnIdx;
  };

  const types = [];
  const funcTypeIndices = [];
  const slotTypes = new Map();

  while (pos < bytes.length) {
    const sectionId = bytes[pos++];
    const sectionLen = readUleb();
    const sectionEnd = pos + sectionLen;
    if (sectionEnd > bytes.length) {
      break;
    }
    if (sectionId === 1) {
      const typeCount = readUleb();
      for (let i = 0; i < typeCount; i++) {
        const start = pos;
        const form = bytes[pos++];
        if (form !== 0x60) {
          pos = sectionEnd;
          break;
        }
        const paramCount = readUleb();
        for (let p = 0; p < paramCount; p++) skipValType();
        const resultCount = readUleb();
        for (let r = 0; r < resultCount; r++) skipValType();
        const typeBytes = bytes.slice(start, pos);
        types.push({
          typeBytes,
          paramCount,
          key: bytesToKey(typeBytes),
        });
      }
    } else if (sectionId === 2) {
      const importCount = readUleb();
      for (let i = 0; i < importCount; i++) {
        const modLen = readUleb();
        pos += modLen;
        const nameLen = readUleb();
        pos += nameLen;
        const kind = bytes[pos++];
        if (kind === 0x00) {
          funcTypeIndices.push(readUleb());
        } else if (kind === 0x01) {
          skipValType();
          skipLimits();
        } else if (kind === 0x02) {
          skipLimits();
        } else if (kind === 0x03) {
          skipValType();
          pos++;
        } else if (kind === 0x04) {
          pos++;
          readUleb();
        } else {
          pos = sectionEnd;
          break;
        }
      }
    } else if (sectionId === 3) {
      const fnCount = readUleb();
      for (let i = 0; i < fnCount; i++) {
        funcTypeIndices.push(readUleb());
      }
    } else if (sectionId === 9) {
      const segCount = readUleb();
      for (let s = 0; s < segCount; s++) {
        const flags = readUleb();
        const isActive = (flags & 0x01) === 0;
        const hasExplicitTable = isActive && (flags & 0x02) !== 0;
        const usesExprs = (flags & 0x04) !== 0;
        let tableIdx = 0;
        let offset = null;
        if (isActive) {
          if (hasExplicitTable) {
            tableIdx = readUleb();
          }
          offset = readConstOffsetExpr();
          if (hasExplicitTable) {
            if (usesExprs) {
              skipValType();
            } else {
              pos++;
            }
          }
        } else {
          if (usesExprs) {
            skipValType();
          } else {
            pos++;
          }
        }
        const elemCount = readUleb();
        for (let i = 0; i < elemCount; i++) {
          const fnIdx = usesExprs ? readElemExprFuncIdx() : readUleb();
          if (isActive && tableIdx === 0 && offset !== null && fnIdx !== null) {
            const typeIdx = funcTypeIndices[fnIdx];
            const typeInfo = (typeIdx !== undefined) ? types[typeIdx] : undefined;
            if (typeInfo) {
              slotTypes.set(offset + i, typeInfo);
            }
          }
        }
      }
    }
    pos = sectionEnd;
  }
  return slotTypes;
}

function getDynamicTrampolineModule(typeInfo, is64) {
  const cacheKey = `${is64 ? '64' : '32'}:${typeInfo.key}`;
  let mod = trampolineModuleCache.get(cacheKey);
  if (!mod) {
    const idValType = is64 ? 0x7e : 0x7f;
    const out = [ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 ];
    // Section 1: Type — 0: (idValType) -> (), 1: target signature
    const typePayload = [ 0x02, 0x60, 0x01, idValType, 0x00, ...typeInfo.typeBytes ];
    appendSection(out, 1, typePayload);
    // Section 2: Import — env.set_id (func 0), env.target (func 1), env.id (mut global 0)
    const importPayload = [
      0x03,
      0x03, 0x65, 0x6e, 0x76, 0x06, 0x73, 0x65, 0x74, 0x5f, 0x69, 0x64, 0x00, 0x00,
      0x03, 0x65, 0x6e, 0x76, 0x06, 0x74, 0x61, 0x72, 0x67, 0x65, 0x74, 0x00, 0x01,
      0x03, 0x65, 0x6e, 0x76, 0x02, 0x69, 0x64, 0x03, idValType, 0x01,
    ];
    appendSection(out, 2, importPayload);
    // Section 3: Function — 1 internal function (func 2) with type 1
    appendSection(out, 3, [ 0x01, 0x01 ]);
    // Section 7: Export — "t" -> func 2
    appendSection(out, 7, [ 0x01, 0x01, 0x74, 0x00, 0x02 ]);
    // Section 10: Code — global.get 0, call 0, local.get 0..N-1, call 1, end
    const body = [ 0x00, 0x23, 0x00, 0x10, 0x00 ];
    for (let p = 0; p < typeInfo.paramCount; p++) {
      body.push(0x20);
      encodeUleb(p, body);
    }
    body.push(0x10, 0x01, 0x0b);
    const codePayload = [ 0x01 ];
    encodeUleb(body.length, codePayload);
    for (let i = 0; i < body.length; i++) {
      codePayload.push(body[i]);
    }
    appendSection(out, 10, codePayload);
    mod = new WebAssembly.Module(new Uint8Array(out));
    trampolineModuleCache.set(cacheKey, mod);
  }
  return mod;
}

var thunkAllocation = mixin({
  ...({
    exports: {
      allocateJsThunk: { argType: 'az', returnType: 'a' },
      freeJsThunk: { argType: 'aa', returnType: 'z' },
      findJsThunk: { argType: 'aa', returnType: 'z' },
    },
    imports: {
      identifyJsThunk: { argType: 'aa', returnType: 'z' },
    },
    init() {
      this.thunkSources = [];
      this.thunkMap = new Map();
      this.dynamicThunkPool = new Map();
      this.freeThunkSlots = [];
      this.wasmTableFuncTypes = null;
    },
    getWasmTableFuncTypes() {
      if (!this.wasmTableFuncTypes && this.wasmBinary) {
        this.wasmTableFuncTypes = parseWasmTableFuncTypes(this.wasmBinary);
      }
      return this.wasmTableFuncTypes;
    },
    allocateTableSlot() {
      const isTable64 = typeof this.table.length === 'bigint';
      while (this.freeThunkSlots.length > 0) {
        const slot = this.freeThunkSlots.pop();
        if (slot < Number(this.table.length) && !this.table.get(isTable64 ? BigInt(slot) : slot)) {
          return slot;
        }
      }
      const tableLen = Number(this.table.length);
      const initialLen = Number(this.initialTableLength);
      for (let i = tableLen - 1; i >= initialLen; i--) {
        if (!this.table.get(isTable64 ? BigInt(i) : i)) {
          return i;
        }
      }
      try {
        this.table.grow(isTable64 ? 8n : 8);
      } catch {
        return 0;
      }
      return tableLen;
    },
    addJsThunkSource() {
      const {
        memoryInitial,
        memoryMax,
        tableInitial,
        multithreaded,
      } = this.options ?? {};
      const w = WebAssembly;
      const env = {}, wasi = {}, wasiPreview = {};
      const imports = { env, wasi, wasi_snapshot_preview1: wasiPreview };
      let secMemory = null;
      let secSpGlobal = null;
      let secLowWaterSp = null;
      let secSuspendedCount = 0;
      const forwardHandleJscall = (fnId, secArgAddr, argSize, canWait) => {
        const byteLen = Number(argSize);
        const secOffset = toBufferOffset(secArgAddr);
        const scratchAddr = (byteLen > 0)
          ? this.allocateScratchMemory(byteLen, 16)
          : (this.memory64 ? 0n : 0);
        if (byteLen > 0) {
          const src = new Uint8Array(secMemory.buffer, secOffset, byteLen);
          const dst = new Uint8Array(this.memory.buffer, toBufferOffset(scratchAddr), byteLen);
          dst.set(src);
        }
        const copyBackAndFree = () => {
          if (this.abandoned) {
            return;
          }
          try {
            if (byteLen > 0) {
              const src = new Uint8Array(this.memory.buffer, toBufferOffset(scratchAddr), byteLen);
              const dst = new Uint8Array(secMemory.buffer, secOffset, byteLen);
              dst.set(src);
            }
          } finally {
            if (byteLen > 0) {
              this.freeScratchMemory(scratchAddr, byteLen, 16);
            }
          }
        };
        let res;
        try {
          res = this.handleJscall(fnId, scratchAddr, byteLen, canWait);
        } catch (err) {
          if (byteLen > 0 && !this.abandoned) {
            this.freeScratchMemory(scratchAddr, byteLen, 16);
          }
          throw err;
        }
        if (isPromise(res)) {
          if (secSpGlobal) {
            const curSp = Number(secSpGlobal.value);
            const step = Math.max(4096, (byteLen + 255) & -16);
            const baseSp = (secLowWaterSp !== null) ? Math.min(secLowWaterSp, curSp) : curSp;
            const targetSp = (baseSp - step) & -16;
            if (targetSp >= 4096) {
              secLowWaterSp = targetSp;
              try {
                secSpGlobal.value = (typeof secSpGlobal.value === 'bigint') ? BigInt(targetSp) : targetSp;
              } catch {}
            }
          }
          secSuspendedCount++;
          const finishSuspend = () => {
            if (--secSuspendedCount === 0) {
              secLowWaterSp = null;
            }
          };
          return res.then(
            (code) => {
              finishSuspend();
              if (this.abandoned) {
                return PosixError.EFAULT;
              }
              copyBackAndFree();
              return code;
            },
            (err) => {
              finishSuspend();
              if (byteLen > 0 && !this.abandoned) {
                this.freeScratchMemory(scratchAddr, byteLen, 16);
              }
              throw err;
            },
          );
        }
        copyBackAndFree();
        return res;
      };
      let importsMemory = false;
      for (const { module, name, kind } of w.Module.imports(this.executable)) {
        if (kind === 'function') {
          if (module === 'env' && name === '_handleJscall' && this.exportFunction) {
            (imports[module] ??= {})[name] = this.exportFunction(forwardHandleJscall, 'zazb', 'i', 'handleJscall');
          } else if (module === 'env' && name === '_displayPanic' && this.exportFunction) {
            (imports[module] ??= {})[name] = this.exportFunction((address, len) => {
              if (secMemory) {
                const array = new Uint8Array(secMemory.buffer, toBufferOffset(address), Number(len));
                console.error(`Zig panic: ${decodeText(array)}`);
              }
            }, 'az', '');
          } else if (module === 'wasi_snapshot_preview1' && name === 'proc_exit' && this.getWASIHandler) {
            (imports[module] ??= {})[name] = this.getWASIHandler('proc_exit');
          } else {
            (imports[module] ??= {})[name] = empty;
          }
        } else if (kind === 'memory' && module === 'env' && name === 'memory') {
          importsMemory = true;
        }
      }
      if (importsMemory) {
        const initialPages = memoryInitial
          ?? (this.initialMemoryPages || ((this.memory?.buffer.byteLength ?? 65536) / 65536));
        env.memory = new w.Memory(this.memory64 ? {
          initial: BigInt(initialPages),
          ...(memoryMax !== undefined ? { maximum: BigInt(memoryMax) } : undefined),
          shared: multithreaded,
          address: 'i64',
        } : {
          initial: initialPages,
          maximum: memoryMax,
          shared: multithreaded,
        });
      }
      let table;
      const initialTable = tableInitial || this.initialTableLength;
      if (initialTable) {
        table = env.__indirect_function_table = new w.Table(this.table64 ? {
          initial: BigInt(initialTable),
          element: 'anyfunc',
          address: 'i64',
        } : {
          initial: initialTable,
          element: 'anyfunc',
        });
      }
      const { exports } = new w.Instance(this.executable, imports);
      secMemory = env.memory ?? exports.memory ?? null;
      secSpGlobal = exports.__stack_pointer ?? null;
      table ??= exports.__indirect_function_table;
      const createJsThunk = exports.createJsThunk && this.importFunction(exports.createJsThunk, 'az', 'a');
      const destroyJsThunk = exports.destroyJsThunk && this.importFunction(exports.destroyJsThunk, 'aa', 'z');
      const identifyJsThunk = exports.identifyJsThunk && this.importFunction(exports.identifyJsThunk, 'aa', 'z');
      const source = {
        thunkCount: 0,
        createJsThunk,
        destroyJsThunk,
        identifyJsThunk,
        table,
      };
      this.thunkSources.unshift(source);
      return source;
    },
    allocateJsThunk(controllerAddress, funcId) {
      const isTable64 = typeof this.table.length === 'bigint';
      const zeroAddr = (this.memory64 || isTable64) ? 0n : 0;
      const { getDynamicJsThunk, setPendingDynamicJsThunkId } = this.instance?.exports ?? {};
      if (getDynamicJsThunk && setPendingDynamicJsThunkId && this.wasmBinary) {
        const ctrlKey = BigInt(controllerAddress);
        const numericFuncId = Number(funcId);
        const idValue = this.memory64 ? BigInt(funcId) : (numericFuncId >>> 0);
        const pool = this.dynamicThunkPool.get(ctrlKey);
        let trampolineFn = null;
        let idGlobal = null;
        if (pool?.length > 0) {
          const pooled = pool.pop();
          trampolineFn = pooled.trampolineFn;
          idGlobal = pooled.idGlobal;
          idGlobal.value = idValue;
        } else {
          const rawDynIdx = getDynamicJsThunk(this.memory64 ? ctrlKey : (Number(controllerAddress) >>> 0));
          const dynamicThunkIdx = Number(typeof rawDynIdx === 'bigint' ? BigInt.asUintN(64, rawDynIdx) : (rawDynIdx >>> 0));
          if (dynamicThunkIdx > 0 && dynamicThunkIdx < Number(this.table.length)) {
            const targetFn = this.table.get(isTable64 ? BigInt(dynamicThunkIdx) : dynamicThunkIdx);
            const typeInfo = this.getWasmTableFuncTypes()?.get(dynamicThunkIdx);
            if (targetFn && typeInfo) {
              const trampolineMod = getDynamicTrampolineModule(typeInfo, Boolean(this.memory64));
              idGlobal = new WebAssembly.Global({
                value: this.memory64 ? 'i64' : 'i32',
                mutable: true,
              }, idValue);
              const { exports } = new WebAssembly.Instance(trampolineMod, {
                env: {
                  set_id: setPendingDynamicJsThunkId,
                  target: targetFn,
                  id: idGlobal,
                },
              });
              trampolineFn = exports.t;
            }
          }
        }
        if (trampolineFn) {
          const thunkIndex = this.allocateTableSlot();
          if (!thunkIndex) {
            let targetPool = this.dynamicThunkPool.get(ctrlKey);
            if (!targetPool) {
              targetPool = [];
              this.dynamicThunkPool.set(ctrlKey, targetPool);
            }
            targetPool.push({ trampolineFn, idGlobal });
            return zeroAddr;
          }
          this.table.set(isTable64 ? BigInt(thunkIndex) : thunkIndex, trampolineFn);
          this.thunkMap.set(trampolineFn, {
            dynamic: true,
            controllerKey: ctrlKey,
            funcId: numericFuncId,
            idGlobal,
            trampolineFn,
            tableIndex: thunkIndex,
          });
          return (this.memory64 || isTable64) ? BigInt(thunkIndex) : thunkIndex;
        }
      }
      let source, sourceAddress = 0;
      for (source of this.thunkSources) {
        sourceAddress = source.createJsThunk(controllerAddress, funcId);
        if (sourceAddress) {
          break;
        }
      }
      if (!sourceAddress) {
        source = this.addJsThunkSource();
        sourceAddress = source.createJsThunk(controllerAddress, funcId);
      }
      if (!sourceAddress) {
        return zeroAddr;
      }
      // sourceAddress is an index into the function table of the source instance
      // we need to get the function object and place it into the main instance's
      // function table
      const isSourceTable64 = typeof source.table.length === 'bigint';
      const thunkObject = source.table.get(isSourceTable64 ? BigInt(sourceAddress) : Number(sourceAddress));
      const thunkIndex = this.allocateTableSlot();
      if (!thunkIndex) {
        source.destroyJsThunk(controllerAddress, sourceAddress);
        return zeroAddr;
      }
      this.table.set(isTable64 ? BigInt(thunkIndex) : thunkIndex, thunkObject);
      source.thunkCount++;
      // remember where the object is from
      this.thunkMap.set(thunkObject, { dynamic: false, source, sourceAddress });
      return (this.memory64 || isTable64) ? BigInt(thunkIndex) : thunkIndex;
    },
    freeJsThunk(controllerAddress, thunkAddress) {
      const numericSlot = Number(thunkAddress);
      if (!(numericSlot > 0 && numericSlot < Number(this.table.length))) {
        return 0;
      }
      const isTable64 = typeof this.table.length === 'bigint';
      const tableIdx = isTable64 ? BigInt(numericSlot) : numericSlot;
      const thunkObject = this.table.get(tableIdx);
      const entry = thunkObject ? this.thunkMap.get(thunkObject) : undefined;
      if (!entry) {
        return 0;
      }
      if (entry.dynamic) {
        const ctrlKey = BigInt(controllerAddress);
        if (entry.controllerKey !== ctrlKey) {
          return 0;
        }
        this.table.set(tableIdx, null);
        this.thunkMap.delete(thunkObject);
        this.freeThunkSlots.push(numericSlot);
        let pool = this.dynamicThunkPool.get(ctrlKey);
        if (!pool) {
          pool = [];
          this.dynamicThunkPool.set(ctrlKey, pool);
        }
        pool.push({
          trampolineFn: entry.trampolineFn,
          idGlobal: entry.idGlobal,
        });
        return entry.funcId;
      }
      const { source, sourceAddress } = entry;
      const fnId = Number(source.destroyJsThunk(controllerAddress, sourceAddress));
      if (!fnId) {
        return 0;
      }
      this.table.set(tableIdx, null);
      this.freeThunkSlots.push(numericSlot);
      if (--source.thunkCount === 0) {
        const index = this.thunkSources.indexOf(source);
        if (index !== -1) {
          this.thunkSources.splice(index, 1);
        }
      }
      this.thunkMap.delete(thunkObject);
      return fnId;
    },
    findJsThunk(controllerAddress, thunkAddress) {
      const numericSlot = Number(thunkAddress);
      if (!(numericSlot > 0 && numericSlot < Number(this.table.length))) {
        return 0;
      }
      const isTable64 = typeof this.table.length === 'bigint';
      const tableIdx = isTable64 ? BigInt(numericSlot) : numericSlot;
      const thunkObject = this.table.get(tableIdx);
      const entry = thunkObject ? this.thunkMap.get(thunkObject) : undefined;
      if (!entry) {
        return 0;
      }
      if (entry.dynamic) {
        return (entry.controllerKey === BigInt(controllerAddress)) ? entry.funcId : 0;
      }
      const { source, sourceAddress } = entry;
      return Number(source.identifyJsThunk(controllerAddress, sourceAddress));
    },
  } ),
});

export { thunkAllocation as default };
