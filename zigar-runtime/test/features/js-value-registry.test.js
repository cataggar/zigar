import { expect } from 'chai';
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

  it('should handle high-bit signed i32 handles and wrap 12-bit generation from 4095 to 1', function() {
    const env = new Env();
    const target = { tag: 'wrap' };
    let lastHandle = 0;
    for (let i = 0; i < 4100; i++) {
      const h = env.allocJsValue(target);
      expect(h & 0x000FFFFF).to.equal(8);
      const gen = h >>> 20;
      expect(gen).to.be.at.least(1);
      expect(gen).to.be.at.most(4095);
      // Verify signed i32 representation (as passed across WebAssembly i32 boundary when gen >= 2048)
      const signedI32 = h | 0;
      expect(env.getJsValue(signedI32)).to.equal(target);
      env.releaseJsValue(signedI32);
      lastHandle = h;
    }
    expect(lastHandle >>> 20).to.equal(5);
    expect(env.getJsValueCount()).to.equal(0);
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
});
