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
  const outDir = join(tmpBase, 'zigar-jshostop-test');
  await mkdir(outDir, { recursive: true });
  const mjsPath = join(
    outDir,
    `jshostop-${memory64 ? 'wasm64' : 'wasm32'}-${useWazig ? 'wazig' : 'legacy'}-${useJSPI ? 'jspi' : 'sync'}-${++moduleCounter}.mjs`,
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

describe('Table-Driven JS Host-Op Dispatcher & Dynamic Zig Callbacks (WASM32 / WASM64 / JSPI)', function() {
  this.timeout(300000);

  const samplePath = resolve(testDir, './zig-samples/js-value/host-ops.zig');
  const plainZigPath = resolve(testDir, './zig-samples/basic/integers.zig');

  it('should tree-shake js-host-op.js completely when a Zig module does not use zigar.js host operations', async function() {
    const plain = await transpile(plainZigPath, {
      nodeCompat: false,
      embedWASM: true,
      topLevelAwait: true,
      optimize: 'ReleaseSmall',
    });
    expect(plain.code).to.not.include('features/js-host-op.js');
    expect(plain.code).to.not.include('features/js-value-registry.js');
  });

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
      let transpiled;
      let debugEnv;

      before(async function() {
        const loaded = await compileAndImport(samplePath, { ...target, exposeEnv: true });
        mod = loaded.mod;
        transpiled = loaded.result;
        debugEnv = mod.__debugEnv;
        mod.__zigar.set('modules', {
          'virtual:toolkit': {
            label: 'tk',
            version: 3,
            combine(a, b) {
              return a + b;
            },
          },
        });
      });

      afterEach(function() {
        expect(Number(mod.activeCallbacks())).to.equal(0);
        expect(Number(mod.activeHandles())).to.equal(0);
      });

      it('should emit js-host-op.js mixin and strip __zigar_js_reg_* exports from stripped WASM', function() {
        expect(transpiled.code).to.include('zigar-runtime/features/js-host-op.js');
        expect(transpiled.code).to.not.include('__zigar_js_reg_');
      });

      it('should execute all 9 host operations, bind `this`, intern UTF-8 keys once, and support Symbol keys', async function() {
        const modRes = await mod.callVirtualModuleStaticAndDynamic(19, 23);
        expect(modRes.string).to.equal('tk:42@v3');

        const bag = {};
        const sym = Symbol('wasm-prop');
        // Warm up once, then run 50 rounds and verify zero extra UTF-8 key decodes!
        await mod.testGlobalAndPropOps(bag, sym, 1);
        const decodesAfterWarmup = debugEnv.jsKeyDecodeCount;
        const propSum = await mod.testGlobalAndPropOps(bag, sym, 50);
        expect(debugEnv.jsKeyDecodeCount).to.equal(decodesAfterWarmup);
        // 15 (Math.abs) + sum_{i=0..49}(i + 10) + 42 (dynKey) + 77 (sym)
        // sum_{i=0..49}(i + 10) = 50*10 + 49*50/2 = 500 + 1225 = 1725 -> + 15 + 42 + 77 = 1859
        expect(propSum).to.equal(1859);
        expect(bag[sym]).to.equal(77);
        expect('counter' in bag).to.be.false;
        expect('dynKey' in bag).to.be.false;

        const ctorAndMethodRes = await mod.testCallFnMethodAndConstruct(
          (a, b) => a * 2 + b,
          StatefulCounter,
          10,
        );
        // base = 10 * 2 + 5 = 25; inst = new StatefulCounter(25); increment(7) -> 32
        expect(ctorAndMethodRes.string).to.equal('counter(ok)=32:32');
      });

      it('should propagate JS exceptions into E!T error unions across call/method/construct/get/set without handle leaks', async function() {
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

        const mask = await mod.testFallibleHostOps(faultyObj, BadCtor, badFn);
        expect(mask).to.equal(0b111111);
      });

      it('should invoke >64 (80) distinct host-op signatures in one WASM module with zero js-fn thunkSources', async function() {
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

        const actual = await mod.stress80DistinctHostSignatures(standaloneFn, helperObj, PayloadBox);
        expect(BigInt(actual)).to.equal(expected);
        // Zero consumption of the 16-thunk js-fn.zig pool!
        expect(debugEnv.thunkSources.length).to.equal(0);
      });

      it('should register, re-entrantly invoke, release, and recycle 64 simultaneous stateful Zig callbacks', async function() {
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
          await mod.register64StatefulCallbacks(bus);
          expect(bus.listeners.size).to.equal(64);
          expect(Number(mod.activeCallbacks())).to.equal(64);
          expect(Number(mod.activeHandles())).to.equal(64);

          // 1. Direct JS -> Zig invocation of all 64 distinct stateful closures
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

          // 2. Re-entrant JS -> Zig -> invokeJsHostOp (bus.emitAll) -> 64 Zig callbacks -> Zig!
          let expectedRound2 = 0n;
          for (let i = 0; i < 64; i++) {
            expectedRound2 += BigInt((i + 1) * 100 + 5 * (i + 2));
          }
          const reentrantSum = await mod.triggerBusFromZig(bus, 5);
          expect(BigInt(reentrantSum)).to.equal(expectedRound2);

          expect(Number(await mod.inspectCallbackTotalCalls())).to.equal(128);
          expect(BigInt(await mod.inspectCallbackTotalAccum())).to.equal(expectedRound1 + expectedRound2);
          expect(debugEnv.thunkSources.length).to.equal(0);

          const staleSample = bus.listeners.get(0);
          await mod.release64StatefulCallbacks();
          expect(Number(mod.activeCallbacks())).to.equal(0);
          expect(Number(mod.activeHandles())).to.equal(0);
          expect(debugEnv.getActiveZigCallbackCount()).to.equal(0);
          expect(() => staleSample(1)).to.throw(/already been released/);
        }
      });

      it('should survive 2,200+ caught infallible JS throws without leaking WASM __stack_pointer or Ref handles', async function() {
        const spBefore = debugEnv.stackPointerGlobal?.value;
        const cleanup = { deferCount: 0 };
        let caught = 0;
        for (let i = 0; i < 2200; i++) {
          const thrower = () => {
            throw new Error('boom');
          };
          const track = (i < 200) ? cleanup : null;
          try {
            await mod.callInfallibleWithStackAndDefer(thrower, track);
            expect.fail('Expected infallible host-op throw to propagate to JS caller');
          } catch (err) {
            expect(err).to.be.instanceOf(Error);
            expect(err.message).to.equal('boom');
            caught++;
          }
        }
        expect(caught).to.equal(2200);
        expect(cleanup.deferCount).to.equal(200);
        if (spBefore !== undefined) {
          expect(debugEnv.stackPointerGlobal.value).to.equal(spBefore);
        }
        expect(Number(mod.activeHandles())).to.equal(0);
      });

      it('should run Zig defers and release owned Callback slots cleanly when infallible host-op inside Callback throws', async function() {
        const cbFn = await mod.createOwnedThrowingCallback();
        expect(Number(mod.activeCallbacks())).to.equal(1);
        expect(Number(mod.liveOwnedCallbackAllocs())).to.equal(1);

        for (let i = 0; i < 10; i++) {
          expect(() => cbFn(() => {
            throw new Error(`cb-boom-${i}`);
          })).to.throw(`cb-boom-${i}`);
        }
        expect(cbFn(() => 123)).to.equal(123);

        const deferRuns = await mod.deinitOwnedThrowingCallback();
        expect(Number(deferRuns)).to.equal(11);
        expect(Number(mod.activeCallbacks())).to.equal(0);
        expect(Number(mod.activeHandles())).to.equal(0);
        expect(Number(mod.liveOwnedCallbackAllocs())).to.equal(0);
        expect(debugEnv.getActiveZigCallbackCount()).to.equal(0);
      });

      it('should isolate nested JS -> Zig outer (E!i32) -> JS mid -> Zig inner (i32) -> throwing JS op', async function() {
        // 1. `mid` catches `inner`'s infallible throw -> `outer` succeeds cleanly!
        const midCaught = () => {
          try {
            mod.nestedInnerInfallible(() => {
              throw new Error('inner-boom');
            });
            return -1;
          } catch (err) {
            expect(err.message).to.equal('inner-boom');
            return 777;
          }
        };
        expect(await mod.nestedOuterFallible(midCaught)).to.equal(777);
        expect(Number(mod.activeHandles())).to.equal(0);

        // 2. `mid` does NOT catch `inner`'s throw -> `outer` receives `error.JsException`!
        const midUncaught = () => mod.nestedInnerInfallible(() => {
          throw new Error('uncaught-inner-boom');
        });
        expect(await mod.nestedOuterCatching(midUncaught)).to.equal(-999);

        let outerErr = null;
        try {
          await mod.nestedOuterFallible(midUncaught);
        } catch (err) {
          outerErr = err;
        }
        expect(outerErr).to.be.instanceOf(Error);
        expect(outerErr.message).to.equal('Js exception');
        expect(JSON.parse(JSON.stringify(outerErr))).to.deep.equal({ error: 'Js exception' });
        expect(Number(mod.activeHandles())).to.equal(0);
      });

      it('should throw NotInErrorSet cleanly in JS while running Zig defers and restoring __stack_pointer', async function() {
        const spBefore = debugEnv.stackPointerGlobal?.value;
        const tracker = { deferRuns: 0 };
        for (let i = 0; i < 60; i++) {
          let thrown = null;
          try {
            await mod.callMismatchedErrorSetWithDefer(() => {
              throw new RangeError('unlisted-js-error');
            }, tracker);
          } catch (err) {
            thrown = err;
          }
          expect(thrown).to.be.instanceOf(TypeError);
          expect(thrown.message).to.match(/not a part of error set .*unlisted-js-error/);
        }
        expect(tracker.deferRuns).to.equal(60);
        if (spBefore !== undefined) {
          expect(debugEnv.stackPointerGlobal.value).to.equal(spBefore);
        }
        expect(Number(mod.activeHandles())).to.equal(0);
      });

      it('should release live Ref(T), composite struct/union Refs, and Callback Refs returned after an infallible throw', async function() {
        for (let i = 0; i < 40; i++) {
          let err1 = null;
          try {
            await mod.returnRefAfterThrow(() => {
              throw new Error(`ref-boom-${i}`);
            });
          } catch (err) {
            err1 = err;
          }
          expect(err1?.message).to.equal(`ref-boom-${i}`);

          let err2 = null;
          try {
            await mod.returnStructRefAfterThrow(() => {
              throw new Error(`struct-ref-boom-${i}`);
            });
          } catch (err) {
            err2 = err;
          }
          expect(err2?.message).to.equal(`struct-ref-boom-${i}`);

          let err3 = null;
          try {
            await mod.returnUnionRefAfterThrow(() => {
              throw new Error(`union-ref-boom-${i}`);
            });
          } catch (err) {
            err3 = err;
          }
          expect(err3?.message).to.equal(`union-ref-boom-${i}`);
        }
        expect(Number(mod.activeHandles())).to.equal(0);

        const cbFn = await mod.createRefAfterThrowCallback();
        for (let i = 0; i < 20; i++) {
          expect(() => cbFn(() => {
            throw new Error(`cb-ref-boom-${i}`);
          })).to.throw(`cb-ref-boom-${i}`);
        }
        expect(cbFn(() => 1)).to.equal(Math);
        await mod.deinitRefAfterThrowCallback();
        expect(Number(mod.activeCallbacks())).to.equal(0);
        expect(Number(mod.activeHandles())).to.equal(0);
      });

      if (target.useJSPI) {
        it('should route pending host errors and __stack_pointer to the right JSPI fiber across 220+ same-microtask resumptions', async function() {
          if (!debugEnv.useJSPI) {
            this.skip();
          }
          const spBefore = debugEnv.stackPointerGlobal?.value;
          const step1A = async () => 1;
          const step1B = async () => 1;
          const step1C = async () => 5;
          const step2C = async () => 6;
          const step1D = async () => 10;
          const step2D = async () => 20;
          for (let i = 0; i < 220; i++) {
            const pA = mod.suspendThenCall(
              step1A,
              () => {
                throw new Error(`fiber-A-${i}`);
              },
            );
            const pB = mod.suspendThenCall(
              step1B,
              () => 2,
            );
            const pC = mod.doubleSuspendThenCall(
              step1C,
              step2C,
              () => {
                throw new Error(`fiber-C-${i}`);
              },
            );
            const pD = mod.doubleSuspendThenCall(
              step1D,
              step2D,
              () => 7,
            );
            const [ rA, rB, rC, rD ] = await Promise.allSettled([ pA, pB, pC, pD ]);
            expect(rA.status).to.equal('rejected');
            expect(rA.reason?.message).to.equal(`fiber-A-${i}`);
            expect(rB.status).to.equal('fulfilled');
            expect(rB.value).to.equal(3);
            expect(rC.status).to.equal('rejected');
            expect(rC.reason?.message).to.equal(`fiber-C-${i}`);
            expect(rD.status).to.equal('fulfilled');
            expect(rD.value).to.equal(37);
          }
          if (spBefore !== undefined) {
            expect(debugEnv.stackPointerGlobal.value).to.equal(spBefore);
          }
          expect(debugEnv.resumingContinuation).to.be.null;
          expect(Number(mod.activeHandles())).to.equal(0);
        });
      }
    });
  }
});
