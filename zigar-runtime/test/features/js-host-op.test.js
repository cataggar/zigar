import { expect } from 'chai';
import {
  MemberFlag,
  MemberType,
  PointerFlag,
  PosixError,
  PrimitiveFlag,
  SliceFlag,
  StructFlag,
  StructureFlag,
  StructurePurpose,
  StructureType,
} from '../../src/constants.js';
import { defineEnvironment } from '../../src/environment.js';
import { HostOpCode, HostOpFlag } from '../../src/features/js-host-op.js';
import '../../src/mixins.js';
import { MEMORY, SLOTS, ZIG } from '../../src/symbols.js';

const Env = defineEnvironment();

function createMemoryHarness(env) {
  const is64 = (process.env.TARGET === 'wasm') ? Boolean(env.memory64) : (process.env.BITS === '64');
  const ptrSize = is64 ? 8 : 4;
  if (process.env.TARGET === 'wasm') {
    env.memory = new WebAssembly.Memory({ initial: 2 });
    return {
      is64,
      ptrSize,
      viewAt(offset, len) {
        return env.obtainZigView(offset, len, false);
      },
      addrOf(offset) {
        return is64 ? BigInt(offset) : offset;
      },
      writeBytes(offset, bytes) {
        new Uint8Array(env.memory.buffer, offset, bytes.length).set(bytes);
      },
    };
  } else {
    const arena = new ArrayBuffer(65536);
    const baseAddr = is64 ? 0x100000n : 0x100000;
    env.obtainZigView = (address, len) => {
      const rel = Number(is64 ? BigInt(address) - baseAddr : address - baseAddr);
      if (len === 0) {
        const dv = new DataView(new ArrayBuffer(0));
        dv[ZIG] = { address, len: 0 };
        return dv;
      }
      const dv = new DataView(arena, rel, len);
      dv[ZIG] = { address, len };
      return dv;
    };
    return {
      is64,
      ptrSize,
      viewAt(offset, len) {
        const address = is64 ? baseAddr + BigInt(offset) : baseAddr + offset;
        return env.obtainZigView(address, len);
      },
      addrOf(offset) {
        return is64 ? baseAddr + BigInt(offset) : baseAddr + offset;
      },
      writeBytes(offset, bytes) {
        new Uint8Array(arena, offset, bytes.length).set(bytes);
      },
    };
  }
}

function writePtr(dv, offset, addr, is64) {
  if (is64) {
    dv.setBigUint64(offset, BigInt(addr), true);
  } else {
    dv.setUint32(offset, Number(addr), true);
  }
}

function writeDescriptor(harness, offset, { signature, op, flags = 0, keyAddr = 0, keyLen = 0, registerThunk = 0, argSize }) {
  const { is64, ptrSize } = harness;
  const size = is64 ? 48 : 32;
  const dv = harness.viewAt(offset, size);
  dv.setBigUint64(0, signature, true);
  dv.setUint32(8, op, true);
  dv.setUint32(12, flags, true);
  writePtr(dv, 16, keyAddr, is64);
  writePtr(dv, 16 + ptrSize, keyLen, is64);
  writePtr(dv, 16 + ptrSize * 2, registerThunk, is64);
  writePtr(dv, 16 + ptrSize * 3, argSize, is64);
  return harness.addrOf(offset);
}

function defineHostOpStructures(env, is64) {
  const ptrSize = is64 ? 8 : 4;
  const voidStruct = {
    type: StructureType.Primitive,
    name: 'void',
    byteSize: 0,
    align: 1,
    flags: StructureFlag.HasValue,
    signature: 10n,
    instance: { members: [ { type: MemberType.Void, bitSize: 0, bitOffset: 0, byteSize: 0 } ] },
    static: {},
  };
  voidStruct.instance.members[0].structure = voidStruct;
  env.beginStructure(voidStruct);
  env.finishStructure(voidStruct);

  const boolStruct = {
    type: StructureType.Primitive,
    name: 'bool',
    byteSize: 1,
    align: 1,
    flags: StructureFlag.HasValue,
    signature: 11n,
    instance: { members: [ { type: MemberType.Bool, bitSize: 1, bitOffset: 0, byteSize: 1 } ] },
    static: {},
  };
  boolStruct.instance.members[0].structure = boolStruct;
  env.beginStructure(boolStruct);
  env.finishStructure(boolStruct);

  const i32 = {
    type: StructureType.Primitive,
    name: 'i32',
    byteSize: 4,
    align: 4,
    flags: StructureFlag.HasValue,
    signature: 12n,
    instance: { members: [ { type: MemberType.Int, bitSize: 32, bitOffset: 0, byteSize: 4 } ] },
    static: {},
  };
  i32.instance.members[0].structure = i32;
  env.beginStructure(i32);
  env.finishStructure(i32);

  const u32 = {
    type: StructureType.Primitive,
    name: 'u32',
    byteSize: 4,
    align: 4,
    flags: StructureFlag.HasValue,
    signature: 13n,
    instance: { members: [ { type: MemberType.Uint, bitSize: 32, bitOffset: 0, byteSize: 4 } ] },
    static: {},
  };
  u32.instance.members[0].structure = u32;
  env.beginStructure(u32);
  env.finishStructure(u32);

  const u8 = {
    type: StructureType.Primitive,
    name: 'u8',
    byteSize: 1,
    align: 1,
    flags: StructureFlag.HasValue,
    signature: 14n,
    instance: { members: [ { type: MemberType.Uint, bitSize: 8, bitOffset: 0, byteSize: 1 } ] },
    static: {},
  };
  u8.instance.members[0].structure = u8;
  env.beginStructure(u8);
  env.finishStructure(u8);

  const strSlice = {
    type: StructureType.Slice,
    name: '[_]u8',
    byteSize: 1,
    align: 1,
    flags: SliceFlag.IsString | SliceFlag.IsTypedArray | StructureFlag.HasProxy,
    signature: 15n,
    instance: { members: [ { type: MemberType.Uint, bitSize: 8, byteSize: 1, structure: u8 } ] },
    static: {},
  };
  env.beginStructure(strSlice);
  env.finishStructure(strSlice);

  const usizeStruct = {
    type: StructureType.Primitive,
    name: 'usize',
    byteSize: ptrSize,
    align: ptrSize,
    flags: StructureFlag.HasValue | PrimitiveFlag.IsSize,
    signature: 150n,
    instance: { members: [ { type: MemberType.Uint, bitSize: ptrSize * 8, bitOffset: 0, byteSize: ptrSize } ] },
    static: {},
  };
  usizeStruct.instance.members[0].structure = usizeStruct;
  env.beginStructure(usizeStruct);
  env.finishStructure(usizeStruct);

  const strPtr = {
    type: StructureType.Pointer,
    name: '[]const u8',
    byteSize: ptrSize * 2,
    align: ptrSize,
    flags: StructureFlag.HasPointer | StructureFlag.HasSlot | StructureFlag.HasObject | StructureFlag.HasValue | StructureFlag.HasProxy
      | PointerFlag.IsMultiple | PointerFlag.HasLength | PointerFlag.IsConst,
    signature: 16n,
    instance: {
      members: [
        { type: MemberType.Object, bitSize: ptrSize * 8, bitOffset: 0, byteSize: ptrSize, slot: 0, structure: strSlice },
        { type: MemberType.Uint, bitSize: ptrSize * 8, bitOffset: 0, byteSize: ptrSize, structure: usizeStruct },
        { type: MemberType.Uint, bitSize: ptrSize * 8, bitOffset: ptrSize * 8, byteSize: ptrSize, structure: usizeStruct },
      ],
    },
    static: {},
  };
  env.beginStructure(strPtr);
  env.finishStructure(strPtr);

  const jsRef = {
    type: StructureType.Struct,
    purpose: StructurePurpose.JsValue,
    name: 'Ref',
    byteSize: 4,
    align: 4,
    flags: StructureFlag.HasValue | StructFlag.IsExtern,
    signature: 17n,
    instance: {
      members: [
        { name: 'handle', type: MemberType.Uint, bitSize: 32, bitOffset: 0, byteSize: 4, structure: u32 },
      ],
    },
    static: {},
  };
  env.beginStructure(jsRef);
  env.finishStructure(jsRef);

  const errSet = {
    type: StructureType.ErrorSet,
    name: 'HostError',
    byteSize: 2,
    align: 2,
    flags: StructureFlag.HasValue,
    signature: 18n,
    instance: {
      members: [],
    },
    static: {},
  };
  errSet.instance.members.push({ type: MemberType.Uint, bitSize: 16, bitOffset: 0, byteSize: 2, structure: errSet });
  env.beginStructure(errSet);
  const jsExcDV = new DataView(new Uint16Array([ 1 ]).buffer);
  const boomDV = new DataView(new Uint16Array([ 2 ]).buffer);
  errSet.static = {
    members: [
      { name: 'JsException', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 0, structure: errSet },
      { name: 'Boom', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 1, structure: errSet },
    ],
    template: {
      [SLOTS]: {
        0: env.createInstance(errSet, jsExcDV),
        1: env.createInstance(errSet, boomDV),
      },
    },
  };
  env.finishStructure(errSet);

  const errUnionI32 = {
    type: StructureType.ErrorUnion,
    name: 'HostError!i32',
    byteSize: 8,
    align: 4,
    flags: StructureFlag.HasValue,
    signature: 19n,
    instance: {
      members: [
        { type: MemberType.Int, bitSize: 32, bitOffset: 0, byteSize: 4, structure: i32 },
        { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 32, byteSize: 2, structure: errSet },
      ],
    },
    static: {},
  };
  env.beginStructure(errUnionI32);
  env.finishStructure(errUnionI32);

  function makeArgStruct(signature, retvalStructure, argStructures) {
    let offset = 0;
    let nextSlot = 0;
    const members = [];
    const retvalSize = retvalStructure.byteSize;
    const retvalType = (retvalStructure.type === StructureType.Primitive)
      ? retvalStructure.instance.members[0].type
      : MemberType.Object;
    members.push({
      name: 'retval',
      type: retvalType,
      bitSize: retvalSize * 8,
      bitOffset: 0,
      byteSize: retvalSize,
      slot: (retvalType === MemberType.Object) ? nextSlot++ : undefined,
      structure: retvalStructure,
    });
    offset = Math.max(retvalSize, 4);
    argStructures.forEach((st, idx) => {
      const align = st.align || 1;
      offset = (offset + align - 1) & ~(align - 1);
      const mType = (st.type === StructureType.Primitive)
        ? st.instance.members[0].type
        : MemberType.Object;
      members.push({
        name: String(idx),
        type: mType,
        bitSize: st.byteSize * 8,
        bitOffset: offset * 8,
        byteSize: st.byteSize,
        slot: (mType === MemberType.Object) ? nextSlot++ : undefined,
        structure: st,
      });
      offset += st.byteSize;
    });
    const totalSize = Math.max(4, (offset + 7) & ~7);
    const hasPointer = [ retvalStructure, ...argStructures ].some((st) => Boolean(st.flags & StructureFlag.HasPointer));
    const s = {
      type: StructureType.ArgStruct,
      name: `Args_${signature}`,
      length: argStructures.length,
      byteSize: totalSize,
      align: ptrSize,
      flags: StructureFlag.HasValue
        | (nextSlot > 0 ? (StructureFlag.HasObject | StructureFlag.HasSlot) : 0)
        | (hasPointer ? StructureFlag.HasPointer : 0),
      signature,
      instance: { members },
      static: {},
    };
    env.beginStructure(s);
    env.finishStructure(s);
    return s;
  }

  return {
    voidStruct,
    boolStruct,
    i32,
    u32,
    strPtr,
    jsRef,
    errSet,
    errUnionI32,
    makeArgStruct,
  };
}

describe('Feature: js-host-op', function() {
  it('should execute all 9 host operations, intern UTF-8 keys once, bind method `this`, and support Symbol keys', function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const types = defineHostOpStructures(env, harness.is64);

    // 1. Module registration & import_module
    const fakeMod = { version: 7 };
    env.registerJsModule('virtual:alpha', fakeMod);
    env.setObject('modules', { 'virtual:beta': { name: 'beta' } });
    expect(env.resolveJsModule('virtual:alpha')).to.equal(fakeMod);
    expect(env.resolveJsModule('virtual:beta')).to.deep.equal({ name: 'beta' });
    const nodePath = env.resolveJsModule('node:path');
    expect(nodePath.join('a', 'b')).to.be.a('string');

    // ArgStructs for each operation
    const argsImport = types.makeArgStruct(101n, types.jsRef, [ types.strPtr ]);
    const argsGetGlobal = types.makeArgStruct(102n, types.jsRef, []);
    const argsGetPropI32 = types.makeArgStruct(103n, types.i32, [ types.jsRef ]);
    const argsSetPropI32 = types.makeArgStruct(104n, types.voidStruct, [ types.jsRef, types.i32 ]);
    const argsHasProp = types.makeArgStruct(105n, types.boolStruct, [ types.jsRef ]);
    const argsDeleteProp = types.makeArgStruct(106n, types.boolStruct, [ types.jsRef ]);
    const argsCallFn = types.makeArgStruct(107n, types.i32, [ types.jsRef, types.i32, types.i32 ]);
    const argsCallMethod = types.makeArgStruct(108n, types.i32, [ types.jsRef, types.i32 ]);
    const argsConstruct = types.makeArgStruct(109n, types.jsRef, [ types.jsRef, types.i32 ]);
    const argsGetSym = types.makeArgStruct(110n, types.i32, [ types.jsRef, types.jsRef ]);
    const argsFallibleMethod = types.makeArgStruct(111n, types.errUnionI32, [ types.jsRef, types.i32 ]);

    // Write UTF-8 keys into Zig memory
    const enc = new TextEncoder();
    const writeKey = (off, str) => {
      const bytes = enc.encode(str);
      harness.writeBytes(off, bytes);
      return { keyAddr: harness.addrOf(off), keyLen: bytes.length };
    };
    const kSpec = writeKey(0x100, 'virtual:alpha');
    const kMath = writeKey(0x140, 'Math');
    const kCount = writeKey(0x180, 'count');
    const kStep = writeKey(0x1C0, 'step');
    const kFail = writeKey(0x200, 'explode');
    const kMissing = writeKey(0x240, 'notAFunction');

    // Write descriptors
    const dImport = writeDescriptor(harness, 0x400, { signature: 101n, op: HostOpCode.ImportModule, flags: HostOpFlag.DynamicKey, argSize: argsImport.byteSize });
    const dGlobal = writeDescriptor(harness, 0x440, { signature: 102n, op: HostOpCode.GetGlobal, ...kMath, argSize: argsGetGlobal.byteSize });
    const dGetCount = writeDescriptor(harness, 0x480, { signature: 103n, op: HostOpCode.GetProp, ...kCount, argSize: argsGetPropI32.byteSize });
    const dSetCount = writeDescriptor(harness, 0x4C0, { signature: 104n, op: HostOpCode.SetProp, ...kCount, argSize: argsSetPropI32.byteSize });
    const dHasCount = writeDescriptor(harness, 0x500, { signature: 105n, op: HostOpCode.HasProp, ...kCount, argSize: argsHasProp.byteSize });
    const dDelCount = writeDescriptor(harness, 0x540, { signature: 106n, op: HostOpCode.DeleteProp, ...kCount, argSize: argsDeleteProp.byteSize });
    const dCallFn = writeDescriptor(harness, 0x580, { signature: 107n, op: HostOpCode.CallFn, argSize: argsCallFn.byteSize });
    const dCallStep = writeDescriptor(harness, 0x5C0, { signature: 108n, op: HostOpCode.CallMethod, ...kStep, argSize: argsCallMethod.byteSize });
    const dConstruct = writeDescriptor(harness, 0x600, { signature: 109n, op: HostOpCode.Construct, argSize: argsConstruct.byteSize });
    const dGetSym = writeDescriptor(harness, 0x640, { signature: 110n, op: HostOpCode.GetProp, flags: HostOpFlag.DynamicKey, argSize: argsGetSym.byteSize });
    const dCallFail = writeDescriptor(harness, 0x680, { signature: 111n, op: HostOpCode.CallMethod, ...kFail, argSize: argsFallibleMethod.byteSize });
    const dCallMissing = writeDescriptor(harness, 0x6C0, { signature: 111n, op: HostOpCode.CallMethod, ...kMissing, argSize: argsFallibleMethod.byteSize });

    const frameAddr = harness.addrOf(0x1000);
    const frameDV = harness.viewAt(0x1000, 128);

    // Execute ImportModule (poison retval slot with 0xaaaaaaaa first to verify writingUninitZig guard!)
    frameDV.setUint32(0, 0xaaaaaaaa, true);
    const arg0Off = argsImport.instance.members[1].bitOffset / 8;
    writePtr(frameDV, arg0Off, kSpec.keyAddr, harness.is64);
    writePtr(frameDV, arg0Off + harness.ptrSize, kSpec.keyLen, harness.is64);
    expect(env.invokeJsHostOp(dImport, frameAddr)).to.equal(0);
    const modHandle = frameDV.getUint32(0, true);
    expect(env.getJsValue(modHandle)).to.equal(fakeMod);
    env.releaseJsValue(modHandle);

    // Execute GetGlobal('Math')
    frameDV.setUint32(0, 0xaaaaaaaa, true);
    expect(env.invokeJsHostOp(dGlobal, frameAddr)).to.equal(0);
    const mathHandle = frameDV.getUint32(0, true);
    expect(env.getJsValue(mathHandle)).to.equal(globalThis.Math);
    env.releaseJsValue(mathHandle);

    // Execute Construct: new Counter(10)
    class Counter {
      constructor(initial) {
        this.count = initial;
      }
      step(delta) {
        if (!(this instanceof Counter)) {
          throw new TypeError('wrong `this` binding!');
        }
        this.count += delta;
        return this.count;
      }
      explode() {
        const err = new Error('boom');
        err.error = 'Boom';
        throw err;
      }
    }
    const ctorHandle = env.allocJsValue(Counter);
    frameDV.setUint32(0, 0xaaaaaaaa, true);
    frameDV.setUint32(4, ctorHandle, true);
    frameDV.setInt32(8, 10, true);
    expect(env.invokeJsHostOp(dConstruct, frameAddr)).to.equal(0);
    const instHandle = frameDV.getUint32(0, true);
    const inst = env.getJsValue(instHandle);
    expect(inst).to.be.instanceOf(Counter);
    expect(inst.count).to.equal(10);

    // Key interning verification: 'count' shared across GetProp, SetProp, HasProp, DeleteProp!
    const decodeBeforeCount = env.jsKeyDecodeCount;
    for (let iter = 0; iter < 50; iter++) {
      // set_prop: inst.count = 20 + iter
      frameDV.setUint32(4, instHandle, true);
      frameDV.setInt32(8, 20 + iter, true);
      expect(env.invokeJsHostOp(dSetCount, frameAddr)).to.equal(0);

      // get_prop: inst.count
      frameDV.setUint32(4, instHandle, true);
      expect(env.invokeJsHostOp(dGetCount, frameAddr)).to.equal(0);
      expect(frameDV.getInt32(0, true)).to.equal(20 + iter);

      // has_prop: 'count' in inst
      frameDV.setUint32(4, instHandle, true);
      expect(env.invokeJsHostOp(dHasCount, frameAddr)).to.equal(0);
      expect(frameDV.getUint8(0)).to.equal(1);
    }
    // Across 150 calls across 3 distinct descriptors sharing kCount, UTF-8 decode happened AT MOST ONCE!
    expect(env.jsKeyDecodeCount - decodeBeforeCount).to.equal(1);

    // call_method: inst.step(5) -> verifies `this` is bound to `inst` AND 'step' is decoded only once!
    const decodeBeforeStep = env.jsKeyDecodeCount;
    for (let i = 0; i < 10; i++) {
      frameDV.setUint32(4, instHandle, true);
      frameDV.setInt32(8, 5, true);
      expect(env.invokeJsHostOp(dCallStep, frameAddr)).to.equal(0);
    }
    expect(env.jsKeyDecodeCount - decodeBeforeStep).to.equal(1);
    expect(inst.count).to.equal(69 + 50);

    // call_fn: standalone function handle
    const fnHandle = env.allocJsValue((a, b) => a * b + 1);
    frameDV.setUint32(4, fnHandle, true);
    frameDV.setInt32(8, 6, true);
    frameDV.setInt32(12, 7, true);
    expect(env.invokeJsHostOp(dCallFn, frameAddr)).to.equal(0);
    expect(frameDV.getInt32(0, true)).to.equal(43);
    env.releaseJsValue(fnHandle);

    // Symbol-keyed get_prop via HostOpFlag.DynamicKey
    const secretSym = Symbol('secret');
    inst[secretSym] = 777;
    const symHandle = env.allocJsValue(secretSym);
    frameDV.setUint32(4, instHandle, true);
    frameDV.setUint32(8, symHandle, true);
    expect(env.invokeJsHostOp(dGetSym, frameAddr)).to.equal(0);
    expect(frameDV.getInt32(0, true)).to.equal(777);
    env.releaseJsValue(symHandle);

    // Fallible ErrorUnion method: mapped error ('Boom') and non-function method ('notAFunction' -> JsException)
    const errArg0Off = argsFallibleMethod.instance.members[1].bitOffset / 8;
    const errArg1Off = argsFallibleMethod.instance.members[2].bitOffset / 8;
    frameDV.setUint32(errArg0Off, instHandle, true);
    frameDV.setInt32(errArg1Off, 1, true);
    expect(env.invokeJsHostOp(dCallFail, frameAddr)).to.equal(0);
    expect(frameDV.getUint16(4, true)).to.be.greaterThan(0);

    inst.notAFunction = 123;
    frameDV.setUint32(errArg0Off, instHandle, true);
    frameDV.setInt32(errArg1Off, 1, true);
    expect(env.invokeJsHostOp(dCallMissing, frameAddr)).to.equal(0);
    expect(frameDV.getUint16(4, true)).to.be.greaterThan(0);

    // delete_prop + has_prop == false
    frameDV.setUint32(4, instHandle, true);
    expect(env.invokeJsHostOp(dDelCount, frameAddr)).to.equal(0);
    expect(frameDV.getUint8(0)).to.equal(1);
    frameDV.setUint32(4, instHandle, true);
    expect(env.invokeJsHostOp(dHasCount, frameAddr)).to.equal(0);
    expect(frameDV.getUint8(0)).to.equal(0);

    env.releaseJsValue(instHandle);
    env.releaseJsValue(ctorHandle);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should register and release >64 dynamic Zig callbacks with zero js-fn thunk usage', function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const types = defineHostOpStructures(env, harness.is64);

    // Callback trampoline ArgStruct: fn (slot_id: usize/u32, x: i32) i32
    const ptrInt = {
      type: StructureType.Primitive,
      name: 'usize',
      byteSize: harness.ptrSize,
      align: harness.ptrSize,
      flags: StructureFlag.HasValue,
      signature: 200n,
      instance: {
        members: [
          {
            type: MemberType.Uint,
            bitSize: harness.ptrSize * 8,
            bitOffset: 0,
            byteSize: harness.ptrSize,
          },
        ],
      },
      static: {},
    };
    ptrInt.instance.members[0].structure = ptrInt;
    env.beginStructure(ptrInt);
    env.finishStructure(ptrInt);

    const cbArgStruct = types.makeArgStruct(201n, types.i32, [ types.i32 ]);
    const trampAddr = harness.is64 ? 0x9999n : 0x9999;
    const descSize = 16 + 2 * harness.ptrSize;
    const descDV = harness.viewAt(0x800, descSize);
    descDV.setBigUint64(0, 201n, true);
    descDV.setUint32(8, 0, true);
    descDV.setUint32(12, 0, true);
    writePtr(descDV, 16, trampAddr, harness.is64);
    writePtr(descDV, 16 + harness.ptrSize, 0, harness.is64);
    const descAddr = harness.addrOf(0x800);

    // Intercept invokeThunk to simulate the shared Zig trampoline reading callbackId from fnHolder[MEMORY][ZIG].address
    const states = new Map();
    env.comptime = false;
    env.useJSPI = 'all';
    env.runThunk = () => true;
    env.invokeThunk = function(thunkHolder, fnHolder, argsHolder) {
      expect(fnHolder.zigarSync).to.be.true;
      const slotId = Number(fnHolder[MEMORY][ZIG].address);
      argsHolder.retval = states.get(slotId) + argsHolder[0];
      return argsHolder.retval;
    };

    const handles = [];
    for (let i = 1; i <= 80; i++) {
      states.set(i, i * 1000);
      const h = env.createZigCallback(descAddr, i);
      expect(h).to.be.greaterThan(0);
      handles.push({ h, slotId: i, expectedBase: i * 1000 });
    }
    expect(env.getActiveZigCallbackCount()).to.equal(80);
    expect(env.getJsValueCount()).to.equal(80);

    for (const { h, expectedBase } of handles) {
      const jsFn = env.getJsValue(h);
      expect(jsFn).to.be.a('function');
      expect(jsFn(7)).to.equal(expectedBase + 7);
    }

    for (const { h, slotId } of handles) {
      env.releaseZigCallback(slotId);
      const releasedFn = env.getJsValue(h);
      expect(() => releasedFn(1)).to.throw(/already been released/);
      env.releaseJsValue(h);
    }
    expect(env.getActiveZigCallbackCount()).to.equal(0);
    expect(env.getJsValueCount()).to.equal(0);

    if (process.env.TARGET === 'node') {
      const exported = env.exportFunctions();
      expect(exported.invokeJsHostOp).to.be.a('function');
      expect(exported.createZigCallback).to.be.a('function');
      expect(exported.releaseZigCallback).to.be.a('function');
    }
  });

  it('should capture uncaught infallible and NotInErrorSet exceptions as pending errors and preserve first error across defer host-ops', function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const types = defineHostOpStructures(env, harness.is64);

    // Narrow error set without JsException (`error{OnlyBoom}!i32`)
    const narrowErrSet = {
      type: StructureType.ErrorSet,
      name: 'NarrowError',
      byteSize: 2,
      align: 2,
      flags: StructureFlag.HasValue,
      signature: 301n,
      instance: { members: [] },
      static: {},
    };
    narrowErrSet.instance.members.push({ type: MemberType.Uint, bitSize: 16, bitOffset: 0, byteSize: 2, structure: narrowErrSet });
    env.beginStructure(narrowErrSet);
    narrowErrSet.static = {
      members: [
        { name: 'OnlyBoom', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 0, structure: narrowErrSet },
      ],
      template: {
        [SLOTS]: {
          0: env.createInstance(narrowErrSet, new DataView(new Uint16Array([ 1 ]).buffer)),
        },
      },
    };
    env.finishStructure(narrowErrSet);

    const narrowEuI32 = {
      type: StructureType.ErrorUnion,
      name: 'NarrowError!i32',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasValue,
      signature: 302n,
      instance: {
        members: [
          { type: MemberType.Int, bitSize: 32, bitOffset: 0, byteSize: 4, structure: types.i32 },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 32, byteSize: 2, structure: narrowErrSet },
        ],
      },
      static: {},
    };
    env.beginStructure(narrowEuI32);
    env.finishStructure(narrowEuI32);

    const argsInfallibleCall = types.makeArgStruct(303n, types.i32, [ types.jsRef ]);
    const argsNarrowCall = types.makeArgStruct(304n, narrowEuI32, [ types.jsRef ]);
    const argsSetProp = types.makeArgStruct(305n, types.voidStruct, [ types.jsRef, types.i32 ]);

    const enc = new TextEncoder();
    const keyBytes = enc.encode('cleaned');
    const keyView = harness.viewAt(0x100, keyBytes.length);
    new Uint8Array(keyView.buffer, keyView.byteOffset, keyBytes.length).set(keyBytes);
    const kCleaned = { keyAddr: harness.addrOf(0x100), keyLen: harness.is64 ? BigInt(keyBytes.length) : keyBytes.length };

    const dInfallible = writeDescriptor(harness, 0x300, { signature: 303n, op: HostOpCode.CallFn, argSize: argsInfallibleCall.byteSize });
    const dNarrow = writeDescriptor(harness, 0x340, { signature: 304n, op: HostOpCode.CallFn, argSize: argsNarrowCall.byteSize });
    const dSetCleaned = writeDescriptor(harness, 0x380, { signature: 305n, op: HostOpCode.SetProp, ...kCleaned, argSize: argsSetProp.byteSize });

    const frameAddr = harness.addrOf(0x900);
    const frameDV = harness.viewAt(0x900, 64);

    // 1. Infallible throw returns PosixError.EFAULT (never throws across FFI!) and records pendingHostError
    const firstBoom = new Error('infallible boom');
    const badFnHandle = env.allocJsValue(() => {
      throw firstBoom;
    });
    frameDV.setUint32(4, badFnHandle, true);
    expect(env.invokeJsHostOp(dInfallible, frameAddr)).to.equal(PosixError.EFAULT);
    expect(env.hasPendingHostError).to.be.true;
    expect(env.pendingHostError).to.equal(firstBoom);

    // 2. Simulated Zig `defer` host-op runs cleanly while pending error is saved & restored (first-error-wins!)
    const targetObj = { cleaned: 0 };
    const objHandle = env.allocJsValue(targetObj);
    const setArg0Off = argsSetProp.instance.members[1].bitOffset / 8;
    const setArg1Off = argsSetProp.instance.members[2].bitOffset / 8;
    frameDV.setUint32(setArg0Off, objHandle, true);
    frameDV.setInt32(setArg1Off, 1, true);
    expect(env.invokeJsHostOp(dSetCleaned, frameAddr)).to.equal(PosixError.NONE);
    expect(targetObj.cleaned).to.equal(1);
    expect(env.hasPendingHostError).to.be.true;
    expect(env.pendingHostError).to.equal(firstBoom);

    // Even if a secondary defer host-op also throws, firstBoom is preserved!
    const secondFnHandle = env.allocJsValue(() => {
      throw new Error('secondary defer error');
    });
    frameDV.setUint32(4, secondFnHandle, true);
    expect(env.invokeJsHostOp(dInfallible, frameAddr)).to.equal(PosixError.EFAULT);
    expect(env.pendingHostError).to.equal(firstBoom);

    const consumed = env.consumePendingHostError();
    expect(consumed?.error).to.equal(firstBoom);
    expect(env.hasPendingHostError).to.be.false;

    // 3. NotInErrorSet mismatch also returns PosixError.EFAULT and records NotInErrorSet as pendingHostError
    const narrowArg0Off = argsNarrowCall.instance.members[1].bitOffset / 8;
    frameDV.setUint32(narrowArg0Off, badFnHandle, true);
    expect(env.invokeJsHostOp(dNarrow, frameAddr)).to.equal(PosixError.EFAULT);
    const narrowPending = env.consumePendingHostError();
    expect(narrowPending?.error).to.be.an('error');
    expect(narrowPending?.error.constructor.name).to.equal('NotInErrorSet');

    env.releaseJsValue(badFnHandle);
    env.releaseJsValue(secondFnHandle);
    env.releaseJsValue(objHandle);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should discard live JsValue handles written to retval when invokeThunk exits with a pending host error', function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const s = defineHostOpStructures(env, harness.is64);

    // ArgStruct for `fn () Ref(Object)` (retval is jsRef at offset 0)
    const argsReturnRef = s.makeArgStruct(0x8801n, s.jsRef, []);
    const ArgStructCtor = argsReturnRef.constructor;

    const leakedCandidate = { role: 'returned-after-throw' };
    let liveHandle = 0;
    const expectedBoom = new Error('infallible-boom-before-return');

    if (process.env.TARGET === 'wasm') {
      let nextScratch = 0x9000;
      env.allocateScratchMemory = (len) => {
        const addr = nextScratch;
        nextScratch += (len + 15) & ~15;
        return addr;
      };
      env.freeScratchMemory = () => {};
      env.runThunk = (_thunkAddr, _fnAddr, argAddr) => {
        liveHandle = env.allocJsValue(leakedCandidate);
        const dv = env.obtainZigView(argAddr, 4, false);
        dv.setUint32(0, liveHandle, true);
        env.recordPendingHostError(expectedBoom);
        return true;
      };
    } else {
      env.getBufferAddress = () => harness.addrOf(0x9000);
      env.runThunk = () => {
        liveHandle = env.allocJsValue(leakedCandidate);
        // Write live handle directly into the outbound argStruct's buffer via active call interception
        return true;
      };
    }

    const thunkDV = new DataView(new ArrayBuffer(0));
    thunkDV[ZIG] = { address: harness.addrOf(0x100), len: 0 };
    const fnDV = new DataView(new ArrayBuffer(0));
    fnDV[ZIG] = { address: harness.addrOf(0x200), len: 0 };
    const thunk = { [MEMORY]: thunkDV };
    const fnObj = Object.assign(() => {}, { [MEMORY]: fnDV });

    if (process.env.TARGET === 'node') {
      // Test discardJsValueRetval directly AND via invokeThunk with live handle in argStruct[MEMORY]
      const argStruct = new ArgStructCtor([]);
      liveHandle = env.allocJsValue(leakedCandidate);
      argStruct[MEMORY].setUint32(0, liveHandle, env.littleEndian);
      expect(env.getJsValueCount()).to.equal(1);
      env.runThunk = () => {
        env.recordPendingHostError(expectedBoom);
        return true;
      };
      expect(() => env.invokeThunk(thunk, fnObj, argStruct)).to.throw(expectedBoom);
      expect(env.getJsValueCount()).to.equal(0);
    } else {
      const caller = env.createOutboundCaller(thunk, ArgStructCtor);
      caller[MEMORY] = fnDV;
      expect(() => caller()).to.throw(expectedBoom);
      expect(liveHandle).to.be.greaterThan(4);
      expect(env.getJsValueCount()).to.equal(0);
    }
  });

  it('should handle ModuleDefault flag and ESM namespace .default fallback for CJS export = callable/class', function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const s = defineHostOpStructures(env, harness.is64);

    // Simulate ESM `import * as cjsMod` wrapping a CJS `module.exports = Object.assign(fn, { extra, method })`
    const cjsFn = Object.assign(
      function(a, b) {
        return a * 10 + b;
      },
      {
        extra: 77,
        readExtra() {
          if (this !== cjsFn) {
            throw new TypeError('lost default this binding');
          }
          return this.extra;
        },
      },
    );
    const esmWrappedCjs = Object.defineProperty({ default: cjsFn }, Symbol.toStringTag, { value: 'Module' });
    env.registerJsModules({
      'esm-wrapped-cjs': esmWrappedCjs,
      'raw-cjs-fn': cjsFn,
    });

    const argsImport = s.makeArgStruct(401n, s.jsRef, []);
    const argsHas = s.makeArgStruct(402n, s.boolStruct, [ s.jsRef ]);
    const argsGetI32 = s.makeArgStruct(403n, s.i32, [ s.jsRef ]);
    const argsCallMethod = s.makeArgStruct(404n, s.i32, [ s.jsRef ]);
    const argsCallFn = s.makeArgStruct(405n, s.i32, [ s.jsRef, s.i32, s.i32 ]);

    const enc = new TextEncoder();
    let strOff = 0x100;
    const putKey = (text) => {
      const bytes = enc.encode(text);
      const view = harness.viewAt(strOff, bytes.length);
      new Uint8Array(view.buffer, view.byteOffset, bytes.length).set(bytes);
      const out = { keyAddr: harness.addrOf(strOff), keyLen: harness.is64 ? BigInt(bytes.length) : bytes.length };
      strOff += (bytes.length + 7) & ~7;
      return out;
    };

    const kWrapped = putKey('esm-wrapped-cjs');
    const kRaw = putKey('raw-cjs-fn');
    const kExtra = putKey('extra');
    const kReadExtra = putKey('readExtra');

    const dImportNs = writeDescriptor(harness, 0x300, { signature: 401n, op: HostOpCode.ImportModule, ...kWrapped, argSize: argsImport.byteSize });
    const dImportDefWrapped = writeDescriptor(harness, 0x340, { signature: 401n, op: HostOpCode.ImportModule, flags: HostOpFlag.ModuleDefault, ...kWrapped, argSize: argsImport.byteSize });
    const dImportDefRaw = writeDescriptor(harness, 0x380, { signature: 401n, op: HostOpCode.ImportModule, flags: HostOpFlag.ModuleDefault, ...kRaw, argSize: argsImport.byteSize });
    const dHasExtra = writeDescriptor(harness, 0x3c0, { signature: 402n, op: HostOpCode.HasProp, ...kExtra, argSize: argsHas.byteSize });
    const dGetExtra = writeDescriptor(harness, 0x400, { signature: 403n, op: HostOpCode.GetProp, ...kExtra, argSize: argsGetI32.byteSize });
    const dCallReadExtra = writeDescriptor(harness, 0x440, { signature: 404n, op: HostOpCode.CallMethod, ...kReadExtra, argSize: argsCallMethod.byteSize });
    const dCallFn = writeDescriptor(harness, 0x480, { signature: 405n, op: HostOpCode.CallFn, argSize: argsCallFn.byteSize });

    const frameAddr = harness.addrOf(0x900);
    const frameDV = harness.viewAt(0x900, 64);

    // 1. ImportModule with ModuleDefault unwraps ESM namespace `.default` AND returns raw CJS export directly
    expect(env.invokeJsHostOp(dImportDefWrapped, frameAddr)).to.equal(PosixError.NONE);
    const hDefWrapped = frameDV.getUint32(0, true);
    expect(env.getJsValue(hDefWrapped)).to.equal(cjsFn);

    expect(env.invokeJsHostOp(dImportDefRaw, frameAddr)).to.equal(PosixError.NONE);
    const hDefRaw = frameDV.getUint32(0, true);
    expect(env.getJsValue(hDefRaw)).to.equal(cjsFn);

    // 2. ImportModule namespace falls back to `.default` for non-hoisted CJS properties/methods & CallFn
    expect(env.invokeJsHostOp(dImportNs, frameAddr)).to.equal(PosixError.NONE);
    const hNs = frameDV.getUint32(0, true);
    expect(env.getJsValue(hNs)).to.equal(esmWrappedCjs);

    frameDV.setUint32(argsHas.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dHasExtra, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(1);

    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetExtra, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(77);

    frameDV.setUint32(argsCallMethod.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dCallReadExtra, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(77);

    frameDV.setUint32(argsCallFn.instance.members[1].bitOffset / 8, hNs, true);
    frameDV.setInt32(argsCallFn.instance.members[2].bitOffset / 8, 4, true);
    frameDV.setInt32(argsCallFn.instance.members[3].bitOffset / 8, 9, true);
    expect(env.invokeJsHostOp(dCallFn, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(49);

    env.releaseJsValue(hDefWrapped);
    env.releaseJsValue(hDefRaw);
    env.releaseJsValue(hNs);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should not shadow real named exports onto target.default on SetProp/DeleteProp and should support registerJsModuleLoaders', async function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const s = defineHostOpStructures(env, harness.is64);

    const errUnionVoid = {
      type: StructureType.ErrorUnion,
      name: 'HostError!void',
      byteSize: 2,
      align: 2,
      flags: StructureFlag.HasValue,
      signature: 420n,
      instance: {
        members: [
          { type: MemberType.Void, bitSize: 0, bitOffset: 0, byteSize: 0, structure: s.voidStruct },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 0, byteSize: 2, structure: s.errSet },
        ],
      },
      static: {},
    };
    env.beginStructure(errUnionVoid);
    env.finishStructure(errUnionVoid);

    const defaultObj = { live: 100, onlyOnDefault: 42 };
    const esmNamespace = Object.create(null);
    Object.defineProperties(esmNamespace, {
      [Symbol.toStringTag]: { value: 'Module' },
      live: {
        get: () => 1,
        enumerable: true,
        configurable: false,
      },
      default: {
        get: () => defaultObj,
        enumerable: true,
        configurable: false,
      },
    });
    Object.freeze(esmNamespace);

    let loaderCalls = 0;
    env.registerJsModuleLoaders({
      './singleton-esm.mjs': async () => {
        loaderCalls++;
        return esmNamespace;
      },
    });
    await env.preloadJsModules([ './singleton-esm.mjs' ]);
    expect(loaderCalls).to.equal(1);
    expect(env.resolveJsModule('./singleton-esm.mjs')).to.equal(esmNamespace);

    const argsSetFallible = s.makeArgStruct(421n, errUnionVoid, [ s.jsRef, s.i32 ]);
    const argsGetI32 = s.makeArgStruct(422n, s.i32, [ s.jsRef ]);
    const argsDelete = s.makeArgStruct(423n, s.boolStruct, [ s.jsRef ]);
    const argsHas = s.makeArgStruct(424n, s.boolStruct, [ s.jsRef ]);

    const enc = new TextEncoder();
    let strOff = 0x100;
    const putKey = (text) => {
      const bytes = enc.encode(text);
      const view = harness.viewAt(strOff, bytes.length);
      new Uint8Array(view.buffer, view.byteOffset, bytes.length).set(bytes);
      const out = { keyAddr: harness.addrOf(strOff), keyLen: harness.is64 ? BigInt(bytes.length) : bytes.length };
      strOff += (bytes.length + 7) & ~7;
      return out;
    };

    const kLive = putKey('live');
    const kOnly = putKey('onlyOnDefault');

    const dSetLive = writeDescriptor(harness, 0x300, { signature: 421n, op: HostOpCode.SetProp, ...kLive, argSize: argsSetFallible.byteSize });
    const dGetLive = writeDescriptor(harness, 0x340, { signature: 422n, op: HostOpCode.GetProp, ...kLive, argSize: argsGetI32.byteSize });
    const dDelLive = writeDescriptor(harness, 0x380, { signature: 423n, op: HostOpCode.DeleteProp, ...kLive, argSize: argsDelete.byteSize });
    const dHasLive = writeDescriptor(harness, 0x3c0, { signature: 424n, op: HostOpCode.HasProp, ...kLive, argSize: argsHas.byteSize });

    const dSetOnly = writeDescriptor(harness, 0x400, { signature: 421n, op: HostOpCode.SetProp, ...kOnly, argSize: argsSetFallible.byteSize });
    const dGetOnly = writeDescriptor(harness, 0x440, { signature: 422n, op: HostOpCode.GetProp, ...kOnly, argSize: argsGetI32.byteSize });
    const dDelOnly = writeDescriptor(harness, 0x480, { signature: 423n, op: HostOpCode.DeleteProp, ...kOnly, argSize: argsDelete.byteSize });
    const dHasOnly = writeDescriptor(harness, 0x4c0, { signature: 424n, op: HostOpCode.HasProp, ...kOnly, argSize: argsHas.byteSize });

    const frameAddr = harness.addrOf(0x900);
    const frameDV = harness.viewAt(0x900, 64);
    const hNs = env.allocJsValue(esmNamespace);

    // 1. SetProp('live', 5) fails with JsException (selector == 1) and does NOT mutate defaultObj.live (100)
    frameDV.setUint16(0, 0, true);
    frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hNs, true);
    frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 5, true);
    expect(env.invokeJsHostOp(dSetLive, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint16(0, true)).to.equal(1);
    expect(defaultObj.live).to.equal(100);

    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetLive, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(1);

    // 2. DeleteProp('live') returns false (0) and does NOT delete defaultObj.live (100)
    frameDV.setUint32(argsDelete.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dDelLive, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(0);
    expect(defaultObj.live).to.equal(100);
    expect('live' in defaultObj).to.be.true;

    frameDV.setUint32(argsHas.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dHasLive, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(1);

    // 3. SetProp & DeleteProp on 'onlyOnDefault' (NOT on namespace) still fall back to defaultObj
    frameDV.setUint16(0, 0xffff, true);
    frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hNs, true);
    frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 77, true);
    expect(env.invokeJsHostOp(dSetOnly, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint16(0, true)).to.equal(0);
    expect(defaultObj.onlyOnDefault).to.equal(77);

    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetOnly, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(77);

    frameDV.setUint32(argsDelete.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dDelOnly, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(1);
    expect('onlyOnDefault' in defaultObj).to.be.false;

    frameDV.setUint32(argsHas.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dHasOnly, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(0);

    env.releaseJsValue(hNs);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should unwrap Node CJS-wrapped ESM namespaces to live module.exports across GetProp, SetProp, DeleteProp, HasProp, and CallMethod', function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const s = defineHostOpStructures(env, harness.is64);

    const errUnionVoid = {
      type: StructureType.ErrorUnion,
      name: 'HostError!void',
      byteSize: 2,
      align: 2,
      flags: StructureFlag.HasValue,
      signature: 450n,
      instance: {
        members: [
          { type: MemberType.Void, bitSize: 0, bitOffset: 0, byteSize: 0, structure: s.voidStruct },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 0, byteSize: 2, structure: s.errSet },
        ],
      },
      static: {},
    };
    env.beginStructure(errUnionVoid);
    env.finishStructure(errUnionVoid);

    // Simulate Node's frozen ESM wrapper over `./named.cjs` where `cjsNs.counter` is a dead load-time snapshot (1)
    // while `cjsNs.default` and `cjsNs['module.exports']` point to the live `module.exports` object.
    const liveExports = {
      counter: 1,
      bump() {
        liveExports.counter += 1;
        return liveExports.counter;
      },
    };
    const cjsNamespace = Object.create(null);
    Object.defineProperties(cjsNamespace, {
      [Symbol.toStringTag]: { value: 'Module' },
      counter: { value: 1, writable: false, enumerable: true, configurable: false },
      bump: { value: liveExports.bump, writable: false, enumerable: true, configurable: false },
      default: { value: liveExports, writable: false, enumerable: true, configurable: false },
      'module.exports': { value: liveExports, writable: false, enumerable: true, configurable: false },
    });
    Object.freeze(cjsNamespace);

    const tsDefaultFn = () => 999;
    const tsCjsExports = Object.defineProperty({ default: tsDefaultFn }, '__esModule', { value: true });
    const tsCjsNamespace = Object.create(null);
    Object.defineProperties(tsCjsNamespace, {
      [Symbol.toStringTag]: { value: 'Module' },
      default: { value: tsCjsExports, enumerable: true },
      'module.exports': { value: tsCjsExports, enumerable: true },
    });
    Object.freeze(tsCjsNamespace);

    env.registerJsModules({
      'pkg-cjs-no-ext': cjsNamespace,
      'pkg-ts-cjs': tsCjsNamespace,
    });

    const argsImport = s.makeArgStruct(451n, s.jsRef, []);
    const argsGetI32 = s.makeArgStruct(452n, s.i32, [ s.jsRef ]);
    const argsCallBump = s.makeArgStruct(453n, s.i32, [ s.jsRef ]);
    const argsSetFallible = s.makeArgStruct(454n, errUnionVoid, [ s.jsRef, s.i32 ]);
    const argsDelete = s.makeArgStruct(455n, s.boolStruct, [ s.jsRef ]);
    const argsHas = s.makeArgStruct(456n, s.boolStruct, [ s.jsRef ]);
    const argsGetRef = s.makeArgStruct(457n, s.jsRef, [ s.jsRef ]);

    const enc = new TextEncoder();
    let strOff = 0x100;
    const putKey = (text) => {
      const bytes = enc.encode(text);
      const view = harness.viewAt(strOff, bytes.length);
      new Uint8Array(view.buffer, view.byteOffset, bytes.length).set(bytes);
      const out = { keyAddr: harness.addrOf(strOff), keyLen: harness.is64 ? BigInt(bytes.length) : bytes.length };
      strOff += (bytes.length + 7) & ~7;
      return out;
    };

    const kCounter = putKey('counter');
    const kBump = putKey('bump');
    const kDefault = putKey('default');
    const kModExports = putKey('module.exports');
    const kPkgCjs = putKey('pkg-cjs-no-ext');
    const kPkgTsCjs = putKey('pkg-ts-cjs');

    const dGetCounter = writeDescriptor(harness, 0x300, { signature: 452n, op: HostOpCode.GetProp, ...kCounter, argSize: argsGetI32.byteSize });
    const dCallBump = writeDescriptor(harness, 0x340, { signature: 453n, op: HostOpCode.CallMethod, ...kBump, argSize: argsCallBump.byteSize });
    const dSetCounter = writeDescriptor(harness, 0x380, { signature: 454n, op: HostOpCode.SetProp, ...kCounter, argSize: argsSetFallible.byteSize });
    const dDelCounter = writeDescriptor(harness, 0x3c0, { signature: 455n, op: HostOpCode.DeleteProp, ...kCounter, argSize: argsDelete.byteSize });
    const dHasCounter = writeDescriptor(harness, 0x400, { signature: 456n, op: HostOpCode.HasProp, ...kCounter, argSize: argsHas.byteSize });
    const dImportDef = writeDescriptor(harness, 0x440, { signature: 451n, op: HostOpCode.ImportModule, flags: HostOpFlag.ModuleDefault, ...kPkgCjs, argSize: argsImport.byteSize });
    const dImportTsDef = writeDescriptor(harness, 0x480, { signature: 451n, op: HostOpCode.ImportModule, flags: HostOpFlag.ModuleDefault, ...kPkgTsCjs, argSize: argsImport.byteSize });
    const dGetDefaultProp = writeDescriptor(harness, 0x4c0, { signature: 457n, op: HostOpCode.GetProp, ...kDefault, argSize: argsGetRef.byteSize });
    const dGetModExportsProp = writeDescriptor(harness, 0x500, { signature: 457n, op: HostOpCode.GetProp, ...kModExports, argSize: argsGetRef.byteSize });

    const frameAddr = harness.addrOf(0x900);
    const frameDV = harness.viewAt(0x900, 64);
    const hNs = env.allocJsValue(cjsNamespace);

    // 1. Initial GetProp('counter') == 1
    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(1);

    // 2. CallMethod('bump') -> 2, and subsequent GetProp('counter') reads live 2 (NOT stale snapshot cjsNamespace.counter === 1)
    frameDV.setUint32(argsCallBump.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dCallBump, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(2);
    expect(cjsNamespace.counter).to.equal(1);

    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(2);

    // 3. SetProp('counter', 42) mutates liveExports.counter without throwing on frozen cjsNamespace
    frameDV.setUint16(0, 0xffff, true);
    frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hNs, true);
    frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 42, true);
    expect(env.invokeJsHostOp(dSetCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint16(0, true)).to.equal(0);
    expect(liveExports.counter).to.equal(42);

    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(42);

    // 4. DeleteProp('counter') -> true, and HasProp('counter') -> false even though 'counter' in cjsNamespace is still true
    frameDV.setUint32(argsDelete.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dDelCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(1);
    expect('counter' in cjsNamespace).to.be.true;
    expect('counter' in liveExports).to.be.false;

    frameDV.setUint32(argsHas.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dHasCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(0);

    // 5. ModuleDefault, GetProp('default'), GetProp('module.exports'), and __esModule CJS default unwrap cleanly
    expect(env.invokeJsHostOp(dImportDef, frameAddr)).to.equal(PosixError.NONE);
    const hDef = frameDV.getUint32(0, true);
    expect(env.getJsValue(hDef)).to.equal(liveExports);

    expect(env.invokeJsHostOp(dImportTsDef, frameAddr)).to.equal(PosixError.NONE);
    const hTsDef = frameDV.getUint32(0, true);
    expect(env.getJsValue(hTsDef)).to.equal(tsDefaultFn);

    frameDV.setUint32(argsGetRef.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetDefaultProp, frameAddr)).to.equal(PosixError.NONE);
    const hGetDef = frameDV.getUint32(0, true);
    expect(env.getJsValue(hGetDef)).to.equal(liveExports);

    frameDV.setUint32(argsGetRef.instance.members[1].bitOffset / 8, hNs, true);
    expect(env.invokeJsHostOp(dGetModExportsProp, frameAddr)).to.equal(PosixError.NONE);
    const hGetModExp = frameDV.getUint32(0, true);
    expect(env.getJsValue(hGetModExp)).to.equal(liveExports);

    env.releaseJsValue(hNs);
    env.releaseJsValue(hDef);
    env.releaseJsValue(hTsDef);
    env.releaseJsValue(hGetDef);
    env.releaseJsValue(hGetModExp);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should preserve ESM facade own exports over CJS star-reexports, support Rollup _mergeNamespaces CJS, and keep __esModule CJS default parity', function() {
    const env = new Env();
    env.littleEndian = true;
    const harness = createMemoryHarness(env);
    const s = defineHostOpStructures(env, harness.is64);

    const errUnionVoid = {
      type: StructureType.ErrorUnion,
      name: 'HostError!void',
      byteSize: 2,
      align: 2,
      flags: StructureFlag.HasValue,
      signature: 470n,
      instance: {
        members: [
          { type: MemberType.Void, bitSize: 0, bitOffset: 0, byteSize: 0, structure: s.voidStruct },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 0, byteSize: 2, structure: s.errSet },
        ],
      },
      static: {},
    };
    env.beginStructure(errUnionVoid);
    env.finishStructure(errUnionVoid);

    // 1. ESM facade (`export * from './named.cjs'; export { default } from './named.cjs'; export const version = 2;`)
    // even when registered without `.mjs` extension (`./facade.js`)
    const namedExports = {
      counter: 1,
      bump() {
        namedExports.counter += 1;
        return namedExports.counter;
      },
    };
    const facadeNs = Object.create(null);
    Object.defineProperties(facadeNs, {
      [Symbol.toStringTag]: { value: 'Module' },
      counter: { value: 1, writable: false, enumerable: true, configurable: false },
      bump: { value: namedExports.bump, writable: false, enumerable: true, configurable: false },
      default: { value: namedExports, writable: false, enumerable: true, configurable: false },
      'module.exports': { value: namedExports, writable: false, enumerable: true, configurable: false },
      version: { value: 2, writable: false, enumerable: true, configurable: false },
    });
    Object.freeze(facadeNs);

    // 2. Rollup @rollup/plugin-commonjs `_mergeNamespaces` helper (exact output of v29)
    function mergeNamespaces(n, m) {
      m.forEach((e) => {
        if (e && typeof(e) !== 'string' && !Array.isArray(e)) {
          Object.keys(e).forEach((k) => {
            if (k !== 'default' && !(k in n)) {
              const d = Object.getOwnPropertyDescriptor(e, k);
              Object.defineProperty(n, k, d.get ? d : {
                enumerable: true,
                get: () => e[k],
              });
            }
          });
        }
      });
      return Object.freeze(n);
    }

    const rollupNamedExports = {
      counter: 1,
      bump() {
        rollupNamedExports.counter += 1;
        return rollupNamedExports.counter;
      },
    };
    const rollupNamedNs = mergeNamespaces({ __proto__: null, default: rollupNamedExports }, [ rollupNamedExports ]);

    const rollupFn = function(x) {
      return x + rollupFn.extra;
    };
    rollupFn.extra = 1;
    const rollupFnNs = mergeNamespaces({ __proto__: null, default: rollupFn }, [ rollupFn ]);

    // 3. TypeScript/Babel `__esModule: true` CJS (`ts.cjs`) under Node ESM AND Rollup `_mergeNamespaces`
    const nodeTsExports = {};
    Object.defineProperty(nodeTsExports, '__esModule', { value: true });
    nodeTsExports.named = 5;
    nodeTsExports.default = { inner: 9 };
    const nodeTsNs = Object.create(null);
    Object.defineProperties(nodeTsNs, {
      [Symbol.toStringTag]: { value: 'Module' },
      __esModule: { value: true, enumerable: true },
      named: { value: 5, enumerable: true },
      default: { value: nodeTsExports, enumerable: true },
      'module.exports': { value: nodeTsExports, enumerable: true },
    });
    Object.freeze(nodeTsNs);

    const rollupTsExports = {};
    Object.defineProperty(rollupTsExports, '__esModule', { value: true });
    rollupTsExports.named = 5;
    rollupTsExports.default = { inner: 9 };
    const rollupTsNs = mergeNamespaces({ __proto__: null, default: rollupTsExports.default }, [ rollupTsExports ]);

    env.registerJsModules({
      './facade.js': facadeNs,
      'rollup-named-no-ext': rollupNamedNs,
      'rollup-fn-no-ext': rollupFnNs,
      './ts-node.cjs': nodeTsNs,
      './ts-rollup.cjs': rollupTsNs,
    });

    const argsGetI32 = s.makeArgStruct(471n, s.i32, [ s.jsRef ]);
    const argsSetFallible = s.makeArgStruct(472n, errUnionVoid, [ s.jsRef, s.i32 ]);
    const argsDelete = s.makeArgStruct(473n, s.boolStruct, [ s.jsRef ]);
    const argsHas = s.makeArgStruct(474n, s.boolStruct, [ s.jsRef ]);
    const argsCallFn = s.makeArgStruct(475n, s.i32, [ s.jsRef, s.i32 ]);

    const enc = new TextEncoder();
    let strOff = 0x100;
    const putKey = (text) => {
      const bytes = enc.encode(text);
      const view = harness.viewAt(strOff, bytes.length);
      new Uint8Array(view.buffer, view.byteOffset, bytes.length).set(bytes);
      const out = { keyAddr: harness.addrOf(strOff), keyLen: harness.is64 ? BigInt(bytes.length) : bytes.length };
      strOff += (bytes.length + 7) & ~7;
      return out;
    };

    const kVersion = putKey('version');
    const kCounter = putKey('counter');
    const kExtra = putKey('extra');
    const kNamed = putKey('named');
    const kInner = putKey('inner');
    const kAdded = putKey('added');

    const dHasVer = writeDescriptor(harness, 0x300, { signature: 474n, op: HostOpCode.HasProp, ...kVersion, argSize: argsHas.byteSize });
    const dGetVer = writeDescriptor(harness, 0x340, { signature: 471n, op: HostOpCode.GetProp, ...kVersion, argSize: argsGetI32.byteSize });
    const dSetVer = writeDescriptor(harness, 0x380, { signature: 472n, op: HostOpCode.SetProp, ...kVersion, argSize: argsSetFallible.byteSize });
    const dDelVer = writeDescriptor(harness, 0x3c0, { signature: 473n, op: HostOpCode.DeleteProp, ...kVersion, argSize: argsDelete.byteSize });

    const dSetCounter = writeDescriptor(harness, 0x400, { signature: 472n, op: HostOpCode.SetProp, ...kCounter, argSize: argsSetFallible.byteSize });
    const dGetCounter = writeDescriptor(harness, 0x440, { signature: 471n, op: HostOpCode.GetProp, ...kCounter, argSize: argsGetI32.byteSize });
    const dDelCounter = writeDescriptor(harness, 0x480, { signature: 473n, op: HostOpCode.DeleteProp, ...kCounter, argSize: argsDelete.byteSize });
    const dHasCounter = writeDescriptor(harness, 0x4c0, { signature: 474n, op: HostOpCode.HasProp, ...kCounter, argSize: argsHas.byteSize });

    const dSetExtra = writeDescriptor(harness, 0x500, { signature: 472n, op: HostOpCode.SetProp, ...kExtra, argSize: argsSetFallible.byteSize });
    const dDelExtra = writeDescriptor(harness, 0x540, { signature: 473n, op: HostOpCode.DeleteProp, ...kExtra, argSize: argsDelete.byteSize });
    const dCallFn = writeDescriptor(harness, 0x580, { signature: 475n, op: HostOpCode.CallFn, argSize: argsCallFn.byteSize });

    const dGetNamed = writeDescriptor(harness, 0x5c0, { signature: 471n, op: HostOpCode.GetProp, ...kNamed, argSize: argsGetI32.byteSize });
    const dHasInner = writeDescriptor(harness, 0x600, { signature: 474n, op: HostOpCode.HasProp, ...kInner, argSize: argsHas.byteSize });
    const dGetInner = writeDescriptor(harness, 0x640, { signature: 471n, op: HostOpCode.GetProp, ...kInner, argSize: argsGetI32.byteSize });
    const dSetAdded = writeDescriptor(harness, 0x680, { signature: 472n, op: HostOpCode.SetProp, ...kAdded, argSize: argsSetFallible.byteSize });
    const dGetAdded = writeDescriptor(harness, 0x6c0, { signature: 471n, op: HostOpCode.GetProp, ...kAdded, argSize: argsGetI32.byteSize });
    const dDelAdded = writeDescriptor(harness, 0x700, { signature: 473n, op: HostOpCode.DeleteProp, ...kAdded, argSize: argsDelete.byteSize });

    const frameAddr = harness.addrOf(0x900);
    const frameDV = harness.viewAt(0x900, 64);

    // A. Verify ESM facade preserves `version` = 2 and rejects SetProp('version', 9) without mutating namedExports
    const hFacade = env.allocJsValue(facadeNs);
    frameDV.setUint32(argsHas.instance.members[1].bitOffset / 8, hFacade, true);
    expect(env.invokeJsHostOp(dHasVer, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(1);

    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hFacade, true);
    expect(env.invokeJsHostOp(dGetVer, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(2);

    frameDV.setUint16(0, 0, true);
    frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hFacade, true);
    frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 9, true);
    expect(env.invokeJsHostOp(dSetVer, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint16(0, true)).to.equal(1);
    expect('version' in namedExports).to.be.false;

    frameDV.setUint32(argsDelete.instance.members[1].bitOffset / 8, hFacade, true);
    expect(env.invokeJsHostOp(dDelVer, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(0);
    env.releaseJsValue(hFacade);

    // B. Verify Rollup `_mergeNamespaces` CJS unwrapping on `rollupNamedNs` and `rollupFnNs`
    const hRollupNamed = env.allocJsValue(rollupNamedNs);
    frameDV.setUint16(0, 0xffff, true);
    frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hRollupNamed, true);
    frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 42, true);
    expect(env.invokeJsHostOp(dSetCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint16(0, true)).to.equal(0);
    expect(rollupNamedExports.counter).to.equal(42);

    frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hRollupNamed, true);
    expect(env.invokeJsHostOp(dGetCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(42);

    frameDV.setUint32(argsDelete.instance.members[1].bitOffset / 8, hRollupNamed, true);
    expect(env.invokeJsHostOp(dDelCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(1);

    frameDV.setUint32(argsHas.instance.members[1].bitOffset / 8, hRollupNamed, true);
    expect(env.invokeJsHostOp(dHasCounter, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(0);
    env.releaseJsValue(hRollupNamed);

    const hRollupFn = env.allocJsValue(rollupFnNs);
    frameDV.setUint16(0, 0xffff, true);
    frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hRollupFn, true);
    frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 20, true);
    expect(env.invokeJsHostOp(dSetExtra, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint16(0, true)).to.equal(0);

    frameDV.setUint32(argsCallFn.instance.members[1].bitOffset / 8, hRollupFn, true);
    frameDV.setInt32(argsCallFn.instance.members[2].bitOffset / 8, 10, true);
    expect(env.invokeJsHostOp(dCallFn, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getInt32(0, true)).to.equal(30);

    frameDV.setUint32(argsDelete.instance.members[1].bitOffset / 8, hRollupFn, true);
    expect(env.invokeJsHostOp(dDelExtra, frameAddr)).to.equal(PosixError.NONE);
    expect(frameDV.getUint8(0)).to.equal(1);
    expect('extra' in rollupFn).to.be.false;
    env.releaseJsValue(hRollupFn);

    // C. Verify `__esModule: true` CJS parity across BOTH Node ESM (`nodeTsNs`) and Rollup (`rollupTsNs`)
    for (const [ ns, backingDefault ] of [
      [ nodeTsNs, nodeTsExports.default ],
      [ rollupTsNs, rollupTsExports.default ],
    ]) {
      const hTs = env.allocJsValue(ns);

      frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hTs, true);
      expect(env.invokeJsHostOp(dGetNamed, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getInt32(0, true)).to.equal(5);

      frameDV.setUint32(argsHas.instance.members[1].bitOffset / 8, hTs, true);
      expect(env.invokeJsHostOp(dHasInner, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getUint8(0)).to.equal(1);

      frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hTs, true);
      expect(env.invokeJsHostOp(dGetInner, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getInt32(0, true)).to.equal(9);

      frameDV.setUint16(0, 0xffff, true);
      frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hTs, true);
      frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 1, true);
      expect(env.invokeJsHostOp(dSetAdded, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getUint16(0, true)).to.equal(0);
      expect(backingDefault.added).to.equal(1);

      frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hTs, true);
      expect(env.invokeJsHostOp(dGetAdded, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getInt32(0, true)).to.equal(1);

      frameDV.setUint32(argsDelete.instance.members[1].bitOffset / 8, hTs, true);
      expect(env.invokeJsHostOp(dDelAdded, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getUint8(0)).to.equal(1);
      expect('added' in backingDefault).to.be.false;

      env.releaseJsValue(hTs);
    }

    // D. Verify CJS namespaces mutated (or having properties deleted) BEFORE module registration still unwrap to live exports
    const preMutatedBareExports = {
      counter: 1,
      bump() {
        preMutatedBareExports.counter += 1;
        return preMutatedBareExports.counter;
      },
    };
    const preMutatedBareNs = Object.create(null);
    Object.defineProperties(preMutatedBareNs, {
      [Symbol.toStringTag]: { value: 'Module' },
      counter: { value: 1, writable: false, enumerable: true, configurable: false },
      bump: { value: preMutatedBareExports.bump, writable: false, enumerable: true, configurable: false },
      default: { value: preMutatedBareExports, writable: false, enumerable: true, configurable: false },
      'module.exports': { value: preMutatedBareExports, writable: false, enumerable: true, configurable: false },
    });
    Object.freeze(preMutatedBareNs);
    // Mutate live CJS exports BEFORE registering with Zigar (`counter` is 2 while snapshot `ns.counter` is still 1)
    expect(preMutatedBareExports.bump()).to.equal(2);
    expect(preMutatedBareNs.counter).to.equal(1);

    const preMutatedExplicitCjsExports = {
      counter: 1,
      removedBeforeLoad: 99,
      bump() {
        preMutatedExplicitCjsExports.counter += 1;
        return preMutatedExplicitCjsExports.counter;
      },
    };
    const preMutatedExplicitCjsNs = Object.create(null);
    Object.defineProperties(preMutatedExplicitCjsNs, {
      [Symbol.toStringTag]: { value: 'Module' },
      counter: { value: 1, writable: false, enumerable: true, configurable: false },
      removedBeforeLoad: { value: 99, writable: false, enumerable: true, configurable: false },
      bump: { value: preMutatedExplicitCjsExports.bump, writable: false, enumerable: true, configurable: false },
      default: { value: preMutatedExplicitCjsExports, writable: false, enumerable: true, configurable: false },
      'module.exports': { value: preMutatedExplicitCjsExports, writable: false, enumerable: true, configurable: false },
    });
    Object.freeze(preMutatedExplicitCjsNs);
    // Both mutate `counter` AND delete `removedBeforeLoad` before registering `.cjs`
    expect(preMutatedExplicitCjsExports.bump()).to.equal(2);
    delete preMutatedExplicitCjsExports.removedBeforeLoad;

    env.registerJsModules({
      'pkg-pre-mutated-cjs': preMutatedBareNs,
      './pre-mutated-named.cjs': preMutatedExplicitCjsNs,
    });

    for (const [ ns, backingExports ] of [
      [ preMutatedBareNs, preMutatedBareExports ],
      [ preMutatedExplicitCjsNs, preMutatedExplicitCjsExports ],
    ]) {
      const hPre = env.allocJsValue(ns);

      // GetProp('counter') reads live 2, NOT stale snapshot 1
      frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hPre, true);
      expect(env.invokeJsHostOp(dGetCounter, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getInt32(0, true)).to.equal(2);

      // SetProp('counter', 42) mutates live exports without throwing TypeError on frozen namespace
      frameDV.setUint16(0, 0xffff, true);
      frameDV.setUint32(argsSetFallible.instance.members[1].bitOffset / 8, hPre, true);
      frameDV.setInt32(argsSetFallible.instance.members[2].bitOffset / 8, 42, true);
      expect(env.invokeJsHostOp(dSetCounter, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getUint16(0, true)).to.equal(0);
      expect(backingExports.counter).to.equal(42);

      frameDV.setUint32(argsGetI32.instance.members[1].bitOffset / 8, hPre, true);
      expect(env.invokeJsHostOp(dGetCounter, frameAddr)).to.equal(PosixError.NONE);
      expect(frameDV.getInt32(0, true)).to.equal(42);

      env.releaseJsValue(hPre);
    }

    expect(env.getJsValueCount()).to.equal(0);
  });
});
