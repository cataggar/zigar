import {
  ArrayFlag, MemberType, PointerFlag, PosixError, SliceFlag, StructurePurpose, StructureType,
  VisitorFlag,
} from '../constants.js';
import { mixin } from '../environment.js';
import { Deadlock, isErrorJSON, NotInErrorSet } from '../errors.js';
import {
  ALLOCATOR, CLASS, FALLBACK, MEMORY, RESTORE, RETURN, SLOTS, THROWING, VISIT, VIVIFICATE, ZIG,
} from '../symbols.js';
import { clearView, decodeText, hasJsValue, isPromise } from '../utils.js';

export const NO_CAPTURED_ERROR_HANDLE = 7;

export const LastErrorMode = {
  Peek: 0,
  Take: 1,
  Has: 2,
  Clear: 3,
};

export const HostOpCode = {
  ImportModule: 1,
  GetGlobal: 2,
  GetProp: 3,
  SetProp: 4,
  DeleteProp: 5,
  HasProp: 6,
  CallFn: 7,
  CallMethod: 8,
  Construct: 9,
};

export const HostOpFlag = {
  DynamicKey: 1 << 0,
  ModuleDefault: 1 << 1,
};

export default mixin({
  init() {
    this.jsHostOpCache = new Map();
    this.jsKeyCache = new Map();
    this.jsKeyDecodeCount = 0;
    this.jsModuleCache = new Map();
    this.jsModuleLoaders = new Map();
    this.jsModuleNamespaces = new WeakSet();
    this.jsCjsNamespaces = new WeakSet();
    this.jsEsmNamespaces = new WeakSet();
    this.moduleBaseURL = null;
    this.zigCallbackTemplateCache = new Map();
    this.zigCallbackMap = new Map();
    this.syncCallDepth = 0;
    this.hasPendingHostError = false;
    this.pendingHostError = undefined;
    this.hasCapturedError = false;
    this.capturedError = undefined;
    this.activeHostErrorFrame = null;
    this.pendingAsyncDisposals = new Map();
    this.nextAsyncDisposalTicket = 1;
  },
  getHostErrorTarget() {
    return this.activeContinuation?.hostErrorFrame ?? this.activeHostErrorFrame ?? this;
  },
  recordPendingHostError(err, target = this.getHostErrorTarget()) {
    if (target && !target.hasPendingHostError) {
      target.hasPendingHostError = true;
      target.pendingHostError = err;
    }
  },
  recordCapturedError(err, target = this.getHostErrorTarget()) {
    if (target) {
      target.hasCapturedError = true;
      target.capturedError = err;
    }
  },
  clearCapturedError(target = this.getHostErrorTarget()) {
    if (target) {
      target.hasCapturedError = false;
      target.capturedError = undefined;
    }
  },
  controlLastJsError(mode) {
    const target = this.getHostErrorTarget();
    switch (Number(mode) >>> 0) {
      case LastErrorMode.Peek:
        if (!target?.hasCapturedError) {
          return NO_CAPTURED_ERROR_HANDLE;
        }
        return this.allocJsValue(target.capturedError);
      case LastErrorMode.Take: {
        if (!target?.hasCapturedError) {
          return NO_CAPTURED_ERROR_HANDLE;
        }
        const err = target.capturedError;
        target.hasCapturedError = false;
        target.capturedError = undefined;
        return this.allocJsValue(err);
      }
      case LastErrorMode.Has:
        return target?.hasCapturedError ? 1 : 0;
      case LastErrorMode.Clear:
        this.clearCapturedError(target);
        return 0;
      default:
        return NO_CAPTURED_ERROR_HANDLE;
    }
  },
  disposeJsValue(handle, catchMode) {
    const rawHandle = Number(handle) >>> 0;
    const shouldCatch = Boolean(catchMode);
    try {
      const target = this.getJsValue(rawHandle);
      if (target !== null && target !== undefined) {
        const sym = getDisposeSymbol();
        const method = sym !== undefined ? target[sym] : undefined;
        if (method !== undefined && method !== null) {
          if (typeof(method) !== 'function') {
            throw createNotCallableError('[Symbol.dispose] is not a function');
          }
          Reflect.apply(method, target, []);
        }
      }
      return 0;
    } catch (err) {
      if (shouldCatch) {
        this.recordCapturedError(err);
        return 1;
      }
      this.recordPendingHostError(err);
      return 0;
    } finally {
      this.releaseJsValueIfValid(rawHandle);
    }
  },
  beginAsyncDisposeJsValue(handle, catchMode, allowSuspend = true) {
    const rawHandle = Number(handle) >>> 0;
    const shouldCatch = Boolean(catchMode);
    let deferredRelease = false;
    try {
      const target = this.getJsValue(rawHandle);
      if (target === null || target === undefined) {
        return 0;
      }
      const asyncSym = getAsyncDisposeSymbol();
      let method = asyncSym !== undefined ? target[asyncSym] : undefined;
      let usedSyncFallback = false;
      if (method === undefined || method === null) {
        const syncSym = getDisposeSymbol();
        method = syncSym !== undefined ? target[syncSym] : undefined;
        if (method === undefined || method === null) {
          return 0;
        }
        if (typeof(method) !== 'function') {
          throw createNotCallableError('[Symbol.dispose] is not a function');
        }
        usedSyncFallback = true;
      } else if (typeof(method) !== 'function') {
        throw createNotCallableError('[Symbol.asyncDispose] is not a function');
      }
      const rawResult = Reflect.apply(method, target, []);
      if (usedSyncFallback || !isThenable(rawResult)) {
        return 0;
      }
      const promise = isPromise(rawResult) ? rawResult : Promise.resolve(rawResult);
      const state = { settled: false, ok: false, err: undefined };
      const tracked = promise.then(
        () => {
          state.settled = true;
          state.ok = true;
        },
        (err) => {
          state.settled = true;
          state.ok = false;
          state.err = err;
        },
      );
      for (let i = 0; i < 16 && !state.settled; i++) {
        drainMicrotasksSync();
      }
      if (state.settled) {
        if (state.ok) {
          return 0;
        }
        if (shouldCatch) {
          this.recordCapturedError(state.err);
          return 1;
        }
        this.recordPendingHostError(state.err);
        return 0;
      }
      if (allowSuspend && this.useJSPI && this.activeContinuation) {
        const ticket = this.nextAsyncDisposalTicket;
        this.nextAsyncDisposalTicket = (ticket >= 0x1FFFFFFF) ? 1 : ticket + 1;
        this.pendingAsyncDisposals.set(ticket, {
          tracked,
          rawHandle,
          shouldCatch,
          errorTarget: this.getHostErrorTarget(),
          state,
        });
        deferredRelease = true;
        return ((ticket << 2) | 3) >>> 0;
      }
      if (shouldCatch) {
        return 2;
      }
      this.recordPendingHostError(new Deadlock());
      return 0;
    } catch (err) {
      if (shouldCatch) {
        this.recordCapturedError(err);
        return 1;
      }
      this.recordPendingHostError(err);
      return 0;
    } finally {
      if (!deferredRelease) {
        this.releaseJsValueIfValid(rawHandle);
      }
    }
  },
  async awaitAsyncDisposeJsValue(ticket) {
    const id = Number(ticket) >>> 0;
    const entry = this.pendingAsyncDisposals.get(id);
    if (!entry) {
      return 0;
    }
    this.pendingAsyncDisposals.delete(id);
    const { tracked, rawHandle, shouldCatch, errorTarget, state } = entry;
    try {
      await tracked;
      if (!state.ok) {
        if (shouldCatch) {
          this.recordCapturedError(state.err, errorTarget);
          return 1;
        }
        this.recordPendingHostError(state.err, errorTarget);
        return 0;
      }
      return 0;
    } finally {
      this.releaseJsValueIfValid(rawHandle);
    }
  },
  asyncDisposeJsValue(handle, catchMode) {
    return this.beginAsyncDisposeJsValue(handle, catchMode, false);
  },
  savePendingHostError() {
    const target = this.getHostErrorTarget();
    if (!target.hasPendingHostError) {
      return null;
    }
    const saved = { target, error: target.pendingHostError };
    target.hasPendingHostError = false;
    target.pendingHostError = undefined;
    return saved;
  },
  restorePendingHostError(saved) {
    if (saved) {
      saved.target.hasPendingHostError = true;
      saved.target.pendingHostError = saved.error;
    }
  },
  consumePendingHostError(target = this.getHostErrorTarget()) {
    if (!target?.hasPendingHostError) {
      return undefined;
    }
    const error = target.pendingHostError;
    target.hasPendingHostError = false;
    target.pendingHostError = undefined;
    return { error };
  },
  trackJsModuleNamespace(moduleExports, specifier) {
    if (moduleExports !== null && (typeof(moduleExports) === 'object' || typeof(moduleExports) === 'function')) {
      this.jsModuleNamespaces.add(moduleExports);
      if (isEsmExtension(specifier)) {
        this.jsEsmNamespaces.add(moduleExports);
        return;
      }
      if (
        isSyntheticCjsNamespace(moduleExports, specifier)
        || (
          isEsModuleNamespaceObject(moduleExports)
          && hasDefaultFallbackTarget(moduleExports.default)
          && hasOnlyCjsMirroredExports(moduleExports)
          && typeof(specifier) === 'string'
          && Boolean(globalThis.Bun)
          && this.isBunCjsModule(specifier, moduleExports)
        )
      ) {
        this.jsCjsNamespaces.add(moduleExports);
      }
    }
  },
  isBunCjsModule(specifier, moduleExports) {
    try {
      const proc = globalThis.process;
      const nodeModule = proc?.getBuiltinModule?.('node:module');
      if (typeof(nodeModule?.createRequire) !== 'function') {
        return false;
      }
      const fallbackBase = `${proc.cwd?.() ?? '/'}/_zigar_host_.js`;
      const strippedBase = String(this.moduleBaseURL || fallbackBase)
        .replace(/^zigar:/, '')
        .split(/[?#]/)[0];
      const usableBase = (strippedBase.includes('://') && !strippedBase.startsWith('file://'))
        ? fallbackBase
        : strippedBase;
      const basePath = usableBase.endsWith('/') ? `${usableBase}_zigar_host_.js` : usableBase;
      const req = nodeModule.createRequire(basePath);
      const spec = specifier.startsWith('file://') ? new URL(specifier) : specifier;
      const resolved = req.resolve(spec);
      return req.cache?.[resolved]?.exports === moduleExports.default;
    } catch {
      return false;
    }
  },
  isJsCjsNamespace(target) {
    if (target === null || typeof(target) !== 'object') {
      return false;
    }
    if (this.jsEsmNamespaces.has(target)) {
      return false;
    }
    if (this.jsCjsNamespaces.has(target)) {
      return true;
    }
    if (this.jsModuleNamespaces.has(target) && (isCjsWrappedNamespace(target) || isRollupMergedCjsNamespace(target))) {
      this.jsCjsNamespaces.add(target);
      return true;
    }
    return false;
  },
  unwrapCjsNamespace(target, propKey) {
    if (!this.isJsCjsNamespace(target)) {
      return target;
    }
    const cjsExports = target.default;
    if ((propKey === 'default' || propKey === 'module.exports') && !(propKey in Object(cjsExports))) {
      return target;
    }
    return cjsExports;
  },
  recoverRequiredEsmNamespace(spec, moduleExports) {
    if (
      moduleExports === null
      || (typeof(moduleExports) !== 'object' && typeof(moduleExports) !== 'function')
      || isEsModuleNamespaceObject(moduleExports)
      || isFrozenNullProtoNamespace(moduleExports)
      || spec.startsWith('node:')
      || isCjsExtension(spec)
    ) {
      return moduleExports;
    }
    try {
      const proc = globalThis.process;
      const nodeModule = proc?.getBuiltinModule?.('node:module');
      if (typeof(nodeModule?.createRequire) !== 'function') {
        return moduleExports;
      }
      const fallbackBase = `${proc.cwd?.() ?? '/'}/_zigar_host_.js`;
      const strippedBase = String(this.moduleBaseURL || fallbackBase)
        .replace(/^zigar:/, '')
        .split(/[?#]/)[0];
      const usableBase = (strippedBase.includes('://') && !strippedBase.startsWith('file://'))
        ? fallbackBase
        : strippedBase;
      const basePath = usableBase.endsWith('/') ? `${usableBase}_zigar_host_.js` : usableBase;
      const req = nodeModule.createRequire(basePath);
      const getEntryNamespace = (entry) => {
        if (entry) {
          for (const sym of Object.getOwnPropertySymbols(entry)) {
            if (typeof(entry[sym]?.getNamespace) === 'function') {
              return entry[sym].getNamespace();
            }
          }
        }
        return undefined;
      };
      try {
        const specTarget = spec.startsWith('file://') ? new URL(spec) : spec;
        const resolved = req.resolve(specTarget);
        const ns = getEntryNamespace(req.cache?.[resolved]);
        if (ns !== undefined) {
          return ns;
        }
      } catch {
        const cleanTail = spec.split(/[?#]/)[0].replace(/^(?:\.\/|\.\.\/)+/, '');
        if (cleanTail && nodeModule._cache) {
          for (const entry of Object.values(nodeModule._cache)) {
            if (
              entry?.exports === moduleExports
              && typeof(entry.filename) === 'string'
              && entry.filename.replace(/\\/g, '/').endsWith(`/${cleanTail}`)
            ) {
              const ns = getEntryNamespace(entry);
              if (ns !== undefined) {
                return ns;
              }
            }
          }
        }
      }
    } catch {}
    return moduleExports;
  },
  registerJsModule(specifier, moduleExports) {
    const spec = String(specifier);
    const normalized = this.recoverRequiredEsmNamespace(spec, moduleExports);
    this.jsModuleCache.set(spec, normalized);
    this.trackJsModuleNamespace(normalized, spec);
    return normalized;
  },
  registerJsModules(modules) {
    if (!modules || typeof(modules) !== 'object') {
      return;
    }
    const entries = (modules instanceof Map) ? modules.entries() : Object.entries(modules);
    for (const [ specifier, moduleExports ] of entries) {
      this.registerJsModule(specifier, moduleExports);
    }
  },
  registerJsModuleLoader(specifier, loader) {
    if (typeof(loader) === 'function') {
      this.jsModuleLoaders.set(String(specifier), loader);
    }
  },
  registerJsModuleLoaders(loaders) {
    if (!loaders || typeof(loaders) !== 'object') {
      return;
    }
    const entries = (loaders instanceof Map) ? loaders.entries() : Object.entries(loaders);
    for (const [ specifier, loader ] of entries) {
      this.registerJsModuleLoader(specifier, loader);
    }
  },
  resolveJsModule(specifier) {
    const spec = String(specifier);
    if (this.jsModuleCache.has(spec)) {
      return this.jsModuleCache.get(spec);
    }
    const proc = globalThis.process;
    if (typeof(proc?.getBuiltinModule) === 'function') {
      if (spec.startsWith('node:')) {
        const builtin = proc.getBuiltinModule(spec);
        if (builtin !== undefined) {
          this.registerJsModule(spec, builtin);
          return builtin;
        }
      }
      const nodeModule = proc.getBuiltinModule('node:module');
      if (typeof(nodeModule?.createRequire) === 'function') {
        const fallbackBase = `${proc.cwd?.() ?? '/'}/_zigar_host_.js`;
        const strippedBase = String(this.moduleBaseURL || fallbackBase)
          .replace(/^zigar:/, '')
          .split(/[?#]/)[0];
        const usableBase = (strippedBase.includes('://') && !strippedBase.startsWith('file://'))
          ? fallbackBase
          : strippedBase;
        const basePath = usableBase.endsWith('/') ? `${usableBase}_zigar_host_.js` : usableBase;
        try {
          const req = nodeModule.createRequire(basePath);
          const loaded = req(spec);
          return this.registerJsModule(spec, loaded);
        } catch (reqErr) {
          if (!spec.includes(':') && !spec.startsWith('.') && !spec.startsWith('/')) {
            const builtin = proc.getBuiltinModule(spec) ?? proc.getBuiltinModule(`node:${spec}`);
            if (builtin !== undefined) {
              this.registerJsModule(spec, builtin);
              return builtin;
            }
          }
          throw reqErr;
        }
      } else if (!spec.includes(':') && !spec.startsWith('.') && !spec.startsWith('/')) {
        const builtin = proc.getBuiltinModule(spec) ?? proc.getBuiltinModule(`node:${spec}`);
        if (builtin !== undefined) {
          this.registerJsModule(spec, builtin);
          return builtin;
        }
      }
    }
    const err = new Error(`Cannot find JS module '${spec}'`);
    err.name = 'ModuleNotFound';
    err.code = 'ModuleNotFound';
    throw err;
  },
  internJsKey(keyAddr, keyLen) {
    const len = Number(keyLen);
    if (len === 0) {
      return '';
    }
    const cacheKey = `${keyAddr}:${len}`;
    const cached = this.jsKeyCache.get(cacheKey);
    if (cached !== undefined) {
      return cached;
    }
    const dv = this.obtainZigView(keyAddr, len, false);
    const bytes = new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength);
    const decoded = decodeText(bytes);
    this.jsKeyDecodeCount++;
    this.jsKeyCache.set(cacheKey, decoded);
    return decoded;
  },
  resolveArgStructBySignature(signature, registerThunk) {
    let structure = this.argStructSignatureMap?.get(signature);
    if (!structure && registerThunk) {
      this.registerTypeWithThunk?.(registerThunk);
      structure = this.argStructSignatureMap?.get(signature);
    }
    if (!structure) {
      throw new Error(`Unregistered host-op ArgStruct signature: 0x${signature.toString(16)}`);
    }
    return structure;
  },
  getHostOpEntry(descriptorAddr) {
    let entry = this.jsHostOpCache.get(descriptorAddr);
    if (entry !== undefined) {
      return entry;
    }
    const is64 = Boolean(this.memory64 || process.env.BITS == 64);
    const ptrSize = is64 ? 8 : 4;
    const descSize = 16 + 4 * ptrSize;
    const dv = this.obtainZigView(descriptorAddr, descSize, false);
    const le = this.littleEndian;
    const signature = dv.getBigUint64(0, le);
    const op = dv.getUint32(8, le);
    const flags = dv.getUint32(12, le);
    const keyAddr = readUsize(dv, 16, ptrSize, le, is64);
    const keyLen = Number(readUsize(dv, 16 + ptrSize, ptrSize, le, false));
    const registerThunk = readUsize(dv, 16 + 2 * ptrSize, ptrSize, le, is64);
    const argByteSize = Number(readUsize(dv, 16 + 3 * ptrSize, ptrSize, le, false));

    const argStructStructure = this.resolveArgStructBySignature(signature, registerThunk);
    const dynamicKey = Boolean(flags & HostOpFlag.DynamicKey);
    const usesStaticKey = !dynamicKey && (
      op === HostOpCode.ImportModule
      || op === HostOpCode.GetGlobal
      || op === HostOpCode.GetProp
      || op === HostOpCode.SetProp
      || op === HostOpCode.DeleteProp
      || op === HostOpCode.HasProp
      || op === HostOpCode.CallMethod
    );
    const key = usesStaticKey ? this.internJsKey(keyAddr, keyLen) : null;
    const marshaler = this.compileHostOpMarshaler(argStructStructure);

    entry = {
      op,
      flags,
      dynamicKey,
      key,
      argByteSize,
      argStructStructure,
      ArgStruct: argStructStructure.constructor,
      ...marshaler,
    };
    this.jsHostOpCache.set(descriptorAddr, entry);
    return entry;
  },
  compileHostOpMarshaler(argStructStructure) {
    const thisEnv = this;
    const members = argStructStructure.instance.members;
    const retvalMember = members[0];
    const argMembers = members.slice(1);
    const extractors = [];

    for (let i = 0; i < argMembers.length; i++) {
      const member = argMembers[i];
      const propIndex = i;
      const { structure, type } = member;
      if (structure?.type === StructureType.Struct && structure.purpose === StructurePurpose.Allocator) {
        extractors.push({
          isAllocator: true,
          read(argStruct) {
            argStruct[ALLOCATOR] = argStruct[propIndex];
          },
        });
      } else if (isConstStringStructure(structure)) {
        extractors.push({
          isAllocator: false,
          read(argStruct) {
            const v = argStruct[propIndex];
            if (v === null || v === undefined) return v;
            if (typeof(v) === 'string') return v;
            if (typeof(v.string) === 'string') return v.string;
            const mem = v[MEMORY];
            if (mem) {
              return decodeText(new Uint8Array(mem.buffer, mem.byteOffset, mem.byteLength));
            }
            return v;
          },
        });
      } else if (type === MemberType.Object && structure?.purpose !== StructurePurpose.JsValue) {
        extractors.push({
          isAllocator: false,
          read(argStruct) {
            const v = argStruct[propIndex];
            if (v?.[MEMORY]?.[ZIG] && typeof(v.constructor) === 'function') {
              return new v.constructor(v);
            }
            return v;
          },
        });
      } else {
        extractors.push({
          isAllocator: false,
          read(argStruct) {
            return argStruct[propIndex];
          },
        });
      }
    }

    let writeSuccess, writeError, isErrorUnionReturn = false;
    if (retvalMember.structure?.type === StructureType.ErrorUnion) {
      isErrorUnionReturn = true;
      const euStructure = retvalMember.structure;
      const [ valueMember, errorMember ] = euStructure.instance.members;
      const ErrorSet = errorMember.structure.constructor;
      const retvalSlot = retvalMember.slot;
      const { set: setValue } = this.defineMember(valueMember);
      const { set: setError } = this.defineMember(errorMember);
      const { set: setErrorNumber } = this.defineMember(errorMember, false);
      const valueIsVoid = (valueMember.type === MemberType.Void);
      const valueIsOptional = (valueMember.structure?.type === StructureType.Optional);
      const valueHasJs = hasJsValue(valueMember.structure);

      writeError = (argStruct, err) => {
        const euObj = argStruct[SLOTS][retvalSlot] ?? argStruct[VIVIFICATE](retvalSlot);
        const matched = matchErrorToSet(ErrorSet, err);
        if (!matched) {
          throw new NotInErrorSet(errorMember.structure, err instanceof Error ? err : new Error(String(err)));
        }
        thisEnv.recordCapturedError(err);
        setError.call(euObj, matched);
        const mem = (process.env.TARGET === 'wasm' && euObj[RESTORE]) ? euObj[RESTORE]() : euObj[MEMORY];
        clearView(mem, valueMember.bitOffset >> 3, valueMember.byteSize);
        euObj[VISIT]?.('clear', VisitorFlag.IgnoreUncreated);
      };

      writeSuccess = (argStruct, result) => {
        const normalized = (valueIsOptional && result === undefined) ? null : result;
        const euObj = argStruct[SLOTS][retvalSlot] ?? argStruct[VIVIFICATE](retvalSlot);
        if (!valueIsVoid) {
          if (valueHasJs) {
            const prevPending = thisEnv.pendingJsHandles;
            const prevUninit = thisEnv.writingUninitZig;
            const allocatedHandles = [];
            thisEnv.pendingJsHandles = allocatedHandles;
            thisEnv.writingUninitZig = true;
            try {
              setValue.call(euObj, normalized, argStruct[ALLOCATOR]);
            } catch (convErr) {
              for (const handle of allocatedHandles) {
                thisEnv.releaseJsValue(handle);
              }
              throw convErr;
            } finally {
              thisEnv.pendingJsHandles = prevPending;
              thisEnv.writingUninitZig = prevUninit;
            }
          } else {
            setValue.call(euObj, normalized, argStruct[ALLOCATOR]);
          }
        }
        setErrorNumber.call(euObj, 0);
      };
    } else {
      const retvalIsVoid = (retvalMember.type === MemberType.Void);
      const retvalIsOptional = (retvalMember.structure?.type === StructureType.Optional);
      const retvalHasJs = hasJsValue(retvalMember.structure);
      writeSuccess = retvalIsVoid
        ? () => {}
        : retvalHasJs
          ? (argStruct, result) => {
              const normalized = (retvalIsOptional && result === undefined) ? null : result;
              const prevPending = thisEnv.pendingJsHandles;
              const prevUninit = thisEnv.writingUninitZig;
              const allocatedHandles = [];
              thisEnv.pendingJsHandles = allocatedHandles;
              thisEnv.writingUninitZig = true;
              try {
                argStruct[RETURN](normalized);
              } catch (convErr) {
                for (const handle of allocatedHandles) {
                  thisEnv.releaseJsValue(handle);
                }
                throw convErr;
              } finally {
                thisEnv.pendingJsHandles = prevPending;
                thisEnv.writingUninitZig = prevUninit;
              }
            }
          : (argStruct, result) => {
              argStruct[RETURN]((retvalIsOptional && result === undefined) ? null : result);
            };
      writeError = null;
    }

    return {
      extractors,
      isErrorUnionReturn,
      writeSuccess,
      writeError,
    };
  },
  invokeJsHostOp(descriptorAddr, argAddr, argSize) {
    const savedPending = this.savePendingHostError();
    let context = null;
    this.syncCallDepth++;
    try {
      const entry = this.getHostOpEntry(descriptorAddr);
      const byteLen = Number(argSize || entry.argByteSize);
      const dv = this.obtainZigView(argAddr, byteLen, false);
      const { ArgStruct, extractors, op, flags, dynamicKey, key, isErrorUnionReturn, writeSuccess, writeError } = entry;
      const argStruct = ArgStruct(dv);
      if (VISIT in argStruct) {
        argStruct[VISIT]('reset', VisitorFlag.IgnoreUncreated);
        context = this.startContext();
        this.updatePointerTargets(context, argStruct, true);
        this.updateShadowTargets(context);
      }
      try {
        const jsArgs = [];
        for (const ext of extractors) {
          if (ext.isAllocator) {
            ext.read(argStruct);
          } else {
            jsArgs.push(ext.read(argStruct));
          }
        }
        let result;
        switch (op) {
          case HostOpCode.ImportModule: {
            const spec = dynamicKey ? jsArgs[0] : key;
            const mod = this.resolveJsModule(spec);
            result = (flags & HostOpFlag.ModuleDefault) ? unwrapModuleDefault(mod) : mod;
            break;
          }
          case HostOpCode.GetGlobal: {
            const propKey = dynamicKey ? jsArgs[0] : key;
            result = globalThis[propKey];
            break;
          }
          case HostOpCode.GetProp: {
            const rawTarget = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            const isModuleRoot = this.jsModuleNamespaces.has(rawTarget);
            const target = this.unwrapCjsNamespace(rawTarget, propKey);
            if (
              target !== null
              && target !== undefined
              && !(propKey in Object(target))
              && isModuleRoot
              && hasDefaultFallbackTarget(target.default)
            ) {
              result = target.default[propKey];
            } else {
              result = target[propKey];
            }
            break;
          }
          case HostOpCode.SetProp: {
            const rawTarget = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            const value = dynamicKey ? jsArgs[2] : jsArgs[1];
            const isModuleRoot = this.jsModuleNamespaces.has(rawTarget);
            const target = this.unwrapCjsNamespace(rawTarget, propKey);
            if (
              target !== null
              && target !== undefined
              && !(propKey in Object(target))
              && isModuleRoot
              && isModuleNamespaceLike(target)
              && hasDefaultFallbackTarget(target.default)
            ) {
              target.default[propKey] = value;
            } else {
              target[propKey] = value;
            }
            result = undefined;
            break;
          }
          case HostOpCode.DeleteProp: {
            const rawTarget = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            const isModuleRoot = this.jsModuleNamespaces.has(rawTarget);
            const target = this.unwrapCjsNamespace(rawTarget, propKey);
            if (
              target !== null
              && target !== undefined
              && !(propKey in Object(target))
              && isModuleRoot
              && isModuleNamespaceLike(target)
              && hasDefaultFallbackTarget(target.default)
            ) {
              result = Reflect.deleteProperty(Object(target.default), propKey);
            } else {
              result = Reflect.deleteProperty(target, propKey);
            }
            break;
          }
          case HostOpCode.HasProp: {
            const rawTarget = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            const isModuleRoot = this.jsModuleNamespaces.has(rawTarget);
            const target = this.unwrapCjsNamespace(rawTarget, propKey);
            let present = Reflect.has(target, propKey);
            if (
              !present
              && isModuleRoot
              && hasDefaultFallbackTarget(target.default)
            ) {
              present = Reflect.has(Object(target.default), propKey);
            }
            result = present;
            break;
          }
          case HostOpCode.CallFn: {
            const rawCallee = jsArgs[0];
            const isModuleRoot = this.jsModuleNamespaces.has(rawCallee);
            let callee = this.isJsCjsNamespace(rawCallee) ? rawCallee.default : rawCallee;
            if (
              typeof(callee) !== 'function'
              && callee !== null
              && callee !== undefined
              && isModuleRoot
              && typeof(callee.default) === 'function'
            ) {
              callee = callee.default;
            }
            if (typeof(callee) !== 'function') {
              throw createNotCallableError('Target is not a function');
            }
            result = Reflect.apply(callee, undefined, jsArgs.slice(1));
            break;
          }
          case HostOpCode.CallMethod: {
            const rawTarget = jsArgs[0];
            const methodKey = dynamicKey ? jsArgs[1] : key;
            const callArgs = dynamicKey ? jsArgs.slice(2) : jsArgs.slice(1);
            const isModuleRoot = this.jsModuleNamespaces.has(rawTarget);
            const target = this.unwrapCjsNamespace(rawTarget, methodKey);
            if (target === null || target === undefined) {
              throw new TypeError(`Cannot read properties of ${target} (reading '${String(methodKey)}')`);
            }
            let receiver = target;
            let method = target[methodKey];
            if (isModuleRoot && hasDefaultFallbackTarget(target.default)) {
              if (!(methodKey in Object(target))) {
                receiver = target.default;
                method = receiver[methodKey];
              } else if (target.default[methodKey] === method) {
                receiver = target.default;
              }
            }
            if (typeof(method) !== 'function') {
              throw createNotCallableError(`${String(methodKey)} is not a function`);
            }
            result = Reflect.apply(method, receiver, callArgs);
            break;
          }
          case HostOpCode.Construct: {
            const rawCtor = jsArgs[0];
            const isModuleRoot = this.jsModuleNamespaces.has(rawCtor);
            let ctor = this.isJsCjsNamespace(rawCtor) ? rawCtor.default : rawCtor;
            if (
              typeof(ctor) !== 'function'
              && ctor !== null
              && ctor !== undefined
              && isModuleRoot
              && typeof(ctor.default) === 'function'
            ) {
              ctor = ctor.default;
            }
            if (typeof(ctor) !== 'function') {
              throw createNotCallableError('Target is not a constructor');
            }
            result = Reflect.construct(ctor, jsArgs.slice(1));
            break;
          }
          default:
            throw new Error(`Unknown JS host operation: ${op}`);
        }
        writeSuccess(argStruct, result);
        if (process.env.TARGET === 'node') {
          dv[FALLBACK]?.(true);
        }
        return PosixError.NONE;
      } catch (err) {
        if (isErrorUnionReturn) {
          writeError(argStruct, err);
          if (process.env.TARGET === 'node') {
            dv[FALLBACK]?.(true);
          }
          return PosixError.NONE;
        }
        if (ArgStruct[THROWING] && err instanceof Error) {
          argStruct[RETURN](err);
          if (process.env.TARGET === 'node') {
            dv[FALLBACK]?.(true);
          }
          return PosixError.NONE;
        }
        throw err;
      }
    } catch (unhandledErr) {
      this.recordPendingHostError(unhandledErr);
      return PosixError.EFAULT;
    } finally {
      this.syncCallDepth--;
      if (context) {
        this.endContext();
      }
      if (savedPending) {
        this.restorePendingHostError(savedPending);
      }
    }
  },
  getZigCallbackTemplate(descriptorAddr) {
    let template = this.zigCallbackTemplateCache.get(descriptorAddr);
    if (template !== undefined) {
      return template;
    }
    const is64 = Boolean(this.memory64 || process.env.BITS == 64);
    const ptrSize = is64 ? 8 : 4;
    const descSize = 16 + 2 * ptrSize;
    const dv = this.obtainZigView(descriptorAddr, descSize, false);
    const le = this.littleEndian;
    const signature = dv.getBigUint64(0, le);
    const flags = dv.getUint32(8, le);
    const trampolineThunk = readUsize(dv, 16, ptrSize, le, is64);
    const registerThunk = readUsize(dv, 16 + ptrSize, ptrSize, le, is64);

    const argStructStructure = this.resolveArgStructBySignature(signature, registerThunk);
    const ArgStruct = argStructStructure.constructor;
    const thunkDV = new DataView(new ArrayBuffer(0));
    thunkDV[ZIG] = { address: trampolineThunk, len: 0 };
    const thunkHolder = { [MEMORY]: thunkDV };
    const retvalStructure = unwrapPayloadStructure(argStructStructure.instance.members[0]?.structure);
    const unwrapString = isConstStringStructure(retvalStructure);

    template = {
      ArgStruct,
      thunkHolder,
      unwrapString,
      is64,
      sync: !(flags & 1),
      once: Boolean(flags & 2),
    };
    this.zigCallbackTemplateCache.set(descriptorAddr, template);
    return template;
  },
  createZigCallback(descriptorAddr, callbackId) {
    const savedPending = this.savePendingHostError();
    try {
      const id = Number(callbackId) >>> 0;
      const template = this.getZigCallbackTemplate(descriptorAddr);
      const caller = this.createOutboundCaller(template.thunkHolder, template.ArgStruct);
      caller.zigarSync = template.sync;
      const slotDV = new DataView(new ArrayBuffer(0));
      slotDV[ZIG] = { address: template.is64 ? BigInt(id) : id, len: 0 };
      caller[MEMORY] = slotDV;
      const state = { id, released: false, handle: 0 };
      const unwrapString = template.unwrapString;
      const isOnce = template.once;
      const unwrapResult = (res) => {
        if (unwrapString && res && typeof(res) === 'object' && MEMORY in res) {
          if (typeof(res.string) === 'string') {
            return res.string;
          }
          const mem = res[MEMORY];
          if (mem) {
            return decodeText(new Uint8Array(mem.buffer, mem.byteOffset, mem.byteLength));
          }
        }
        return res;
      };
      const wrapper = (...args) => {
        if (state.released) {
          throw new Error('Zig callback has already been released');
        }
        if (isOnce) {
          state.released = true;
          this.zigCallbackMap.delete(id);
        }
        let asyncResult = false;
        try {
          const res = caller(...args);
          const pending = this.consumePendingHostError();
          if (pending) {
            throw pending.error;
          }
          if (isPromise(res)) {
            asyncResult = true;
            return res.then(
              (resolved) => unwrapResult(resolved),
            ).finally(() => {
              if (isOnce) {
                this.releaseJsValueIfValid(state.handle);
              }
            });
          }
          return unwrapResult(res);
        } finally {
          if (isOnce && !asyncResult) {
            this.releaseJsValueIfValid(state.handle);
          }
        }
      };
      const handle = this.allocJsValue(wrapper);
      state.handle = handle;
      this.zigCallbackMap.set(id, state);
      return handle;
    } catch (err) {
      this.recordPendingHostError(err);
      return 0;
    } finally {
      if (savedPending) {
        this.restorePendingHostError(savedPending);
      }
    }
  },
  releaseZigCallback(callbackId) {
    const id = Number(callbackId) >>> 0;
    const state = this.zigCallbackMap.get(id);
    if (state) {
      state.released = true;
      this.zigCallbackMap.delete(id);
    }
  },
  getActiveZigCallbackCount() {
    return this.zigCallbackMap.size;
  },
  async preloadJsModules(specifiers = this.jsModules, baseURL = this.moduleBaseURL) {
    if (baseURL && !this.moduleBaseURL) {
      this.moduleBaseURL = baseURL;
    }
    if (!Array.isArray(specifiers) || specifiers.length === 0) {
      return;
    }
    for (const rawSpec of specifiers) {
      const spec = String(rawSpec);
      if (!spec || this.jsModuleCache.has(spec) || spec.startsWith('virtual:') || spec.startsWith('\0')) {
        continue;
      }
      const customLoader = this.jsModuleLoaders.get(spec);
      try {
        let loaded;
        if (typeof(customLoader) === 'function') {
          loaded = await customLoader();
        } else {
          let importTarget = spec;
          const effectiveBase = baseURL ?? this.moduleBaseURL;
          if ((spec.startsWith('./') || spec.startsWith('../')) && effectiveBase) {
            const cleanBase = String(effectiveBase).replace(/^zigar:/, '').split(/[?#]/)[0];
            const baseHref = cleanBase.includes('://')
              ? cleanBase
              : `file://${cleanBase.startsWith('/') ? '' : '/'}${cleanBase.replace(/\\/g, '/')}`;
            importTarget = new URL(spec, baseHref).href;
          }
          loaded = await import(importTarget);
        }
        this.registerJsModule(spec, loaded);
      } catch (importErr) {
        try {
          this.resolveJsModule(spec);
        } catch {
          throw importErr;
        }
      }
    }
  },
  ...(process.env.TARGET === 'wasm' ? {
    exports: {
      invokeJsHostOp: { argType: 'aaz', returnType: 'i' },
      createZigCallback: { argType: 'ai', returnType: 'i' },
      releaseZigCallback: { argType: 'i' },
      controlLastJsError: { argType: 'i', returnType: 'i' },
      disposeJsValue: { argType: 'ib', returnType: 'i' },
      beginAsyncDisposeJsValue: { argType: 'ib', returnType: 'i' },
      awaitAsyncDisposeJsValue: { argType: 'i', returnType: 'i' },
    },
  } : process.env.TARGET === 'node' ? {
    exports: {
      invokeJsHostOp: {},
      createZigCallback: {},
      releaseZigCallback: {},
      controlLastJsError: {},
      disposeJsValue: {},
      asyncDisposeJsValue: {},
    },
  /* c8 ignore next */
  } : undefined),
});

function getDisposeSymbol() {
  return Symbol.dispose ?? Symbol.for('nodejs.dispose');
}

function getAsyncDisposeSymbol() {
  return Symbol.asyncDispose ?? Symbol.for('nodejs.asyncDispose');
}

function isThenable(val) {
  return val !== null && (typeof(val) === 'object' || typeof(val) === 'function') && typeof(val.then) === 'function';
}

const noopMicrotaskTick = () => {};

function drainMicrotasksSync() {
  try {
    const proc = globalThis.process;
    if (globalThis.Bun) {
      proc?.getBuiltinModule?.('bun:jsc')?.drainMicrotasks?.();
    } else if (typeof(proc?._tickCallback) === 'function') {
      if (typeof(proc.nextTick) === 'function') {
        proc.nextTick(noopMicrotaskTick);
      }
      proc._tickCallback();
    }
  } catch {}
}

function hasDefaultFallbackTarget(val) {
  return val !== null && (typeof(val) === 'object' || typeof(val) === 'function');
}

function isEsModuleNamespaceObject(mod) {
  return mod !== null && typeof(mod) === 'object' && mod[Symbol.toStringTag] === 'Module';
}

function isFrozenNullProtoNamespace(mod) {
  return mod !== null
    && typeof(mod) === 'object'
    && Object.getPrototypeOf(mod) === null
    && Object.isFrozen(mod);
}

function isEsmExtension(specifier) {
  return typeof(specifier) === 'string' && /\.m[jt]s(?:$|[?#])/i.test(specifier);
}

function isCjsExtension(specifier) {
  return typeof(specifier) === 'string' && /\.c[jt]s(?:$|[?#])/i.test(specifier);
}

function hasOnlyCjsMirroredExports(mod, cjsExports = mod.default) {
  const target = Object(cjsExports);
  for (const key of Reflect.ownKeys(mod)) {
    if (typeof(key) !== 'string' || key === 'default' || key === 'module.exports') {
      continue;
    }
    if (!(key in target) && mod[key] !== undefined) {
      return false;
    }
  }
  return true;
}

function isCjsWrappedNamespace(mod) {
  return isEsModuleNamespaceObject(mod)
    && hasDefaultFallbackTarget(mod.default)
    && ('module.exports' in mod)
    && mod['module.exports'] === mod.default
    && hasOnlyCjsMirroredExports(mod);
}

function isRollupMergedCjsNamespace(mod) {
  if (isEsModuleNamespaceObject(mod) || !isFrozenNullProtoNamespace(mod) || !hasDefaultFallbackTarget(mod.default)) {
    return false;
  }
  if (!hasOnlyCjsMirroredExports(mod)) {
    return false;
  }
  let hasGetterExport = false;
  for (const key of Reflect.ownKeys(mod)) {
    if (typeof(key) !== 'string' || key === 'default') {
      continue;
    }
    const desc = Object.getOwnPropertyDescriptor(mod, key);
    if (!desc || typeof(desc.get) !== 'function' || desc.set !== undefined) {
      return false;
    }
    hasGetterExport = true;
  }
  return hasGetterExport;
}

function isSyntheticCjsNamespace(mod, specifier) {
  if (
    isCjsExtension(specifier)
    && isEsModuleNamespaceObject(mod)
    && hasDefaultFallbackTarget(mod.default)
  ) {
    return true;
  }
  if (isCjsWrappedNamespace(mod)) {
    return true;
  }
  return isRollupMergedCjsNamespace(mod);
}

function isModuleNamespaceLike(mod) {
  if (mod === null || typeof(mod) !== 'object') {
    return false;
  }
  return mod[Symbol.toStringTag] === 'Module'
    || mod.__esModule === true
    || Object.getPrototypeOf(mod) === null;
}

function unwrapModuleDefault(mod) {
  if (isModuleNamespaceLike(mod)) {
    const def = mod.default;
    if (def !== null && (typeof(def) === 'object' || typeof(def) === 'function') && def.__esModule === true && ('default' in def)) {
      return def.default;
    }
    return def;
  }
  if (mod !== null && (typeof(mod) === 'object' || typeof(mod) === 'function') && ('default' in mod)) {
    return mod.default;
  }
  return mod;
}

function readUsize(dv, byteOffset, ptrSize, littleEndian, asBigInt) {
  if (ptrSize === 8) {
    const v = dv.getBigUint64(byteOffset, littleEndian);
    return asBigInt ? v : Number(v);
  }
  const v = dv.getUint32(byteOffset, littleEndian);
  return asBigInt ? BigInt(v) : v;
}

function unwrapPayloadStructure(structure) {
  let s = structure;
  while (s && (s.type === StructureType.ErrorUnion || s.type === StructureType.Optional)) {
    s = s.instance?.members?.[0]?.structure;
  }
  return s;
}

function isConstStringStructure(structure) {
  let s = structure;
  if (s?.type === StructureType.Optional) {
    s = s.instance?.members?.[0]?.structure;
  }
  if (!s || s.type !== StructureType.Pointer || !(s.flags & PointerFlag.IsConst)) {
    return false;
  }
  const target = s.instance?.members?.[0]?.structure;
  if (!target) {
    return false;
  }
  if (target.type === StructureType.Slice && (target.flags & SliceFlag.IsString)) {
    return true;
  }
  if (target.type === StructureType.Array && (target.flags & ArrayFlag.IsString)) {
    return true;
  }
  return false;
}

function createNotCallableError(message) {
  const err = new TypeError(message);
  err.code = 'NotCallable';
  return err;
}

function matchErrorToSet(ErrorSet, err) {
  const ZigErrorCls = ErrorSet[CLASS];
  if (ZigErrorCls && err instanceof ZigErrorCls) {
    const m = ErrorSet(err);
    if (m) return m;
  }
  if (typeof(err) === 'string') {
    const m = ErrorSet(err) || (Object.hasOwn(ErrorSet, err) ? ErrorSet[err] : null);
    if (m) return m;
  } else if (err && typeof(err) === 'object') {
    if (isErrorJSON(err)) {
      const m = ErrorSet(err) || (Object.hasOwn(ErrorSet, err.error) ? ErrorSet[err.error] : null);
      if (m) return m;
    }
    if (typeof(err.code) === 'string' && Object.hasOwn(ErrorSet, err.code)) {
      return ErrorSet[err.code];
    }
    if (err instanceof Error) {
      const m = ErrorSet(err)
        || (err.name && Object.hasOwn(ErrorSet, err.name) ? ErrorSet[err.name] : null)
        || (err.message && Object.hasOwn(ErrorSet, err.message) ? ErrorSet[err.message] : null);
      if (m) return m;
    } else if (typeof(err.name) === 'string' && Object.hasOwn(ErrorSet, err.name)) {
      return ErrorSet[err.name];
    }
  }
  return (Object.hasOwn(ErrorSet, 'JsException') ? ErrorSet.JsException : null)
    ?? (Object.hasOwn(ErrorSet, 'Unexpected') ? ErrorSet.Unexpected : null);
}
