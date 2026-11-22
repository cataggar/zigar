# `ts-zigar` (`zigar ts` / `ts2zig`) — TypeScript 7.1 to Zig 0.17 Bindings

`ts-zigar` generates idiomatic, zero-fallback **Zig 0.17** bindings directly from TypeScript `.d.ts` / `.ts` declarations and npm packages (`@types/node@26`, `monaco-editor`, `lib.dom.d.ts`, `@types/aws-lambda`, `@azure/functions`, and arbitrary ESM/CJS libraries).

Bindings run unchanged across:

- **WebAssembly (`wasm32` & `wasm64`)** via `zigar-compiler` / `rollup-plugin-zigar` (including V8 **JavaScript Promise Integration** / `WebAssembly.promising` via `useJSPI: true`)
- **Node.js 26 Active LTS (`node-zigar`)** via N-API + `zigar.thread.WorkQueue`
- **Bun (`bun-zigar`)** via N-API + `zigar.thread.WorkQueue`

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [CLI Reference (`zigar ts` / `ts2zig` & `zigar wit`)](#cli-reference-zigar-ts--ts2zig--zigar-wit)
3. [Quick Start](#quick-start)
4. [TypeScript to Zig 0.17 Mapping Guide](#typescript-to-zig-017-mapping-guide)
   - [Primitives, BigInt, Strings & Nullability](#1-primitives-bigint-strings--nullability)
   - [Plain Options Structs vs. `Ref(T)` Handle Wrappers](#2-plain-options-structs-vs-reft-handle-wrappers)
   - [Enums, Literal Sets, Template Patterns & Unions](#3-enums-literal-sets-template-patterns--unions)
   - [Functions, Smart Overloads, Callbacks & Module Interop](#4-functions-smart-overloads-callbacks--module-interop)
   - [Classes, Multi-Interface Heritage & Declaration Merging](#5-classes-multi-interface-heritage--declaration-merging)
   - [Generics, Type Operators & Built-in Utility Types](#6-generics-type-operators--built-in-utility-types)
   - [Promises (JSPI / `WorkQueue`), Iterators & Explicit Resource Management](#7-promises-jspi--workqueue-iterators--explicit-resource-management)
   - [Handle Lifecycles & Error Handling](#8-handle-lifecycles--error-handling)
5. [TypeScript 7.1 Go WASM Component (`zigar:typescript@7.1.0`)](#typescript-71-go-wasm-component-zigartypescript710)
6. [Node.js 26, Browser & Cloud Runtime Guide](#nodejs-26-browser--cloud-runtime-guide)

---

## Architecture Overview

```text
  .d.ts / npm package (@types/node@26, monaco-editor, @azure/functions, ...)
         │
         ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  typescript-compiler.component.wasm (zigar:typescript@7.1.0)     │
  │  • Upstream TypeScript 7.1 Go compiler + type checker            │
  │  • Built reproducibly via componentize-go                        │
  │  • Returns arena-indexed WIT declaration-graph in one ABI pass   │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │  zigar wit Canonical ABI (wasm32 / wasm64)
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  ts-zigar (ts-zigar/src/*.zig)                                   │
  │  • Declaration merging, heritage & overload deduplication        │
  │  • Plain-data options struct vs. stateful Ref(T) classification  │
  │  • Validates every emitted file via std.zig.Ast + AstGen         │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │  generated/*.zig + __zigar_runtime.zig
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  zigar.js Runtime Bridge (zigar-compiler/zig/type/js.zig)        │
  │  • Indexed JS handle table + Closure registry + LastError slot   │
  │  • WASM32 / WASM64 (JSPI) • node-zigar (N-API) • bun-zigar       │
  │  • Static ES module import metadata for Rollup/Vite tree-shaking │
  └──────────────────────────────────────────────────────────────────┘
```

---

## CLI Reference (`zigar ts` / `ts2zig` & `zigar wit`)

`ts-zigar` can be invoked via `npx zigar ts` (`zigar-compiler` / `node-zigar`), its standalone `npx ts2zig` alias, or the native `ts-zigar` executable (`cd ts-zigar && zig build`).

### `zigar ts` / `ts2zig`

```text
Usage: ts-zigar [options]
       zigar ts [options]
       ts2zig [options]

Generate Zig 0.17 bindings from TypeScript (.d.ts / .ts) declarations using
the embedded TypeScript 7.1 WASM Component compiler and semantic extractor.

Options:
  -t, --types <path>          Input .d.ts / .ts file or package directory (repeatable, required)
  -d, --out-dir <dir>         Output directory for generated .zig modules (required)
  -m, --module <name>         Emit only matching module(s) and their dependencies (repeatable)
  -s, --substitute <from=to>  Substitute or strip module prefix (repeatable, e.g. node:fs=fs, node:=)
      --component <path>      Override path to typescript-compiler.component.wasm
      --report-fallbacks      Print structured summary of lossy type fallbacks to stderr
      --strict-fallbacks      Exit with error if any lossy type fallback is emitted
  -h, --help                  Print this help message and exit
  -v, --version               Print version information and exit
```

Both space-separated (`-t ./node_modules/@types/node`) and inline (`--types=./api.d.ts`) forms are accepted.

#### Flag Details

- **`-t, --types <path>`** *(repeatable, required)*: Accepts an individual `.d.ts` / `.d.mts` / `.d.cts` / `.ts` file or an npm package root directory containing `package.json` (`exports`, `types`/`typings`, `main`/`module`, and `/// <reference types="..." />` / `path` directives are resolved automatically). Pass `-t` multiple times to link dependent packages into a single unified Zig module graph (for example `-t node_modules/@azure/functions -t node_modules/@types/node`).
- **`-d, --out-dir <dir>`** *(required)*: Target directory where `root.zig`, `__zigar_runtime.zig`, and per-module `.zig` files are written. Every emitted file is parsed, ZIR-checked (`std.zig.AstGen`), and canonically formatted before writing.
- **`-m, --module <name>`** *(repeatable)*: Filters emission to the named module(s) plus their transitive type dependencies, keeping generated trees compact when targeting specific entrypoints.
- **`-s, --substitute <from=to>`** *(repeatable)*: Rewrites generated Zig namespace/file prefixes while **preserving the original JavaScript runtime import specifier** on wire calls:
  - Prefix replacement: `-s node:fs=fs` or `-s monaco-editor/esm/vs/editor/editor.api=monaco`
  - Prefix stripping (allowed when `<from>` ends with `:`, `/`, or `.`): `-s node:=` emits `node:http` as `http.zig` (`pkg.http`) while still importing `"node:http"` at runtime.
- **`--component <path>`**: Explicit path to `typescript-compiler.component.wasm`.
- **`--report-fallbacks`**: Emits a structured summary of any lossy TypeScript -> Zig type fallbacks to `stderr`.
- **`--strict-fallbacks`**: Exits with a non-zero status if any lossy type fallback is encountered during lowering.

#### Environment Variables

| Variable | Purpose |
| --- | --- |
| `TS_ZIGAR_COMPONENT_PATH` / `TS_ZIGAR_COMPONENT_WASM` | Default path to `typescript-compiler.component.wasm` when `--component` is omitted |
| `TS_ZIGAR_CACHE_DIR` | Directory used by `build-component.mjs` to cache the pinned upstream `microsoft/TypeScript` checkout and Go staging tree |
| `TS_ZIGAR_NODE` | Node.js binary path used by native `ts-zigar` when spawning the WASI component host |
| `ZIGAR_CACHE_DIR` | Build cache directory used by `npx zigar ts` / `npx zigar wit` when compiling WASM CLI tools |

### `zigar wit`

```text
Usage:
  zigar wit <file.wit | dir> [--world <name>] [--wasm64] [-o <output.zig>]
  zigar wit --wasi <ns:pkg/world[@ver]> [--wasm64] [-o <output.zig>]
  zigar wit --detect-zigar-abi <path.wasm>
  zigar wit --help
```

- Generates Canonical ABI Zig 0.17 guest/host bindings for WIT interfaces, worlds, resources, and embedded WASI `0.2.x` / `0.3.0` packages (`wasm32` and `--wasm64` Memory64).
- `--detect-zigar-abi <path.wasm>` inspects a core WASM module or Component for `zigar:abi` fast-path metadata.

---

## Quick Start

### 1. Generate Node.js 26 Bindings

```bash
npm install --save-dev @types/node@26
npx zigar ts -t ./node_modules/@types/node -s node:= -d ./src/generated/node
```

### 2. Call JavaScript / Node.js APIs from Zig 0.17

Expose the generated `root.zig` module to Zigar via `build.extra.zig`:

```zig
// src/build.extra.zig
const std = @import("std");
const cfg = @import("build.cfg.zig");

pub fn getImports(b: *std.Build, args: anytype) []const std.Build.Module.Import {
    const node_root_path = std.fs.path.resolve(b.allocator, &.{
        cfg.module_dir,
        "generated/node/root.zig",
    }) catch @panic("OOM");
    const node_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = node_root_path },
        .imports = &.{
            .{ .name = "zigar", .module = args.zigar },
        },
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "node", .module = node_mod },
    }) catch @panic("OOM");
}
```

Use the generated bindings in `src/app.zig`:

```zig
// src/app.zig
const std = @import("std");
const node = @import("node");

pub fn printRuntimeBanner(alloc: std.mem.Allocator) !void {
    const con = try node.globals.console.get();
    defer con.deinit();

    const proc = try node.globals.process.get();
    defer proc.deinit();

    const ver = try proc.versionAlloc(alloc);
    defer alloc.free(ver);

    try con.log(.{ "Running Zig 0.17 on Node.js", ver });
}
```

When bundled with `rollup-plugin-zigar`, Zigar inspects static `zigar_js` module descriptors referenced by reachable Zig machine code and emits `import` statements **only** for the exact JavaScript modules your Zig code actually calls.

---

## TypeScript to Zig 0.17 Mapping Guide

### 1. Primitives, BigInt, Strings & Nullability

| TypeScript Type | Zig 0.17 Argument Type | Zig 0.17 Return Type | Notes |
| --- | --- | --- | --- |
| `void`, `undefined` | `void` | `void` | |
| `boolean` | `bool` | `bool` | |
| `number` | `f64` | `f64` | Exact-width integer helpers generated where applicable |
| `bigint` | `i64` / `i128` | `i64` / `js.BigInt` | Overflow-checked via `js.OverflowError` |
| `string` | `[]const u8` | `*Alloc(alloc, ...)` -> `[]u8` / `js.String` | UTF-8 transcoded on `*Alloc`; zero-copy JS handle on `js.String` |
| `symbol` / `unique symbol` | `js.Ref(js.Symbol)` | `js.Ref(js.Symbol)` | |
| `any` / `unknown` / `object` | `js.Ref(js.Any)` / `js.Ref(js.Unknown)` / `js.Ref(js.Object)` | Same | Safe opaque handle wrappers |
| `T \| undefined` / `param?: T` | `?T` (default `= null` on struct fields) | `?T` | `null` in Zig maps to JS `undefined` for optional parameters/fields |
| `T \| null` | `?T` | `?T` | Preserves JS `null` wire semantics via `NullishKind.null_only` |
| `T \| null \| undefined` | `js.Nullable(T)` | `js.Nullable(T)` | Distinguishes `.@"undefined"`, `.@"null"`, and `.{ .value = v }` |
| `Uint8Array` / `Buffer` / `ArrayBuffer` | `js.Uint8Array` / `js.Buffer` / `js.ArrayBuffer` (or `[]const u8` via `.fromSlice`) | Same | Zero-copy/bulk binary views |
| `T[]` / `readonly T[]` | `[]const T` or `js.Array(T)` | `*Alloc` -> `[]T` or `js.Array(T)` | Release decoded slices with `defer js.freeDecoded([]T, alloc, s)` |

**String & slice return convention**: Functions, getters, and methods whose return type requires heap allocation (strings, decoded arrays, plain structs containing strings/slices) emit an `*Alloc` variant taking `std.mem.Allocator` alongside handle-returning variants:

```zig
const url = try req.urlAlloc(alloc);
defer alloc.free(url);
```

For nested decoded structs or slices containing strings or handles, use `defer js.freeDecoded(ReturnType, alloc, value)` to recursively release both Zig memory and any embedded `Ref` handles.

---

### 2. Plain Options Structs vs. `Ref(T)` Handle Wrappers

`ts-zigar` classifies object/interface declarations into two categories:

1. **Plain Data / Options Structs** — Pure data interfaces and type literals (no methods, constructors, call/construct signatures, or stateful class identity) become **value-type Zig `struct`s** with snake_case field names, default `= null` optional fields, and `.toJsRef()` / `.fromJsRefAlloc(alloc, ref)` marshalling:
   ```zig
   // TypeScript: app.http("hello", { methods: ["GET", "POST"], authLevel: "anonymous", route: "hello/{id?}", handler })
   const methods: [2]azure.HttpMethod = .{ .get, .post };
   try azure.app.http("hello", .{
       .methods = &methods,
       .auth_level = .anonymous,
       .route = "hello/{id?}",
       .handler = handler,
   });
   ```
   Omitted optional fields (`= null`) are not set on the resulting JS object, preserving `"key" in opts === false` semantics in libraries that distinguish omitted properties from explicit `undefined`.

2. **Stateful `Ref(T)` Handle Wrappers** — Classes (`declare class`), interfaces with methods/call/construct signatures/mutating identity (such as `http.Server`, `IncomingMessage`, `HttpRequest`, `InvocationContext`, `monaco.editor.IStandaloneCodeEditor`), `Map<K, V>`, `Set<T>`, and `Error` subclasses become thin `extern struct { handle: u32 }` wrappers backed by Zigar's indexed JS handle table:
   ```zig
   const resp = try azure.HttpResponse.init(.{
       .status = 200,
       .body = .{ .str = body_bytes },
   });
   // Return to JS caller (transfers handle) or release locally with `defer resp.deinit();`
   ```

---

### 3. Enums, Literal Sets, Template Patterns & Unions

- **TypeScript `enum` and `const enum`**: Emitted as typed Zig enums (`i32` / `i64` backed for numeric enums, wire-mapped for string/mixed enums) preserving member aliases and rejecting out-of-domain JS values with `error.TypeError`.
- **Closed Literal Unions** (`"GET" | "POST" | "PUT"`, `0 | 1 | 2`): Lowered to ergonomic Zig enums (`.get`, `.post`, `.put`) with lossless wire round-tripping.
- **Template Literal Types** (`` `http://${string}` ``, `` `${number}px` ``): Validated via `zigar.js.matchTemplatePattern` with bounded memoized matching.
- **Discriminated & Heterogeneous Unions** (`string | Uint8Array | ReadableStream`, `{ kind: "ok"; value: number } | { kind: "err"; message: string }`): Emitted as Zig `union(enum)` types with `.toJsRef()`, `.fromJsRef(ref)` / `.fromJsRefAlloc(alloc, ref)`, `deinit()`, and automatic coercion helpers (`js.coerceUnion`).

---

### 4. Functions, Smart Overloads, Callbacks & Module Interop

- **Overload Deduplication & Semantic Naming**:
  - Subsumed TypeScript overloads (such as prefix-optional signatures or union-equivalent signatures) are collapsed automatically.
  - Distinct overloads receive **semantic suffix names** derived from their distinguishing parameter types (for example `getHttpMethodFunctionOptions`, `fromArrayBuffer`, `readFileWithOptions`) plus a unified comptime dispatcher on the base name where unambiguous.
- **Variadic / Rest Parameters** (`...args: any[]`): Passed as Zig tuples (for example `try con.log(.{ "status:", @as(i32, 200) })`).
- **Zig Callbacks (`zigar.js.Closure`)**:
  ```zig
  const RequestClosure = js.Closure(*ServerState, ServerState.onRequest);

  const req_cb = try RequestClosure.tryInit(state);
  errdefer req_cb.deinit(); // releases registered JS callback trampoline on failure

  const srv = try http.createServer(.{&req_cb});
  (try srv.on(.{ .@"error", &err_cb })).deinit();
  ```
  Always release `Closure` instances via `.deinit()` once unregistered (for example on server close); `js.activeCallbackCount()` reports live registered callbacks for leak auditing.
- **ESM, CommonJS (`export =`), Default Exports & Bundled Packages**:
  - Named ESM exports, `export default`, `export =` CommonJS callable/constructable namespaces, and UMD globals are all lowered through `zigar.js.Module(specifier)` descriptors.
  - `@types/<pkg>` packages map automatically to `<pkg>` runtime specifiers, `package.json` `"exports"` reverse-map declaration paths to public subpaths, and bundled runtime packages (`main`/`module` + `types` without `exports`, such as `@azure/functions`) map entrypoints to bare `<pkg>` while keeping declaration-only internal files encapsulated.

---

### 5. Classes, Multi-Interface Heritage & Declaration Merging

- **Constructors**: Emitted as `ClassName.init(...)` (plus semantic constructor overloads when multiple `new (...)` signatures exist).
- **Single & Multi-Interface Heritage**: Derived classes and interfaces expose zero-cost borrowed `.as(BaseInterface)` upcasts and checked `.tryAs(DerivedClass)` downcasts.
- **Declaration Merging**: Merged `interface + namespace`, `class + interface`, `function + namespace` (callable namespaces), and multi-file `interface` augmentations are unified into a single Zig namespace before code emission.

---

### 6. Generics, Type Operators & Built-in Utility Types

- **Generic Functions & Methods**:
  - Explicit type parameters: `try mod.identity(f64, 42.5)`
  - Default type arguments (`<T = string>`): `*Default` / `*DefaultAlloc` helpers (`try mod.identityDefaultAlloc(alloc, "hello")`)
  - Call-site inference: `*Infer` / `*InferAlloc` helpers (`try mod.identityInfer(@as(i32, -9))`)
  - `const T` type parameters preserve fixed-length tuple/array literal types.
- **Generic Classes & Interfaces**:
  - `Box(T)` type constructors, `BoxDefault()` when all type parameters have defaults, and `BoxWith(.{ .T = []const u8, .Meta = .from_default })` named partial specialization.
- **TypeScript Type Operators & Utility Types**: Mapped to `zigar.js` comptime type functions (`js.Partial(T)`, `js.Required(T)`, `js.Readonly(T)`, `js.Pick(T, keys)`, `js.Omit(T, keys)`, `js.Intersect(parts)`, `js.EnumRecord(K, V)`, `js.NonNullable(T)`, `js.Awaited(T)`, `js.KeyOf(T)`, `js.IndexAccess(T, K)`, `js.Parameters(Fn)`, `js.ReturnType(Fn)`, `js.ConstructorParameters(Ctor)`, `js.InstanceType(Ctor)`).

---

### 7. Promises (JSPI / `WorkQueue`), Iterators & Explicit Resource Management

- **Async `Promise<T>` Functions & Methods**:
  Every TypeScript signature returning `Promise<T>` emits **two** Zig forms:
  1. **Auto-awaiting primary function** (`fetchData(...) !T` / `fetchDataAlloc(alloc, ...) !T`): Suspends the Zig stack transparently via **V8 WebAssembly JSPI** (`useJSPI: true` in `rollup-plugin-zigar` / `zigar-compiler`) or **native `zigar.thread.WorkQueue`** (`node-zigar` / `bun-zigar`) and resumes with the resolved `T` (or returns `error.JsException` on rejection):
     ```zig
     try ntp.setTimeoutDefault(5, null, null); // awaits node:timers/promises setTimeout(5)

     const u8_in = try js.Uint8Array.fromSlice(input_bytes);
     defer u8_in.deinit();
     const ab = try subtle.digest(.from("SHA-256"), .from(u8_in)); // awaits crypto.subtle.digest
     defer ab.deinit();
     ```
     *(Calling an auto-awaiting function synchronously without JSPI or outside a `WorkQueue` task safely returns `error.HostUnavailable` without leaking handles.)*
  2. **Raw `*Promise` companion** (`fetchDataPromise(...) !js.Promise(T)`): Returns the unsettled `js.Promise(T)` handle without suspending, enabling concurrent fan-out via `try js.promiseAll(.{ p1, p2 })` or manual `try p.await()`.

- **Exporting Async Zig Functions to JavaScript**:
  - **WASM + JSPI (`useJSPI: true`)**: Export a regular Zig function `pub fn handler(...) !js.Object` — `rollup-plugin-zigar` wraps exports with `WebAssembly.promising(...)` so JavaScript callers receive a native `Promise`.
  - **Native `node-zigar` / `bun-zigar`**: Dispatch through `var work_queue: zigar.thread.WorkQueue(worker_ns) = .{};` using `zigar.function.Promise(T)` so worker threads post JS host calls back onto the main V8 thread safely while keeping the Node.js event loop non-blocking.

- **`Iterable<T>` & `AsyncIterable<T>`**:
  - Positional `Iterable<T>` parameters accept plain Zig slices directly (`&.{ 10, 20, 30 }`).
  - Returned iterators expose `while (try it.next()) |item| { ... }` / `nextAlloc(alloc)` with `defer it.deinit()` (or `defer gen.closeAndDeinit()` to trigger generator `.return()` on early exit).

- **Explicit Resource Management (`[Symbol.dispose]` & `[Symbol.asyncDispose]`)**:
  - Types implementing `Disposable` (`[Symbol.dispose]` or `Symbol.for("nodejs.dispose")`) expose `.dispose()` and `.tryDispose()`.
  - Types implementing `AsyncDisposable` (`[Symbol.asyncDispose]` or `Symbol.for("nodejs.asyncDispose")`) expose `.asyncDispose()` and `.tryAsyncDispose()`.

---

### 8. Handle Lifecycles & Error Handling

#### Critical Distinction: `deinit()` vs. `dispose()`

| Method | Releases Zigar Handle Slot? | Invokes JS `[Symbol.dispose]` / `[Symbol.asyncDispose]`? | When to Use |
| --- | :---: | :---: | --- |
| `defer x.deinit()` | **Yes** | **No** | Standard ownership cleanup for any JS object/function/array/promise handle (`Ref(T)`, `js.Object`, `js.Array`, `js.Promise`, `HttpRequest`, etc.) |
| `defer x.dispose()` / `try x.tryDispose()` | **Yes** | **Yes** (sync) | Scoped resources (cursors, file/lock handles, disposables) where you want ECMAScript `using` cleanup to run |
| `defer x.asyncDispose()` / `try x.tryAsyncDispose()` | **Yes** | **Yes** (async) | Async resources (`await using`) inside a JSPI or `WorkQueue` context |

- Reserved singleton handles (`undefined`, `null`, `false`, `true`, `globalThis`) are static indices (`0..4`); calling `.deinit()` or `.clone()` on them is a zero-cost no-op.
- Audit handle and callback hygiene in tests via `js.activeHandleCount()` and `js.activeCallbackCount()`.

#### Inspecting JavaScript Exceptions (`error.JsException`)

When a JS call throws or a `Promise` rejects, generated functions return `error.JsException` and capture the thrown JS error value in the thread-local last-error slot:

```zig
const res = someJsCall() catch |err| switch (err) {
    error.JsException => {
        if (js.takeLastError()) |exc| {
            defer exc.deinit();
            if (try exc.message(alloc)) |msg| {
                defer alloc.free(msg);
                std.log.err("JS exception: {s}", .{msg});
            }
        }
        return err;
    },
    else => return err,
};
```

Always consume (`takeLastError()` / `tryTakeLastError()`) or clear (`clearLastError()`) captured exceptions when recovering from `error.JsException` in Zig.

---

## TypeScript 7.1 Go WASM Component (`zigar:typescript@7.1.0`)

`ts-zigar` embeds the upstream **TypeScript 7.1** Go compiler (`microsoft/TypeScript/tsc`) compiled to a WebAssembly Component (`ts-zigar/component/dist/typescript-compiler.component.wasm`) matching `ts-zigar/wit/typescript.wit` (`package zigar:typescript@7.1.0; world typescript-compiler`).

### WIT World Summary (`ts-zigar/wit/typescript.wit`)

- **`zigar:typescript/types@7.1.0`**: Arena-indexed `declaration-graph` (`strings`, `modules`, `entry-modules`, `decls`, `types`, `signatures`, `type-params`, `properties`, `diagnostics`) so recursive TypeScript types cross the Canonical ABI boundary in a single flat return value.
- **`zigar:typescript/compiler@7.1.0`**: Stateful `vfs`, `program`, and `checker` resources plus `create-program`, `transpile-module`, and `compiler-version`.
- **`zigar:typescript/extractor@7.1.0`**: `extract-module-graph(prog, config) -> result<declaration-graph, list<diagnostic>>`.

### Rebuilding `typescript-compiler.component.wasm`

Prerequisites: **Node.js 26+**, **Go 1.27+**, **Zig 0.17**, and **`componentize-go`** (`v0.5.3+`).

```bash
# Option A: Build via Zig build system
cd ts-zigar
zig build component

# Option B: Invoke the staged builder directly (supports custom output path and --force)
node ts-zigar/component/build-component.mjs -o ts-zigar/component/dist/typescript-compiler.component.wasm --force

# Run component unit + WIT Canonical ABI + TypeScript 7.1 torture tests
cd ts-zigar
zig build test-component
zig build test -Drequire-ts71=true --summary all
```

`build-component.mjs` fetches a shallow, commit-pinned checkout of `microsoft/TypeScript` into `${TS_ZIGAR_CACHE_DIR:-.cache/ts-zigar}`, stages `./tsc` into an isolated build tree (satisfying Go `internal/` visibility without mutating the cached upstream checkout), generates Go WIT bindings via `componentize-go`, overlays `ts-zigar/component/adapter/`, and produces `typescript-compiler.component.wasm`.

Host-side Zig bindings for `typescript.wit` (`wasm32` and `wasm64`) are generated automatically during `zig build` and `npx zigar ts` via `wit-zigar` (`npx zigar wit ts-zigar/wit/typescript.wit --world typescript-compiler`). See [`examples/ts-zigar/ts-compiler-component-hello-world/`](../examples/ts-zigar/ts-compiler-component-hello-world/) for a standalone Zig + Node.js example driving the TypeScript 7.1 component directly.

---

## Node.js 26, Browser & Cloud Runtime Guide

### Cloud Node.js 26 Active LTS Matrix

| Cloud Platform | Service / Environment | Runtime Identifier | Recommended Backend | Example |
| --- | --- | --- | --- | --- |
| **Google Cloud** | App Engine Standard (Ubuntu 24.04) / Cloud Run | `runtime: nodejs26` | Stripped JSPI WASM (`dist/gae_server.mjs`) or Linux Native N-API | [`examples/ts-zigar/gcloud-appengine-node26/`](../examples/ts-zigar/gcloud-appengine-node26/) |
| **AWS** | AWS Lambda Managed Runtime (AL2023) | `nodejs26.x` (`x86_64` / `arm64`) | Stripped JSPI WASM (`< 256 KiB`, zero `node_modules`) | [`examples/ts-zigar/aws-lambda-node26/`](../examples/ts-zigar/aws-lambda-node26/) |
| **AWS** | Lambda Custom Container / Elastic Beanstalk | `public.ecr.aws/lambda/nodejs:26` / Node.js 26 AL2023 | Standalone Native `node-zigar` (`WorkQueue`) or JSPI WASM | [`examples/ts-zigar/aws-lambda-node26/`](../examples/ts-zigar/aws-lambda-node26/) |
| **Microsoft Azure** | Azure Functions v4 (Flex / Consumption / Premium) | `FUNCTIONS_EXTENSION_VERSION=~4`, `linuxFxVersion: "NODE\|26"` | Stripped JSPI WASM (`functions/*.mjs`) or Linux Native `WorkQueue` (`functions-native/*.mjs`) | [`examples/ts-zigar/azure-functions-node26/`](../examples/ts-zigar/azure-functions-node26/) |
| **Microsoft Azure** | Azure App Service (Linux) | `NODE\|26-lts` | Stripped JSPI WASM or Linux Native `WorkQueue` | [`examples/ts-zigar/azure-functions-node26/`](../examples/ts-zigar/azure-functions-node26/) |

### Cloud Deployment Highlights

1. **Google App Engine (`nodejs26`)**:
   - Prebuild WASM via `npm run build:wasm` (`predeploy` script) and use `.gcloudignore` so `gcloud app deploy` uploads only `app.yaml`, `package.json`, `run-wasm.mjs`, and `dist/**`.
   - Bind `0.0.0.0:$PORT` (default `8080`), handle `/_ah/warmup`, emit single-line JSON logs with `logging.googleapis.com/severity` + `logging.googleapis.com/trace` (`x-cloud-trace-context`), and drain keep-alive connections cleanly on `SIGTERM`.

2. **AWS Lambda (`nodejs26.x`) & Elastic Beanstalk**:
   - Link `@types/aws-lambda` + `@types/node@26` (`zigar ts -t node_modules/@types/aws-lambda -t node_modules/@types/node -s node:= -d generated`).
   - Bundle with `rollup-plugin-zigar` (`optimize: 'ReleaseSmall'`, `useJSPI: true`, `stripWASM: true`, `topLevelAwait: true`) so cold starts instantiate a `< 256 KiB` WASM module once during Lambda `INIT` and reuse it across warm `INVOKE` cycles with zero `npm` runtime dependencies.
   - Respect `AWS_LAMBDA_LOG_FORMAT=JSON` and `X-Amzn-Trace-Id` / `_X_AMZN_TRACE_ID` for CloudWatch & X-Ray correlation.

3. **Azure Functions v4 (`NODE|26`) & Azure App Service**:
   - Link `@azure/functions` + `@types/node@26` (`zigar ts -t node_modules/@azure/functions -t node_modules/@types/node -s node:= -d generated`).
   - Register v4 HTTP triggers (`azure.app.http(...)`) at module load time from an entrypoint matching `package.json` `"main"` (`"functions/*.mjs"` for architecture-independent JSPI WASM Zip Deploy, or `"functions-native/*.mjs"` for native `WorkQueue`).
   - On the native `WorkQueue` backend, register both `app.hook.appTerminate(() => shutdown())` and a `SIGTERM` drain handler that re-signals `SIGTERM` once `WorkQueue` drains so worker shutdown completes cleanly even with open gRPC host channels.

4. **Browser (`monaco-editor` + `lib.dom.d.ts`)**:
   - Link DOM declarations with `monaco-editor` (`zigar ts -t lib.dom.d.ts -t node_modules/monaco-editor/esm/vs/editor/editor.api.d.ts ...`) and bundle with Vite + `rollup-plugin-zigar` (`nodeCompat: false`). See [`examples/ts-zigar/monaco-editor/`](../examples/ts-zigar/monaco-editor/) and [`examples/ts-zigar/monaco-editor-hello-world/`](../examples/ts-zigar/monaco-editor-hello-world/).
