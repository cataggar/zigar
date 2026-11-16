import { expect } from 'chai';
import { join } from 'node:path';

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

describe('Bun Native JS Host-Op Dispatcher & Dynamic Zig Callbacks Integration', function() {
  this.timeout(300000);

  const sampleURL = new URL('../../node-zigar/test/zig-samples/js-value/host-ops.zig', import.meta.url).href;
  let mod;

  before(async function() {
    global.__test_options = {
      optimize: 'ReleaseSafe',
      quiet: true,
    };
    mod = await import(sampleURL);
    mod.__zigar.set('modules', {
      'virtual:toolkit': {
        label: 'bun-tk',
        version: 11,
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

  it('should execute all 9 host operations, resolve node:path, bind `this`, and support Symbol keys on Bun N-API', function() {
    const modRes = mod.callVirtualModuleStaticAndDynamic(19, 23);
    expect(modRes.string).to.equal('bun-tk:42@v11');

    const joined = mod.importNodePathJoin('alpha', 'beta');
    expect(joined.string).to.equal(join('alpha', 'beta'));

    const bag = {};
    const sym = Symbol('bun-prop');
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

  it('should propagate JS exceptions into E!T error unions across Bun N-API without leaking handles', function() {
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

  it('should invoke >64 (80) distinct host-op signatures and 64 simultaneous stateful Zig callbacks on Bun N-API', function() {
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

    const bus = {
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
    };
    mod.register64StatefulCallbacks(bus);
    expect(Number(mod.activeCallbacks())).to.equal(64);
    expect(Number(mod.activeHandles())).to.equal(64);

    let expectedRound = 0n;
    for (let i = 0; i < 64; i++) {
      expectedRound += BigInt((i + 1) * 100 + 5 * (i + 2));
    }
    const reentrantSum = mod.triggerBusFromZig(bus, 5);
    expect(BigInt(reentrantSum)).to.equal(expectedRound);

    const staleSample = bus.listeners.get(0);
    mod.release64StatefulCallbacks();
    expect(Number(mod.activeCallbacks())).to.equal(0);
    expect(Number(mod.activeHandles())).to.equal(0);
    expect(() => staleSample(1)).to.throw(/already been released/);
  });

  it('should survive 2,200+ caught infallible JS throws, Callback throws, nested throws, and NotInErrorSet on Bun N-API', function() {
    const cleanup = { deferCount: 0 };
    for (let i = 0; i < 2200; i++) {
      expect(() => mod.callInfallibleWithStackAndDefer(() => {
        throw new Error('boom');
      }, i < 50 ? cleanup : null)).to.throw('boom');
    }
    expect(cleanup.deferCount).to.equal(50);
    expect(Number(mod.activeHandles())).to.equal(0);

    const cbFn = mod.createOwnedThrowingCallback();
    expect(() => cbFn(() => {
      throw new Error('cb-boom');
    })).to.throw('cb-boom');
    expect(Number(mod.deinitOwnedThrowingCallback())).to.equal(1);
    expect(Number(mod.activeCallbacks())).to.equal(0);
    expect(Number(mod.liveOwnedCallbackAllocs())).to.equal(0);

    expect(mod.nestedOuterFallible(() => {
      try {
        mod.nestedInnerInfallible(() => {
          throw new Error('inner');
        });
        return -1;
      } catch {
        return 777;
      }
    })).to.equal(777);
    expect(mod.nestedOuterCatching(() => mod.nestedInnerInfallible(() => {
      throw new Error('inner');
    }))).to.equal(-999);

    const tracker = { deferRuns: 0 };
    expect(() => mod.callMismatchedErrorSetWithDefer(() => {
      throw new RangeError('unlisted');
    }, tracker)).to.throw();
    expect(tracker.deferRuns).to.equal(1);

    for (let i = 0; i < 20; i++) {
      expect(() => mod.returnRefAfterThrow(() => {
        throw new Error(`bun-ref-boom-${i}`);
      })).to.throw(`bun-ref-boom-${i}`);
      expect(() => mod.returnStructRefAfterThrow(() => {
        throw new Error(`bun-struct-ref-boom-${i}`);
      })).to.throw(`bun-struct-ref-boom-${i}`);
      expect(() => mod.returnUnionRefAfterThrow(() => {
        throw new Error(`bun-union-ref-boom-${i}`);
      })).to.throw(`bun-union-ref-boom-${i}`);
    }
    const cbRefFn = mod.createRefAfterThrowCallback();
    expect(() => cbRefFn(() => {
      throw new Error('bun-cb-ref-boom');
    })).to.throw('bun-cb-ref-boom');
    expect(cbRefFn(() => 1)).to.equal(Math);
    mod.deinitRefAfterThrowCallback();
    expect(Number(mod.activeCallbacks())).to.equal(0);
    expect(Number(mod.activeHandles())).to.equal(0);
  });
});
