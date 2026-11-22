# `ts-zigar`

TypeScript 7.1 (`.d.ts` / `.ts`) to **Zig 0.17** binding generator powered by the embedded TypeScript 7.1 Go WebAssembly Component (`zigar:typescript@7.1.0`) and Zigar's `zigar.js` runtime bridge.

For the full type-mapping guide, `zigar.js` handle lifecycle rules, and cloud deployment documentation, see [`../docs/ts-zigar.md`](../docs/ts-zigar.md) and [`../examples/ts-zigar/README.md`](../examples/ts-zigar/README.md).

## CLI Usage

```bash
# Via zigar-compiler / node-zigar CLI
npx zigar ts -t ./node_modules/@types/node -s node:= -d ./src/generated/node

# Via standalone ts2zig alias
npx ts2zig -t ./api.d.ts -d ./src/generated/api

# Via native Zig 0.17 CLI (ts-zigar/zig-out/bin/ts-zigar)
cd ts-zigar && zig build
./zig-out/bin/ts-zigar -t ../examples/ts-zigar/node/node_modules/@types/node -s node:= -d ./out
```

### Options

| Flag | Description |
| --- | --- |
| `-t, --types <path>` | Input `.d.ts` / `.ts` file or npm package directory *(repeatable, required)* |
| `-d, --out-dir <dir>` | Output directory for generated `.zig` modules *(required)* |
| `-m, --module <name>` | Emit only matching module(s) and their transitive dependencies *(repeatable)* |
| `-s, --substitute <from=to>` | Substitute module/namespace path prefix while preserving JS wire specifiers *(repeatable, e.g. `node:fs=fs` or `node:=`)* |
| `--component <path>` | Override path to `typescript-compiler.component.wasm` |
| `--report-fallbacks` | Print structured summary of lossy type fallbacks to `stderr` |
| `--strict-fallbacks` | Exit with error if any lossy type fallback is emitted |
| `-h, --help` | Print help message and exit |
| `-v, --version` | Print version (`0.17.0 (TypeScript 7.1.0)`) and exit |

## Package Layout

```text
ts-zigar/
├── build.zig                     # Zig 0.17 build graph (CLI, WIT codegen, WASM checks, test suites)
├── wit/
│   └── typescript.wit            # WIT world `zigar:typescript@7.1.0/typescript-compiler`
├── component/
│   ├── build-component.mjs       # Reproducible staged builder (`microsoft/TypeScript` + `componentize-go`)
│   ├── build-typescript-pkg.mjs  # Staged TypeScript 7.1 `.d.ts` fixture builder for torture tests
│   ├── adapter/                  # Go 1.27 WIT compiler, VFS, checker, and batch graph extractor
│   └── test/                     # Node.js WASI Preview 2 component & extractor unit tests
├── src/
│   ├── main.zig                  # CLI entrypoint (`ts-zigar`)
│   ├── cli.zig                   # Argument & `-s` substitution parser
│   ├── host.zig                  # Native Node WASI & WASM extern component host (`TypeScriptHost`)
│   ├── driver.zig                # Package resolution (`exports`, `@types/*`, bundled packages) & pipeline
│   ├── ir.zig                    # Lowered Zig module/declaration/type IR
│   ├── merge_decls.zig           # Interface/namespace/class/callable declaration merging
│   ├── classify_decls.zig        # Plain options struct vs. `Ref(T)` handle classification
│   ├── lower_types.zig           # Primitives, arrays, tuples, nullability, binary views
│   ├── lower_unions.zig          # Enums, closed literal sets, template patterns, tagged unions
│   ├── lower_objects.zig         # Plain options structs & stateful handle wrappers
│   ├── lower_functions.zig       # Functions, callbacks (`Closure`), rest tuples, ESM/CJS exports
│   ├── overloads.zig             # Subsumed overload deduplication & semantic overload naming
│   ├── lower_heritage.zig        # Class/interface inheritance, upcasts, and checked downcasts
│   ├── lower_generics.zig        # Generic functions/types, `*Default`, `*Infer`, `*With`, utility types
│   ├── lower_protocols.zig       # `Promise<T>` (JSPI / `*Promise`), `Iterable`, `AsyncIterable`, `Disposable`
│   └── emit.zig                  # Canonical Zig 0.17 emitter + `std.zig.Ast` / `AstGen` verification
└── test/                         # WIT codegen, host, CLI emit, `@types/node@26`, and TS 7.1 torture tests
```

## Building & Testing

```bash
cd ts-zigar

# Build the TypeScript 7.1 Go WASM Component (requires Node.js 26+, Go 1.27+, componentize-go)
zig build component

# Build the native `ts-zigar` CLI binary (`zig-out/bin/ts-zigar`)
zig build

# Run WASI component + extractor tests
zig build test-component

# Run all Zig unit, CLI emit, @types/node@26, and TypeScript 7.1 declaration torture tests
zig build test -Drequire-ts71=true --summary all
```
