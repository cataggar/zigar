import { expect } from 'chai';
import { mkdir, writeFile } from 'fs/promises';
import os from 'os';
import { join, resolve } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';
import { transpile } from '../src/transpilation.js';

const testDir = fileURLToPath(new URL('.', import.meta.url));
const compilerRoot = resolve(testDir, '..');
const runtimeDistUrl = pathToFileURL(resolve(compilerRoot, '../zigar-runtime/dist') + '/').href;

let moduleCounter = 0;

async function compileAndImport(zigPath, options = {}) {
  const {
    memory64 = false,
    useJSPI = false,
    useWazig = true,
    stripWASM = true,
    optimize = 'ReleaseSmall',
    exposeEnv = false,
  } = options;
  const result = await transpile(zigPath, {
    nodeCompat: false,
    embedWASM: true,
    topLevelAwait: true,
    stripWASM,
    optimize,
    memory64,
    useJSPI,
    useWazig,
  });
  const tmpBase = process.env.TMPDIR || os.tmpdir();
  const outDir = join(tmpBase, 'zigar-issue38-test');
  await mkdir(outDir, { recursive: true });
  const mjsPath = join(
    outDir,
    `issue38-${memory64 ? 'wasm64' : 'wasm32'}-${useWazig ? 'wazig' : 'legacy'}-${useJSPI ? 'jspi' : 'sync'}-${++moduleCounter}.mjs`,
  );
  let runnableCode = result.code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${runtimeDistUrl}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${runtimeDistUrl}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${runtimeDistUrl}$2"`);
  if (exposeEnv) {
    runnableCode += '\nexport { env as __debugEnv };\n';
  }
  await writeFile(mjsPath, runnableCode, 'utf-8');
  const mod = await import(pathToFileURL(mjsPath).href);
  return { mod, result };
}

function delayedResolve(ms, value) {
  return new Promise((resolveFn) => setTimeout(() => resolveFn(value), ms));
}

function delayedReject(ms, err) {
  return new Promise((_, rejectFn) => setTimeout(() => rejectFn(err), ms));
}

describe('Standard zigar.js Wrappers: Promise, Binary Views, Collections, Intrinsics & Iterators (WASM32 / WASM64 / JSPI)', function() {
  this.timeout(300000);

  const samplePath = resolve(testDir, './zig-samples/js-value/standard-wrappers.zig');

  const targets = [
    { label: 'wasm32 (useWazig=true, non-JSPI)', memory64: false, useWazig: true, useJSPI: false },
    { label: 'wasm32 (useWazig=true, JSPI)', memory64: false, useWazig: true, useJSPI: true },
    { label: 'wasm64 (useWazig=true, JSPI)', memory64: true, useWazig: true, useJSPI: true },
    { label: 'wasm32 (useWazig=false, JSPI)', memory64: false, useWazig: false, useJSPI: true },
    { label: 'wasm64 (useWazig=false, non-JSPI)', memory64: true, useWazig: false, useJSPI: false },
  ];

  for (const target of targets) {
    describe(`Target: ${target.label}`, function() {
      let mod;
      let debugEnv;

      before(async function() {
        const loaded = await compileAndImport(samplePath, { ...target, exposeEnv: true });
        mod = loaded.mod;
        debugEnv = mod.__debugEnv;
      });

      afterEach(async function() {
        if (mod) {
          expect(Number(await mod.activeCallbacks())).to.equal(0);
          expect(Number(await mod.activeHandles())).to.equal(0);
          expect(Number(await mod.liveZigAllocs())).to.equal(0);
          expect(Boolean(await mod.hasPendingCapturedError())).to.be.false;
          expect(debugEnv.getActiveZigCallbackCount()).to.equal(0);
        }
      });

      it('should construct resolved/rejected/optional Promises and chain .then() / .catchError() with Closure', async function() {
        const pResolved = mod.makeResolvedPromise(21);
        expect(pResolved).to.be.instanceOf(Promise);
        expect(await pResolved).to.equal(21);

        const pMaybeNone = await mod.maybePromise(false, 0);
        expect(pMaybeNone).to.be.null;
        const pMaybeSome = mod.maybePromise(true, 99);
        expect(pMaybeSome).to.be.instanceOf(Promise);
        expect(await pMaybeSome).to.equal(99);

        const pChained = mod.chainPromiseTriple(delayedResolve(5, 13));
        expect(pChained).to.be.instanceOf(Promise);
        expect(await pChained).to.equal(40);

        const pRecovered = mod.chainPromiseRecover(delayedReject(5, new Error('recoverable')));
        expect(pRecovered).to.be.instanceOf(Promise);
        expect(await pRecovered).to.equal(42);

        const pRejected = mod.makeRejectedPromise('zig-reject-msg');
        expect(pRejected).to.be.instanceOf(Promise);
        let caughtReason = null;
        try {
          await pRejected;
        } catch (err) {
          caughtReason = err;
        }
        expect(caughtReason).to.equal('zig-reject-msg');
      });

      it('should perform O(1) bulk transfers across Buffer, TypedArrays, ArrayBuffer, SharedArrayBuffer, and DataView', async function() {
        // 0-length and multi-KB Node Buffer roundtrips + Buffer.isBuffer verification
        const emptyBuf = await mod.createNodeBufferReversed(new Uint8Array(0));
        expect(Buffer.isBuffer(emptyBuf)).to.be.true;
        expect(emptyBuf.byteLength).to.equal(0);
        expect(await mod.checkIsNodeBuffer(emptyBuf)).to.be.true;
        expect(await mod.checkIsNodeBuffer(new Uint8Array(4))).to.be.false;

        const src16k = new Uint8Array(16384);
        for (let i = 0; i < src16k.length; i++) src16k[i] = (i * 17 + 3) & 0xff;
        const revBuf = await mod.createNodeBufferReversed(src16k);
        expect(Buffer.isBuffer(revBuf)).to.be.true;
        expect(revBuf.byteLength).to.equal(16384);
        expect(revBuf[0]).to.equal(src16k[16383]);
        expect(revBuf[16383]).to.equal(src16k[0]);

        const xoredLen = await mod.xorBufferInPlace(revBuf, 0x5a);
        expect(xoredLen).to.equal(16384);
        expect(revBuf[0]).to.equal(src16k[16383] ^ 0x5a);

        expect(await mod.bufferOutOfBoundsWrite(Buffer.alloc(8))).to.be.true;
        expect((await mod.roundtripBufferUtf8('Hello Zigar Buffer!')).string).to.equal('Hello Zigar Buffer!');

        // TypedArrays (0-length, Uint8ClampedArray, Int32Array, Float64Array, BigUint64Array, non-zero byteOffset subarray)
        const taTotal = await mod.typedArraysShowcase();
        expect(taTotal).to.equal((-100 + 50 + 75 + 1000) + (1.5 + 2.25 - 0.75));

        const backing = new Uint8Array([ 99, 99, 10, 20, 30, 40, 88 ]);
        const sub = backing.subarray(2, 6);
        expect(Number(await mod.sumUint8Subarray(sub))).to.equal(100);

        // ArrayBuffer + SharedArrayBuffer + DataView (multi-KB)
        const checksum = Number(await mod.arrayBufferAndSharedRoundtrip(8192));
        let expectedChecksum = 0;
        for (let idx = 4; idx < 8188; idx++) {
          expectedChecksum += (idx * 31 + 7) & 0xff;
        }
        expect(checksum).to.equal(expectedChecksum);
      });

      it('should support Array (with mid-array error cleanup), Map, Set, Record, BigInt, Date, RegExp, and sync Iterator', async function() {
        const mixedBadStrArray = [ 'first-alloc', 'second-alloc', false, 'fourth-alloc' ];
        const arrResult = await mod.arrayRoundtripAndMidErrorCleanup(mixedBadStrArray);
        expect(arrResult).to.equal((5 + 20 + 30) + 3);

        const collSummary = (await mod.collectionsMapSetRecordShowcase()).string;
        expect(collSummary).to.equal('entry_sum=40|map_rem=2|set_sum=18|keys=2|k1=100|k1_after=false');

        const intrinsicSummary = (await mod.bigIntDateRegExpShowcase()).string;
        expect(intrinsicSummary).to.equal('iso=2026-05-01T12:30:00.000Z|match=true|nomatch=false|flags=i');

        // Sync Iterator over generator with early break triggering generator `finally` (`IteratorClose`)
        let generatorClosed = false;
        function* numberGen() {
          try {
            yield 10;
            yield 20;
            yield 30;
            yield 40;
          } finally {
            generatorClosed = true;
          }
        }
        const partialSum = await mod.consumeSyncIteratorEarly(numberGen(), 2);
        expect(partialSum).to.equal(30);
        expect(generatorClosed).to.be.true;
      });

      if (target.useJSPI) {
        it('should suspend via JSPI on Promise.await() for primitives, structs, strings, Refs, void, repeated awaits, and concurrent Promise.all with fiber-isolated takeLastError()', async function() {
          const unhandled = [];
          const onUnhandled = (reason) => unhandled.push(reason);
          process.on('unhandledRejection', onUnhandled);
          try {
            // Repeated .await() on the same Promise without double-freeing
            const sharedP = delayedResolve(10, 77);
            expect(await mod.awaitTwiceAndSum(sharedP)).to.equal(154);

            // Struct, String (allocator), Ref(Object), and void payloads
            expect(await mod.awaitPointSum(delayedResolve(5, { x: 4, y: 9 }))).to.equal(49);
            expect((await mod.awaitUpperString(delayedResolve(5, 'jspi-zigar'))).string).to.equal('JSPI-ZIGAR');
            expect((await mod.awaitRefTag(delayedResolve(5, { tag: 'live-ref-ok' }))).string).to.equal('live-ref-ok');
            expect(await mod.awaitVoidPromise(delayedResolve(5, undefined))).to.equal(204);

            // Rejections with Error (with code), string, and undefined + uninspected rejection
            const rejErrSummary = (await mod.awaitInspectRejection(
              delayedReject(5, Object.assign(new TypeError('bad async input'), { code: 'ERR_ASYNC_BAD' })),
            )).string;
            expect(rejErrSummary).to.equal('type=object|name=TypeError|code=ERR_ASYNC_BAD|msg=bad async input');

            const rejStrSummary = (await mod.awaitInspectRejection(delayedReject(5, 'plain-str-reject'))).string;
            expect(rejStrSummary).to.equal('type=string|name=<null>|code=<null>|msg=plain-str-reject');

            const rejUndefSummary = (await mod.awaitInspectRejection(delayedReject(5, undefined))).string;
            expect(rejUndefSummary).to.equal('type=undefined|name=<null>|code=<null>|msg=<null>');

            expect(await mod.awaitCatchUninspected(delayedReject(5, new Error('ignored-rejection')))).to.equal(-999);

            // Concurrent Promise.all across 5 simultaneous JSPI fibers with interleaved timers & rejections
            const results = await Promise.all([
              mod.awaitAdd(delayedResolve(25, 100), delayedResolve(10, 23)),
              mod.awaitInspectRejection(delayedReject(12, Object.assign(new RangeError('fiber-2-err'), { code: 'E_F2' }))),
              mod.awaitAdd(delayedResolve(5, 400), delayedResolve(20, 50)),
              mod.awaitInspectRejection(delayedReject(18, 'fiber-4-str')),
              mod.awaitCatchUninspected(delayedReject(8, new Error('fiber-5-uninspected'))),
            ]);
            expect(results[0]).to.equal(123);
            expect(results[1].string).to.equal('type=object|name=RangeError|code=E_F2|msg=fiber-2-err');
            expect(results[2]).to.equal(450);
            expect(results[3].string).to.equal('type=string|name=<null>|code=<null>|msg=fiber-4-str');
            expect(results[4]).to.equal(-999);

            await delayedResolve(20, null);
            expect(unhandled).to.deep.equal([]);
          } finally {
            process.off('unhandledRejection', onUnhandled);
          }
        });

        it('should consume AsyncIterator(T) over async function*, handle mid-stream throws, and await .close() early break', async function() {
          let asyncFinallyCompleted = false;
          async function* streamWords(throwAtThird) {
            try {
              await delayedResolve(4, null);
              yield 'alpha';
              await delayedResolve(4, null);
              yield 'beta';
              if (throwAtThird) {
                await delayedResolve(4, null);
                throw new Error('stream-exploded');
              }
              yield 'gamma';
            } finally {
              await delayedResolve(6, null);
              asyncFinallyCompleted = true;
            }
          }

          // Full consumption
          const full = (await mod.consumeAsyncIterator(streamWords(false), 0)).string;
          expect(full).to.equal('alpha,beta,gamma');
          expect(asyncFinallyCompleted).to.be.true;

          // Early break at 2 items awaits async finally cleanup!
          asyncFinallyCompleted = false;
          const early = (await mod.consumeAsyncIterator(streamWords(false), 2)).string;
          expect(early).to.equal('alpha,beta');
          expect(asyncFinallyCompleted).to.be.true;

          // Mid-stream throw surfaces error.JsException + exact message via takeLastError()
          const midErr = (await mod.consumeAsyncIterator(streamWords(true), 0)).string;
          expect(midErr).to.equal('alpha,beta|ERR:stream-exploded');

          // Fallback to sync iterable via ECMAScript GetIterator(obj, async)
          const syncFallback = (await mod.consumeAsyncIterator([ 's1', 's2' ], 0)).string;
          expect(syncFallback).to.equal('s1,s2');
        });
      } else {
        it('should cleanly return HostUnavailable on Promise.await() and AsyncIterator.next() when JSPI is disabled', async function() {
          let pErr = null;
          try {
            await mod.awaitTwiceAndSum(Promise.resolve(10));
          } catch (err) {
            pErr = err;
          }
          expect(pErr).to.be.an('error');
          expect(pErr.message).to.match(/Host unavailable/i);

          let aiErr = null;
          try {
            async function* gen() {
              yield 'x';
            }
            await mod.consumeAsyncIterator(gen(), 0);
          } catch (err) {
            aiErr = err;
          }
          expect(aiErr).to.be.an('error');
          expect(aiErr.message).to.match(/Host unavailable/i);
        });
      }
    });
  }
});
