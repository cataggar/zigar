import { expect } from 'chai';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import os from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { defineEnvironment } from '../../zigar-runtime/src/environment.js';
import '../../zigar-runtime/src/mixins.js';
import { compile } from '../src/compilation.js';
import { transpile } from '../src/transpilation.js';
import { extractLimits } from '../src/wasm-decoding.js';

const testDir = fileURLToPath(new URL('.', import.meta.url));
const compilerRoot = resolve(testDir, '..');
const runtimeDistDir = resolve(compilerRoot, '../zigar-runtime/dist');
const runtimeDistUrl = pathToFileURL(runtimeDistDir + '/').href;
const sampleDir = resolve(testDir, './zig-samples/js-value/module-imports');

let counter = 0;

function rewriteRuntimeImports(code, { cjs = false } = {}) {
  if (cjs) {
    return code
      .replace(/require\((['"])zigar-runtime\1\)/g, `require(${JSON.stringify(join(runtimeDistDir, 'index.js'))})`)
      .replace(/require\((['"])zigar-runtime\/([^'"]+)\1\)/g, (_, _q, sub) => `require(${JSON.stringify(join(runtimeDistDir, sub))})`);
  }
  return code
    .replace(/from\s+(['"])zigar-runtime\1/g, `from "${runtimeDistUrl}index.js"`)
    .replace(/from\s+(['"])zigar-runtime\/([^'"]+)\1/g, `from "${runtimeDistUrl}$2"`)
    .replace(/import\s+(['"])zigar-runtime\/([^'"]+)\1/g, `import "${runtimeDistUrl}$2"`);
}

describe('Tree-Shaken ES Module Imports & CJS/ESM Interop (zigar-compiler WASM)', function() {
  this.timeout(300000);

  const treeshakeZig = join(sampleDir, 'treeshake-app.zig');
  const parityZig = join(sampleDir, 'module-parity.zig');

  it('should reflect ONLY reachable js.Module specifiers across a 50-module helper and unexported root declarations', async function() {
    const result = await transpile(treeshakeZig, {
      nodeCompat: false,
      embedWASM: true,
      topLevelAwait: true,
      stripWASM: true,
      optimize: 'ReleaseSmall',
    });

    expect(result.jsModules).to.deep.equal([ 'node:path' ]);
    expect(result.code).to.contain('import * as __zigar_js_mod_0 from "node:path";');
    expect(result.code).to.contain('env.registerJsModules({');
    expect(result.code).to.contain('"node:path": __zigar_js_mod_0,');

    for (let i = 1; i <= 49; i++) {
      const pkg = `pkg-${String(i).padStart(2, '0')}`;
      expect(result.code).to.not.include(pkg);
    }
    expect(result.code).to.not.include('unused-mod');
    expect(result.code).to.not.include('unused-public-mod');
    expect(result.code).to.not.include('unused-2');
    expect(result.code).to.not.include('__zigar_js_mod_1');

    const tmpBase = process.env.TMPDIR || os.tmpdir();
    const outDir = join(tmpBase, 'zigar-esmod-wasm');
    await mkdir(outDir, { recursive: true });
    const mjsPath = join(outDir, `treeshake-${++counter}.mjs`);
    await writeFile(mjsPath, rewriteRuntimeImports(result.code), 'utf-8');

    const mod = await import(pathToFileURL(mjsPath).href);
    expect(mod.joinPaths('left', 'right').string).to.equal(join('left', 'right'));
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  for (const target of [
    { label: 'wasm32', memory64: false },
    { label: 'wasm64', memory64: true },
  ]) {
    it(`should support node builtins, local .mjs ESM, and local .cjs export = callable/class in static ESM (${target.label})`, async function() {
      const sampleFileURL = pathToFileURL(parityZig).href;
      const result = await transpile(parityZig, {
        nodeCompat: false,
        embedWASM: true,
        topLevelAwait: true,
        stripWASM: true,
        optimize: 'ReleaseSmall',
        memory64: target.memory64,
        jsModuleResolver: (spec) => (spec.startsWith('./') || spec.startsWith('../'))
          ? new URL(spec, sampleFileURL).href
          : spec,
      });

      expect(result.jsModules).to.have.members([
        'node:path',
        'node:url',
        './esm-helper.mjs',
        './cjs-export-equals.cjs',
        './cjs-class.cjs',
        './singleton-esm.mjs',
        './named.cjs',
        './falsy.mjs',
        './facade.mjs',
        './fn.cjs',
        './ts.cjs',
      ]);
      expect(result.jsModules).to.have.lengthOf(11);

      const tmpBase = process.env.TMPDIR || os.tmpdir();
      const outDir = join(tmpBase, 'zigar-esmod-wasm');
      await mkdir(outDir, { recursive: true });
      const mjsPath = join(outDir, `parity-${target.label}-${++counter}.mjs`);
      await writeFile(mjsPath, rewriteRuntimeImports(result.code), 'utf-8');

      const mod = await import(pathToFileURL(mjsPath).href);
      expect(mod.exerciseNodeBuiltins().string).to.equal(
        'item.zig|p/item.zig|https://example.org/docs/spec?v=2|file:',
      );
      expect(mod.exerciseLocalEsm('wasm').string).to.equal(
        'v17=v17|zig<->esm|esm-default:wasm|esm-default:handle',
      );
      expect(mod.exerciseLocalCjsExportEquals(4, 23).string).to.equal(
        '423|cjs-static-extra|cjs-static-extra:ok|708|cjs-ctor-tag|155',
      );
      expect(mod.exerciseNamespaceShadowMutation().string).to.equal(
        '1:100|set_err|1:100|del=false:has=true:def=100|only=77=77|del_only=true:has_only=false',
      );
      expect(mod.exerciseNamedCjs().string).to.equal(
        '1|2=2|42->43|del=true:has=false:def_has=false|restored=1',
      );
      expect(mod.exerciseFalsyEsm().string).to.equal(
        'z=0|b=false|null=true|undef=true|set_err=true:def=100:del=false',
      );
      expect(mod.exerciseEsmFacade().string).to.equal(
        'has=true:v=2|set_err=true:named_has=false:del=false:after=2|extra=33=33:del=true:has=false',
      );
      expect(mod.exerciseFnCjs().string).to.equal(
        '11:1|20->30|del=true:has=false|restored=11',
      );
      expect(mod.exerciseTsEsModuleCjs().string).to.equal(
        'named=true:5|inner=true:9=9|added=true:1=1|del=true:has=false',
      );
      expect(Number(mod.activeHandles())).to.equal(0);
    });
  }

  it('should support CJS output (moduleFormat: "cjs") and dynamicJsImports: true from a different cwd without manual moduleBaseURL injection', async function() {
    const sampleFileURL = pathToFileURL(parityZig).href;
    const cjsRes = await transpile(parityZig, {
      nodeCompat: true,
      embedWASM: true,
      topLevelAwait: false,
      stripWASM: true,
      optimize: 'ReleaseSmall',
      moduleFormat: 'cjs',
      jsModuleResolver: (spec) => (spec.startsWith('./') || spec.startsWith('../'))
        ? fileURLToPath(new URL(spec, sampleFileURL))
        : spec,
    });
    expect(cjsRes.code).to.contain('const __zigar_js_mod_0 = require(');

    const tmpBase = process.env.TMPDIR || os.tmpdir();
    const outDir = join(tmpBase, 'zigar-esmod-wasm');
    await mkdir(outDir, { recursive: true });
    const cjsPath = join(outDir, `parity-cjs-${++counter}.cjs`);
    await writeFile(cjsPath, rewriteRuntimeImports(cjsRes.code, { cjs: true }), 'utf-8');

    const req = createRequire(import.meta.url);
    const cjsMod = req(cjsPath);
    await cjsMod.__zigar.init();
    expect(cjsMod.exerciseNodeBuiltins().string).to.equal(
      'item.zig|p/item.zig|https://example.org/docs/spec?v=2|file:',
    );
    expect(cjsMod.exerciseLocalEsm('cjs').string).to.equal(
      'v17=v17|zig<->esm|esm-default:cjs|esm-default:handle',
    );
    expect(cjsMod.exerciseLocalCjsExportEquals(4, 23).string).to.equal(
      '423|cjs-static-extra|cjs-static-extra:ok|708|cjs-ctor-tag|155',
    );
    expect(cjsMod.exerciseNamespaceShadowMutation().string).to.equal(
      '1:100|set_err|1:100|del=false:has=true:def=100|only=77=77|del_only=true:has_only=false',
    );
    expect(cjsMod.exerciseNamedCjs().string).to.equal(
      '1|2=2|42->43|del=true:has=false:def_has=false|restored=1',
    );
    expect(cjsMod.exerciseFalsyEsm().string).to.equal(
      'z=0|b=false|null=true|undef=true|set_err=true:def=100:del=false',
    );
    expect(cjsMod.exerciseEsmFacade().string).to.equal(
      'has=true:v=2|set_err=true:named_has=false:del=false:after=2|extra=33=33:del=true:has=false',
    );
    expect(cjsMod.exerciseFnCjs().string).to.equal(
      '11:1|20->30|del=true:has=false|restored=11',
    );
    expect(cjsMod.exerciseTsEsModuleCjs().string).to.equal(
      'named=true:5|inner=true:9=9|added=true:1=1|del=true:has=false',
    );
    expect(Number(cjsMod.activeHandles())).to.equal(0);

    // dynamicJsImports: true mode — write generated ESM alongside local helper modules and import from an unrelated cwd!
    const dynRes = await transpile(parityZig, {
      nodeCompat: false,
      embedWASM: true,
      topLevelAwait: true,
      stripWASM: true,
      optimize: 'ReleaseSmall',
      dynamicJsImports: true,
    });
    expect(dynRes.code).to.not.contain('import * as __zigar_js_mod_');
    expect(dynRes.code).to.contain('if (typeof import.meta?.url === \'string\') env.moduleBaseURL = import.meta.url;');
    expect(dynRes.code).to.contain('env.registerJsModuleLoaders({');
    expect(dynRes.code).to.contain('"./singleton-esm.mjs": () => import("./singleton-esm.mjs"),');
    expect(dynRes.code).to.contain('"preloadJsModules"');

    const runId = ++counter;
    const dynOutDir = join(tmpBase, `zigar-esmod-dyn-${runId}`);
    const unrelatedCwd = join(tmpBase, `zigar-unrelated-cwd-${runId}`);
    await mkdir(dynOutDir, { recursive: true });
    await mkdir(unrelatedCwd, { recursive: true });
    for (const helperFile of [
      'esm-helper.mjs',
      'cjs-export-equals.cjs',
      'cjs-class.cjs',
      'singleton-esm.mjs',
      'named.cjs',
      'falsy.mjs',
      'facade.mjs',
      'fn.cjs',
      'ts.cjs',
    ]) {
      await copyFile(join(sampleDir, helperFile), join(dynOutDir, helperFile));
    }
    const dynPath = join(dynOutDir, 'parity-dyn.mjs');
    // Zero manual env.moduleBaseURL injection — must resolve via import.meta.url & local () => import(...) thunks!
    await writeFile(dynPath, rewriteRuntimeImports(dynRes.code), 'utf-8');

    const prevCwd = process.cwd();
    process.chdir(unrelatedCwd);
    try {
      const singletonFromJs = await import(pathToFileURL(join(dynOutDir, 'singleton-esm.mjs')).href);
      expect(singletonFromJs.visits).to.equal(0);

      const dynMod = await import(pathToFileURL(dynPath).href);
      expect(dynMod.exerciseLocalEsm('dyn').string).to.equal(
        'v17=v17|zig<->esm|esm-default:dyn|esm-default:handle',
      );
      expect(dynMod.exerciseLocalCjsExportEquals(4, 23).string).to.equal(
        '423|cjs-static-extra|cjs-static-extra:ok|708|cjs-ctor-tag|155',
      );
      expect(dynMod.exerciseNamespaceShadowMutation().string).to.equal(
        '1:100|set_err|1:100|del=false:has=true:def=100|only=77=77|del_only=true:has_only=false',
      );
      expect(dynMod.exerciseNamedCjs().string).to.equal(
        '1|2=2|42->43|del=true:has=false:def_has=false|restored=1',
      );
      expect(dynMod.exerciseFalsyEsm().string).to.equal(
        'z=0|b=false|null=true|undef=true|set_err=true:def=100:del=false',
      );
      expect(dynMod.exerciseEsmFacade().string).to.equal(
        'has=true:v=2|set_err=true:named_has=false:del=false:after=2|extra=33=33:del=true:has=false',
      );
      expect(dynMod.exerciseFnCjs().string).to.equal(
        '11:1|20->30|del=true:has=false|restored=11',
      );
      expect(dynMod.exerciseTsEsModuleCjs().string).to.equal(
        'named=true:5|inner=true:9=9|added=true:1=1|del=true:has=false',
      );
      expect(dynMod.bumpSingletonVisits(9)).to.equal(9);
      expect(singletonFromJs.visits).to.equal(9);
      expect(dynMod.exerciseRuntimeRelativeImport('./cjs-export-equals.cjs', 3, 19)).to.equal(319);
      expect(Number(dynMod.activeHandles())).to.equal(0);
    } finally {
      process.chdir(prevCwd);
    }
  });

  it('should support in-memory JIT WASM execution via createEnvironment + preloadJsModules without writing a JS wrapper', async function() {
    const { outputPath } = await compile(parityZig, null, {
      arch: 'wasm32',
      platform: 'wasi',
      isWASM: true,
      optimize: 'ReleaseSmall',
    });
    const wasmBytes = await readFile(outputPath);
    const dv = new DataView(wasmBytes.buffer, wasmBytes.byteOffset, wasmBytes.byteLength);
    const limits = extractLimits(dv);
    const Env = defineEnvironment();
    const env = new Env();
    env.moduleBaseURL = pathToFileURL(parityZig).href;
    env.loadModule(wasmBytes, {
      memoryInitial: limits.memoryInitial !== undefined ? Number(limits.memoryInitial) : undefined,
      memoryMax: limits.memoryMax !== undefined ? Number(limits.memoryMax) : undefined,
      tableInitial: limits.tableInitial !== undefined ? Number(limits.tableInitial) : undefined,
      multithreaded: false,
    });
    await env.initPromise;
    env.acquireStructures();
    await env.preloadJsModules();
    const mod = env.useStructures();

    expect(mod.exerciseNodeBuiltins().string).to.equal(
      'item.zig|p/item.zig|https://example.org/docs/spec?v=2|file:',
    );
    expect(mod.exerciseLocalEsm('jit').string).to.equal(
      'v17=v17|zig<->esm|esm-default:jit|esm-default:handle',
    );
    expect(mod.exerciseLocalCjsExportEquals(4, 23).string).to.equal(
      '423|cjs-static-extra|cjs-static-extra:ok|708|cjs-ctor-tag|155',
    );
    expect(mod.exerciseNamespaceShadowMutation().string).to.equal(
      '1:100|set_err|1:100|del=false:has=true:def=100|only=77=77|del_only=true:has_only=false',
    );
    expect(mod.exerciseNamedCjs().string).to.equal(
      '1|2=2|42->43|del=true:has=false:def_has=false|restored=1',
    );
    expect(mod.exerciseFalsyEsm().string).to.equal(
      'z=0|b=false|null=true|undef=true|set_err=true:def=100:del=false',
    );
    expect(mod.exerciseEsmFacade().string).to.equal(
      'has=true:v=2|set_err=true:named_has=false:del=false:after=2|extra=33=33:del=true:has=false',
    );
    expect(mod.exerciseFnCjs().string).to.equal(
      '11:1|20->30|del=true:has=false|restored=11',
    );
    expect(mod.exerciseTsEsModuleCjs().string).to.equal(
      'named=true:5|inner=true:9=9|added=true:1=1|del=true:has=false',
    );
    expect(Number(mod.activeHandles())).to.equal(0);
  });
});
