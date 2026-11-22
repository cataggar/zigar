# `@zigar-examples/node` (`ts-zigar`)

Shared, reproducible **Node.js 26 Active LTS (`@types/node@26`)** Zig 0.17 binding package mirroring [`taggartsoftware/ts2rs/node`](https://github.com/taggartsoftware/ts2rs/tree/master/node) and consumed by:

- [`../node-console-hello-world`](../node-console-hello-world)
- [`../node-server-hello-world`](../node-server-hello-world)

## Generating Bindings

```bash
npm run generate
```

Under the hood, `generate.mjs` runs `zigar ts` (`ts2zig`) across the complete `@types/node@26` declaration graph with `-s "node:="` so `node:http`, `node:events`, `node:fs`, etc. are exposed cleanly as `node.http`, `node.events`, `node.fs` while retaining canonical `node:*` runtime ES module specifiers:

```bash
npx zigar ts \
  -t ./node_modules/@types/node \
  -s "node:=" \
  -d ./generated
```

## Consuming `@import("node")` in Zig

Consumer examples wire `generated/root.zig` as `@import("node")` via `src/build.extra.zig`:

```zig
const node = @import("node");
```

Because `ts-zigar` emits lazy `zigar.js` metadata, importing `@import("node")` from the full 63-module `@types/node@26` graph **tree-shakes** unused Node.js built-in modules at Zig comptime:

- `node-console-hello-world` (uses only `node.globals.process` and `node.globals.console`) emits **zero** `node:*` ES module imports.
- `node-server-hello-world` (uses `node.http` and `node.globals`) emits **only** `import * as ... from "node:http"`.
