import { expect } from 'chai';
import { mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import os from 'node:os';
import { join } from 'node:path';
import '../dist/index.cjs';
import { load } from '../dist/index.js';

describe('Native ES Module Imports, Tree-Shaking & CJS/ESM Interop (node-zigar)', function() {
  this.timeout(300000);

  const treeshakeURL = new URL('./zig-samples/js-value/module-imports/treeshake-app.zig?optimize=ReleaseSafe&quiet=1', import.meta.url);
  const parityURL = new URL('./zig-samples/js-value/module-imports/module-parity.zig?optimize=ReleaseSafe&quiet=1', import.meta.url);

  it('should emit ONLY reachable js.Module static imports and strip 49 unused modules in native ESM loader code', async function() {
    const { source } = await load(treeshakeURL.href, {}, () => {});
    expect(source).to.contain('import * as __zigar_js_mod_0 from "node:path";');
    expect(source).to.contain('env.registerJsModules({');
    expect(source).to.contain('"node:path": __zigar_js_mod_0,');
    for (let i = 1; i <= 49; i++) {
      expect(source).to.not.include(`pkg-${String(i).padStart(2, '0')}`);
    }
    expect(source).to.not.include('unused-mod');
    expect(source).to.not.include('unused-public-mod');
    expect(source).to.not.include('unused-2');

    const mod = await import(treeshakeURL.href);
    expect(mod.joinPaths('alpha', 'beta').string).to.equal(join('alpha', 'beta'));
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  it('should interoperate across node:path, node:url, local .mjs ESM, and local .cjs export = callable/class via ESM import()', async function() {
    const mod = await import(parityURL.href);
    expect(mod.exerciseNodeBuiltins().string).to.equal(
      'item.zig|p/item.zig|https://example.org/docs/spec?v=2|file:',
    );
    expect(mod.exerciseLocalEsm('node-esm').string).to.equal(
      'v17=v17|zig<->esm|esm-default:node-esm|esm-default:handle',
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
    const unrelatedCwd = join(process.env.TMPDIR || os.tmpdir(), 'node-zigar-unrelated-cwd');
    await mkdir(unrelatedCwd, { recursive: true });
    const prevCwd = process.cwd();
    process.chdir(unrelatedCwd);
    try {
      expect(mod.exerciseRuntimeRelativeImport('./cjs-export-equals.cjs', 3, 19)).to.equal(319);
    } finally {
      process.chdir(prevCwd);
    }
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  it('should interoperate identically when loaded via CommonJS require() (node-zigar/cjs)', function() {
    const require = createRequire(import.meta.url);
    const mod = require('./zig-samples/js-value/module-imports/module-parity.zig?optimize=ReleaseSafe&quiet=1');
    expect(mod.exerciseNodeBuiltins().string).to.equal(
      'item.zig|p/item.zig|https://example.org/docs/spec?v=2|file:',
    );
    expect(mod.exerciseLocalEsm('node-cjs').string).to.equal(
      'v17=v17|zig<->esm|esm-default:node-cjs|esm-default:handle',
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
    expect(mod.exerciseRuntimeRelativeImport('./cjs-export-equals.cjs', 3, 19)).to.equal(319);
    expect(Number(mod.activeHandles())).to.equal(0);
  });
});
