# `wazig` (`v0.17.0-wazig.3`) vs Standard `zig` (`0.17.0`) — Benchmark Suite

Reproducible Node.js ESM benchmark and comparison suite (`wazig-benchmark.js`) measuring **`wazig` (`v0.17.0-wazig.3`)** against **standard `zig` (`0.17.0`)** across all four dimensions relevant to `zigar-compiler` and `zigar-runtime`:

1. **Toolchain & Distribution Footprint** — Compressed download archive sizes, installed disk footprint (`wazig.wasm` + Wasm-focused `lib/` vs native `zig` binary + multi-target `lib/`), file counts, `lib/` subdirectory breakdown, and CLI startup latency (`wazig version` vs `zig version`).
2. **Compilation & Transpilation Performance (Cold & Warm Cache)** — Compares three compilation pipelines across 14 representative Zig modules (Pure-Zig basic, C header `translate-c`, Libc `-lc`, Multithreaded WASM, and Compute Kernels):
   - **`zig build` (Upstream baseline)**: `zigPath: 'zig', useBuildExe: false`
   - **`zig build-exe` (Native Zig fast-path)**: `zigPath: 'zig', useBuildExe: true`
   - **`wazig build-exe` (`v0.17.0-wazig.3`)**: `zigPath: 'wazig', useBuildExe: true`
   Measures cold `.zig-cache` compilation, warm shared `.zig-cache` compilation (where `std`, `compiler_rt`, `libzigc.a`, and `translate-c` are cached), and warm incremental rebuilds after a source edit, plus a direct `translate-c` cold vs warm microbenchmark and out-of-the-box multithreaded WASM verification.
3. **Output `.wasm` Binary Size (Raw & Stripped)** — Measures raw (`compile()`) and dead-code/reflection-stripped (`stripUnused()`) `.wasm` binary sizes across all four Zig optimization modes (`Debug`, `ReleaseSmall`, `ReleaseFast`, `ReleaseSafe`) for:
   - `zig 0.17.0` with upstream `-lc` + LLVM (`useLibc: true, useLLVM: true`)
   - `zig 0.17.0` pure-Zig + LLVM (`useLibc: false, useLLVM: true`)
   - `zig 0.17.0` self-hosted `stage2_wasm` (`useLibc: false, useLLVM: false`)
   - `wazig v0.17.0-wazig.3` (`stage2_wasm` + MIR dead-store/copy-propagation, MemArg offset folding, local RLE compaction, trivial callee inlining, and post-link dead-function/constant pruning)
4. **Runtime Execution Performance in V8 (Node.js)** — Transpiles and instantiates 13 compute and image-processing workloads via `transpile({ optimize: 'ReleaseFast' })` + `zigar-runtime`, running warmup iterations followed by timed iterations (`performance.now()`) and reporting `median`, `mean`, `min`, and `p95` (in `ms`):
   - **Benchmarks Game**: `nbody`, `fannkuch-redux`, `spectral-norm`, `mandelbrot`, `binary-trees`, `fasta`
   - **Image Processing**: `polish-flag`, `resize`, `greyscale`, `sepia`, `circle-pattern`, `raytracer`, `mandelbulb-quick`

---

## Prerequisites

- **Node.js** `>= 20` (with `zigar-compiler` dependencies installed in `../zigar-compiler/node_modules` and `zigar-runtime` built in `../zigar-runtime/dist`)
- **`wazig`** (`v0.17.0-wazig.3`) on `PATH` (wrapped with `wasmtime`)
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

| Dimension | Standard `zig` (`0.17.0`) | `wazig` (`v0.17.0-wazig.3`) | Impact |
| :--- | :--- | :--- | :--- |
| **Release Download Size** | `52.9–100.3 MB` per OS/arch (`419.8 MB` across 6 desktop targets) | **`8.86 MB` (`8.45 MiB`)** single universal `wasm64-wasip3` archive | **5.97x–11.3x smaller** per target; **47.4x smaller** across 6 targets |
| **Installed Disk Footprint** | `360.34 MB` (`343.65 MiB`, `19,505` files) | **`71.24 MB` (`67.94 MiB`, `1,322` files)** | **5.06x smaller** on disk, **14.75x fewer files** |
| **Cold `translate-c` Latency** | `~61,744 ms` (compiles external `lib/compiler/translate-c` via LLVM) | **`~319 ms`** (in-process Aro C frontend inside `wazig.wasm`) | **~194x faster** cold C-header translation |
| **Cold C-Import Compile (`print.zig`)** | `~62,636 ms` (`zig build-exe`) | **`~18,549 ms`** (`wazig build-exe`) | **3.38x faster** end-to-end cold compile |
| **Multithreaded WASM (`thread.zig`, `atomic.zig`)** | **Fails out-of-the-box** (`WasmAllocator` unimplemented; `-fno-llvm` lacks `naked`/TLS) | **Works out-of-the-box** (built-in `WasmAllocator`, `wasi-thread`, `stage2_wasm` TLS/atomics) | **Zero manual stdlib patching or LLVM required** |
| **Libc `-lc` Reactor Linking (`dupe.zig`)** | `-fno-llvm` **fails** (`libc.a: undefined function: __main_argc_argv`); LLVM compiles ~400 C files | **Works out-of-the-box** across all 4 optimize modes via pure-Zig `libzigc.a` | **Pure-Zig `libzigc.a` without Clang/LLVM** |
| **`Debug` `.wasm` Binary Size** | `1,804–3,535 KiB` raw / `232–288 KiB` stripped (`-lc`) | **`226–737 KiB` raw / `147–186 KiB` stripped** | **4.8x–8.0x smaller raw**, **23%–37% smaller stripped** |
| **`ReleaseSmall` Stripped vs `zig -fno-llvm`** | `152–549 KiB` stripped (fails to inline `getFactoryThunk`; crashes `stripUnused()` in other modes) | **`93–129 KiB` stripped** (MIR + post-link dead-code & RLE compaction) | **1.6x–4.27x smaller stripped** than upstream `stage2_wasm` |
