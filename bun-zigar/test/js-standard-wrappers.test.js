import { expect } from 'chai';

function delayedResolve(ms, value) {
  return new Promise((resolveFn) => setTimeout(() => resolveFn(value), ms));
}

function delayedReject(ms, err) {
  return new Promise((_, rejectFn) => setTimeout(() => rejectFn(err), ms));
}

describe('Bun Native Standard zigar.js Wrappers & WorkQueue Async Promise/AsyncIterator Bridge (bun-zigar)', function() {
  this.timeout(300000);

  const sampleURL = new URL('../../node-zigar/test/zig-samples/js-value/standard-wrappers.zig', import.meta.url).href;
  let mod;
  let queueStarted = false;

  before(async function() {
    global.__test_options = {
      optimize: 'ReleaseSafe',
      quiet: true,
    };
    mod = await import(sampleURL);
  });

  after(async function() {
    if (mod && queueStarted) {
      await mod.shutdown();
      queueStarted = false;
    }
  });

  afterEach(function() {
    if (mod) {
      expect(Number(mod.activeCallbacks())).to.equal(0);
      expect(Number(mod.activeHandles())).to.equal(0);
      expect(Number(mod.liveZigAllocs())).to.equal(0);
      expect(Boolean(mod.hasPendingCapturedError())).to.be.false;
    }
  });

  it('should return HostUnavailable on main-thread synchronous .await() and AsyncIterator.next(), and OffJsThread on raw OS threads', async function() {
    expect(() => mod.mainThreadAwaitReturnsHostUnavailable(Promise.resolve(10)))
      .to.throw(Error)
      .with.property('message')
      .that.matches(/Host unavailable/i);

    async function* gen() {
      yield 1;
    }
    expect(() => mod.mainThreadAsyncIterReturnsHostUnavailable(gen()))
      .to.throw(Error)
      .with.property('message')
      .that.matches(/Host unavailable/i);

    expect(mod.probeRawThreadOffJsThread(Promise.resolve(7))).to.be.true;
  });

  it('should support Promise.resolve/reject/.then/.catchError, Buffer, TypedArrays, Collections, BigInt, Date, RegExp, and Iterator on the main thread', async function() {
    const pResolved = mod.makeResolvedPromise(21);
    expect(pResolved).to.be.instanceOf(Promise);
    expect(await pResolved).to.equal(21);

    expect(mod.maybePromise(false, 0)).to.be.null;
    expect(await mod.maybePromise(true, 88)).to.equal(88);

    const pChained = mod.chainPromiseTriple(delayedResolve(5, 13));
    expect(await pChained).to.equal(40);

    const pRecovered = mod.chainPromiseRecover(delayedReject(5, new Error('recoverable')));
    expect(await pRecovered).to.equal(42);

    const pRejected = mod.makeRejectedPromise('bun-reject-msg');
    let caughtReason = null;
    try {
      await pRejected;
    } catch (err) {
      caughtReason = err;
    }
    expect(caughtReason).to.equal('bun-reject-msg');

    const emptyBuf = mod.createNodeBufferReversed(new Uint8Array(0));
    expect(Buffer.isBuffer(emptyBuf)).to.be.true;
    expect(emptyBuf.byteLength).to.equal(0);
    expect(mod.checkIsNodeBuffer(emptyBuf)).to.be.true;
    expect(mod.checkIsNodeBuffer(new Uint8Array(4))).to.be.false;

    const src16k = new Uint8Array(16384);
    for (let i = 0; i < src16k.length; i++) src16k[i] = (i * 19 + 5) & 0xff;
    const revBuf = mod.createNodeBufferReversed(src16k);
    expect(Buffer.isBuffer(revBuf)).to.be.true;
    expect(revBuf[0]).to.equal(src16k[16383]);
    expect(mod.xorBufferInPlace(revBuf, 0x3c)).to.equal(16384);
    expect(revBuf[0]).to.equal(src16k[16383] ^ 0x3c);
    expect(mod.roundtripBufferUtf8('Bun Zigar Buffer').string).to.equal('Bun Zigar Buffer');

    const checksum = Number(mod.typedArraysAndViewsShowcase(8192));
    let expectedChecksum = 0;
    for (let idx = 4; idx < 8188; idx++) {
      expectedChecksum += (idx * 31 + 7) & 0xff;
    }
    expect(checksum).to.equal(expectedChecksum);

    const summary = mod.collectionsAndIntrinsicsShowcase([ 'a', 'b', false, 'd' ]).string;
    expect(summary).to.equal('set=2|keys=1|iso=2026-05-01T12:30:00.000Z|re=true');

    let closed = false;
    function* numGen() {
      try {
        yield 100;
        yield 200;
        yield 300;
      } finally {
        closed = true;
      }
    }
    expect(mod.consumeSyncIteratorEarly(numGen(), 2)).to.equal(300);
    expect(closed).to.be.true;
  });

  it('should execute Promise.await() across concurrent WorkQueue workers (n_jobs = 4) with worker-isolated takeLastError() and auto-cleanup', async function() {
    await mod.startup(4);
    queueStarted = true;

    expect(mod.probeRawThreadOffJsThread(Promise.resolve(9))).to.be.true;

    const sharedP = delayedResolve(10, 64);
    expect(await mod.workerAwaitTwiceAndSum(sharedP)).to.equal(128);

    expect(await mod.workerAwaitPointSum(delayedResolve(5, { x: 7, y: 8 }))).to.equal(78);
    expect((await mod.workerAwaitUpperString(delayedResolve(5, 'worker-bridge'))).string).to.equal('WORKER-BRIDGE');
    expect((await mod.workerAwaitRefTag(delayedResolve(5, { tag: 'worker-ref-ok' }))).string).to.equal('worker-ref-ok');
    expect(await mod.workerAwaitVoidPromise(delayedResolve(5, undefined))).to.equal(204);

    const concurrent = await Promise.all([
      mod.workerAwaitAdd(delayedResolve(30, 100), delayedResolve(10, 11)),
      mod.workerAwaitInspectRejection(delayedReject(15, Object.assign(new TypeError('w-err-1'), { code: 'EW1' }))),
      mod.workerAwaitAdd(delayedResolve(8, 200), delayedResolve(22, 22)),
      mod.workerAwaitInspectRejection(delayedReject(25, 'w-plain-str-2')),
      mod.workerAwaitCatchUninspected(delayedReject(12, new Error('w-uninspected-3'))),
      mod.workerAwaitInspectRejection(delayedReject(18, undefined)),
      mod.workerAwaitCatchUninspected(delayedReject(6, new Error('w-uninspected-4'))),
      mod.workerAwaitAdd(delayedResolve(14, 300), delayedResolve(16, 33)),
    ]);
    expect(concurrent[0]).to.equal(111);
    expect(concurrent[1].string).to.equal('type=object|name=TypeError|code=EW1|msg=w-err-1');
    expect(concurrent[2]).to.equal(222);
    expect(concurrent[3].string).to.equal('type=string|name=<null>|code=<null>|msg=w-plain-str-2');
    expect(concurrent[4]).to.equal(-999);
    expect(concurrent[5].string).to.equal('type=undefined|name=<null>|code=<null>|msg=<null>');
    expect(concurrent[6]).to.equal(-999);
    expect(concurrent[7]).to.equal(333);

    const cleanChecks = await Promise.all([
      mod.workerVerifyCleanErrorState(),
      mod.workerVerifyCleanErrorState(),
      mod.workerVerifyCleanErrorState(),
      mod.workerVerifyCleanErrorState(),
    ]);
    expect(cleanChecks).to.deep.equal([ true, true, true, true ]);
  });

  it('should support AsyncIterator(T), sync wrappers, and pending Symbol.asyncDispose inside WorkQueue worker threads', async function() {
    let asyncGenFinally = false;
    async function* workerWordStream(shouldThrow) {
      try {
        await delayedResolve(5, null);
        yield 'one';
        await delayedResolve(5, null);
        yield 'two';
        if (shouldThrow) {
          await delayedResolve(5, null);
          throw new Error('worker-stream-boom');
        }
        yield 'three';
      } finally {
        await delayedResolve(8, null);
        asyncGenFinally = true;
      }
    }

    const full = (await mod.workerConsumeAsyncIterator(workerWordStream(false), 0)).string;
    expect(full).to.equal('one,two,three');
    expect(asyncGenFinally).to.be.true;

    asyncGenFinally = false;
    const early = (await mod.workerConsumeAsyncIterator(workerWordStream(false), 2)).string;
    expect(early).to.equal('one,two');
    expect(asyncGenFinally).to.be.true;

    const midErr = (await mod.workerConsumeAsyncIterator(workerWordStream(true), 0)).string;
    expect(midErr).to.equal('one,two|ERR:worker-stream-boom');

    const syncFallback = (await mod.workerConsumeAsyncIterator([ 'sync-a', 'sync-b' ], 0)).string;
    expect(syncFallback).to.equal('sync-a,sync-b');

    let asyncDisposed = false;
    const asyncResource = {
      async [Symbol.asyncDispose ?? Symbol.for('nodejs.asyncDispose')]() {
        await delayedResolve(10, null);
        asyncDisposed = true;
      },
    };
    const workerSummary = (await mod.workerSyncWrappersAndAsyncDispose(asyncResource)).string;
    expect(asyncDisposed).to.be.true;
    expect(workerSummary).to.equal('buf=true|got=15|bi=-12345678901234567890');

    await mod.shutdown();
    queueStarted = false;
  });

  it('should isolate error frames when a worker-bridged JS op synchronously re-enters main-thread Zig exports or closures', async function() {
    await mod.startup(2);
    queueStarted = true;

    const boomObj = {
      boom() {
        throw new Error('inner-boom');
      },
    };

    // 1a. worker -> JS -> sync Zig export calling infallible obj.call("boom"), caught in JS
    let caughtInJs = null;
    const caughtExportVal = await mod.workerNestedSyncReentrancy(() => {
      try {
        return mod.syncCallInfallibleBoom(boomObj);
      } catch (err) {
        caughtInJs = err.message;
        return -77;
      }
    });
    expect(caughtInJs).to.equal('inner-boom');
    expect(caughtExportVal).to.equal(-77);

    // 1b. worker -> JS -> sync Zig export calling infallible obj.call("boom"), uncaught -> propagates as error.JsException
    const propagatedExportMsg = (await mod.workerNestedSyncPropagateError(() => mod.syncCallInfallibleBoom(boomObj))).string;
    expect(propagatedExportMsg).to.equal('inner-boom');

    // 2. worker -> JS -> sync Zig export calling obj.tryCall("boom") catch -1 -> returns -1 with hasLastError() == false on worker
    const recoveredExportVal = await mod.workerNestedSyncReentrancy(() => mod.syncTryCallRecover(boomObj));
    expect(recoveredExportVal).to.equal(-1);

    // 3. Pre-existing worker captured error is preserved (neither overwritten nor evicted) across nested syncTryCallRecover
    const preservedOuterMsg = (await mod.workerNestedPreserveOuterError(
      () => {
        throw new Error('outer-worker-boom');
      },
      () => mod.syncTryCallRecover(boomObj),
    )).string;
    expect(preservedOuterMsg).to.equal('outer-worker-boom');

    // 4. Same guarantees for nested main-thread Zig Closure (`createZigCallback`) invoked from worker-bridged JS op
    const onceBoomCatch = mod.makeOnceClosureInfallibleBoom(boomObj);
    let caughtClosureMsg = null;
    const caughtClosureVal = await mod.workerNestedSyncReentrancy(() => {
      try {
        return onceBoomCatch();
      } catch (err) {
        caughtClosureMsg = err.message;
        return -88;
      }
    });
    expect(caughtClosureMsg).to.equal('inner-boom');
    expect(caughtClosureVal).to.equal(-88);

    const onceBoomProp = mod.makeOnceClosureInfallibleBoom(boomObj);
    const propagatedClosureMsg = (await mod.workerNestedSyncPropagateError(() => onceBoomProp())).string;
    expect(propagatedClosureMsg).to.equal('inner-boom');

    const onceTryRecover = mod.makeOnceClosureTryRecover(boomObj);
    const recoveredClosureVal = await mod.workerNestedSyncReentrancy(() => onceTryRecover());
    expect(recoveredClosureVal).to.equal(-1);

    await mod.shutdown();
    queueStarted = false;
  });
});
