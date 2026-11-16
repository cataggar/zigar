import { VisitorFlag, PosixError, StructureType, StructurePurpose, MemberType, PointerFlag, SliceFlag, ArrayFlag } from '../constants.js';
import { mixin } from '../environment.js';
import { NotInErrorSet, isErrorJSON } from '../errors.js';
import { ZIG, MEMORY, VISIT, FALLBACK, THROWING, RETURN, ALLOCATOR, SLOTS, VIVIFICATE, RESTORE, CLASS } from '../symbols.js';
import { decodeText, hasJsValue, clearView } from '../utils.js';

const HostOpCode = {
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

const HostOpFlag = {
  DynamicKey: 1 << 0,
  ModuleDefault: 1 << 1,
};

var jsHostOp = mixin({
  init() {
    this.jsHostOpCache = new Map();
    this.jsKeyCache = new Map();
    this.jsKeyDecodeCount = 0;
    this.jsModuleCache = new Map();
    this.jsModuleLoaders = new Map();
    this.jsModuleNamespaces = new WeakSet();
    this.moduleBaseURL = null;
    this.zigCallbackTemplateCache = new Map();
    this.zigCallbackMap = new Map();
    this.syncCallDepth = 0;
    this.hasPendingHostError = false;
    this.pendingHostError = undefined;
    this.activeHostErrorFrame = null;
  },
  getHostErrorTarget() {
    return this.activeContinuation?.hostErrorFrame ?? this.activeHostErrorFrame ?? this;
  },
  recordPendingHostError(err) {
    const target = this.getHostErrorTarget();
    if (!target.hasPendingHostError) {
      target.hasPendingHostError = true;
      target.pendingHostError = err;
    }
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
  trackJsModuleNamespace(moduleExports) {
    if (moduleExports !== null && (typeof(moduleExports) === 'object' || typeof(moduleExports) === 'function')) {
      this.jsModuleNamespaces.add(moduleExports);
    }
  },
  registerJsModule(specifier, moduleExports) {
    this.jsModuleCache.set(String(specifier), moduleExports);
    this.trackJsModuleNamespace(moduleExports);
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
          this.registerJsModule(spec, loaded);
          return loaded;
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
    const is64 = Boolean(this.memory64 || "32" == 64);
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
        setError.call(euObj, matched);
        const mem = (euObj[RESTORE]) ? euObj[RESTORE]() : euObj[MEMORY];
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
            const target = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            if (
              target !== null
              && target !== undefined
              && !(propKey in Object(target))
              && this.jsModuleNamespaces.has(target)
              && hasDefaultFallbackTarget(target.default)
            ) {
              result = target.default[propKey];
            } else {
              result = target[propKey];
            }
            break;
          }
          case HostOpCode.SetProp: {
            const target = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            const value = dynamicKey ? jsArgs[2] : jsArgs[1];
            if (
              target !== null
              && target !== undefined
              && !(propKey in Object(target))
              && this.jsModuleNamespaces.has(target)
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
            const target = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            if (
              target !== null
              && target !== undefined
              && !(propKey in Object(target))
              && this.jsModuleNamespaces.has(target)
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
            const target = jsArgs[0];
            const propKey = dynamicKey ? jsArgs[1] : key;
            let present = Reflect.has(target, propKey);
            if (
              !present
              && this.jsModuleNamespaces.has(target)
              && hasDefaultFallbackTarget(target.default)
            ) {
              present = Reflect.has(Object(target.default), propKey);
            }
            result = present;
            break;
          }
          case HostOpCode.CallFn: {
            let callee = jsArgs[0];
            if (
              typeof(callee) !== 'function'
              && callee !== null
              && callee !== undefined
              && this.jsModuleNamespaces.has(callee)
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
            const target = jsArgs[0];
            const methodKey = dynamicKey ? jsArgs[1] : key;
            const callArgs = dynamicKey ? jsArgs.slice(2) : jsArgs.slice(1);
            if (target === null || target === undefined) {
              throw new TypeError(`Cannot read properties of ${target} (reading '${String(methodKey)}')`);
            }
            let receiver = target;
            let method = target[methodKey];
            if (this.jsModuleNamespaces.has(target) && hasDefaultFallbackTarget(target.default)) {
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
            let ctor = jsArgs[0];
            if (
              typeof(ctor) !== 'function'
              && ctor !== null
              && ctor !== undefined
              && this.jsModuleNamespaces.has(ctor)
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
        if ("wasm" === 'node') ;
        return PosixError.NONE;
      } catch (err) {
        if (isErrorUnionReturn) {
          writeError(argStruct, err);
          if ("wasm" === 'node') ;
          return PosixError.NONE;
        }
        if (ArgStruct[THROWING] && err instanceof Error) {
          argStruct[RETURN](err);
          if ("wasm" === 'node') ;
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
    const is64 = Boolean(this.memory64 || "32" == 64);
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
      const wrapper = (...args) => {
        if (state.released) {
          throw new Error('Zig callback has already been released');
        }
        const res = caller(...args);
        const pending = this.consumePendingHostError();
        if (pending) {
          throw pending.error;
        }
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
  ...({
    exports: {
      invokeJsHostOp: { argType: 'aaz', returnType: 'i' },
      createZigCallback: { argType: 'ai', returnType: 'i' },
      releaseZigCallback: { argType: 'i' },
    },
  } ),
});

function hasDefaultFallbackTarget(val) {
  return val !== null && (typeof(val) === 'object' || typeof(val) === 'function');
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
    return mod.default;
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

export { HostOpCode, HostOpFlag, jsHostOp as default };
