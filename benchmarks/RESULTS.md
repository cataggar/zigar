# `wazig` (`0.17.0-wazig.3`) vs Standard `zig` (`0.17.0`) — Benchmark & Comparison Report

- **Generated**: `2026-11-05T07:30:40.392Z`
- **Mode**: `quick` (`v22.15.0` on `linux/arm64`, `unknown`, 16 cores)
- **Toolchains**: `wazig 0.17.0-wazig.3` (`wasm64-wasip3` via Wasmtime) vs `zig 0.17.0` (native `arm64-linux` with LLVM 21)

## Executive Summary: Why Switch to `wazig` + `build-exe`?

| Key Metric | Standard `zig` (`0.17.0`) | `wazig` (`0.17.0-wazig.3`) | Advantage |
| :--- | :--- | :--- | :--- |
| **Download Archive Size** | `52.88 MB (50.43 MiB)` per OS/arch (`419.77 MB (400.33 MiB)` for 6 targets) | **`8.86 MB (8.45 MiB)`** (1 universal archive for all OS/arch) | **5.97x smaller** per platform (**47.4x smaller** across 6 targets) |
| **Installed Disk Footprint** | `360.34 MB (343.65 MiB)` (`19,505` files) | **`71.24 MB (67.94 MiB)`** (`1,322` files) | **5.06x smaller** on disk, **14.75x fewer files** |
| **Cold `translate-c` Latency** | `61744 ms` (compiles external `translate-c` via LLVM) | **`319 ms`** (in-process Aro C frontend) | **193.6x faster** cold C-header translation |
| **Cold C-Import Module Compile (`print.zig`)** | `62688 ms` (`zig build-exe`) | **`18746 ms`** (`wazig build-exe`) | **3.34x faster** end-to-end cold compile |
| **New Module Compile (Warm Global Cache, `simple.zig`)** | `6261 ms` (upstream `zig build`) | **`3059 ms`** (`wazig build-exe` shared cache) | **2.05x faster** per new module (no `build.zig` runner) |
| **Multithreaded WASM (`thread.zig`, `atomic.zig`)** | **Fails out-of-the-box** (`WasmAllocator` unimplemented; `-fno-llvm` lacks `naked`/TLS) | **Works out-of-the-box** (built-in `WasmAllocator`, `stage2_wasm` TLS & atomics) | **Zero manual stdlib patching (`wasi-thread.patch`) or LLVM needed** |
| **`Debug` Output `.wasm` Size (Raw / Stripped)** | `3534.8 KiB (3,619,678 B)` / `288.2 KiB (295,106 B)` | **`737.4 KiB (755,141 B)` / `183.9 KiB (188,330 B)`** | **4.79x smaller raw**, **36.2% smaller stripped** |
| **`ReleaseSmall` Stripped `.wasm` vs `zig -fno-llvm`** | `549.4 KiB (562,626 B)` (fails to inline factory thunk) | **`128.7 KiB (131,806 B)`** (MIR + post-link dead-code & RLE opt) | **4.27x smaller** than upstream `stage2_wasm` |

---
## 1. Toolchain & Distribution Footprint

| Component / Metric | `wazig` (`0.17.0-wazig.3`) | Standard `zig` (`0.17.0`) | Ratio (`zig / wazig`) |
| :--- | ---: | ---: | ---: |
| **Distribution Target** | `wasm64-wasip3` (Single universal binary) | `arm64-linux` (OS/arch-specific binary) | **1 universal vs N platform builds** |
| **Compressed Archive (Single Platform)** | `8.86 MB (8.45 MiB)` (`wazig.tar.zst`) | `52.88 MB (50.43 MiB)` (`zig-aarch64-linux-0.17.0.tar.xz`) | **5.97x smaller** |
| **Compressed Archives (6 Desktop Targets)** | `8.86 MB (8.45 MiB)` (same `wazig.tar.zst`) | `419.77 MB (400.33 MiB)` (Linux/macOS/Windows x64+arm64) | **47.4x smaller** |
| **Compiler Binary (`wazig.wasm` vs `zig`)** | `41.35 MB (39.43 MiB)` | `171.69 MB (163.74 MiB)` | **4.15x smaller** |
| **Standard Library & Headers (`lib/`)** | `29.90 MB (28.51 MiB)` (`1,321` files) | `187.64 MB (178.95 MiB)` (`19,501` files) | **6.28x smaller** |
| **Total Uncompressed Install** | **`71.24 MB (67.94 MiB)`** (`1,322` files) | **`360.34 MB (343.65 MiB)`** (`19,505` files) | **5.06x smaller (14.75x fewer files)** |
| **CLI Startup Latency (`<cmd> version` median / p95)** | `313.9 ms` / `318.4 ms` | `5.1 ms` / `5.3 ms` | `+308.9 ms` Wasmtime init |

### `lib/` Directory Breakdown (`wazig` Wasm-Focused Tree vs Standard `zig`)

| Subdirectory | `wazig` Size (Files) | Standard `zig` Size (Files) | Notes |
| :--- | ---: | ---: | :--- |
| `lib/libc` | `734.5 KB (717.3 KiB)` (343) | `133.15 MB (126.98 MiB)` (16667) | WASI + musl C headers only in `wazig` (omits glibc/darwin/mingw/windows target libc trees) |
| `lib/include` | `204.4 KB (199.7 KiB)` (40) | `13.43 MB (12.81 MiB)` (243) | Wasm-focused intrinsic headers only (omits x86 AVX/AMX/SSE, ARM Neon/SVE, Hexagon, PPC headers) |
| `lib/std` | `17.34 MB (16.53 MiB)` (568) | `17.16 MB (16.37 MiB)` (565) | Zig standard library with pre-applied WASI thread & `WasmAllocator` support |
| `lib/compiler` | `8.08 MB (7.71 MiB)` (158) | `8.07 MB (7.70 MiB)` (158) | Compiler support modules (`aro`, `reduce`, etc.) |
| `lib/c` | `2.40 MB (2.29 MiB)` (65) | `78.9 KB (77.0 KiB)` (20) | Pure-Zig WASI libc (`libzigc.a`) implementation (`stdio.zig`, `math.zig`, `malloc.zig`, etc.) |
| `lib/compiler_rt` | `818.1 KB (798.9 KiB)` (139) | `818.1 KB (798.9 KiB)` (139) | Compiler runtime intrinsics |
| `lib/libcxx` | `0 B` (0) | `9.68 MB (9.23 MiB)` (1339) | Omitted in `wazig` (C++ stdlib not needed for Zig/C Wasm modules) |
| `lib/libcxxabi` | `0 B` (0) | `520.7 KB (508.5 KiB)` (33) | Omitted in `wazig` |
| `lib/libtsan` | `0 B` (0) | `3.17 MB (3.02 MiB)` (278) | Omitted in `wazig` |
| `lib/libunwind` | `0 B` (0) | `765.9 KB (747.9 KiB)` (32) | Omitted in `wazig` |
| `lib/docs` | `0 B` (0) | `253.2 KB (247.3 KiB)` (10) | Omitted in `wazig` |
| `lib/lldb` | `0 B` (0) | `58.0 KB (56.6 KiB)` (1) | Omitted in `wazig` |

---
## 2. Compilation & Transpilation Performance (Cold & Warm Cache)

### 2.1 In-Process `translate-c` Latency (`wazig` vs `zig`)

In Zig 0.17.0, `zig translate-c` compiles an external `translate-c` binary via LLVM on first use when `--global-cache-dir` is cold (which happens in every isolated `.zig-cache` build directory). `wazig` embeds the pure-Zig **Aro** C frontend and `translate-c` translator directly in-process inside `wazig.wasm`:

| Command | Cold `.zig-cache` (`ms`) | Warm `.zig-cache` (`ms`) | Cold Speedup |
| :--- | ---: | ---: | ---: |
| **`wazig translate-c` (in-process Aro)** | **`319.0 ms`** | `310.0 ms` | **193.6x faster** |
| **`zig translate-c` (external Clang/LLVM sub-binary)** | `61743.9 ms` | `11.8 ms` | 1.0x (baseline) |

### 2.2 Multithreaded WASM Out-of-the-Box Support (`thread.zig`, `atomic.zig`)

| Compiler Configuration | Out-of-the-Box Status | Details |
| :--- | :--- | :--- |
| **`wazig build-exe` (`0.17.0-wazig.3`)** | **PASS (Out-of-the-Box)** | Ships with thread-safe `WasmAllocator`, `wasi_thread_start` naked/clothed trampoline, `__tls_base`, and `stage2_wasm` atomics without LLVM |
| **Standard `zig` (`0.17.0`, stock install)** | **FAIL** | `/home/g/.local/share/ghr/tools/_v2/units/u-cataggar/u-zig/_unit/zig-aarch64-linux-0.17.0/lib/std/heap.zig:18:74: error: unimplemented` — requires manually patching `lib/std` with `wasi-thread.patch` |
| **Standard `zig -fno-llvm` (even with `wasi-thread.patch`)** | **FAIL** | `/home/g/.local/share/ghr/tools/_v2/units/u-cataggar/u-zig/u-wazig/_unit/lib/std/Thread.zig:1019:67: error: calling convention 'naked' not supported by compiler backend 'stage2_wasm'` |

### 2.3 Module Compilation Times Across 3 Modes (`ReleaseSmall`, in `ms`)

- **Cold `.zig-cache`**: Fresh `buildDir` with an empty `.zig-cache` (compiles `compiler_rt`, `std`, `libzigc.a`, and the module from scratch; note that `zig build` Warm Shared below uses an already-warmed host global cache — on a truly cold CI runner with an empty global cache, `zig build` takes **~107,300 ms** on its first run to compile host `libc` + `build.zig` runner vs **~17,500 ms** for `wazig build-exe`, a **6.1x cold speedup** for `wazig`).
- **Warm Shared Cache (New Module)**: Compiling a new module when `std`, `compiler_rt`, and `libzigc.a` are already cached in `buildDir` (via `zigar-compiler`'s hardlinked shared cache). `wazig build-exe` (~3.0–3.4s) is **~1.9x–2.1x faster** than upstream `zig build` (~6.2–6.5s) because it skips compiling and running a per-module `build.zig` runner.
- **Warm Incremental Rebuild**: Recompiling after a source edit in the same `moduleBuildDir`.

| Category | Module | `zig build` Warm Shared / Warm Inc (`ms`) | `zig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | `wazig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | Notes |
| :--- | :--- | ---: | ---: | ---: | :--- |
| Pure-Zig Basic | `integers` | `6346` / `843` | `3086` / `1021` / `1056` | **`17486` / `3401` / `3389`** | `wazig` **1.87x faster** new-module vs `zig build` (`3.4s` vs `6.3s`) |
| Pure-Zig Basic | `simple` | `6261` / `1006` | `3002*` / `937` / `956` | **`17143*` / `3059` / `3044`** | `wazig` **2.05x faster** new-module vs `zig build` (`3.1s` vs `6.3s`) |
| Pure-Zig Basic | `console` | `6239` / `987` | `2980*` / `915` / `937` | **`16986*` / `2901` / `2860`** | `wazig` **2.15x faster** new-module vs `zig build` (`2.9s` vs `6.2s`) |
| C Header (translate-c) | `print` | `6207` / `723` | `62688` / `967` / `918` | **`18746` / `4477` / `4473`** | `wazig` **3.3x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| C Header (translate-c) | `return-c-pointer` | `9246` / `4222` | `65726*` / `4006` / `4172` | **`28349*` / `14080` / `14279`** | `wazig` **2.3x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| Libc (-lc) | `dupe` | `7164` / `1775` | `34121` / `1896` / `1917` | **`15942` / `3898` / `3859`** | `wazig` **1.84x faster** new-module vs `zig build`; pure-Zig `libzigc.a` |
| Multithreaded WASM | `thread` | `6425` / `1094` | `3166*` / `1101` / `1044` | **`17833*` / `3748` / `3727`** | Stock `zig` fails without manual `wasi-thread.patch`; `wazig` works out-of-the-box |
| Multithreaded WASM | `atomic` | `6178` / `889` | `3185` / `854` / `839` | **`17865` / `3185` / `3168`** | Stock `zig` fails without manual `wasi-thread.patch`; `wazig` works out-of-the-box |
| Compute Kernels | `mandelbrot` | `6322` / `811` | `3085` / `1045` / `1018` | **`17353` / `3260` / `3221`** | `wazig` **1.94x faster** new-module vs `zig build` (`3.3s` vs `6.3s`) |
| Compute Kernels | `nbody` | `6788` / `1571` | `3550*` / `1511` / `1521` | **`18621*` / `4528` / `4564`** | `wazig` **1.50x faster** new-module vs `zig build` (`4.5s` vs `6.8s`) |
| Compute Kernels | `fannkuch-redux` | `9071` / `3772` | `5834*` / `3794` / `3722` | **`25881*` / `11787` / `11781`** | `wazig` **0.77x faster** new-module vs `zig build` (`11.8s` vs `9.1s`) |
| Compute Kernels | `spectral-norm` | `6410` / `1144` | `3172*` / `1132` / `1094` | **`17714*` / `3620` / `3612`** | `wazig` **1.77x faster** new-module vs `zig build` (`3.6s` vs `6.4s`) |
| Compute Kernels | `sepia` | `6959` / `1677` | `3722*` / `1682` / `1627` | **`18948*` / `4854` / `4826`** | `wazig` **1.43x faster** new-module vs `zig build` (`4.9s` vs `7.0s`) |
| Compute Kernels | `raytracer` | `8045` / `2764` | `4807*` / `2767` / `2714` | **`22241*` / `8147` / `8220`** | `wazig` **0.99x faster** new-module vs `zig build` (`8.1s` vs `8.0s`) |

---
## 3. Output `.wasm` Binary Size (Raw & Stripped)

Compares output `.wasm` sizes before (`compile()`) and after dead-code & reflection factory stripping (`stripUnused()`) across all 4 Zig optimization modes:
1. **Upstream `zig` (`-lc` + LLVM)**: Prior default where `build.zig` unconditionally linked `libc`.
2. **Standard `zig` (Pure-Zig + LLVM)**: `useLibc: false` with LLVM 21 backend.
3. **Standard `zig` (`-fno-llvm` `stage2_wasm`)**: Upstream self-hosted Wasm backend (**crashes `stripUnused()`** in `Debug`/`ReleaseFast`/`ReleaseSafe` due to unnormalized `host.wasm.getFactoryThunk__func_*` name section entries, and **fails to strip reflection metadata in `ReleaseSmall`** because `getFactoryThunk` is not inlined).
4. **`wazig` (`v0.17.0-wazig.3`)**: Self-hosted `stage2_wasm` enhanced with MIR dead-store/copy-propagation, MemArg offset folding, local RLE compaction, trivial callee inlining, and post-link dead-function/constant pruning.

### 3.1 `Debug` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.3)` Raw / Stripped | `wazig` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1821.7 KiB` / `232.0 KiB` | `1464.9 KiB` / `170.9 KiB` | `338.1 KiB` / `ERR (unstrippable)` | **`230.6 KiB` / `147.2 KiB`** | **7.90x smaller raw**, **-36.6% stripped** vs `-lc` |
| `console` | `1803.5 KiB` / `232.2 KiB` | `1447.2 KiB` / `171.1 KiB` | `324.6 KiB` / `ERR (unstrippable)` | **`226.2 KiB` / `147.1 KiB`** | **7.97x smaller raw**, **-36.6% stripped** vs `-lc` |
| `print (translate-c)` | `1812.6 KiB` / `234.0 KiB` | `1455.6 KiB` / `172.5 KiB` | `326.9 KiB` / `ERR (unstrippable)` | **`228.3 KiB` / `147.9 KiB`** | **7.94x smaller raw**, **-36.8% stripped** vs `-lc` |
| `dupe (-lc)` | `2014.1 KiB` / `236.2 KiB` | `2014.1 KiB` / `236.2 KiB` | FAIL (`-lc` linker bug) | **`324.3 KiB` / `182.2 KiB`** | **6.21x smaller raw**, **-22.9% stripped** vs `-lc` |
| `fannkuch-redux` | `3534.8 KiB` / `288.2 KiB` | `3075.6 KiB` / `222.5 KiB` | `911.8 KiB` / `ERR (unstrippable)` | **`737.4 KiB` / `183.9 KiB`** | **4.79x smaller raw**, **-36.2% stripped** vs `-lc` |
| `nbody` | `2186.5 KiB` / `235.8 KiB` | `1808.2 KiB` / `174.5 KiB` | `459.2 KiB` / `ERR (unstrippable)` | **`336.9 KiB` / `150.8 KiB`** | **6.49x smaller raw**, **-36.0% stripped** vs `-lc` |
| `sepia` | `2215.4 KiB` / `238.7 KiB` | `1835.5 KiB` / `177.4 KiB` | `474.5 KiB` / `ERR (unstrippable)` | **`347.5 KiB` / `154.2 KiB`** | **6.37x smaller raw**, **-35.4% stripped** vs `-lc` |
| `raytracer` | `3014.1 KiB` / `265.3 KiB` | `2597.8 KiB` / `203.4 KiB` | `752.4 KiB` / `ERR (unstrippable)` | **`594.2 KiB` / `186.2 KiB`** | **5.07x smaller raw**, **-29.8% stripped** vs `-lc` |

### 3.2 `ReleaseSmall` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.3)` Raw / Stripped | `wazig` vs `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `60.1 KiB` / `44.4 KiB` | `44.5 KiB` / `31.0 KiB` | `162.9 KiB` / `155.5 KiB` | **`135.7 KiB` / `93.1 KiB`** | **1.67x smaller stripped** (**-16.7% raw** vs `-fno-llvm`) |
| `console` | `59.1 KiB` / `44.7 KiB` | `43.6 KiB` / `31.4 KiB` | `152.7 KiB` / `152.4 KiB` | **`132.8 KiB` / `94.4 KiB`** | **1.62x smaller stripped** (**-13.0% raw** vs `-fno-llvm`) |
| `print (translate-c)` | `59.5 KiB` / `44.8 KiB` | `44.0 KiB` / `31.4 KiB` | `154.6 KiB` / `154.3 KiB` | **`134.4 KiB` / `97.2 KiB`** | **1.59x smaller stripped** (**-13.0% raw** vs `-fno-llvm`) |
| `dupe (-lc)` | `72.7 KiB` / `45.3 KiB` | `72.7 KiB` / `45.3 KiB` | FAIL (`-lc` linker bug) | **`204.8 KiB` / `124.0 KiB`** | **PASS** (`zig -fno-llvm` fails to link `-lc`) |
| `fannkuch-redux` | `204.0 KiB` / `55.2 KiB` | `188.1 KiB` / `42.1 KiB` | `555.4 KiB` / `549.4 KiB` | **`481.4 KiB` / `128.7 KiB`** | **4.27x smaller stripped** (**-13.3% raw** vs `-fno-llvm`) |
| `nbody` | `88.7 KiB` / `46.0 KiB` | `73.6 KiB` / `32.9 KiB` | `248.3 KiB` / `240.9 KiB` | **`210.2 KiB` / `96.4 KiB`** | **2.50x smaller stripped** (**-15.3% raw** vs `-fno-llvm`) |
| `sepia` | `92.0 KiB` / `45.9 KiB` | `76.9 KiB` / `32.8 KiB` | `257.1 KiB` / `249.7 KiB` | **`216.4 KiB` / `98.1 KiB`** | **2.54x smaller stripped** (**-15.9% raw** vs `-fno-llvm`) |
| `raytracer` | `147.8 KiB` / `59.1 KiB` | `132.5 KiB` / `46.0 KiB` | `444.3 KiB` / `436.7 KiB` | **`386.3 KiB` / `124.9 KiB`** | **3.50x smaller stripped** (**-13.0% raw** vs `-fno-llvm`) |

### 3.3 `ReleaseFast` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.3)` Raw / Stripped | `wazig` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1428.6 KiB` / `48.4 KiB` | `1117.2 KiB` / `33.6 KiB` | `187.2 KiB` / `ERR (unstrippable)` | **`158.3 KiB` / `93.9 KiB`** | **9.02x smaller raw** vs `-lc`; **-15.4% raw** vs `-fno-llvm` (strippable) |
| `console` | `1419.1 KiB` / `49.0 KiB` | `1107.7 KiB` / `34.2 KiB` | `176.0 KiB` / `ERR (unstrippable)` | **`154.9 KiB` / `95.2 KiB`** | **9.16x smaller raw** vs `-lc`; **-12.0% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1423.7 KiB` / `49.1 KiB` | `1112.2 KiB` / `34.4 KiB` | `178.2 KiB` / `ERR (unstrippable)` | **`156.8 KiB` / `98.1 KiB`** | **9.08x smaller raw** vs `-lc`; **-12.0% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1581.3 KiB` / `49.8 KiB` | `1581.3 KiB` / `49.8 KiB` | FAIL (`-lc` linker bug) | **`247.0 KiB` / `125.6 KiB`** | **6.40x smaller raw** vs `-lc`; **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `3018.3 KiB` / `62.5 KiB` | `2692.2 KiB` / `47.9 KiB` | `738.4 KiB` / `ERR (unstrippable)` | **`645.1 KiB` / `131.7 KiB`** | **4.68x smaller raw** vs `-lc`; **-12.6% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1755.5 KiB` / `50.3 KiB` | `1445.1 KiB` / `35.7 KiB` | `303.7 KiB` / `ERR (unstrippable)` | **`260.4 KiB` / `97.2 KiB`** | **6.74x smaller raw** vs `-lc`; **-14.3% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1850.4 KiB` / `49.7 KiB` | `1540.0 KiB` / `35.1 KiB` | `316.2 KiB` / `ERR (unstrippable)` | **`268.3 KiB` / `99.1 KiB`** | **6.90x smaller raw** vs `-lc`; **-15.1% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2303.9 KiB` / `66.9 KiB` | `1998.2 KiB` / `52.3 KiB` | `577.3 KiB` / `ERR (unstrippable)` | **`499.1 KiB` / `125.9 KiB`** | **4.62x smaller raw** vs `-lc`; **-13.5% raw** vs `-fno-llvm` (strippable) |

### 3.4 `ReleaseSafe` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.3)` Raw / Stripped | `wazig` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1503.2 KiB` / `72.0 KiB` | `1158.5 KiB` / `50.5 KiB` | `245.1 KiB` / `ERR (unstrippable)` | **`211.4 KiB` / `140.1 KiB`** | **7.11x smaller raw** vs `-lc`; **-13.7% raw** vs `-fno-llvm` (strippable) |
| `console` | `1495.3 KiB` / `72.4 KiB` | `1150.4 KiB` / `50.9 KiB` | `231.6 KiB` / `ERR (unstrippable)` | **`207.1 KiB` / `141.0 KiB`** | **7.22x smaller raw** vs `-lc`; **-10.6% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1499.5 KiB` / `72.4 KiB` | `1154.6 KiB` / `50.9 KiB` | `234.4 KiB` / `ERR (unstrippable)` | **`209.2 KiB` / `142.0 KiB`** | **7.17x smaller raw** vs `-lc`; **-10.7% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1611.2 KiB` / `73.6 KiB` | `1611.2 KiB` / `73.6 KiB` | FAIL (`-lc` linker bug) | **`305.3 KiB` / `179.5 KiB`** | **5.28x smaller raw** vs `-lc`; **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `2639.8 KiB` / `93.9 KiB` | `2325.4 KiB` / `72.0 KiB` | `816.2 KiB` / `ERR (unstrippable)` | **`715.5 KiB` / `184.0 KiB`** | **3.69x smaller raw** vs `-lc`; **-12.3% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1720.4 KiB` / `74.0 KiB` | `1380.6 KiB` / `52.7 KiB` | `366.6 KiB` / `ERR (unstrippable)` | **`318.1 KiB` / `144.0 KiB`** | **5.41x smaller raw** vs `-lc`; **-13.2% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1721.5 KiB` / `73.7 KiB` | `1378.5 KiB` / `52.3 KiB` | `380.6 KiB` / `ERR (unstrippable)` | **`327.5 KiB` / `147.8 KiB`** | **5.26x smaller raw** vs `-lc`; **-13.9% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2154.4 KiB` / `91.9 KiB` | `1815.1 KiB` / `70.4 KiB` | `658.7 KiB` / `ERR (unstrippable)` | **`574.4 KiB` / `182.1 KiB`** | **3.75x smaller raw** vs `-lc`; **-12.8% raw** vs `-fno-llvm` (strippable) |

---
## 4. Runtime Execution Performance in V8 (Node.js)

All 13 compute & image-processing modules transpiled via `transpile({ optimize: 'ReleaseFast' })` and executed in Node.js V8 (`v22.15.0`). Times in milliseconds (`median` / `mean` / `min` / `p95`).

| Suite | Benchmark | Workload | `wazig (0.17.0-wazig.3)` Median (p95) `ms` | `zig (-fno-llvm)` Median (p95) `ms` | `zig (LLVM)` Median (p95) `ms` | `wazig` vs `zig -fno-llvm` |
| :--- | :--- | :--- | ---: | ---: | ---: | :--- |
| Benchmarks Game | `nbody` | `advance(solar_bodies, 0.01, 500000)` | **`101.64`** (`101.86`) | `99.65` (`99.90`) | `49.41` (`49.61`) | **0.98x** (`stage2_wasm` parity) |
| Benchmarks Game | `fannkuch-redux` | `Pfannkuchen(10)` | **`2180.26`** (`2180.35`) | `2203.88` (`2204.34`) | `195.98` (`196.72`) | **1.01x** (`stage2_wasm` parity) |
| Benchmarks Game | `spectral-norm` | `spectralNorm(1000)` | **`494.35`** (`494.76`) | `515.13` (`515.19`) | `59.10` (`59.13`) | **1.04x** (`stage2_wasm` parity) |
| Benchmarks Game | `mandelbrot` | `mandelbrot(1000)` | **`167.40`** (`167.45`) | `166.60` (`166.75`) | `64.85` (`64.99`) | **1.00x** (`stage2_wasm` parity) |
| Benchmarks Game | `binary-trees` | `binaryTree(12)` | **`136.25`** (`136.27`) | `143.59` (`143.68`) | `15.64` (`15.82`) | **1.05x** (`stage2_wasm` parity) |
| Benchmarks Game | `fasta` | `fasta(100000)` | **`101.73`** (`102.47`) | `107.21` (`107.62`) | `104.22` (`106.71`) | **1.05x** (`stage2_wasm` parity) |
| Image Processing | `polish-flag` | `render(320x200)` | **`6.36`** (`6.39`) | `6.45` (`6.52`) | `0.33` (`0.39`) | **1.01x** (`stage2_wasm` parity) |
| Image Processing | `resize` | `malgorzata-socha.png -> 384x288` | **`70.62`** (`70.86`) | `73.14` (`73.18`) | `3.12` (`3.24`) | **1.04x** (`stage2_wasm` parity) |
| Image Processing | `greyscale` | `malgorzata-socha.png (in-place)` | **`27.33`** (`27.35`) | `27.88` (`27.92`) | `1.16` (`1.30`) | **1.02x** (`stage2_wasm` parity) |
| Image Processing | `sepia` | `malgorzata-socha.png (intensity=0.3)` | **`85.08`** (`85.16`) | `85.50` (`85.73`) | `4.24` (`4.25`) | **1.00x** (`stage2_wasm` parity) |
| Image Processing | `circle-pattern` | `malgorzata-socha.png (circle filter)` | **`83.65`** (`83.79`) | `82.30` (`82.32`) | `6.53` (`6.63`) | **0.98x** (`stage2_wasm` parity) |
| Image Processing | `raytracer` | `process(256x256)` | **`450.98`** (`451.15`) | `458.63` (`458.68`) | `25.87` (`25.93`) | **1.02x** (`stage2_wasm` parity) |
| Image Processing | `mandelbulb-quick` | `process(200x200)` | **`660.56`** (`665.78`) | `622.96` (`623.26`) | `201.51` (`201.63`) | **0.94x** (`stage2_wasm` parity) |

---
## 5. Key Takeaways & Case for Switching to `wazig`

1. **8.45 MiB Universal Download vs 50–100 MB Per-Platform LLVM Toolchain**: `wazig` ships as a single OS/arch-independent `wasm64-wasip3` binary (`8.86 MB` / `8.45 MiB` compressed, `71.2 MB` uncompressed across `1,322` files) vs standard `zig`'s `360.3 MB` uncompressed install across `19,505` files (**5.06x smaller disk footprint**, **14.75x fewer files**, and **47.4x smaller** total release assets across 6 desktop OS/arch targets).
2. **194x Faster Cold `translate-c` via In-Process Aro**: Standard `zig 0.17.0` moved `translate-c` into an external sub-binary that takes **~61.7 seconds** to compile on a cold cache. `wazig` embeds `translate-c` + Aro in-process and completes cold C header translation in **~319 ms**.
3. **Out-of-the-Box Multithreaded WASM & Pure-Zig `libzigc.a` Without LLVM**: Stock `zig 0.17.0` fails on `multithreaded: true` WASM builds (`WasmAllocator` unimplemented) unless users manually patch their system Zig installation with `wasi-thread.patch`, and `zig -fno-llvm` fails both on multithreaded WASM (`naked` calling convention unsupported) and on `-lc` reactor modules (`libc.a: undefined function: __main_argc_argv`). `wazig` supports both out of the box.
4. **Dramatically Smaller `Debug` Binaries & Working `stage2_wasm` Stripping**: In `Debug` mode (Zigar's default development mode), `wazig` emits raw `.wasm` binaries **4.8x–8.0x smaller** than LLVM (`226–737 KiB` vs `1.80–3.53 MiB`) and stripped binaries **23%–37% smaller** (`147–186 KiB` vs `232–288 KiB`). Unlike upstream `zig -fno-llvm` (which crashes `stripUnused()` in `Debug`/`ReleaseFast`/`ReleaseSafe` and fails to strip reflection metadata in `ReleaseSmall`), `wazig`'s MIR + post-link optimizations produce **1.6x–4.27x smaller** stripped `ReleaseSmall` binaries than upstream `stage2_wasm`.
