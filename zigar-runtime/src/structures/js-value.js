import { FIRST_DYNAMIC_JS_VALUE_SLOT, StructurePurpose } from '../constants.js';
import { mixin } from '../environment.js';
import { throwReadOnly } from '../errors.js';
import { ENTRIES, INITIALIZE, MEMORY, PROPS, PURPOSE, READ_ONLY, TARGET, ZIG } from '../symbols.js';
import { defineValue } from '../utils.js';

export default mixin({
  defineJsValue(structure, descriptors) {
    const {
      instance: { members: [ handleMember ] },
    } = structure;
    const { get: getHandle, set: setHandle } = this.defineMember(handleMember);
    const thisEnv = this;
    const get = function() {
      if (Object.hasOwn(this, TARGET)) {
        return this[TARGET];
      }
      const handle = getHandle.call(this);
      return thisEnv.getJsValue(handle);
    };
    const initializer = function(arg) {
      if (this[READ_ONLY]) {
        throwReadOnly();
      }
      let value = arg;
      if (arg && typeof(arg) === 'object' && arg.constructor?.[PURPOSE] === StructurePurpose.JsValue) {
        value = arg.$;
      }
      const inZigMemory = Boolean(this[MEMORY]?.[ZIG]);
      if (inZigMemory || thisEnv.pendingJsHandles !== null) {
        if (Object.hasOwn(this, TARGET)) {
          delete this[TARGET];
        }
        const prevHandle = (inZigMemory && !thisEnv.writingUninitZig) ? (getHandle.call(this) >>> 0) : 0;
        const handle = thisEnv.allocJsValue(value);
        setHandle.call(this, handle);
        if (prevHandle >= FIRST_DYNAMIC_JS_VALUE_SLOT) {
          thisEnv.releaseJsValue(prevHandle);
        }
      } else {
        this[TARGET] = value;
        setHandle.call(this, 0);
      }
    };
    const constructor = this.createConstructor(structure);
    descriptors.$ = { get, set: initializer };
    descriptors.handle = { get: getHandle };
    descriptors[INITIALIZE] = defineValue(initializer);
    descriptors[ENTRIES] = this.defineStructEntries();
    descriptors[Symbol.iterator] = this.defineStructIterator();
    descriptors[PROPS] = defineValue([ 'handle' ]);
    return constructor;
  },
});
