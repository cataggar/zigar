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
    expect(Number(mod.activeHandles())).to.equal(0);
  });
});
