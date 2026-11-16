import { expect } from 'chai';

describe('Native JS Exception Bridging, Symbol.dispose/asyncDispose, and Zig Closures (node-zigar)', function() {
  this.timeout(300000);

  const sampleURL = new URL('./zig-samples/js-value/exceptions-dispose-closures.zig?optimize=ReleaseSafe&quiet=1', import.meta.url);
  let mod;

  before(async function() {
    mod = await import(sampleURL.href);
  });

  afterEach(function() {
    if (mod) {
      expect(Number(mod.activeCallbacks())).to.equal(0);
      expect(Number(mod.activeHandles())).to.equal(0);
      expect(Number(mod.liveBoxAllocs())).to.equal(0);
      expect(Boolean(mod.hasPendingCapturedError())).to.be.false;
    }
  });

  it('should catch 400+ error.JsException throws lazily without allocating or leaking handles when uninspected', function() {
    const caught = mod.catchManyWithoutTakingError((i) => {
      throw Object.assign(new RangeError(`boom-${i}`), { code: 'ERR_RANGE' });
    }, 400);
    expect(caught).to.equal(400);
  });

  it('should inspect TypeError, real node:fs ENOENT, plain objects, strings, null, and undefined via lastError/takeLastError', function() {
    const typeErrSummary = mod.inspectThrownException(() => {
      throw new TypeError('bad native arg');
    }).string;
    expect(typeErrSummary).to.equal('type=object|name=TypeError|code=<null>|msg=bad native arg|stack=yes');

    const fsSummary = mod.inspectNodeFsReadMissingFile('/nonexistent_zigar_issue_37_native_missing.txt').string;
    expect(fsSummary).to.include('type=object|name=Error|code=ENOENT|');
    expect(fsSummary).to.include('ENOENT');
    expect(fsSummary).to.include('|stack=yes');

    const customCodeObj = mod.inspectThrownException(() => {
      throw { name: 'RpcError', code: 503, message: 'unavailable' };
    }).string;
    expect(customCodeObj).to.equal('type=object|name=RpcError|code=503|msg=unavailable|stack=no');

    const strSummary = mod.inspectThrownException(() => {
      throw 'native string failure';
    }).string;
    expect(strSummary).to.equal('type=string|name=<null>|code=<null>|msg=native string failure|stack=no');

    const nullSummary = mod.inspectThrownException(() => {
      throw null;
    }).string;
    expect(nullSummary).to.equal('type=object|name=<null>|code=<null>|msg=<null>|stack=no');

    const undefSummary = mod.inspectThrownException(() => {
      throw undefined;
    }).string;
    expect(undefSummary).to.equal('type=undefined|name=<null>|code=<null>|msg=<null>|stack=no');
  });

  it('should support Symbol.dispose and Symbol.asyncDispose on native N-API with zero handle leaks and intact run-to-completion', async function() {
    const log = [];
    mod.resetSyncDisposeDeferRuns();

    expect(mod.useResourceWithDeferDispose({
      tag: 'native-1',
      [Symbol.dispose]() {
        log.push(`sync:${this.tag}`);
      },
    })).to.equal(42);
    expect(log).to.deep.equal([ 'sync:native-1' ]);
    expect(mod.getSyncDisposeDeferRuns()).to.equal(1);

    expect(mod.useResourceWithTryDispose({}).string).to.equal('ok');
    expect(mod.useResourceWithTryDispose({ [Symbol.dispose]: null }).string).to.equal('ok');

    const caughtSync = mod.useResourceWithTryDispose({
      [Symbol.dispose]() {
        throw Object.assign(new Error('native sync close failed'), { code: 'EIO' });
      },
    }).string;
    expect(caughtSync).to.equal('type=object|name=Error|code=EIO|msg=native sync close failed|stack=yes');

    mod.resetSyncDisposeDeferRuns();
    expect(() => mod.useResourceWithDeferDispose({
      [Symbol.dispose]() {
        throw new Error('native defer dispose boom');
      },
    })).to.throw('native defer dispose boom');
    expect(mod.getSyncDisposeDeferRuns()).to.equal(1);

    // Symbol.asyncDispose: synchronous non-Promise [Symbol.asyncDispose](), [Symbol.dispose]() fallback, and sync throw
    expect(mod.useResourceWithTryAsyncDispose({
      [Symbol.asyncDispose]() {
        log.push('native-sync-async-ok');
      },
    }).string).to.equal('ok');
    expect(log).to.include('native-sync-async-ok');

    expect(mod.useResourceWithTryAsyncDispose({
      [Symbol.dispose]() {
        log.push('native-async-fallback');
      },
    }).string).to.equal('ok');
    expect(log).to.include('native-async-fallback');

    expect(mod.useResourceWithDeferAsyncDispose({
      [Symbol.asyncDispose]() {
        log.push('native-defer-sync-async');
      },
    })).to.equal(77);
    expect(log).to.include('native-defer-sync-async');

    expect(mod.useResourceWithDeferAsyncDispose({
      [Symbol.dispose]() {
        log.push('native-defer-fallback');
      },
    })).to.equal(77);
    expect(log).to.include('native-defer-fallback');

    const caughtSyncAsync = mod.useResourceWithTryAsyncDispose({
      [Symbol.asyncDispose]() {
        throw Object.assign(new Error('native sync asyncDispose throw'), { code: 'EPIPE' });
      },
    }).string;
    expect(caughtSyncAsync).to.equal('type=object|name=Error|code=EPIPE|msg=native sync asyncDispose throw|stack=yes');

    // Promise-returning [Symbol.asyncDispose]() (both resolving and rejecting) on a sync native stack
    // releases handle, returns HostUnavailable, and NEVER causes UnhandledPromiseRejection
    expect(mod.useResourceWithTryAsyncDispose({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
      },
    }).string).to.equal('HostUnavailable');
    expect(Number(mod.activeHandles())).to.equal(0);

    expect(mod.useResourceWithTryAsyncDispose({
      [Symbol.asyncDispose]() {
        return Promise.reject(new Error('native rejected asyncDispose'));
      },
    }).string).to.equal('HostUnavailable');
    expect(Number(mod.activeHandles())).to.equal(0);

    expect(mod.useResourceWithTryAsyncDispose({
      [Symbol.asyncDispose]() {
        return new Promise((resolve) => setTimeout(resolve, 10));
      },
    }).string).to.equal('HostUnavailable');

    // Regression A: process.nextTick MUST NOT run inside synchronous tryAsyncDisp call!
    const orderLog = [];
    process.nextTick(() => orderLog.push('nextTick'));
    orderLog.push('before');
    expect(() => mod.tryAsyncDisp({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
      },
    })).to.throw();
    orderLog.push('after');
    await new Promise((resolve) => setImmediate(resolve));
    expect(orderLog).to.deep.equal([ 'before', 'after', 'nextTick' ]);

    // Regression B: unrelated Promise.reject handled later in the same tick MUST NOT trigger unhandled-rejection crash!
    const pending = Promise.reject(new Error('handled later in same tick'));
    expect(() => mod.tryAsyncDisp({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
      },
    })).to.throw();
    pending.catch(() => {});
    await new Promise((resolve) => setImmediate(resolve));
  });

  it('should support stateful Closure, owned HeapBox, re-entrant .deinit(), and .once() with ABA-safe cleanup', function() {
    const res = mod.exerciseStatefulClosures((addFn, mulFn, ownedFn) => {
      return addFn(7) + mulFn(3) + addFn(4) + ownedFn(10);
    });
    expect(res).to.equal(128);

    let savedOnce = null;
    const emitter = {
      registerOnce(fn) {
        savedOnce = fn;
      },
      fire(x) {
        return savedOnce(x);
      },
      fireAgain(x) {
        return savedOnce(x);
      },
    };
    expect(mod.exerciseOnceClosuresAndAbaSafety(emitter)).to.equal(62);
    expect(() => savedOnce(5)).to.throw(/already been released/);

    // Pre-trampoline JS arg conversion throw on .once() both WITH closure.deinit() and WITHOUT closure.deinit()
    let lastBadOnce = null;
    mod.exerciseOnceConversionErrorCleanup({
      callBadArg(fn) {
        lastBadOnce = fn;
        return fn('not a number');
      },
    });
    expect(() => lastBadOnce(1)).to.throw(/already been released/);

    // Top-level detached .once() closure called with invalid JS arg releases handle, slot, and HeapBox
    const detachedOnce = mod.makeDetachedOnceClosure(33);
    expect(Number(mod.activeHandles())).to.equal(1);
    expect(Number(mod.activeCallbacks())).to.equal(1);
    expect(Number(mod.liveBoxAllocs())).to.equal(1);
    expect(() => detachedOnce('not a number')).to.throw(/Cannot convert/);
    expect(Number(mod.activeHandles())).to.equal(0);
    expect(Number(mod.activeCallbacks())).to.equal(0);
    expect(Number(mod.liveBoxAllocs())).to.equal(0);
    expect(() => detachedOnce(1)).to.throw(/already been released/);
  });
});
