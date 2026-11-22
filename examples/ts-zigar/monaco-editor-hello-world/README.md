# `monaco-editor-hello-world` — Browser Monaco Editor in Zig 0.17 (`Vite` + `rollup-plugin-zigar`)

Interactive browser **Monaco Editor** application written in **Zig 0.17**, bound via **`zigar ts`** (`ts-zigar`) from [`examples/ts-zigar/monaco-editor`](../monaco-editor), and bundled into a tree-shaken ES module + WebAssembly browser bundle using **Vite** and **`rollup-plugin-zigar`** (mirroring `ts2rs/monaco-editor-hello-world`).

## Architecture

1. **Generated Browser DOM + Monaco Zig Bindings (`../monaco-editor/generated`)**:
   - `../monaco-editor/generate.mjs` runs `zigar ts` over `dom.d.ts` and `monaco-editor@0.57.0` (`-s monaco-editor=monaco`) to emit lazy `comptime` Zig 0.17 modules (`web.dom` and `web.monaco`).
   - `src/build.extra.zig` wires `@import("web")` into `rollup-plugin-zigar` (browser WASM32) and `node-zigar` (native Node.js).
2. **Zig 0.17 Application (`src/app.zig`)**:
   - Installs `globalThis.MonacoEnvironment` with a persistent Zig closure (`WorkerUrlClosure`) routing `"typescript"`/`"javascript"` -> `"./ts.worker.js"`, `"json"` -> `"./json.worker.js"`, `"css"`/`"scss"`/`"less"` -> `"./css.worker.js"`, `"html"`/`"handlebars"`/`"razor"` -> `"./html.worker.js"`, and default labels -> `"./editor.worker.js"`.
   - Resolves `#container` via `dom.document.getElementById("container")`.
   - Mounts a `vs-dark` TypeScript editor via `monaco.editor.create(container, .{ .value = ..., .language = "typescript", .theme = "vs-dark", .automatic_layout = true, .tab_size = 2, .minimap = .{ .enabled = false } }, null)`.
   - Exposes `getValue`, `setValue`, `resolveWorkerUrl`, and deterministic `unmount()` releasing all `JsValue` handles and callback thunks (`activeHandles() == 0`, `activeCallbacks() == 0`).
3. **Tree-Shaken Vite + `rollup-plugin-zigar` Bundle (`vite.config.js`, `src/main.js`)**:
   - Imports only the standalone Monaco editor core and TypeScript language contribution (`monaco-editor/internal/common/workers.js` and `monaco-editor/languages/{definitions,features}/typescript/register.js`) alongside `src/app.zig` (`monaco-editor/editor/editor.api.js`), keeping ~80 unused language grammars out of `dist/assets/`.
   - Compiles `src/app.zig` to stripped `ReleaseSmall` WebAssembly (`dist/assets/app-<hash>.wasm`, ~150 KiB raw / ~48 KiB gzipped) and emits standalone ES module workers (`dist/{editor,json,css,html,ts}.worker.js`).

## Quick Start

```bash
cd examples/ts-zigar/monaco-editor-hello-world

# 1. Build production browser bundle into dist/
npm run build

# 2. Launch interactive Vite dev server
npm run dev

# 3. Preview production dist/ bundle locally
npm run preview

# 4. Run full automated verification suite (zig build test + Vite build + JSDOM/HTTP mount + dev server)
npm test
```

## Standalone Zig Compilation Check

```bash
zig build test --summary all
```
