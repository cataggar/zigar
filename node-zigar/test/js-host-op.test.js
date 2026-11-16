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
});
