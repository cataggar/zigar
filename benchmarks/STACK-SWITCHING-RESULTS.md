# V8 `--experimental-wasm-growable-stacks` & `--experimental-wasm-wasmfx` — Benchmark & Prototype Results (`#14`)

Empirical evaluation, prototype, and runtime integration of V8's WebAssembly stack-switching mechanisms across **`zigar-runtime`**, **`wazig` (`v0.17.0-wazig.4`)**, **`wazigl` (`v0.17.0-wazigl.4`)**, **`zig` (`0.17.0`)**, **`jsco` / `jco` (WASI P1/P2/P3)**, and **Wasmtime (`50.0.1`)**.

- **Runtime**: Node.js `v24.21.0` (V8 `13.6.233.17-node.53`, `linux-arm64`)
- **Toolchains**: `wazig` `0.17.0-wazig.4`, `wazigl` `0.17.0-wazigl.4`, `zig` `0.17.0`, `wasmtime` `50.0.1 (c307ec81d 2026-10-29)`
- **Benchmark Scripts**:
  - [`benchmarks/wasm-stack-switching-benchmark.js`](./wasm-stack-switching-benchmark.js) → [`benchmarks/stack-switching-results.json`](./stack-switching-results.json)
  - [`benchmarks/wasmfx-prototype.js`](./wasmfx-prototype.js) → [`benchmarks/wasmfx-results.json`](./wasmfx-results.json)

---

## Executive Summary

| Dimension | Default Fixed JSPI (`984 KB`) | Fixed Small JSPI (`4 KB`) | V8 Growable Stacks (`4 KB` + `--experimental-wasm-growable-stacks`) | Impact |
| :--- | :--- | :--- | :--- | :--- |
| **Virtual Memory / Fiber (`depth = 5`, `N = 1000`)** | `984.0 KiB/fiber` (`984,000 KiB` `deltaVmSize`) | `44.0 KiB/fiber` (`44,000 KiB` `deltaVmSize`) | **`44.0 KiB/fiber` (`44,000 KiB` `deltaVmSize`)** | **22.36x smaller `VmSize` / `rw-p`** (`4 KB` stack + `40 KB` `kJSLimitOffsetKB` margin) |
| **Resident Memory / Fiber (`depth = 5`, `N = 1000`)** | `5.10 KiB/fiber` (`5,104 KiB` `deltaRssAnon`) | `5.10 KiB/fiber` (`5,100 KiB` `deltaRssAnon`) | **`5.10 KiB/fiber` (`5,100–5,104 KiB` `deltaRssAnon`)** | Identical demand-paged `RssAnon` (`~1.28` 4K pages touched at `depth = 5`) |
| **Deep Concurrent Fibers (`depth = 100`, `N = 1000`)** | `984.0 KiB/fiber` `VmSize` (`17.10 KiB` `RssAnon`) | **CRASH (`RangeError` at `depth = 31`)** | **`132.0 KiB/fiber` `VmSize`** (`17.11 KiB` Turboshaft / `21.10 KiB` Tiered `RssAnon`) | **7.45x smaller `VmSize`** (`44 + 88 KiB` linked segments), **zero stack overflows** |
| **Max Recursion Depth (`5 .. 5,000` frames)** | Succeeds (`4.45 ns/frame` at `d = 5000`) | **Overflows at `depth = 31`** (`max = 30`) | **Succeeds across `5 .. 5,000`** (`3.62 ns/frame` Turboshaft / `4.53 ns/frame` Tiered at `d = 5000`) | **Unbounded growth** with negligible (`~0.08 ns/frame` tiered) prologue check overhead |
| **Post-Burst Stack Decommit (`200` fibers @ `d = 1000`)** | Retains `196,800 KiB` `VmSize` | Cannot reach `d = 1000` | Peak `+61,600 KiB` `rw-p` / `+19,420 KiB` `RssAnon` → **Reclaims `91.0%` `RssAnon` (`17,668 KiB`) & decommits `93.5%` `rw-p` (`57,596 KiB` → `PROT_NONE`)** | V8 `StackPool` (`4 MiB` cap) decommits excess stack pages (`rw-p` → `---p`) on completion |
| **Batched JSPI Suspend/Resume (`100 × 100` concurrent)** | `9,543.06 ns/cycle` | Overflows at `depth > 30` | **`1,561.63 ns/cycle` (Turboshaft) / `1,599.77 ns/cycle` (Tiered)** | **5.97x–6.11x faster** (93 `44 KiB` stacks fit in V8's `4 MiB` `StackPool` vs 4 `984 KB` stacks) |
| **Concurrent Dual-Stack (`global[0]` `__stack_pointer`, 50 fibers × 20)** | **82% corrupted (`41/50` fibers)** without `global[0]` switching | **82% corrupted** without `global[0]` switching | **0% corrupted (`50/50` fibers valid)** with per-continuation `global[0]` switching (`+150 ns/switch` e2e; `38.96 ns` raw `global[0]` save+restore) | Host stack switching MUST be paired with `global[0]` (`__stack_pointer`) switching |

---

## 1. Concurrent Suspended JSPI Stack Memory Scaling (`N = 1 .. 1000` Fibers)

In V8 `13.6`, `StackMemory::Allocate(size)` always adds `kJSLimitOffsetKB * KB` (`40 KiB`) of redzone/margin to the requested `--wasm-stack-switching-stack-size`:
- With default `--wasm-stack-switching-stack-size=984`, each fiber allocates a contiguous **`984 KiB` (`246` 4K pages)** virtual mapping (`deltaVmSizeKiB` / `deltaRwAnonKiB`).
- With `--experimental-wasm-growable-stacks --wasm-stack-switching-stack-size=4`, each fiber starts with a **`44 KiB` (`4 KiB` usable Wasm frame space + `40 KiB` margin)** initial segment and dynamically links doubled segments (`88 KiB`, `176 KiB`, `352 KiB`, ...) via `WasmGrowableStackGuard` only when recursion exceeds the current segment.

### Shallow Suspension (`depth = 5`, `deltaVmSizeKiB` / `deltaRssAnonKiB`)

| Config | V8 Flags | `N = 10` `ΔVmSize` / `ΔRssAnon` | `N = 100` `ΔVmSize` / `ΔRssAnon` | `N = 500` `ΔVmSize` / `ΔRssAnon` | `N = 1000` `ΔVmSize` (`KiB/fiber`) | `N = 1000` `ΔRssAnon` (`KiB/fiber`) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| **Config A** | Default Fixed `984 KB` | `9,840` / `132 KiB` | `98,400` / `572 KiB` | `492,000` / `2,624 KiB` | `984,000 KiB` (**`984.0 KiB`**) | `5,104 KiB` (**`5.10 KiB`**) |
| **Config B** | Fixed `64 KB` | `1,040` / `132 KiB` | `10,400` / `572 KiB` | `52,000` / `2,624 KiB` | `104,000 KiB` (**`104.0 KiB`**) | `5,104 KiB` (**`5.10 KiB`**) |
| **Config C** | Fixed `4 KB` (no grow) | `440` / `132 KiB` | `4,400` / `576 KiB` | `22,000` / `2,624 KiB` | `44,000 KiB` (**`44.0 KiB`**) | `5,100 KiB` (**`5.10 KiB`**) |
| **Config D** | **Growable `4 KB` (`--no-liftoff`)** | **`440` / `136 KiB`** | **`4,400` / `572 KiB`** | **`22,000` / `2,624 KiB`** | **`44,000 KiB` (`44.0 KiB`)** | **`5,100 KiB` (`5.10 KiB`)** |
| **Config E** | **Growable `4 KB` (Tiered)** | **`440` / `132 KiB`** | **`4,400` / `572 KiB`** | **`22,000` / `2,624 KiB`** | **`44,000 KiB` (`44.0 KiB`)** | **`5,104 KiB` (`5.10 KiB`)** |

### Deep Suspension (`depth = 100`, `deltaVmSizeKiB` / `deltaRssAnonKiB`)

| Config | V8 Flags | Status @ `depth = 100` | `N = 100` `ΔVmSize` / `ΔRssAnon` | `N = 500` `ΔVmSize` / `ΔRssAnon` | `N = 1000` `ΔVmSize` (`KiB/fiber`) | `N = 1000` `ΔRssAnon` (`KiB/fiber`) |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: |
| **Config A** | Default Fixed `984 KB` | OK (1 segment: `984 KiB`) | `98,400` / `1,772 KiB` | `492,000` / `8,624 KiB` | `984,000 KiB` (**`984.0 KiB`**) | `17,100 KiB` (**`17.10 KiB`**) |
| **Config B** | Fixed `64 KB` | OK (1 segment: `104 KiB`) | `10,400` / `1,772 KiB` | `52,000` / `8,620 KiB` | `104,000 KiB` (**`104.0 KiB`**) | `17,108 KiB` (**`17.11 KiB`**) |
| **Config C** | Fixed `4 KB` (no grow) | **STACK_OVERFLOW (`RangeError` @ `d = 31`)** | — | — | — | — |
| **Config D** | **Growable `4 KB` (`--no-liftoff`)** | **OK (2 segments: `44 + 88 = 132 KiB`)** | **`13,200` / `1,772 KiB`** | **`66,000` / `8,624 KiB`** | **`132,000 KiB` (`132.0 KiB`)** | **`17,108 KiB` (`17.11 KiB`)** |
| **Config E** | **Growable `4 KB` (Tiered)** | **OK (2 segments: `44 + 88 = 132 KiB`)** | **`13,200` / `2,172 KiB`** | **`66,000` / `10,624 KiB`** | **`132,000 KiB` (`132.0 KiB`)** | **`21,100 KiB` (`21.10 KiB`)** |

---

## 2. Recursion Depth & Stack Overflow Resilience (`depth = 5 .. 5,000`)

Without `--experimental-wasm-growable-stacks`, a `4 KB` JSPI stack overflows at **frame depth `31`** (`maxSuccessDepth = 30`, `RangeError: Maximum call stack size exceeded`). With `--experimental-wasm-growable-stacks`, V8's Turboshaft `GrowableStacksReducer` emits stack-limit checks at function prologues (`Runtime::kWasmGrowableStackGuard`) and return epilogues (`Runtime::kWasmShrinkStack`), scaling seamlessly to `depth = 5,000`.

| Config | Max Depth Reached | Overflow Depth | `d = 5` (`ns/frame`) | `d = 25` (`ns/frame`) | `d = 100` (`ns/frame`) | `d = 500` (`ns/frame`) | `d = 1000` (`ns/frame`) | `d = 2500` (`ns/frame`) | `d = 5000` (`ns/frame`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Fixed `4 KB` (No Growable)** | `30` | **`31` (`RangeError`)** | `210.80` | `45.99` | *overflow* | *overflow* | *overflow* | *overflow* | *overflow* |
| **Fixed `984 KB` (Default)** | `5,000` | None | `209.00` | `46.76` | `13.64` | `5.99` | `5.13` | `4.44` | `4.45` |
| **Growable `4 KB` (`--no-liftoff`)** | **`5,000`** | **None** | `214.62` | `45.55` | `13.12` | `5.26` | `4.39` | `3.72` | **`3.62`** |
| **Growable `4 KB` (Tiered)** | **`5,000`** | **None** | `212.26` | `46.79` | `14.65` | `6.22` | `5.22` | `4.60` | **`4.53`** |

> **Critical Liftoff vs Turboshaft Finding**: In V8 `13.6`, `GrowableStacksReducer` is implemented in the **Turboshaft** optimizing compiler tier, not the baseline **Liftoff** compiler. If a cold recursive Wasm function is invoked at `depth > 30` on its very first call before tiering up (~30–50 calls), Liftoff will hit the 4 KB stack limit unless either:
> 1. `--no-liftoff` is passed,
> 2. The function has warmed up into Turboshaft, or
> 3. `--wasm-stack-switching-stack-size=16` (or `32`) is used so cold Liftoff frames tier up mid-recursion before filling the initial segment.

---

## 3. Dynamic Stack Shrinking & Page Reclamation After Deep-Recursion Burst

Test workload: **200 concurrent JSPI fibers** recurse to **`depth = 1,000`** (allocating 3 linked segments per fiber: `44 KiB + 88 KiB + 176 KiB = 308 KiB/fiber`), suspend simultaneously at the bottom (`phase2DeepBurst`), resume and unwind to `depth = 1` (`phase3UnwoundShallow`), and then complete (`phase4PostReclaim`).

| Phase | `VmSize` (`KiB`) | `RssAnon` (`KiB`) | `/proc/self/smaps` `rw-p` (Committed) | `/proc/self/smaps` `---p` (`PROT_NONE` Decommitted) |
| :--- | ---: | ---: | ---: | ---: |
| **Phase 1: Baseline (Pre-Burst)** | `9,574,908` | `22,384` | `363,724 KiB` | `9,099,376 KiB` |
| **Phase 2: Peak Burst (`200` fibers @ `d = 1000`)** | `9,636,508` (**`+61,600 KiB`**) | `41,804` (**`+19,420 KiB`**) | `425,324 KiB` (**`+61,600 KiB`**) | `9,099,376 KiB` |
| **Phase 3: Unwound to `d = 1` (Still Suspended)** | `9,636,508` | `41,968` | `425,324 KiB` | `9,099,376 KiB` |
| **Phase 4: Post-Reclaim (All Fibers Completed)** | `9,636,508` | `24,136` (**`-17,668 KiB` / `91.0%` reclaimed**) | `367,728 KiB` (**`-57,596 KiB` / `93.5%` decommitted**) | `9,156,972 KiB` (**`+57,596 KiB` moved to `PROT_NONE`**) |

- Note how V8's virtual address cage retains the virtual reservation (`VmSize = 9,636,508 KiB`), while decommitting **`57,596 KiB` (`93.5%` of the `61,600 KiB` burst)** from `rw-p` back to `---p` (`PROT_NONE`) and releasing **`17,668 KiB` (`91.0%`) of physical `RssAnon`** back to the OS kernel (retaining `4,004 KiB` of `rw-p` pages in V8's `4 MiB` `StackPool`).

---

## 4. JSPI Suspension / Resumption Latency Microbenchmark (`10,000` Cycles)

| Benchmark Workload (Median `ns`) | Default Fixed `984 KB` | Growable `4 KB` (`--no-liftoff`) | Growable `4 KB` (Tiered) | Speedup (Growable vs `984 KB`) |
| :--- | ---: | ---: | ---: | ---: |
| **1. Direct Sync Wasm Call (No JSPI)** | `57.33 ns` | `37.61 ns` | `53.27 ns` | `1.08x–1.52x` |
| **2. `promising` → `Suspending` (Sync Return)** | `1,144.97 ns` | `1,216.88 ns` | `1,128.44 ns` | `0.94x–1.01x` |
| **3. Sequential `Promise.resolve` (`10,000` cycles)** | `1,035.63 ns` | `1,099.17 ns` | `1,037.45 ns` | `0.94x–1.00x` |
| **4. Batched `100 × 100` Concurrent Fibers** | `9,543.06 ns` | **`1,561.63 ns`** | **`1,599.77 ns`** | **5.97x–6.11x faster** |

**Why Batched `100 × 100` Concurrent Suspensions Are 6x Faster With `--wasm-stack-switching-stack-size=4`**:
V8's per-isolate `StackPool` has a hard capacity limit of `4 MiB` (`4,194,304 B`). With `984 KB` stacks, only **4 stacks** fit in the pool—so every batch of 100 concurrent calls triggers **96 OS page commit/decommit cycles** and TLB shootdowns. With `4 KB` initial stacks (`44 KiB` with `kJSLimitOffsetKB`), **93 stacks** (`4,092 KiB`) fit inside V8's `4 MiB` `StackPool`, eliminating ~93% of kernel memory-mapping churn.

---

## 5. `--experimental-wasm-wasmfx` (Typed Continuations) & `wasmtime -W stack-switching=y`

### V8 13.6 (`--experimental-wasm-wasmfx`) vs Wasmtime `50.0.1` Support Matrix

| Feature / Opcode | Wire Encoding | Without `--experimental-wasm-wasmfx` | With `--experimental-wasm-wasmfx` (V8 `13.6.233.17`) | Wasmtime `50.0.1` (`x86_64` AOT, `-W stack-switching=y`) |
| :--- | :--- | :--- | :--- | :--- |
| **Abstract `contref` / `nullcontref`** | `0x68` / `0x75` | `CompileError: invalid value type 'cont'` | **Validates, compiles, instantiates & runs (`ret = 1`)** | Compiles (`x86_64` AOT) |
| **Concrete `(type $ct (cont $ft))`** | `0x5d <type_idx>` | `CompileError: core stack switching not enabled` | **Validates (`true`) & compiles (`WebAssembly.Module`)**; traps in `CreateMapForType` on instantiate | Compiles (`x86_64` AOT) |
| **Recursive `sub (cont $ft)`** | `0x4e` / `0x50 0x5d` | `CompileError: core stack switching not enabled` | **Validates (`true`) & compiles (`WebAssembly.Module`)** | Compiles (`x86_64` AOT) |
| **`cont.new $ct`** | `0xe0 <ct_idx>` | `Invalid opcode 0xe0` | `CompileError: Invalid opcode 0xe0` (decoder not wired yet) | **Compiles (`14,072 B` `.cwasm`)** |
| **`cont.bind $src $dst`** | `0xe1 <s_idx> <d_idx>` | `Invalid opcode 0xe1` | `CompileError: Invalid opcode 0xe1` | **Compiles (`13,960 B` `.cwasm`)** |
| **`suspend $tag`** | `0xe2 <tag_idx>` | `Invalid opcode 0xe2` | `CompileError: Invalid opcode 0xe2` | **Compiles (`14,024 B` `.cwasm`)** |
| **`resume $ct (on ...)`** | `0xe3 <ct_idx> <vec>` | `Invalid opcode 0xe3` | `CompileError: Invalid opcode 0xe3` | **Compiles (`14,016 B` `.cwasm`)** |
| **`resume_throw $ct $tag`** | `0xe4 <ct_idx> <tag>` | `Invalid opcode 0xe4` | `CompileError: Invalid opcode 0xe4` | **Compiles (`14,200 B` `.cwasm`)** |
| **`resume_throw_ref $ct`** | `0xe5 <ct_idx> <vec>` | `Invalid opcode 0xe5` | `CompileError: Invalid opcode 0xe5` | **Compiles (`14,080 B` `.cwasm`)** |
| **`switch $ct $tag`** | `0xe6 <ct_idx> <tag>` | `Invalid opcode 0xe6` | `CompileError: Invalid opcode 0xe6` | **Compiles (`14,024 B` `.cwasm`)** |

- **Wasmtime `50.0.1` Target Support**: `wasmtime compile --target x86_64-unknown-linux-gnu -W stack-switching=y -W exceptions=y -W function-references=y` compiles all 7 WasmFX instructions (`0xe0..0xe6`) into a `19,184 B` ELF64 `.cwasm` artifact in `8.81 ms`, lowering `switch`/`resume`/`suspend` into zero-syscall inline register swaps (`%rsp`, `%rbp`, `%rip`). On `aarch64-unknown-linux-gnu`, Wasmtime `50.0.1` returns `Error: the wasm_stack_switching feature is not supported on this compiler configuration`.

```asm
movq    (%rcx), %rax        ; load target continuation %rsp
movq    %rsp, (%rcx)        ; save current %rsp into active continuation control block
movq    %rax, %rsp          ; switch hardware stack pointer!
movq    8(%rcx), %rax       ; load target %rbp
movq    %rbp, 8(%rcx)       ; save current %rbp
movq    %rax, %rbp          ; switch frame pointer!
movq    0x10(%rcx), %rax    ; load target resumption %rip
leaq    6(%rip), %rdx       ; compute return address
movq    %rdx, 0x10(%rcx)    ; save return %rip
jmpq    *%rax               ; jump directly into target continuation!
```

---

## 6. Dual-Stack (`__stack_pointer` / `global[0]`) Context Switching & `zigar-runtime` Integration

### Why Host Stack Switching Alone Corrupts Linear Shadow Stacks
Zig, C, and Rust compile to WebAssembly using a **dual-stack ABI**:
1. **The Wasm Engine Stack** (SSA locals, control-flow labels, call return addresses) — switched automatically by V8 JSPI (`WebAssembly.Suspending` / `WebAssembly.promising`) or WasmFX (`resume` / `suspend` / `switch`).
2. **The Linear Memory Shadow Stack (`global[0]` / `__stack_pointer`)** — used for local structs, arrays, and address-taken variables (`&local_var`). Neither JSPI nor WasmFX switches `global[0]`!

When `50` concurrent `wazig`-compiled Zig fibers (`depth = 20`, `1,000` total suspensions, each holding a `64 B` `[16]u32` stack frame on `__stack_pointer`) suspend and resolve out of order:

| Mode (`wazig 0.17.0-wazig.4` `ReleaseSmall`, 50 Fibers × Depth 20) | Valid Fibers | Corrupted Fibers | Corruption Rate | Unique Frame Addresses (`expected = 1000`) | Colliding Frame Addresses | Warmed Throughput (`20k` Switches) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **Shared `__stack_pointer` (Standard JSPI)** | `9 / 50` | **`41 / 50`** | **82.0%** | `808 / 1000` | **`56` collisions** (up to 4 fibers overwriting the same address) | `1,461 ns/switch` |
| **Per-Continuation `__stack_pointer` Switched** | **`50 / 50`** | **`0 / 50`** | **0.0%** | **`1000 / 1000`** | **`0` collisions** | `1,611 ns/switch` (`+150 ns/switch` e2e; `38.96 ns` raw `global[0]` save+restore) |

### Architectural Split: `zigar-runtime` vs `wazig` / `wazigl` Compilers
1. **JSPI + `--experimental-wasm-growable-stacks` → `zigar-runtime` + `zigar-compiler` + `wazig` / `wazigl`**:
   - Both `wazig` (`v0.17.0-wazig.4`, via `src/link/Wasm.zig`) and `wazigl` (`v0.17.0-wazigl.4`, via `--export-if-defined=__stack_pointer` in `src/link/Lld.zig`) now export `__stack_pointer` (`global[0]`) natively by default on reactor modules. `zigar-compiler` (`stripUnused()` and `ensureStackPointerExport()` in `zigar-compiler/src/wasm-decoding.js`, called from `transpile()` in both stripped and `Debug` modes) also ensures `__stack_pointer` (`global[0]`) is exported when compiling with stock `zig`.
   - `zigar-runtime` (`module-loading.js`, `call-marshaling-outbound.js`, `call-marshaling-inbound.js`) supports `{ useJSPI: true, continuationStackSize }`:
     - Wraps `_handleJscall` and WASI syscalls in `new WebAssembly.Suspending(...)` and `runThunk` / `runVariadicThunk` in `WebAssembly.promising(...)` (note: under `useJSPI: true`, outbound Zig calls return Promises, while async generators return `AsyncGenerator` directly).
     - Allocates and pools 16-byte-aligned linear shadow stacks via `allocateScratchMemory` (`continuationStackPool`, with `0xdeadbeef` stack-bottom canary checks), saving `exports.__stack_pointer.value` upon entering `wrapSuspending` and restoring it in the `.then(...)` handler before returning to V8's `WebAssembly.Suspending` resumption path.
2. **WasmFX (`--experimental-wasm-wasmfx`) → `wazig` Compiler (`std.Io`)**:
   - In-Wasm fiber switching (`cont.new`, `suspend`, `resume`, `switch`) for `wasm32-wasip3` `std.Io` does not cross the JS host boundary and belongs in `wazig`'s `std.Io` scheduler, which must swap `global[0]` (`__stack_pointer`) alongside `resume`/`switch`.

---

## 7. Real Ecosystem `.wasm` Binary Verification (`wazig`, `zigar`, `jsco` / `jco`)

All tested binaries validate, compile, instantiate, and execute with V8's `--experimental-wasm-growable-stacks --wasm-stack-switching-stack-size=4` with **zero special compiler flags**:

| Ecosystem | Binary | Format | Size (`B`) | Core Modules | `global[0]` (`__stack_pointer`) | Exported `__stack_pointer` | V8 Growable Stacks Execution (`4 KB` initial stack) |
| :--- | :--- | :--- | ---: | ---: | :--- | :--- | :--- |
| **`wazig` `0.17.0-wazig.4`** | `stack_bench.wasm` | `core-module` | `1,676` | `1` | `mut i32 = 262144` | `true` (default in `wazig` & `wazigl`) | **PASS** (`depth = 2000`, async WASI `fd_read`/`fd_write`, stack restored) |
| **`zigar`** | `simple.wasm` | `core-module` | `45,955` | `1` | `mut i32 = 262144` | `true` | **PASS** (`allocateScratchMemory` = `327680` + JSPI `_initialize`) |
| **`zigar`** | `read-file.wasm` | `core-module` | `56,393` | `1` | `mut i32 = 262144` | `true` | **PASS** (`allocateScratchMemory` = `327680` + JSPI `_initialize`) |
| **`zigar`** | `thread.wasm` | `core-module` | `82,735` | `1` | `mut i32 = 262144` | `true` | **PASS** (`allocateScratchMemory` = `16777216` + JSPI `_initialize`) |
| **`jsco` (WASI P1)** | `file-io.wasm` | `core-module` | `767` | `1` | None (hand-written WAT) | `false` | **PASS** (`_start`, `9` JSPI suspensions) |
| **`jsco` (WASI P3)** | `echo-async-p3.wasm` | `component-model` | `1,009` | `2` | `mut i32 = 1024` | `false` | **PASS** (core module `#1`, `cabi_realloc` = `1024`, `echo`) |
| **`jsco` (WASI P3)** | `jspi_deadlock_repro.wasm` | `component-model` | `104,835` | `4` | `mut i32 = 1048576` | `false` | **PASS** (`cabi_realloc` = `1056464`, `[async-lift]...#run-repro`, `7` suspensions) |
| **`jsco / jco` (WASI P3)** | `p3_filesystem_file_read_write.component.wasm` | `component-model` | `7,952,911` | `4` | `mut i32 = 1048576` | `false` | **PASS** (`cabi_realloc` = `1077552`, `[async-lift]wasi:cli/run#run`, `7` suspensions) |
| **`jsco / jco` (WASI P3)** | `p3_http_echo.component.wasm` | `component-model` | `7,777,461` | `4` | `mut i32 = 1048576` | `false` | **PASS** (`cabi_realloc` = `1074256`, `[async-lift]wasi:http/handler#handle`, `7` suspensions) |

