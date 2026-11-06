# `wazig` (`0.17.0-wazig.4`) & `wazigl` (`0.17.0-wazigl.4`) vs Standard `zig` (`0.17.0`) — Benchmark & Comparison Report

- **Generated**: `2026-11-06T22:49:42.008Z`
- **Mode**: `quick` (`v22.15.0` on `linux/arm64`, `unknown`, 16 cores)
- **Toolchains**: `wazig 0.17.0-wazig.4` (`wasm64-wasip3` self-hosted `stage2_wasm` + Aro via Wasmtime), `wazigl 0.17.0-wazigl.4` (`wasm64-wasip3` Wasm-hosted LLVM 21 + Clang + lld via Wasmtime), vs `zig 0.17.0` (native `arm64-linux` with LLVM 21)

## Executive Summary: `wazig` vs `wazigl` vs Standard `zig`

| Key Metric | Standard `zig` (`0.17.0`) | `wazigl` (`0.17.0-wazigl.4`) | `wazig` (`0.17.0-wazig.4`) | Advantage |
| :--- | :--- | :--- | :--- | :--- |
| **Download Archive Size** | `52.88 MB (50.43 MiB)` per OS/arch (`419.77 MB (400.33 MiB)` for 6 targets) | **`38.25 MB (36.48 MiB)`** (1 universal archive with LLVM 21 + Clang) | **`8.88 MB (8.47 MiB)`** (1 universal archive, self-hosted `stage2_wasm`) | `wazig`: **5.96x smaller** (**47.27x** vs 6 targets); `wazigl`: **1.38x smaller** (**10.97x** vs 6 targets) |
| **Installed Disk Footprint** | `360.34 MB (343.65 MiB)` (`19,505` files) | **`237.00 MB (226.02 MiB)`** (`1,322` files) | **`66.55 MB (63.47 MiB)`** (`1,322` files) | `wazig`: **5.41x smaller**, **14.75x fewer files**; `wazigl`: **1.52x smaller**, **14.75x fewer files** |
| **Cold `translate-c` Latency** | `54625 ms` (compiles external `translate-c` sub-binary via LLVM) | **`1437 ms`** (in-process Clang frontend) | **`243 ms`** (in-process Aro C frontend) | `wazig`: **224.5x faster**; `wazigl`: **38.0x faster** cold C-header translation |
| **Cold C-Import Module Compile (`print.zig`)** | `57163 ms` (`zig build-exe`) | **`15884 ms`** (`wazigl build-exe`) | **`9681 ms`** (`wazig build-exe`) | `wazig`: **5.90x faster**; `wazigl`: **3.60x faster** cold compile |
| **New Module Compile (Warm Shared Cache, `simple.zig`)** | `7126 ms` (upstream `zig build`) | `10472 ms` (`wazigl build-exe`) | **`3932 ms`** (`wazig build-exe`) | `wazig`: **1.81x faster** per new module (no `build.zig` runner) |
| **Multithreaded WASM (`thread.zig`, `atomic.zig`)** | **Fails out-of-the-box** (`WasmAllocator` unimplemented; `-fno-llvm` lacks `naked`/TLS) | **Works out-of-the-box** (built-in `WasmAllocator`, LLVM TLS & atomics) | **Works out-of-the-box** (built-in `WasmAllocator`, `stage2_wasm` TLS & atomics) | **Zero manual stdlib patching (`wasi-thread.patch`) needed in `wazig` or `wazigl`** |
| **`Debug` Output `.wasm` Size (Raw / Stripped)** | `3534.8 KiB (3,619,672 B)` / `288.2 KiB (295,106 B)` | `3078.8 KiB (3,152,738 B)` / `222.8 KiB (228,187 B)` | **`632.2 KiB (647,397 B)` / `152.5 KiB (156,210 B)`** | `wazig`: **5.59x smaller raw**, **47.1% smaller stripped** |
| **`ReleaseSmall` Stripped `.wasm` (`fannkuch-redux`)** | `549.5 KiB (562,644 B)` (`zig -fno-llvm`, fails to inline thunk) | **`42.1 KiB (43,138 B)`** (matches native LLVM `42.1 KiB (43,138 B)`) | **`100.4 KiB (102,850 B)`** (MIR + SROA + Optimizer.zig) | `wazig`: **5.47x smaller** than `zig -fno-llvm`; `wazigl`: exact LLVM size parity |

---
## 1. Toolchain & Distribution Footprint

### 1.1 Three-Way Toolchain Footprint Comparison

| Component / Metric | `wazig` (`0.17.0-wazig.4`) | `wazigl` (`0.17.0-wazigl.4`) | Standard `zig` (`0.17.0`) | `zig / wazig` | `zig / wazigl` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **Distribution Target** | `wasm64-wasip3` (Universal, self-hosted) | `wasm64-wasip3` (Universal, Wasm LLVM 21) | `arm64-linux` (OS/arch-specific native) | **1 universal** | **1 universal** |
| **Compressed Archive (Single Platform)** | `8.88 MB (8.47 MiB)` (`wazig.tar.zst`) | `38.25 MB (36.48 MiB)` (`wazigl.tar.zst`) | `52.88 MB (50.43 MiB)` (`zig-aarch64-linux-0.17.0.tar.xz`) | **5.96x smaller** | **1.38x smaller** |
| **Compressed Archives (6 Desktop Targets)** | `8.88 MB (8.47 MiB)` (same `wazig.tar.zst`) | `38.25 MB (36.48 MiB)` (same `wazigl.tar.zst`) | `419.77 MB (400.33 MiB)` (Linux/macOS/Win x64+arm64) | **47.27x smaller** | **10.97x smaller** |
| **Compiler Binary (`.wasm` vs `zig`)** | `36.63 MB (34.94 MiB)` (`wazig.wasm`) | `207.08 MB (197.48 MiB)` (`wazigl.wasm`) | `171.69 MB (163.74 MiB)` (`zig`) | **4.69x smaller** | `1.21x` of `zig` |
| **Standard Library & Headers (`lib/`)** | `29.92 MB (28.54 MiB)` (`1,321` files) | `29.92 MB (28.54 MiB)` (`1,321` files) | `187.64 MB (178.95 MiB)` (`19,501` files) | **6.27x smaller** | **6.27x smaller** |
| **Total Uncompressed Install** | **`66.55 MB (63.47 MiB)`** (`1,322` files) | **`237.00 MB (226.02 MiB)`** (`1,322` files) | **`360.34 MB (343.65 MiB)`** (`19,505` files) | **5.41x smaller (14.75x fewer files)** | **1.52x smaller (14.75x fewer files)** |
| **CLI Startup Latency (`<cmd> version` median / p95)** | `245.9 ms` / `253.1 ms` | `1404.8 ms` / `1435.9 ms` | `4.0 ms` / `4.2 ms` | `+241.9 ms` Wasmtime | `+1400.8 ms` Wasmtime |

### 1.2 Head-to-Head: `wazigl` (`0.17.0-wazigl.4`) vs Baseline `zig` (`0.17.0`)

`wazigl` compiles the full **Zig + LLVM 21 + Clang + LLD (`wasm-ld`)** pipeline into a single portable `wasm64-wasip3` module (`wazigl.wasm`). Compared directly against baseline `zig 0.17.0`:

1. **Universal Wasm Distribution & Smaller Archive**: `wazigl.tar.zst` is **`38.25 MB (36.48 MiB)`** for all platforms vs **`52.88 MB (50.43 MiB)`–`100.27 MB (95.62 MiB)`** per OS/arch for native `zig` (**1.38x smaller** than Linux `aarch64`, **2.62x smaller** than Windows `x86_64`, and **10.97x smaller** across 6 desktop targets).
2. **1.52x Smaller Installed Disk Footprint & 14.75x Fewer Files**: Even with LLVM 21 + Clang + LLD linked into `wazigl.wasm` (`207.08 MB (197.48 MiB)`), pruning non-Wasm target libc/C++/intrinsic headers shrinks `lib/` from `187.64 MB (178.95 MiB)` (`19,501` files) to `29.92 MB (28.54 MiB)` (`1,321` files), reducing total installed size from `360.34 MB (343.65 MiB)` to `237.00 MB (226.02 MiB)`.
3. **38.0x Faster Cold `translate-c` (In-Process Clang vs External Sub-Binary)**: Baseline `zig 0.17.0` compiles an external `translate-c` binary via LLVM on a cold cache (**`54625 ms`**), whereas `wazigl` keeps Clang's `translate-c` linked in-process and translates C headers in **`1437 ms`** cold (**`1429 ms`** warm).
4. **Pure-Zig `libzigc.a` & Out-of-the-Box Multithreaded WASM (`thread.zig`, `atomic.zig`)**: Baseline `zig 0.17.0` fails on `multithreaded: true` WASM builds (`WasmAllocator` unimplemented) without manually applying `wasi-thread.patch`. `wazigl` ships with `WasmAllocator`, WASI thread startup trampolines, and pure-Zig `libzigc.a` out of the box.
5. **Default `__stack_pointer` Export in `wasm-ld`**: `wazigl`'s embedded `lld` (`wasm-ld`) exports `__stack_pointer` by default on reactor modules alongside LLVM codegen.
6. **Identical Pure-Zig `.wasm` Sizes (1.29x–1.43x Smaller Than Upstream `-lc`) & Pure-Zig `libzigc.a`**: For pure-Zig modules across `ReleaseSmall`, `ReleaseFast`, and `ReleaseSafe`, `wazigl` produces byte-for-byte identical stripped `.wasm` sizes to native `zig (Pure-Zig LLVM)` (`31.0–46.0 KiB` in `ReleaseSmall`, **1.29x–1.43x smaller** than upstream `zig (-lc + LLVM)` `44.4–59.1 KiB`), while for `-lc` modules (`dupe.zig`), `wazigl`'s pure-Zig `libzigc.a` produces **`44.7 KiB (45,724 B)`** stripped in `ReleaseSmall` vs **`45.3 KiB (46,428 B)`** for upstream `zig -lc` (**1.02x smaller** without compiling C files).
7. **Full V8 Runtime Execution Parity with Native `zig (LLVM)`**: Because `wazigl` uses the same LLVM 21 optimization pipeline as native `zig`, its generated `.wasm` binaries run at **1.00x parity** with native `zig (LLVM)` across all 13 Benchmarks Game and Image Processing workloads in Node.js V8, while trading off ~1.3x–2.3x slower warm compilation speed than `zig build` (~3.4x–5.9x slower than native `zig build-exe`, and **2.2x–3.6x faster** cold compilation on C-import modules) because LLVM 21 executes inside Wasmtime rather than natively.

### 1.3 `lib/` Directory Breakdown (`wazig` & `wazigl` Wasm-Focused Tree vs Standard `zig`)

| Subdirectory | `wazig` Size (Files) | `wazigl` Size (Files) | Standard `zig` Size (Files) | Notes |
| :--- | ---: | ---: | ---: | :--- |
| `lib/libc` | `734.5 KB (717.3 KiB)` (343) | `734.5 KB (717.3 KiB)` (343) | `133.15 MB (126.98 MiB)` (16667) | WASI + musl C headers only in `wazig` & `wazigl` (omits glibc/darwin/mingw/windows target libc trees) |
| `lib/include` | `204.4 KB (199.7 KiB)` (40) | `204.4 KB (199.7 KiB)` (40) | `13.43 MB (12.81 MiB)` (243) | `wazig`: Wasm intrinsic headers only; `wazigl`: Wasm + Clang builtin headers (`__stdarg_*`, `wasm_simd128.h`, etc.) |
| `lib/std` | `17.36 MB (16.56 MiB)` (568) | `17.36 MB (16.56 MiB)` (568) | `17.16 MB (16.37 MiB)` (565) | Zig standard library with pre-applied WASI thread & `WasmAllocator` support in `wazig` & `wazigl` |
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
| **`wazig translate-c` (in-process Aro)** | **`243.3 ms`** | `244.1 ms` | **224.5x faster** |
| **`wazigl translate-c` (in-process Clang)** | **`1437.0 ms`** | `1428.5 ms` | **38.0x faster** |
| **`zig translate-c` (external Clang/LLVM sub-binary)** | `54624.6 ms` | `5.3 ms` | 1.0x (baseline) |

### 2.2 Multithreaded WASM & `-lc` Out-of-the-Box Support (`thread.zig`, `atomic.zig`, `dupe.zig`)

| Compiler Configuration | Multithreaded WASM | `-lc` Reactor Modules | Details |
| :--- | :--- | :--- | :--- |
| **`wazig build-exe` (`0.17.0-wazig.4`)** | **PASS (Out-of-the-Box)** | **PASS (Pure-Zig `libzigc.a`)** | Built-in `WasmAllocator`, `wasi_thread_start` trampoline, `__tls_base`, and `stage2_wasm` atomics without LLVM |
| **`wazigl build-exe` (`0.17.0-wazigl.4`)** | **PASS (Out-of-the-Box)** | **PASS (Pure-Zig `libzigc.a`)** | Built-in `WasmAllocator`, Wasm-hosted LLVM 21 TLS/atomics, and pure-Zig `libzigc.a` |
| **Standard `zig` (`0.17.0`, stock install)** | **FAIL** | **PASS (Heavy musl `libc.a`)** | `~/.local/share/ghr/tools/_v2/units/u-cataggar/u-zig/_unit/zig-aarch64-linux-0.17.0/lib/std/heap.zig:18:74: error: unimplemented` — requires manually patching `lib/std` with `wasi-thread.patch` |
| **Standard `zig -fno-llvm` (even with `wasi-thread.patch`)** | **FAIL** | **FAIL (`__main_argc_argv`)** | `~/.local/share/ghr/tools/_v2/units/u-cataggar/u-zig/u-wazig/_unit/lib/std/Thread.zig:1019:67: error: calling convention 'naked' not supported by compiler backend 'stage2_wasm'` |

### 2.3 Module Compilation Times Across 4 Modes (`ReleaseSmall`, in `ms`)

- **Cold `.zig-cache`**: Fresh `buildDir` with an empty `.zig-cache` (compiles `compiler_rt`, `std`, `libzigc.a`, and the module from scratch; note that `zig build` Warm Shared below uses an already-warmed host global cache — on a truly cold CI runner with an empty global cache, `zig build` takes **~107,300 ms** on its first run to compile host `libc` + `build.zig` runner vs **~9,300–16,200 ms** for `wazig build-exe`, a **6.6x–11.5x cold speedup** for `wazig`).
- **Warm Shared Cache (New Module)**: Compiling a new module when `std`, `compiler_rt`, and `libzigc.a` are already cached in `buildDir` (via `zigar-compiler`'s hardlinked shared cache). `wazig build-exe` (~3.9s) is **~1.81x faster** than upstream `zig build` (~7.1s) and **~2.66x faster** than `wazigl build-exe` (~10.5s, which runs LLVM 21 inside Wasmtime).
- **Warm Incremental Rebuild**: Recompiling after a source edit in the same `moduleBuildDir`.

| Category | Module | `zig build` Warm Shared / Warm Inc (`ms`) | `zig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | `wazig build-exe` Cold / Warm Shared / Warm Inc (`ms`) | `wazigl build-exe` Cold / Warm Shared / Warm Inc (`ms`) | Notes |
| :--- | :--- | ---: | ---: | ---: | ---: | :--- |
| Pure-Zig Basic | `integers` | `5606` / `710` | `2715` / `2683` / `836` | **`9030` / `4105` / `1938`** | `14665` / `10699` / `4488` | `wazig` **1.37x faster** vs `zig build` & **2.6x faster** vs `wazigl` |
| Pure-Zig Basic | `simple` | `7126` / `816` | `2658*` / `2626` / `766` | **`8857*` / `3932` / `1719`** | `14438*` / `10472` / `4114` | `wazig` **1.81x faster** vs `zig build` & **2.7x faster** vs `wazigl` |
| Pure-Zig Basic | `console` | `7129` / `817` | `2661*` / `2629` / `767` | **`8786*` / `3861` / `1712`** | `14448*` / `10483` / `4119` | `wazig` **1.85x faster** vs `zig build` & **2.7x faster** vs `wazigl` |
| C Header (translate-c) | `print` | `5574` / `665` | `57163` / `2739` / `771` | **`9681` / `4621` / `2496`** | `15884` / `11408` / `5700` | `wazig` **5.9x faster** & `wazigl` **3.6x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| C Header (translate-c) | `return-c-pointer` | `10015` / `3612` | `59939*` / `5515` / `3562` | **`19766*` / `14705` / `7606`** | `27449*` / `22973` / `26345` | `wazig` **3.0x faster** & `wazigl` **2.2x faster** cold vs `zig build-exe` (in-process `translate-c`) |
| Libc (-lc) | `dupe` | `6427` / `1575` | `6217` / `1630` / `1642` | **`16189` / `2468` / `2506`** | `30341` / `9647` / `5689` | `wazig` **2.60x faster** new-module vs `zig build`; pure-Zig `libzigc.a` in `wazig` & `wazigl` |
| Multithreaded WASM | `thread` | `5562` / `1046` | `3031*` / `1062` / `996` | **`12953*` / `6150` / `2237`** | `11549*` / `5355` / `5145` | Stock `zig` fails without `wasi-thread.patch`; both `wazig` & `wazigl` work out-of-the-box |
| Multithreaded WASM | `atomic` | `5284` / `847` | `2753` / `784` / `797` | **`8900` / `2097` / `2382`** | `14905` / `8711` / `4813` | Stock `zig` fails without `wasi-thread.patch`; both `wazig` & `wazigl` work out-of-the-box |
| Compute Kernels | `mandelbrot` | `5835` / `778` | `2835` / `3251` / `903` | **`9075` / `4106` / `1888`** | `15013` / `11048` / `4503` | `wazig` **1.42x faster** vs `zig build` & **2.7x faster** vs `wazigl` |
| Compute Kernels | `nbody` | `7702` / `1403` | `3202*` / `3202` / `1353` | **`9771*` / `4802` / `2635`** | `14846*` / `10881` / `6752` | `wazig` **1.60x faster** vs `zig build` & **2.3x faster** vs `wazigl` |
| Compute Kernels | `fannkuch-redux` | `9747` / `3178` | `5247*` / `5247` / `3128` | **`13623*` / `8654` / `6339`** | `21793*` / `17828` / `15607` | `wazig` **1.13x faster** vs `zig build` & **2.1x faster** vs `wazigl` |
| Compute Kernels | `spectral-norm` | `7453` / `1049` | `2953*` / `2953` / `999` | **`9222*` / `4253` / `2098`** | `14001*` / `10036` / `4983` | `wazig` **1.75x faster** vs `zig build` & **2.4x faster** vs `wazigl` |
| Compute Kernels | `sepia` | `7828` / `1460` | `3328*` / `3328` / `1410` | **`9894*` / `4925` / `2725`** | `15272*` / `11307` / `7034` | `wazig` **1.59x faster** vs `zig build` & **2.3x faster** vs `wazigl` |
| Compute Kernels | `raytracer` | `8875` / `2531` | `4375*` / `4375` / `2481` | **`11748*` / `6779` / `4519`** | `18830*` / `14865` / `12379` | `wazig` **1.31x faster** vs `zig build` & **2.2x faster** vs `wazigl` |

---
## 3. Output `.wasm` Binary Size (Raw & Stripped)

Compares output `.wasm` sizes before (`compile()`) and after dead-code & reflection factory stripping (`stripUnused()`) across all 4 Zig optimization modes and 5 compiler configurations:
1. **Upstream `zig` (`-lc` + LLVM)**: Prior default where `build.zig` unconditionally linked `libc`.
2. **Standard `zig` (Pure-Zig + LLVM)**: `useLibc: false` with native LLVM 21 backend.
3. **`wazigl` (`0.17.0-wazigl.4`, Wasm-hosted LLVM + Pure-Zig `libzigc.a`)**: Wasm-hosted LLVM 21 backend matching native `zig (Pure-Zig LLVM)` on pure-Zig modules while shrinking `-lc` modules via pure-Zig `libzigc.a`.
4. **Standard `zig` (`-fno-llvm` `stage2_wasm`)**: Upstream self-hosted Wasm backend (**crashes `stripUnused()`** in `Debug`/`ReleaseFast`/`ReleaseSafe` due to unnormalized `host.wasm.getFactoryThunk__func_*` name section entries, **fails to link `-lc`**, and **fails to strip reflection metadata in `ReleaseSmall`** because `getFactoryThunk` is not inlined).
5. **`wazig` (`0.17.0-wazig.4`)**: Self-hosted `stage2_wasm` enhanced with SROA, `Optimizer.zig` leaf inlining & peephole passes, MIR dead-store/copy-propagation, MemArg offset folding, local RLE compaction, and post-link dead-function/constant pruning.

### 3.1 `Debug` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.4)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.4)` Raw / Stripped | `wazig` & `wazigl` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1821.7 KiB` / `232.0 KiB` | `1464.9 KiB` / `170.9 KiB` | `1468.2 KiB` / `171.2 KiB` | `338.1 KiB` / `ERR (unstrippable)` | **`189.3 KiB` / `123.4 KiB`** | `wazig`: **9.62x smaller raw**, **-46.8% stripped** vs `-lc` |
| `console` | `1803.5 KiB` / `232.2 KiB` | `1447.2 KiB` / `171.1 KiB` | `1450.5 KiB` / `171.4 KiB` | `324.6 KiB` / `ERR (unstrippable)` | **`185.3 KiB` / `123.4 KiB`** | `wazig`: **9.73x smaller raw**, **-46.9% stripped** vs `-lc` |
| `print (translate-c)` | `1812.6 KiB` / `234.0 KiB` | `1455.6 KiB` / `172.5 KiB` | `1458.9 KiB` / `172.9 KiB` | `326.9 KiB` / `ERR (unstrippable)` | **`187.3 KiB` / `124.1 KiB`** | `wazig`: **9.68x smaller raw**, **-47.0% stripped** vs `-lc` |
| `dupe (-lc)` | `2014.1 KiB` / `236.2 KiB` | `2014.1 KiB` / `236.2 KiB` | `3345.3 KiB` / `234.5 KiB` | FAIL (`-lc` linker bug) | **`269.0 KiB` / `152.7 KiB`** | `wazig`: **7.49x smaller raw**, **-35.3% stripped** vs `-lc` |
| `fannkuch-redux` | `3534.8 KiB` / `288.2 KiB` | `3075.6 KiB` / `222.5 KiB` | `3078.8 KiB` / `222.8 KiB` | `911.8 KiB` / `ERR (unstrippable)` | **`632.2 KiB` / `152.5 KiB`** | `wazig`: **5.59x smaller raw**, **-47.1% stripped** vs `-lc` |
| `nbody` | `2186.5 KiB` / `235.8 KiB` | `1808.2 KiB` / `174.5 KiB` | `1811.5 KiB` / `174.8 KiB` | `459.2 KiB` / `ERR (unstrippable)` | **`281.7 KiB` / `126.5 KiB`** | `wazig`: **7.76x smaller raw**, **-46.4% stripped** vs `-lc` |
| `sepia` | `2215.4 KiB` / `238.7 KiB` | `1835.5 KiB` / `177.4 KiB` | `1838.8 KiB` / `177.7 KiB` | `474.5 KiB` / `ERR (unstrippable)` | **`290.3 KiB` / `129.9 KiB`** | `wazig`: **7.63x smaller raw**, **-45.6% stripped** vs `-lc` |
| `raytracer` | `3014.1 KiB` / `265.3 KiB` | `2597.8 KiB` / `203.4 KiB` | `2601.1 KiB` / `203.7 KiB` | `752.4 KiB` / `ERR (unstrippable)` | **`499.9 KiB` / `155.7 KiB`** | `wazig`: **6.03x smaller raw**, **-41.3% stripped** vs `-lc` |

### 3.2 `ReleaseSmall` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.4)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.4)` Raw / Stripped | `wazig` vs `zig (-fno-llvm)` & `wazigl` vs `zig` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `60.1 KiB` / `44.4 KiB` | `44.5 KiB` / `31.0 KiB` | `44.5 KiB` / `31.0 KiB` | `162.9 KiB` / `155.5 KiB` | **`106.3 KiB` / `76.2 KiB`** | `wazig`: **2.04x smaller stripped** (**-34.8% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `console` | `59.1 KiB` / `44.7 KiB` | `43.6 KiB` / `31.4 KiB` | `43.6 KiB` / `31.4 KiB` | `152.7 KiB` / `152.5 KiB` | **`103.7 KiB` / `77.3 KiB`** | `wazig`: **1.97x smaller stripped** (**-32.1% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `print (translate-c)` | `59.5 KiB` / `44.8 KiB` | `44.0 KiB` / `31.4 KiB` | `44.0 KiB` / `31.4 KiB` | `154.6 KiB` / `154.3 KiB` | **`105.2 KiB` / `79.2 KiB`** | `wazig`: **1.95x smaller stripped** (**-32.0% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `dupe (-lc)` | `72.7 KiB` / `45.3 KiB` | `72.7 KiB` / `45.3 KiB` | `71.4 KiB` / `44.7 KiB` | FAIL (`-lc` linker bug) | **`165.0 KiB` / `101.5 KiB`** | **PASS** (`zig -fno-llvm` fails `-lc`; `wazigl` **1.02x smaller** than `zig -lc`) |
| `fannkuch-redux` | `204.0 KiB` / `55.2 KiB` | `188.1 KiB` / `42.1 KiB` | `188.1 KiB` / `42.1 KiB` | `555.4 KiB` / `549.5 KiB` | **`406.7 KiB` / `100.4 KiB`** | `wazig`: **5.47x smaller stripped** (**-26.8% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `nbody` | `88.7 KiB` / `46.0 KiB` | `73.6 KiB` / `32.9 KiB` | `73.6 KiB` / `32.9 KiB` | `248.3 KiB` / `240.9 KiB` | **`172.0 KiB` / `78.9 KiB`** | `wazig`: **3.05x smaller stripped** (**-30.7% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `sepia` | `92.0 KiB` / `45.9 KiB` | `76.9 KiB` / `32.8 KiB` | `76.9 KiB` / `32.8 KiB` | `257.1 KiB` / `249.7 KiB` | **`177.4 KiB` / `80.8 KiB`** | `wazig`: **3.09x smaller stripped** (**-31.0% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |
| `raytracer` | `147.8 KiB` / `59.1 KiB` | `132.5 KiB` / `46.0 KiB` | `132.5 KiB` / `46.0 KiB` | `444.3 KiB` / `436.7 KiB` | **`321.0 KiB` / `102.7 KiB`** | `wazig`: **4.25x smaller stripped** (**-27.7% raw** vs `-fno-llvm`); `wazigl` = LLVM parity |

### 3.3 `ReleaseFast` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.4)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.4)` Raw / Stripped | `wazig` & `wazigl` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1428.6 KiB` / `48.4 KiB` | `1117.2 KiB` / `33.6 KiB` | `1117.1 KiB` / `33.6 KiB` | `187.2 KiB` / `ERR (unstrippable)` | **`168.2 KiB` / `111.1 KiB`** | `wazig`: **8.49x smaller raw** vs `-lc`, **-10.2% raw** vs `-fno-llvm` (strippable) |
| `console` | `1419.1 KiB` / `49.0 KiB` | `1107.7 KiB` / `34.2 KiB` | `1107.6 KiB` / `34.2 KiB` | `176.0 KiB` / `ERR (unstrippable)` | **`164.4 KiB` / `112.1 KiB`** | `wazig`: **8.63x smaller raw** vs `-lc`, **-6.6% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1423.7 KiB` / `49.1 KiB` | `1112.2 KiB` / `34.4 KiB` | `1112.1 KiB` / `34.4 KiB` | `178.2 KiB` / `ERR (unstrippable)` | **`166.2 KiB` / `114.1 KiB`** | `wazig`: **8.57x smaller raw** vs `-lc`, **-6.7% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1581.3 KiB` / `49.8 KiB` | `1581.3 KiB` / `49.8 KiB` | `2889.2 KiB` / `51.9 KiB` | FAIL (`-lc` linker bug) | **`266.4 KiB` / `160.5 KiB`** | `wazig`: **5.93x smaller raw** vs `-lc`, **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `3018.3 KiB` / `62.5 KiB` | `2692.2 KiB` / `47.9 KiB` | `2692.0 KiB` / `47.9 KiB` | `738.4 KiB` / `ERR (unstrippable)` | **`653.0 KiB` / `138.6 KiB`** | `wazig`: **4.62x smaller raw** vs `-lc`, **-11.6% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1755.5 KiB` / `50.3 KiB` | `1445.1 KiB` / `35.7 KiB` | `1445.0 KiB` / `35.7 KiB` | `303.7 KiB` / `ERR (unstrippable)` | **`262.5 KiB` / `113.8 KiB`** | `wazig`: **6.69x smaller raw** vs `-lc`, **-13.5% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1850.4 KiB` / `49.7 KiB` | `1540.0 KiB` / `35.1 KiB` | `1539.9 KiB` / `35.1 KiB` | `316.2 KiB` / `ERR (unstrippable)` | **`271.7 KiB` / `115.9 KiB`** | `wazig`: **6.81x smaller raw** vs `-lc`, **-14.1% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2303.9 KiB` / `66.9 KiB` | `1998.2 KiB` / `52.3 KiB` | `1998.1 KiB` / `52.3 KiB` | `577.3 KiB` / `ERR (unstrippable)` | **`472.2 KiB` / `140.1 KiB`** | `wazig`: **4.88x smaller raw** vs `-lc`, **-18.2% raw** vs `-fno-llvm` (strippable) |

### 3.4 `ReleaseSafe` Mode — Raw & Stripped `.wasm` Sizes

| Module | `zig (-lc + LLVM)` Raw / Stripped | `zig (Pure-Zig LLVM)` Raw / Stripped | `wazigl (0.17.0-wazigl.4)` Raw / Stripped | `zig (-fno-llvm)` Raw / Stripped | `wazig (0.17.0-wazig.4)` Raw / Stripped | `wazig` & `wazigl` vs Upstream `-lc` & `zig (-fno-llvm)` |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| `simple` | `1503.2 KiB` / `72.0 KiB` | `1158.5 KiB` / `50.5 KiB` | `1158.4 KiB` / `50.5 KiB` | `245.1 KiB` / `ERR (unstrippable)` | **`170.2 KiB` / `115.7 KiB`** | `wazig`: **8.83x smaller raw** vs `-lc`, **-30.5% raw** vs `-fno-llvm` (strippable) |
| `console` | `1495.3 KiB` / `72.4 KiB` | `1150.4 KiB` / `50.9 KiB` | `1150.3 KiB` / `50.9 KiB` | `231.6 KiB` / `ERR (unstrippable)` | **`166.3 KiB` / `116.5 KiB`** | `wazig`: **8.99x smaller raw** vs `-lc`, **-28.2% raw** vs `-fno-llvm` (strippable) |
| `print (translate-c)` | `1499.5 KiB` / `72.4 KiB` | `1154.6 KiB` / `50.9 KiB` | `1154.5 KiB` / `50.9 KiB` | `234.4 KiB` / `ERR (unstrippable)` | **`168.2 KiB` / `117.4 KiB`** | `wazig`: **8.91x smaller raw** vs `-lc`, **-28.3% raw** vs `-fno-llvm` (strippable) |
| `dupe (-lc)` | `1611.2 KiB` / `73.6 KiB` | `1611.2 KiB` / `73.6 KiB` | `2895.7 KiB` / `74.4 KiB` | FAIL (`-lc` linker bug) | **`249.7 KiB` / `148.8 KiB`** | `wazig`: **6.45x smaller raw** vs `-lc`, **PASS** (`-fno-llvm` fails `-lc`) |
| `fannkuch-redux` | `2639.8 KiB` / `93.9 KiB` | `2325.4 KiB` / `72.0 KiB` | `2325.3 KiB` / `72.0 KiB` | `816.2 KiB` / `ERR (unstrippable)` | **`610.5 KiB` / `151.8 KiB`** | `wazig`: **4.32x smaller raw** vs `-lc`, **-25.2% raw** vs `-fno-llvm` (strippable) |
| `nbody` | `1720.4 KiB` / `74.0 KiB` | `1380.6 KiB` / `52.7 KiB` | `1380.4 KiB` / `52.7 KiB` | `366.6 KiB` / `ERR (unstrippable)` | **`263.1 KiB` / `118.9 KiB`** | `wazig`: **6.54x smaller raw** vs `-lc`, **-28.2% raw** vs `-fno-llvm` (strippable) |
| `sepia` | `1721.5 KiB` / `73.7 KiB` | `1378.5 KiB` / `52.3 KiB` | `1378.4 KiB` / `52.3 KiB` | `380.6 KiB` / `ERR (unstrippable)` | **`270.5 KiB` / `122.6 KiB`** | `wazig`: **6.36x smaller raw** vs `-lc`, **-28.9% raw** vs `-fno-llvm` (strippable) |
| `raytracer` | `2154.4 KiB` / `91.9 KiB` | `1815.1 KiB` / `70.4 KiB` | `1814.9 KiB` / `70.4 KiB` | `658.7 KiB` / `ERR (unstrippable)` | **`480.4 KiB` / `150.2 KiB`** | `wazig`: **4.49x smaller raw** vs `-lc`, **-27.1% raw** vs `-fno-llvm` (strippable) |

---
## 4. Runtime Execution Performance in V8 (Node.js)

All 13 compute & image-processing modules transpiled via `transpile({ optimize: 'ReleaseFast' })` and executed in Node.js V8 (`v22.15.0`). Times in milliseconds (`median` / `p95`).

| Suite | Benchmark | Workload | `wazig (0.17.0-wazig.4)` Median (p95) `ms` | `wazigl (0.17.0-wazigl.4)` Median (p95) `ms` | `zig (-fno-llvm)` Median (p95) `ms` | `zig (LLVM)` Median (p95) `ms` | `wazig` vs `zig -fno-llvm` | `wazigl` vs `zig (LLVM)` |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: | :--- | :--- |
| Benchmarks Game | `nbody` | `advance(solar_bodies, 0.01, 500000)` | **`52.09`** (`52.25`) | `49.45` (`49.46`) | `99.92` (`100.15`) | `49.33` (`49.46`) | **1.92x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `fannkuch-redux` | `Pfannkuchen(10)` | **`311.46`** (`312.13`) | `195.84` (`196.67`) | `2213.57` (`2217.59`) | `196.10` (`196.98`) | **7.11x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `spectral-norm` | `spectralNorm(1000)` | **`82.60`** (`82.61`) | `59.07` (`59.10`) | `512.81` (`513.08`) | `59.10` (`59.16`) | **6.21x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `mandelbrot` | `mandelbrot(1000)` | **`75.69`** (`75.76`) | `64.90` (`65.16`) | `166.28` (`166.28`) | `64.86` (`64.93`) | **2.20x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `binary-trees` | `binaryTree(12)` | **`34.63`** (`34.79`) | `15.59` (`15.61`) | `143.78` (`143.80`) | `15.57` (`15.65`) | **4.15x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Benchmarks Game | `fasta` | `fasta(100000)` | **`103.57`** (`107.38`) | `97.98` (`101.66`) | `111.57` (`114.52`) | `102.28` (`104.68`) | **1.08x faster** vs `-fno-llvm` | `1.04x` (LLVM parity) |
| Image Processing | `polish-flag` | `render(320x200)` | **`4.27`** (`4.30`) | `0.42` (`0.87`) | `6.25` (`6.27`) | `0.33` (`0.38`) | **1.46x faster** vs `-fno-llvm` | `0.79x` (sub-ms noise; identical LLVM codegen) |
| Image Processing | `resize` | `malgorzata-socha.png -> 384x288` | **`49.68`** (`49.72`) | `2.99` (`3.04`) | `72.80` (`76.74`) | `3.06` (`3.06`) | **1.47x faster** vs `-fno-llvm` | `1.02x` (LLVM parity) |
| Image Processing | `greyscale` | `malgorzata-socha.png (in-place)` | **`18.25`** (`18.32`) | `1.17` (`1.29`) | `28.01` (`28.25`) | `1.17` (`1.23`) | **1.53x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Image Processing | `sepia` | `malgorzata-socha.png (intensity=0.3)` | **`58.20`** (`58.22`) | `4.09` (`4.17`) | `84.70` (`84.97`) | `4.16` (`4.18`) | **1.46x faster** vs `-fno-llvm` | `1.02x` (LLVM parity) |
| Image Processing | `circle-pattern` | `malgorzata-socha.png (circle filter)` | **`63.25`** (`63.28`) | `6.40` (`6.45`) | `82.31` (`82.41`) | `6.49` (`6.53`) | **1.30x faster** vs `-fno-llvm` | `1.01x` (LLVM parity) |
| Image Processing | `raytracer` | `process(256x256)` | **`351.44`** (`351.48`) | `25.82` (`25.94`) | `458.44` (`459.68`) | `25.89` (`25.97`) | **1.30x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |
| Image Processing | `mandelbulb-quick` | `process(200x200)` | **`413.38`** (`414.43`) | `201.30` (`201.37`) | `614.17` (`614.32`) | `201.15` (`201.16`) | **1.49x faster** vs `-fno-llvm` | `1.00x` (LLVM parity) |

---
## 5. Key Takeaways: `wazig` (`0.17.0-wazig.4`) & `wazigl` (`0.17.0-wazigl.4`) vs Standard `zig` (`0.17.0`)

1. **Universal `wasm64-wasip3` Distribution (`wazig` 8.47 MiB & `wazigl` 36.48 MiB vs 50–100 MB Per-Platform Native `zig`)**: Both `wazig` (`8.88 MB (8.47 MiB)` compressed, `66.55 MB (63.47 MiB)` uncompressed across `1,322` files) and `wazigl` (`38.25 MB (36.48 MiB)` compressed, `237.00 MB (226.02 MiB)` uncompressed across `1,322` files) run on any OS/CPU via Wasmtime — replacing 6 desktop OS/arch archives totaling `419.77 MB (400.33 MiB)` (**47.27x smaller** with `wazig`, **10.97x smaller** with `wazigl`).
2. **225x Faster (`wazig`) & 38.0x Faster (`wazigl`) Cold `translate-c`**: Standard `zig 0.17.0` moved `translate-c` into an external sub-binary that takes **~54.6 seconds** to compile on a cold cache. `wazig` embeds `translate-c` + Aro in-process (**~243 ms** cold) and `wazigl` embeds `translate-c` + Clang in-process (**~1437 ms** cold).
3. **Out-of-the-Box Multithreaded WASM & Pure-Zig `libzigc.a` in Both `wazig` and `wazigl`**: Stock `zig 0.17.0` fails on `multithreaded: true` WASM builds (`WasmAllocator` unimplemented) unless users manually patch their system Zig installation with `wasi-thread.patch`, and `zig -fno-llvm` fails both on multithreaded WASM (`naked` calling convention unsupported) and on `-lc` reactor modules (`libc.a: undefined function: __main_argc_argv`). Both `wazig` and `wazigl` support multithreaded WASM and `-lc` reactor modules out of the box.
4. **Dramatically Smaller `Debug` & `ReleaseSmall` Binaries with Native `__stack_pointer` Export**: In `Debug` mode (Zigar's default development mode), `wazig` emits raw `.wasm` binaries **5.59x–9.73x smaller** than LLVM (`185–632 KiB` vs `1.80–3.53 MiB`) and stripped binaries **35%–47% smaller** (`123–156 KiB` vs `232–288 KiB`). In `ReleaseSmall`, `wazig`'s SROA, leaf inlining, MIR peephole, and post-link optimizations produce **1.95x–5.47x smaller** stripped binaries than upstream `zig -fno-llvm`, while `wazigl` matches native `zig (Pure-Zig LLVM)` byte-for-byte (**1.29x–1.43x smaller** than upstream `zig -lc`) and links `-lc` modules via pure-Zig `libzigc.a`.
5. **Complementary Compile-Time vs Runtime Tradeoff (`wazig` vs `wazigl`)**: `wazig` compiles new modules in **~3.9s** (**~1.81x faster** than `zig build` and **~2.66x faster** than `wazigl`) while executing **1.08x–7.11x faster** in V8 than upstream `zig -fno-llvm`. When full LLVM codegen optimization is required without a platform-native Zig/LLVM install, `wazigl` delivers **1.00x V8 runtime parity** and **1.00x output size parity** with native `zig (LLVM)` from a single portable Wasm binary.
