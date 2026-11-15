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
import { UndefinedArgument } from '../../src/errors.js';
import '../../src/mixins.js';
import { MEMORY, READ_ONLY, SLOTS } from '../../src/symbols.js';

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

describe('Structure: js-value', function() {
  it('should wrap and unwrap JS values via StructurePurpose.JsValue', function() {
    const env = new Env();
    const { jsRef } = defineBasicTypes(env);
    const Ref = jsRef.constructor;

    const target = { name: 'live-js-object' };
    const fn = function greet() { return 'hi'; };

    const refObj = new Ref(target);
    expect(refObj.$).to.equal(target);
    expect(refObj.valueOf()).to.equal(target);
    expect(JSON.stringify(refObj)).to.equal(JSON.stringify(target));
    expect(refObj.handle & 0x000FFFFF).to.equal(8);
    expect(env.getJsValueCount()).to.equal(1);

    const refFn = new Ref(fn);
    expect(refFn.$).to.equal(fn);
    expect(refFn.valueOf()).to.equal(fn);
    expect(env.getJsValueCount()).to.equal(2);

    const refUndef = new Ref(undefined);
    expect(refUndef.$).to.be.undefined;
    expect(refUndef.handle).to.equal(0);
    expect(env.getJsValueCount()).to.equal(2);

    // Initializing from another Ref instance allocates an independent owned handle
    const refCopy = new Ref(refObj);
    expect(refCopy.$).to.equal(target);
    expect(refCopy.handle).to.not.equal(refObj.handle);
    expect(env.getJsValueCount()).to.equal(3);

    refCopy[READ_ONLY] = true;
    expect(() => { refCopy.$ = target; }).to.throw(TypeError);
  });

  it('should copy JS-side composite structs, optionals, error unions, arrays, and unions without handle aliasing', function() {
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

    const Pair = pairStruct.constructor;
    const p1 = new Pair({ a: objA, b: objB });
    expect(p1.a).to.equal(objA);
    expect(p1.b).to.equal(objB);
    expect(p1.valueOf()).to.eql({ a: objA, b: objB });
    expect(env.getJsValueCount()).to.equal(2);
    const p2 = new Pair(p1);
    expect(p2.a).to.equal(objA);
    expect(p2.b).to.equal(objB);
    expect(env.getJsValueCount()).to.equal(4);

    const Opt = optStruct.constructor;
    const o1 = new Opt(objA);
    const o2 = new Opt(o1);
    expect(o2.$).to.equal(objA);
    expect(env.getJsValueCount()).to.equal(6);
    const oNull = new Opt(null);
    const oNull2 = new Opt(oNull);
    expect(oNull2.$).to.be.null;
    expect(env.getJsValueCount()).to.equal(6);

    const EU = euStruct.constructor;
    const euUndef = new EU(undefined);
    expect(euUndef.$).to.be.undefined;
    expect(env.getJsValueCount()).to.equal(6);
    const euVal = new EU(objB);
    const euVal2 = new EU(euVal);
    expect(euVal2.$).to.equal(objB);
    expect(env.getJsValueCount()).to.equal(8);

    const Arr = arrStruct.constructor;
    const arr1 = new Arr([ objA, objB ]);
    const arr2 = new Arr(arr1);
    expect(arr2[0]).to.equal(objA);
    expect(arr2[1]).to.equal(objB);
    expect(env.getJsValueCount()).to.equal(12);

    const Tagged = unionStruct.constructor;
    const u1 = new Tagged({ js: objA });
    const u2 = new Tagged(u1);
    expect(u2.js).to.equal(objA);
    expect(env.getJsValueCount()).to.equal(14);

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
    argsInst[SLOTS][0] = p2;
    env.consumeJsValueRetval(argsInst);
    // p2's 2 handles were consumed & released while p2.a / p2.b remain readable!
    expect(env.getJsValueCount()).to.equal(12);
    expect(p2.a).to.equal(objA);
    expect(p2.b).to.equal(objB);
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
});
