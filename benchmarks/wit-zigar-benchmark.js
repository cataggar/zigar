#!/usr/bin/env node
/**
 * wit-zigar & zigar ABI Performance Benchmark Suite (Issue #8 / #15 / #18 / #19)
 *
 * Benchmarks the core thesis of Issue #8 Section 2 & Section 3 on real
 * `wazig 0.17.0-wazig.6` `ReleaseFast` WebAssembly binaries running in V8 (Node.js):
 *
 *   Part 1 — In-Wasm Component Model Canonical ABI vs `wit-zigar` `"zigar:abi"` Zero-Copy Fast Path
 *     1. `transform-rect` (blittable `Rect` + `f32` -> `Rect`):
 *        - Canonical ABI (`CanonLower` + `CanonLift` + indirect return area)
 *        - `wit-zigar` `"zigar:abi"` (`FastLower` + `FastLift`, single contiguous `ArgStruct` frame)
 *        - `ZigarBridge.call("transform_rect")` auto-dispatch
 *     2. `inspect-record` (17-field `ComplexRecord` with `string`, `list<point>`, `list<string>`,
 *        `option`, `result`, `variant`, `flags8..70` -> `result<string, error-kind>`):
 *        - Canonical ABI (`CanonLower` + `CanonLift`: 17+ flat params spill, 5 `cabi_realloc`
 *          allocations per call, UTF-8 scan, `cabi_post` cleanup)
 *        - `wit-zigar` `"zigar:abi"` (`FastLower` + `FastLift` + zero-copy in-place slices in
 *          `BridgeMemory`: 0 `cabi_realloc` calls, 0 `cabi_post` calls)
 *     3. WASI 0.3 Stackful Async Subtask + `WaitableSet` + `ShadowStackPool` (`async-five` & `async-compute`):
 *        - Full `AsyncScheduler` subtask lifecycle with 16-byte-aligned shadow stack switching
 *
 *   Part 2 — JS <-> Wasm Host Boundary (`zigar-compiler` + `zigar-runtime` on `service.zig`, `ReleaseFast`)
 *     1. Synchronous `useJSPI: false` vs `WebAssembly.promising` `useJSPI: true` call latency
 *        (`transformRect`, `fastAbiRoundTrip`, `scaleRects` slice marshaling, `canonAbiAsyncSubtask`)
 *     2. Concurrent JSPI `Promise.all` throughput across 16 isolated continuation shadow stacks
 */

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, '..');
const DEFAULT_BASE_CACHE =
  process.env.WAZIG_BENCH_BASE_CACHE ||
  (existsSync('/d/zigar-worktrees') ? '/d/zigar-worktrees/.cache' : path.join(ROOT_DIR, '.tmp-bench'));
const CACHE_ROOT = process.env.CACHE_ROOT || DEFAULT_BASE_CACHE;
const TMP_ROOT = path.join(CACHE_ROOT, 'tmp-wit-zigar-bench');
const ZIG_GLOBAL_CACHE = process.env.ZIG_GLOBAL_CACHE_DIR || path.join(CACHE_ROOT, 'zig-global');
const ZIG_LOCAL_CACHE = path.join(CACHE_ROOT, 'wit-zigar-bench-local');
const RUNTIME_DIST_DIR = path.join(ROOT_DIR, 'zigar-runtime', 'dist');
const WIT_ZIGAR_DIR = path.join(ROOT_DIR, 'wit-zigar');
const SERVICE_ZIG_PATH = path.join(ROOT_DIR, 'zigar-compiler', 'test', 'zig-samples', 'wit-zigar', 'service.zig');

for (const dir of [ CACHE_ROOT, TMP_ROOT, ZIG_GLOBAL_CACHE, ZIG_LOCAL_CACHE ]) {
  mkdirSync(dir, { recursive: true });
}
process.env.ZIG_GLOBAL_CACHE_DIR = ZIG_GLOBAL_CACHE;
process.env.ZIG_LOCAL_CACHE_DIR = ZIG_LOCAL_CACHE;
process.env.TMPDIR = TMP_ROOT;
process.env.TARGET = 'wasm';
process.env.BITS = '32';
process.env.MIXIN = 'track';

const { transpile } = await import('../zigar-compiler/src/transpilation.js');

const LOCAL_BIN_DIR = path.join(os.homedir(), '.local', 'bin');
if (existsSync(LOCAL_BIN_DIR) && !(process.env.PATH || '').split(':').includes(LOCAL_BIN_DIR)) {
  process.env.PATH = `${LOCAL_BIN_DIR}:${process.env.PATH || ''}`;
}
const WAZIG_BIN = existsSync(path.join(LOCAL_BIN_DIR, 'wazig'))
  ? path.join(LOCAL_BIN_DIR, 'wazig')
  : (existsSync('/d/zig/wazig/bin/wazig') ? '/d/zig/wazig/bin/wazig' : 'wazig');

function median(values) {
  const sorted = [ ...values ].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function benchSync(fn, iterations, warmup = Math.min(2000, Math.max(100, Math.floor(iterations / 10))), runs = 7) {
  for (let i = 0; i < warmup; i++) fn();
  const samplesNs = [];
  for (let r = 0; r < runs; r++) {
    const t0 = performance.now();
    for (let i = 0; i < iterations; i++) fn();
    const elapsedMs = performance.now() - t0;
    samplesNs.push((elapsedMs * 1e6) / iterations);
  }
  const medNs = median(samplesNs);
  const minNs = Math.min(...samplesNs);
  return {
    iterations,
    medianNsPerOp: Number(medNs.toFixed(1)),
    minNsPerOp: Number(minNs.toFixed(1)),
    opsPerSec: Math.round(1e9 / medNs),
  };
}

async function benchAsync(fn, iterations, warmup = Math.min(500, Math.max(50, Math.floor(iterations / 10))), runs = 7) {
  for (let i = 0; i < warmup; i++) await fn();
  const samplesNs = [];
  for (let r = 0; r < runs; r++) {
    const t0 = performance.now();
    for (let i = 0; i < iterations; i++) await fn();
    const elapsedMs = performance.now() - t0;
    samplesNs.push((elapsedMs * 1e6) / iterations);
  }
  const medNs = median(samplesNs);
  const minNs = Math.min(...samplesNs);
  return {
    iterations,
    medianNsPerOp: Number(medNs.toFixed(1)),
    minNsPerOp: Number(minNs.toFixed(1)),
    opsPerSec: Math.round(1e9 / medNs),
  };
}

function buildInWasmAbiHarness() {
  const genZigPath = path.join(TMP_ROOT, 'generated_sample.zig');
  // Generate bindings for wit-zigar/test/fixtures/sample.wit using zigar wit CLI
  execFileSync(
    'zig',
    [
      'run',
      path.join(WIT_ZIGAR_DIR, 'src', 'main.zig'),
      '--cache-dir',
      ZIG_LOCAL_CACHE,
      '--',
      path.join(WIT_ZIGAR_DIR, 'test', 'fixtures', 'sample.wit'),
      '-o',
      genZigPath,
    ],
    {
      cwd: WIT_ZIGAR_DIR,
      env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: ZIG_GLOBAL_CACHE, ZIG_LOCAL_CACHE_DIR: ZIG_LOCAL_CACHE },
      stdio: 'pipe',
    },
  );

  const harnessPath = path.join(TMP_ROOT, 'wit_zigar_wasm_bench.zig');
  const wasmPath = path.join(TMP_ROOT, 'wit_zigar_wasm_bench.wasm');

  const harnessSource = `
const std = @import("std");
const wit_zigar = @import("wit_zigar");
const sample = @import("generated_sample");

const canon = wit_zigar.canon;
const fast_abi = wit_zigar.fast_abi;
const async_rt = wit_zigar.async_runtime;
const bridge = wit_zigar.zigar_bridge;

const ST = sample.shared_types;
const GuestService = sample.guest_service;
const HostApi = sample.host_api;

const SampleImpl = struct {
    pub fn spill_seventeen(
        a1: u32, a2: u32, a3: u32, a4: u32,
        a5: u32, a6: u32, a7: u32, a8: u32,
        a9: u32, a10: u32, a11: u32, a12: u32,
        a13: u32, a14: u32, a15: u32, a16: u32,
        a17: u32,
    ) u32 {
        return a1 +% a2 +% a3 +% a4 +% a5 +% a6 +% a7 +% a8 +%
            a9 +% a10 +% a11 +% a12 +% a13 +% a14 +% a15 +% a16 +% a17;
    }

    pub fn transform_rect(r: ST.Rect, scale: f32) ST.Rect {
        return .{
            .origin = .{ .x = r.origin.x * scale, .y = r.origin.y * scale },
            .extent = .{ .x = r.extent.x * scale, .y = r.extent.y * scale },
            .id = r.id + 1,
            .layer = r.layer,
            .tag = r.tag,
        };
    }

    pub fn inspect_record(rec: ST.ComplexRecord) sample.Result([]const u8, ST.ErrorKind) {
        if (rec.points.len == 0) return .{ .err = .invalid_input };
        return .{ .ok = rec.label };
    }

    pub fn async_compute(a: u32, b: u32, c: u32, d: u32, e: u32) sample.Result(ST.Point, ST.ErrorKind) {
        return .{
            .ok = .{
                .x = @floatFromInt(a + b + c),
                .y = @floatFromInt(d + e),
            },
        };
    }
};

var bench_mem: [65536]u8 align(16) = @splat(0);
var realloc_calls: u32 = 0;
var post_return_calls: u32 = 0;
var sink_u64: u64 = 0;

fn countPostReturn(_: ?*anyopaque, _: usize) void {
    post_return_calls += 1;
}

const WasmHeapRealloc = struct {
    const Entry = struct {
        ptr: [*]u8,
        len: usize,
        alignment: std.mem.Alignment,
    };
    entries: [32]Entry = undefined,
    count: usize = 0,

    fn realloc(raw_ctx: ?*anyopaque, orig_ptr: usize, orig_size: usize, alignment: usize, new_size: usize) canon.Error!usize {
        _ = orig_ptr;
        _ = orig_size;
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        realloc_calls += 1;
        if (new_size == 0) return alignBackward(usize, 16, @max(alignment, 1));
        const align_enum = std.mem.Alignment.fromByteUnits(@max(alignment, 1));
        const raw = std.heap.wasm_allocator.rawAlloc(new_size, align_enum, @returnAddress()) orelse return error.OutOfMemory;
        self.entries[self.count] = .{ .ptr = raw, .len = new_size, .alignment = align_enum };
        self.count += 1;
        return @intFromPtr(raw);
    }

    fn alignBackward(comptime T: type, addr: T, alignment: T) T {
        return addr & ~(alignment - 1);
    }

    fn freeAll(self: *@This()) void {
        for (self.entries[0..self.count]) |e| {
            std.heap.wasm_allocator.rawFree(e.ptr[0..e.len], e.alignment, @returnAddress());
        }
        self.count = 0;
    }

    fn warmUp(self: *@This()) void {
        const sizes = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384 };
        for (sizes) |sz| {
            _ = realloc(self, 0, 0, 8, sz) catch unreachable;
        }
        self.freeAll();
        realloc_calls = 0;
    }

    fn memorySlice() []u8 {
        return @as([*]u8, @ptrFromInt(1))[0 .. 128 * 1024 * 1024];
    }
};

export fn get_realloc_calls() u32 {
    return realloc_calls;
}

export fn get_post_return_calls() u32 {
    return post_return_calls;
}

export fn get_sink() u32 {
    return @truncate(sink_u64);
}

export fn bench_spill17_canon(iterations: u32) u32 {
    realloc_calls = 0;
    post_return_calls = 0;
    var heap_realloc = WasmHeapRealloc{};
    heap_realloc.warmUp();

    const ctx = canon.MemoryContext{
        .memory = WasmHeapRealloc.memorySlice(),
        .base_addr = 1,
        .realloc_ctx = &heap_realloc,
        .realloc_fn = &WasmHeapRealloc.realloc,
        .post_return_fn = &countPostReturn,
        .allocator = std.heap.wasm_allocator,
        .zero_copy_slices = false,
    };
    canon.setActiveMemoryContext(ctx);
    const FnT = HostApi.spill_seventeen_Fn;
    const thunk = canon.CanonLift(FnT, .{}).thunk(&SampleImpl.spill_seventeen);
    var acc: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        acc +%= canon.CanonLower(FnT, .{}).call(ctx, thunk, .{
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, i + 17,
        }) catch unreachable;
        heap_realloc.freeAll();
    }
    sink_u64 +%= acc;
    return acc;
}

export fn bench_spill17_fast(iterations: u32) u32 {
    realloc_calls = 0;
    post_return_calls = 0;
    var ctx = canon.MemoryContext{
        .memory = &bench_mem,
        .fast_frame_offset = 64,
        .fast_scratch_limit = bench_mem.len,
    };
    const FnT = HostApi.spill_seventeen_Fn;
    const Lower = fast_abi.FastLower(FnT, false);
    const Lift = fast_abi.FastLift(FnT, SampleImpl.spill_seventeen, false);
    const frame_off = Lower.resolveFrameOffset(&ctx, .{
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
    }) catch unreachable;
    var acc: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        acc +%= Lower.callAtOffset(&ctx, frame_off, Lift.thunk(), .{
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, i + 17,
        }) catch unreachable;
    }
    sink_u64 +%= acc;
    return acc;
}

export fn bench_transform_rect_canon(iterations: u32) u32 {
    realloc_calls = 0;
    post_return_calls = 0;
    var heap_realloc = WasmHeapRealloc{};
    heap_realloc.warmUp();

    const ctx = canon.MemoryContext{
        .memory = WasmHeapRealloc.memorySlice(),
        .base_addr = 1,
        .realloc_ctx = &heap_realloc,
        .realloc_fn = &WasmHeapRealloc.realloc,
        .post_return_fn = &countPostReturn,
        .allocator = std.heap.wasm_allocator,
        .zero_copy_slices = false,
    };
    canon.setActiveMemoryContext(ctx);
    const FnT = GuestService.transform_rect_Fn;
    const thunk = canon.CanonLift(FnT, .{}).thunk(&SampleImpl.transform_rect);
    var r = ST.Rect{
        .origin = .{ .x = 1.25, .y = 2.5 },
        .extent = .{ .x = 10.0, .y = 20.0 },
        .id = 1,
        .layer = 2,
        .tag = 42,
    };
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        r = canon.CanonLower(FnT, .{}).call(ctx, thunk, .{ r, 1.00001 }) catch unreachable;
        heap_realloc.freeAll();
    }
    sink_u64 +%= r.id;
    return r.id;
}

export fn bench_transform_rect_fast(iterations: u32) u32 {
    realloc_calls = 0;
    post_return_calls = 0;
    var ctx = canon.MemoryContext{
        .memory = &bench_mem,
        .fast_frame_offset = 64,
        .fast_scratch_limit = bench_mem.len,
    };
    const FnT = GuestService.transform_rect_Fn;
    const Lower = fast_abi.FastLower(FnT, false);
    const Lift = fast_abi.FastLift(FnT, SampleImpl.transform_rect, false);
    const frame_off = Lower.resolveFrameOffset(&ctx, .{
        ST.Rect{
            .origin = .{ .x = 1.25, .y = 2.5 },
            .extent = .{ .x = 10.0, .y = 20.0 },
            .id = 1,
            .layer = 2,
            .tag = 42,
        },
        @as(f32, 1.00001),
    }) catch unreachable;
    var r = ST.Rect{
        .origin = .{ .x = 1.25, .y = 2.5 },
        .extent = .{ .x = 10.0, .y = 20.0 },
        .id = 1,
        .layer = 2,
        .tag = 42,
    };
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        r = Lower.callAtOffset(&ctx, frame_off, Lift.thunk(), .{ r, 1.00001 }) catch unreachable;
    }
    sink_u64 +%= r.id;
    return r.id;
}

export fn bench_inspect_record_canon(iterations: u32) u32 {
    realloc_calls = 0;
    post_return_calls = 0;
    var heap_realloc = WasmHeapRealloc{};
    heap_realloc.warmUp();

    const ctx = canon.MemoryContext{
        .memory = WasmHeapRealloc.memorySlice(),
        .base_addr = 1,
        .realloc_ctx = &heap_realloc,
        .realloc_fn = &WasmHeapRealloc.realloc,
        .post_return_fn = &countPostReturn,
        .allocator = std.heap.wasm_allocator,
        .zero_copy_slices = false,
    };
    canon.setActiveMemoryContext(ctx);
    const FnT = GuestService.inspect_record_Fn;
    const thunk = canon.CanonLift(FnT, .{}).thunk(&SampleImpl.inspect_record);
    const pts = [_]ST.Point{
        .{ .x = 1.0, .y = 2.0 },
        .{ .x = 3.0, .y = 4.0 },
        .{ .x = 5.0, .y = 6.0 },
        .{ .x = 7.0, .y = 8.0 },
    };
    const tags = [_][]const u8{ "alpha", "beta", "gamma" };
    const rec = ST.ComplexRecord{
        .id = 777,
        .label = "zero-copy-wit-zigar-benchmark-payload",
        .points = &pts,
        .tags = &tags,
        .maybe_score = 9001,
        .maybe_note = "note-payload",
        .outcome = .{ .ok = .{ .x = 4.0, .y = 8.0 } },
        .tint = .blue,
        .glyph = 'Z',
        .f8 = .{ .b0 = true, .b3 = true },
        .f16 = .{ .f1 = true, .f9 = true },
        .f32_val = .{ .k0 = true, .k15 = true },
        .f64_val = ST.Flags64.fromPacked(.{ .m0 = true, .m20 = true }),
        .f70 = .{},
        .v_if = .{ .as_float = 3.14159 },
        .v_ii = .{ .as_int64 = -123456789 },
        .v_ff = .{ .as_f32 = -42.5 },
        .v_multi = .{ .second = .{ .x = -77, .y = 99 } },
    };
    var total_len: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const res = canon.CanonLower(FnT, .{}).call(ctx, thunk, .{rec}) catch unreachable;
        total_len +%= @intCast(res.ok.len);
        std.heap.wasm_allocator.free(res.ok);
        heap_realloc.freeAll();
    }
    sink_u64 +%= total_len;
    return total_len;
}

export fn bench_inspect_record_fast(iterations: u32) u32 {
    realloc_calls = 0;
    post_return_calls = 0;
    const GuestBridge = bridge.ZigarBridge(GuestService, SampleImpl, .{
        .unwrap_results = false,
        .scratch_capacity = 32768,
        .prefer_fast_abi = true,
    });
    var inst = GuestBridge.init(std.heap.wasm_allocator);
    const pts = [_]ST.Point{
        .{ .x = 1.0, .y = 2.0 },
        .{ .x = 3.0, .y = 4.0 },
        .{ .x = 5.0, .y = 6.0 },
        .{ .x = 7.0, .y = 8.0 },
    };
    const zero_copy_pts = inst.bridge_memory.copySliceInPlace(ST.Point, &pts) catch unreachable;
    const zero_copy_label = inst.bridge_memory.copySliceInPlace(u8, "zero-copy-wit-zigar-benchmark-payload") catch unreachable;
    const zero_copy_note = inst.bridge_memory.copySliceInPlace(u8, "note-payload") catch unreachable;
    const tag0 = inst.bridge_memory.copySliceInPlace(u8, "alpha") catch unreachable;
    const tag1 = inst.bridge_memory.copySliceInPlace(u8, "beta") catch unreachable;
    const tag2 = inst.bridge_memory.copySliceInPlace(u8, "gamma") catch unreachable;
    const tags = [_][]const u8{ tag0, tag1, tag2 };
    const rec = ST.ComplexRecord{
        .id = 777,
        .label = zero_copy_label,
        .points = zero_copy_pts,
        .tags = &tags,
        .maybe_score = 9001,
        .maybe_note = zero_copy_note,
        .outcome = .{ .ok = .{ .x = 4.0, .y = 8.0 } },
        .tint = .blue,
        .glyph = 'Z',
        .f8 = .{ .b0 = true, .b3 = true },
        .f16 = .{ .f1 = true, .f9 = true },
        .f32_val = .{ .k0 = true, .k15 = true },
        .f64_val = ST.Flags64.fromPacked(.{ .m0 = true, .m20 = true }),
        .f70 = .{},
        .v_if = .{ .as_float = 3.14159 },
        .v_ii = .{ .as_int64 = -123456789 },
        .v_ff = .{ .as_f32 = -42.5 },
        .v_multi = .{ .second = .{ .x = -77, .y = 99 } },
    };
    var f_ctx = inst.memoryContext();
    const FnT = GuestService.inspect_record_Fn;
    const Lower = fast_abi.FastLower(FnT, false);
    const Lift = fast_abi.FastLift(FnT, SampleImpl.inspect_record, false);
    const frame_off = Lower.resolveFrameOffset(&f_ctx, .{rec}) catch unreachable;
    var total_len: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const res = Lower.callAtOffset(&f_ctx, frame_off, Lift.thunk(), .{rec}) catch unreachable;
        total_len +%= @intCast(res.ok.len);
    }
    sink_u64 +%= total_len;
    return total_len;
}

export fn bench_wasi_p3_async_subtask(iterations: u32) u32 {
    var sched = async_rt.AsyncScheduler.init(std.heap.wasm_allocator);
    defer sched.deinit();
    var host_sp: usize = 0x0008_0000;
    sched.sp_binding = async_rt.StackPointerBinding.fromHostSlot(&host_sp);

    var bump = canon.BumpAllocator.init(128, bench_mem.len);
    var mem_ctx = bump.memoryContext(&bench_mem);
    mem_ctx.allocator = std.heap.wasm_allocator;
    sched.configureMemoryContext(&mem_ctx);

    const PendingSubtask = struct {
        sched_ptr: *async_rt.AsyncScheduler,
        mem_ctx_ptr: *canon.MemoryContext,
        params_ptr: usize = 0,
        ret_ptr: usize = 0,
        steps: u32 = 0,
        var current: ?*@This() = null;

        fn step(raw_ctx: ?*anyopaque, _: *async_rt.AsyncScheduler, _: i32) !async_rt.SubtaskState {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.steps += 1;
            if (self.steps == 1) return .started;
            const mctx = self.mem_ctx_ptr.*;
            const a = try canon.loadFromMemory(u32, .wasm32, mctx, self.params_ptr + 0);
            const b = try canon.loadFromMemory(u32, .wasm32, mctx, self.params_ptr + 4);
            try canon.storeToMemory(u64, .wasm32, mctx, self.ret_ptr, @as(u64, a) + b);
            return .returned;
        }

        fn coreFn(params_ptr: i32, ret_ptr: i32) i32 {
            const self = current.?;
            self.params_ptr = @intCast(@as(u32, @bitCast(params_ptr)));
            self.ret_ptr = @intCast(@as(u32, @bitCast(ret_ptr)));
            self.steps = 0;
            const h = self.sched_ptr.spawnAsyncSubtask(self, step) catch unreachable;
            return async_rt.SubtaskState.started.pack(@intCast(h));
        }
    };

    var env = PendingSubtask{ .sched_ptr = &sched, .mem_ctx_ptr = &mem_ctx };
    PendingSubtask.current = &env;
    defer PendingSubtask.current = null;

    const stack = sched.stack_pool.acquire(std.heap.wasm_allocator) catch unreachable;
    defer sched.stack_pool.release(std.heap.wasm_allocator, stack) catch {};
    var task_ctx = async_rt.TaskContext.init(stack, sched.sp_binding);
    sched.active_task = &task_ctx;
    defer sched.active_task = null;

    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        bump.offset = 128;
        task_ctx.enter();
        const v = canon.CanonLower(HostApi.async_five_Fn, .{
            .arch = .wasm32,
            .is_async = true,
        }).call(mem_ctx, &PendingSubtask.coreFn, .{ i, 10, 20, 30, 40 }) catch unreachable;
        acc +%= v;
        task_ctx.complete() catch unreachable;
    }
    sink_u64 +%= acc;
    return @truncate(acc);
}
`;
  writeFileSync(harnessPath, harnessSource, 'utf8');

  const localWitZigarSrc = path.join(TMP_ROOT, 'wit-zigar-src');
  cpSync(path.join(WIT_ZIGAR_DIR, 'src'), localWitZigarSrc, { recursive: true, force: true });
  const wazigCacheDir = path.join(TMP_ROOT, '.zig-cache');
  mkdirSync(wazigCacheDir, { recursive: true });

  const t0 = performance.now();
  execFileSync(
    WAZIG_BIN,
    [
      'build-exe',
      '-fno-llvm',
      '-target',
      'wasm32-wasi',
      '-O',
      'ReleaseFast',
      '-fno-entry',
      '-rdynamic',
      '--dep',
      'wit_zigar',
      '--dep',
      'generated_sample',
      '-Mroot=wit_zigar_wasm_bench.zig',
      '-Mwit_zigar=wit-zigar-src/root.zig',
      '-Mgenerated_sample=generated_sample.zig',
      '-femit-bin=wit_zigar_wasm_bench.wasm',
    ],
    {
      cwd: TMP_ROOT,
      env: {
        ...process.env,
        ZIG_GLOBAL_CACHE_DIR: '.zig-cache',
        ZIG_LOCAL_CACHE_DIR: '.zig-cache',
        ZIG_LIB_DIR: '/lib',
      },
      stdio: 'pipe',
    },
  );
  const compileMs = performance.now() - t0;
  const wasmBytes = readFileSync(wasmPath);
  return { wasmBytes, compileMs: Math.round(compileMs) };
}

async function transpileServiceModule({ useJSPI, tag }) {
  const buildDir = path.join(TMP_ROOT, `service-build-${tag}`);
  mkdirSync(buildDir, { recursive: true });
  const t0 = performance.now();
  const { code } = await transpile(SERVICE_ZIG_PATH, {
    optimize: 'ReleaseFast',
    embedWASM: true,
    stripWASM: true,
    useWazig: true,
    useJSPI,
    continuationStackSize: 8192,
    zigPath: WAZIG_BIN,
    buildDir,
    moduleResolver: () => RUNTIME_DIST_DIR,
  });
  const transpileMs = Math.round(performance.now() - t0);
  const resolvedCode = code
    .replace(
      `from ${JSON.stringify(RUNTIME_DIST_DIR)}`,
      `from ${JSON.stringify(pathToFileURL(path.join(RUNTIME_DIST_DIR, 'index.js')).href)}`,
    );
  const mjsPath = path.join(TMP_ROOT, `service-${tag}-${Date.now()}.mjs`);
  writeFileSync(mjsPath, resolvedCode, 'utf8');
  const mod = await import(pathToFileURL(mjsPath).href);
  return { mod, transpileMs };
}

async function main() {
  const wazigVersion = execFileSync(WAZIG_BIN, [ 'version' ], { encoding: 'utf8' }).trim();
  console.log(`=== wit-zigar & zigar ABI Benchmark Suite (wazig ${wazigVersion}, Node ${process.version}) ===\n`);

  // Part 1: In-Wasm Canonical ABI vs wit-zigar "zigar:abi" Fast Path
  const { wasmBytes, compileMs } = buildInWasmAbiHarness();
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }),
  });
  const exp = instance.exports;

  const ITERS_FAST = 100_000;
  const ITERS_RECORD = 50_000;
  const ITERS_ASYNC = 20_000;

  // Verify single-call realloc & post-return counts
  exp.bench_spill17_canon(1);
  const spill17CanonReallocs = exp.get_realloc_calls();
  const spill17CanonPosts = exp.get_post_return_calls();

  exp.bench_spill17_fast(1);
  const spill17FastReallocs = exp.get_realloc_calls();
  const spill17FastPosts = exp.get_post_return_calls();

  exp.bench_transform_rect_canon(1);
  const transformCanonReallocs = exp.get_realloc_calls();
  const transformCanonPosts = exp.get_post_return_calls();

  exp.bench_transform_rect_fast(1);
  const transformFastReallocs = exp.get_realloc_calls();
  const transformFastPosts = exp.get_post_return_calls();

  exp.bench_inspect_record_canon(1);
  const inspectCanonReallocs = exp.get_realloc_calls();
  const inspectCanonPosts = exp.get_post_return_calls();

  exp.bench_inspect_record_fast(1);
  const inspectFastReallocs = exp.get_realloc_calls();
  const inspectFastPosts = exp.get_post_return_calls();

  const spill17Canon = benchSync(() => exp.bench_spill17_canon(100), 100, 10, 9);
  spill17Canon.medianNsPerOp = Number((spill17Canon.medianNsPerOp / 100).toFixed(2));
  spill17Canon.minNsPerOp = Number((spill17Canon.minNsPerOp / 100).toFixed(2));
  spill17Canon.opsPerSec = Math.round(1e9 / spill17Canon.medianNsPerOp);
  spill17Canon.cabiReallocPerCall = spill17CanonReallocs;
  spill17Canon.cabiPostPerCall = spill17CanonPosts;

  const spill17Fast = benchSync(() => exp.bench_spill17_fast(100), 100, 10, 9);
  spill17Fast.medianNsPerOp = Number((spill17Fast.medianNsPerOp / 100).toFixed(2));
  spill17Fast.minNsPerOp = Number((spill17Fast.minNsPerOp / 100).toFixed(2));
  spill17Fast.opsPerSec = Math.round(1e9 / spill17Fast.medianNsPerOp);
  spill17Fast.cabiReallocPerCall = spill17FastReallocs;
  spill17Fast.cabiPostPerCall = spill17FastPosts;

  const transformCanon = benchSync(() => exp.bench_transform_rect_canon(100), 100, 10, 9);
  transformCanon.medianNsPerOp = Number((transformCanon.medianNsPerOp / 100).toFixed(2));
  transformCanon.minNsPerOp = Number((transformCanon.minNsPerOp / 100).toFixed(2));
  transformCanon.opsPerSec = Math.round(1e9 / transformCanon.medianNsPerOp);
  transformCanon.cabiReallocPerCall = transformCanonReallocs;
  transformCanon.cabiPostPerCall = transformCanonPosts;

  const transformFast = benchSync(() => exp.bench_transform_rect_fast(100), 100, 10, 9);
  transformFast.medianNsPerOp = Number((transformFast.medianNsPerOp / 100).toFixed(2));
  transformFast.minNsPerOp = Number((transformFast.minNsPerOp / 100).toFixed(2));
  transformFast.opsPerSec = Math.round(1e9 / transformFast.medianNsPerOp);
  transformFast.cabiReallocPerCall = transformFastReallocs;
  transformFast.cabiPostPerCall = transformFastPosts;

  const inspectCanon = benchSync(() => exp.bench_inspect_record_canon(50), 100, 10, 9);
  inspectCanon.medianNsPerOp = Number((inspectCanon.medianNsPerOp / 50).toFixed(2));
  inspectCanon.minNsPerOp = Number((inspectCanon.minNsPerOp / 50).toFixed(2));
  inspectCanon.opsPerSec = Math.round(1e9 / inspectCanon.medianNsPerOp);
  inspectCanon.cabiReallocPerCall = inspectCanonReallocs;
  inspectCanon.cabiPostPerCall = inspectCanonPosts;

  const inspectFast = benchSync(() => exp.bench_inspect_record_fast(50), 100, 10, 9);
  inspectFast.medianNsPerOp = Number((inspectFast.medianNsPerOp / 50).toFixed(2));
  inspectFast.minNsPerOp = Number((inspectFast.minNsPerOp / 50).toFixed(2));
  inspectFast.opsPerSec = Math.round(1e9 / inspectFast.medianNsPerOp);
  inspectFast.cabiReallocPerCall = inspectFastReallocs;
  inspectFast.cabiPostPerCall = inspectFastPosts;

  const wasiP3AsyncSubtask = benchSync(() => exp.bench_wasi_p3_async_subtask(50), 100, 10, 9);
  wasiP3AsyncSubtask.medianNsPerOp = Number((wasiP3AsyncSubtask.medianNsPerOp / 50).toFixed(2));
  wasiP3AsyncSubtask.minNsPerOp = Number((wasiP3AsyncSubtask.minNsPerOp / 50).toFixed(2));
  wasiP3AsyncSubtask.opsPerSec = Math.round(1e9 / wasiP3AsyncSubtask.medianNsPerOp);

  const spill17Speedup = Number((spill17Canon.medianNsPerOp / spill17Fast.medianNsPerOp).toFixed(2));
  const transformSpeedup = Number((transformCanon.medianNsPerOp / transformFast.medianNsPerOp).toFixed(2));
  const inspectSpeedup = Number((inspectCanon.medianNsPerOp / inspectFast.medianNsPerOp).toFixed(2));

  console.log(`Part 1: In-Wasm ABI Lower/Lift Microbenchmarks (${wasmBytes.byteLength} B ReleaseFast .wasm, compiled in ${compileMs} ms)`);
  console.log(`  spill-seventeen (17 x u32 -> u32, >16 flat params):`);
  console.log(`    Canonical ABI (CanonLower -> CanonLift): ${spill17Canon.medianNsPerOp} ns/op (${spill17Canon.cabiReallocPerCall} cabi_realloc, ${spill17Canon.cabiPostPerCall} cabi_post)`);
  console.log(`    wit-zigar "zigar:abi" (FastLower -> FastLift): ${spill17Fast.medianNsPerOp} ns/op (${spill17Fast.cabiReallocPerCall} cabi_realloc, ${spill17Fast.cabiPostPerCall} cabi_post) -> ${spill17Speedup}x faster`);
  console.log(`  transform-rect (Rect + f32 -> Rect, <=16 flat params + indirect retptr):`);
  console.log(`    Canonical ABI (CanonLower -> CanonLift): ${transformCanon.medianNsPerOp} ns/op (${transformCanon.cabiReallocPerCall} cabi_realloc, ${transformCanon.cabiPostPerCall} cabi_post)`);
  console.log(`    wit-zigar "zigar:abi" (FastLower -> FastLift): ${transformFast.medianNsPerOp} ns/op (${transformFast.cabiReallocPerCall} cabi_realloc, ${transformFast.cabiPostPerCall} cabi_post) -> ${transformSpeedup}x faster`);
  console.log(`  inspect-record (17-field ComplexRecord -> result<string, error-kind>):`);
  console.log(`    Canonical ABI (CanonLower -> CanonLift): ${inspectCanon.medianNsPerOp} ns/op (${inspectCanon.cabiReallocPerCall} cabi_realloc, ${inspectCanon.cabiPostPerCall} cabi_post)`);
  console.log(`    wit-zigar "zigar:abi" (FastLower -> FastLift zero-copy): ${inspectFast.medianNsPerOp} ns/op (${inspectFast.cabiReallocPerCall} cabi_realloc, ${inspectFast.cabiPostPerCall} cabi_post) -> ${inspectSpeedup}x faster`);
  console.log(`  WASI 0.3 AsyncSubtask + ShadowStackPool + TaskContext switch: ${wasiP3AsyncSubtask.medianNsPerOp} ns/subtask\n`);

  // Part 2: JS <-> Wasm Host Boundary (zigar-compiler + zigar-runtime, useJSPI: false vs useJSPI: true)
  const syncService = await transpileServiceModule({ useJSPI: false, tag: 'sync' });
  const jspiService = await transpileServiceModule({ useJSPI: true, tag: 'jspi' });

  const sampleRect = { origin: { x: 2.5, y: 5.0 }, size: { x: 10.0, y: 20.0 } };
  const sampleRectSlice = Array.from({ length: 16 }, (_, i) => ({
    origin: { x: i * 1.5, y: i * 2.5 },
    size: { x: 10 + i, y: 20 + i },
  }));

  const jsSyncTransformRect = benchSync(
    () => syncService.mod.transformRect(sampleRect, 1.0, 2.0, 1.5),
    10_000,
  );
  const jsSyncFastAbiRoundTrip = benchSync(
    () => syncService.mod.fastAbiRoundTrip(sampleRect, 1.0, 2.0, 1.5),
    10_000,
  );
  const jsSyncSumRectAreas16 = benchSync(
    () => syncService.mod.sumRectAreas(sampleRectSlice),
    5_000,
  );
  const jsSyncCanonAsyncSubtask = benchSync(
    () => syncService.mod.canonAbiAsyncSubtask(100, 200),
    10_000,
  );

  const hasJSPI = typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function';
  let jsJspiTransformRect = null;
  let jsJspiFastAbiRoundTrip = null;
  let jsJspiConcurrent16 = null;

  if (hasJSPI) {
    jsJspiTransformRect = await benchAsync(
      () => jspiService.mod.transformRect(sampleRect, 1.0, 2.0, 1.5),
      5_000,
    );
    jsJspiFastAbiRoundTrip = await benchAsync(
      () => jspiService.mod.fastAbiRoundTrip(sampleRect, 1.0, 2.0, 1.5),
      5_000,
    );
    const immediateHostCb = async (seq) => ((seq & 0xff) << 16) | 10;
    const batch16 = await benchAsync(
      async () => {
        const tasks = [];
        for (let i = 0; i < 16; i++) {
          tasks.push(jspiService.mod.asyncComputeWithHost(sampleRect, 0, immediateHostCb));
        }
        await Promise.all(tasks);
      },
      200,
      20,
      7,
    );
    jsJspiConcurrent16 = {
      batchSize: 16,
      medianNsPerCall: Number((batch16.medianNsPerOp / 16).toFixed(1)),
      minNsPerCall: Number((batch16.minNsPerOp / 16).toFixed(1)),
      callsPerSec: Math.round(1e9 / (batch16.medianNsPerOp / 16)),
    };
  }

  console.log(`Part 2: JS <-> Wasm Host Boundary via zigar-runtime (ReleaseFast):`);
  console.log(`  transformRect (useJSPI: false, sync DataView):   ${jsSyncTransformRect.medianNsPerOp} ns/op (${jsSyncTransformRect.opsPerSec.toLocaleString()} ops/s)`);
  console.log(`  fastAbiRoundTrip (useJSPI: false, sync):         ${jsSyncFastAbiRoundTrip.medianNsPerOp} ns/op (${jsSyncFastAbiRoundTrip.opsPerSec.toLocaleString()} ops/s)`);
  console.log(`  sumRectAreas[16] (useJSPI: false, slice marshal): ${jsSyncSumRectAreas16.medianNsPerOp} ns/op (${jsSyncSumRectAreas16.opsPerSec.toLocaleString()} ops/s)`);
  console.log(`  canonAbiAsyncSubtask (useJSPI: false, sync):     ${jsSyncCanonAsyncSubtask.medianNsPerOp} ns/op (${jsSyncCanonAsyncSubtask.opsPerSec.toLocaleString()} ops/s)`);
  if (hasJSPI) {
    const jspiOverheadRatio = (jsJspiTransformRect.medianNsPerOp / jsSyncTransformRect.medianNsPerOp).toFixed(2);
    console.log(`  transformRect (useJSPI: true, promising+stack):  ${jsJspiTransformRect.medianNsPerOp} ns/op (${jspiOverheadRatio}x vs sync useJSPI: false)`);
    console.log(`  fastAbiRoundTrip (useJSPI: true, promising):     ${jsJspiFastAbiRoundTrip.medianNsPerOp} ns/op`);
    console.log(`  asyncComputeWithHost (16 concurrent JSPI fibers): ${jsJspiConcurrent16.medianNsPerCall} ns/call (${jsJspiConcurrent16.callsPerSec.toLocaleString()} calls/s)`);
  }

  const results = {
    timestamp: new Date().toISOString(),
    wazigVersion,
    nodeVersion: process.version,
    v8Version: process.versions.v8,
    arch: `${os.platform()}-${os.arch()}`,
    inWasmAbi: {
      wasmSizeBytes: wasmBytes.byteLength,
      compileMs,
      spillSeventeen: {
        canonicalAbi: spill17Canon,
        zigarFastAbi: spill17Fast,
        speedupX: spill17Speedup,
      },
      transformRect: {
        canonicalAbi: transformCanon,
        zigarFastAbi: transformFast,
        speedupX: transformSpeedup,
      },
      inspectRecord: {
        canonicalAbi: inspectCanon,
        zigarFastAbi: inspectFast,
        speedupX: inspectSpeedup,
      },
      wasiP3AsyncSubtask,
    },
    jsHostBoundary: {
      syncTranspileMs: syncService.transpileMs,
      jspiTranspileMs: jspiService.transpileMs,
      syncUseJspiFalse: {
        transformRect: jsSyncTransformRect,
        fastAbiRoundTrip: jsSyncFastAbiRoundTrip,
        sumRectAreas16: jsSyncSumRectAreas16,
        canonAbiAsyncSubtask: jsSyncCanonAsyncSubtask,
      },
      jspiUseJspiTrue: hasJSPI
        ? {
            transformRect: jsJspiTransformRect,
            fastAbiRoundTrip: jsJspiFastAbiRoundTrip,
            concurrent16AsyncComputeWithHost: jsJspiConcurrent16,
            promisingVsSyncRatio: Number((jsJspiTransformRect.medianNsPerOp / jsSyncTransformRect.medianNsPerOp).toFixed(2)),
          }
        : null,
    },
  };

  const outJsonPath = path.join(__dirname, 'wit-zigar-results.json');
  writeFileSync(outJsonPath, JSON.stringify(results, null, 2) + '\n', 'utf8');
  console.log(`\nSaved JSON report to ${outJsonPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
