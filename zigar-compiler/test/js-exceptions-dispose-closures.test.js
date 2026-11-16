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
  const outDir = join(tmpBase, 'zigar-issue37-test');
  await mkdir(outDir, { recursive: true });
  const mjsPath = join(
    outDir,
    `issue37-${memory64 ? 'wasm64' : 'wasm32'}-${useWazig ? 'wazig' : 'legacy'}-${useJSPI ? 'jspi' : 'sync'}-${++moduleCounter}.mjs`,
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

describe('JS Exception Bridging, Symbol.dispose/asyncDispose, and Zig Closures (WASM32 / WASM64 / JSPI)', function() {
  this.timeout(300000);

  const samplePath = resolve(testDir, './zig-samples/js-value/exceptions-dispose-closures.zig');

  const targets = [
    { label: 'wasm32 (useWazig=true)', memory64: false, useWazig: true, useJSPI: false },
    { label: 'wasm32 (useWazig=true, JSPI)', memory64: false, useWazig: true, useJSPI: true },
    { label: 'wasm64 (useWazig=true, JSPI)', memory64: true, useWazig: true, useJSPI: true },
    { label: 'wasm32 (useWazig=false)', memory64: false, useWazig: false, useJSPI: false },
    { label: 'wasm64 (useWazig=false)', memory64: true, useWazig: false, useJSPI: false },
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
          expect(Number(await mod.liveBoxAllocs())).to.equal(0);
          expect(Boolean(await mod.hasPendingCapturedError())).to.be.false;
          expect(debugEnv.getActiveZigCallbackCount()).to.equal(0);
        }
      });

      it('should catch 400+ error.JsException throws lazily without allocating or leaking handles when uninspected', async function() {
        const caught = await mod.catchManyWithoutTakingError((i) => {
          throw Object.assign(new RangeError(`boom-${i}`), { code: 'ERR_RANGE' });
        }, 400);
        expect(caught).to.equal(400);
      });

      it('should inspect TypeError, node:fs ENOENT, plain objects, strings, numbers, null, and undefined via lastError/takeLastError', async function() {
        const typeErrSummary = (await mod.inspectThrownException(() => {
          throw new TypeError('bad argument value');
        })).string;
        expect(typeErrSummary).to.equal('type=object|name=TypeError|code=<null>|msg=bad argument value|stack=yes');

        const fsSummary = (await mod.inspectNodeFsReadMissingFile('/nonexistent_zigar_issue_37_missing_file.txt')).string;
        expect(fsSummary).to.include('type=object|name=Error|code=ENOENT|');
        expect(fsSummary).to.include('ENOENT');
        expect(fsSummary).to.include('|stack=yes');

        const customCodeObj = (await mod.inspectThrownException(() => {
          throw { name: 'HttpError', code: 404, message: 'not found' };
        })).string;
        expect(customCodeObj).to.equal('type=object|name=HttpError|code=404|msg=not found|stack=no');

        const strSummary = (await mod.inspectThrownException(() => {
          throw 'plain string failure';
        })).string;
        expect(strSummary).to.equal('type=string|name=<null>|code=<null>|msg=plain string failure|stack=no');

        const nullSummary = (await mod.inspectThrownException(() => {
          throw null;
        })).string;
        expect(nullSummary).to.equal('type=object|name=<null>|code=<null>|msg=<null>|stack=no');

        const undefSummary = (await mod.inspectThrownException(() => {
          throw undefined;
        })).string;
        expect(undefSummary).to.equal('type=undefined|name=<null>|code=<null>|msg=<null>|stack=no');
      });

      it('should support Symbol.dispose via defer dispose() and tryDispose() with zero handle leaks even on throw', async function() {
        const log = [];
        await mod.resetSyncDisposeDeferRuns();

        const out = await mod.useResourceWithDeferDispose({
          tag: 'conn-1',
          [Symbol.dispose]() {
            log.push(`closed:${this.tag}`);
          },
        });
        expect(out).to.equal(42);
        expect(log).to.deep.equal([ 'closed:conn-1' ]);
        expect(await mod.getSyncDisposeDeferRuns()).to.equal(1);

        // Missing or null [Symbol.dispose] is a clean no-op and releases handle
        expect((await mod.useResourceWithTryDispose({})).string).to.equal('ok');
        expect((await mod.useResourceWithTryDispose({ [Symbol.dispose]: null })).string).to.equal('ok');

        // Non-callable [Symbol.dispose] surfaces TypeError via tryDispose() and still releases handle
        const badDisp = (await mod.useResourceWithTryDispose({ [Symbol.dispose]: 123 })).string;
        expect(badDisp).to.include('name=TypeError|code=NotCallable');

        // Throwing [Symbol.dispose] caught via tryDispose()
        const caughtDisp = (await mod.useResourceWithTryDispose({
          [Symbol.dispose]() {
            throw Object.assign(new Error('flush failed'), { code: 'EIO' });
          },
        })).string;
        expect(caughtDisp).to.equal('type=object|name=Error|code=EIO|msg=flush failed|stack=yes');

        // Throwing [Symbol.dispose] inside `defer res.dispose()` runs remaining Zig defers and rethrows to JS
        await mod.resetSyncDisposeDeferRuns();
        let deferDispErr = null;
        try {
          await mod.useResourceWithDeferDispose({
            [Symbol.dispose]() {
              throw new Error('defer dispose boom');
            },
          });
        } catch (err) {
          deferDispErr = err;
        }
        expect(deferDispErr).to.be.an('error');
        expect(deferDispErr.message).to.equal('defer dispose boom');
        expect(await mod.getSyncDisposeDeferRuns()).to.equal(1);
      });

      it('should support Symbol.asyncDispose (microtask, sync fallback, and JSPI timer suspension / sync HostUnavailable)', async function() {
        const log = [];

        if (target.useJSPI) {
          // 1. Microtask-settled async [Symbol.asyncDispose] + fallback [Symbol.dispose]
          const rMicro = await mod.useResourceWithTryAsyncDispose({
            id: 'micro',
            async [Symbol.asyncDispose]() {
              await Promise.resolve();
              log.push(`async:${this.id}`);
            },
          });
          expect(rMicro.string).to.equal('ok');
          expect(log).to.deep.equal([ 'async:micro' ]);

          const rFallback = await mod.useResourceWithTryAsyncDispose({
            id: 'sync-fallback',
            [Symbol.dispose]() {
              log.push(`fallback:${this.id}`);
            },
          });
          expect(rFallback.string).to.equal('ok');
          expect(log).to.deep.equal([ 'async:micro', 'fallback:sync-fallback' ]);

          const rDeferAsync = await mod.useResourceWithDeferAsyncDispose({
            async [Symbol.asyncDispose]() {
              await Promise.resolve();
              log.push('defer-async-ok');
            },
          });
          expect(rDeferAsync).to.equal(77);
          expect(log).to.include('defer-async-ok');

          // 2. Microtask-rejected async [Symbol.asyncDispose]
          const rMicroRej = await mod.useResourceWithTryAsyncDispose({
            async [Symbol.asyncDispose]() {
              await Promise.resolve();
              throw Object.assign(new Error('async close failed'), { code: 'EBADF' });
            },
          });
          expect(rMicroRej.string).to.equal('type=object|name=Error|code=EBADF|msg=async close failed|stack=yes');

          // 3. Timer-resolved & timer-rejected [Symbol.asyncDispose] under JSPI suspension
          const rTimer = await mod.useResourceWithTryAsyncDispose({
            [Symbol.asyncDispose]() {
              return new Promise((resolve) => setTimeout(() => {
                log.push('timer-async-disposed');
                resolve();
              }, 15));
            },
          });
          expect(rTimer.string).to.equal('ok');
          expect(log).to.include('timer-async-disposed');

          const rTimerRej = await mod.useResourceWithTryAsyncDispose({
            [Symbol.asyncDispose]() {
              return new Promise((_, reject) => setTimeout(() => {
                reject(Object.assign(new TypeError('delayed reject'), { code: 'ETIMEDOUT' }));
              }, 15));
            },
          });
          expect(rTimerRej.string).to.equal('type=object|name=TypeError|code=ETIMEDOUT|msg=delayed reject|stack=yes');

          // Defer `asyncDispose()` rejecting after timer propagates rejection cleanly to JS Promise!
          await mod.resetSyncDisposeDeferRuns();
          let deferErr = null;
          try {
            await mod.useResourceWithDeferAsyncDispose({
              [Symbol.asyncDispose]() {
                return new Promise((_, reject) => setTimeout(() => reject(new Error('delayed defer boom')), 10));
              },
            });
          } catch (err) {
            deferErr = err;
          }
          expect(deferErr).to.be.an('error');
          expect(deferErr.message).to.equal('delayed defer boom');
          expect(await mod.getSyncDisposeDeferRuns()).to.equal(1);
        } else {
          // Synchronous non-JSPI stack: microtask-settled async [Symbol.asyncDispose] & [Symbol.dispose] fallback work synchronously!
          const rMicro = mod.useResourceWithTryAsyncDispose({
            id: 'micro',
            async [Symbol.asyncDispose]() {
              await Promise.resolve();
              log.push(`async:${this.id}`);
            },
          });
          expect(rMicro.string).to.equal('ok');
          expect(log).to.deep.equal([ 'async:micro' ]);

          const rFallback = mod.useResourceWithTryAsyncDispose({
            id: 'sync-fallback',
            [Symbol.dispose]() {
              log.push(`fallback:${this.id}`);
            },
          });
          expect(rFallback.string).to.equal('ok');
          expect(log).to.deep.equal([ 'async:micro', 'fallback:sync-fallback' ]);

          const rDeferAsync = mod.useResourceWithDeferAsyncDispose({
            async [Symbol.asyncDispose]() {
              await Promise.resolve();
              log.push('defer-async-ok');
            },
          });
          expect(rDeferAsync).to.equal(77);
          expect(log).to.include('defer-async-ok');

          const rMicroRej = mod.useResourceWithTryAsyncDispose({
            async [Symbol.asyncDispose]() {
              await Promise.resolve();
              throw Object.assign(new Error('async close failed'), { code: 'EBADF' });
            },
          });
          expect(rMicroRej.string).to.equal('type=object|name=Error|code=EBADF|msg=async close failed|stack=yes');

          // Non-JSPI sync stack: timer Promise returns HostUnavailable immediately without deadlocking or leaking handles
          const rSyncTimer = mod.useResourceWithTryAsyncDispose({
            [Symbol.asyncDispose]() {
              return new Promise((resolve) => setTimeout(resolve, 10));
            },
          });
          expect(rSyncTimer.string).to.equal('HostUnavailable');

          // Inside a V8 microtask continuation where V8 forbids nested PerformMicrotaskCheckpoint, returns HostUnavailable cleanly
          const nestedMicroResult = await Promise.resolve().then(() => mod.useResourceWithTryAsyncDispose({
            async [Symbol.asyncDispose]() {
              await Promise.resolve();
            },
          }));
          expect(nestedMicroResult.string).to.equal('HostUnavailable');
        }
      });

      it('should support stateful Closure, owned HeapBox, re-entrant .deinit(), and .once() with ABA-safe cleanup', async function() {
        const res = await mod.exerciseStatefulClosures((addFn, mulFn, ownedFn) => {
          // counter starts at 5: add(7) -> 12, mul(3) -> 36, add(4) -> 40; owned(10) -> 37
          const a = addFn(7);
          const b = mulFn(3);
          const c = addFn(4);
          const d = ownedFn(10);
          return a + b + c + d; // 12 + 36 + 40 + 37 = 125 (+ 3 calls = 128)
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
        expect(await mod.exerciseOnceClosuresAndAbaSafety(emitter)).to.equal(62);
        expect(() => savedOnce(5)).to.throw(/already been released/);
      });

      if (target.useJSPI) {
        it('should isolate pending takeLastError() across concurrent suspended JSPI fibers without cross-contamination', async function() {
          const [ s1, s2, s3 ] = await Promise.all([
            mod.fiberThrowSuspendAndInspect(
              () => {
                throw Object.assign(new Error('fiber-one-missing'), { code: 'ENOENT' });
              },
              () => new Promise((resolve) => setTimeout(() => resolve(1), 20)),
            ),
            mod.fiberThrowSuspendAndInspect(
              () => {
                throw Object.assign(new TypeError('fiber-two-denied'), { code: 'EACCES' });
              },
              () => new Promise((resolve) => setTimeout(() => resolve(2), 5)),
            ),
            mod.fiberThrowSuspendAndInspect(
              () => {
                throw 'fiber-three-primitive';
              },
              () => new Promise((resolve) => setTimeout(() => resolve(3), 12)),
            ),
          ]);

          expect(s1.string).to.equal('type=object|name=Error|code=ENOENT|msg=fiber-one-missing|stack=yes');
          expect(s2.string).to.equal('type=object|name=TypeError|code=EACCES|msg=fiber-two-denied|stack=yes');
          expect(s3.string).to.equal('type=string|name=<null>|code=<null>|msg=fiber-three-primitive|stack=no');
        });
      }
    });
  }
});
