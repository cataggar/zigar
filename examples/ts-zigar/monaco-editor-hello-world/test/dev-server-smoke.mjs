import assert from 'node:assert/strict';
import { realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import { APP_DIR, ensureViteDeps } from '../build.mjs';

const localNm = ensureViteDeps();
const vitePkgReal = realpathSync(join(localNm, 'vite/package.json'));
const viteReq = createRequire(vitePkgReal);
const { createServer } = await import(pathToFileURL(realpathSync(join(localNm, 'vite/dist/node/index.js'))).href);

const viteServer = await createServer({
  configFile: join(APP_DIR, 'vite.config.js'),
  logLevel: 'error',
  optimizeDeps: {
    noDiscovery: true,
    include: [],
  },
  server: {
    host: '127.0.0.1',
    port: 0,
    hmr: false,
    ws: false,
    watch: null,
  },
});
await viteServer.listen();

try {
  const address = viteServer.httpServer.address();
  const devBase = `http://127.0.0.1:${address.port}`;

  const htmlRes = await fetch(`${devBase}/`, { headers: { connection: 'close' } });
  assert.equal(htmlRes.status, 200);
  const htmlText = await htmlRes.text();
  assert.match(htmlText, /id="container"/);

  for (const workerRoute of [ 'ts.worker.js', 'json.worker.js', 'css.worker.js', 'html.worker.js', 'editor.worker.js' ]) {
    const res = await fetch(`${devBase}/${workerRoute}`, { headers: { connection: 'close' } });
    assert.equal(res.status, 200, `Vite dev server must serve /${workerRoute}`);
    const jsText = await res.text();
    const fsMatch = jsText.match(/import\s+"(\/@fs\/[^"]+)"/);
    assert.ok(fsMatch, `Dev worker /${workerRoute} must import resolved Monaco worker via /@fs/`);

    const workerModuleRes = await fetch(`${devBase}${fsMatch[1]}`, { headers: { connection: 'close' } });
    assert.equal(
      workerModuleRes.status,
      200,
      `Vite dev server must allow serving ${fsMatch[1]} (not 403 Restricted)`,
    );
    const workerModuleJs = await workerModuleRes.text();
    assert.ok(workerModuleJs.length > 64, `Resolved worker module ${fsMatch[1]} must return non-empty JS`);
  }
} finally {
  viteServer.httpServer?.closeAllConnections?.();
  await viteServer.close();
  try {
    await viteReq('esbuild').stop?.();
  } catch {}
}

process.exit(0);
