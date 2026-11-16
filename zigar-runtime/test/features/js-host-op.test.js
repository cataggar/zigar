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
});
