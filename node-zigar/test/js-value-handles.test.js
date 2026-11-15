import { expect } from 'chai';
import { execFile } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { Worker } from 'node:worker_threads';
import { load } from '../dist/index.js';

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

describe('Native JsValue Handle Registry & zigar.js.Ref(T) Integration', function() {
  this.timeout(300000);

  const sampleURL = new URL('./zig-samples/js-value/handles.zig?optimize=ReleaseSafe&quiet=1', import.meta.url);
  const debugSampleURL = new URL('./zig-samples/js-value/handles.zig?optimize=Debug&quiet=1', import.meta.url);
  const loaderPath = fileURLToPath(new URL('../dist/index.js', import.meta.url));
  const cjsEntryPath = fileURLToPath(new URL('../dist/index.cjs', import.meta.url));
  const sampleFilePath = fileURLToPath(new URL('./zig-samples/js-value/handles.zig', import.meta.url));

  let mod;

  before(async function() {
    mod = await import(sampleURL.href);
  });

  afterEach(function() {
    if (mod) {
      mod.clearGlobal();
      expect(Number(mod.activeCount())).to.equal(0);
    }
  });

  it('should generate clean native loader code without broken zigar-runtime subpath imports', async function() {
    const { source } = await load(sampleURL.href, {}, () => {});
    expect(source).to.contain('node-zigar-addon');
    expect(source).to.not.contain('features/js-value-registry.js');
    expect(source).to.not.contain('structures/js-value.js');
  });

  it('should preserve exact Object.is identity across native N-API roundtrips with zero leaked slots', function() {
    const plain = { nested: { count: 42 } };
    const widget = new CustomWidget('alpha');
    const map = new Map([['k', 'v']]);
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const proxied = new Proxy({ secret: 99 }, {
      get(obj, prop) {
        return prop === 'doubled' ? obj.secret * 2 : Reflect.get(obj, prop);
      },
    });
    const fn = function compute(x, y) { return x + y; };
    const sym = Symbol('unique-token');
    const sharedSym = Symbol.for('zigar.native.jsvalue.shared');

    for (const candidate of [
      plain,
      widget,
      map,
      bytes,
      proxied,
      fn,
      sym,
      sharedSym,
      'hello world',
      0,
      -0,
      NaN,
      3.141592653589793,
      9007199254740993n,
      true,
      false,
      null,
      undefined,
      globalThis,
    ]) {
      const out = mod.identity(candidate);
      expect(Object.is(out, candidate)).to.be.true;
      expect(Number(mod.activeCount())).to.equal(0);
    }

    expect(mod.identityObject(widget)).to.equal(widget);
    expect(mod.identityObject(widget) instanceof CustomWidget).to.be.true;
    expect(mod.identityObject(widget).describe()).to.equal('widget:alpha');
    expect(mod.identityObject(proxied).doubled).to.equal(198);
    expect(mod.identitySymbol(sym)).to.equal(sym);
    expect(mod.identityFunction(fn)(19, 23)).to.equal(42);
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should use reserved constant slots 0..4 without dynamic allocation', function() {
    expect(mod.getUndefined()).to.be.undefined;
    expect(mod.getNull()).to.be.null;
    expect(mod.getBool(false)).to.equal(false);
    expect(mod.getBool(true)).to.equal(true);
    expect(mod.getGlobalThis()).to.equal(globalThis);

    expect(mod.inspectRawHandle(undefined)).to.equal(0);
    expect(mod.inspectRawHandle(null)).to.equal(1);
    expect(mod.inspectRawHandle(false)).to.equal(2);
    expect(mod.inspectRawHandle(true)).to.equal(3);
    expect(mod.inspectRawHandle(globalThis)).to.equal(4);

    expect(mod.inspectPredicates(undefined)).to.equal(1 | 4 | 8);
    expect(mod.inspectPredicates(null)).to.equal(2 | 4 | 8);
    expect(mod.inspectPredicates(false)).to.equal(8);
    expect(mod.inspectPredicates(true)).to.equal(8);
    expect(mod.inspectPredicates(globalThis)).to.equal(8);
    expect(mod.inspectPredicates({ dynamic: true })).to.equal(0);
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should report typeof, instanceof, Object.is equality, and fallible try* methods accurately on the JS thread', function() {
    expect(mod.checkIsJsThread()).to.be.true;

    expect(String(mod.inspectTypeof(undefined))).to.equal('undefined');
    expect(String(mod.inspectTypeof(null))).to.equal('object');
    expect(String(mod.inspectTypeof({}))).to.equal('object');
    expect(String(mod.inspectTypeof(true))).to.equal('boolean');
    expect(String(mod.inspectTypeof(123))).to.equal('number');
    expect(String(mod.inspectTypeof(123n))).to.equal('bigint');
    expect(String(mod.inspectTypeof('abc'))).to.equal('string');
    expect(String(mod.inspectTypeof(Symbol('s')))).to.equal('symbol');
    expect(String(mod.inspectTypeof(() => {}))).to.equal('function');

    const sub = new SubWidget('beta');
    expect(mod.checkInstanceof(sub, SubWidget)).to.be.true;
    expect(mod.checkInstanceof(sub, CustomWidget)).to.be.true;
    expect(mod.checkInstanceof(sub, Map)).to.be.false;
    expect(mod.checkInstanceof('not-an-object', CustomWidget)).to.be.false;

    const sameRef = { id: 1 };
    expect(mod.checkEqual(sameRef, sameRef)).to.be.true;
    expect(mod.checkEqual({ id: 1 }, { id: 1 })).to.be.false;
    expect(mod.checkEqual(NaN, NaN)).to.be.true;
    expect(mod.checkEqual(+0, -0)).to.be.false;

    const casted = mod.castAndClone(sub);
    expect(Object.is(casted, sub)).to.be.true;

    expect(mod.exerciseTryOpsOnMainThread(sub, CustomWidget)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should persist handles across native N-API calls and clone cleanly without dangling napi_handle_scope locals', function() {
    const firstObj = new CustomWidget('persisted-1');
    const secondObj = new CustomWidget('persisted-2');

    mod.storeGlobal(firstObj);
    expect(Number(mod.activeCount())).to.equal(1);

    for (let i = 0; i < 50; i++) {
      const loaded = mod.loadGlobalClone();
      expect(Object.is(loaded, firstObj)).to.be.true;
    }
    expect(Number(mod.activeCount())).to.equal(1);

    mod.storeGlobal(secondObj);
    expect(Number(mod.activeCount())).to.equal(1);
    expect(Object.is(mod.loadGlobalClone(), secondObj)).to.be.true;

    mod.clearGlobal();
    expect(Number(mod.activeCount())).to.equal(0);

    // Churn 10,000 clone/typeof/eql/deinit/activeHandleCount calls inside a single native N-API call
    const target = { churnTarget: true };
    const distinct = { churnTarget: false };
    const matched = mod.churnHandlesInSingleCall(target, distinct, 10000);
    expect(matched).to.equal(10000);
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should marshal composite structs, optionals, error unions, arrays, and tagged unions leak-free', function() {
    const left = { side: 'left' };
    const right = Symbol('right');

    const swapped = mod.swapPair({ first: left, second: right });
    expect(Object.is(swapped.first, right)).to.be.true;
    expect(Object.is(swapped.second, left)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    const kept = mod.maybePass(true, left);
    expect(Object.is(kept, left)).to.be.true;
    expect(mod.maybePass(false, left)).to.be.null;
    expect(Number(mod.activeCount())).to.equal(0);

    const okVal = mod.tryPass(false, left);
    expect(Object.is(okVal, left)).to.be.true;
    expect(() => mod.tryPass(true, left)).to.throw(/Rejected/);
    expect(Number(mod.activeCount())).to.equal(0);

    const reversed = mod.reversePairArray([left, right]);
    expect(Object.is(reversed[0], right)).to.be.true;
    expect(Object.is(reversed[1], left)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    const taggedJs = mod.wrapTagged(true, left, 0);
    expect(Object.is(taggedJs.js, left)).to.be.true;
    const taggedCode = mod.wrapTagged(false, left, 77);
    expect(taggedCode.code).to.equal(77);
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should borrow Ref(T) arguments passed to JS callbacks, retain composite args across wraparound, and propagate callback errors', function() {
    const targetObj = new CustomWidget('callback-target');
    const derivedObj = { wrapped: targetObj };
    let seenInsideCallback;

    const returned = mod.callWithBorrowedRef(targetObj, (arg) => {
      seenInsideCallback = arg;
      expect(Number(mod.activeCount())).to.equal(1);
      return derivedObj;
    });
    expect(Object.is(seenInsideCallback, targetObj)).to.be.true;
    expect(Object.is(returned, derivedObj)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    const objA = new CustomWidget('retained-A');
    const objB = { kind: 'retained-B' };
    let savedPair;
    let savedArr;
    let savedTagged;
    mod.callWithBorrowedComposites(objA, objB, (pair, arr, tagged) => {
      savedPair = pair;
      savedArr = arr;
      savedTagged = tagged;
      expect(Number(mod.activeCount())).to.equal(2);
    });
    expect(Number(mod.activeCount())).to.equal(0);

    for (let i = 0; i < 4100; i++) {
      mod.inspectRawHandle({ churn: i });
    }
    expect(Number(mod.activeCount())).to.equal(0);
    expect(Object.is(savedPair.first, objA)).to.be.true;
    expect(Object.is(savedPair.second, objB)).to.be.true;
    expect(Object.is(savedArr[0], objA)).to.be.true;
    expect(Object.is(savedArr[1], objB)).to.be.true;
    expect(Object.is(savedTagged.js, objA)).to.be.true;

    const inputObj = new CustomWidget('fallible-input');
    const outputObj = { ok: true };
    const ok = mod.callFallibleCallback(inputObj, (arg) => {
      expect(Object.is(arg, inputObj)).to.be.true;
      return outputObj;
    });
    expect(Object.is(ok, outputObj)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    expect(() => mod.callFallibleCallback(inputObj, () => {
      throw new Error('Rejected');
    })).to.throw(/Rejected/);
    expect(Number(mod.activeCount())).to.equal(0);

    expect(() => mod.callFallibleCallback(inputObj, () => {
      throw new TypeError('boom');
    })).to.throw(/Unexpected/);
    expect(Number(mod.activeCount())).to.equal(0);

    const origConsoleError = console.error;
    console.error = () => {};
    try {
      expect(() => mod.callFallibleCompositeCallback(inputObj, () => ({
        ref: { shouldBeRolledBack: true },
        num: 'invalid-uint',
      }))).to.throw(/Unexpected/);
      expect(Number(mod.activeCount())).to.equal(0);
    } finally {
      console.error = origConsoleError;
    }

    expect(() => mod.takeRefAndUint({ outboundRollback: true }, 'not-a-uint')).to.throw(Error);
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should reuse freed slots, trap on double-deinit or ABA stale handles, and still run defer cleanup while JS exceptions are pending', function() {
    const raw1 = mod.inspectRawHandle({ seq: 1 });
    const raw2 = mod.inspectRawHandle({ seq: 2 });
    const raw3 = mod.inspectRawHandle({ seq: 3 });

    const slot1 = raw1 & 0x3FFF;
    const slot2 = raw2 & 0x3FFF;
    const slot3 = raw3 & 0x3FFF;
    const gen1 = raw1 >>> 20;
    const gen2 = raw2 >>> 20;
    const gen3 = raw3 >>> 20;

    expect(slot1).to.be.at.least(8);
    expect(slot2).to.equal(slot1);
    expect(slot3).to.equal(slot1);
    expect(gen2).to.equal(gen1 + 1);
    expect(gen3).to.equal(gen2 + 1);

    expect(() => mod.triggerDoubleDeinit({ doomed: true })).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );
    expect(Number(mod.activeCount())).to.equal(0);

    // Verify `defer valid_guard.deinit()` still releases valid handles even while a JS TypeError is pending!
    expect(() => mod.triggerStaleUseWithValidDefer({ stale: true }, { validGuard: true })).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );
    expect(Number(mod.activeCount())).to.equal(0);

    const replacement = { replacement: true };
    expect(() => mod.triggerAbaStaleUse({ stale: true }, replacement)).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );
    expect(Number(mod.activeCount())).to.equal(1);
    expect(Object.is(mod.loadGlobalClone(), replacement)).to.be.true;
    mod.clearGlobal();
    expect(Number(mod.activeCount())).to.equal(0);
  });

  it('should sync mutations and release borrowed handles for pointer, slice, and exported Zig globals (including Debug 0xaa)', async function() {
    const objA = { a: 1 };
    const objB = { b: 2 };
    const objC = new CustomWidget('replaced');
    const objD = { d: 4 };

    const pair = new mod.Pair({ first: objA, second: objB });
    expect(Number(mod.activeCount())).to.equal(0);
    mod.setFirst(pair, objC);
    expect(Object.is(pair.first, objC)).to.be.true;
    expect(Object.is(pair.second, objB)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    mod.swapInPlace(pair);
    expect(Object.is(pair.first, objB)).to.be.true;
    expect(Object.is(pair.second, objC)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    const taken = mod.takeFirstAndSet(pair, objD);
    expect(Object.is(taken, objB)).to.be.true;
    expect(Object.is(pair.first, objD)).to.be.true;
    expect(Object.is(pair.second, objC)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    const m = new mod.Mixed({ ref: objA, num: 1 });
    mod.setNum(m, 42);
    expect(m.num).to.equal(42);
    expect(Object.is(m.ref, objA)).to.be.true;
    mod.setMixedBoth(m, objC, 99);
    expect(m.num).to.equal(99);
    expect(Object.is(m.ref, objC)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    expect(String(mod.ptrFirstType({ first: objA, second: objB }))).to.equal('object');
    expect(String(mod.ptrFirstType(new mod.Pair({ first: () => {}, second: objB })))).to.equal('function');
    expect(Number(mod.sliceLen([ objA, 'str', 123, null, undefined ]))).to.equal(5);
    expect(Number(mod.activeCount())).to.equal(0);

    const mutSlice = new mod.RefSlice([ objA, objB ]);
    mod.sliceReplaceElem(mutSlice, 1, objC);
    expect(Object.is(mutSlice[0], objA)).to.be.true;
    expect(Object.is(mutSlice[1], objC)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    const tagged = new mod.TaggedValue({ js: objA });
    mod.switchTaggedToCode(tagged, 777);
    expect(tagged.code).to.equal(777);
    expect(Number(mod.activeCount())).to.equal(0);

    const asyncPair = new mod.Pair({ first: objA, second: objB });
    mod.callAsyncMutatePair(asyncPair, objD, (cur) => {
      expect(Object.is(cur, objA)).to.be.true;
      return objC;
    });
    expect(Object.is(asyncPair.first, objC)).to.be.true;
    expect(Object.is(asyncPair.second, objD)).to.be.true;
    expect(Number(mod.activeCount())).to.equal(0);

    // Exported Zig variables, 0xaa poisoned uninit globals, ABA stale uninit_ref, and nested TaggedValue
    for (const poison of [ false, true ]) {
      if (poison) mod.poisonUninitVarsWith0xAA();
      mod.default.uninit_ref = objA;
      expect(Object.is(mod.default.uninit_ref, objA)).to.be.true;
      expect(Number(mod.activeCount())).to.equal(1);
      mod.default.uninit_ref = objB;
      expect(Object.is(mod.default.uninit_ref, objB)).to.be.true;
      expect(Number(mod.activeCount())).to.equal(1);
      mod.default.uninit_ref = undefined;
      expect(Number(mod.activeCount())).to.equal(0);

      mod.default.uninit_pair = { first: objA, second: objB };
      expect(Number(mod.activeCount())).to.equal(2);
      mod.default.uninit_pair = { first: undefined, second: null };
      expect(Number(mod.activeCount())).to.equal(0);

      mod.default.uninit_tagged = { js: objA };
      expect(Number(mod.activeCount())).to.equal(1);
      mod.default.uninit_tagged = { code: 123 };
      expect(Number(mod.activeCount())).to.equal(0);
    }

    const zigOwned = new CustomWidget('zig-owned-aba');
    mod.leaveStaleDeinitInUninitRefAndReuseSlot({ doomed: true }, zigOwned);
    expect(Number(mod.activeCount())).to.equal(1);
    mod.default.uninit_ref = objA;
    expect(Number(mod.activeCount())).to.equal(2);
    expect(Object.is(mod.loadGlobalClone(), zigOwned)).to.be.true;
    mod.default.uninit_ref = undefined;
    mod.clearGlobal();
    expect(Number(mod.activeCount())).to.equal(0);

    mod.zigSetOptTaggedJs(objA);
    expect(Number(mod.activeCount())).to.equal(1);
    mod.default.opt_tagged = null;
    expect(Number(mod.activeCount())).to.equal(0);

    mod.zigSetEuTaggedJs(objA);
    expect(Number(mod.activeCount())).to.equal(1);
    mod.default.eu_tagged = new Error('Rejected');
    expect(() => mod.default.eu_tagged).to.throw(/Rejected/);
    expect(Number(mod.activeCount())).to.equal(0);

    mod.zigSetWrapperJs(objA, 5);
    expect(Number(mod.activeCount())).to.equal(1);
    mod.default.wrapper = { n: 6 };
    expect(mod.default.wrapper.t.code).to.equal(0);
    expect(Number(mod.activeCount())).to.equal(0);

    mod.zigSetOuterNestedJs(objA);
    expect(Number(mod.activeCount())).to.equal(1);
    mod.default.outer_union = { plain: 7 };
    expect(Number(mod.activeCount())).to.equal(0);

    // Real Zig Debug-mode 0xaa uninitialized globals
    const debugMod = await import(debugSampleURL.href);
    debugMod.default.uninit_ref = objA;
    expect(Object.is(debugMod.default.uninit_ref, objA)).to.be.true;
    expect(Number(debugMod.activeCount())).to.equal(1);
    debugMod.default.uninit_ref = undefined;
    expect(Number(debugMod.activeCount())).to.equal(0);
  });

  it('should work identically via CommonJS require() and under DISABLE_EXTERNAL_BUFFER=1 fallback sync', async function() {
    const require = createRequire(import.meta.url);
    require(cjsEntryPath);
    const cjsMod = require(`${sampleFilePath}?optimize=ReleaseSafe&recompile=0&quiet=1`);
    const cjsObj = new CustomWidget('cjs-widget');
    expect(Object.is(cjsMod.identityObject(cjsObj), cjsObj)).to.be.true;
    expect(Number(cjsMod.activeCount())).to.equal(0);

    // Spawn child Node process with DISABLE_EXTERNAL_BUFFER=1 to verify [FALLBACK] shadow-buffer synchronization
    const script = `
      import { pathToFileURL } from 'node:url';
      const mod = await import(pathToFileURL(${JSON.stringify(sampleFilePath)}).href + '?optimize=ReleaseSafe&recompile=0&quiet=1');
      const a = { k: 'a' };
      const b = { k: 'b' };
      mod.default.exported_ref = a;
      if (mod.default.exported_ref !== a || Number(mod.activeCount()) !== 1) throw new Error('exported_ref mismatch');
      mod.default.exported_ref = b;
      if (mod.default.exported_ref !== b || Number(mod.activeCount()) !== 1) throw new Error('exported_ref overwrite leak');
      mod.default.exported_ref = null;
      const p = new mod.Pair({ first: a, second: b });
      const taken = mod.takeFirstAndSet(p, { k: 'c' });
      if (taken !== a || p.second !== b || Number(mod.activeCount()) !== 0) throw new Error('pointer fallback sync failed');
      console.log('FALLBACK_OK');
    `;
    const { stdout } = await execFileAsync(
      process.execPath,
      [ `--loader=${loaderPath}`, '--no-warnings', '--input-type=module', '-e', script ],
      { env: { ...process.env, DISABLE_EXTERNAL_BUFFER: '1' } },
    );
    expect(stdout).to.contain('FALLBACK_OK');
  });

  it('should fail fast on Zig background threads (error.OffJsThread for try* and @panic for infallible methods)', async function() {
    // 1. In-process background thread probe: all 6 fallible `try*` ops + `!js.isJsThread()` fail fast cleanly
    const obj = new CustomWidget('off-thread-probe');
    const mask = mod.probeOffThreadTryOps(obj, CustomWidget);
    expect(mask).to.equal(0x7F);
    expect(Number(mod.activeCount())).to.equal(0);

    // 2. Subprocess infallible background thread call: panics cleanly with clear message instead of V8 segfault
    const panicScript = `
      import { pathToFileURL } from 'node:url';
      const mod = await import(pathToFileURL(${JSON.stringify(sampleFilePath)}).href + '?optimize=ReleaseSafe&recompile=0&quiet=1');
      mod.triggerOffThreadPanic({ panicTest: true });
    `;
    let exitCode = 0;
    let stderr = '';
    try {
      await execFileAsync(
        process.execPath,
        [ `--loader=${loaderPath}`, '--no-warnings', '--input-type=module', '-e', panicScript ],
        { env: process.env },
      );
    } catch (err) {
      exitCode = err.code ?? 1;
      stderr = String(err.stderr ?? '');
    }
    expect(exitCode).to.not.equal(0);
    expect(stderr).to.contain('JsValue operations require the JS thread');
  });

  it('should isolate handles across Node worker_threads realms and throw InvalidJsValueHandle on cross-worker dereference', async function() {
    const mainObj = { owner: 'main-thread' };
    mod.storeGlobal(mainObj);
    const mainRawBits = mod.getSavedRawHandle();
    const mainRealmTag = (mainRawBits >>> 14) & 0x3F;
    expect(Number(mod.activeCount())).to.equal(1);

    const workerCode = `
      import { parentPort, workerData } from 'node:worker_threads';
      import { pathToFileURL } from 'node:url';

      const wMod = await import(pathToFileURL(workerData.sampleFilePath).href + '?optimize=ReleaseSafe&recompile=0&quiet=1');
      const workerObj = { owner: 'worker-thread' };
      const workerRawBits = wMod.inspectRawHandle(workerObj);

      // Allocate a live handle in Worker's own slot 8 so slot index & generation collide with main thread!
      const liveWorkerObj = { liveInWorkerSlot8: true };
      const clonedInWorker = wMod.identityObject(liveWorkerObj);
      if (clonedInWorker !== liveWorkerObj) throw new Error('worker identity failed');

      let typeofErr = null;
      try {
        wMod.inspectRawBitsTypeof(workerData.mainRawBits);
      } catch (err) {
        typeofErr = err.message;
      }

      let releaseErr = null;
      try {
        wMod.releaseRawBits(workerData.mainRawBits);
      } catch (err) {
        releaseErr = err.message;
      }

      parentPort.postMessage({
        workerRawBits,
        workerRealmTag: (workerRawBits >>> 14) & 0x3F,
        typeofErr,
        releaseErr,
        workerActiveCount: Number(wMod.activeCount()),
      });
    `;

    const workerResult = await new Promise((resolve, reject) => {
      const worker = new Worker(workerCode, {
        eval: true,
        workerData: { sampleFilePath, mainRawBits },
        execArgv: [ `--loader=${loaderPath}`, '--no-warnings' ],
      });
      worker.once('message', resolve);
      worker.once('error', reject);
    });

    expect(workerResult.workerRealmTag).to.not.equal(mainRealmTag);
    expect(workerResult.typeofErr).to.match(/Invalid or released JS value handle/);
    expect(workerResult.releaseErr).to.match(/Invalid or released JS value handle/);
    expect(workerResult.workerActiveCount).to.equal(0);

    // Passing Worker's raw handle bits back to main thread must ALSO throw InvalidJsValueHandle!
    expect(() => mod.inspectRawBitsTypeof(workerResult.workerRawBits)).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );
    expect(() => mod.releaseRawBits(workerResult.workerRawBits)).to.throw(
      TypeError,
      /Invalid or released JS value handle/,
    );

    // Main thread's live handle in slot 8 remains completely uncorrupted
    expect(Object.is(mod.loadGlobalClone(), mainObj)).to.be.true;
    mod.clearGlobal();
    expect(Number(mod.activeCount())).to.equal(0);
  });
});
