import { FIRST_DYNAMIC_JS_VALUE_SLOT, MemberType, StructurePurpose, StructureType, UnionFlag } from '../constants.js';
import { mixin } from '../environment.js';
import { InvalidJsValueHandle } from '../errors.js';
import { CAST, FALLBACK, LENGTH, MEMORY, NAME, SLOTS, TARGET, VIVIFICATE, ZIG } from '../symbols.js';
import { hasJsValue } from '../utils.js';

export const RESERVED_UNDEFINED = 0;
export const RESERVED_NULL = 1;
export const RESERVED_FALSE = 2;
export const RESERVED_TRUE = 3;
export const RESERVED_GLOBAL_THIS = 4;
export const FIRST_DYNAMIC_SLOT = FIRST_DYNAMIC_JS_VALUE_SLOT;

const SLOT_INDEX_MASK = 0x00003FFF;
const REALM_SHIFT = 14;
const REALM_MASK = 0x3F;
const GEN_SHIFT = 20;
const GEN_MASK = 0x0FFF;
const ACTIVE_BIT = 0x1000;
const MAX_SLOTS = SLOT_INDEX_MASK + 1;
const INITIAL_CAPACITY = 64;
const noop = () => {};

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
  env.jsValueFreeNext = new Int32Array(INITIAL_CAPACITY).fill(-1);
  env.jsValueFreeHead = -1;
  env.jsValueFreeTail = -1;
  env.jsValueRetiredHead = -1;
  env.jsValueRetiredTail = -1;
  env.jsValueNextSlot = FIRST_DYNAMIC_SLOT;
  env.jsValueActiveCount = 0;
  env.pendingJsHandles = null;
  env.writingUninitZig = false;
}

export default mixin({
  init() {
    this.jsValueRealmTag = 0;
    initRegistryState(this);
    this.destructors?.push(() => initRegistryState(this));
  },
  setJsValueRealmTag(tag) {
    this.jsValueRealmTag = tag & REALM_MASK;
  },
  resetJsValueRegistry() {
    initRegistryState(this);
  },
  growJsValueRegistry() {
    const oldCap = this.jsValueSlots.length;
    if (oldCap >= MAX_SLOTS) {
      throw new RangeError('JsValueRegistry exhausted');
    }
    const newCap = Math.min(oldCap * 2, MAX_SLOTS);
    this.jsValueSlots.length = newCap;
    const nextGen = new Uint16Array(newCap);
    nextGen.set(this.jsValueGenerations);
    this.jsValueGenerations = nextGen;
    const nextFree = new Int32Array(newCap).fill(-1);
    nextFree.set(this.jsValueFreeNext);
    this.jsValueFreeNext = nextFree;
  },
  allocJsValue(value) {
    if (value === undefined) return RESERVED_UNDEFINED;
    if (value === null) return RESERVED_NULL;
    if (value === false) return RESERVED_FALSE;
    if (value === true) return RESERVED_TRUE;
    if (value === globalThis) return RESERVED_GLOBAL_THIS;
    if (value instanceof Promise) {
      value.then(undefined, noop);
    }
    let slot, gen;
    if (this.jsValueFreeHead >= 0) {
      slot = this.jsValueFreeHead;
      const next = this.jsValueFreeNext[slot];
      this.jsValueFreeHead = next;
      if (next < 0) {
        this.jsValueFreeTail = -1;
      }
      this.jsValueFreeNext[slot] = -1;
      const prevGen = this.jsValueGenerations[slot] & GEN_MASK;
      gen = prevGen + 1;
    } else if (this.jsValueNextSlot < MAX_SLOTS) {
      if (this.jsValueNextSlot >= this.jsValueSlots.length) {
        this.growJsValueRegistry();
      }
      slot = this.jsValueNextSlot++;
      gen = 1;
    } else if (this.jsValueRetiredHead >= 0) {
      slot = this.jsValueRetiredHead;
      const next = this.jsValueFreeNext[slot];
      this.jsValueRetiredHead = next;
      if (next < 0) {
        this.jsValueRetiredTail = -1;
      }
      this.jsValueFreeNext[slot] = -1;
      gen = 1;
    } else {
      throw new RangeError('JsValueRegistry exhausted');
    }
    this.jsValueSlots[slot] = value;
    this.jsValueGenerations[slot] = ACTIVE_BIT | gen;
    this.jsValueActiveCount++;
    const handle = ((gen << GEN_SHIFT) | (this.jsValueRealmTag << REALM_SHIFT) | slot) >>> 0;
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
    const slot = handle & SLOT_INDEX_MASK;
    const realm = (handle >>> REALM_SHIFT) & REALM_MASK;
    const gen = handle >>> GEN_SHIFT;
    if (realm !== this.jsValueRealmTag || slot < FIRST_DYNAMIC_SLOT || slot >= this.jsValueNextSlot
      || gen === 0 || this.jsValueGenerations[slot] !== (ACTIVE_BIT | gen)) {
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
    const slot = handle & SLOT_INDEX_MASK;
    const realm = (handle >>> REALM_SHIFT) & REALM_MASK;
    const gen = handle >>> GEN_SHIFT;
    if (realm !== this.jsValueRealmTag || slot < FIRST_DYNAMIC_SLOT || slot >= this.jsValueNextSlot
      || gen === 0 || this.jsValueGenerations[slot] !== (ACTIVE_BIT | gen)) {
      throw new InvalidJsValueHandle(handle);
    }
    this.jsValueSlots[slot] = undefined;
    this.jsValueActiveCount--;
    if (gen >= GEN_MASK) {
      // Quarantine slots once their 12-bit generation reaches 0xFFF (4095) into the
      // retired FIFO list: `jsValueGenerations[slot] = 0` invalidates stale handles,
      // and the slot is only recycled back to generation 1 once all fresh slots up to
      // MAX_SLOTS have been allocated (~67M alloc/release cycles).
      this.jsValueGenerations[slot] = 0;
      this.jsValueFreeNext[slot] = -1;
      if (this.jsValueRetiredTail >= 0) {
        this.jsValueFreeNext[this.jsValueRetiredTail] = slot;
        this.jsValueRetiredTail = slot;
      } else {
        this.jsValueRetiredHead = slot;
        this.jsValueRetiredTail = slot;
      }
    } else {
      this.jsValueGenerations[slot] = gen;
      this.jsValueFreeNext[slot] = -1;
      if (this.jsValueFreeTail >= 0) {
        this.jsValueFreeNext[this.jsValueFreeTail] = slot;
        this.jsValueFreeTail = slot;
      } else {
        this.jsValueFreeHead = slot;
        this.jsValueFreeTail = slot;
      }
    }
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
    const slot = handle & SLOT_INDEX_MASK;
    const realm = (handle >>> REALM_SHIFT) & REALM_MASK;
    const gen = handle >>> GEN_SHIFT;
    return (realm === this.jsValueRealmTag && slot >= FIRST_DYNAMIC_SLOT
      && slot < this.jsValueNextSlot && gen !== 0
      && this.jsValueGenerations[slot] === (ACTIVE_BIT | gen));
  },
  releaseJsValueIfValid(handle) {
    if (this.isValidJsValueHandle(handle)) {
      this.releaseJsValue(handle >>> 0);
    }
  },
  consumeJsValueObject(refObj) {
    if (!refObj || Object.hasOwn(refObj, TARGET)) {
      return;
    }
    const dv = refObj[MEMORY];
    if (process.env.TARGET === 'node') {
      dv[FALLBACK]?.(false, 0, 4);
    }
    try {
      const handle = dv.getUint32(0, this.littleEndian);
      const value = this.getJsValue(handle);
      this.releaseJsValue(handle);
      refObj[TARGET] = value;
    } finally {
      dv.setUint32(0, RESERVED_UNDEFINED, this.littleEndian);
      if (process.env.TARGET === 'node') {
        dv[FALLBACK]?.(true, 0, 4);
      }
    }
  },
  consumeJsValueSlot(parent, slot, structure, errState = null) {
    if (!hasJsValue(structure)) {
      return;
    }
    const isRoot = !errState;
    const state = errState ?? { error: null };
    const obj = parent[SLOTS][slot] ?? parent[VIVIFICATE](slot);
    if (structure.purpose === StructurePurpose.JsValue) {
      try {
        this.consumeJsValueObject(obj);
      } catch (err) {
        state.error ??= err;
      }
      if (isRoot && state.error) {
        throw state.error;
      }
      return;
    }
    if (process.env.TARGET === 'node') {
      obj[MEMORY]?.[FALLBACK]?.(false);
    }
    switch (structure.type) {
      case StructureType.Struct: {
        for (const member of structure.instance.members) {
          if (member.type === MemberType.Object) {
            this.consumeJsValueSlot(obj, member.slot, member.structure, state);
          }
        }
        break;
      }
      case StructureType.Optional: {
        const [ valueMember, presentMember ] = structure.instance.members;
        if (valueMember.type === MemberType.Object
          && isNonZeroBytes(obj[MEMORY], presentMember.bitOffset >> 3, presentMember.byteSize)) {
          this.consumeJsValueSlot(obj, valueMember.slot, valueMember.structure, state);
        }
        break;
      }
      case StructureType.ErrorUnion: {
        const [ valueMember, errorMember ] = structure.instance.members;
        if (valueMember.type === MemberType.Object
          && !isNonZeroBytes(obj[MEMORY], errorMember.bitOffset >> 3, errorMember.byteSize)) {
          this.consumeJsValueSlot(obj, valueMember.slot, valueMember.structure, state);
        }
        break;
      }
      case StructureType.Union: {
        const activeMember = getActiveUnionMember(structure, obj[MEMORY], 0, this.littleEndian);
        if (activeMember?.type === MemberType.Object) {
          this.consumeJsValueSlot(obj, activeMember.slot, activeMember.structure, state);
        }
        break;
      }
      case StructureType.Array: {
        const [ elementMember ] = structure.instance.members;
        if (elementMember.type === MemberType.Object) {
          for (let i = 0; i < structure.length; i++) {
            this.consumeJsValueSlot(obj, i, elementMember.structure, state);
          }
        }
        break;
      }
    }
    if (isRoot && state.error) {
      throw state.error;
    }
  },
  releaseZigJsValues(structure, dv, offset = 0) {
    if (!dv?.[ZIG] || this.writingUninitZig || this.jsValueActiveCount === 0 || !hasJsValue(structure)) {
      return;
    }
    if (process.env.TARGET === 'wasm' && this.restoreView) {
      dv = this.restoreView(dv);
    } else if (process.env.TARGET === 'node') {
      dv[FALLBACK]?.(false, offset, structure.byteSize);
    }
    this.releaseJsValuesInView(structure, dv, offset, false);
  },
  releaseJsValuesInView(structure, dv, offset = 0, clearHandles = false) {
    const le = this.littleEndian;
    const visit = (s, base) => {
      if (s.purpose === StructurePurpose.JsValue) {
        const handle = dv.getUint32(base, le) >>> 0;
        this.releaseJsValueIfValid(handle);
        if (clearHandles) {
          dv.setUint32(base, RESERVED_UNDEFINED, le);
        }
        return;
      }
      switch (s.type) {
        case StructureType.Struct: {
          for (const m of s.instance.members) {
            if (m.type === MemberType.Object && m.bitOffset !== undefined && hasJsValue(m.structure)) {
              visit(m.structure, base + (m.bitOffset >> 3));
            }
          }
          break;
        }
        case StructureType.Array: {
          const [ elem ] = s.instance.members;
          if (hasJsValue(elem.structure)) {
            for (let i = 0; i < s.length; i++) {
              visit(elem.structure, base + i * elem.byteSize);
            }
          }
          break;
        }
        case StructureType.Optional: {
          const [ valMember, presentMember ] = s.instance.members;
          if (hasJsValue(valMember.structure)) {
            const presentOffset = base + (presentMember.bitOffset >> 3);
            const isPresent = (presentMember.bitSize === 1)
              ? (dv.getUint8(presentOffset) === 1)
              : isNonZeroBytes(dv, presentOffset, presentMember.byteSize);
            if (isPresent) {
              visit(valMember.structure, base + (valMember.bitOffset >> 3));
            }
          }
          break;
        }
        case StructureType.ErrorUnion: {
          const [ valMember, errMember ] = s.instance.members;
          if (hasJsValue(valMember.structure)
            && !isNonZeroBytes(dv, base + (errMember.bitOffset >> 3), errMember.byteSize)) {
            visit(valMember.structure, base + (valMember.bitOffset >> 3));
          }
          break;
        }
        case StructureType.Union: {
          const activeMember = getActiveUnionMember(s, dv, base, le);
          if (activeMember && activeMember.type === MemberType.Object
            && activeMember.bitOffset !== undefined && hasJsValue(activeMember.structure)) {
            visit(activeMember.structure, base + (activeMember.bitOffset >> 3));
          }
          break;
        }
      }
    };
    visit(structure, offset);
  },
  // Releases by-value `Ref(T)` handles written into `argStruct.retval` when a call aborts or
  // leaves a pending host exception. Pointers and Zig slices (`[]const Ref(T)` / `*Ref(T)`,
  // represented as `StructureType.Pointer` to `StructureType.Slice` or target memory) are
  // intentionally NOT walked here — matching `hasJsValue` in `utils.js` — because handles behind
  // pointers/slices reside in Zig-owned memory and are borrowed rather than ownership-transferred.
  discardJsValueRetval(argStruct) {
    const retvalMember = argStruct?.[VIVIFICATE]?.retvalMember;
    if (!retvalMember || retvalMember.type !== MemberType.Object || this.jsValueActiveCount === 0) {
      return;
    }
    const { structure, bitOffset, byteSize } = retvalMember;
    if (!hasJsValue(structure)) {
      return;
    }
    const offset = bitOffset >> 3;
    const dv = argStruct[MEMORY];
    if (process.env.TARGET === 'node') {
      dv[FALLBACK]?.(false, offset, byteSize);
    }
    this.releaseJsValuesInView(structure, dv, offset, true);
    if (process.env.TARGET === 'node') {
      dv[FALLBACK]?.(true, offset, byteSize);
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
          const isPresent = (presentMember.bitSize === 1)
            ? (rootDV.getUint8(relPresent) === 1)
            : isNonZeroBytes(rootDV, relPresent, presentMember.byteSize);
          if (valueMember.type === MemberType.Object && hasJsValue(valueMember.structure) && isPresent) {
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
          const relBase = obj[MEMORY].byteOffset - rootDV.byteOffset;
          const activeMember = getActiveUnionMember(s, rootDV, relBase, le);
          if (activeMember?.type === MemberType.Object && hasJsValue(activeMember.structure)) {
            const child = obj[SLOTS][activeMember.slot] ?? obj[VIVIFICATE](activeMember.slot);
            visit(child, activeMember.structure);
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
  ...(process.env.TARGET === 'wasm' ? {
    exports: {
      cloneJsValue: { argType: 'i', returnType: 'i' },
      releaseJsValue: { argType: 'i' },
      typeofJsValue: { argType: 'i', returnType: 'i' },
      instanceofJsValue: { argType: 'ii', returnType: 'b' },
      equalJsValue: { argType: 'ii', returnType: 'b' },
      getJsValueCount: { argType: '', returnType: 'i' },
    },
  } : process.env.TARGET === 'node' ? {
    exports: {
      cloneJsValue: {},
      releaseJsValue: {},
      typeofJsValue: {},
      instanceofJsValue: {},
      equalJsValue: {},
      getJsValueCount: {},
      setJsValueRealmTag: {},
    },
  /* c8 ignore next */
  } : undefined),
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

function readTagValue(dv, byteOffset, selMember, littleEndian) {
  const signed = (selMember.type === MemberType.Int);
  switch (selMember.byteSize) {
    case 1: return signed ? dv.getInt8(byteOffset) : dv.getUint8(byteOffset);
    case 2: return signed ? dv.getInt16(byteOffset, littleEndian) : dv.getUint16(byteOffset, littleEndian);
    case 4: return signed ? dv.getInt32(byteOffset, littleEndian) : dv.getUint32(byteOffset, littleEndian);
    case 8: return signed ? dv.getBigInt64(byteOffset, littleEndian) : dv.getBigUint64(byteOffset, littleEndian);
    default: return readUintBytes(dv, byteOffset, selMember.byteSize, littleEndian);
  }
}

function getActiveUnionMember(s, dv, base, littleEndian) {
  if (!(s.flags & UnionFlag.HasSelector)) {
    return undefined;
  }
  const members = s.instance.members;
  const selMember = members[members.length - 1];
  const selOffset = base + (selMember.bitOffset >> 3);
  if (s.flags & UnionFlag.HasTag) {
    const rawTag = readTagValue(dv, selOffset, selMember, littleEndian);
    const item = selMember.structure?.constructor?.[CAST]?.(rawTag);
    const activeName = item?.[NAME];
    return (activeName !== undefined) ? members.find(m => m.name === activeName) : undefined;
  } else {
    const idx = readUintBytes(dv, selOffset, selMember.byteSize, littleEndian);
    return (idx < members.length - 1) ? members[idx] : undefined;
  }
}
