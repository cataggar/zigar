# `wazig` (`v0.17.0-wazig.6`) & `wazigl` (`v0.17.0-wazigl.6`) vs Standard `zig` (`0.17.0`) — Benchmark Suite

Reproducible Node.js ESM benchmark and comparison suite (`wazig-benchmark.js`) measuring **`wazig` (`v0.17.0-wazig.6`)** and **`wazigl` (`v0.17.0-wazigl.6`)** against **standard `zig` (`0.17.0`)** across all four dimensions relevant to `zigar-compiler` and `zigar-runtime`:

1. **Toolchain & Distribution Footprint** — Compressed download archive sizes (`wazig.tar.zst` `8.47 MB` / `8.08 MiB` and `wazigl.tar.zst` `38.02 MB` / `36.26 MiB` vs `zig` `52.88–100.27 MB` per platform), installed disk footprint (`wazig.wasm` `31.78 MB`, `wazigl.wasm` `202.40 MB`, and Wasm-focused `lib/` `29.94 MB` vs native `zig` binary `171.69 MB` + multi-target `lib/` `187.64 MB`), file counts, `lib/` subdirectory breakdown, and CLI startup latency (`wazig version`, `wazigl version`, `zig version`).
2. **Compilation & Transpilation Performance (Cold & Warm Cache)** — Compares four compilation pipelines across 14 representative Zig modules (Pure-Zig basic, C header `translate-c`, Libc `-lc`, Multithreaded WASM, and Compute Kernels):
   - **`zig build` (Upstream baseline)**: `zigPath: 'zig', useBuildExe: false`
   - **`zig build-exe` (Native Zig fast-path)**: `zigPath: 'zig', useBuildExe: true`
   - **`wazig build-exe` (`v0.17.0-wazig.6`)**: `zigPath: 'wazig', useBuildExe: true`
   - **`wazigl build-exe` (`v0.17.0-wazigl.6`)**: `zigPath: 'wazigl', useBuildExe: true`
   Measures cold `.zig-cache` compilation, warm shared `.zig-cache` compilation (where `std`, `compiler_rt`, `libzigc.a`, and `translate-c` are cached), and warm incremental rebuilds after a source edit, plus a direct `translate-c` cold vs warm microbenchmark and out-of-the-box multithreaded WASM verification.
3. **Output `.wasm` Binary Size (Raw & Stripped)** — Measures raw (`compile()`) and dead-code/reflection-stripped (`stripUnused()`) `.wasm` binary sizes across all four Zig optimization modes (`Debug`, `ReleaseSmall`, `ReleaseFast`, `ReleaseSafe`) for:
   - `zig 0.17.0` with upstream `-lc` + LLVM (`useLibc: true, useLLVM: true`)
   - `zig 0.17.0` pure-Zig + LLVM (`useLibc: false, useLLVM: true`)
   - `wazigl v0.17.0-wazigl.6` Wasm-hosted LLVM 22 + pure-Zig `libzigc.a` (`zigPath: 'wazigl', useLLVM: true`)
   - `zig 0.17.0` self-hosted `stage2_wasm` (`useLibc: false, useLLVM: false`)
   - `wazig v0.17.0-wazig.6` (`stage2_wasm` + SROA, `Optimizer.zig` leaf inlining & peephole passes, MIR dead-store/copy-propagation, MemArg offset folding, local RLE compaction, and post-link dead-function/constant pruning)
4. **Runtime Execution Performance in V8 (Node.js)** — Transpiles and instantiates 13 compute and image-processing workloads via `transpile({ optimize: 'ReleaseFast' })` + `zigar-runtime` across `wazig`, `wazigl`, `zig (-fno-llvm)`, and `zig (LLVM)`, running warmup iterations followed by timed iterations (`performance.now()`) and reporting `median`, `mean`, `min`, and `p95` (in `ms`):
   - **Benchmarks Game**: `nbody`, `fannkuch-redux`, `spectral-norm`, `mandelbrot`, `binary-trees`, `fasta`
   - **Image Processing**: `polish-flag`, `resize`, `greyscale`, `sepia`, `circle-pattern`, `raytracer`, `mandelbulb-quick`

---

## Prerequisites

- **Node.js** `>= 20` (Node.js `24+` recommended for V8 `--experimental-wasm-growable-stacks` & `--experimental-wasm-wasmfx`; with `zigar-compiler` dependencies installed in `../zigar-compiler/node_modules` and `zigar-runtime` built in `../zigar-runtime/dist`)
- **`wazig`** (`v0.17.0-wazig.6`) on `PATH` (wrapped with `wasmtime`)
- **`wazigl`** (`v0.17.0-wazigl.6`) on `PATH` (wrapped with `wasmtime`)
- **`zig`** (`0.17.0`) on `PATH`

---

## Running Locally

### Quick Mode (Smoke Check & Fast Verification)

Runs all 4 benchmark dimensions with reduced iteration counts and category-shared cold cache baselines:

```sh
node benchmarks/wazig-benchmark.js --quick
```

### Full Mode (Default)

Runs all 4 benchmark dimensions with full cold-cache builds across every module and full V8 timing sample counts:

```sh
node benchmarks/wazig-benchmark.js
```

### Custom Output Paths & Cache Directory

By default, the script writes:
- Markdown report: `benchmarks/RESULTS.md` (and prints the Markdown report to `stdout`)
- Structured JSON data: `benchmarks/results.json`

You can override output paths via CLI flags:

```sh
node benchmarks/wazig-benchmark.js \
  --quick \
  --json benchmarks/results.json \
  --markdown benchmarks/RESULTS.md
```

### CLI Options

| Flag | Description | Default |
| :--- | :--- | :--- |
| `--quick` | Fewer iterations/samples and category-seeded cold cache baselines for fast verification | `false` (full mode) |
| `--json <path>` | Output path for structured JSON benchmark results | `benchmarks/results.json` |
| `--markdown <path>` | Output path for formatted Markdown benchmark report | `benchmarks/RESULTS.md` |
| `--help`, `-h` | Show CLI usage information | — |

---

## Running in CI (GitHub Actions)

Example GitHub Actions step to run the benchmark suite and upload `RESULTS.md` + `results.json` as workflow artifacts and step summary:

```yaml
jobs:
  wazig-benchmarks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '22'

      - name: Install dependencies and build zigar-runtime
        run: |
          npm --prefix zigar-runtime ci
          npm --prefix zigar-runtime run build
          npm --prefix zigar-compiler ci

      - name: Run wazig vs zig benchmark suite
        run: |
          node benchmarks/wazig-benchmark.js --quick >> "$GITHUB_STEP_SUMMARY"

      - name: Upload benchmark artifacts
        uses: actions/upload-artifact@v4
        with:
          name: wazig-benchmark-results
          path: |
            benchmarks/RESULTS.md
            benchmarks/results.json
```

---

## Summary of Key Findings (from [`RESULTS.md`](./RESULTS.md))

| Dimension | Standard `zig` (`0.17.0`) | `wazigl` (`v0.17.0-wazigl.6`) | `wazig` (`v0.17.0-wazig.6`) | Impact |
| :--- | :--- | :--- | :--- | :--- |
| **Release Download Size** | `52.88–100.27 MB` per OS/arch (`419.77 MB` across 6 desktop targets) | **`38.02 MB` (`36.26 MiB`)** single universal `wasm64-wasip3` archive (with LLVM 22 + Clang) | **`8.47 MB` (`8.08 MiB`)** single universal `wasm64-wasip3` archive (self-hosted `stage2_wasm`) | `wazig`: **6.24x–11.8x smaller** per target (**49.57x** vs 6 targets); `wazigl`: **1.39x–2.64x smaller** (**11.04x** vs 6 targets) |
| **Installed Disk Footprint** | `360.34 MB` (`343.65 MiB`, `19,505` files) | **`232.34 MB` (`221.57 MiB`, `1,322` files)** | **`61.72 MB` (`58.87 MiB`, `1,322` files)** | `wazig`: **5.84x smaller**, **14.75x fewer files**; `wazigl`: **1.55x smaller**, **14.75x fewer files** |
| **Cold `translate-c` Latency** | `~54,625 ms` (compiles external `lib/compiler/translate-c` via LLVM) | **`~1,327 ms`** (in-process Clang C frontend inside `wazigl.wasm`) | **`~212 ms`** (in-process Aro C frontend inside `wazig.wasm`) | `wazig`: **~258x faster**; `wazigl`: **~41.2x faster** cold C-header translation |
| **Cold C-Import Compile (`print.zig`)** | `~57,290 ms` (`zig build-exe`) | **`~14,289 ms`** (`wazigl build-exe`) | **`~8,176 ms`** (`wazig build-exe`) | `wazig`: **7.01x faster**; `wazigl`: **4.01x faster** end-to-end cold compile |
| **Multithreaded WASM (`thread.zig`, `atomic.zig`)** | **Fails out-of-the-box** (`WasmAllocator` unimplemented; `-fno-llvm` lacks `naked`/TLS) | **Works out-of-the-box** (built-in `WasmAllocator`, `wasi-thread`, LLVM TLS/atomics) | **Works out-of-the-box** (built-in `WasmAllocator`, `wasi-thread`, `stage2_wasm` TLS/atomics) | **Zero manual stdlib patching required in `wazig` or `wazigl`** |
| **Libc `-lc` Reactor Linking (`dupe.zig`)** | `-fno-llvm` **fails** (`libc.a: undefined function: __main_argc_argv`); LLVM links musl `libc.a` | **Works out-of-the-box** across all 4 optimize modes via pure-Zig `libzigc.a` | **Works out-of-the-box** across all 4 optimize modes via pure-Zig `libzigc.a` | **Pure-Zig `libzigc.a` in both `wazig` and `wazigl`** |
| **`Debug` `.wasm` Binary Size** | `1,804–3,535 KiB` raw / `232–288 KiB` stripped (`-lc`) | `1,451–3,345 KiB` raw / `171–235 KiB` stripped | **`158–484 KiB` raw / `105–136 KiB` stripped** | `wazig`: **7.30x–11.40x smaller raw**, **45%–59% smaller stripped** |
| **`ReleaseSmall` Stripped vs `zig -fno-llvm`** | `153–550 KiB` stripped (fails to inline `getFactoryThunk`; crashes `stripUnused()` in other modes) | **`31–46 KiB` stripped** (byte-for-byte parity with native `zig (Pure-Zig LLVM)`) | **`60–85 KiB` stripped** (MIR + SROA + `Optimizer.zig` + post-link pruning) | `wazig`: **2.47x–7.32x smaller stripped** than `zig -fno-llvm`; `wazigl`: **exact LLVM size parity** |
| **V8 Runtime Execution (`ReleaseFast`)** | `zig -fno-llvm`: `5.86–2,048.67 ms`; `zig (LLVM)`: `0.36–186.45 ms` | **`0.40–189.72 ms`** (**1.00x parity** with native `zig (LLVM)`) | **`2.92–266.85 ms`** (**0.97x–12.04x faster** than `zig -fno-llvm`; matches LLVM on `nbody` & `fannkuch-redux`) | `wazig` up to **12.04x faster** than `-fno-llvm`; `wazigl` **1.00x parity** with native LLVM |

---

## V8 Stack Switching & `wit-zigar` ABI Benchmarks

In addition to the `wazig` vs `zig` toolchain suite, `benchmarks/` includes three reproducible benchmark & prototype suites for V8 WebAssembly stack switching and `wit-zigar` Component Model Canonical ABI vs `"zigar:abi"` comptime fast-path execution (require Node.js 24+ / V8 13.6+):

```sh
# 1. V8 --experimental-wasm-growable-stacks vs fixed 984 KB JSPI stacks benchmark
node benchmarks/wasm-stack-switching-benchmark.js

# 2. V8 --experimental-wasm-wasmfx, Wasmtime 50.0.1 stack-switching, and dual-stack global[0] prototype
node benchmarks/wasmfx-prototype.js

# 3. wit-zigar Component Model Canonical ABI (cabi_realloc) vs "zigar:abi" zero-copy fast path & zigar bridge
node benchmarks/wit-zigar-benchmark.js
```

See [**`benchmarks/STACK-SWITCHING-RESULTS.md`**](./STACK-SWITCHING-RESULTS.md) for the complete empirical report, memory/latency tables, `wit-zigar` ABI comparisons, and `zigar-runtime` / `wazig` architectural analysis.

