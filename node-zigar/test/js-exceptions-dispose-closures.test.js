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

  it('should support Symbol.dispose and Symbol.asyncDispose on native N-API with zero handle leaks', function() {
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

    // Symbol.asyncDispose: microtask settlement, [Symbol.dispose] fallback, rejection capture, and non-deadlocking timer fallback
    expect(mod.useResourceWithTryAsyncDispose({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
        await Promise.resolve();
        log.push('native-async-ok');
      },
    }).string).to.equal('ok');
    expect(log).to.include('native-async-ok');

    expect(mod.useResourceWithTryAsyncDispose({
      [Symbol.dispose]() {
        log.push('native-async-fallback');
      },
    }).string).to.equal('ok');
    expect(log).to.include('native-async-fallback');

    expect(mod.useResourceWithDeferAsyncDispose({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
        log.push('native-defer-async');
      },
    })).to.equal(77);
    expect(log).to.include('native-defer-async');

    const caughtAsync = mod.useResourceWithTryAsyncDispose({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
        throw Object.assign(new Error('native async reject'), { code: 'EPIPE' });
      },
    }).string;
    expect(caughtAsync).to.equal('type=object|name=Error|code=EPIPE|msg=native async reject|stack=yes');

    expect(mod.useResourceWithTryAsyncDispose({
      [Symbol.asyncDispose]() {
        return new Promise((resolve) => setTimeout(resolve, 10));
      },
    }).string).to.equal('HostUnavailable');
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
  });
});
