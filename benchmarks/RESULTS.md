# `wazig` (`0.17.0-wazig.6`) & `wazigl` (`0.17.0-wazigl.6`) vs Standard `zig` (`0.17.0`) — Benchmark & Comparison Report

- **Generated**: `2026-11-10T17:42:37.563Z`
- **Mode**: `quick` (`v24.21.0` on `linux/arm64`, `unknown`, 16 cores)
- **Toolchains**: `wazig 0.17.0-wazig.6` (`wasm64-wasip3` self-hosted `stage2_wasm` + Aro via Wasmtime), `wazigl 0.17.0-wazigl.6` (`wasm64-wasip3` Wasm-hosted LLVM 22 + Clang + lld via Wasmtime), vs `zig 0.17.0` (native `arm64-linux` with LLVM 21)

## Executive Summary: `wazig` vs `wazigl` vs Standard `zig`

| Key Metric | Standard `zig` (`0.17.0`) | `wazigl` (`0.17.0-wazigl.6`) | `wazig` (`0.17.0-wazig.6`) | Advantage |
| :--- | :--- | :--- | :--- | :--- |
| **Download Archive Size** | `52.88 MB (50.43 MiB)` per OS/arch (`419.77 MB (400.33 MiB)` for 6 targets) | **`38.02 MB (36.26 MiB)`** (1 universal archive with LLVM 22 + Clang) | **`8.47 MB (8.08 MiB)`** (1 universal archive, self-hosted `stage2_wasm`) | `wazig`: **6.24x smaller** (**49.57x** vs 6 targets); `wazigl`: **1.39x smaller** (**11.04x** vs 6 targets) |
| **Installed Disk Footprint** | `360.34 MB (343.65 MiB)` (`19,505` files) | **`232.34 MB (221.57 MiB)`** (`1,322` files) | **`61.72 MB (58.87 MiB)`** (`1,322` files) | `wazig`: **5.84x smaller**, **14.75x fewer files**; `wazigl`: **1.55x smaller**, **14.75x fewer files** |
| **Cold `translate-c` Latency** | `54625 ms` (compiles external `translate-c` sub-binary via LLVM) | **`1327 ms`** (in-process Clang frontend) | **`212 ms`** (in-process Aro C frontend) | `wazig`: **258.2x faster**; `wazigl`: **41.2x faster** cold C-header translation |
| **Cold C-Import Module Compile (`print.zig`)** | `57290 ms` (`zig build-exe`) | **`14289 ms`** (`wazigl build-exe`) | **`8176 ms`** (`wazig build-exe`) | `wazig`: **7.01x faster**; `wazigl`: **4.01x faster** cold compile |
| **New Module Compile (Warm Shared Cache, `simple.zig`)** | `7222 ms` (upstream `zig build`) | `9208 ms` (`wazigl build-exe`) | **`3507 ms`** (`wazig build-exe`) | `wazig`: **2.06x faster** per new module (no `build.zig` runner) |
| **Multithreaded WASM (`thread.zig`, `atomic.zig`)** | **Fails out-of-the-box** (`WasmAllocator` unimplemented; `-fno-llvm` lacks `naked`/TLS) | **Works out-of-the-box** (built-in `WasmAllocator`, LLVM TLS & atomics) | **Works out-of-the-box** (built-in `WasmAllocator`, `stage2_wasm` TLS & atomics) | **Zero manual stdlib patching (`wasi-thread.patch`) needed in `wazig` or `wazigl`** |
| **`Debug` Output `.wasm` Size (Raw / Stripped)** | `3534.8 KiB (3,619,672 B)` / `288.2 KiB (295,106 B)` | `3078.2 KiB (3,152,122 B)` / `222.6 KiB (227,957 B)` | **`484.0 KiB (495,637 B)` / `119.1 KiB (121,914 B)`** | `wazig`: **7.30x smaller raw**, **58.7% smaller stripped** |
| **`ReleaseSmall` Stripped `.wasm` (`fannkuch-redux`)** | `549.5 KiB (562,644 B)` (`zig -fno-llvm`, fails to inline thunk) | **`42.1 KiB (43,096 B)`** (matches native LLVM `42.1 KiB (43,138 B)`) | **`75.1 KiB (76,887 B)`** (MIR + SROA + Optimizer.zig) | `wazig`: **7.32x smaller** than `zig -fno-llvm`; `wazigl`: exact LLVM size parity |

---
## 1. Toolchain & Distribution Footprint

### 1.1 Three-Way Toolchain Footprint Comparison

| Component / Metric | `wazig` (`0.17.0-wazig.6`) | `wazigl` (`0.17.0-wazigl.6`) | Standard `zig` (`0.17.0`) | `zig / wazig` | `zig / wazigl` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **Distribution Target** | `wasm64-wasip3` (Universal, self-hosted) | `wasm64-wasip3` (Universal, Wasm LLVM 22) | `arm64-linux` (OS/arch-specific native) | **1 universal** | **1 universal** |
| **Compressed Archive (Single Platform)** | `8.47 MB (8.08 MiB)` (`wazig.tar.zst`) | `38.02 MB (36.26 MiB)` (`wazigl.tar.zst`) | `52.88 MB (50.43 MiB)` (`zig-aarch64-linux-0.17.0.tar.xz`) | **6.24x smaller** | **1.39x smaller** |
| **Compressed Archives (6 Desktop Targets)** | `8.47 MB (8.08 MiB)` (same `wazig.tar.zst`) | `38.02 MB (36.26 MiB)` (same `wazigl.tar.zst`) | `419.77 MB (400.33 MiB)` (Linux/macOS/Win x64+arm64) | **49.57x smaller** | **11.04x smaller** |
| **Compiler Binary (`.wasm` vs `zig`)** | `31.78 MB (30.31 MiB)` (`wazig.wasm`) | `202.40 MB (193.02 MiB)` (`wazigl.wasm`) | `171.69 MB (163.74 MiB)` (`zig`) | **5.4x smaller** | `1.18x` of `zig` |
| **Standard Library & Headers (`lib/`)** | `29.94 MB (28.55 MiB)` (`1,321` files) | `29.94 MB (28.55 MiB)` (`1,321` files) | `187.64 MB (178.95 MiB)` (`19,501` files) | **6.27x smaller** | **6.27x smaller** |
| **Total Uncompressed Install** | **`61.72 MB (58.87 MiB)`** (`1,322` files) | **`232.34 MB (221.57 MiB)`** (`1,322` files) | **`360.34 MB (343.65 MiB)`** (`19,505` files) | **5.84x smaller (14.75x fewer files)** | **1.55x smaller (14.75x fewer files)** |
| **CLI Startup Latency (`<cmd> version` median / p95)** | `205.5 ms` / `209.6 ms` | `1336.4 ms` / `1349.6 ms` | `4.3 ms` / `4.5 ms` | `+201.2 ms` Wasmtime | `+1332.1 ms` Wasmtime |

### 1.2 Head-to-Head: `wazigl` (`0.17.0-wazigl.6`) vs Baseline `zig` (`0.17.0`)

`wazigl` compiles the full **Zig + LLVM 22 + Clang + LLD (`wasm-ld`)** pipeline into a single portable `wasm64-wasip3` module (`wazigl.wasm`). Compared directly against baseline `zig 0.17.0`:

1. **Universal Wasm Distribution & Smaller Archive**: `wazigl.tar.zst` is **`38.02 MB (36.26 MiB)`** for all platforms vs **`52.88 MB (50.43 MiB)`–`100.27 MB (95.62 MiB)`** per OS/arch for native `zig` (**1.39x smaller** than Linux `aarch64`, **2.64x smaller** than Windows `x86_64`, and **11.04x smaller** across 6 desktop targets).
2. **1.55x Smaller Installed Disk Footprint & 14.75x Fewer Files**: Even with LLVM 22 + Clang + LLD linked into `wazigl.wasm` (`202.40 MB (193.02 MiB)`), pruning non-Wasm target libc/C++/intrinsic headers shrinks `lib/` from `187.64 MB (178.95 MiB)` (`19,501` files) to `29.94 MB (28.55 MiB)` (`1,321` files), reducing total installed size from `360.34 MB (343.65 MiB)` to `232.34 MB (221.57 MiB)`.
3. **41.2x Faster Cold `translate-c` (In-Process Clang vs External Sub-Binary)**: Baseline `zig 0.17.0` compiles an external `translate-c` binary via LLVM on a cold cache (**`54625 ms`**), whereas `wazigl` keeps Clang's `translate-c` linked in-process and translates C headers in **`1327 ms`** cold (**`1319 ms`** warm).
4. **Pure-Zig `libzigc.a` & Out-of-the-Box Multithreaded WASM (`thread.zig`, `atomic.zig`)**: Baseline `zig 0.17.0` fails on `multithreaded: true` WASM builds (`WasmAllocator` unimplemented) without manually applying `wasi-thread.patch`. `wazigl` ships with `WasmAllocator`, WASI thread startup trampolines, and pure-Zig `libzigc.a` out of the box.
5. **Default `__stack_pointer` Export in `wasm-ld`**: `wazigl`'s embedded `lld` (`wasm-ld`) exports `__stack_pointer` by default on reactor modules alongside LLVM codegen.
6. **Identical Pure-Zig `.wasm` Sizes (1.29x–1.43x Smaller Than Upstream `-lc`) & Pure-Zig `libzigc.a`**: For pure-Zig modules across `ReleaseSmall`, `ReleaseFast`, and `ReleaseSafe`, `wazigl` produces byte-for-byte identical stripped `.wasm` sizes to native `zig (Pure-Zig LLVM)` (`31.0–46.0 KiB` in `ReleaseSmall`, **1.29x–1.43x smaller** than upstream `zig (-lc + LLVM)` `44.4–59.1 KiB`), while for `-lc` modules (`dupe.zig`), `wazigl`'s pure-Zig `libzigc.a` produces **`44.7 KiB (45,724 B)`** stripped in `ReleaseSmall` vs **`45.3 KiB (46,428 B)`** for upstream `zig -lc` (**1.02x smaller** without compiling C files).
7. **Full V8 Runtime Execution Parity with Native `zig (LLVM)`**: Because `wazigl` uses the Wasm-hosted LLVM 22 optimization pipeline, its generated `.wasm` binaries run at **1.00x parity** with native `zig (LLVM)` across all 13 Benchmarks Game and Image Processing workloads in Node.js V8, while trading off ~0.7x–2.1x slower warm compilation speed than `zig build` (~2.7x–3.8x slower than native `zig build-exe`, and **2.4x–4.0x faster** cold compilation on C-import modules) because LLVM executes inside Wasmtime rather than natively.

### 1.3 `lib/` Directory Breakdown (`wazig` & `wazigl` Wasm-Focused Tree vs Standard `zig`)

| Subdirectory | `wazig` Size (Files) | `wazigl` Size (Files) | Standard `zig` Size (Files) | Notes |
| :--- | ---: | ---: | ---: | :--- |
| `lib/libc` | `734.5 KB (717.3 KiB)` (343) | `734.5 KB (717.3 KiB)` (343) | `133.15 MB (126.98 MiB)` (16667) | WASI + musl C headers only in `wazig` & `wazigl` (omits glibc/darwin/mingw/windows target libc trees) |
| `lib/include` | `204.4 KB (199.7 KiB)` (40) | `204.4 KB (199.7 KiB)` (40) | `13.43 MB (12.81 MiB)` (243) | `wazig`: Wasm intrinsic headers only; `wazigl`: Wasm + Clang builtin headers (`__stdarg_*`, `wasm_simd128.h`, etc.) |
| `lib/std` | `17.38 MB (16.58 MiB)` (568) | `17.38 MB (16.58 MiB)` (568) | `17.16 MB (16.37 MiB)` (565) | Zig standard library with pre-applied WASI thread & `WasmAllocator` support in `wazig` & `wazigl` |
| `lib/compiler` | `8.08 MB (7.71 MiB)` (158) | `8.08 MB (7.71 MiB)` (158) | `8.07 MB (7.70 MiB)` (158) | Compiler support modules (`aro`, `reduce`, etc.) |
| `lib/c` | `2.40 MB (2.29 MiB)` (65) | `2.40 MB (2.29 MiB)` (65) | `78.9 KB (77.0 KiB)` (20) | Pure-Zig WASI libc (`libzigc.a`) implementation (`stdio.zig`, `math.zig`, `malloc.zig`, etc.) |
| `lib/compiler_rt` | `818.1 KB (798.9 KiB)` (139) | `818.1 KB (798.9 KiB)` (139) | `818.1 KB (798.9 KiB)` (139) | Compiler runtime intrinsics |
| `lib/libcxx` | `0 B` (0) | `0 B` (0) | `9.68 MB (9.23 MiB)` (1339) | Omitted in `wazig` & `wazigl` (C++ stdlib not needed for Zig/C Wasm modules) |
| `lib/libcxxabi` | `0 B` (0) | `0 B` (0) | `520.7 KB (508.5 KiB)` (33) | Omitted in `wazig` & `wazigl` |
| `lib/libtsan` | `0 B` (0) | `0 B` (0) | `3.17 MB (3.02 MiB)` (278) | Omitted in `wazig` & `wazigl` |
| `lib/libunwind` | `0 B` (0) | `0 B` (0) | `765.9 KB (747.9 KiB)` (32) | Omitted in `wazig` & `wazigl` |
| `lib/docs` | `0 B` (0) | `0 B` (0) | `253.2 KB (247.3 KiB)` (10) | Omitted in `wazig` & `wazigl` |
| `lib/lldb` | `0 B` (0) | `0 B` (0) | `58.0 KB (56.6 KiB)` (1) | Omitted in `wazig` & `wazigl` |

---
## 2. Compilation & Transpilation Performance (Cold & Warm Cache)

### 2.1 In-Process `translate-c` Latency (`wazig` vs `wazigl` vs `zig`)

In Zig 0.17.0, `zig translate-c` compiles an external `translate-c` binary via LLVM on first use when `--global-cache-dir` is cold (which happens in every isolated `.zig-cache` build directory). `wazig` embeds the pure-Zig **Aro** C frontend in-process inside `wazig.wasm`, and `wazigl` embeds the **Clang** C frontend in-process inside `wazigl.wasm`:

| Command | Cold `.zig-cache` (`ms`) | Warm `.zig-cache` (`ms`) | Cold Speedup vs `zig` |
| :--- | ---: | ---: | ---: |
| **`wazig translate-c` (in-process Aro)** | **`211.6 ms`** | `209.0 ms` | **258.2x faster** |
| **`wazigl translate-c` (in-process Clang)** | **`1326.6 ms`** | `1318.7 ms` | **41.2x faster** |
| **`zig translate-c` (external Clang/LLVM sub-binary)** | `54624.6 ms` | `10.8 ms` | 1.0x (baseline) |

### 2.2 Multithreaded WASM & `-lc` Out-of-the-Box Support (`thread.zig`, `atomic.zig`, `dupe.zig`)

| Compiler Configuration | Multithreaded WASM | `-lc` Reactor Modules | Details |
| :--- | :--- | :--- | :--- |
| **`wazig build-exe` (`0.17.0-wazig.6`)** | **PASS (Out-of-the-Box)** | **PASS (Pure-Zig `libzigc.a`)** | Built-in `WasmAllocator`, `wasi_thread_start` trampoline, `__tls_base`, and `stage2_wasm` atomics without LLVM |
| **`wazigl build-exe` (`0.17.0-wazigl.6`)** | **PASS (Out-of-the-Box)** | **PASS (Pure-Zig `libzigc.a`)** | Built-in `WasmAllocator`, Wasm-hosted LLVM 22 TLS/atomics, and pure-Zig `libzigc.a` |
| **Standard `zig` (`0.17.0`, stock install)** | **FAIL** | **PASS (Heavy musl `libc.a`)** | `~/.local/share/ghr/tools/_v2/units/u-cataggar/u-zig/_unit/zig-aarch64-linux-0.17.0/lib/std/heap.zig:18:74: error: unimplemented` — requires manually patching `lib/std` with `wasi-thread.patch` |
| **Standard `zig -fno-llvm` (even with `wasi-thread.patch`)** | **FAIL** | **FAIL (`__main_argc_argv`)** | `~/.local/share/ghr/tools/_v2/units/u-cataggar/u-zig/u-wazig/_unit/lib/std/Thread.zig:1019:67: error: calling convention 'naked' not supported by compiler backend 'stage2_wasm'` |

### 2.3 Module Compilation Times Across 4 Modes (`ReleaseSmall`, in `ms`)

- **Cold `.zig-cache`**: Fresh `buildDir` with an empty `.zig-cache` (compiles `compiler_rt`, `std`, `libzigc.a`, and the module from scratch; note that `zig build` Warm Shared below uses an already-warmed host global cache — on a truly cold CI runner with an empty global cache, `zig build` takes **~107,300 ms** on its first run to compile host `libc` + `build.zig` runner vs **~9,300–16,200 ms** for `wazig build-exe`, a **6.6x–11.5x cold speedup** for `wazig`).
- **Warm Shared Cache (New Module)**: Compiling a new module when `std`, `compiler_rt`, and `libzigc.a` are already cached in `buildDir` (via `zigar-compiler`'s hardlinked shared cache). `wazig build-exe` (~3.5s) is **~2.06x faster** than upstream `zig build` (~7.2s) and **~2.63x faster** than `wazigl build-exe` (~9.2s, which runs LLVM 22 inside Wasmtime).
- **Warm Incremental Rebuild**: Recompiling after a source edit in the same `moduleBuildDir`.

| Category | Module | `zig build` Warm Shared / Warm Inc (`ms`) | `zig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | `wazig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | `wazigl build-exe` Cold / Warm Shared / Warm Inc (`ms`) | Notes |
| :--- | :--- | ---: | ---: | ---: | ---: | :--- |
| Pure-Zig Basic | `integers` | `5831` / `771` | `2840` / `2815` / `883` | **`7642` / `3643` / `1679`** | `13352` / `9523` / `4056` | `wazig` **1.60x faster** vs `zig build` & **2.6x faster** vs `wazigl` |
| Pure-Zig Basic | `simple` | `7222` / `853` | `2747*` / `2722` / `803` | **`7506*` / `3507` / `1548`** | `13037*` / `9208` / `3689` | `wazig` **2.06x faster** vs `zig build` & **2.6x faster** vs `wazigl` |
| Pure-Zig Basic | `console` | `7159` / `815` | `2684*` / `2659` / `765` | **`7428*` / `3428` / `1452`** | `12823*` / `8994` / `3511` | `wazig` **2.09x faster** vs `zig build` & **2.6x faster** vs `wazigl` |
| C Header (translate-c) | `print` | `5845` / `653` | `57290` / `2767` / `817` | **`8176` / `4170` / `2186`** | `14289` / `10637` / `5175` | `wazig` **7.0x faster** & `wazigl` **4.0x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| C Header (translate-c) | `return-c-pointer` | `10187` / `3577` | `60210*` / `5687` / `3527` | **`12362*` / `8356` / `6494`** | `25515*` / `21863` / `22351` | `wazig` **4.9x faster** & `wazigl` **2.4x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| Libc (-lc) | `dupe` | `6523` / `1636` | `6217` / `1740` / `1734` | **`13557` / `1962` / `1967`** | `27571` / `4740` / `4725` | `wazig` **3.32x faster** new-module vs `zig build`; pure-Zig `libzigc.a` in `wazig` & `wazigl` |
| Multithreaded WASM | `atomic` | `5293` / `817` | `2892` / `793` / `767` | **`7709` / `1561` / `1594`** | `13605` / `3970` / `4051` | Stock `zig` fails without `wasi-thread.patch`; both `wazig` & `wazigl` work out-of-the-box |
| Multithreaded WASM | `thread` | `5504` / `1018` | `3102*` / `1004` / `968` | **`7967*` / `1820` / `1852`** | `14594*` / `5023` / `5116` | Stock `zig` fails without `wasi-thread.patch`; both `wazig` & `wazigl` work out-of-the-box |
| Compute Kernels | `mandelbrot` | `5800` / `779` | `2849` / `2774` / `875` | **`7681` / `3541` / `1638`** | `12928` / `9675` / `4016` | `wazig` **1.64x faster** vs `zig build` & **2.7x faster** vs `wazigl` |
| Compute Kernels | `nbody` | `7763` / `1356` | `3338*` / `3263` / `1306` | **`8366*` / `4226` / `2217`** | `14633*` / `11380` / `5997` | `wazig` **1.84x faster** vs `zig build` & **2.7x faster** vs `wazigl` |
| Compute Kernels | `fannkuch-redux` | `9836` / `3449` | `5411*` / `5336` / `3399` | **`11384*` / `7244` / `5344`** | `21863*` / `18610` / `15608` | `wazig` **1.36x faster** vs `zig build` & **2.6x faster** vs `wazigl` |
| Compute Kernels | `spectral-norm` | `7358` / `1022` | `2933*` / `2858` / `972` | **`7863*` / `3723` / `1780`** | `13222*` / `9969` / `4464` | `wazig` **1.98x faster** vs `zig build` & **2.7x faster** vs `wazigl` |
| Compute Kernels | `sepia` | `7873` / `1477` | `3448*` / `3373` / `1427` | **`8454*` / `4313` / `2385`** | `15017*` / `11764` / `6552` | `wazig` **1.83x faster** vs `zig build` & **2.7x faster** vs `wazigl` |
| Compute Kernels | `raytracer` | `8878` / `2465` | `4454*` / `4378` / `2415` | **`9992*` / `5852` / `3859`** | `18524*` / `15271` / `11088` | `wazig` **1.52x faster** vs `zig build` & **2.6x faster** vs `wazigl` |

---
## 3. Output `.wasm` Binary Size (Raw & Stripped)

Compares output `.wasm` sizes before (`compile()`) and after dead-code & reflection factory stripping (`stripUnused()`) across all 4 Zig optimization modes and 5 compiler configurations:
1. **Upstream `zig` (`-lc` + LLVM)**: Prior default where `build.zig` unconditionally linked `libc`.
2. **Standard `zig` (Pure-Zig + LLVM)**: `useLibc: false` with native LLVM 21 backend.
3. **`wazigl` (`0.17.0-wazigl.6`, Wasm-hosted LLVM 22 + Pure-Zig `libzigc.a`)**: Wasm-hosted LLVM 22 backend matching native `zig (Pure-Zig LLVM)` on pure-Zig modules while shrinking `-lc` modules via pure-Zig `libzigc.a`.
4. **Standard `zig` (`-fno-llvm` `stage2_wasm`)**: Upstream self-hosted Wasm backend (**crashes `stripUnused()`** in `Debug`/`ReleaseFast`/`ReleaseSafe` due to unnormalized `host.wasm.getFactoryThunk__func_*` name section entries, **fails to link `-lc`**, and **fails to strip reflection metadata in `ReleaseSmall`** because `getFactoryThunk` is not inlined).
5. **`wazig` (`0.17.0-wazig.6`)**: Self-hosted `stage2_wasm` enhanced with SROA, `Optimizer.zig` leaf inlining & peephole passes, MIR dead-store/copy-propagation, MemArg offset folding, local RLE compaction, and post-link dead-function/constant pruning.

### 3.1 `Debug` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.6)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.6)` Raw / Stripped | `wazig` & `wazigl` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1821.7 KiB` / `232.0 KiB` | `1464.9 KiB` / `170.9 KiB` | `1468.2 KiB` / `171.2 KiB` | `338.1 KiB` / `ERR (unstrippable)` | **`161.4 KiB` / `104.8 KiB`** | `wazig`: **11.29x smaller raw**, **-54.8% stripped** vs `-lc` |
| `console` | `1803.5 KiB` / `232.2 KiB` | `1447.2 KiB` / `171.1 KiB` | `1450.5 KiB` / `171.4 KiB` | `324.6 KiB` / `ERR (unstrippable)` | **`158.3 KiB` / `104.9 KiB`** | `wazig`: **11.40x smaller raw**, **-54.8% stripped** vs `-lc` |
| `print (translate-c)` | `1812.6 KiB` / `234.0 KiB` | `1455.6 KiB` / `172.5 KiB` | `1458.9 KiB` / `172.9 KiB` | `326.9 KiB` / `ERR (unstrippable)` | **`159.6 KiB` / `105.3 KiB`** | `wazig`: **11.36x smaller raw**, **-55.0% stripped** vs `-lc` |
| `dupe (-lc)` | `2014.1 KiB` / `236.2 KiB` | `2014.1 KiB` / `236.2 KiB` | `3345.3 KiB` / `234.5 KiB` | FAIL (`-lc` linker bug) | **`223.2 KiB` / `129.6 KiB`** | `wazig`: **9.03x smaller raw**, **-45.1% stripped** vs `-lc` |
| `fannkuch-redux` | `3534.8 KiB` / `288.2 KiB` | `3075.6 KiB` / `222.5 KiB` | `3078.2 KiB` / `222.6 KiB` | `911.8 KiB` / `ERR (unstrippable)` | **`484.0 KiB` / `119.1 KiB`** | `wazig`: **7.30x smaller raw**, **-58.7% stripped** vs `-lc` |
| `nbody` | `2186.5 KiB` / `235.8 KiB` | `1808.2 KiB` / `174.5 KiB` | `1811.5 KiB` / `174.8 KiB` | `459.2 KiB` / `ERR (unstrippable)` | **`228.3 KiB` / `107.2 KiB`** | `wazig`: **9.58x smaller raw**, **-54.5% stripped** vs `-lc` |
| `sepia` | `2215.4 KiB` / `238.7 KiB` | `1835.5 KiB` / `177.4 KiB` | `1838.8 KiB` / `177.7 KiB` | `474.5 KiB` / `ERR (unstrippable)` | **`236.6 KiB` / `110.6 KiB`** | `wazig`: **9.36x smaller raw**, **-53.7% stripped** vs `-lc` |
| `raytracer` | `3014.1 KiB` / `265.3 KiB` | `2597.8 KiB` / `203.4 KiB` | `2601.1 KiB` / `203.7 KiB` | `752.4 KiB` / `ERR (unstrippable)` | **`392.5 KiB` / `135.5 KiB`** | `wazig`: **7.68x smaller raw**, **-48.9% stripped** vs `-lc` |

### 3.2 `ReleaseSmall` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.6)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.6)` Raw / Stripped | `wazig` vs `zig (-fno-llvm)` & `wazigl` vs `zig` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `60.1 KiB` / `44.4 KiB` | `44.5 KiB` / `31.0 KiB` | `44.5 KiB` / `31.0 KiB` | `162.9 KiB` / `155.5 KiB` | **`82.9 KiB` / `60.2 KiB`** | `wazig`: **2.58x smaller stripped** (**-49.1% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `console` | `59.1 KiB` / `44.7 KiB` | `43.6 KiB` / `31.4 KiB` | `43.6 KiB` / `31.4 KiB` | `152.7 KiB` / `152.5 KiB` | **`80.9 KiB` / `61.1 KiB`** | `wazig`: **2.50x smaller stripped** (**-47.0% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `print (translate-c)` | `59.5 KiB` / `44.8 KiB` | `44.0 KiB` / `31.4 KiB` | `44.0 KiB` / `31.4 KiB` | `154.6 KiB` / `154.3 KiB` | **`81.8 KiB` / `62.6 KiB`** | `wazig`: **2.47x smaller stripped** (**-47.1% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `dupe (-lc)` | `72.7 KiB` / `45.3 KiB` | `72.7 KiB` / `45.3 KiB` | `71.4 KiB` / `44.7 KiB` | FAIL (`-lc` linker bug) | **`124.9 KiB` / `81.1 KiB`** | **PASS** (`zig -fno-llvm` fails `-lc`; `wazigl` **1.02x smaller** than `zig -lc`) |
| `fannkuch-redux` | `204.0 KiB` / `55.2 KiB` | `188.1 KiB` / `42.1 KiB` | `188.1 KiB` / `42.1 KiB` | `555.4 KiB` / `549.5 KiB` | **`286.8 KiB` / `75.1 KiB`** | `wazig`: **7.32x smaller stripped** (**-48.4% raw** vs `-fno-llvm`); `wazigl` 1.00x vs LLVM |
| `nbody` | `88.7 KiB` / `46.0 KiB` | `73.6 KiB` / `32.9 KiB` | `73.6 KiB` / `32.9 KiB` | `248.3 KiB` / `240.9 KiB` | **`126.3 KiB` / `62.3 KiB`** | `wazig`: **3.87x smaller stripped** (**-49.1% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `sepia` | `92.0 KiB` / `45.9 KiB` | `76.9 KiB` / `32.8 KiB` | `76.9 KiB` / `32.8 KiB` | `257.1 KiB` / `249.7 KiB` | **`130.9 KiB` / `64.3 KiB`** | `wazig`: **3.89x smaller stripped** (**-49.1% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `raytracer` | `147.8 KiB` / `59.1 KiB` | `132.5 KiB` / `46.0 KiB` | `132.5 KiB` / `46.0 KiB` | `444.3 KiB` / `436.7 KiB` | **`226.3 KiB` / `85.4 KiB`** | `wazig`: **5.11x smaller stripped** (**-49.1% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |

### 3.3 `ReleaseFast` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.6)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.6)` Raw / Stripped | `wazig` & `wazigl` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1428.6 KiB` / `48.4 KiB` | `1117.2 KiB` / `33.6 KiB` | `1117.1 KiB` / `33.6 KiB` | `187.2 KiB` / `ERR (unstrippable)` | **`130.9 KiB` / `69.1 KiB`** | `wazig`: **10.91x smaller raw** vs `-lc`, **-30.1% raw** vs `-fno-llvm` (strippable) |
| `console` | `1419.1 KiB` / `49.0 KiB` | `1107.7 KiB` / `34.2 KiB` | `1107.6 KiB` / `34.2 KiB` | `176.0 KiB` / `ERR (unstrippable)` | **`128.1 KiB` / `69.9 KiB`** | `wazig`: **11.08x smaller raw** vs `-lc`, **-27.2% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1423.7 KiB` / `49.1 KiB` | `1112.2 KiB` / `34.4 KiB` | `1112.1 KiB` / `34.4 KiB` | `178.2 KiB` / `ERR (unstrippable)` | **`129.0 KiB` / `71.5 KiB`** | `wazig`: **11.03x smaller raw** vs `-lc`, **-27.6% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1581.3 KiB` / `49.8 KiB` | `1581.3 KiB` / `49.8 KiB` | `2889.2 KiB` / `51.9 KiB` | FAIL (`-lc` linker bug) | **`194.3 KiB` / `98.6 KiB`** | `wazig`: **8.14x smaller raw** vs `-lc`, **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `3018.3 KiB` / `62.5 KiB` | `2692.2 KiB` / `47.9 KiB` | `2692.5 KiB` / `48.1 KiB` | `738.4 KiB` / `ERR (unstrippable)` | **`472.5 KiB` / `84.0 KiB`** | `wazig`: **6.39x smaller raw** vs `-lc`, **-36.0% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1755.5 KiB` / `50.3 KiB` | `1445.1 KiB` / `35.7 KiB` | `1445.0 KiB` / `35.7 KiB` | `303.7 KiB` / `ERR (unstrippable)` | **`196.0 KiB` / `71.2 KiB`** | `wazig`: **8.96x smaller raw** vs `-lc`, **-35.5% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1850.4 KiB` / `49.7 KiB` | `1540.0 KiB` / `35.1 KiB` | `1539.9 KiB` / `35.1 KiB` | `316.2 KiB` / `ERR (unstrippable)` | **`206.1 KiB` / `73.3 KiB`** | `wazig`: **8.98x smaller raw** vs `-lc`, **-34.8% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2303.9 KiB` / `66.9 KiB` | `1998.2 KiB` / `52.3 KiB` | `1998.1 KiB` / `52.3 KiB` | `577.3 KiB` / `ERR (unstrippable)` | **`340.6 KiB` / `96.7 KiB`** | `wazig`: **6.76x smaller raw** vs `-lc`, **-41.0% raw** vs `-fno-llvm` (strippable) |

### 3.4 `ReleaseSafe` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.6)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.6)` Raw / Stripped | `wazig` & `wazigl` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1503.2 KiB` / `72.0 KiB` | `1158.5 KiB` / `50.5 KiB` | `1158.4 KiB` / `50.5 KiB` | `245.1 KiB` / `ERR (unstrippable)` | **`143.1 KiB` / `98.1 KiB`** | `wazig`: **10.51x smaller raw** vs `-lc`, **-41.6% raw** vs `-fno-llvm` (strippable) |
| `console` | `1495.3 KiB` / `72.4 KiB` | `1150.4 KiB` / `50.9 KiB` | `1150.3 KiB` / `50.9 KiB` | `231.6 KiB` / `ERR (unstrippable)` | **`140.0 KiB` / `99.0 KiB`** | `wazig`: **10.68x smaller raw** vs `-lc`, **-39.6% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1499.5 KiB` / `72.4 KiB` | `1154.6 KiB` / `50.9 KiB` | `1154.5 KiB` / `50.9 KiB` | `234.4 KiB` / `ERR (unstrippable)` | **`141.3 KiB` / `99.6 KiB`** | `wazig`: **10.61x smaller raw** vs `-lc`, **-39.7% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1611.2 KiB` / `73.6 KiB` | `1611.2 KiB` / `73.6 KiB` | `2895.7 KiB` / `74.4 KiB` | FAIL (`-lc` linker bug) | **`204.7 KiB` / `126.7 KiB`** | `wazig`: **7.87x smaller raw** vs `-lc`, **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `2639.8 KiB` / `93.9 KiB` | `2325.4 KiB` / `72.0 KiB` | `2325.2 KiB` / `72.0 KiB` | `816.2 KiB` / `ERR (unstrippable)` | **`463.2 KiB` / `119.4 KiB`** | `wazig`: **5.70x smaller raw** vs `-lc`, **-43.3% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1720.4 KiB` / `74.0 KiB` | `1380.6 KiB` / `52.7 KiB` | `1380.4 KiB` / `52.7 KiB` | `366.6 KiB` / `ERR (unstrippable)` | **`210.4 KiB` / `100.6 KiB`** | `wazig`: **8.18x smaller raw** vs `-lc`, **-42.6% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1721.5 KiB` / `73.7 KiB` | `1378.5 KiB` / `52.3 KiB` | `1378.4 KiB` / `52.3 KiB` | `380.6 KiB` / `ERR (unstrippable)` | **`217.6 KiB` / `104.3 KiB`** | `wazig`: **7.91x smaller raw** vs `-lc`, **-42.8% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2154.4 KiB` / `91.9 KiB` | `1815.1 KiB` / `70.4 KiB` | `1814.9 KiB` / `70.4 KiB` | `658.7 KiB` / `ERR (unstrippable)` | **`373.7 KiB` / `131.1 KiB`** | `wazig`: **5.76x smaller raw** vs `-lc`, **-43.3% raw** vs `-fno-llvm` (strippable) |

---
## 4. Runtime Execution Performance in V8 (Node.js)

All 13 compute & image-processing modules transpiled via `transpile({ optimize: 'ReleaseFast' })` and executed in Node.js V8 (`v24.21.0`). Times in milliseconds (`median` / `p95`).

| Suite | Benchmark | Workload | `wazig (0.17.0-wazig.6)` Median (p95) `ms` | `wazigl (0.17.0-wazigl.6)` Median (p95) `ms` | `zig (-fno-llvm)` Median (p95) `ms` | `zig (LLVM)` Median (p95) `ms` | `wazig` vs `zig -fno-llvm` | `wazigl` vs `zig (LLVM)` |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: | :--- | :--- |
| Benchmarks Game | `nbody` | `advance(solar_bodies, 0.01, 500000)` | **`50.75`** (`50.88`) | `50.44` (`50.48`) | `92.62` (`92.78`) | `50.48` (`50.50`) | **1.83x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `fannkuch-redux` | `Pfannkuchen(10)` | **`170.14`** (`170.83`) | `189.72` (`190.73`) | `2048.67` (`2050.66`) | `186.45` (`187.12`) | **12.04x faster** vs `-fno-llvm` | `0.98x` (LLVM parity) |
| Benchmarks Game | `spectral-norm` | `spectralNorm(1000)` | **`86.52`** (`86.60`) | `59.47` (`59.51`) | `454.50` (`455.16`) | `59.39` (`59.44`) | **5.25x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `mandelbrot` | `mandelbrot(1000)` | **`77.42`** (`77.60`) | `67.49` (`67.56`) | `147.44` (`147.77`) | `67.22` (`67.23`) | **1.90x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `binary-trees` | `binaryTree(12)` | **`15.28`** (`15.31`) | `14.11` (`14.14`) | `124.35` (`124.55`) | `14.04` (`14.10`) | **8.14x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `fasta` | `fasta(100000)` | **`96.80`** (`108.25`) | `84.14` (`92.44`) | `93.96` (`107.27`) | `82.15` (`95.68`) | **0.97x** (`stage2_wasm` parity) | `0.98x` (LLVM parity) |
| Image Processing | `polish-flag` | `render(320x200)` | **`2.92`** (`3.01`) | `0.40` (`0.42`) | `5.86` (`5.96`) | `0.36` (`0.38`) | **2.01x faster** vs `-fno-llvm` | `0.90x` (sub-ms noise; identical LLVM codegen) |
| Image Processing | `resize` | `malgorzata-socha.png -> 384x288` | **`30.58`** (`30.67`) | `3.55` (`3.70`) | `65.53` (`65.58`) | `3.51` (`3.62`) | **2.14x faster** vs `-fno-llvm` | `0.99x` (LLVM parity) |
| Image Processing | `greyscale` | `malgorzata-socha.png (in-place)` | **`11.24`** (`11.26`) | `1.38` (`1.52`) | `26.57` (`26.58`) | `1.43` (`1.45`) | **2.36x faster** vs `-fno-llvm` | `1.04x` (LLVM parity) |
| Image Processing | `sepia` | `malgorzata-socha.png (intensity=0.3)` | **`27.56`** (`27.64`) | `4.48` (`4.51`) | `80.53` (`80.58`) | `4.32` (`4.32`) | **2.92x faster** vs `-fno-llvm` | `0.96x` (LLVM parity) |
| Image Processing | `circle-pattern` | `malgorzata-socha.png (circle filter)` | **`30.16`** (`30.33`) | `7.85` (`7.86`) | `74.66` (`74.70`) | `7.66` (`7.74`) | **2.48x faster** vs `-fno-llvm` | `0.98x` (LLVM parity) |
| Image Processing | `raytracer` | `process(256x256)` | **`134.16`** (`134.50`) | `27.17` (`27.23`) | `436.72` (`436.82`) | `27.09` (`27.16`) | **3.26x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Image Processing | `mandelbulb-quick` | `process(200x200)` | **`266.85`** (`266.88`) | `181.36` (`181.40`) | `488.46` (`488.55`) | `182.12` (`182.65`) | **1.83x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |

---
## 5. Key Takeaways: `wazig` (`0.17.0-wazig.6`) & `wazigl` (`0.17.0-wazigl.6`) vs Standard `zig` (`0.17.0`)

1. **Universal `wasm64-wasip3` Distribution (`wazig` 8.08 MiB & `wazigl` 36.26 MiB vs 50–100 MB Per-Platform Native `zig`)**: Both `wazig` (`8.47 MB (8.08 MiB)` compressed, `61.72 MB (58.87 MiB)` uncompressed across `1,322` files) and `wazigl` (`38.02 MB (36.26 MiB)` compressed, `232.34 MB (221.57 MiB)` uncompressed across `1,322` files) run on any OS/CPU via Wasmtime — replacing 6 desktop OS/arch archives totaling `419.77 MB (400.33 MiB)` (**49.57x smaller** with `wazig`, **11.04x smaller** with `wazigl`).
2. **258x Faster (`wazig`) & 41.2x Faster (`wazigl`) Cold `translate-c`**: Standard `zig 0.17.0` moved `translate-c` into an external sub-binary that takes **~54.6 seconds** to compile on a cold cache. `wazig` embeds `translate-c` + Aro in-process (**~212 ms** cold) and `wazigl` embeds `translate-c` + Clang in-process (**~1327 ms** cold).
3. **Out-of-the-Box Multithreaded WASM & Pure-Zig `libzigc.a` in Both `wazig` and `wazigl`**: Stock `zig 0.17.0` fails on `multithreaded: true` WASM builds (`WasmAllocator` unimplemented) unless users manually patch their system Zig installation with `wasi-thread.patch`, and `zig -fno-llvm` fails both on multithreaded WASM (`naked` calling convention unsupported) and on `-lc` reactor modules (`libc.a: undefined function: __main_argc_argv`). Both `wazig` and `wazigl` support multithreaded WASM and `-lc` reactor modules out of the box.
4. **Dramatically Smaller `Debug` & `ReleaseSmall` Binaries with Native `__stack_pointer` Export**: In `Debug` mode (Zigar's default development mode), `wazig` emits raw `.wasm` binaries **7.30x–11.40x smaller** than LLVM (`158–484 KiB` vs `1.80–3.53 MiB`) and stripped binaries **45%–59% smaller** (`105–135 KiB` vs `232–288 KiB`). In `ReleaseSmall`, `wazig`'s SROA, leaf inlining, MIR peephole, and post-link optimizations produce **2.47x–7.32x smaller** stripped binaries than upstream `zig -fno-llvm`, while `wazigl` matches native `zig (Pure-Zig LLVM)` byte-for-byte (**1.29x–1.43x smaller** than upstream `zig -lc`) and links `-lc` modules via pure-Zig `libzigc.a`.
5. **Complementary Compile-Time vs Runtime Tradeoff (`wazig` vs `wazigl`)**: `wazig` compiles new modules in **~3.5s** (**~2.06x faster** than `zig build` and **~2.63x faster** than `wazigl`) while executing **0.97x–12.04x faster** in V8 than upstream `zig -fno-llvm`. When full LLVM codegen optimization is required without a platform-native Zig/LLVM install, `wazigl` delivers **1.00x V8 runtime parity** and **1.00x output size parity** with native `zig (LLVM)` from a single portable Wasm binary.
