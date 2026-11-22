# Zigar

![Logo](./logo.png)

A software tool set that lets you utilize [Zig](https://ziglang.org/) code in your JavaScript or
PHP projects.

Consult the [project wiki](https://github.com/chung-leong/zigar/wiki) for installation instructions
and tutorials.

## Features

* Access to all Zig data types in JavaScript/PHP
* Zig-to-JavaScript/PHP, JavaScript/PHP-to-Zig call marshalling
* Async task management
* Threads in native code and WebAssembly (with support for pthread)
* Emulating of file system operations
* Support for MacOS, Linux, and Windows (both 64-bit and 32-bit)
* Support for Node.js, Bun.js, Electron, and NW.js (native code execution)
* Support for Webpack, Rollup, and Vite (WebAssembly)
* TypeScript 7.1 (`.d.ts`) to Zig 0.17 binding generation (`npx zigar ts` / `npx ts2zig`) across WASM (JSPI), `node-zigar`, and `bun-zigar`
* WebAssembly Component Model (WIT) to Zig 0.17 binding generation (`npx zigar wit`) for `wasm32` and `wasm64`

## TypeScript & WIT Bindings (`zigar ts` / `ts2zig` & `zigar wit`)

Generate idiomatic Zig 0.17 bindings directly from TypeScript `.d.ts` declarations or npm packages (such as `@types/node@26`, `monaco-editor`, `@types/aws-lambda`, and `@azure/functions`) using the embedded TypeScript 7.1 Go WebAssembly Component:

```bash
# Generate Zig 0.17 bindings for Node.js 26 Active LTS
npx zigar ts -t ./node_modules/@types/node -s node:= -d ./src/generated/node

# Generate Zig 0.17 Canonical ABI bindings from a WIT world
npx zigar wit ./path/to/world.wit --world my-world -o ./src/generated_wit.zig
```

* [**`docs/ts-zigar.md`**](./docs/ts-zigar.md) — Complete `zigar ts` / `ts2zig` CLI reference, TypeScript-to-Zig 0.17 mapping guide, `zigar.js` handle lifecycles (`defer x.deinit()` vs. `dispose()`), JSPI / `WorkQueue` async patterns, and Cloud Node.js 26 deployment guide (Google App Engine `nodejs26`, AWS Lambda `nodejs26.x`, Azure Functions v4 `Node.js 26`)
* [**`ts-zigar/README.md`**](./ts-zigar/README.md) — `ts-zigar` compiler & TypeScript 7.1 WASM Component build/test guide
* [**`wit-zigar/README.md`**](./wit-zigar/README.md) — `wit-zigar` (`zigar wit`) Canonical ABI generator & Component host guide
* [**`examples/ts-zigar/README.md`**](./examples/ts-zigar/README.md) — Runnable Node.js 26, Monaco Editor browser, TypeScript 7.1 Component, and Cloud serverless examples

## Versioning

The major and minor version numbers of Zigar correspond to the version of the Zig compiler
it's designed for. The current version is 0.17.0. It works with Zig 0.17.0. Use version 0.16.0 
if you're still using that version of Zig. It's functionally identical.

## Technical support

If you have questions concerning this project, please post them at this project's
[discussion section](https://github.com/chung-leong/zigar/discussions). I can also be contacted at
[ziggit.dev](https://ziggit.dev/), which also happens to be an excellent forum for finding help on
all matters related to the Zig language.
