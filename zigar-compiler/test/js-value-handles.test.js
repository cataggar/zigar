import { expect } from 'chai';
import { mkdir, stat, writeFile } from 'fs/promises';
import os from 'os';
import { join, resolve } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';
import { StructurePurpose } from '../../zigar-runtime/src/constants.js';
import { compile, getModuleCachePath } from '../src/compilation.js';
import { transpile } from '../src/transpilation.js';
import { getArch, getPlatform } from '../src/utility-functions.js';

const testDir = fileURLToPath(new URL('.', import.meta.url));
const compilerRoot = resolve(testDir, '..');
const runtimeDistUrl = pathToFileURL(resolve(compilerRoot, '../zigar-runtime/dist') + '/').href;

let moduleCounter = 0;

async function compileAndImport(zigPath, options = {}) {
  const {
    memory64 = false,
    useJSPI = false,
    useWazig = true,
    stripUnused = true,
  } = options;
  const result = await transpile(zigPath, {
    nodeCompat: false,
    embedWASM: true,
    topLevelAwait: true,
    stripUnused,
    optimize: 'ReleaseSmall',
    memory64,
    useJSPI,
    useWazig,
  });
  const tmpBase = process.env.TMPDIR || os.tmpdir();
  const outDir = join(tmpBase, 'zigar-jsvalue-test');
  await mkdir(outDir, { recursive: true });
  const mjsPath = join(
    outDir,
    `jsvalue-${memory64 ? 'wasm64' : 'wasm32'}-${useWazig ? 'wazig' : 'legacy'}-${useJSPI ? 'jspi' : 'sync'}-${++moduleCounter}.mjs`,
  );
  const runnableCode = result.code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${runtimeDistUrl}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${runtimeDistUrl}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${runtimeDistUrl}$2"`);
  await writeFile(mjsPath, runnableCode, 'utf-8');
  const mod = await import(pathToFileURL(mjsPath).href);
  return { mod, result };
}

class CustomWidget {
  constructor(label) {
    this.label = label;
  }
  describe() {
    return `widget:${this.label}`;
  }
}

class SubWidget extends CustomWidget {}

describe('JsValue Handle Registry & zigar.js.Ref(T) End-to-End Integration', function() {
  this.timeout(300000);

  const samplePath = resolve(testDir, './zig-samples/js-value/handles.zig');

  const targets = [
    { label: 'wasm32 (useWazig=true)', memory64: false, useWazig: true, useJSPI: false },
    { label: 'wasm64 (useWazig=true, JSPI)', memory64: true, useWazig: true, useJSPI: true },
    { label: 'wasm32 (useWazig=false)', memory64: false, useWazig: false, useJSPI: false },
    { label: 'wasm64 (useWazig=false)', memory64: true, useWazig: false, useJSPI: false },
  ];

  for (const target of targets) {
    describe(`Target: ${target.label}`, function() {
      let mod;
      let transpiled;

      before(async function() {
        const loaded = await compileAndImport(samplePath, target);
        mod = loaded.mod;
        transpiled = loaded.result;
      });

      afterEach(function() {
        mod.clearGlobal();
        expect(Number(mod.activeCount())).to.equal(0);
      });

      it('should emit StructurePurpose.JsValue metadata and tree-shaken runtime imports', function() {
        expect(transpiled.structures.some((s) => s.purpose === StructurePurpose.JsValue)).to.be.true;
        expect(transpiled.code).to.include('zigar-runtime/features/js-value-registry.js');
        expect(transpiled.code).to.include('zigar-runtime/structures/js-value.js');
      });

      it('should preserve exact Object.is identity across roundtrips with zero leaked slots', function() {
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
        const sharedSym = Symbol.for('zigar.jsvalue.shared');

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

      it('should report typeof, instanceof, and Object.is equality accurately', function() {
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
        expect(Number(mod.activeCount())).to.equal(0);
      });

      it('should persist handles across WASM calls and clone cleanly on return', function() {
        const firstObj = new CustomWidget('persisted-1');
        const secondObj = new CustomWidget('persisted-2');

        mod.storeGlobal(firstObj);
        expect(Number(mod.activeCount())).to.equal(1);

        const loaded1 = mod.loadGlobalClone();
        const loaded2 = mod.loadGlobalClone();
        expect(Object.is(loaded1, firstObj)).to.be.true;
        expect(Object.is(loaded2, firstObj)).to.be.true;
        expect(Number(mod.activeCount())).to.equal(1);

        // Replacing global releases previous handle and retains the new one
        mod.storeGlobal(secondObj);
        expect(Number(mod.activeCount())).to.equal(1);
        expect(Object.is(mod.loadGlobalClone(), secondObj)).to.be.true;

        mod.clearGlobal();
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

      it('should borrow Ref(T) arguments passed to JS callbacks and transfer callback return ownership', async function() {
        const targetObj = new CustomWidget('callback-target');
        const derivedObj = { wrapped: targetObj };
        let seenInsideCallback;

        const returned = await mod.callWithBorrowedRef(targetObj, (arg) => {
          seenInsideCallback = arg;
          // While inside callback, `targetObj` handle is borrowed (still 1 active handle in Zig)
          expect(Number(mod.activeCount())).to.equal(1);
          return derivedObj;
        });

        expect(Object.is(seenInsideCallback, targetObj)).to.be.true;
        expect(Object.is(returned, derivedObj)).to.be.true;
        expect(Number(mod.activeCount())).to.equal(0);

        if (target.useJSPI) {
          let asyncSeen;
          const asyncDerived = { asyncWrapped: targetObj };
          const asyncReturned = await mod.callWithBorrowedRef(targetObj, async (arg) => {
            await Promise.resolve();
            asyncSeen = arg;
            expect(Number(mod.activeCount())).to.equal(1);
            return asyncDerived;
          });
          expect(Object.is(asyncSeen, targetObj)).to.be.true;
          expect(Object.is(asyncReturned, asyncDerived)).to.be.true;
          expect(Number(mod.activeCount())).to.equal(0);
        }
      });

      it('should reuse freed slots with incremented generation and trap on double-deinit or ABA stale handles', function() {
        const raw1 = mod.inspectRawHandle({ seq: 1 });
        const raw2 = mod.inspectRawHandle({ seq: 2 });
        const raw3 = mod.inspectRawHandle({ seq: 3 });

        const slot1 = raw1 & 0xFFFFF;
        const slot2 = raw2 & 0xFFFFF;
        const slot3 = raw3 & 0xFFFFF;
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

        const replacement = { replacement: true };
        expect(() => mod.triggerAbaStaleUse({ stale: true }, replacement)).to.throw(
          TypeError,
          /Invalid or released JS value handle/,
        );
        // `saved_ref` still holds `replacement` cleanly in the reused slot
        expect(Number(mod.activeCount())).to.equal(1);
        expect(Object.is(mod.loadGlobalClone(), replacement)).to.be.true;
        mod.clearGlobal();
        expect(Number(mod.activeCount())).to.equal(0);
      });
    });
  }

  it('should omit JsValue runtime imports when compiling modules without Ref(T)', async function() {
    const simplePath = resolve(testDir, './zig-samples/basic/simple.zig');
    const result = await transpile(simplePath, {
      nodeCompat: false,
      embedWASM: true,
      topLevelAwait: true,
      stripUnused: true,
      optimize: 'ReleaseSmall',
    });
    expect(result.code).to.not.include('js-value-registry.js');
    expect(result.code).to.not.include('structures/js-value.js');
  });

  it('should compile zigar.js.Ref(T) cleanly against the native host interface', async function() {
    const tmpBase = process.env.TMPDIR || os.tmpdir();
    const options = {
      optimize: 'Debug',
      platform: getPlatform(),
      arch: getArch(),
      isWASM: false,
      cacheDir: join(tmpBase, 'zigar-jsvalue-native-cache'),
    };
    const modPath = getModuleCachePath(samplePath, options);
    const { outputPath } = await compile(samplePath, modPath, options);
    const info = await stat(outputPath);
    expect(info.size).to.be.greaterThan(0);
  });
});
