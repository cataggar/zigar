import { MemberType, StructureFlag, StructurePurpose, StructureType, VisitorFlag } from '../constants.js';
import { mixin } from '../environment.js';
import { isErrorJSON, NotInErrorSet } from '../errors.js';
import { CLASS, INITIALIZE, MEMORY, SLOTS, VISIT, VIVIFICATE, ZIG } from '../symbols.js';
import { clearView, copyObject, defineValue, hasJsValue, isCompatibleInstanceOf } from '../utils.js';

export default mixin({
  defineErrorUnion(structure, descriptors) {
    const {
      instance: { members: [ valueMember, errorMember ] },
      flags,
    } = structure;
    const containsJsValue = hasJsValue(structure);
    const valueAcceptsJsValue = acceptsArbitraryJsValue(valueMember.structure);
    const thisEnv = this;
    const { get: getValue, set: setValue } = this.defineMember(valueMember);
    const { get: getError, set: setError } = this.defineMember(errorMember);
    const { get: getErrorNumber, set: setErrorNumber } = this.defineMember(errorMember, false);
    const get = function() {
      const errNum = getErrorNumber.call(this);
      if (errNum) {
        throw getError.call(this);
      } else {
        return getValue.call(this);
      }
    };
    const isValueVoid = valueMember.type === MemberType.Void
      || valueMember.structure?.purpose === StructurePurpose.JsValue;
    const ErrorSet = errorMember.structure.constructor;
    const { bitOffset, byteSize, slot: valueSlot } = valueMember;
    const assignValue = function(val, allocator) {
      if (containsJsValue && this[MEMORY]?.[ZIG] && !thisEnv.writingUninitZig && getErrorNumber.call(this) !== 0) {
        const prevUninit = thisEnv.writingUninitZig;
        thisEnv.writingUninitZig = true;
        try {
          setValue.call(this, val, allocator);
        } finally {
          thisEnv.writingUninitZig = prevUninit;
        }
      } else {
        setValue.call(this, val, allocator);
      }
      setErrorNumber.call(this, 0);
    };
    const assignError = function(errVal) {
      if (containsJsValue) {
        if (this[MEMORY]?.[ZIG] && !thisEnv.writingUninitZig && !getErrorNumber.call(this)) {
          thisEnv.releaseZigJsValues(valueMember.structure, this[MEMORY], bitOffset >> 3);
        }
        if (this[SLOTS] && valueSlot !== undefined) {
          delete this[SLOTS][valueSlot];
        }
      }
      setError.call(this, errVal);
      clearView(this[MEMORY], bitOffset >> 3, byteSize);
      this[VISIT]?.('clear', VisitorFlag.IgnoreUncreated);
    };
    const propApplier = this.createApplier(structure);
    const initializer = this.createInitializer(function(arg, allocator) {
      if (isCompatibleInstanceOf(arg, constructor) && !containsJsValue) {
        copyObject(this, arg);
        if (flags & StructureFlag.HasPointer) {
          if (!getErrorNumber.call(this)) {
            this[VISIT]('copy', 0, arg);
          }
        }
      } else if (isCompatibleInstanceOf(arg, constructor)) {
        if (getErrorNumber.call(arg)) {
          assignError.call(this, getError.call(arg));
        } else {
          assignValue.call(this, getValue.call(arg), allocator);
        }
      } else if (arg instanceof ErrorSet[CLASS] && ErrorSet(arg)) {
        assignError.call(this, arg);
      } else if (arg !== undefined || isValueVoid) {
        try {
          if (valueAcceptsJsValue && (arg instanceof Error || (arg && typeof(arg) === 'object' && isErrorJSON(arg)))) {
            throw arg;
          }
          // call setValue() first, in case it throws
          assignValue.call(this, arg, allocator);
          return;
        } catch (err) {
          if (arg instanceof Error) {
            const match = ErrorSet(arg) ?? ErrorSet.Unexpected;
            if (match) {
              assignError.call(this, match);
            } else {
              // we gave setValue a chance to see if the error is actually an acceptable value
              // now is time to throw an error
              throw new NotInErrorSet(errorMember.structure, arg);
            }
          } else if (isErrorJSON(arg)) {
            // setValue() failed because the argument actually is an error as JSON
            assignError.call(this, arg);
          } else if (arg && typeof(arg) === 'object') {
            // maybe the argument contains a special property like `dataView` or `base64`
            if (propApplier.call(this, arg) === 0) {
              // propApplier() found zero prop, so it's time to throw
              throw err;
            }
          } else {
            throw err;
          }
        }
      }
    });
    const constructor = this.createConstructor(structure);
    descriptors.$ = { get, set: initializer };
    descriptors[INITIALIZE] = defineValue(initializer);
    descriptors[VIVIFICATE] = (flags & StructureFlag.HasObject) && this.defineVivificatorStruct(structure);
    // for operating on pointers contained in the error union
    descriptors[VISIT] = (flags & StructureFlag.HasPointer) && this.defineVisitorErrorUnion(valueMember, getErrorNumber);
    return constructor;
  },
});

function acceptsArbitraryJsValue(structure) {
  if (!structure) {
    return false;
  }
  if (structure.purpose === StructurePurpose.JsValue) {
    return true;
  }
  if (structure.type === StructureType.Optional || structure.type === StructureType.ErrorUnion) {
    return acceptsArbitraryJsValue(structure.instance?.members?.[0]?.structure);
  }
  return false;
}
