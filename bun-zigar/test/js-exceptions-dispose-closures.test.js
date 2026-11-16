import { expect } from 'chai';

describe('Bun Native JS Exception Bridging, Symbol.dispose/asyncDispose, and Zig Closures (bun-zigar)', function() {
  this.timeout(300000);

  const sampleURL = new URL('../../node-zigar/test/zig-samples/js-value/exceptions-dispose-closures.zig', import.meta.url).href;
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
      throw new TypeError('bad bun arg');
    }).string;
    expect(typeErrSummary).to.equal('type=object|name=TypeError|code=<null>|msg=bad bun arg|stack=yes');

    const fsSummary = mod.inspectNodeFsReadMissingFile('/nonexistent_zigar_issue_37_bun_missing.txt').string;
    expect(fsSummary).to.include('type=object|name=Error|code=ENOENT|');
    expect(fsSummary).to.include('ENOENT');

    const strSummary = mod.inspectThrownException(() => {
      throw 'bun string failure';
    }).string;
    expect(strSummary).to.equal('type=string|name=<null>|code=<null>|msg=bun string failure|stack=no');

    const nullSummary = mod.inspectThrownException(() => {
      throw null;
    }).string;
    expect(nullSummary).to.equal('type=object|name=<null>|code=<null>|msg=<null>|stack=no');

    const undefSummary = mod.inspectThrownException(() => {
      throw undefined;
    }).string;
    expect(undefSummary).to.equal('type=undefined|name=<null>|code=<null>|msg=<null>|stack=no');
  });

  it('should support Symbol.dispose and Symbol.asyncDispose on Bun N-API with zero handle leaks', function() {
    const log = [];
    mod.resetSyncDisposeDeferRuns();

    expect(mod.useResourceWithDeferDispose({
      tag: 'bun-1',
      [Symbol.dispose]() {
        log.push(`sync:${this.tag}`);
      },
    })).to.equal(42);
    expect(log).to.deep.equal([ 'sync:bun-1' ]);
    expect(mod.getSyncDisposeDeferRuns()).to.equal(1);

    const caughtSync = mod.useResourceWithTryDispose({
      [Symbol.dispose]() {
        throw Object.assign(new Error('bun sync close failed'), { code: 'EIO' });
      },
    }).string;
    expect(caughtSync).to.include('type=object|name=Error|code=EIO|msg=bun sync close failed|');

    expect(mod.useResourceWithTryAsyncDispose({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
        log.push('bun-async-ok');
      },
    }).string).to.equal('ok');
    expect(log).to.include('bun-async-ok');

    expect(mod.useResourceWithTryAsyncDispose({
      [Symbol.dispose]() {
        log.push('bun-async-fallback');
      },
    }).string).to.equal('ok');
    expect(log).to.include('bun-async-fallback');

    const caughtAsync = mod.useResourceWithTryAsyncDispose({
      async [Symbol.asyncDispose]() {
        await Promise.resolve();
        throw Object.assign(new Error('bun async reject'), { code: 'EPIPE' });
      },
    }).string;
    expect(caughtAsync).to.include('type=object|name=Error|code=EPIPE|msg=bun async reject|');

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
