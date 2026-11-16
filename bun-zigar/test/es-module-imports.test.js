import { expect } from 'chai';
import { join } from 'node:path';

describe('Bun Native ES Module Imports, Tree-Shaking & CJS/ESM Interop (bun-zigar)', function() {
  this.timeout(300000);

  const treeshakeURL = new URL('../../node-zigar/test/zig-samples/js-value/module-imports/treeshake-app.zig', import.meta.url).href;
  const parityURL = new URL('../../node-zigar/test/zig-samples/js-value/module-imports/module-parity.zig', import.meta.url).href;

  it('should tree-shake 49 unused modules and resolve node:path on Bun N-API', async function() {
    global.__test_options = { optimize: 'ReleaseSafe', quiet: true };
    const mod = await import(treeshakeURL);
    expect(mod.joinPaths('alpha', 'beta').string).to.equal(join('alpha', 'beta'));
    expect(Number(mod.activeHandles())).to.equal(0);
  });

  it('should interoperate across node:path, node:url, local .mjs ESM, and local .cjs export = callable/class on Bun N-API', async function() {
    global.__test_options = { optimize: 'ReleaseSafe', quiet: true };
    const namedNs = await import('../../node-zigar/test/zig-samples/js-value/module-imports/named.cjs');
    expect(namedNs.default.bump()).to.equal(2);
    const mod = await import(parityURL);
    expect(mod.exerciseNodeBuiltins().string).to.equal(
      'item.zig|p/item.zig|https://example.org/docs/spec?v=2|file:',
    );
    expect(mod.exerciseLocalEsm('bun-esm').string).to.equal(
      'v17=v17|zig<->esm|esm-default:bun-esm|esm-default:handle',
    );
    expect(mod.exerciseLocalCjsExportEquals(4, 23).string).to.equal(
      '423|cjs-static-extra|cjs-static-extra:ok|708|cjs-ctor-tag|155',
    );
    expect(mod.exerciseNamespaceShadowMutation().string).to.equal(
      '1:100|set_err|1:100|del=false:has=true:def=100|only=77=77|del_only=true:has_only=false',
    );
    expect(mod.exerciseNamedCjs().string).to.equal(
      '2|3=3|42->43|del=true:has=false:def_has=false|restored=1',
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
    expect(mod.exerciseRuntimeRelativeImport('./cjs-export-equals.cjs', 3, 19)).to.equal(319);
    expect(Number(mod.activeHandles())).to.equal(0);
  });
});
