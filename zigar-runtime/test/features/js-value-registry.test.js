import { expect } from 'chai';
import { MemberType, StructureFlag, StructurePurpose, StructureType } from '../../src/constants.js';
import { defineEnvironment } from '../../src/environment.js';
import { InvalidJsValueHandle } from '../../src/errors.js';
import {
  FIRST_DYNAMIC_SLOT,
  RESERVED_FALSE,
  RESERVED_GLOBAL_THIS,
  RESERVED_NULL,
  RESERVED_TRUE,
  RESERVED_UNDEFINED,
} from '../../src/features/js-value-registry.js';
import { FALLBACK, MEMORY, SLOTS, TARGET, ZIG } from '../../src/symbols.js';
import '../../src/mixins.js';

const Env = defineEnvironment();

describe('Feature: js-value-registry', function() {
  it('should map reserved constants without allocating slots and treat release as no-op', function() {
    const env = new Env();
    expect(env.allocJsValue(undefined)).to.equal(RESERVED_UNDEFINED);
    expect(env.allocJsValue(null)).to.equal(RESERVED_NULL);
    expect(env.allocJsValue(false)).to.equal(RESERVED_FALSE);
    expect(env.allocJsValue(true)).to.equal(RESERVED_TRUE);
    expect(env.allocJsValue(globalThis)).to.equal(RESERVED_GLOBAL_THIS);
    expect(env.getJsValueCount()).to.equal(0);

    expect(env.getJsValue(RESERVED_UNDEFINED)).to.be.undefined;
    expect(env.getJsValue(RESERVED_NULL)).to.be.null;
    expect(env.getJsValue(RESERVED_FALSE)).to.be.false;
    expect(env.getJsValue(RESERVED_TRUE)).to.be.true;
    expect(env.getJsValue(RESERVED_GLOBAL_THIS)).to.equal(globalThis);

    for (const h of [
      RESERVED_UNDEFINED,
      RESERVED_NULL,
      RESERVED_FALSE,
      RESERVED_TRUE,
      RESERVED_GLOBAL_THIS,
    ]) {
      expect(env.cloneJsValue(h)).to.equal(h);
      env.releaseJsValue(h);
      env.releaseJsValue(h);
    }
    expect(env.getJsValueCount()).to.equal(0);

    for (const unused of [ 5, 6, 7 ]) {
      expect(() => env.getJsValue(unused)).to.throw(InvalidJsValueHandle);
      expect(() => env.releaseJsValue(unused)).to.throw(InvalidJsValueHandle);
      expect(() => env.cloneJsValue(unused)).to.throw(InvalidJsValueHandle);
    }
  });

  it('should allocate dynamic slots starting at index 8 and preserve Object.is identity', function() {
    const env = new Env();
    class Widget {
      constructor(name) {
        this.name = name;
      }
    }
    const plain = { a: 1 };
    const widget = new Widget('gear');
    const fn = function sample() { return 42; };
    const sym = Symbol('token');
    const values = [ plain, widget, fn, sym, 'hello', 123.5, 9007199254740993n, NaN, -0, +0 ];

    const handles = values.map((v) => env.allocJsValue(v));
    expect(handles[0] & 0x000FFFFF).to.equal(FIRST_DYNAMIC_SLOT);
    expect(handles[0] >>> 20).to.equal(1);
    expect(env.getJsValueCount()).to.equal(values.length);

    for (let i = 0; i < values.length; i++) {
      expect(Object.is(env.getJsValue(handles[i]), values[i])).to.be.true;
    }

    for (const h of handles) {
      env.releaseJsValue(h);
    }
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should reuse freed slots with incremented generation and catch stale or double-released handles', function() {
    const env = new Env();
    const first = { id: 1 };
    const second = { id: 2 };
    const h1 = env.allocJsValue(first);
    expect(h1 & 0x000FFFFF).to.equal(8);
    expect(h1 >>> 20).to.equal(1);

    env.releaseJsValue(h1);
    expect(env.getJsValueCount()).to.equal(0);
    expect(() => env.getJsValue(h1)).to.throw(InvalidJsValueHandle);
    expect(() => env.releaseJsValue(h1)).to.throw(InvalidJsValueHandle);
    expect(() => env.cloneJsValue(h1)).to.throw(InvalidJsValueHandle);

    const h2 = env.allocJsValue(second);
    expect(h2 & 0x000FFFFF).to.equal(8);
    expect(h2 >>> 20).to.equal(2);
    expect(env.getJsValue(h2)).to.equal(second);
    // Stale h1 pointing to reused slot 8 must still fail (no ABA bug)
    expect(() => env.getJsValue(h1)).to.throw(InvalidJsValueHandle);
    expect(() => env.releaseJsValue(h1)).to.throw(InvalidJsValueHandle);

    env.releaseJsValue(h2);
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should cycle freed slots FIFO, retire slots at generation 4095, and never alias stale handles across 10,000 cycles', function() {
    const env = new Env();

    // Verify FIFO free-queue ordering across multiple freed slots
    const fa = env.allocJsValue({ slot: 'a' });
    const fb = env.allocJsValue({ slot: 'b' });
    const fc = env.allocJsValue({ slot: 'c' });
    expect([ fa & 0x000FFFFF, fb & 0x000FFFFF, fc & 0x000FFFFF ]).to.deep.equal([ 8, 9, 10 ]);
    env.releaseJsValue(fa);
    env.releaseJsValue(fb);
    env.releaseJsValue(fc);
    const ra = env.allocJsValue({ slot: 'a2' });
    const rb = env.allocJsValue({ slot: 'b2' });
    const rc = env.allocJsValue({ slot: 'c2' });
    expect([ ra & 0x000FFFFF, rb & 0x000FFFFF, rc & 0x000FFFFF ]).to.deep.equal([ 8, 9, 10 ]);
    expect([ ra >>> 20, rb >>> 20, rc >>> 20 ]).to.deep.equal([ 2, 2, 2 ]);
    env.releaseJsValue(ra);
    env.releaseJsValue(rb);
    env.releaseJsValue(rc);

    // Run 10,000 create/release cycles on a fresh environment while retaining stale handles
    const freshEnv = new Env();
    let staleIter1 = 0;
    let staleIter4095 = 0;
    let handleIter4096 = 0;
    for (let i = 1; i <= 10000; i++) {
      const target = { cycle: i };
      const h = freshEnv.allocJsValue(target);
      const gen = h >>> 20;
      expect(gen).to.be.at.least(1);
      expect(gen).to.be.at.most(4095);
      if (i === 1) {
        expect(h & 0x000FFFFF).to.equal(8);
        expect(gen).to.equal(1);
        staleIter1 = h;
      } else if (i === 4095) {
        expect(h & 0x000FFFFF).to.equal(8);
        expect(gen).to.equal(4095);
        staleIter4095 = h;
      } else if (i === 4096) {
        // Slot 8 retired permanently at generation 4095; allocation advances to slot 9 generation 1!
        expect(h & 0x000FFFFF).to.equal(9);
        expect(gen).to.equal(1);
        handleIter4096 = h;
      }
      // Verify signed i32 representation (as passed across WebAssembly i32 boundary when gen >= 2048)
      const signedI32 = h | 0;
      expect(freshEnv.getJsValue(signedI32)).to.equal(target);
      if (i > 1) {
        expect(() => freshEnv.getJsValue(staleIter1)).to.throw(InvalidJsValueHandle);
      }
      if (i > 4095) {
        expect(() => freshEnv.getJsValue(staleIter4095)).to.throw(InvalidJsValueHandle);
      }
      freshEnv.releaseJsValue(signedI32);
    }
    expect(handleIter4096 & 0x000FFFFF).to.equal(9);
    expect(freshEnv.getJsValueCount()).to.equal(0);

    // Allocate one more live object and verify neither stale handle aliases it
    const finalLive = freshEnv.allocJsValue({ final: true });
    expect(() => freshEnv.getJsValue(staleIter1)).to.throw(InvalidJsValueHandle);
    expect(() => freshEnv.getJsValue(staleIter4095)).to.throw(InvalidJsValueHandle);
    expect(freshEnv.getJsValue(finalLive)).to.deep.equal({ final: true });
    freshEnv.releaseJsValue(finalLive);
    expect(freshEnv.getJsValueCount()).to.equal(0);
  });

  it('should release remaining valid sibling handles when consuming a composite containing a stale handle', function() {
    const env = new Env();
    env.littleEndian = true;
    const staleFirst = env.allocJsValue({ stale: true });
    env.releaseJsValue(staleFirst);
    const validSecond = env.allocJsValue({ valid: true });
    expect(env.getJsValueCount()).to.equal(1);

    const buf = new ArrayBuffer(8);
    const dv = new DataView(buf);
    dv.setUint32(0, staleFirst, true);
    dv.setUint32(4, validSecond, true);

    const jsValStruct = {
      purpose: StructurePurpose.JsValue,
      type: StructureType.Struct,
      flags: StructureFlag.HasJsValue,
      byteSize: 4,
    };
    const pairStruct = {
      purpose: StructurePurpose.Unknown,
      type: StructureType.Struct,
      flags: StructureFlag.HasJsValue | StructureFlag.HasSlot,
      byteSize: 8,
      instance: {
        members: [
          { type: MemberType.Object, offset: 0, bitOffset: 0, slot: 0, structure: jsValStruct },
          { type: MemberType.Object, offset: 4, bitOffset: 32, slot: 1, structure: jsValStruct },
        ],
      },
    };
    const refFirst = { [MEMORY]: new DataView(buf, 0, 4) };
    const refSecond = { [MEMORY]: new DataView(buf, 4, 4) };
    const pairObj = {
      [MEMORY]: dv,
      [SLOTS]: { 0: refFirst, 1: refSecond },
    };
    const argObj = {
      [SLOTS]: { 0: pairObj },
    };

    expect(() => env.consumeJsValueSlot(argObj, 0, pairStruct)).to.throw(InvalidJsValueHandle);
    expect(env.getJsValueCount()).to.equal(0);
    expect(refSecond[TARGET]).to.deep.equal({ valid: true });
    expect(dv.getUint32(0, true)).to.equal(0);
    expect(dv.getUint32(4, true)).to.equal(0);
  });

  it('should clone dynamic handles into independent slots and grow capacity cleanly', function() {
    const env = new Env();
    const obj = { shared: true };
    const h1 = env.allocJsValue(obj);
    const h2 = env.cloneJsValue(h1);
    expect(h2).to.not.equal(h1);
    expect(env.getJsValueCount()).to.equal(2);

    env.releaseJsValue(h1);
    expect(env.getJsValueCount()).to.equal(1);
    expect(env.getJsValue(h2)).to.equal(obj);
    env.releaseJsValue(h2);
    expect(env.getJsValueCount()).to.equal(0);

    const manyHandles = [];
    for (let i = 0; i < 300; i++) {
      manyHandles.push(env.allocJsValue({ index: i }));
    }
    expect(env.getJsValueCount()).to.equal(300);
    for (let i = 0; i < 300; i++) {
      expect(env.getJsValue(manyHandles[i]).index).to.equal(i);
      env.releaseJsValue(manyHandles[i]);
    }
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should implement typeofJsValue, instanceofJsValue, and equalJsValue accurately', function() {
    const env = new Env();
    class Base {}
    class Derived extends Base {}
    const inst = new Derived();
    const sym = Symbol('s');
    const fn = () => {};

    const hInst = env.allocJsValue(inst);
    const hBase = env.allocJsValue(Base);
    const hDerived = env.allocJsValue(Derived);
    const hArray = env.allocJsValue(Array);
    const hNum = env.allocJsValue(42);
    const hBig = env.allocJsValue(42n);
    const hStr = env.allocJsValue('zig');
    const hSym = env.allocJsValue(sym);
    const hFn = env.allocJsValue(fn);
    const hNaN1 = env.allocJsValue(NaN);
    const hNaN2 = env.allocJsValue(NaN);
    const hNegZero = env.allocJsValue(-0);
    const hPosZero = env.allocJsValue(+0);

    expect(env.typeofJsValue(RESERVED_UNDEFINED)).to.equal(0);
    expect(env.typeofJsValue(RESERVED_NULL)).to.equal(1);
    expect(env.typeofJsValue(hInst)).to.equal(1);
    expect(env.typeofJsValue(RESERVED_TRUE)).to.equal(2);
    expect(env.typeofJsValue(hNum)).to.equal(3);
    expect(env.typeofJsValue(hBig)).to.equal(4);
    expect(env.typeofJsValue(hStr)).to.equal(5);
    expect(env.typeofJsValue(hSym)).to.equal(6);
    expect(env.typeofJsValue(hFn)).to.equal(7);

    expect(env.instanceofJsValue(hInst, hDerived)).to.be.true;
    expect(env.instanceofJsValue(hInst, hBase)).to.be.true;
    expect(env.instanceofJsValue(hInst, hArray)).to.be.false;
    expect(env.instanceofJsValue(RESERVED_NULL, hBase)).to.be.false;
    expect(() => env.instanceofJsValue(hInst, hNum)).to.throw(TypeError);

    expect(env.equalJsValue(hInst, env.cloneJsValue(hInst))).to.be.true;
    // release the temporary clone we just made
    expect(env.equalJsValue(hNaN1, hNaN2)).to.be.true;
    expect(env.equalJsValue(hNegZero, hPosZero)).to.be.false;
    expect(env.equalJsValue(RESERVED_NULL, RESERVED_UNDEFINED)).to.be.false;

    env.resetJsValueRegistry();
    expect(env.getJsValueCount()).to.equal(0);
  });

  it('should isolate dynamic handles across realms via setJsValueRealmTag while preserving reserved constants', function() {
    const primaryEnv = new Env();
    const workerEnv = new Env();
    primaryEnv.setJsValueRealmTag(0);
    workerEnv.setJsValueRealmTag(32);

    const primaryObj = { realm: 'primary' };
    const workerObj = { realm: 'worker' };
    const hPrimary = primaryEnv.allocJsValue(primaryObj);
    const hWorker = workerEnv.allocJsValue(workerObj);

    // Both allocate slot 8 generation 1, but realm bits (14..19) differ (0 vs 32)
    expect(hPrimary & 0x3FFF).to.equal(FIRST_DYNAMIC_SLOT);
    expect(hWorker & 0x3FFF).to.equal(FIRST_DYNAMIC_SLOT);
    expect((hPrimary >>> 14) & 0x3F).to.equal(0);
    expect((hWorker >>> 14) & 0x3F).to.equal(32);
    expect(hPrimary).to.not.equal(hWorker);

    // Cross-realm handle lookup/clone/release/typeof/equal must throw InvalidJsValueHandle
    expect(() => workerEnv.getJsValue(hPrimary)).to.throw(InvalidJsValueHandle);
    expect(() => workerEnv.cloneJsValue(hPrimary)).to.throw(InvalidJsValueHandle);
    expect(() => workerEnv.releaseJsValue(hPrimary)).to.throw(InvalidJsValueHandle);
    expect(() => workerEnv.typeofJsValue(hPrimary)).to.throw(InvalidJsValueHandle);
    expect(() => workerEnv.equalJsValue(hPrimary, hWorker)).to.throw(InvalidJsValueHandle);

    expect(() => primaryEnv.getJsValue(hWorker)).to.throw(InvalidJsValueHandle);
    expect(() => primaryEnv.releaseJsValue(hWorker)).to.throw(InvalidJsValueHandle);

    // Own handles and reserved constants remain completely intact
    expect(primaryEnv.getJsValue(hPrimary)).to.equal(primaryObj);
    expect(workerEnv.getJsValue(hWorker)).to.equal(workerObj);
    expect(workerEnv.getJsValue(RESERVED_GLOBAL_THIS)).to.equal(globalThis);
    expect(workerEnv.cloneJsValue(RESERVED_TRUE)).to.equal(RESERVED_TRUE);

    primaryEnv.releaseJsValue(hPrimary);
    workerEnv.releaseJsValue(hWorker);
    expect(primaryEnv.getJsValueCount()).to.equal(0);
    expect(workerEnv.getJsValueCount()).to.equal(0);

    if (process.env.TARGET === 'node') {
      const exports = primaryEnv.exportFunctions();
      expect(exports.cloneJsValue).to.be.a('function');
      expect(exports.releaseJsValue).to.be.a('function');
      expect(exports.typeofJsValue).to.be.a('function');
      expect(exports.instanceofJsValue).to.be.a('function');
      expect(exports.equalJsValue).to.be.a('function');
      expect(exports.getJsValueCount).to.be.a('function');
      expect(exports.setJsValueRealmTag).to.be.a('function');
    }
  });

  it('should recycle quarantined max-generation slots past 67M churn cycles without exhausting, while throwing when 16,376 handles are simultaneously live', function() {
    this.timeout(60000);
    const env = new Env();
    const reusable = { marker: 'long-running-server' };
    const totalDynamicSlots = 16384 - FIRST_DYNAMIC_SLOT; // 16,376
    const fullQuarantineCycles = totalDynamicSlots * 4095; // 67,059,720

    let slot8FinalBeforeWrap = 0;
    for (let i = 1; i <= fullQuarantineCycles; i++) {
      const h = env.allocJsValue(reusable);
      if (i === 4095) {
        slot8FinalBeforeWrap = h;
      }
      env.releaseJsValue(h);
    }
    expect(env.getJsValueCount()).to.equal(0);
    expect(() => env.getJsValue(slot8FinalBeforeWrap)).to.throw(InvalidJsValueHandle);

    // Cycle 67,059,721 must recycle quarantined slot 8 at generation 1 instead of throwing
    const wrappedFirst = env.allocJsValue(reusable);
    expect(wrappedFirst & 0x3FFF).to.equal(FIRST_DYNAMIC_SLOT);
    expect(wrappedFirst >>> 20).to.equal(1);
    expect(env.getJsValue(wrappedFirst)).to.equal(reusable);
    expect(() => env.getJsValue(slot8FinalBeforeWrap)).to.throw(InvalidJsValueHandle);
    env.releaseJsValue(wrappedFirst);

    // Continue churning another 50,000 cycles smoothly
    for (let i = 0; i < 50000; i++) {
      const h = env.allocJsValue(reusable);
      env.releaseJsValue(h);
    }
    expect(env.getJsValueCount()).to.equal(0);

    // Exhaustion only occurs when all 16,376 dynamic slots are simultaneously active
    const satEnv = new Env();
    const liveHandles = new Uint32Array(totalDynamicSlots);
    for (let i = 0; i < totalDynamicSlots; i++) {
      liveHandles[i] = satEnv.allocJsValue(reusable);
    }
    expect(satEnv.getJsValueCount()).to.equal(totalDynamicSlots);
    expect(() => satEnv.allocJsValue(reusable)).to.throw(RangeError, /JsValueRegistry exhausted/);

    satEnv.releaseJsValue(liveHandles[0]);
    const recovered = satEnv.allocJsValue(reusable);
    expect(satEnv.getJsValue(recovered)).to.equal(reusable);
    satEnv.releaseJsValue(recovered);
    for (let i = 1; i < totalDynamicSlots; i++) {
      satEnv.releaseJsValue(liveHandles[i]);
    }
    expect(satEnv.getJsValueCount()).to.equal(0);
  });

  it('should synchronize [FALLBACK] buffers when consuming or releasing Zig-memory JsValue handles on Node', function() {
    if (process.env.TARGET !== 'node') {
      return;
    }
    const env = new Env();
    env.littleEndian = true;
    const target = { fallbackSynced: true };
    const h1 = env.allocJsValue(target);
    const h2 = env.allocJsValue({ second: true });

    const externBuf = new ArrayBuffer(8);
    const externView = new DataView(externBuf);
    externView.setUint32(0, h1, true);
    externView.setUint32(4, h2, true);

    // Local shadow buffer starts zeroed until FALLBACK(false) pulls from externBuf
    const shadowBuf = new ArrayBuffer(8);
    const shadowView = new DataView(shadowBuf, 0, 4);
    const syncCalls = [];
    shadowView[FALLBACK] = (toExtern, offset = 0, len = shadowView.byteLength) => {
      syncCalls.push(toExtern);
      const src = toExtern ? new Uint8Array(shadowBuf, offset, len) : new Uint8Array(externBuf, offset, len);
      const dst = toExtern ? new Uint8Array(externBuf, offset, len) : new Uint8Array(shadowBuf, offset, len);
      dst.set(src);
    };

    const refObj = { [MEMORY]: shadowView };
    env.consumeJsValueObject(refObj);
    expect(refObj[TARGET]).to.equal(target);
    expect(externView.getUint32(0, true)).to.equal(0);
    expect(syncCalls).to.deep.equal([ false, true ]);
    expect(env.getJsValueCount()).to.equal(1);

    const jsValStruct = {
      purpose: StructurePurpose.JsValue,
      type: StructureType.Struct,
      byteSize: 4,
    };
    const subView = new DataView(shadowBuf, 4, 4);
    subView[ZIG] = { address: 0x1004, len: 4 };
    subView[FALLBACK] = (toExtern) => {
      syncCalls.push(toExtern);
      const src = toExtern ? new Uint8Array(shadowBuf, 4, 4) : new Uint8Array(externBuf, 4, 4);
      const dst = toExtern ? new Uint8Array(externBuf, 4, 4) : new Uint8Array(shadowBuf, 4, 4);
      dst.set(src);
    };
    env.releaseZigJsValues(jsValStruct, subView, 0);
    expect(syncCalls).to.deep.equal([ false, true, false ]);
    expect(env.getJsValueCount()).to.equal(0);
  });
});
