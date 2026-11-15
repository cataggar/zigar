import { MemberType, StructurePurpose, StructureType, UnionFlag } from '../constants.js';
import { mixin } from '../environment.js';
import { InvalidJsValueHandle } from '../errors.js';
import { VIVIFICATE, SLOTS, PROPS, MEMORY, TARGET } from '../symbols.js';
import { hasJsValue } from '../utils.js';

const RESERVED_UNDEFINED = 0;
const RESERVED_NULL = 1;
const RESERVED_FALSE = 2;
const RESERVED_TRUE = 3;
const RESERVED_GLOBAL_THIS = 4;
const FIRST_DYNAMIC_SLOT = 8;

const SLOT_MASK = 0x000FFFFF;
const GEN_SHIFT = 20;
const GEN_MASK = 0x0FFF;
const ACTIVE_BIT = 0x1000;
const MAX_SLOTS = SLOT_MASK + 1;
const INITIAL_CAPACITY = 64;

const JS_TYPE_CODES = {
  undefined: 0,
  object: 1,
  boolean: 2,
  number: 3,
  bigint: 4,
  string: 5,
  symbol: 6,
  function: 7,
};

function initRegistryState(env) {
  env.jsValueSlots = new Array(INITIAL_CAPACITY);
  env.jsValueGenerations = new Uint16Array(INITIAL_CAPACITY);
  env.jsValueFreeNext = new Int32Array(INITIAL_CAPACITY);
  env.jsValueFreeHead = -1;
  env.jsValueNextSlot = FIRST_DYNAMIC_SLOT;
  env.jsValueActiveCount = 0;
  env.pendingJsHandles = null;
}

var jsValueRegistry = mixin({
  init() {
    initRegistryState(this);
    this.destructors?.push(() => initRegistryState(this));
  },
  resetJsValueRegistry() {
    initRegistryState(this);
  },
  growJsValueRegistry() {
    const oldCap = this.jsValueSlots.length;
    if (oldCap >= MAX_SLOTS) {
      throw new RangeError('JsValue handle table exhausted');
    }
    const newCap = Math.min(oldCap * 2, MAX_SLOTS);
    this.jsValueSlots.length = newCap;
    const nextGen = new Uint16Array(newCap);
    nextGen.set(this.jsValueGenerations);
    this.jsValueGenerations = nextGen;
    const nextFree = new Int32Array(newCap);
    nextFree.set(this.jsValueFreeNext);
    this.jsValueFreeNext = nextFree;
  },
  allocJsValue(value) {
    if (value === undefined) return RESERVED_UNDEFINED;
    if (value === null) return RESERVED_NULL;
    if (value === false) return RESERVED_FALSE;
    if (value === true) return RESERVED_TRUE;
    if (value === globalThis) return RESERVED_GLOBAL_THIS;
    let slot, gen;
    if (this.jsValueFreeHead >= 0) {
      slot = this.jsValueFreeHead;
      this.jsValueFreeHead = this.jsValueFreeNext[slot];
      const prevGen = this.jsValueGenerations[slot] & GEN_MASK;
      gen = (prevGen >= GEN_MASK) ? 1 : prevGen + 1;
    } else {
      if (this.jsValueNextSlot >= this.jsValueSlots.length) {
        this.growJsValueRegistry();
      }
      slot = this.jsValueNextSlot++;
      gen = 1;
    }
    this.jsValueSlots[slot] = value;
    this.jsValueGenerations[slot] = ACTIVE_BIT | gen;
    this.jsValueActiveCount++;
    const handle = ((gen << GEN_SHIFT) | slot) >>> 0;
    if (this.pendingJsHandles) {
      this.pendingJsHandles.push(handle);
    }
    return handle;
  },
  getJsValue(handle) {
    handle >>>= 0;
    switch (handle) {
      case RESERVED_UNDEFINED: return undefined;
      case RESERVED_NULL: return null;
      case RESERVED_FALSE: return false;
      case RESERVED_TRUE: return true;
      case RESERVED_GLOBAL_THIS: return globalThis;
    }
    if (handle < FIRST_DYNAMIC_SLOT) {
      throw new InvalidJsValueHandle(handle);
    }
    const slot = handle & SLOT_MASK;
    const gen = handle >>> GEN_SHIFT;
    if (slot < FIRST_DYNAMIC_SLOT || slot >= this.jsValueNextSlot || gen === 0
      || this.jsValueGenerations[slot] !== (ACTIVE_BIT | gen)) {
      throw new InvalidJsValueHandle(handle);
    }
    return this.jsValueSlots[slot];
  },
  cloneJsValue(handle) {
    handle >>>= 0;
    if (handle <= RESERVED_GLOBAL_THIS) {
      return handle;
    }
    const value = this.getJsValue(handle);
    return this.allocJsValue(value);
  },
  releaseJsValue(handle) {
    handle >>>= 0;
    if (handle <= RESERVED_GLOBAL_THIS) {
      return;
    }
    if (handle < FIRST_DYNAMIC_SLOT) {
      throw new InvalidJsValueHandle(handle);
    }
    const slot = handle & SLOT_MASK;
    const gen = handle >>> GEN_SHIFT;
    if (slot < FIRST_DYNAMIC_SLOT || slot >= this.jsValueNextSlot || gen === 0
      || this.jsValueGenerations[slot] !== (ACTIVE_BIT | gen)) {
      throw new InvalidJsValueHandle(handle);
    }
    this.jsValueGenerations[slot] = gen;
    this.jsValueSlots[slot] = undefined;
    this.jsValueFreeNext[slot] = this.jsValueFreeHead;
    this.jsValueFreeHead = slot;
    this.jsValueActiveCount--;
  },
  typeofJsValue(handle) {
    const value = this.getJsValue(handle);
    return JS_TYPE_CODES[typeof(value)];
  },
  instanceofJsValue(handle, ctorHandle) {
    const value = this.getJsValue(handle);
    const ctor = this.getJsValue(ctorHandle);
    return Boolean(value instanceof ctor);
  },
  equalJsValue(lhsHandle, rhsHandle) {
    const lhs = this.getJsValue(lhsHandle);
    const rhs = this.getJsValue(rhsHandle);
    return Object.is(lhs, rhs);
  },
  getJsValueCount() {
    return this.jsValueActiveCount;
  },
  consumeJsValueObject(refObj) {
    if (!refObj || Object.hasOwn(refObj, TARGET)) {
      return;
    }
    const dv = refObj[MEMORY];
    const handle = dv.getUint32(0, this.littleEndian);
    const value = this.getJsValue(handle);
    this.releaseJsValue(handle);
    refObj[TARGET] = value;
    dv.setUint32(0, RESERVED_UNDEFINED, this.littleEndian);
  },
  consumeJsValueSlot(parent, slot, structure) {
    if (!hasJsValue(structure)) {
      return;
    }
    const obj = parent[SLOTS][slot] ?? parent[VIVIFICATE](slot);
    if (structure.purpose === StructurePurpose.JsValue) {
      this.consumeJsValueObject(obj);
      return;
    }
    switch (structure.type) {
      case StructureType.Struct: {
        for (const member of structure.instance.members) {
          if (member.type === MemberType.Object) {
            this.consumeJsValueSlot(obj, member.slot, member.structure);
          }
        }
        break;
      }
      case StructureType.Optional: {
        const [ valueMember, presentMember ] = structure.instance.members;
        if (valueMember.type === MemberType.Object
          && isNonZeroBytes(obj[MEMORY], presentMember.bitOffset >> 3, presentMember.byteSize)) {
          this.consumeJsValueSlot(obj, valueMember.slot, valueMember.structure);
        }
        break;
      }
      case StructureType.ErrorUnion: {
        const [ valueMember, errorMember ] = structure.instance.members;
        if (valueMember.type === MemberType.Object
          && !isNonZeroBytes(obj[MEMORY], errorMember.bitOffset >> 3, errorMember.byteSize)) {
          this.consumeJsValueSlot(obj, valueMember.slot, valueMember.structure);
        }
        break;
      }
      case StructureType.Union: {
        if (structure.flags & UnionFlag.HasTag) {
          const [ activeName ] = obj[PROPS];
          const activeMember = structure.instance.members.find(m => m.name === activeName);
          if (activeMember?.type === MemberType.Object) {
            this.consumeJsValueSlot(obj, activeMember.slot, activeMember.structure);
          }
        }
        break;
      }
      case StructureType.Array: {
        const [ elementMember ] = structure.instance.members;
        if (elementMember.type === MemberType.Object) {
          for (let i = 0; i < structure.length; i++) {
            this.consumeJsValueSlot(obj, i, elementMember.structure);
          }
        }
        break;
      }
    }
  },
  consumeJsValueRetval(argStruct) {
    const retvalMember = argStruct?.[VIVIFICATE]?.retvalMember;
    if (retvalMember && retvalMember.type === MemberType.Object) {
      this.consumeJsValueSlot(argStruct, retvalMember.slot, retvalMember.structure);
    }
  },
  ...({
    exports: {
      cloneJsValue: { argType: 'i', returnType: 'i' },
      releaseJsValue: { argType: 'i' },
      typeofJsValue: { argType: 'i', returnType: 'i' },
      instanceofJsValue: { argType: 'ii', returnType: 'b' },
      equalJsValue: { argType: 'ii', returnType: 'b' },
      getJsValueCount: { argType: '', returnType: 'i' },
    },
  } ),
});

function isNonZeroBytes(dv, byteOffset, byteSize) {
  for (let i = 0; i < byteSize; i++) {
    if (dv.getUint8(byteOffset + i) !== 0) {
      return true;
    }
  }
  return false;
}

export { FIRST_DYNAMIC_SLOT, RESERVED_FALSE, RESERVED_GLOBAL_THIS, RESERVED_NULL, RESERVED_TRUE, RESERVED_UNDEFINED, jsValueRegistry as default };
