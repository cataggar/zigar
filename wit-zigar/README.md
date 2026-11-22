# `wit-zigar` (`zigar wit`)

WebAssembly Interface Types (**WIT**) parser, Canonical ABI (`wasm32` & `wasm64` Memory64) Zig 0.17 binding generator, embedded WASI `0.2.x` / `0.3.0` world catalog, and Node.js / Zig WebAssembly Component host bridge.

## CLI Usage

```bash
# Generate Zig 0.17 bindings for a WIT file or directory
npx zigar wit ./ts-zigar/wit/typescript.wit --world typescript-compiler -o ./generated_ts.zig

# Emit Memory64 (cm64) Canonical ABI signatures
npx zigar wit ./ts-zigar/wit/typescript.wit --world typescript-compiler --wasm64 -o ./generated_ts_wasm64.zig

# Generate bindings from an embedded WASI 0.2 / 0.3 world
npx zigar wit --wasi wasi:cli/command@0.3.0 -o ./wasi_cli.zig

# Inspect a core WASM module or Component for `zigar:abi` fast-path metadata
npx zigar wit --detect-zigar-abi ./module.wasm
```

## Testing

```bash
cd wit-zigar
zig build test
```
