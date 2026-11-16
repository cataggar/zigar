import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { Worker } from 'node:worker_threads';

const execFileAsync = promisify(execFile);

class CustomWidget {
  constructor(label) {
    this.label = label;
  }
  describe() {
    return `widget:${this.label}`;
  }
}

class SubWidget extends CustomWidget {}

describe('Bun Native JsValue Handle Registry & zigar.js.Ref(T) Integration', function() {
  this.timeout(300000);

  const sampleURL = new URL('../../node-zigar/test/zig-samples/js-value/handles.zig', import.meta.url).href;
  const relayURL = new URL('../../node-zigar/test/zig-samples/js-value/relay.zig', import.meta.url).href;
  const samplePath = fileURLToPath(sampleURL);
  const workerScriptURL = new URL('./js-value-worker.mjs', import.meta.url);
  const workerScriptPath = fileURLToPath(workerScriptURL);

  let mod;

  before(async function() {
    global.__test_options = {
      optimize: 'ReleaseSafe',
      quiet: true,
    };
    mod = await import(sampleURL);
  });

  afterEach(function() {
    if (mod) {
      mod.clearGlobal();
      expect(Number(mod.activeCount())).to.equal(0);
    }
  });

  it('should preserve exact Object.is identity and reserved constant handles 0..4 across Bun N-API', function() {
    const widget = new CustomWidget('bun-alpha');
    const map = new Map([['k', 'v']]);
    const fn = (a, b) => a * b;
    const sym = Symbol('bun-token');

    for (const candidate of [
      { nested: 1 },
      widget,
      map,
      fn,
      sym,
      'hello bun',
      0,
      -0,
      NaN,
      9007199254740993n,
      true,
      false,
      null,
      undefined,
      globalThis,
    ]) {
      expect(Object.is(mod.identity(candidate), candidate)).to.be.true;
      expect(Number(mod.activeCount())).to.equal(0);
    }

    expect(mod.identityObject(widget).describe()).to.equal('widget:bun-alpha');
    expect(mod.identitySymbol(sym)).to.equal(sym);
    expect(mod.identityFunction(fn)(6, 7)).to.equal(42);

    expect(mod.inspectRawHandle(undefined)).to.equal(0);
    expect(mod.inspectRawHandle(null)).to.equal(1);
    expect(mod.inspectRawHandle(false)).to.equal(2);
    expect(mod.inspectRawHandle(true)).to.equal(3);
    expect(mod.inspectRawHandle(globalThis)).to.equal(4);
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should support typeof, instanceof, eql, persistent globals, HandleScope churn, composites, callbacks, and pointers', function() {
    expect(mod.checkIsJsThread()).to.be.true;
    const sub = new SubWidget('bun-sub');
    expect(mod.checkInstanceof(sub, SubWidget)).to.be.true;
    expect(mod.checkInstanceof(sub, CustomWidget)).to.be.true;
    expect(mod.checkEqual(NaN, NaN)).to.be.true;
    expect(mod.checkEqual(+0, -0)).to.be.false;
    expect(mod.exerciseTryOpsOnMainThread(sub, CustomWidget)).to.be.true;

    mod.storeGlobal(sub);
    for (let i = 0; i < 25; i++) {
      expect(Object.is(mod.loadGlobalClone(), sub)).to.be.true;
    }
    mod.clearGlobal();
    expect(Number(mod.activeCount())).to.equal(0);

    expect(mod.churnHandlesInSingleCall({ a: 1 }, { b: 2 }, 5000)).to.equal(5000);
    expect(Number(mod.activeCount())).to.equal(0);

    const objA = { side: 'A' };
    const objB = { side: 'B' };
    const swapped = mod.swapPair({ first: objA, second: objB });
    expect(Object.is(swapped.first, objB)).to.be.true;
    expect(Object.is(swapped.second, objA)).to.be.true;

    const returned = mod.callWithBorrowedRef(sub, (arg) => {
      expect(Object.is(arg, sub)).to.be.true;
      return objA;
    });
    expect(Object.is(returned, objA)).to.be.true;

    const pair = new mod.Pair({ first: objA, second: objB });
    const taken = mod.takeFirstAndSet(pair, sub);
    expect(Object.is(taken, objA)).to.be.true;
    expect(Object.is(pair.first, sub)).to.be.true;

    mod.poisonUninitVarsWith0xAA();
    mod.default.uninit_ref = objA;
    expect(Object.is(mod.default.uninit_ref, objA)).to.be.true;
    mod.default.uninit_ref = undefined;
    expect(Number(mod.activeCount())).to.equal(0);

    expect(() => mod.triggerStaleUseWithValidDefer({ stale: 1 }, { guard: 2 })).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should restore active ModuleHost across M1 -> N -> M2 re-entrancy when M1 and M2 share the same .so', async function() {
    global.__test_options = { optimize: 'ReleaseSafe', recompile: false, quiet: true };
    const mod2 = await import(`${sampleURL}?quiet=1`);
    global.__test_options = { optimize: 'ReleaseSafe', recompile: false, quiet: true };
    const relayMod = await import(relayURL);

    const m1Fn = () => 'bun-m1';
    const m2Obj = new CustomWidget('bun-m2');
    let m2Seen = null;
    const outerType = mod.checkTypeAfterCallback(m1Fn, () => {
      relayMod.relay(() => {
        m2Seen = mod2.identityObject(m2Obj);
      });
    });
    expect(m2Seen).to.equal(m2Obj);
    expect(String(outerType)).to.equal('function');
    expect(Number(mod.activeCount())).to.equal(0);
    expect(Number(mod2.activeCount())).to.equal(0);
    expect(Number(relayMod.activeCount())).to.equal(0);
  });

  it('should fail fast on Zig background threads and isolate handles across Bun Workers', async function() {
    const obj = new CustomWidget('bun-thread-probe');
    expect(mod.probeOffThreadTryOps(obj, CustomWidget)).to.equal(0x7F);
    expect(Number(mod.activeCount())).to.equal(0);

    let exitCode = 0;
    let stderr = '';
    try {
      await execFileAsync(process.execPath, [ workerScriptPath, '--panic-off-thread' ], { env: process.env });
    } catch (err) {
      exitCode = err.code ?? 1;
      stderr = String(err.stderr ?? '');
    }
    expect(exitCode).to.not.equal(0);
    expect(stderr).to.contain('JsValue operations require the JS thread');

    const mainObj = { owner: 'bun-main' };
    mod.storeGlobal(mainObj);
    const mainRawBits = mod.getSavedRawHandle();
    const mainRealmTag = (mainRawBits >>> 14) & 0x3F;

    const workerResult = await new Promise((resolve, reject) => {
      const worker = new Worker(workerScriptURL, {
        workerData: { samplePath, mainRawBits },
      });
      worker.once('message', resolve);
      worker.once('error', reject);
    });

    expect(workerResult.workerRealmTag).to.not.equal(mainRealmTag);
    expect(workerResult.typeofErr).to.match(/Invalid or released JS value handle/);
    expect(workerResult.releaseErr).to.match(/Invalid or released JS value handle/);
    expect(workerResult.workerActiveCount).to.equal(0);

    expect(() => mod.inspectRawBitsTypeof(workerResult.workerRawBits)).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );
    expect(Object.is(mod.loadGlobalClone(), mainObj)).to.be.true;
    mod.clearGlobal();
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should support 24+ live *const fn (i32) i32 JS callbacks, reclaim released slots, and enforce M1/L1/L2 handle safety on Bun', function() {
    for (let i = 0; i < 24; i++) {
      expect(Number(mod.registerIntFn((x) => (i + 1) * 100 + x))).to.equal(i);
    }
    for (let i = 0; i < 24; i++) {
      expect(mod.callRegisteredIntFn(i, 7)).to.equal((i + 1) * 100 + 7);
    }
    mod.releaseAllRegisteredIntFns();

    let staleIter1 = 0;
    let staleIter4095 = 0;
    for (let i = 1; i <= 10000 || staleIter4095 === 0; i++) {
      const raw = mod.inspectRawHandle({ cycle: i });
      const gen = raw >>> 20;
      expect(gen).to.be.at.least(1);
      expect(gen).to.be.at.most(4095);
      if (i === 1) staleIter1 = raw;
      if (gen === 4095 && staleIter4095 === 0) staleIter4095 = raw;
      if (i > 30000) break;
    }
    const liveAfterChurn = { bunLiveAfter10k: true };
    mod.storeGlobal(liveAfterChurn);
    expect(() => mod.inspectRawBitsTypeof(staleIter1)).to.throw(TypeError, /Invalid or released JS value handle/);
    expect(() => mod.inspectRawBitsTypeof(staleIter4095)).to.throw(TypeError, /Invalid or released JS value handle/);
    expect(Object.is(mod.loadGlobalClone(), liveAfterChurn)).to.be.true;
    mod.clearGlobal();
    expect(Number(mod.activeCount())).to.equal(0);

    expect(() => mod.returnPairWithStaleFirst({ stale: 1 }, { validSibling: 2 })).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );
    expect(Number(mod.activeCount())).to.equal(0);

    mod.storeBorrowedSliceRefs({ a: 1 }, { b: 2 });
    expect(Number(mod.activeCount())).to.equal(2);
    expect(() => mod.returnBorrowedSliceOnHostError(() => {
      throw new RangeError('pending-slice-host-err');
    })).to.throw(RangeError, /pending-slice-host-err/);
    expect(Number(mod.activeCount())).to.equal(2);
    mod.clearBorrowedSliceRefs();
    expect(Number(mod.activeCount())).to.equal(0);
  });
});
