import { MemberType, StructurePurpose, StructureType, UnionFlag, FIRST_DYNAMIC_JS_VALUE_SLOT } from '../constants.js';
import { mixin } from '../environment.js';
import { InvalidJsValueHandle } from '../errors.js';
import { VIVIFICATE, MEMORY, TARGET, ZIG, SLOTS, PROPS, LENGTH } from '../symbols.js';
import { hasJsValue } from '../utils.js';

const RESERVED_UNDEFINED = 0;
const RESERVED_NULL = 1;
const RESERVED_FALSE = 2;
const RESERVED_TRUE = 3;
const RESERVED_GLOBAL_THIS = 4;
const FIRST_DYNAMIC_SLOT = FIRST_DYNAMIC_JS_VALUE_SLOT;

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
  env.writingUninitZig = false;
  env.zigJsOwnedSlots = new Map();
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
  isValidJsValueHandle(handle) {
    handle >>>= 0;
    if (handle < FIRST_DYNAMIC_SLOT) {
      return false;
    }
    const slot = handle & SLOT_MASK;
    const gen = handle >>> GEN_SHIFT;
    return (slot >= FIRST_DYNAMIC_SLOT && slot < this.jsValueNextSlot && gen !== 0
      && this.jsValueGenerations[slot] === (ACTIVE_BIT | gen));
  },
  releaseZigOwnedHandleAt(dv, base = 0) {
    const zig = dv?.[ZIG];
    if (!zig || zig.address === undefined || this.zigJsOwnedSlots.size === 0) {
      return;
    }
    const key = BigInt(zig.address) + BigInt(base);
    const trackedHandle = this.zigJsOwnedSlots.get(key);
    if (trackedHandle !== undefined) {
      this.zigJsOwnedSlots.delete(key);
      const memHandle = dv.getUint32(base, this.littleEndian) >>> 0;
      if (memHandle === trackedHandle && this.isValidJsValueHandle(trackedHandle)) {
        this.releaseJsValue(trackedHandle);
      }
    }
  },
  recordZigOwnedHandleAt(dv, base, handle) {
    const zig = dv?.[ZIG];
    if (!zig || zig.address === undefined) {
      return;
    }
    const key = BigInt(zig.address) + BigInt(base);
    if ((handle >>> 0) >= FIRST_DYNAMIC_SLOT) {
      this.zigJsOwnedSlots.set(key, handle >>> 0);
    } else {
      this.zigJsOwnedSlots.delete(key);
    }
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
        } else if (structure.flags & UnionFlag.HasSelector) {
          const members = structure.instance.members;
          const selMember = members[members.length - 1];
          const idx = readUintBytes(obj[MEMORY], selMember.bitOffset >> 3, selMember.byteSize, this.littleEndian);
          const activeMember = members[idx];
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
  releaseZigJsValues(structure, dv, offset = 0) {
    if (!dv?.[ZIG] || this.writingUninitZig || this.zigJsOwnedSlots.size === 0 || !hasJsValue(structure)) {
      return;
    }
    if (this.restoreView) {
      dv = this.restoreView(dv);
    }
    const byteSize = structure.byteSize ?? 0;
    const startAddr = BigInt(dv[ZIG].address) + BigInt(offset);
    const endAddr = startAddr + BigInt(byteSize);
    for (const [ key, trackedHandle ] of this.zigJsOwnedSlots) {
      if (key >= startAddr && key < endAddr) {
        this.zigJsOwnedSlots.delete(key);
        const relOffset = offset + Number(key - startAddr);
        if (relOffset >= 0 && relOffset + 4 <= dv.byteLength) {
          const memHandle = dv.getUint32(relOffset, this.littleEndian) >>> 0;
          if (memHandle === trackedHandle && this.isValidJsValueHandle(trackedHandle)) {
            this.releaseJsValue(trackedHandle);
          }
        }
      }
    }
  },
  walkActiveJsValueLeaves(rootObj, structure, rootDV, callback) {
    const le = this.littleEndian;
    const visit = (obj, s) => {
      if (s.purpose === StructurePurpose.JsValue) {
        const relOffset = obj[MEMORY].byteOffset - rootDV.byteOffset;
        callback(obj, relOffset);
        return;
      }
      switch (s.type) {
        case StructureType.Struct: {
          for (const member of s.instance.members) {
            if (member.type === MemberType.Object && hasJsValue(member.structure)) {
              const child = obj[SLOTS][member.slot] ?? obj[VIVIFICATE](member.slot);
              visit(child, member.structure);
            }
          }
          break;
        }
        case StructureType.Array: {
          const [ elementMember ] = s.instance.members;
          if (elementMember.type === MemberType.Object && hasJsValue(elementMember.structure)) {
            for (let i = 0; i < s.length; i++) {
              const child = obj[SLOTS][i] ?? obj[VIVIFICATE](i);
              visit(child, elementMember.structure);
            }
          }
          break;
        }
        case StructureType.Slice: {
          const [ elementMember ] = s.instance.members;
          if (elementMember.type === MemberType.Object && hasJsValue(elementMember.structure)) {
            const len = obj[LENGTH] ?? obj.length;
            for (let i = 0; i < len; i++) {
              const child = obj[SLOTS][i] ?? obj[VIVIFICATE](i);
              visit(child, elementMember.structure);
            }
          }
          break;
        }
        case StructureType.Optional: {
          const [ valueMember, presentMember ] = s.instance.members;
          const relPresent = (obj[MEMORY].byteOffset - rootDV.byteOffset) + (presentMember.bitOffset >> 3);
          if (valueMember.type === MemberType.Object && hasJsValue(valueMember.structure)
            && isNonZeroBytes(rootDV, relPresent, presentMember.byteSize)) {
            const child = obj[SLOTS][valueMember.slot] ?? obj[VIVIFICATE](valueMember.slot);
            visit(child, valueMember.structure);
          }
          break;
        }
        case StructureType.ErrorUnion: {
          const [ valueMember, errorMember ] = s.instance.members;
          const relErr = (obj[MEMORY].byteOffset - rootDV.byteOffset) + (errorMember.bitOffset >> 3);
          if (valueMember.type === MemberType.Object && hasJsValue(valueMember.structure)
            && !isNonZeroBytes(rootDV, relErr, errorMember.byteSize)) {
            const child = obj[SLOTS][valueMember.slot] ?? obj[VIVIFICATE](valueMember.slot);
            visit(child, valueMember.structure);
          }
          break;
        }
        case StructureType.Union: {
          if (s.flags & UnionFlag.HasTag) {
            let activeName;
            try {
              [ activeName ] = obj[PROPS];
            } catch {}
            const activeMember = activeName && s.instance.members.find(m => m.name === activeName);
            if (activeMember?.type === MemberType.Object && hasJsValue(activeMember.structure)) {
              const child = obj[SLOTS][activeMember.slot] ?? obj[VIVIFICATE](activeMember.slot);
              visit(child, activeMember.structure);
            }
          } else if (s.flags & UnionFlag.HasSelector) {
            const members = s.instance.members;
            const selMember = members[members.length - 1];
            const relSel = (obj[MEMORY].byteOffset - rootDV.byteOffset) + (selMember.bitOffset >> 3);
            const idx = readUintBytes(rootDV, relSel, selMember.byteSize, le);
            const activeMember = members[idx];
            if (activeMember?.type === MemberType.Object && hasJsValue(activeMember.structure)) {
              const child = obj[SLOTS][activeMember.slot] ?? obj[VIVIFICATE](activeMember.slot);
              visit(child, activeMember.structure);
            }
          }
          break;
        }
      }
    };
    visit(rootObj, structure);
  },
  prepareJsValueTarget(context, target, structure, writable) {
    const rootDV = target?.[MEMORY];
    if (!rootDV || rootDV[ZIG] || !hasJsValue(structure)) {
      return;
    }
    let map = context.jsValueTargets;
    if (!map) {
      map = context.jsValueTargets = new Map();
    }
    const existing = map.get(target);
    if (existing) {
      existing.writable ||= writable;
      return;
    }
    const le = this.littleEndian;
    const preHandles = new Map();
    const prevPending = this.pendingJsHandles;
    this.pendingJsHandles = null;
    try {
      this.walkActiveJsValueLeaves(target, structure, rootDV, (refObj, relOffset) => {
        const jsVal = Object.hasOwn(refObj, TARGET)
          ? refObj[TARGET]
          : this.getJsValue(rootDV.getUint32(relOffset, le));
        refObj[TARGET] = jsVal;
        const handle = this.allocJsValue(jsVal);
        rootDV.setUint32(relOffset, handle, le);
        preHandles.set(relOffset, { refObj, handle });
      });
    } catch (err) {
      for (const [ relOffset, { handle } ] of preHandles) {
        rootDV.setUint32(relOffset, RESERVED_UNDEFINED, le);
        if (this.isValidJsValueHandle(handle)) {
          this.releaseJsValue(handle);
        }
      }
      throw err;
    } finally {
      this.pendingJsHandles = prevPending;
    }
    map.set(target, { structure, writable, preHandles });
  },
  finalizeJsValueTargets(context, { abortOnly = false, failed = false, retvalStruct = null } = {}) {
    const map = context.jsValueTargets;
    if (!map) {
      return;
    }
    context.jsValueTargets = null;
    const le = this.littleEndian;
    const handlesToRelease = new Set();
    let resolveErr = null;
    if (!abortOnly) {
      for (const [ target, { structure, writable, preHandles } ] of map) {
        if (!writable) {
          continue;
        }
        const rootDV = target[MEMORY];
        this.walkActiveJsValueLeaves(target, structure, rootDV, (refObj, relOffset) => {
          const postHandle = rootDV.getUint32(relOffset, le) >>> 0;
          const preEntry = preHandles.get(relOffset);
          if (postHandle >= FIRST_DYNAMIC_SLOT) {
            if (this.isValidJsValueHandle(postHandle)) {
              refObj[TARGET] = this.getJsValue(postHandle);
              handlesToRelease.add(postHandle);
            } else if (preEntry && postHandle === preEntry.handle) {
              refObj[TARGET] = undefined;
            } else if (!failed && !resolveErr) {
              resolveErr = new InvalidJsValueHandle(postHandle);
            }
          } else {
            try {
              refObj[TARGET] = this.getJsValue(postHandle);
            } catch (err) {
              if (!failed && !resolveErr) resolveErr = err;
            }
          }
          rootDV.setUint32(relOffset, RESERVED_UNDEFINED, le);
        });
      }
      if (!failed && retvalStruct) {
        try {
          this.consumeJsValueRetval(retvalStruct);
        } catch (err) {
          if (!resolveErr) resolveErr = err;
        }
      }
    }
    for (const [ target, { writable, preHandles } ] of map) {
      const rootDV = target[MEMORY];
      for (const [ relOffset, { handle } ] of preHandles) {
        if (!writable || abortOnly) {
          rootDV.setUint32(relOffset, RESERVED_UNDEFINED, le);
        }
        if (handle >= FIRST_DYNAMIC_SLOT) {
          handlesToRelease.add(handle);
        }
      }
    }
    for (const handle of handlesToRelease) {
      if (this.isValidJsValueHandle(handle)) {
        this.releaseJsValue(handle);
      }
    }
    if (resolveErr && !failed) {
      throw resolveErr;
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

function readUintBytes(dv, byteOffset, byteSize, littleEndian) {
  let value = 0;
  for (let i = 0; i < byteSize; i++) {
    const byte = dv.getUint8(byteOffset + i);
    const shift = (littleEndian ? i : (byteSize - 1 - i)) * 8;
    value |= byte << shift;
  }
  return value >>> 0;
}

export { FIRST_DYNAMIC_SLOT, RESERVED_FALSE, RESERVED_GLOBAL_THIS, RESERVED_NULL, RESERVED_TRUE, RESERVED_UNDEFINED, jsValueRegistry as default };
