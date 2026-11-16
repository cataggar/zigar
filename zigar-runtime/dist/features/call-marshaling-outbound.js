import { StructureType, StructurePurpose, MemberType } from '../constants.js';
import { mixin } from '../environment.js';
import { Exit, UndefinedArgument, adjustArgumentError, ZigError } from '../errors.js';
import { ATTRIBUTES, MEMORY, FINALIZE, GENERATOR, RETURN, SETTERS, VISIT, UPDATE, TRANSFORM, VIVIFICATE, PROMISE, ALLOCATOR } from '../symbols.js';
import { isPromise } from '../utils.js';

var callMarshalingOutbound = mixin({
  createOutboundCaller(thunk, ArgStruct) {
    const thisEnv = this;
    const self = function (...args) {
      {
        if (!thisEnv.runThunk) {
          return thisEnv.initPromise.then(() => {
            return self(...args);
          });
        }
      }
      // `this` is present when running a promise and generator callback received from a inbound call
      // it's going to be the argument struct of that call
      const argStruct = new ArgStruct(args, this?.[ALLOCATOR]);
      {
        try {
          return thisEnv.invokeThunk(thunk, self, argStruct);
        } catch (err) {
          // do nothing when exit code is 0
          if (err instanceof Exit && err.code === 0) {
            return;
          }
          throw err;
        }
      }
    };
    return self;
  },
  copyArguments(argStruct, argList, members, options, argAlloc) {
    let destIndex = 0, srcIndex = 0;
    let allocatorCount = 0;
    const setters = argStruct[SETTERS];
    const allocatedHandles = (this.allocJsValue) ? [] : null;
    const prevPending = this.pendingJsHandles;
    if (allocatedHandles) {
      this.pendingJsHandles = allocatedHandles;
    }
    try {
      for (const { type, structure } of members) {
        let arg, promise, generator, signal, hasArg = false;
        if (structure.type === StructureType.Struct) {
          switch (structure.purpose) {
            case StructurePurpose.Allocator:
              // use programmer-supplied allocator if found in options object, handling rare scenarios
              // where a function uses multiple allocators
              const allocator = (++allocatorCount === 1)
              ? options?.['allocator'] ?? options?.['allocator1']
              : options?.[`allocator${allocatorCount}`];
              // otherwise use default allocator which allocates relocatable memory from JS engine
              arg = allocator ?? this.createDefaultAllocator(argStruct, structure);
              hasArg = true;
              break;
            case StructurePurpose.Promise:
              promise ||= this.createPromise(structure, argStruct, options?.['callback']);
              arg = promise;
              hasArg = true;
              break;
            case StructurePurpose.Generator:
              generator ||= this.createGenerator(structure, argStruct, options?.['callback']);
              arg = generator;
              hasArg = true;
              break;
            case StructurePurpose.AbortSignal:
              // create an Int32Array with one element, hooking it up to the programmer-supplied
              // AbortSignal object if found
              signal ||= this.createSignal(structure, options?.['signal']);
              arg = signal;
              hasArg = true;
              break;
            case StructurePurpose.File:
              arg = this.createFile(argList[srcIndex++]);
              hasArg = true;
              break;
            case StructurePurpose.Directory:
              arg = this.createDirectory(argList[srcIndex++]);
              hasArg = true;
              break;
          }
        }
        if (!hasArg) {
          // just a regular argument
          arg = argList[srcIndex++];
          // only void and JsValue allow the value of undefined
          if (arg === undefined && type !== MemberType.Void && structure.purpose !== StructurePurpose.JsValue) {
            throw new UndefinedArgument();
          }
        }
        try {
          const set = setters[destIndex++];
          set.call(argStruct, arg, argAlloc);
        } catch (err) {
          throw adjustArgumentError(err, destIndex - 1);
        }
      }
    } catch (err) {
      if (allocatedHandles) {
        for (const handle of allocatedHandles) {
          this.releaseJsValue(handle);
        }
      }
      throw err;
    } finally {
      if (allocatedHandles) {
        this.pendingJsHandles = prevPending;
      }
    }
  },
  invokeThunk(thunk, fn, argStruct) {
    const context = this.startContext();
    const attrs = argStruct[ATTRIBUTES];
    const thunkAddress = this.getViewAddress(thunk[MEMORY]);
    const fnAddress = this.getViewAddress(fn[MEMORY]);
    const isAsync = FINALIZE in argStruct;
    const hasPointers = VISIT in argStruct;
    let argAddress, attrAddress;
    try {
      if (hasPointers) {
        this.updatePointerAddresses(context, argStruct);
      }
      // return address of shadow for argumnet struct
      argAddress = ("wasm" === 'wasm')
      ? this.getShadowAddress(context, argStruct, null, false)
      : this.getViewAddress(argStruct[MEMORY]);
      // get address of attributes if function variadic
      attrAddress = ("wasm" === 'wasm')
      ? (attrs) ? this.getShadowAddress(context, attrs) : 0
      : (attrs) ? this.getViewAddress(attrs[MEMORY]) : 0;
      this.updateShadows(context);
    } catch (err) {
      if (context.jsValueTargets) {
        this.finalizeJsValueTargets(context, { abortOnly: true, failed: true });
      }
      this.endContext();
      throw err;
    }
    let finalized = false;
    const finalize = (failed = false, retvalStruct = null) => {
      let finalizeErr = null;
      try {
        this.updateShadowTargets(context);
        if (context.jsValueTargets) {
          this.finalizeJsValueTargets(context, { failed, retvalStruct });
        } else if (!failed && retvalStruct) {
          this.consumeJsValueRetval?.(retvalStruct);
        }
        // create objects that pointers point to
        if (hasPointers) {
          this.updatePointerTargets(context, argStruct);
        }
      } catch (err) {
        finalizeErr = err;
      } finally {
        this.flushStreams?.();
        this.endContext();
        finalized = true;
      }
      if (finalizeErr && !failed) {
        throw finalizeErr;
      }
    };
    if (isAsync) {
      argStruct[FINALIZE] = () => finalize(false);
    }
    const runnerName = (attrs) ? 'runVariadicThunk' : 'runThunk';
    const syncRunner = this[`${runnerName}Sync`] ;
    let useSyncRunner = false;
    if (syncRunner) {
      if (this.comptime || fn.zigarSync || this.syncCallDepth > 0) {
        useSyncRunner = true;
      } else if (this.useJSPI && this.jspiMode !== 'all' && !this.customWASI) {
        const fnSlot = Number(fnAddress);
        if (this.asyncExportSet) {
          useSyncRunner = !this.asyncExportSet.has(fn.name) && (!this.syncFuncSet || this.syncFuncSet.has(fnSlot));
        } else if (this.syncFuncSet) {
          useSyncRunner = this.syncFuncSet.has(fnSlot);
        }
      }
    }
    let success;
    const errorFrame = {
      hasPendingHostError: false,
      pendingHostError: undefined,
      hasCapturedError: false,
      capturedError: undefined,
    };
    const clearCapturedErrorFrame = () => {
      errorFrame.hasCapturedError = false;
      errorFrame.capturedError = undefined;
      if (prevErrorFrame === null) {
        this.hasCapturedError = false;
        this.capturedError = undefined;
      }
    };
    const consumeErrorFrame = () => {
      clearCapturedErrorFrame();
      if (!errorFrame.hasPendingHostError) {
        return undefined;
      }
      const error = errorFrame.pendingHostError;
      errorFrame.hasPendingHostError = false;
      errorFrame.pendingHostError = undefined;
      return { error };
    };
    const discardPendingRetval = () => {
      if (argStruct[VIVIFICATE]?.retvalHasJsValue) {
        {
          const shadowDV = this.findShadowView(argStruct[MEMORY]);
          if (shadowDV) {
            argStruct[UPDATE]?.(shadowDV);
          }
        }
        this.discardJsValueRetval?.(argStruct);
      }
    };
    const prevErrorFrame = this.activeHostErrorFrame;
    const prevWorkerId = this.activeWorkerId;
    const prevWorkerErrorFrame = this.activeWorkerErrorFrame;
    this.activeHostErrorFrame = errorFrame;
    this.activeWorkerId = 0n;
    this.activeWorkerErrorFrame = null;
    try {
      if (useSyncRunner) {
        const prevContinuation = this.activeContinuation;
        this.activeContinuation = null;
        try {
          success = (attrs)
            ? this.runVariadicThunkSync(thunkAddress, fnAddress, argAddress, attrAddress, attrs.length)
            : this.runThunkSync(thunkAddress, fnAddress, argAddress);
        } finally {
          this.activeContinuation = prevContinuation;
        }
      } else {
        success = (attrs)
          ? this.runVariadicThunk(thunkAddress, fnAddress, argAddress, attrAddress, attrs.length)
          : this.runThunk(thunkAddress, fnAddress, argAddress);
      }
    } catch (err) {
      this.activeHostErrorFrame = prevErrorFrame;
      this.activeWorkerId = prevWorkerId;
      this.activeWorkerErrorFrame = prevWorkerErrorFrame;
      const pending = consumeErrorFrame();
      const isCleanExit = !pending && (err instanceof Exit && err.code === 0);
      if (!finalized) {
        finalize(!isCleanExit);
      }
      if (pending) {
        throw pending.error;
      }
      throw err;
    }
    this.activeHostErrorFrame = prevErrorFrame;
    this.activeWorkerId = prevWorkerId;
    this.activeWorkerErrorFrame = prevWorkerErrorFrame;
    const finishCall = (success) => {
      const pending = consumeErrorFrame();
      if (pending) {
        if (!finalized) {
          if (success) {
            discardPendingRetval();
          }
          finalize(true);
        }
        throw pending.error;
      }
      if (!success) {
        if (!finalized) {
          finalize(true);
        }
        throw new ZigError();
      }
      {
        // finalized can be true here, if a function chooses to immediately invoke a promise's resolve method
        if (!finalized) {
          // copy retval from shadow view
          argStruct[UPDATE]?.(this.findShadowView(argStruct[MEMORY]));
        }
      }
      const transform = fn[TRANSFORM];
      if (isAsync) {
        let retval = null;
        // if a function has returned a value or failed synchronmously, the promise is resolved immediately
        if (!finalized) {
          try {
            if (argStruct[VIVIFICATE]?.retvalHasJsValue) {
              this.consumeJsValueRetval?.(argStruct);
            }
            retval = argStruct.retval;
          } catch (err) {
            retval = new ZigError(err, 1);
          }
        }
        if (retval != null) {
          if (transform) {
            retval = transform(retval);
          }
          argStruct[RETURN](retval);
        } else {
          if (transform) {
            // so the promise or generator can perform the transform 
            argStruct[TRANSFORM] = transform;
          }
        }
        // this would be undefined if a callback function is used instead
        return argStruct[PROMISE] ?? argStruct[GENERATOR];
      } else {
        try {
          const retvalStruct = argStruct[VIVIFICATE]?.retvalHasJsValue ? argStruct : null;
          finalize(false, retvalStruct);
          const { retval } = argStruct;
          return (transform) ? transform(retval) : retval;
        } catch (err) {
          throw new ZigError(err, 1);
        }
      }
    };
    if (isPromise(success)) {
      const promise = success.then(finishCall, (err) => {
        const pending = consumeErrorFrame();
        const isCleanExit = !pending && (err instanceof Exit && err.code === 0);
        if (!finalized) {
          finalize(!isCleanExit);
        }
        if (pending) {
          throw pending.error;
        }
        if (isCleanExit) {
          return;
        }
        throw err;
      });
      if (isAsync && argStruct[GENERATOR]) {
        promise.catch((err) => argStruct[RETURN]?.(err));
        return argStruct[GENERATOR];
      }
      return promise;
    }
    return finishCall(success);
  },
  ...({
    imports: {
      runThunk: { argType: 'iii', returnType: 'b' },
      runVariadicThunk: { argType: 'iiiii', returnType: 'b' },
    },
  } ),
});

export { callMarshalingOutbound as default };
