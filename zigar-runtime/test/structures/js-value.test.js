import { expect } from 'chai';
import {
  ArgStructFlag,
  MemberFlag,
  MemberType,
  OptionalFlag,
  StructFlag,
  StructureFlag,
  StructurePurpose,
  StructureType,
  UnionFlag,
} from '../../src/constants.js';
import { defineEnvironment } from '../../src/environment.js';
import { NotInErrorSet, UndefinedArgument } from '../../src/errors.js';
import '../../src/mixins.js';
import { MEMORY, READ_ONLY, RETURN, SLOTS, ZIG } from '../../src/symbols.js';

const Env = defineEnvironment();

function defineBasicTypes(env) {
  const u32 = {
    type: StructureType.Primitive,
    name: 'u32',
    byteSize: 4,
    align: 4,
    flags: StructureFlag.HasValue,
    signature: 1n,
    instance: {
      members: [],
    },
    static: {},
  };
  u32.instance.members.push({ type: MemberType.Uint, bitSize: 32, bitOffset: 0, byteSize: 4, structure: u32 });
  env.beginStructure(u32);
  env.finishStructure(u32);

  const boolStruct = {
    type: StructureType.Primitive,
    name: 'bool',
    byteSize: 1,
    align: 1,
    flags: StructureFlag.HasValue,
    signature: 2n,
    instance: {
      members: [],
    },
    static: {},
  };
  boolStruct.instance.members.push({ type: MemberType.Bool, bitSize: 1, bitOffset: 0, byteSize: 1, structure: boolStruct });
  env.beginStructure(boolStruct);
  env.finishStructure(boolStruct);

  const jsRef = {
    type: StructureType.Struct,
    purpose: StructurePurpose.JsValue,
    name: 'Ref',
    byteSize: 4,
    align: 4,
    flags: StructureFlag.HasValue | StructFlag.IsExtern,
    signature: 3n,
    instance: {
      members: [
        { name: 'handle', type: MemberType.Uint, bitSize: 32, bitOffset: 0, byteSize: 4, structure: u32 },
      ],
    },
    static: {},
  };
  env.beginStructure(jsRef);
  env.finishStructure(jsRef);
  return { u32, boolStruct, jsRef };
}

function createZigBufferSetup(env) {
  if (process.env.TARGET === 'wasm') {
    env.memory = new WebAssembly.Memory({ initial: 1 });
    return (offset, len) => env.obtainZigView(offset, len);
  } else {
    return (offset, len) => {
      const buf = new ArrayBuffer(len);
      buf[ZIG] = { address: process.env.BITS === '64' ? BigInt(offset) : offset, len };
      return env.obtainView(buf, 0, len);
    };
  }
}

describe('Structure: js-value', function() {
  it('should wrap and unwrap JS values in JS memory without allocating registry slots', function() {
    const env = new Env();
    const { jsRef } = defineBasicTypes(env);
    const Ref = jsRef.constructor;

    const target = { name: 'live-js-object' };
    const replacement = { name: 'replacement-object' };
    const fn = function greet() { return 'hi'; };

    const refObj = new Ref(target);
    expect(refObj.$).to.equal(target);
    expect(refObj.valueOf()).to.equal(target);
    expect(JSON.stringify(refObj)).to.equal(JSON.stringify(target));
    expect(refObj.handle).to.equal(0);
    expect(env.getJsValueCount()).to.equal(0);

    // Reassigning a JS-memory Ref updates [TARGET] without leaking slots
    refObj.$ = replacement;
    expect(refObj.$).to.equal(replacement);
    expect(env.getJsValueCount()).to.equal(0);
    refObj.$ = target;

    const refFn = new Ref(fn);
    expect(refFn.$).to.equal(fn);
    expect(refFn.valueOf()).to.equal(fn);
    expect(env.getJsValueCount()).to.equal(0);

    const refUndef = new Ref(undefined);
    expect(refUndef.$).to.be.undefined;
    expect(refUndef.handle).to.equal(0);
    expect(env.getJsValueCount()).to.equal(0);

    // Initializing from another Ref instance copies the JS value with zero table allocations
    const refCopy = new Ref(refObj);
    expect(refCopy.$).to.equal(target);
    expect(env.getJsValueCount()).to.equal(0);

    refCopy[READ_ONLY] = true;
    expect(() => { refCopy.$ = target; }).to.throw(TypeError);
  });

  it('should keep JS-memory composites handle-free and resolve borrowed Zig composite handles on copy', function() {
    const env = new Env();
    const { u32, boolStruct, jsRef } = defineBasicTypes(env);

    const pairStruct = {
      type: StructureType.Struct,
      name: 'Pair',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | StructFlag.IsExtern,
      signature: 10n,
      instance: {
        members: [
          { name: 'a', type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef, flags: MemberFlag.IsRequired },
          { name: 'b', type: MemberType.Object, bitSize: 32, bitOffset: 32, byteSize: 4, slot: 1, structure: jsRef, flags: MemberFlag.IsRequired },
        ],
      },
      static: {},
    };
    env.beginStructure(pairStruct);
    env.finishStructure(pairStruct);

    const optStruct = {
      type: StructureType.Optional,
      name: '?Ref',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasValue | StructureFlag.HasObject | StructureFlag.HasSlot | OptionalFlag.HasSelector,
      signature: 11n,
      instance: {
        members: [
          { type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { type: MemberType.Bool, bitSize: 1, bitOffset: 32, byteSize: 1, structure: boolStruct },
        ],
      },
      static: {},
    };
    env.beginStructure(optStruct);
    env.finishStructure(optStruct);

    const errSet = {
      type: StructureType.ErrorSet,
      name: 'ErrSet',
      byteSize: 2,
      align: 2,
      flags: StructureFlag.HasValue,
      signature: 12n,
      instance: {
        members: [],
      },
      static: {},
    };
    errSet.instance.members.push({ type: MemberType.Uint, bitSize: 16, bitOffset: 0, byteSize: 2, structure: errSet });
    env.beginStructure(errSet);
    const failDV = new DataView(new Uint16Array([ 1 ]).buffer);
    errSet.static = {
      members: [
        { name: 'Fail', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 0, structure: errSet },
      ],
      template: { [SLOTS]: { 0: env.createInstance(errSet, failDV) } },
    };
    env.finishStructure(errSet);

    const euStruct = {
      type: StructureType.ErrorUnion,
      name: 'ErrSet!Ref',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasValue | StructureFlag.HasObject | StructureFlag.HasSlot,
      signature: 13n,
      instance: {
        members: [
          { type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 32, byteSize: 2, structure: errSet },
        ],
      },
      static: {},
    };
    env.beginStructure(euStruct);
    env.finishStructure(euStruct);

    const arrStruct = {
      type: StructureType.Array,
      name: '[2]Ref',
      length: 2,
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | StructureFlag.HasProxy,
      signature: 14n,
      instance: {
        members: [ { type: MemberType.Object, bitSize: 32, byteSize: 4, structure: jsRef } ],
      },
      static: {},
    };
    env.beginStructure(arrStruct);
    env.finishStructure(arrStruct);

    const tagEnum = {
      type: StructureType.Enum,
      name: 'Tag',
      byteSize: 1,
      align: 1,
      flags: StructureFlag.HasValue,
      signature: 15n,
      instance: {
        members: [],
      },
      static: {},
    };
    tagEnum.instance.members.push({ type: MemberType.Uint, bitSize: 8, bitOffset: 0, byteSize: 1, structure: tagEnum });
    env.beginStructure(tagEnum);
    const tagJsDV = new DataView(new Uint8Array([ 0 ]).buffer);
    const tagNumDV = new DataView(new Uint8Array([ 1 ]).buffer);
    tagEnum.static = {
      members: [
        { name: 'js', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 0, structure: tagEnum },
        { name: 'num', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 1, structure: tagEnum },
      ],
      template: {
        [SLOTS]: {
          0: env.createInstance(tagEnum, tagJsDV),
          1: env.createInstance(tagEnum, tagNumDV),
        },
      },
    };
    env.finishStructure(tagEnum);

    const unionStruct = {
      type: StructureType.Union,
      name: 'Tagged',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | UnionFlag.HasSelector | UnionFlag.HasTag,
      signature: 16n,
      instance: {
        members: [
          { name: 'js', type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { name: 'num', type: MemberType.Uint, bitSize: 32, bitOffset: 0, byteSize: 4, structure: u32 },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 8, bitOffset: 32, byteSize: 1, structure: tagEnum },
        ],
      },
      static: {},
    };
    env.beginStructure(unionStruct);
    env.finishStructure(unionStruct);

    const objA = { k: 'a' };
    const objB = { k: 'b' };
    const objC = { k: 'c' };

    // Standalone JS-memory composites and reassignments allocate zero handles
    const Pair = pairStruct.constructor;
    const p1 = new Pair({ a: objA, b: objB });
    expect(p1.a).to.equal(objA);
    expect(p1.b).to.equal(objB);
    expect(p1.valueOf()).to.eql({ a: objA, b: objB });
    p1.a = objC;
    expect(p1.a).to.equal(objC);
    p1.a = objA;
    const p2 = new Pair(p1);
    expect(p2.a).to.equal(objA);
    expect(p2.b).to.equal(objB);
    expect(env.getJsValueCount()).to.equal(0);

    const Opt = optStruct.constructor;
    const o1 = new Opt(objA);
    const o2 = new Opt(o1);
    expect(o2.$).to.equal(objA);
    const oNull = new Opt(null);
    const oNull2 = new Opt(oNull);
    expect(oNull2.$).to.be.null;
    expect(env.getJsValueCount()).to.equal(0);

    const EU = euStruct.constructor;
    const euUndef = new EU(undefined);
    expect(euUndef.$).to.be.undefined;
    const euVal = new EU(objB);
    const euVal2 = new EU(euVal);
    expect(euVal2.$).to.equal(objB);
    expect(env.getJsValueCount()).to.equal(0);

    const Arr = arrStruct.constructor;
    const arr1 = new Arr([ objA, objB ]);
    const arr2 = new Arr(arr1);
    expect(arr2[0]).to.equal(objA);
    expect(arr2[1]).to.equal(objB);
    expect(env.getJsValueCount()).to.equal(0);

    const Tagged = unionStruct.constructor;
    const u1 = new Tagged({ js: objA });
    const u2 = new Tagged(u1);
    expect(u2.js).to.equal(objA);
    expect(env.getJsValueCount()).to.equal(0);

    // Simulate Zig-memory composites carrying borrowed handles passed to JS callbacks:
    // copying into JS memory via `new Ctor(zigInst)` must eagerly resolve [TARGET]
    // so JS copies remain valid after Zig releases its borrowed handles!
    const allocZigDV = createZigBufferSetup(env);
    const hA = env.allocJsValue(objA);
    const hB = env.allocJsValue(objB);
    expect(env.getJsValueCount()).to.equal(2);

    const zigPairDV = allocZigDV(0x1000, 8);
    zigPairDV.setUint32(0, hA, env.littleEndian);
    zigPairDV.setUint32(4, hB, env.littleEndian);
    const zigPair = Pair(zigPairDV);
    const savedPair = new Pair(zigPair);
    expect(env.getJsValueCount()).to.equal(2);

    const zigArrDV = allocZigDV(0x1010, 8);
    zigArrDV.setUint32(0, hA, env.littleEndian);
    zigArrDV.setUint32(4, hB, env.littleEndian);
    const zigArr = Arr(zigArrDV);
    const savedArr = new Arr(zigArr);

    const zigOptDV = allocZigDV(0x1020, 8);
    zigOptDV.setUint32(0, hA, env.littleEndian);
    zigOptDV.setUint8(4, 1);
    const zigOpt = Opt(zigOptDV);
    const savedOpt = new Opt(zigOpt);

    const zigTaggedDV = allocZigDV(0x1030, 8);
    zigTaggedDV.setUint32(0, hB, env.littleEndian);
    zigTaggedDV.setUint8(4, 0);
    const zigTagged = Tagged(zigTaggedDV);
    const savedTagged = new Tagged(zigTagged);
    expect(env.getJsValueCount()).to.equal(2);

    // Zig runs `defer deinit()` on its borrowed handles and slots are reused >4096 times
    env.releaseJsValue(hA);
    env.releaseJsValue(hB);
    expect(env.getJsValueCount()).to.equal(0);
    for (let i = 0; i < 4100; i++) {
      const temp = env.allocJsValue({ unrelated: i });
      env.releaseJsValue(temp);
    }
    expect(env.getJsValueCount()).to.equal(0);

    // Retained JS copies still hold exact original JS objects without throwing or aliasing!
    expect(savedPair.a).to.equal(objA);
    expect(savedPair.b).to.equal(objB);
    expect(savedArr[0]).to.equal(objA);
    expect(savedArr[1]).to.equal(objB);
    expect(savedOpt.$).to.equal(objA);
    expect(savedTagged.js).to.equal(objB);

    // Mutating Zig-memory variables (`pub var`) directly from JS releases replaced handles cleanly
    const pubVarPairDV = allocZigDV(0x1040, 8);
    const pubVarPair = Pair(pubVarPairDV);
    pubVarPair.a = objA;
    pubVarPair.b = objB;
    expect(env.getJsValueCount()).to.equal(2);
    pubVarPair.a = objC;
    expect(env.getJsValueCount()).to.equal(2);
    expect(pubVarPair.a).to.equal(objC);
    pubVarPair.a = null;
    pubVarPair.b = undefined;
    expect(env.getJsValueCount()).to.equal(0);

    // Switching Zig-memory tagged union between integer and Ref neither collides nor leaks
    const pubVarTaggedDV = allocZigDV(0x1050, 8);
    pubVarTaggedDV.setUint8(4, 1); // active = .num
    const pubVarTagged = Tagged(pubVarTaggedDV);
    const otherHandle = env.allocJsValue(objA);
    pubVarTagged.$ = { num: otherHandle };
    expect(pubVarTagged.num).to.equal(otherHandle);
    pubVarTagged.$ = { js: objB };
    expect(env.getJsValueCount()).to.equal(2);
    expect(env.getJsValue(otherHandle)).to.equal(objA);
    pubVarTagged.$ = { num: 99 };
    expect(env.getJsValueCount()).to.equal(1);
    env.releaseJsValue(otherHandle);
    expect(env.getJsValueCount()).to.equal(0);

    // Consume retval slot on a synthetic ArgStruct holding Pair
    const argStructDef = {
      type: StructureType.ArgStruct,
      name: 'Args',
      byteSize: 8,
      align: 4,
      length: 0,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot,
      signature: 17n,
      instance: {
        members: [
          { name: 'retval', type: MemberType.Object, bitSize: 64, bitOffset: 0, byteSize: 8, slot: 0, structure: pairStruct },
        ],
      },
      static: {},
    };
    env.beginStructure(argStructDef);
    env.finishStructure(argStructDef);
    const Args = argStructDef.constructor;
    const argsInst = new Args([]);
    argsInst[RETURN](p2);
    expect(env.getJsValueCount()).to.equal(2);
    env.consumeJsValueRetval(argsInst);
    expect(env.getJsValueCount()).to.equal(0);
    expect(argsInst.retval.a).to.equal(objA);
    expect(argsInst.retval.b).to.equal(objB);
  });

  it('should map thrown Error on E!Ref(T) to Zig errors and roll back failed retval handles', function() {
    const env = new Env();
    const { u32, boolStruct, jsRef } = defineBasicTypes(env);
    const Ref = jsRef.constructor;

    const strictErrSet = {
      type: StructureType.ErrorSet,
      name: 'StrictErr',
      byteSize: 2,
      align: 2,
      flags: StructureFlag.HasValue,
      signature: 30n,
      instance: { members: [] },
      static: {},
    };
    strictErrSet.instance.members.push({ type: MemberType.Uint, bitSize: 16, bitOffset: 0, byteSize: 2, structure: strictErrSet });
    env.beginStructure(strictErrSet);
    strictErrSet.static = {
      members: [
        { name: 'Fail', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 0, structure: strictErrSet },
      ],
      template: { [SLOTS]: { 0: env.createInstance(strictErrSet, new DataView(new Uint16Array([ 1 ]).buffer)) } },
    };
    env.finishStructure(strictErrSet);

    const anyErrSet = {
      type: StructureType.ErrorSet,
      name: 'AnyErr',
      byteSize: 2,
      align: 2,
      flags: StructureFlag.HasValue,
      signature: 31n,
      instance: { members: [] },
      static: {},
    };
    anyErrSet.instance.members.push({ type: MemberType.Uint, bitSize: 16, bitOffset: 0, byteSize: 2, structure: anyErrSet });
    env.beginStructure(anyErrSet);
    anyErrSet.static = {
      members: [
        { name: 'Fail', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 0, structure: anyErrSet },
        { name: 'Unexpected', type: MemberType.Object, flags: MemberFlag.IsPartOfSet, slot: 1, structure: anyErrSet },
      ],
      template: {
        [SLOTS]: {
          0: env.createInstance(anyErrSet, new DataView(new Uint16Array([ 1 ]).buffer)),
          1: env.createInstance(anyErrSet, new DataView(new Uint16Array([ 2 ]).buffer)),
        },
      },
    };
    env.finishStructure(anyErrSet);

    const optRefStruct = {
      type: StructureType.Optional,
      name: '?Ref',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasValue | StructureFlag.HasObject | StructureFlag.HasSlot | OptionalFlag.HasSelector,
      signature: 32n,
      instance: {
        members: [
          { type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { type: MemberType.Bool, bitSize: 1, bitOffset: 32, byteSize: 1, structure: boolStruct },
        ],
      },
      static: {},
    };
    env.beginStructure(optRefStruct);
    env.finishStructure(optRefStruct);

    const strictEU = {
      type: StructureType.ErrorUnion,
      name: 'StrictErr!Ref',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasValue | StructureFlag.HasObject | StructureFlag.HasSlot,
      signature: 33n,
      instance: {
        members: [
          { type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 32, byteSize: 2, structure: strictErrSet },
        ],
      },
      static: {},
    };
    env.beginStructure(strictEU);
    env.finishStructure(strictEU);

    const anyOptEU = {
      type: StructureType.ErrorUnion,
      name: 'AnyErr!?Ref',
      byteSize: 12,
      align: 4,
      flags: StructureFlag.HasValue | StructureFlag.HasObject | StructureFlag.HasSlot,
      signature: 34n,
      instance: {
        members: [
          { type: MemberType.Object, bitSize: 64, bitOffset: 0, byteSize: 8, slot: 0, structure: optRefStruct },
          { type: MemberType.Uint, flags: MemberFlag.IsSelector, bitSize: 16, bitOffset: 64, byteSize: 2, structure: anyErrSet },
        ],
      },
      static: {},
    };
    env.beginStructure(anyOptEU);
    env.finishStructure(anyOptEU);

    const StrictErr = strictErrSet.constructor;
    const AnyErr = anyErrSet.constructor;
    const StrictEU = strictEU.constructor;
    const AnyOptEU = anyOptEU.constructor;

    // Matching JS Error maps to StrictErr.Fail (NOT a Ref(Error) success!)
    const euFail = new StrictEU(new Error('Fail'));
    expect(() => euFail.$).to.throw(StrictErr.Fail);
    expect(env.getJsValueCount()).to.equal(0);

    // JSON error object maps to StrictErr.Fail
    const euJsonFail = new StrictEU({ error: 'Fail' });
    expect(() => euJsonFail.$).to.throw(StrictErr.Fail);
    expect(env.getJsValueCount()).to.equal(0);

    // Unmatched TypeError on strict error set throws NotInErrorSet with 0 leaked handles
    expect(() => new StrictEU(new TypeError('boom'))).to.throw(NotInErrorSet);
    expect(env.getJsValueCount()).to.equal(0);

    // Unmatched TypeError on error set containing Unexpected maps to AnyErr.Unexpected (including E!?Ref)
    const euUnexpected = new AnyOptEU(new TypeError('boom'));
    expect(() => euUnexpected.$).to.throw(AnyErr.Unexpected);
    expect(env.getJsValueCount()).to.equal(0);

    // Explicit `new Ref(err)` still allows returning an Error object as a success value
    const explicitErr = new TypeError('carried-as-value');
    const euCarried = new StrictEU(new Ref(explicitErr));
    expect(euCarried.$).to.equal(explicitErr);
    expect(env.getJsValueCount()).to.equal(0);

    // Composite retval rollback + uninitialized 0xaaaaaaaa Zig stack safety on argStruct[RETURN]
    const mixedStruct = {
      type: StructureType.Struct,
      name: 'RefAndUint',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | StructFlag.IsExtern,
      signature: 35n,
      instance: {
        members: [
          { name: 'ref', type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef, flags: MemberFlag.IsRequired },
          { name: 'num', type: MemberType.Uint, bitSize: 32, bitOffset: 32, byteSize: 4, structure: u32, flags: MemberFlag.IsRequired },
        ],
      },
      static: {},
    };
    env.beginStructure(mixedStruct);
    env.finishStructure(mixedStruct);

    const cbArgStruct = {
      type: StructureType.ArgStruct,
      name: 'CbArgs',
      byteSize: 8,
      align: 4,
      length: 0,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | ArgStructFlag.IsThrowing,
      signature: 36n,
      instance: {
        members: [
          { name: 'retval', type: MemberType.Object, bitSize: 64, bitOffset: 0, byteSize: 8, slot: 0, structure: mixedStruct },
        ],
      },
      static: {},
    };
    env.beginStructure(cbArgStruct);
    env.finishStructure(cbArgStruct);
    const CbArgs = cbArgStruct.constructor;

    // Fill Zig stack ArgStruct memory with 0xaa (Debug uninitialized memory)
    const allocZigDV = createZigBufferSetup(env);
    const zigStackDV = allocZigDV(0x2000, 8);
    new Uint8Array(zigStackDV.buffer, zigStackDV.byteOffset, 8).fill(0xaa);
    const cbArgs = CbArgs(zigStackDV);

    // Partial failure (ref succeeds, num throws TypeError) rolls back ref's handle!
    expect(() => cbArgs[RETURN]({ ref: { partial: true }, num: 'not-a-uint' })).to.throw(Error);
    expect(env.getJsValueCount()).to.equal(0);

    // Valid return writes into 0xaa stack memory without attempting to release 0xaaaaaaaa
    const okPayload = { ok: true };
    cbArgs[RETURN]({ ref: okPayload, num: 42 });
    expect(env.getJsValueCount()).to.equal(1);
    expect(cbArgs.retval.ref).to.equal(okPayload);
    expect(cbArgs.retval.num).to.equal(42);
    env.consumeJsValueRetval(cbArgs);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should allow undefined for JsValue args and roll back handles if a later argument fails', function() {
    const env = new Env();
    const { u32, jsRef } = defineBasicTypes(env);

    const argStructDef = {
      type: StructureType.ArgStruct,
      name: 'FnArgs',
      byteSize: 12,
      align: 4,
      length: 2,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | ArgStructFlag.HasOptions,
      signature: 20n,
      instance: {
        members: [
          { name: 'retval', type: MemberType.Void, bitSize: 0, bitOffset: 0, byteSize: 0, structure: u32 },
          { name: '0', type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { name: '1', type: MemberType.Uint, bitSize: 32, bitOffset: 32, byteSize: 4, structure: u32 },
        ],
      },
      static: {},
    };
    env.beginStructure(argStructDef);
    env.finishStructure(argStructDef);
    const FnArgs = argStructDef.constructor;

    // Passing undefined for JsValue succeeds with handle 0
    const okArgs = new FnArgs([ undefined, 7 ]);
    expect(okArgs[0]).to.be.undefined;
    expect(okArgs[1]).to.equal(7);
    expect(env.getJsValueCount()).to.equal(0);

    // Passing undefined for u32 still throws UndefinedArgument and rolls back arg 0's handle!
    const liveObj = { rollback: true };
    expect(() => new FnArgs([ liveObj, undefined ])).to.throw(UndefinedArgument);
    expect(env.getJsValueCount()).to.equal(0);

    // Passing invalid type for u32 also rolls back arg 0's handle!
    expect(() => new FnArgs([ liveObj, 'not-a-u32' ])).to.throw(Error);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should safely overwrite uninitialized 0xaaaaaaaa Zig globals, ABA stale slots, and Zig-written handles', function() {
    const env = new Env();
    const { u32, jsRef } = defineBasicTypes(env);
    const Ref = jsRef.constructor;

    const pairStruct = {
      type: StructureType.Struct,
      name: 'Pair',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | StructFlag.IsExtern,
      signature: 40n,
      instance: {
        members: [
          { name: 'first', type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { name: 'second', type: MemberType.Object, bitSize: 32, bitOffset: 32, byteSize: 4, slot: 1, structure: jsRef },
        ],
      },
      static: {},
    };
    env.beginStructure(pairStruct);
    env.finishStructure(pairStruct);
    const Pair = pairStruct.constructor;

    const allocZigDV = createZigBufferSetup(env);

    // Uninitialized `pub var uninit_ref: Ref(Any) = undefined;` filled with 0xaa (0xaaaaaaaa)
    const uninitRefDV = allocZigDV(0x3000, 4);
    new Uint8Array(uninitRefDV.buffer, uninitRefDV.byteOffset, 4).fill(0xaa);
    const uninitRef = Ref(uninitRefDV);

    const obj1 = { x: 1 };
    const obj2 = { x: 2 };
    uninitRef.$ = obj1;
    expect(uninitRef.$).to.equal(obj1);
    expect(env.getJsValueCount()).to.equal(1);

    uninitRef.$ = obj2;
    expect(uninitRef.$).to.equal(obj2);
    expect(env.getJsValueCount()).to.equal(1);

    uninitRef.$ = undefined;
    expect(uninitRef.$).to.be.undefined;
    expect(env.getJsValueCount()).to.equal(0);

    // Zig-written handle in Zig memory is cleanly released when JS overwrites it!
    const zigWrittenDV = allocZigDV(0x3008, 4);
    const zigHandle = env.allocJsValue(obj1);
    zigWrittenDV.setUint32(0, zigHandle, env.littleEndian);
    expect(env.getJsValueCount()).to.equal(1);
    const zigWrittenRef = Ref(zigWrittenDV);
    zigWrittenRef.$ = obj2;
    expect(zigWrittenRef.$).to.equal(obj2);
    expect(env.getJsValueCount()).to.equal(1);
    zigWrittenRef.$ = undefined;
    expect(env.getJsValueCount()).to.equal(0);

    // ABA safety: stale handle left in Zig memory after Zig deinit (whose slot index was
    // reused by another owner with generation + 1) must NOT release the new owner's handle!
    const staleDV = allocZigDV(0x3010, 4);
    const oldHandle = env.allocJsValue({ doomed: true });
    staleDV.setUint32(0, oldHandle, env.littleEndian);
    env.releaseJsValue(oldHandle);
    const innocentObj = { keepAlive: true };
    const reusedSlotHandle = env.allocJsValue(innocentObj);
    expect(reusedSlotHandle & 0xFFFFF).to.equal(oldHandle & 0xFFFFF);
    expect(reusedSlotHandle).to.not.equal(oldHandle);

    const staleRef = Ref(staleDV);
    staleRef.$ = obj1;
    expect(env.getJsValueCount()).to.equal(2);
    expect(env.getJsValue(reusedSlotHandle)).to.equal(innocentObj);
    expect(staleRef.$).to.equal(obj1);

    staleRef.$ = undefined;
    expect(env.getJsValueCount()).to.equal(1);
    expect(env.getJsValue(reusedSlotHandle)).to.equal(innocentObj);
    env.releaseJsValue(reusedSlotHandle);
    expect(env.getJsValueCount()).to.equal(0);

    // Uninitialized `Pair` filled with 0xaa overwritten from JS
    const uninitPairDV = allocZigDV(0x3020, 8);
    new Uint8Array(uninitPairDV.buffer, uninitPairDV.byteOffset, 8).fill(0xaa);
    const uninitPair = Pair(uninitPairDV);
    uninitPair.$ = { first: obj1, second: obj2 };
    expect(env.getJsValueCount()).to.equal(2);
    expect(uninitPair.first).to.equal(obj1);
    expect(uninitPair.second).to.equal(obj2);
    uninitPair.$ = { first: undefined, second: null };
    expect(env.getJsValueCount()).to.equal(0);

    // Suppress unused variable lint if needed
    expect(u32.byteSize).to.equal(4);
  });

  it('should materialize call-scoped borrowed handles for pointer/slice targets and sync mutations back', function() {
    const env = new Env();
    const { u32, jsRef } = defineBasicTypes(env);

    const pairStruct = {
      type: StructureType.Struct,
      name: 'Pair',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | StructFlag.IsExtern,
      signature: 50n,
      instance: {
        members: [
          { name: 'first', type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { name: 'second', type: MemberType.Object, bitSize: 32, bitOffset: 32, byteSize: 4, slot: 1, structure: jsRef },
        ],
      },
      static: {},
    };
    env.beginStructure(pairStruct);
    env.finishStructure(pairStruct);
    const Pair = pairStruct.constructor;

    const mixedStruct = {
      type: StructureType.Struct,
      name: 'Mixed',
      byteSize: 8,
      align: 4,
      flags: StructureFlag.HasObject | StructureFlag.HasSlot | StructFlag.IsExtern,
      signature: 51n,
      instance: {
        members: [
          { name: 'ref', type: MemberType.Object, bitSize: 32, bitOffset: 0, byteSize: 4, slot: 0, structure: jsRef },
          { name: 'num', type: MemberType.Uint, bitSize: 32, bitOffset: 32, byteSize: 4, structure: u32 },
        ],
      },
      static: {},
    };
    env.beginStructure(mixedStruct);
    env.finishStructure(mixedStruct);
    const Mixed = mixedStruct.constructor;

    const a = { a: 1 };
    const b = { b: 2 };
    const c = { c: 3 };

    // Writable `*Pair`: Zig deinits `first` and writes `c`'s handle
    const pair = new Pair({ first: a, second: b });
    expect(env.getJsValueCount()).to.equal(0);
    const ctx1 = {};
    env.prepareJsValueTarget(ctx1, pair, pairStruct, true);
    expect(env.getJsValueCount()).to.equal(2);
    const preFirst = pair[MEMORY].getUint32(0, env.littleEndian);
    env.releaseJsValue(preFirst);
    const newHandle = env.allocJsValue(c);
    pair[MEMORY].setUint32(0, newHandle, env.littleEndian);
    env.finalizeJsValueTargets(ctx1);
    expect(pair.first).to.equal(c);
    expect(pair.second).to.equal(b);
    expect(env.getJsValueCount()).to.equal(0);

    // Writable `*Pair` in-place swap (`p.first <-> p.second`) must read both before releasing!
    const ctxSwap = {};
    env.prepareJsValueTarget(ctxSwap, pair, pairStruct, true);
    const h0 = pair[MEMORY].getUint32(0, env.littleEndian);
    const h1 = pair[MEMORY].getUint32(4, env.littleEndian);
    pair[MEMORY].setUint32(0, h1, env.littleEndian);
    pair[MEMORY].setUint32(4, h0, env.littleEndian);
    env.finalizeJsValueTargets(ctxSwap);
    expect(pair.first).to.equal(b);
    expect(pair.second).to.equal(c);
    expect(env.getJsValueCount()).to.equal(0);

    // Writable `*Mixed`: Zig mutates `num = 42` without touching `ref`
    const mixed = new Mixed({ ref: a, num: 1 });
    const ctxMixed = {};
    env.prepareJsValueTarget(ctxMixed, mixed, mixedStruct, true);
    expect(env.getJsValueCount()).to.equal(1);
    mixed[MEMORY].setUint32(4, 42, env.littleEndian);
    env.finalizeJsValueTargets(ctxMixed);
    expect(mixed.ref).to.equal(a);
    expect(mixed.num).to.equal(42);
    expect(env.getJsValueCount()).to.equal(0);

    // Const `*const Pair`: borrowed handles released cleanly
    const ctxConst = {};
    env.prepareJsValueTarget(ctxConst, pair, pairStruct, false);
    expect(env.getJsValueCount()).to.equal(2);
    env.finalizeJsValueTargets(ctxConst);
    expect(pair.first).to.equal(b);
    expect(pair.second).to.equal(c);
    expect(env.getJsValueCount()).to.equal(0);
  });
});
