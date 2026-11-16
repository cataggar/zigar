import { expect } from 'chai';
import { join } from 'node:path';
import { load } from '../dist/index.js';

class StatefulCounter {
  constructor(initial) {
    this.count = initial;
  }
  increment(delta) {
    if (!(this instanceof StatefulCounter)) {
      throw new TypeError('method lost `this` binding');
    }
    this.count += delta;
    return this.count;
  }
  describe(tag) {
    if (!(this instanceof StatefulCounter)) {
      throw new TypeError('method lost `this` binding');
    }
    return `counter(${tag})=${this.count}`;
  }
}

class PayloadBox {
  constructor(payload) {
    this.computed = Number(payload.tag) + Number(payload.value);
  }
}

describe('Native JS Host-Op Dispatcher & Dynamic Zig Callbacks Integration', function() {
  this.timeout(300000);

  const sampleURL = new URL('./zig-samples/js-value/host-ops.zig?optimize=ReleaseSafe&quiet=1', import.meta.url);
  let mod;

  before(async function() {
    mod = await import(sampleURL.href);
    mod.__zigar.set('modules', {
      'virtual:toolkit': {
        label: 'native-tk',
        version: 9,
        combine(a, b) {
          return a + b;
        },
      },
    });
  });

  afterEach(function() {
    if (mod) {
      expect(Number(mod.activeCallbacks())).to.equal(0);
      expect(Number(mod.activeHandles())).to.equal(0);
    }
  });

  it('should generate clean native loader code without zigar-runtime subpath imports', async function() {
    const { source } = await load(sampleURL.href, {}, () => {});
    expect(source).to.contain('node-zigar-addon');
    expect(source).to.not.contain('features/js-host-op.js');
    expect(source).to.not.contain('features/js-value-registry.js');
  });

  it('should execute all 9 host operations, resolve node:path, bind `this`, and support Symbol keys on native N-API', function() {
    const modRes = mod.callVirtualModuleStaticAndDynamic(19, 23);
    expect(modRes.string).to.equal('native-tk:42@v9');

    const joined = mod.importNodePathJoin('alpha', 'beta');
    expect(joined.string).to.equal(join('alpha', 'beta'));

    const bag = {};
    const sym = Symbol('native-prop');
    const propSum = mod.testGlobalAndPropOps(bag, sym, 50);
    expect(propSum).to.equal(1859);
    expect(bag[sym]).to.equal(77);
    expect('counter' in bag).to.be.false;
    expect('dynKey' in bag).to.be.false;

    const ctorAndMethodRes = mod.testCallFnMethodAndConstruct(
      (a, b) => a * 2 + b,
      StatefulCounter,
      10,
    );
    expect(ctorAndMethodRes.string).to.equal('counter(ok)=32:32');
  });

  it('should propagate JS exceptions into E!T error unions across native N-API without leaking handles', function() {
    const faultyObj = {
      notAFunction: 42,
      validate(n) {
        if (n < 0) {
          const err = new Error('negative');
          err.error = 'ValidationFailed';
          throw err;
        }
        return { ok: true };
      },
    };
    Object.defineProperty(faultyObj, 'throwingProp', {
      get() {
        throw new RangeError('getter boom');
      },
    });
    Object.defineProperty(faultyObj, 'readOnlyProp', {
      set() {
        throw new TypeError('setter boom');
      },
    });
    function BadCtor() {
      throw new Error('ctor boom');
    }
    const badFn = () => {
      throw new Error('fn boom');
    };

    const mask = mod.testFallibleHostOps(faultyObj, BadCtor, badFn);
    expect(mask).to.equal(0b111111);
  });

  it('should invoke >64 (80) distinct host-op signatures in one native module cleanly', function() {
    const standaloneFn = (p) => Number(p.tag) + Number(p.value) * 2;
    const helperObj = {
      evalPayload(p, bonus) {
        if (this !== helperObj) {
          throw new TypeError('wrong receiver');
        }
        return Number(p.value) - Number(p.tag) + bonus;
      },
      makePayload(tag, value) {
        if (this !== helperObj) {
          throw new TypeError('wrong receiver');
        }
        return { tag, value };
      },
    };

    let expected = 0n;
    for (let i = 0; i < 80; i++) {
      const val = i * 3 + 1;
      switch (i % 5) {
        case 0:
          expected += BigInt(i + val * 2);
          break;
        case 1:
          expected += BigInt(val - i + i);
          break;
        case 2:
          expected += BigInt(val + i);
          break;
        case 3:
          expected += BigInt(i + val);
          break;
        case 4:
          expected += BigInt((i + 10) + i);
          break;
      }
    }

    const actual = mod.stress80DistinctHostSignatures(standaloneFn, helperObj, PayloadBox);
    expect(BigInt(actual)).to.equal(expected);
  });

  it('should register, re-entrantly invoke, release, and recycle 64 simultaneous stateful Zig callbacks on native N-API', function() {
    const createBus = () => ({
      listeners: new Map(),
      register(idx, fn) {
        this.listeners.set(idx, fn);
      },
      emitAll(input) {
        let total = 0n;
        for (const fn of this.listeners.values()) {
          total += BigInt(fn(input));
        }
        return total;
      },
    });

    for (let cycle = 0; cycle < 2; cycle++) {
      const bus = createBus();
      mod.register64StatefulCallbacks(bus);
      expect(bus.listeners.size).to.equal(64);
      expect(Number(mod.activeCallbacks())).to.equal(64);
      expect(Number(mod.activeHandles())).to.equal(64);

      let directSum = 0n;
      let expectedRound1 = 0n;
      for (let i = 0; i < 64; i++) {
        const id = i + 1;
        const mul = i + 2;
        const out = bus.listeners.get(i)(3);
        expect(out).to.equal(id * 100 + 3 * mul);
        directSum += BigInt(out);
        expectedRound1 += BigInt(id * 100 + 3 * mul);
      }
      expect(directSum).to.equal(expectedRound1);

      let expectedRound2 = 0n;
      for (let i = 0; i < 64; i++) {
        expectedRound2 += BigInt((i + 1) * 100 + 5 * (i + 2));
      }
      const reentrantSum = mod.triggerBusFromZig(bus, 5);
      expect(BigInt(reentrantSum)).to.equal(expectedRound2);

      expect(Number(mod.inspectCallbackTotalCalls())).to.equal(128);
      expect(BigInt(mod.inspectCallbackTotalAccum())).to.equal(expectedRound1 + expectedRound2);

      const staleSample = bus.listeners.get(0);
      mod.release64StatefulCallbacks();
      expect(Number(mod.activeCallbacks())).to.equal(0);
      expect(Number(mod.activeHandles())).to.equal(0);
      expect(() => staleSample(1)).to.throw(/already been released/);
    }
  });

  it('should survive 2,200+ caught infallible JS throws on native N-API without leaking Ref handles', function() {
    const cleanup = { deferCount: 0 };
    let caught = 0;
    for (let i = 0; i < 2200; i++) {
      const thrower = () => {
        throw new Error('boom');
      };
      const track = (i < 200) ? cleanup : null;
      expect(() => mod.callInfallibleWithStackAndDefer(thrower, track)).to.throw('boom');
      caught++;
    }
    expect(caught).to.equal(2200);
    expect(cleanup.deferCount).to.equal(200);
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  it('should run Zig defers and free owned Callback slots cleanly when infallible host-op inside Callback throws', function() {
    const cbFn = mod.createOwnedThrowingCallback();
    expect(Number(mod.activeCallbacks())).to.equal(1);
    expect(Number(mod.liveOwnedCallbackAllocs())).to.equal(1);

    for (let i = 0; i < 10; i++) {
      expect(() => cbFn(() => {
        throw new Error(`cb-boom-${i}`);
      })).to.throw(`cb-boom-${i}`);
    }
    expect(cbFn(() => 123)).to.equal(123);

    const deferRuns = mod.deinitOwnedThrowingCallback();
    expect(Number(deferRuns)).to.equal(11);
    expect(Number(mod.activeCallbacks())).to.equal(0);
    expect(Number(mod.activeHandles())).to.equal(0);
    expect(Number(mod.liveOwnedCallbackAllocs())).to.equal(0);
  });

  it('should isolate nested JS -> Zig outer (E!i32) -> JS mid -> Zig inner (i32) -> throwing JS op on native N-API', function() {
    const midCaught = () => {
      try {
        mod.nestedInnerInfallible(() => {
          throw new Error('inner-boom');
        });
        return -1;
      } catch (err) {
        expect(err.message).to.equal('inner-boom');
        return 777;
      }
    };
    expect(mod.nestedOuterFallible(midCaught)).to.equal(777);
    expect(Number(mod.activeHandles())).to.equal(0);

    const midUncaught = () => mod.nestedInnerInfallible(() => {
      throw new Error('uncaught-inner-boom');
    });
    expect(mod.nestedOuterCatching(midUncaught)).to.equal(-999);
    let outerErr = null;
    try {
      mod.nestedOuterFallible(midUncaught);
    } catch (err) {
      outerErr = err;
    }
    expect(outerErr).to.be.instanceOf(Error);
    expect(outerErr.message).to.equal('Js exception');
    expect(JSON.parse(JSON.stringify(outerErr))).to.deep.equal({ error: 'Js exception' });
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  it('should throw NotInErrorSet cleanly in JS on native N-API while running Zig defers', function() {
    const tracker = { deferRuns: 0 };
    for (let i = 0; i < 60; i++) {
      let thrown = null;
      try {
        mod.callMismatchedErrorSetWithDefer(() => {
          throw new RangeError('unlisted-js-error');
        }, tracker);
      } catch (err) {
        thrown = err;
      }
      expect(thrown).to.be.instanceOf(TypeError);
      expect(thrown.message).to.match(/not a part of error set .*unlisted-js-error/);
    }
    expect(tracker.deferRuns).to.equal(60);
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  it('should release live Ref(T), composite struct/union Refs, and Callback Refs returned after an infallible throw on native N-API', function() {
    for (let i = 0; i < 40; i++) {
      expect(() => mod.returnRefAfterThrow(() => {
        throw new Error(`ref-boom-${i}`);
      })).to.throw(`ref-boom-${i}`);
      expect(() => mod.returnStructRefAfterThrow(() => {
        throw new Error(`struct-ref-boom-${i}`);
      })).to.throw(`struct-ref-boom-${i}`);
      expect(() => mod.returnUnionRefAfterThrow(() => {
        throw new Error(`union-ref-boom-${i}`);
      })).to.throw(`union-ref-boom-${i}`);
    }
    expect(Number(mod.activeHandles())).to.equal(0);

    const cbFn = mod.createRefAfterThrowCallback();
    for (let i = 0; i < 20; i++) {
      expect(() => cbFn(() => {
        throw new Error(`cb-ref-boom-${i}`);
      })).to.throw(`cb-ref-boom-${i}`);
    }
    expect(cbFn(() => 1)).to.equal(Math);
    mod.deinitRefAfterThrowCallback();
    expect(Number(mod.activeCallbacks())).to.equal(0);
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  it('should pass by-value extern struct Point4 and sret return across 24 callconv(.c) callbacks on native N-API', function() {
    try {
      for (let i = 0; i < 24; i++) {
        const idx = i;
        mod.registerPointCb(idx, (pt) => ({
          x: pt.x + (idx + 1) * 100,
          y: pt.y - (idx + 1) * 10,
          z: pt.z + (idx + 1) * 1000,
          w: pt.w ^ (idx + 1),
        }));
      }
      for (let i = 0; i < 24; i++) {
        const input = { x: i + 1, y: i + 2, z: i + 3, w: i + 4 };
        const out = mod.callPointCb(i, input);
        expect({ x: out.x, y: out.y, z: out.z, w: out.w }).to.deep.equal({
          x: input.x + (i + 1) * 100,
          y: input.y - (i + 1) * 10,
          z: input.z + (i + 1) * 1000,
          w: input.w ^ (i + 1),
        });
      }
      mod.clearPointCbs();
      for (let i = 0; i < 24; i++) {
        const idx = i;
        mod.registerPointCb(idx, (pt) => ({
          x: pt.x + (idx + 50),
          y: pt.y + (idx + 60),
          z: pt.z + (idx + 70),
          w: pt.w + (idx + 80),
        }));
      }
      for (let i = 0; i < 24; i++) {
        const out = mod.callPointCb(i, { x: 1, y: 2, z: 3, w: 4 });
        expect({ x: out.x, y: out.y, z: out.z, w: out.w }).to.deep.equal({
          x: 1 + i + 50,
          y: 2 + i + 60,
          z: 3 + i + 70,
          w: 4 + i + 80,
        });
      }
    } finally {
      mod.clearPointCbs();
    }
  });
});
