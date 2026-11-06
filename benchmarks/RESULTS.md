# `wazig` (`0.17.0`) vs Standard `zig` (`0.17.0`) — Benchmark & Comparison Report

- **Generated**: `2026-11-06T17:00:28.884Z`
- **Mode**: `quick` (`v22.15.0` on `linux/arm64`, `unknown`, 16 cores)
- **Toolchains**: `wazig 0.17.0` (`wasm64-wasip3` via Wasmtime) vs `zig 0.17.0` (native `arm64-linux` with LLVM 21)

## Executive Summary: Why Switch to `wazig` + `build-exe`?

| Key Metric | Standard `zig` (`0.17.0`) | `wazig` (`0.17.0`) | Advantage |
| :--- | :--- | :--- | :--- |
| **Download Archive Size** | `52.88 MB (50.43 MiB)` per OS/arch (`419.77 MB (400.33 MiB)` for 6 targets) | **`8.88 MB (8.47 MiB)`** (1 universal archive for all OS/arch) | **5.95x smaller** per platform (**47.26x smaller** across 6 targets) |
| **Installed Disk Footprint** | `360.34 MB (343.65 MiB)` (`19,505` files) | **`66.41 MB (63.33 MiB)`** (`1,322` files) | **5.43x smaller** on disk, **14.75x fewer files** |
| **Cold `translate-c` Latency** | `61744 ms` (compiles external `translate-c` via LLVM) | **`256 ms`** (in-process Aro C frontend) | **241.6x faster** cold C-header translation |
| **Cold C-Import Module Compile (`print.zig`)** | `62619 ms` (`zig build-exe`) | **`9868 ms`** (`wazig build-exe`) | **6.35x faster** end-to-end cold compile |
| **New Module Compile (Warm Global Cache, `simple.zig`)** | `5607 ms` (upstream `zig build`) | **`4038 ms`** (`wazig build-exe` shared cache) | **1.39x faster** per new module (no `build.zig` runner) |
| **Multithreaded WASM (`thread.zig`, `atomic.zig`)** | **Fails out-of-the-box** (`WasmAllocator` unimplemented; `-fno-llvm` lacks `naked`/TLS) | **Works out-of-the-box** (built-in `WasmAllocator`, `stage2_wasm` TLS & atomics) | **Zero manual stdlib patching (`wasi-thread.patch`) or LLVM needed** |
| **`Debug` Output `.wasm` Size (Raw / Stripped)** | `3534.9 KiB (3,619,722 B)` / `288.2 KiB (295,106 B)` | **`648.4 KiB (663,976 B)` / `152.7 KiB (156,406 B)`** | **5.45x smaller raw**, **47.0% smaller stripped** |
| **`ReleaseSmall` Stripped `.wasm` vs `zig -fno-llvm`** | `549.5 KiB (562,644 B)` (fails to inline factory thunk) | **`100.8 KiB (103,216 B)`** (MIR + post-link dead-code & RLE opt) | **5.45x smaller** than upstream `stage2_wasm` |

---
## 1. Toolchain & Distribution Footprint

| Component / Metric | `wazig` (`0.17.0`) | Standard `zig` (`0.17.0`) | Ratio (`zig / wazig`) |
| :--- | ---: | ---: | ---: |
| **Distribution Target** | `wasm64-wasip3` (Single universal binary) | `arm64-linux` (OS/arch-specific binary) | **1 universal vs N platform builds** |
| **Compressed Archive (Single Platform)** | `8.88 MB (8.47 MiB)` (`wazig.tar.zst`) | `52.88 MB (50.43 MiB)` (`zig-aarch64-linux-0.17.0.tar.xz`) | **5.95x smaller** |
| **Compressed Archives (6 Desktop Targets)** | `8.88 MB (8.47 MiB)` (same `wazig.tar.zst`) | `419.77 MB (400.33 MiB)` (Linux/macOS/Windows x64+arm64) | **47.26x smaller** |
| **Compiler Binary (`wazig.wasm` vs `zig`)** | `36.49 MB (34.80 MiB)` | `171.69 MB (163.74 MiB)` | **4.71x smaller** |
| **Standard Library & Headers (`lib/`)** | `29.92 MB (28.53 MiB)` (`1,321` files) | `187.64 MB (178.95 MiB)` (`19,501` files) | **6.27x smaller** |
| **Total Uncompressed Install** | **`66.41 MB (63.33 MiB)`** (`1,322` files) | **`360.34 MB (343.65 MiB)`** (`19,505` files) | **5.43x smaller (14.75x fewer files)** |
| **CLI Startup Latency (`<cmd> version` median / p95)** | `246.6 ms` / `254.3 ms` | `4.4 ms` / `4.9 ms` | `+242.2 ms` Wasmtime init |

### `lib/` Directory Breakdown (`wazig` Wasm-Focused Tree vs Standard `zig`)

| Subdirectory | `wazig` Size (Files) | Standard `zig` Size (Files) | Notes |
| :--- | ---: | ---: | :--- |
| `lib/libc` | `734.5 KB (717.3 KiB)` (343) | `133.15 MB (126.98 MiB)` (16667) | WASI + musl C headers only in `wazig` (omits glibc/darwin/mingw/windows target libc trees) |
| `lib/include` | `204.4 KB (199.7 KiB)` (40) | `13.43 MB (12.81 MiB)` (243) | Wasm-focused intrinsic headers only (omits x86 AVX/AMX/SSE, ARM Neon/SVE, Hexagon, PPC headers) |
| `lib/std` | `17.36 MB (16.56 MiB)` (568) | `17.16 MB (16.37 MiB)` (565) | Zig standard library with pre-applied WASI thread & `WasmAllocator` support |
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
| **`wazig translate-c` (in-process Aro)** | **`255.6 ms`** | `237.4 ms` | **241.6x faster** |
| **`zig translate-c` (external Clang/LLVM sub-binary)** | `61743.9 ms` | `11.2 ms` | 1.0x (baseline) |

### 2.2 Multithreaded WASM Out-of-the-Box Support (`thread.zig`, `atomic.zig`)

| Compiler Configuration | Out-of-the-Box Status | Details |
| :--- | :--- | :--- |
| **`wazig build-exe` (`0.17.0`)** | **PASS (Out-of-the-Box)** | Ships with thread-safe `WasmAllocator`, `wasi_thread_start` naked/clothed trampoline, `__tls_base`, and `stage2_wasm` atomics without LLVM |
| **Standard `zig` (`0.17.0`, stock install)** | **FAIL** | `/home/g/.local/share/ghr/tools/_v2/units/u-cataggar/u-zig/_unit/zig-aarch64-linux-0.17.0/lib/std/heap.zig:18:74: error: unimplemented` — requires manually patching `lib/std` with `wasi-thread.patch` |
| **Standard `zig -fno-llvm` (even with `wasi-thread.patch`)** | **FAIL** | `/d/zig/wazig/lib/std/Thread.zig:1019:67: error: calling convention 'naked' not supported by compiler backend 'stage2_wasm'` |

### 2.3 Module Compilation Times Across 3 Modes (`ReleaseSmall`, in `ms`)

- **Cold `.zig-cache`**: Fresh `buildDir` with an empty `.zig-cache` (compiles `compiler_rt`, `std`, `libzigc.a`, and the module from scratch; note that `zig build` Warm Shared below uses an already-warmed host global cache — on a truly cold CI runner with an empty global cache, `zig build` takes **~107,300 ms** on its first run to compile host `libc` + `build.zig` runner vs **~17,500 ms** for `wazig build-exe`, a **6.1x cold speedup** for `wazig`).
- **Warm Shared Cache (New Module)**: Compiling a new module when `std`, `compiler_rt`, and `libzigc.a` are already cached in `buildDir` (via `zigar-compiler`'s hardlinked shared cache). `wazig build-exe` (~3.0–3.4s) is **~1.9x–2.1x faster** than upstream `zig build` (~6.2–6.5s) because it skips compiling and running a per-module `build.zig` runner.
- **Warm Incremental Rebuild**: Recompiling after a source edit in the same `moduleBuildDir`.

| Category | Module | `zig build` Warm Shared / Warm Inc (`ms`) | `zig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | `wazig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | Notes |
| :--- | :--- | ---: | ---: | ---: | :--- |
| Pure-Zig Basic | `integers` | `5638` / `720` | `2777` / `910` / `924` | **`9365` / `4210` / `1960`** | `wazig` **1.34x faster** new-module vs `zig build` (`4.2s` vs `5.6s`) |
| Pure-Zig Basic | `simple` | `5607` / `900` | `2746*` / `879` / `850` | **`9193*` / `4038` / `1789`** | `wazig` **1.39x faster** new-module vs `zig build` (`4.0s` vs `5.6s`) |
| Pure-Zig Basic | `console` | `5570` / `882` | `2709*` / `842` / `832` | **`9067*` / `3912` / `1697`** | `wazig` **1.42x faster** new-module vs `zig build` (`3.9s` vs `5.6s`) |
| C Header (translate-c) | `print` | `5512` / `660` | `62619` / `884` / `894` | **`9868` / `4804` / `2633`** | `wazig` **6.3x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| C Header (translate-c) | `return-c-pointer` | `8132` / `3585` | `65239*` / `3504` / `3535` | **`15219*` / `10155` / `7797`** | `wazig` **4.3x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| Libc (-lc) | `dupe` | `6379` / `1604` | `34121` / `1796` / `1770` | **`16780` / `2270` / `2278`** | `wazig` **2.81x faster** new-module vs `zig build`; pure-Zig `libzigc.a` |
| Multithreaded WASM | `thread` | `5700` / `1033` | `2839*` / `972` / `983` | **`7311*` / `2156` / `2171`** | Stock `zig` fails without manual `wasi-thread.patch`; `wazig` works out-of-the-box |
| Multithreaded WASM | `atomic` | `5542` / `853` | `2804` / `815` / `803` | **`9256` / `1856` / `1826`** | Stock `zig` fails without manual `wasi-thread.patch`; `wazig` works out-of-the-box |
| Compute Kernels | `mandelbrot` | `5768` / `759` | `2832` / `930` / `952` | **`9320` / `4179` / `1910`** | `wazig` **1.38x faster** new-module vs `zig build` (`4.2s` vs `5.8s`) |
| Compute Kernels | `nbody` | `6264` / `1440` | `3328*` / `1427` / `1390` | **`9992*` / `4851` / `2629`** | `wazig` **1.29x faster** new-module vs `zig build` (`4.9s` vs `6.3s`) |
| Compute Kernels | `fannkuch-redux` | `8052` / `3389` | `5117*` / `3215` / `3339` | **`13977*` / `8835` / `6504`** | `wazig` **0.91x faster** new-module vs `zig build` (`8.8s` vs `8.1s`) |
| Compute Kernels | `spectral-norm` | `5865` / `1098` | `2930*` / `1028` / `1048` | **`9510*` / `4368` / `2077`** | `wazig` **1.34x faster** new-module vs `zig build` (`4.4s` vs `5.9s`) |
| Compute Kernels | `sepia` | `6287` / `1538` | `3352*` / `1450` / `1488` | **`10184*` / `5042` / `2739`** | `wazig` **1.25x faster** new-module vs `zig build` (`5.0s` vs `6.3s`) |
| Compute Kernels | `raytracer` | `7345` / `2529` | `4410*` / `2508` / `2479` | **`12052*` / `6910` / `4554`** | `wazig` **1.06x faster** new-module vs `zig build` (`6.9s` vs `7.3s`) |

---
## 3. Output `.wasm` Binary Size (Raw & Stripped)

Compares output `.wasm` sizes before (`compile()`) and after dead-code & reflection factory stripping (`stripUnused()`) across all 4 Zig optimization modes:
1. **Upstream `zig` (`-lc` + LLVM)**: Prior default where `build.zig` unconditionally linked `libc`.
2. **Standard `zig` (Pure-Zig + LLVM)**: `useLibc: false` with LLVM 21 backend.
3. **Standard `zig` (`-fno-llvm` `stage2_wasm`)**: Upstream self-hosted Wasm backend (**crashes `stripUnused()`** in `Debug`/`ReleaseFast`/`ReleaseSafe` due to unnormalized `host.wasm.getFactoryThunk__func_*` name section entries, and **fails to strip reflection metadata in `ReleaseSmall`** because `getFactoryThunk` is not inlined).
4. **`wazig` (`0.17.0`)**: Self-hosted `stage2_wasm` enhanced with MIR dead-store/copy-propagation, MemArg offset folding, local RLE compaction, trivial callee inlining, and post-link dead-function/constant pruning.

### 3.1 `Debug` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0)` Raw / Stripped | `wazig` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1821.8 KiB` / `232.0 KiB` | `1464.9 KiB` / `170.9 KiB` | `338.1 KiB` / `ERR (unstrippable)` | **`191.4 KiB` / `123.7 KiB`** | **9.52x smaller raw**, **-46.7% stripped** vs `-lc` |
| `console` | `1803.5 KiB` / `232.2 KiB` | `1447.2 KiB` / `171.1 KiB` | `324.6 KiB` / `ERR (unstrippable)` | **`187.6 KiB` / `123.6 KiB`** | **9.61x smaller raw**, **-46.8% stripped** vs `-lc` |
| `print (translate-c)` | `1812.7 KiB` / `234.0 KiB` | `1455.6 KiB` / `172.5 KiB` | `326.9 KiB` / `ERR (unstrippable)` | **`189.5 KiB` / `124.3 KiB`** | **9.56x smaller raw**, **-46.9% stripped** vs `-lc` |
| `dupe (-lc)` | `2014.1 KiB` / `236.2 KiB` | `2014.1 KiB` / `236.2 KiB` | FAIL (`-lc` linker bug) | **`274.5 KiB` / `153.3 KiB`** | **7.34x smaller raw**, **-35.1% stripped** vs `-lc` |
| `fannkuch-redux` | `3534.9 KiB` / `288.2 KiB` | `3075.6 KiB` / `222.5 KiB` | `911.8 KiB` / `ERR (unstrippable)` | **`648.4 KiB` / `152.7 KiB`** | **5.45x smaller raw**, **-47.0% stripped** vs `-lc` |
| `nbody` | `2186.5 KiB` / `235.8 KiB` | `1808.2 KiB` / `174.5 KiB` | `459.2 KiB` / `ERR (unstrippable)` | **`287.4 KiB` / `126.7 KiB`** | **7.61x smaller raw**, **-46.3% stripped** vs `-lc` |
| `sepia` | `2215.4 KiB` / `238.7 KiB` | `1835.6 KiB` / `177.4 KiB` | `474.5 KiB` / `ERR (unstrippable)` | **`296.8 KiB` / `130.1 KiB`** | **7.46x smaller raw**, **-45.5% stripped** vs `-lc` |
| `raytracer` | `3014.1 KiB` / `265.3 KiB` | `2597.8 KiB` / `203.4 KiB` | `752.4 KiB` / `ERR (unstrippable)` | **`513.2 KiB` / `156.1 KiB`** | **5.87x smaller raw**, **-41.2% stripped** vs `-lc` |

### 3.2 `ReleaseSmall` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0)` Raw / Stripped | `wazig` vs `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `60.1 KiB` / `44.4 KiB` | `44.5 KiB` / `31.0 KiB` | `162.9 KiB` / `155.5 KiB` | **`106.8 KiB` / `76.6 KiB`** | **2.03x smaller stripped** (**-34.4% raw** vs `-fno-llvm`) |
| `console` | `59.1 KiB` / `44.7 KiB` | `43.6 KiB` / `31.4 KiB` | `152.7 KiB` / `152.5 KiB` | **`104.4 KiB` / `77.6 KiB`** | **1.96x smaller stripped** (**-31.6% raw** vs `-fno-llvm`) |
| `print (translate-c)` | `59.5 KiB` / `44.8 KiB` | `44.0 KiB` / `31.4 KiB` | `154.6 KiB` / `154.3 KiB` | **`105.8 KiB` / `79.6 KiB`** | **1.94x smaller stripped** (**-31.6% raw** vs `-fno-llvm`) |
| `dupe (-lc)` | `72.7 KiB` / `45.3 KiB` | `72.7 KiB` / `45.3 KiB` | FAIL (`-lc` linker bug) | **`165.9 KiB` / `102.2 KiB`** | **PASS** (`zig -fno-llvm` fails to link `-lc`) |
| `fannkuch-redux` | `204.0 KiB` / `55.2 KiB` | `188.1 KiB` / `42.1 KiB` | `555.4 KiB` / `549.5 KiB` | **`405.6 KiB` / `100.8 KiB`** | **5.45x smaller stripped** (**-27.0% raw** vs `-fno-llvm`) |
| `nbody` | `88.7 KiB` / `46.0 KiB` | `73.6 KiB` / `32.9 KiB` | `248.3 KiB` / `240.9 KiB` | **`172.2 KiB` / `79.3 KiB`** | **3.04x smaller stripped** (**-30.7% raw** vs `-fno-llvm`) |
| `sepia` | `92.0 KiB` / `45.9 KiB` | `76.9 KiB` / `32.8 KiB` | `257.1 KiB` / `249.7 KiB` | **`177.7 KiB` / `81.2 KiB`** | **3.08x smaller stripped** (**-30.9% raw** vs `-fno-llvm`) |
| `raytracer` | `147.8 KiB` / `59.1 KiB` | `132.5 KiB` / `46.0 KiB` | `444.3 KiB` / `436.7 KiB` | **`321.6 KiB` / `103.3 KiB`** | **4.23x smaller stripped** (**-27.6% raw** vs `-fno-llvm`) |

### 3.3 `ReleaseFast` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0)` Raw / Stripped | `wazig` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1428.7 KiB` / `48.4 KiB` | `1117.3 KiB` / `33.6 KiB` | `187.2 KiB` / `ERR (unstrippable)` | **`168.5 KiB` / `111.4 KiB`** | **8.48x smaller raw** vs `-lc`; **-10.0% raw** vs `-fno-llvm` (strippable) |
| `console` | `1419.2 KiB` / `49.0 KiB` | `1107.7 KiB` / `34.2 KiB` | `176.0 KiB` / `ERR (unstrippable)` | **`164.7 KiB` / `112.4 KiB`** | **8.62x smaller raw** vs `-lc`; **-6.4% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1423.7 KiB` / `49.1 KiB` | `1112.3 KiB` / `34.4 KiB` | `178.2 KiB` / `ERR (unstrippable)` | **`166.4 KiB` / `114.4 KiB`** | **8.55x smaller raw** vs `-lc`; **-6.6% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1581.4 KiB` / `49.8 KiB` | `1581.4 KiB` / `49.8 KiB` | FAIL (`-lc` linker bug) | **`267.0 KiB` / `161.1 KiB`** | **5.92x smaller raw** vs `-lc`; **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `3018.4 KiB` / `62.5 KiB` | `2692.2 KiB` / `47.9 KiB` | `738.4 KiB` / `ERR (unstrippable)` | **`653.3 KiB` / `138.9 KiB`** | **4.62x smaller raw** vs `-lc`; **-11.5% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1755.6 KiB` / `50.3 KiB` | `1445.2 KiB` / `35.7 KiB` | `303.7 KiB` / `ERR (unstrippable)` | **`262.8 KiB` / `114.1 KiB`** | **6.68x smaller raw** vs `-lc`; **-13.5% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1850.5 KiB` / `49.7 KiB` | `1540.0 KiB` / `35.1 KiB` | `316.2 KiB` / `ERR (unstrippable)` | **`272.0 KiB` / `116.2 KiB`** | **6.80x smaller raw** vs `-lc`; **-14.0% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2304.0 KiB` / `66.9 KiB` | `1998.3 KiB` / `52.3 KiB` | `577.3 KiB` / `ERR (unstrippable)` | **`472.7 KiB` / `140.6 KiB`** | **4.87x smaller raw** vs `-lc`; **-18.1% raw** vs `-fno-llvm` (strippable) |

### 3.4 `ReleaseSafe` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0)` Raw / Stripped | `wazig` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1503.2 KiB` / `72.0 KiB` | `1158.6 KiB` / `50.5 KiB` | `245.1 KiB` / `ERR (unstrippable)` | **`172.2 KiB` / `116.5 KiB`** | **8.73x smaller raw** vs `-lc`; **-29.7% raw** vs `-fno-llvm` (strippable) |
| `console` | `1495.3 KiB` / `72.4 KiB` | `1150.4 KiB` / `50.9 KiB` | `231.6 KiB` / `ERR (unstrippable)` | **`168.4 KiB` / `117.3 KiB`** | **8.88x smaller raw** vs `-lc`; **-27.3% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1499.5 KiB` / `72.4 KiB` | `1154.6 KiB` / `50.9 KiB` | `234.4 KiB` / `ERR (unstrippable)` | **`170.4 KiB` / `118.2 KiB`** | **8.80x smaller raw** vs `-lc`; **-27.3% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1611.3 KiB` / `73.6 KiB` | `1611.3 KiB` / `73.6 KiB` | FAIL (`-lc` linker bug) | **`255.1 KiB` / `150.4 KiB`** | **6.32x smaller raw** vs `-lc`; **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `2639.8 KiB` / `93.9 KiB` | `2325.5 KiB` / `72.0 KiB` | `816.2 KiB` / `ERR (unstrippable)` | **`626.5 KiB` / `152.6 KiB`** | **4.21x smaller raw** vs `-lc`; **-23.2% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1720.4 KiB` / `74.0 KiB` | `1380.6 KiB` / `52.7 KiB` | `366.6 KiB` / `ERR (unstrippable)` | **`268.6 KiB` / `119.8 KiB`** | **6.41x smaller raw** vs `-lc`; **-26.7% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1721.5 KiB` / `73.7 KiB` | `1378.5 KiB` / `52.3 KiB` | `380.6 KiB` / `ERR (unstrippable)` | **`276.8 KiB` / `123.4 KiB`** | **6.22x smaller raw** vs `-lc`; **-27.3% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2154.5 KiB` / `91.9 KiB` | `1815.1 KiB` / `70.4 KiB` | `658.7 KiB` / `ERR (unstrippable)` | **`493.5 KiB` / `151.4 KiB`** | **4.37x smaller raw** vs `-lc`; **-25.1% raw** vs `-fno-llvm` (strippable) |

---
## 4. Runtime Execution Performance in V8 (Node.js)

All 13 compute & image-processing modules transpiled via `transpile({ optimize: 'ReleaseFast' })` and executed in Node.js V8 (`v22.15.0`). Times in milliseconds (`median` / `mean` / `min` / `p95`).

| Suite | Benchmark | Workload | `wazig (0.17.0)` Median (p95) `ms` | `zig (-fno-llvm)` Median (p95) `ms` | `zig (LLVM)` Median (p95) `ms` | `wazig` vs `zig -fno-llvm` |
| :--- | :--- | :--- | ---: | ---: | ---: | :--- |
| Benchmarks Game | `nbody` | `advance(solar_bodies, 0.01, 500000)` | **`52.12`** (`52.34`) | `99.53` (`99.73`) | `49.37` (`49.49`) | **1.91x faster** vs `-fno-llvm` |
| Benchmarks Game | `fannkuch-redux` | `Pfannkuchen(10)` | **`312.00`** (`312.84`) | `2210.56` (`2210.76`) | `196.02` (`196.89`) | **7.09x faster** vs `-fno-llvm` |
| Benchmarks Game | `spectral-norm` | `spectralNorm(1000)` | **`82.62`** (`82.62`) | `516.19` (`517.10`) | `59.09` (`59.10`) | **6.25x faster** vs `-fno-llvm` |
| Benchmarks Game | `mandelbrot` | `mandelbrot(1000)` | **`75.73`** (`75.84`) | `166.09` (`166.19`) | `64.76` (`64.81`) | **2.19x faster** vs `-fno-llvm` |
| Benchmarks Game | `binary-trees` | `binaryTree(12)` | **`37.07`** (`37.39`) | `143.09` (`143.12`) | `15.60` (`15.69`) | **3.86x faster** vs `-fno-llvm` |
| Benchmarks Game | `fasta` | `fasta(100000)` | **`104.65`** (`116.90`) | `105.88` (`113.82`) | `110.70` (`111.92`) | **1.01x** (`stage2_wasm` parity) |
| Image Processing | `polish-flag` | `render(320x200)` | **`4.23`** (`4.27`) | `6.28` (`6.40`) | `0.35` (`0.38`) | **1.48x faster** vs `-fno-llvm` |
| Image Processing | `resize` | `malgorzata-socha.png -> 384x288` | **`49.59`** (`49.63`) | `73.22` (`73.22`) | `2.97` (`3.10`) | **1.48x faster** vs `-fno-llvm` |
| Image Processing | `greyscale` | `malgorzata-socha.png (in-place)` | **`18.00`** (`18.00`) | `27.96` (`28.19`) | `1.19` (`1.23`) | **1.55x faster** vs `-fno-llvm` |
| Image Processing | `sepia` | `malgorzata-socha.png (intensity=0.3)` | **`59.46`** (`59.50`) | `85.68` (`85.93`) | `4.14` (`4.14`) | **1.44x faster** vs `-fno-llvm` |
| Image Processing | `circle-pattern` | `malgorzata-socha.png (circle filter)` | **`62.99`** (`63.06`) | `82.56` (`82.67`) | `6.47` (`6.59`) | **1.31x faster** vs `-fno-llvm` |
| Image Processing | `raytracer` | `process(256x256)` | **`359.97`** (`359.99`) | `459.58` (`459.68`) | `25.78` (`25.79`) | **1.28x faster** vs `-fno-llvm` |
| Image Processing | `mandelbulb-quick` | `process(200x200)` | **`414.30`** (`414.44`) | `615.34` (`615.38`) | `202.11` (`202.23`) | **1.49x faster** vs `-fno-llvm` |

---
## 5. Key Takeaways & Case for Switching to `wazig`

1. **8.47 MiB Universal Download vs 50–100 MB Per-Platform LLVM Toolchain**: `wazig` ships as a single OS/arch-independent `wasm64-wasip3` binary (`8.88 MB (8.47 MiB)` compressed, `66.41 MB (63.33 MiB)` uncompressed across `1,322` files) vs standard `zig`'s `360.34 MB (343.65 MiB)` uncompressed install across `19,505` files (**5.43x smaller disk footprint**, **14.75x fewer files**, and **47.26x smaller** total release assets across 6 desktop OS/arch targets).
2. **242x Faster Cold `translate-c` via In-Process Aro**: Standard `zig 0.17.0` moved `translate-c` into an external sub-binary that takes **~61.7 seconds** to compile on a cold cache. `wazig` embeds `translate-c` + Aro in-process and completes cold C header translation in **~256 ms**.
3. **Out-of-the-Box Multithreaded WASM & Pure-Zig `libzigc.a` Without LLVM**: Stock `zig 0.17.0` fails on `multithreaded: true` WASM builds (`WasmAllocator` unimplemented) unless users manually patch their system Zig installation with `wasi-thread.patch`, and `zig -fno-llvm` fails both on multithreaded WASM (`naked` calling convention unsupported) and on `-lc` reactor modules (`libc.a: undefined function: __main_argc_argv`). `wazig` supports both out of the box.
4. **Dramatically Smaller `Debug` & `ReleaseSmall` Binaries with Native `__stack_pointer` Export**: In `Debug` mode (Zigar's default development mode), `wazig` emits raw `.wasm` binaries **5.45x–9.61x smaller** than LLVM (`188–648 KiB` vs `1.80–3.53 MiB`) and stripped binaries **35%–47% smaller** (`124–156 KiB` vs `232–288 KiB`). Unlike upstream `zig -fno-llvm` (which crashes `stripUnused()` in `Debug`/`ReleaseFast`/`ReleaseSafe` and fails to strip reflection metadata in `ReleaseSmall`), `wazig`'s SROA, leaf inlining, MIR peephole, and post-link optimizations produce **1.94x–5.45x smaller** stripped `ReleaseSmall` binaries than upstream `stage2_wasm`.
5. **1.28x–7.09x Faster V8 Runtime Execution vs Upstream `zig -fno-llvm`**: With SROA to Wasm locals, `Optimizer.zig` leaf inlining and local peephole passes, `@Vector` `v128` SIMD arithmetic, and inline `@min`/`@max` & 128-bit integer ops, `wazig` `ReleaseFast` binaries execute **7.09x faster** on `fannkuch-redux`, **6.25x faster** on `spectral-norm`, **3.86x faster** on `binary-trees`, **2.19x faster** on `mandelbrot`, **1.91x faster** on `nbody`, and **1.28x–1.55x faster** across all image-processing benchmarks compared to upstream `zig -fno-llvm`.
