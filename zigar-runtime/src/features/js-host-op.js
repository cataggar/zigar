import {
  ArrayFlag, MemberType, PointerFlag, PosixError, SliceFlag, StructurePurpose, StructureType,
  VisitorFlag,
} from '../constants.js';
import { mixin } from '../environment.js';
import { isErrorJSON, NotInErrorSet } from '../errors.js';
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
  BinaryCreate: 10,
  BinaryRead: 11,
  BinaryWrite: 12,
  BinaryInfo: 13,
  BigIntFromWords: 14,
  BigIntFromString: 15,
  BigIntToWords: 16,
  BigIntToString: 17,
  GetIterator: 18,
  IteratorNext: 19,
  IteratorReturn: 20,
  PromiseSettle: 21,
  CollectionOp: 22,
};

export const AwaitMode = {
  Promise: 0,
  AsyncIteratorNext: 1,
  AsyncIteratorReturn: 2,
};

export const BinaryKind = {
  ArrayBuffer: 0,
  SharedArrayBuffer: 1,
  DataView: 2,
  Buffer: 3,
  Uint8Array: 4,
  Int8Array: 5,
  Uint8ClampedArray: 6,
  Uint16Array: 7,
  Int16Array: 8,
  Uint32Array: 9,
  Int32Array: 10,
  BigUint64Array: 11,
  BigInt64Array: 12,
  Float32Array: 13,
  Float64Array: 14,
};

export const BinaryInfoKind = {
  ByteLength: 0,
  ByteOffset: 1,
  ElementLength: 2,
  IsBuffer: 3,
  IsArray: 4,
};

export const CollectionSubOp = {
  ArrayInit: 0,
  ArrayWithCapacity: 1,
  ArrayLen: 2,
  ArrayGet: 3,
  ArraySet: 4,
  ArrayPush: 5,
  ArrayPop: 6,
  MapInit: 7,
  MapSize: 8,
  MapGet: 9,
  MapSet: 10,
  MapHas: 11,
  MapDelete: 12,
  MapClear: 13,
  MapKeys: 14,
  MapValues: 15,
  MapEntries: 16,
  SetInit: 17,
  SetSize: 18,
  SetAdd: 19,
  SetHas: 20,
  SetDelete: 21,
  SetClear: 22,
  SetValues: 23,
  RecordInit: 24,
  RecordGet: 25,
  RecordSet: 26,
  RecordHas: 27,
  RecordDelete: 28,
  RecordKeys: 29,
  TypedArrayGet: 30,
  TypedArraySet: 31,
  DataViewInit: 32,
  BinarySlice: 33,
  BinaryGetBuffer: 34,
  BufferFromString: 35,
  BufferToString: 36,
  DateNow: 37,
  DateFromMs: 38,
  DateFromIso: 39,
  DateGetMs: 40,
  DateToIso: 41,
  RegExpInit: 42,
  RegExpTest: 43,
  RegExpSource: 44,
  RegExpFlags: 45,
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
    this.workerErrorFrames = new Map();
    this.activeWorkerId = 0n;
    this.activeWorkerErrorFrame = null;
    this.pendingAsyncDisposals = new Map();
    this.nextAsyncDisposalTicket = 1;
    this.pendingPromiseAwaits = new Map();
    this.nextPromiseAwaitTicket = 1;
  },
  setWorkerJsErrorContext(workerId) {
    const prevFrame = this.activeWorkerErrorFrame;
    const id = BigInt(workerId || 0);
    this.activeWorkerId = id;
    if (id === 0n) {
      this.activeWorkerErrorFrame = null;
      if (prevFrame && !prevFrame.hasCapturedError && !prevFrame.hasPendingHostError) {
        this.workerErrorFrames.delete(prevFrame.workerId);
      }
      return;
    }
    let frame = this.workerErrorFrames.get(id);
    if (!frame) {
      frame = {
        workerId: id,
        hasPendingHostError: false,
        pendingHostError: undefined,
        hasCapturedError: false,
        capturedError: undefined,
      };
      this.workerErrorFrames.set(id, frame);
    }
    this.activeWorkerErrorFrame = frame;
  },
  withWorkerJsErrorContext(workerId, fn) {
    const prevId = this.activeWorkerId;
    this.setWorkerJsErrorContext(workerId);
    try {
      return fn();
    } finally {
      this.setWorkerJsErrorContext(prevId);
    }
  },
  clearWorkerJsErrors() {
    this.workerErrorFrames.clear();
    this.activeWorkerId = 0n;
    this.activeWorkerErrorFrame = null;
  },
  getHostErrorTarget() {
    return this.activeWorkerErrorFrame ?? this.activeContinuation?.hostErrorFrame ?? this.activeHostErrorFrame ?? this;
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
      if (method === undefined || method === null) {
        const syncSym = getDisposeSymbol();
        method = syncSym !== undefined ? target[syncSym] : undefined;
        if (method === undefined || method === null) {
          return 0;
        }
        if (typeof(method) !== 'function') {
          throw createNotCallableError('[Symbol.dispose] is not a function');
        }
      } else if (typeof(method) !== 'function') {
        throw createNotCallableError('[Symbol.asyncDispose] is not a function');
      }
      const rawResult = Reflect.apply(method, target, []);
      const then = (rawResult !== null && (typeof(rawResult) === 'object' || typeof(rawResult) === 'function'))
        ? rawResult.then
        : undefined;
      if (typeof(then) !== 'function') {
        return 0;
      }
      if (allowSuspend && this.useJSPI && this.activeContinuation) {
        const state = { ok: false, err: undefined };
        const promise = isPromise(rawResult)
          ? rawResult
          : new Promise((resolve, reject) => Reflect.apply(then, rawResult, [ resolve, reject ]));
        const tracked = promise.then(
          () => {
            state.ok = true;
          },
          (err) => {
            state.ok = false;
            state.err = err;
          },
        );
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
      if (isPromise(rawResult)) {
        rawResult.then(undefined, noop);
      } else {
        new Promise((resolve, reject) => Reflect.apply(then, rawResult, [ resolve, reject ])).then(undefined, noop);
      }
      return 2;
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
  asyncDisposeJsValueWorker(handle, catchMode, workerId, futexHandle) {
    const wId = BigInt(workerId || 0);
    const rawHandle = Number(handle) >>> 0;
    const shouldCatch = Boolean(catchMode);
    let deferredRelease = false;
    return this.withWorkerJsErrorContext(wId, () => {
      try {
        const target = this.getJsValue(rawHandle);
        if (target === null || target === undefined) {
          this.finalizeAsyncCall(futexHandle, 0);
          return 0;
        }
        const asyncSym = getAsyncDisposeSymbol();
        let method = asyncSym !== undefined ? target[asyncSym] : undefined;
        if (method === undefined || method === null) {
          const syncSym = getDisposeSymbol();
          method = syncSym !== undefined ? target[syncSym] : undefined;
          if (method === undefined || method === null) {
            this.finalizeAsyncCall(futexHandle, 0);
            return 0;
          }
          if (typeof(method) !== 'function') {
            throw createNotCallableError('[Symbol.dispose] is not a function');
          }
        } else if (typeof(method) !== 'function') {
          throw createNotCallableError('[Symbol.asyncDispose] is not a function');
        }
        const rawResult = Reflect.apply(method, target, []);
        const then = (rawResult !== null && (typeof(rawResult) === 'object' || typeof(rawResult) === 'function'))
          ? rawResult.then
          : undefined;
        if (typeof(then) !== 'function') {
          this.finalizeAsyncCall(futexHandle, 0);
          return 0;
        }
        deferredRelease = true;
        const promise = isPromise(rawResult)
          ? rawResult
          : new Promise((resolve, reject) => Reflect.apply(then, rawResult, [ resolve, reject ]));
        promise.then(
          () => {
            this.releaseJsValueIfValid(rawHandle);
            this.finalizeAsyncCall(futexHandle, 0);
          },
          (err) => {
            this.releaseJsValueIfValid(rawHandle);
            const status = this.withWorkerJsErrorContext(wId, () => {
              if (shouldCatch) {
                this.recordCapturedError(err);
                return 1;
              }
              this.recordPendingHostError(err);
              return 0;
            });
            this.finalizeAsyncCall(futexHandle, status);
          },
        );
        return 0;
      } catch (err) {
        const status = shouldCatch
          ? (this.recordCapturedError(err), 1)
          : (this.recordPendingHostError(err), 0);
        this.finalizeAsyncCall(futexHandle, status);
        return 0;
      } finally {
        if (!deferredRelease) {
          this.releaseJsValueIfValid(rawHandle);
        }
      }
    });
  },
  suppressPromiseRejection(handle) {
    const rawHandle = Number(handle) >>> 0;
    try {
      const target = this.getJsValue(rawHandle);
      suppressThenableRejection(target);
    } catch {
      // ignore invalid handle
    }
  },
  beginAwaitJsPromise(handle, mode) {
    const rawHandle = Number(handle) >>> 0;
    const awaitMode = Number(mode) >>> 0;
    let rawTarget;
    try {
      rawTarget = this.getJsValue(rawHandle);
    } catch (err) {
      this.recordPendingHostError(err);
      return 1;
    }
    if (!this.useJSPI || !this.activeContinuation) {
      if (awaitMode === AwaitMode.Promise) {
        suppressThenableRejection(rawTarget);
      }
      return 2;
    }
    const ticket = this.nextPromiseAwaitTicket;
    this.nextPromiseAwaitTicket = (ticket >= 0x0FFFFFFF) ? 1 : ticket + 1;
    try {
      const start = evaluateAwaitStart(rawTarget, awaitMode);
      if (start.immediateNoop) {
        return 0;
      }
      const state = { ok: false, val: undefined, err: undefined };
      const tracked = Promise.resolve(start.rawPromiseOrValue).then(
        (val) => {
          state.ok = true;
          state.val = val;
        },
        (err) => {
          state.ok = false;
          state.err = err;
        },
      );
      this.pendingPromiseAwaits.set(ticket, { tracked, awaitMode, state });
      return ((ticket << 3) | 7) >>> 0;
    } catch (syncErr) {
      this.pendingPromiseAwaits.set(ticket, {
        tracked: null,
        awaitMode,
        state: { ok: false, val: undefined, err: syncErr },
      });
      return ((ticket << 3) | 3) >>> 0;
    }
  },
  async awaitJsPromise(ticket) {
    const id = Number(ticket) >>> 0;
    const entry = this.pendingPromiseAwaits.get(id);
    if (entry?.tracked) {
      await entry.tracked;
    }
    return 0;
  },
  finishAwaitJsPromise(ticket, descriptorAddr, argAddr, argSize, doneFlagAddr) {
    const id = Number(ticket) >>> 0;
    const entry = this.pendingPromiseAwaits.get(id);
    if (!entry) {
      return PosixError.EFAULT;
    }
    this.pendingPromiseAwaits.delete(id);
    return this.marshalAwaitOutcome(descriptorAddr, argAddr, argSize, doneFlagAddr, entry.awaitMode, entry.state);
  },
  awaitJsPromiseWorker(handle, mode, descriptorAddr, argAddr, argSize, doneFlagAddr, workerId, futexHandle) {
    const wId = BigInt(workerId || 0);
    const rawHandle = Number(handle) >>> 0;
    const awaitMode = Number(mode) >>> 0;
    return this.withWorkerJsErrorContext(wId, () => {
      let start;
      try {
        const rawTarget = this.getJsValue(rawHandle);
        start = evaluateAwaitStart(rawTarget, awaitMode);
      } catch (syncErr) {
        const status = this.marshalAwaitOutcome(
          descriptorAddr,
          argAddr,
          argSize,
          doneFlagAddr,
          awaitMode,
          { ok: false, val: undefined, err: syncErr },
        );
        this.finalizeAsyncCall(futexHandle, status);
        return PosixError.NONE;
      }
      if (start.immediateNoop) {
        this.finalizeAsyncCall(futexHandle, PosixError.NONE);
        return PosixError.NONE;
      }
      Promise.resolve(start.rawPromiseOrValue).then(
        (val) => {
          const status = this.withWorkerJsErrorContext(wId, () =>
            this.marshalAwaitOutcome(
              descriptorAddr,
              argAddr,
              argSize,
              doneFlagAddr,
              awaitMode,
              { ok: true, val, err: undefined },
            ),
          );
          this.finalizeAsyncCall(futexHandle, status);
        },
        (err) => {
          const status = this.withWorkerJsErrorContext(wId, () =>
            this.marshalAwaitOutcome(
              descriptorAddr,
              argAddr,
              argSize,
              doneFlagAddr,
              awaitMode,
              { ok: false, val: undefined, err },
            ),
          );
          this.finalizeAsyncCall(futexHandle, status);
        },
      );
      return PosixError.NONE;
    });
  },
  marshalAwaitOutcome(descriptorAddr, argAddr, argSize, doneFlagAddr, awaitMode, state) {
    const savedPending = this.savePendingHostError();
    let context = null;
    this.syncCallDepth++;
    try {
      const entry = this.getHostOpEntry(descriptorAddr);
      const byteLen = Number(argSize || entry.argByteSize);
      const dv = this.obtainZigView(argAddr, byteLen, false);
      const { ArgStruct, extractors, isErrorUnionReturn, writeSuccess, writeError } = entry;
      const argStruct = ArgStruct(dv);
      if (VISIT in argStruct) {
        argStruct[VISIT]('reset', VisitorFlag.IgnoreUncreated);
        context = this.startContext();
        this.updatePointerTargets(context, argStruct, true);
        this.updateShadowTargets(context);
      }
      try {
        for (const ext of extractors) {
          if (ext.isAllocator) {
            ext.read(argStruct);
          }
        }
        if (!state.ok) {
          throw state.err;
        }
        if (awaitMode === AwaitMode.Promise) {
          writeSuccess(argStruct, state.val);
        } else if (awaitMode === AwaitMode.AsyncIteratorNext) {
          const step = state.val;
          if (step === null || typeof(step) !== 'object') {
            throw new TypeError('AsyncIterator result is not an object');
          }
          if (step.done) {
            writeByteFlag(this, doneFlagAddr, 1);
          } else {
            writeSuccess(argStruct, step.value);
          }
        } else if (awaitMode === AwaitMode.AsyncIteratorReturn) {
          const step = state.val;
          if (step === null || typeof(step) !== 'object') {
            throw new TypeError('AsyncIterator return result is not an object');
          }
          writeSuccess(argStruct, undefined);
        }
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
          case HostOpCode.BinaryCreate: {
            result = createBinaryObject(this, flags, jsArgs[0], Number(jsArgs[1]), Boolean(jsArgs[2]));
            break;
          }
          case HostOpCode.BinaryRead: {
            const srcView = getBinaryBytesView(jsArgs[0]);
            const destAddr = jsArgs[1];
            const reqLen = Number(jsArgs[2]);
            const offset = Number(jsArgs[3]);
            if (offset < 0 || offset > srcView.byteLength) {
              throw new RangeError('Offset is outside the bounds of the binary view');
            }
            const copyLen = Math.min(reqLen, srcView.byteLength - offset);
            if (copyLen > 0) {
              const zigDv = this.obtainZigView(destAddr, copyLen, false);
              if (!zigDv) {
                throw new TypeError('Invalid destination pointer for BinaryRead');
              }
              new Uint8Array(zigDv.buffer, zigDv.byteOffset, copyLen).set(srcView.subarray(offset, offset + copyLen));
              if (process.env.TARGET === 'node') {
                zigDv[FALLBACK]?.(true);
              }
            }
            result = copyLen;
            break;
          }
          case HostOpCode.BinaryWrite: {
            const dstView = getBinaryBytesView(jsArgs[0]);
            const srcAddr = jsArgs[1];
            const copyLen = Number(jsArgs[2]);
            const offset = Number(jsArgs[3]);
            if (offset < 0 || copyLen < 0 || offset + copyLen > dstView.byteLength) {
              throw new RangeError('Source slice exceeds target binary view bounds');
            }
            if (copyLen > 0) {
              const zigDv = this.obtainZigView(srcAddr, copyLen, false);
              if (!zigDv) {
                throw new TypeError('Invalid source pointer for BinaryWrite');
              }
              dstView.set(new Uint8Array(zigDv.buffer, zigDv.byteOffset, copyLen), offset);
            }
            result = undefined;
            break;
          }
          case HostOpCode.BinaryInfo: {
            const rawTarget = jsArgs[0];
            switch (flags) {
              case BinaryInfoKind.ByteLength:
                if (ArrayBuffer.isView(rawTarget) || rawTarget instanceof ArrayBuffer || isSharedArrayBuffer(rawTarget)) {
                  result = rawTarget.byteLength;
                } else {
                  throw new TypeError('Expected ArrayBuffer, SharedArrayBuffer, or ArrayBufferView');
                }
                break;
              case BinaryInfoKind.ByteOffset:
                if (ArrayBuffer.isView(rawTarget)) {
                  result = rawTarget.byteOffset;
                } else {
                  throw new TypeError('Expected ArrayBufferView');
                }
                break;
              case BinaryInfoKind.ElementLength:
                if (ArrayBuffer.isView(rawTarget) && !(rawTarget instanceof DataView)) {
                  result = rawTarget.length;
                } else {
                  throw new TypeError('Expected TypedArray');
                }
                break;
              case BinaryInfoKind.IsBuffer:
                result = Boolean(globalThis.Buffer?.isBuffer?.(rawTarget));
                break;
              case BinaryInfoKind.IsArray:
                result = Array.isArray(rawTarget);
                break;
              default:
                throw new Error(`Unknown BinaryInfo kind: ${flags}`);
            }
            break;
          }
          case HostOpCode.BigIntFromWords: {
            const isNegative = Boolean(jsArgs[0]);
            const lo = BigInt.asUintN(64, BigInt(jsArgs[1]));
            const hi = BigInt.asUintN(64, BigInt(jsArgs[2]));
            const mag = (hi << 64n) | lo;
            result = isNegative ? -mag : mag;
            break;
          }
          case HostOpCode.BigIntFromString: {
            result = parseBigIntString(jsArgs[0]);
            break;
          }
          case HostOpCode.BigIntToWords: {
            const rawTarget = jsArgs[0];
            if (typeof(rawTarget) !== 'bigint') {
              throw new TypeError('Expected a BigInt value');
            }
            const width = Number(jsArgs[1]);
            const isSigned = Boolean(jsArgs[2]);
            const outWordsAddr = jsArgs[3];
            let min;
            let max;
            if (isSigned) {
              const half = 1n << BigInt(width - 1);
              min = -half;
              max = half - 1n;
            } else {
              min = 0n;
              max = (1n << BigInt(width)) - 1n;
            }
            if (rawTarget < min || rawTarget > max) {
              result = 1;
            } else {
              const bits = BigInt.asUintN(128, rawTarget);
              const lo = BigInt.asUintN(64, bits);
              const hi = BigInt.asUintN(64, bits >> 64n);
              const outDv = this.obtainZigView(outWordsAddr, 16, false);
              outDv.setBigUint64(0, lo, this.littleEndian);
              outDv.setBigUint64(8, hi, this.littleEndian);
              if (process.env.TARGET === 'node') {
                outDv[FALLBACK]?.(true);
              }
              result = 0;
            }
            break;
          }
          case HostOpCode.BigIntToString: {
            const rawTarget = jsArgs[0];
            if (typeof(rawTarget) !== 'bigint') {
              throw new TypeError('Expected a BigInt value');
            }
            result = rawTarget.toString(Number(jsArgs[1]));
            break;
          }
          case HostOpCode.GetIterator: {
            const rawTarget = jsArgs[0];
            if (rawTarget === null || rawTarget === undefined) {
              throw new TypeError('Cannot iterate null or undefined');
            }
            const isAsync = Boolean(flags & 1);
            const method = isAsync
              ? (rawTarget[Symbol.asyncIterator] ?? rawTarget[Symbol.iterator])
              : rawTarget[Symbol.iterator];
            if (typeof(method) !== 'function') {
              throw createNotCallableError(isAsync ? 'Target is not async-iterable' : 'Target is not iterable');
            }
            const iter = Reflect.apply(method, rawTarget, []);
            if (iter === null || (typeof(iter) !== 'object' && typeof(iter) !== 'function')) {
              throw new TypeError('Iterator must be an object');
            }
            result = iter;
            break;
          }
          case HostOpCode.IteratorNext: {
            const iter = jsArgs[0];
            const doneFlagAddr = jsArgs[1];
            if (iter === null || (typeof(iter) !== 'object' && typeof(iter) !== 'function')) {
              throw new TypeError('Iterator must be an object');
            }
            const nextFn = iter.next;
            if (typeof(nextFn) !== 'function') {
              throw createNotCallableError('iterator.next is not a function');
            }
            const step = Reflect.apply(nextFn, iter, []);
            if (step === null || typeof(step) !== 'object') {
              throw new TypeError('Iterator result is not an object');
            }
            if (step.done) {
              writeByteFlag(this, doneFlagAddr, 1);
              if (process.env.TARGET === 'node') {
                dv[FALLBACK]?.(true);
              }
              return PosixError.NONE;
            }
            result = step.value;
            break;
          }
          case HostOpCode.IteratorReturn: {
            const iter = jsArgs[0];
            if (iter !== null && (typeof(iter) === 'object' || typeof(iter) === 'function')) {
              const retFn = iter.return;
              if (retFn !== undefined && retFn !== null) {
                if (typeof(retFn) !== 'function') {
                  throw createNotCallableError('iterator.return is not a function');
                }
                const step = Reflect.apply(retFn, iter, []);
                if (step === null || typeof(step) !== 'object') {
                  throw new TypeError('Iterator return result is not an object');
                }
              }
            }
            result = undefined;
            break;
          }
          case HostOpCode.PromiseSettle: {
            if (flags === 1) {
              const p = Promise.reject(jsArgs[0]);
              p.then(undefined, noop);
              result = p;
            } else if (flags === 2) {
              result = Promise.resolve(undefined);
            } else {
              result = Promise.resolve(jsArgs[0]);
            }
            break;
          }
          case HostOpCode.CollectionOp: {
            const out = executeCollectionOp(this, flags, jsArgs);
            if (out.skipWriteSuccess) {
              if (process.env.TARGET === 'node') {
                dv[FALLBACK]?.(true);
              }
              return PosixError.NONE;
            }
            result = out.result;
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
    const descSize = 16 + 3 * ptrSize;
    const dv = this.obtainZigView(descriptorAddr, descSize, false);
    const le = this.littleEndian;
    const signature = dv.getBigUint64(0, le);
    const flags = dv.getUint32(8, le);
    const trampolineThunk = readUsize(dv, 16, ptrSize, le, is64);
    const registerThunk = readUsize(dv, 16 + ptrSize, ptrSize, le, is64);
    const cancelThunk = readUsize(dv, 16 + 2 * ptrSize, ptrSize, le, is64);

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
      cancelThunk,
      unwrapString,
      is64,
      sync: !(flags & 1),
      once: Boolean(flags & 2),
    };
    this.zigCallbackTemplateCache.set(descriptorAddr, template);
    return template;
  },
  cancelZigCallbackSlot(cancelThunk, slotAddr, zeroAddr) {
    if (!cancelThunk) {
      return;
    }
    if (process.env.TARGET === 'wasm') {
      const runner = this.runThunkSync ?? this.runThunk;
      if (runner) {
        const prevContinuation = this.activeContinuation;
        this.activeContinuation = null;
        try {
          runner(cancelThunk, slotAddr, zeroAddr);
        } finally {
          this.activeContinuation = prevContinuation;
        }
      }
    } else {
      this.runThunk?.(cancelThunk, slotAddr, zeroAddr);
    }
  },
  createZigCallback(descriptorAddr, callbackId) {
    const savedPending = this.savePendingHostError();
    try {
      const id = Number(callbackId) >>> 0;
      const template = this.getZigCallbackTemplate(descriptorAddr);
      const caller = this.createOutboundCaller(template.thunkHolder, template.ArgStruct);
      caller.zigarSync = template.sync;
      const slotAddr = template.is64 ? BigInt(id) : id;
      const zeroAddr = template.is64 ? 0n : 0;
      const slotDV = new DataView(new ArrayBuffer(0));
      slotDV[ZIG] = { address: slotAddr, len: 0 };
      caller[MEMORY] = slotDV;
      const state = { id, released: false, handle: 0, handleReleased: false };
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
      const finishOnceCleanup = () => {
        if (this.zigCallbackMap.get(id) === state) {
          this.cancelZigCallbackSlot(template.cancelThunk, slotAddr, zeroAddr);
          this.releaseZigCallback(id);
        }
      };
      const wrapper = (...args) => {
        if (state.released) {
          throw new Error('Zig callback has already been released');
        }
        if (isOnce) {
          state.released = true;
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
                finishOnceCleanup();
              }
            });
          }
          return unwrapResult(res);
        } finally {
          if (isOnce && !asyncResult) {
            finishOnceCleanup();
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
      if (!state.handleReleased) {
        state.handleReleased = true;
        this.releaseJsValueIfValid(state.handle);
      }
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
      beginAwaitJsPromise: { argType: 'ii', returnType: 'i' },
      awaitJsPromise: { argType: 'i', returnType: 'i' },
      finishAwaitJsPromise: { argType: 'iaaza', returnType: 'i' },
    },
  } : process.env.TARGET === 'node' ? {
    imports: {
      finalizeAsyncCall: {},
    },
    exports: {
      invokeJsHostOp: {},
      createZigCallback: {},
      releaseZigCallback: {},
      controlLastJsError: {},
      disposeJsValue: {},
      asyncDisposeJsValue: {},
      asyncDisposeJsValueWorker: {},
      awaitJsPromiseWorker: {},
      suppressPromiseRejection: {},
      setWorkerJsErrorContext: {},
      clearWorkerJsErrors: {},
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

const noop = () => {};

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

const TYPED_ARRAY_CTORS = [
  Uint8Array,
  Int8Array,
  Uint8ClampedArray,
  Uint16Array,
  Int16Array,
  Uint32Array,
  Int32Array,
  BigUint64Array,
  BigInt64Array,
  Float32Array,
  Float64Array,
];

function isSharedArrayBuffer(val) {
  return typeof(SharedArrayBuffer) === 'function' && val instanceof SharedArrayBuffer;
}

function getBinaryBytesView(rawTarget) {
  if (ArrayBuffer.isView(rawTarget)) {
    return new Uint8Array(rawTarget.buffer, rawTarget.byteOffset, rawTarget.byteLength);
  }
  if (rawTarget instanceof ArrayBuffer || isSharedArrayBuffer(rawTarget)) {
    return new Uint8Array(rawTarget);
  }
  throw new TypeError('Expected ArrayBuffer, SharedArrayBuffer, or ArrayBufferView');
}

function copyZigBytesToUint8(env, ptrAddr, dstUint8) {
  const byteLen = dstUint8.byteLength;
  if (byteLen === 0) {
    return;
  }
  const zigDv = env.obtainZigView(ptrAddr, byteLen, false);
  if (!zigDv) {
    throw new TypeError('Invalid source pointer for binary creation');
  }
  dstUint8.set(new Uint8Array(zigDv.buffer, zigDv.byteOffset, byteLen));
}

function createBinaryObject(env, kind, ptrAddr, len, copyFromZig) {
  switch (kind) {
    case BinaryKind.ArrayBuffer: {
      const ab = new ArrayBuffer(len);
      if (copyFromZig && len > 0) {
        copyZigBytesToUint8(env, ptrAddr, new Uint8Array(ab));
      }
      return ab;
    }
    case BinaryKind.SharedArrayBuffer: {
      if (typeof(SharedArrayBuffer) !== 'function') {
        throw new ReferenceError('SharedArrayBuffer is not available in this JS runtime');
      }
      const sab = new SharedArrayBuffer(len);
      if (copyFromZig && len > 0) {
        copyZigBytesToUint8(env, ptrAddr, new Uint8Array(sab));
      }
      return sab;
    }
    case BinaryKind.DataView: {
      const ab = new ArrayBuffer(len);
      if (copyFromZig && len > 0) {
        copyZigBytesToUint8(env, ptrAddr, new Uint8Array(ab));
      }
      return new DataView(ab);
    }
    case BinaryKind.Buffer: {
      if (typeof(globalThis.Buffer?.alloc) !== 'function') {
        throw new ReferenceError('Buffer is not defined in this JS runtime');
      }
      const buf = copyFromZig ? globalThis.Buffer.allocUnsafe(len) : globalThis.Buffer.alloc(len);
      if (copyFromZig && len > 0) {
        copyZigBytesToUint8(env, ptrAddr, buf);
      }
      return buf;
    }
    default: {
      const ctor = TYPED_ARRAY_CTORS[kind - BinaryKind.Uint8Array];
      if (!ctor) {
        throw new Error(`Unknown binary kind: ${kind}`);
      }
      const ta = new ctor(len);
      if (copyFromZig && len > 0) {
        copyZigBytesToUint8(env, ptrAddr, new Uint8Array(ta.buffer, ta.byteOffset, ta.byteLength));
      }
      return ta;
    }
  }
}

function parseBigIntString(str) {
  if (typeof(str) !== 'string') {
    throw new TypeError('Expected string for BigInt.fromString');
  }
  const trimmed = str.trim();
  if (trimmed.length === 0) {
    throw new SyntaxError('Cannot convert empty string to a BigInt');
  }
  if (trimmed.startsWith('+') && trimmed.length > 1 && !/\s/.test(trimmed[1])) {
    const body = trimmed.slice(1);
    if (/^0[xXbBoO]/.test(body)) {
      throw new SyntaxError(`Cannot convert ${str} to a BigInt`);
    }
    return BigInt(body);
  }
  if (/^-0[xXbBoO][0-9a-fA-F]+$/.test(trimmed)) {
    return -BigInt(trimmed.slice(1));
  }
  return BigInt(trimmed);
}

function writeByteFlag(env, flagAddr, value) {
  if (!flagAddr) {
    return;
  }
  const dv = env.obtainZigView(flagAddr, 1, false);
  if (dv) {
    dv.setUint8(0, value);
    if (process.env.TARGET === 'node') {
      dv[FALLBACK]?.(true);
    }
  }
}

function suppressThenableRejection(val) {
  if (val !== null && (typeof(val) === 'object' || typeof(val) === 'function')) {
    if (isPromise(val)) {
      val.then(undefined, noop);
    } else {
      try {
        const then = val.then;
        if (typeof(then) === 'function') {
          Reflect.apply(then, val, [ noop, noop ]);
        }
      } catch {
        // ignore getter error
      }
    }
  }
}

function evaluateAwaitStart(rawTarget, awaitMode) {
  if (awaitMode === AwaitMode.Promise) {
    return { immediateNoop: false, rawPromiseOrValue: rawTarget };
  }
  if (awaitMode === AwaitMode.AsyncIteratorNext) {
    if (rawTarget === null || (typeof(rawTarget) !== 'object' && typeof(rawTarget) !== 'function')) {
      throw new TypeError('AsyncIterator must be an object');
    }
    const nextFn = rawTarget.next;
    if (typeof(nextFn) !== 'function') {
      throw createNotCallableError('asyncIterator.next is not a function');
    }
    return { immediateNoop: false, rawPromiseOrValue: Reflect.apply(nextFn, rawTarget, []) };
  }
  if (awaitMode === AwaitMode.AsyncIteratorReturn) {
    if (rawTarget === null || (typeof(rawTarget) !== 'object' && typeof(rawTarget) !== 'function')) {
      return { immediateNoop: true, rawPromiseOrValue: undefined };
    }
    const retFn = rawTarget.return;
    if (retFn === undefined || retFn === null) {
      return { immediateNoop: true, rawPromiseOrValue: undefined };
    }
    if (typeof(retFn) !== 'function') {
      throw createNotCallableError('asyncIterator.return is not a function');
    }
    return { immediateNoop: false, rawPromiseOrValue: Reflect.apply(retFn, rawTarget, []) };
  }
  throw new Error(`Unknown await mode: ${awaitMode}`);
}

function ensureArray(val) {
  if (!Array.isArray(val)) {
    throw new TypeError('Expected JS Array');
  }
  return val;
}

function ensureMap(val) {
  if (!(val instanceof Map)) {
    throw new TypeError('Expected JS Map');
  }
  return val;
}

function ensureSet(val) {
  if (!(val instanceof Set)) {
    throw new TypeError('Expected JS Set');
  }
  return val;
}

function ensureRecordObject(val) {
  if (val === null || (typeof(val) !== 'object' && typeof(val) !== 'function')) {
    throw new TypeError('Expected JS Object');
  }
  return val;
}

function ensureTypedArray(val) {
  if (!ArrayBuffer.isView(val) || val instanceof DataView) {
    throw new TypeError('Expected JS TypedArray');
  }
  return val;
}

function ensureDate(val) {
  if (!(val instanceof Date)) {
    throw new TypeError('Expected JS Date');
  }
  return val;
}

function ensureRegExp(val) {
  if (!(val instanceof RegExp)) {
    throw new TypeError('Expected JS RegExp');
  }
  return val;
}

function executeCollectionOp(env, subOp, jsArgs) {
  switch (subOp) {
    case CollectionSubOp.ArrayInit:
      return { result: [], skipWriteSuccess: false };
    case CollectionSubOp.ArrayWithCapacity:
      return { result: new Array(Number(jsArgs[0])), skipWriteSuccess: false };
    case CollectionSubOp.ArrayLen:
      return { result: ensureArray(jsArgs[0]).length, skipWriteSuccess: false };
    case CollectionSubOp.ArrayGet: {
      const a = ensureArray(jsArgs[0]);
      const idx = Number(jsArgs[1]);
      if (idx < 0 || idx >= a.length) {
        throw new RangeError('Array index out of bounds');
      }
      return { result: a[idx], skipWriteSuccess: false };
    }
    case CollectionSubOp.ArraySet: {
      const a = ensureArray(jsArgs[0]);
      const idx = Number(jsArgs[1]);
      if (idx < 0) {
        throw new RangeError('Negative array index');
      }
      a[idx] = jsArgs[2];
      return { result: undefined, skipWriteSuccess: false };
    }
    case CollectionSubOp.ArrayPush:
      return { result: ensureArray(jsArgs[0]).push(jsArgs[1]), skipWriteSuccess: false };
    case CollectionSubOp.ArrayPop: {
      const a = ensureArray(jsArgs[0]);
      if (a.length === 0) {
        writeByteFlag(env, jsArgs[1], 1);
        return { result: undefined, skipWriteSuccess: true };
      }
      return { result: a.pop(), skipWriteSuccess: false };
    }
    case CollectionSubOp.MapInit:
      return { result: new Map(), skipWriteSuccess: false };
    case CollectionSubOp.MapSize:
      return { result: ensureMap(jsArgs[0]).size, skipWriteSuccess: false };
    case CollectionSubOp.MapGet: {
      const m = ensureMap(jsArgs[0]);
      const key = jsArgs[1];
      if (!m.has(key)) {
        writeByteFlag(env, jsArgs[2], 1);
        return { result: undefined, skipWriteSuccess: true };
      }
      return { result: m.get(key), skipWriteSuccess: false };
    }
    case CollectionSubOp.MapSet:
      ensureMap(jsArgs[0]).set(jsArgs[1], jsArgs[2]);
      return { result: undefined, skipWriteSuccess: false };
    case CollectionSubOp.MapHas:
      return { result: ensureMap(jsArgs[0]).has(jsArgs[1]), skipWriteSuccess: false };
    case CollectionSubOp.MapDelete:
      return { result: ensureMap(jsArgs[0]).delete(jsArgs[1]), skipWriteSuccess: false };
    case CollectionSubOp.MapClear:
      ensureMap(jsArgs[0]).clear();
      return { result: undefined, skipWriteSuccess: false };
    case CollectionSubOp.MapKeys:
      return { result: ensureMap(jsArgs[0]).keys(), skipWriteSuccess: false };
    case CollectionSubOp.MapValues:
      return { result: ensureMap(jsArgs[0]).values(), skipWriteSuccess: false };
    case CollectionSubOp.MapEntries:
      return { result: ensureMap(jsArgs[0]).entries(), skipWriteSuccess: false };
    case CollectionSubOp.SetInit:
      return { result: new Set(), skipWriteSuccess: false };
    case CollectionSubOp.SetSize:
      return { result: ensureSet(jsArgs[0]).size, skipWriteSuccess: false };
    case CollectionSubOp.SetAdd:
      ensureSet(jsArgs[0]).add(jsArgs[1]);
      return { result: undefined, skipWriteSuccess: false };
    case CollectionSubOp.SetHas:
      return { result: ensureSet(jsArgs[0]).has(jsArgs[1]), skipWriteSuccess: false };
    case CollectionSubOp.SetDelete:
      return { result: ensureSet(jsArgs[0]).delete(jsArgs[1]), skipWriteSuccess: false };
    case CollectionSubOp.SetClear:
      ensureSet(jsArgs[0]).clear();
      return { result: undefined, skipWriteSuccess: false };
    case CollectionSubOp.SetValues:
      return { result: ensureSet(jsArgs[0]).values(), skipWriteSuccess: false };
    case CollectionSubOp.RecordInit:
      return { result: {}, skipWriteSuccess: false };
    case CollectionSubOp.RecordGet: {
      const obj = ensureRecordObject(jsArgs[0]);
      const key = jsArgs[1];
      if (!Object.hasOwn(obj, key)) {
        writeByteFlag(env, jsArgs[2], 1);
        return { result: undefined, skipWriteSuccess: true };
      }
      return { result: obj[key], skipWriteSuccess: false };
    }
    case CollectionSubOp.RecordSet: {
      const obj = ensureRecordObject(jsArgs[0]);
      const key = jsArgs[1];
      const val = jsArgs[2];
      if (key === '__proto__') {
        Object.defineProperty(obj, '__proto__', {
          value: val,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      } else {
        obj[key] = val;
      }
      return { result: undefined, skipWriteSuccess: false };
    }
    case CollectionSubOp.RecordHas:
      return { result: Object.hasOwn(ensureRecordObject(jsArgs[0]), jsArgs[1]), skipWriteSuccess: false };
    case CollectionSubOp.RecordDelete:
      return { result: Reflect.deleteProperty(ensureRecordObject(jsArgs[0]), jsArgs[1]), skipWriteSuccess: false };
    case CollectionSubOp.RecordKeys:
      return { result: Object.keys(ensureRecordObject(jsArgs[0])), skipWriteSuccess: false };
    case CollectionSubOp.TypedArrayGet: {
      const ta = ensureTypedArray(jsArgs[0]);
      const idx = Number(jsArgs[1]);
      if (idx < 0 || idx >= ta.length) {
        throw new RangeError('TypedArray index out of bounds');
      }
      return { result: ta[idx], skipWriteSuccess: false };
    }
    case CollectionSubOp.TypedArraySet: {
      const ta = ensureTypedArray(jsArgs[0]);
      const idx = Number(jsArgs[1]);
      if (idx < 0 || idx >= ta.length) {
        throw new RangeError('TypedArray index out of bounds');
      }
      ta[idx] = jsArgs[2];
      return { result: undefined, skipWriteSuccess: false };
    }
    case CollectionSubOp.DataViewInit: {
      const ab = jsArgs[0];
      const offset = Number(jsArgs[1]);
      const hasLen = Boolean(jsArgs[2]);
      const len = Number(jsArgs[3]);
      return { result: hasLen ? new DataView(ab, offset, len) : new DataView(ab, offset), skipWriteSuccess: false };
    }
    case CollectionSubOp.BinarySlice: {
      const target = jsArgs[0];
      const begin = Number(jsArgs[1]);
      const hasEnd = Boolean(jsArgs[2]);
      const end = Number(jsArgs[3]);
      if (!(target instanceof ArrayBuffer) && !isSharedArrayBuffer(target)) {
        throw new TypeError('Expected ArrayBuffer or SharedArrayBuffer');
      }
      return { result: hasEnd ? target.slice(begin, end) : target.slice(begin), skipWriteSuccess: false };
    }
    case CollectionSubOp.BinaryGetBuffer: {
      const view = jsArgs[0];
      if (!ArrayBuffer.isView(view)) {
        throw new TypeError('Expected ArrayBufferView');
      }
      return { result: view.buffer, skipWriteSuccess: false };
    }
    case CollectionSubOp.BufferFromString: {
      if (typeof(globalThis.Buffer?.from) !== 'function') {
        throw new ReferenceError('Buffer is not defined in this JS runtime');
      }
      return { result: globalThis.Buffer.from(String(jsArgs[0]), 'utf8'), skipWriteSuccess: false };
    }
    case CollectionSubOp.BufferToString: {
      const target = jsArgs[0];
      if (globalThis.Buffer?.isBuffer?.(target)) {
        return { result: target.toString('utf8'), skipWriteSuccess: false };
      }
      if (ArrayBuffer.isView(target)) {
        return { result: decodeText(new Uint8Array(target.buffer, target.byteOffset, target.byteLength)), skipWriteSuccess: false };
      }
      throw new TypeError('Expected Buffer or Uint8Array');
    }
    case CollectionSubOp.DateNow:
      return { result: Date.now(), skipWriteSuccess: false };
    case CollectionSubOp.DateFromMs:
      return { result: new Date(Number(jsArgs[0])), skipWriteSuccess: false };
    case CollectionSubOp.DateFromIso: {
      const d = new Date(String(jsArgs[0]));
      if (Number.isNaN(d.getTime())) {
        throw new RangeError('Invalid ISO date string');
      }
      return { result: d, skipWriteSuccess: false };
    }
    case CollectionSubOp.DateGetMs:
      return { result: ensureDate(jsArgs[0]).getTime(), skipWriteSuccess: false };
    case CollectionSubOp.DateToIso:
      return { result: ensureDate(jsArgs[0]).toISOString(), skipWriteSuccess: false };
    case CollectionSubOp.RegExpInit:
      return { result: new RegExp(String(jsArgs[0]), String(jsArgs[1])), skipWriteSuccess: false };
    case CollectionSubOp.RegExpTest:
      return { result: ensureRegExp(jsArgs[0]).test(String(jsArgs[1])), skipWriteSuccess: false };
    case CollectionSubOp.RegExpSource:
      return { result: ensureRegExp(jsArgs[0]).source, skipWriteSuccess: false };
    case CollectionSubOp.RegExpFlags:
      return { result: ensureRegExp(jsArgs[0]).flags, skipWriteSuccess: false };
    default:
      throw new Error(`Unknown collection sub-operation: ${subOp}`);
  }
}
