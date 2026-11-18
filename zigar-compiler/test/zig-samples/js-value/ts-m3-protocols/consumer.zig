const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const m = gen.m3_protocols_esm;
const cjs = gen.m3_protocols_cjs;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

var live_allocs = std.atomic.Value(usize).init(0);

const TrackingAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ptr = zigar.mem.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = live_allocs.fetchAdd(1, .acq_rel);
        return ptr;
    }

    fn resize(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return zigar.mem.allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return zigar.mem.allocator.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        zigar.mem.allocator.rawFree(buf, alignment, ret_addr);
        _ = live_allocs.fetchSub(1, .acq_rel);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
};

const tracked_alloc = TrackingAllocator.allocator();

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}

pub fn liveZigAllocs() usize {
    return live_allocs.load(.acquire);
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

fn checkInvariants(handles_before: u32, cbs_before: u32, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (js.activeCallbackCount() != cbs_before) return error.Unexpected;
    if (live_allocs.load(.acquire) != allocs_before) return error.Unexpected;
    if (js.hasLastError()) return error.Unexpected;
}

/// Sync protocols: positional `Iterable<T>`, `Generator<T>` early close,
/// `[Symbol.iterator]` + `[Symbol.dispose]` (`defer r.deinit()` + `tryDispose`),
/// `Symbol.for("nodejs.dispose")`, constrained generics, and CJS sync protocols.
pub fn exerciseSyncProtocols(out_alloc: std.mem.Allocator) ![]u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    try m.resetCounters();

    {
        const sum = try m.sumIterable(&.{ 10, 20, 30, 40 });
        if (sum != 100) return std.fmt.allocPrint(out_alloc, "fail:sumIterable:{d}", .{sum});

        const sum_c = try m.sumConstrained([]const f64, &.{ 1, 2, 3, 4 });
        if (sum_c != 10) return std.fmt.allocPrint(out_alloc, "fail:sumConstrained:{d}", .{sum_c});

        const it = try m.rangeIter(5, 4);
        defer it.deinit();
        var collected: f64 = 0;
        var count: usize = 0;
        while (try it.next()) |v| {
            collected += v;
            count += 1;
        }
        if (count != 4 or collected != 26) return std.fmt.allocPrint(out_alloc, "fail:rangeIter:{d}:{d}", .{ count, collected });

        {
            const gen_it = try m.tokenGen("tok");
            defer gen_it.closeAndDeinit();
            const t0 = (try gen_it.nextAlloc(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:gen_t0_null");
            defer tracked_alloc.free(t0);
            const t1 = (try gen_it.nextAlloc(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:gen_t1_null");
            defer tracked_alloc.free(t1);
            if (!std.mem.eql(u8, t0, "tok:0") or !std.mem.eql(u8, t1, "tok:1")) {
                return std.fmt.allocPrint(out_alloc, "fail:gen_items:{s},{s}", .{ t0, t1 });
            }
        }
        if ((try m.getGenClosedCount()) != 1) return out_alloc.dupe(u8, "fail:gen_close_count");

        // H2: `deinit()` and `js.freeDecoded` MUST release handle slots WITHOUT invoking `[Symbol.dispose]`!
        {
            const peek_cur = try m.TokenCursor.init(&.{"peek-only"}, false);
            peek_cur.deinit();

            const arr_cur = try tracked_alloc.alloc(m.TokenCursor, 1);
            arr_cur[0] = try m.TokenCursor.init(&.{"freed-decoded"}, false);
            js.freeDecoded([]const m.TokenCursor, tracked_alloc, arr_cur);

            const pre_log = try m.getDisposeLogAlloc(tracked_alloc);
            defer js.freeDecoded([]const []const u8, tracked_alloc, pre_log);
            if (pre_log.len != 0) return std.fmt.allocPrint(out_alloc, "fail:deinit_disposed:{d}", .{pre_log.len});
        }

        // TokenCursor: `[Symbol.iterator]` + explicit `[Symbol.dispose]` on `defer cur.dispose()`
        {
            const cur = try m.TokenCursor.init(&.{ "alpha", "beta", "gamma" }, false);
            defer cur.dispose();

            const wd = try m.withDisposableInferAlloc(tracked_alloc, cur, "live");
            defer tracked_alloc.free(wd);
            if (!std.mem.eql(u8, wd, "disposable:live")) return std.fmt.allocPrint(out_alloc, "fail:withDisposable:{s}", .{wd});

            const cit = try cur.iterator();
            defer cit.deinit();
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(tracked_alloc);
            while (try cit.nextAlloc(tracked_alloc)) |s| {
                defer tracked_alloc.free(s);
                if (joined.items.len > 0) try joined.append(tracked_alloc, ',');
                try joined.appendSlice(tracked_alloc, s);
            }
            if (!std.mem.eql(u8, joined.items, "alpha,beta,gamma")) {
                return std.fmt.allocPrint(out_alloc, "fail:cursor_iter:{s}", .{joined.items});
            }
        }

        // Legacy `Symbol.for("nodejs.dispose")`
        {
            const leg = try m.LegacySyncHandle.init("fd42");
            defer leg.dispose();
        }

        const log = try m.getDisposeLogAlloc(tracked_alloc);
        defer js.freeDecoded([]const []const u8, tracked_alloc, log);
        if (log.len != 2 or !std.mem.eql(u8, log[0], "cursor:alpha+beta+gamma") or !std.mem.eql(u8, log[1], "legacy-sync:fd42")) {
            return std.fmt.allocPrint(out_alloc, "fail:dispose_log_len:{d}", .{log.len});
        }

        // Throwing `tryDispose()` consumes & releases the handle while capturing JS error cleanly
        {
            const bad_cur = try m.TokenCursor.init(&.{"err"}, true);
            if (bad_cur.tryDispose()) |_| {
                return out_alloc.dupe(u8, "fail:tryDispose_did_not_fail");
            } else |err| {
                if (err != error.JsException) return std.fmt.allocPrint(out_alloc, "fail:tryDispose_err:{s}", .{@errorName(err)});
                var exc = (try js.tryTakeLastError()) orelse return out_alloc.dupe(u8, "fail:tryDispose_no_exc");
                defer exc.deinit();
                const msg = (try exc.message(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:tryDispose_no_msg");
                defer tracked_alloc.free(msg);
                if (std.mem.indexOf(u8, msg, "sync-dispose-failed") == null) {
                    return std.fmt.allocPrint(out_alloc, "fail:tryDispose_msg:{s}", .{msg});
                }
            }
        }

        // CJS sync Iterable + Disposable
        const joined_cjs = try cjs.joinIterableAlloc(tracked_alloc, &.{ "x", "y", "z" }, "-");
        defer tracked_alloc.free(joined_cjs);
        if (!std.mem.eql(u8, joined_cjs, "x-y-z")) return std.fmt.allocPrint(out_alloc, "fail:cjs_join:{s}", .{joined_cjs});

        {
            const cres = try cjs.CjsResource.init("sock7");
            defer cres.dispose();
        }
        const last_cjs = try cjs.lastCjsDisposedAlloc(tracked_alloc);
        defer tracked_alloc.free(last_cjs);
        if (!std.mem.eql(u8, last_cjs, "cjs:sock7")) return std.fmt.allocPrint(out_alloc, "fail:cjs_dispose:{s}", .{last_cjs});
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_alloc.dupe(u8, "sync-protocols-ok");
}

/// Verifies that calling an auto-awaited `Promise<T>` function synchronously without JSPI (or on
/// native main thread outside `WorkQueue`) returns `error.HostUnavailable` while `*Promise` raw
/// companion handles still work without leaking!
pub fn probeSyncAwaitHostUnavailable() !bool {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    const p = try m.fetchDoubledPromise(5);
    p.deinit();

    const got_unavail = if (m.fetchDoubled(5)) |_| false else |err| (err == error.HostUnavailable);
    try checkInvariants(handles_before, cbs_before, allocs_before);
    return got_unavail;
}

const worker_ns = struct {
    pub fn exerciseAsyncPromises(out_alloc: std.mem.Allocator) ![]u8 {
        const handles_before = js.activeHandleCount();
        const cbs_before = js.activeCallbackCount();
        const allocs_before = live_allocs.load(.acquire);

        try m.resetCounters();

        {
            const d = try m.fetchDoubled(21);
            if (d != 42) return std.fmt.allocPrint(out_alloc, "fail:fetchDoubled:{d}", .{d});

            const greet = try m.fetchGreetingAlloc(tracked_alloc, "Zigar");
            defer tracked_alloc.free(greet);
            if (!std.mem.eql(u8, greet, "Hello, Zigar!")) return std.fmt.allocPrint(out_alloc, "fail:greet:{s}", .{greet});

            try m.touchAsyncCounter();
            const pt = try m.touchAsyncCounterPromise();
            defer pt.deinit();
            try pt.await();
            if ((try m.getAsyncTouchCount()) != 2) return out_alloc.dupe(u8, "fail:touchCount");

            const nested = try m.nestedPromiseValue(23);
            if (nested != 123) return std.fmt.allocPrint(out_alloc, "fail:nested:{d}", .{nested});

            const aliased = try m.aliasedPromise(15);
            if (aliased != 45) return std.fmt.allocPrint(out_alloc, "fail:aliased:{d}", .{aliased});
            const aliased_p = try m.aliasedPromisePromise(10);
            defer aliased_p.deinit();
            if ((try aliased_p.await()) != 30) return out_alloc.dupe(u8, "fail:aliasedPromise");

            // Concurrent tuple fan-out via `*Promise` companions + `js.promiseAllAlloc`
            {
                const p1 = try m.fetchDoubledPromise(10);
                defer p1.deinit();
                const p2 = try m.fetchGreetingPromise("Fanout");
                defer p2.deinit();
                const tuple_res = try js.promiseAllAlloc(tracked_alloc, .{ p1, p2 });
                defer tracked_alloc.free(tuple_res[1]);
                if (tuple_res[0] != 20 or !std.mem.eql(u8, tuple_res[1], "Hello, Fanout!")) {
                    return std.fmt.allocPrint(out_alloc, "fail:promiseAllTuple:{d}:{s}", .{ tuple_res[0], tuple_res[1] });
                }
            }

            // Concurrent fixed-array + slice fan-out via `*Promise` companions + `js.promiseAll` / `js.promiseAllAlloc`
            {
                const ps = [_]js.Promise(f64){
                    try m.fetchDoubledPromise(1),
                    try m.fetchDoubledPromise(2),
                    try m.fetchDoubledPromise(3),
                };
                defer for (ps) |p| p.deinit();
                const arr_vals = try js.promiseAll(ps);
                if (arr_vals[0] != 2 or arr_vals[1] != 4 or arr_vals[2] != 6) {
                    return out_alloc.dupe(u8, "fail:promiseAllArray");
                }
                const ps_slice: []const js.Promise(f64) = &ps;
                const vals = try js.promiseAllAlloc(tracked_alloc, ps_slice);
                defer tracked_alloc.free(vals);
                if (vals.len != 3 or vals[0] != 2 or vals[1] != 4 or vals[2] != 6) {
                    return out_alloc.dupe(u8, "fail:promiseAllSlice");
                }
            }

            // Overloaded async function + `*Promise`
            if ((try m.loadEntry(@as(f64, 7))) != 70) return out_alloc.dupe(u8, "fail:loadEntry_num");
            const le_str = try m.loadEntryAlloc(tracked_alloc, "seven");
            defer tracked_alloc.free(le_str);
            if (!std.mem.eql(u8, le_str, "entry:seven")) return std.fmt.allocPrint(out_alloc, "fail:loadEntry_str:{s}", .{le_str});
            {
                const lep = try m.loadEntryPromise(@as(f64, 9));
                defer lep.deinit();
                if ((try lep.await()) != 90) return out_alloc.dupe(u8, "fail:loadEntryPromise_num");
            }

            // Generic async `*Infer` + `*PromiseInfer`
            if ((try m.asyncIdentityInfer(@as(f64, 123))) != 123) return out_alloc.dupe(u8, "fail:asyncIdentityInfer");
            {
                const pi = try m.asyncIdentityPromiseInfer(@as(f64, 456));
                defer pi.deinit();
                if ((try pi.await()) != 456) return out_alloc.dupe(u8, "fail:asyncIdentityPromiseInfer");
            }

            // Rejected promise error capture via `js.tryTakeLastError()`
            if (m.failAsync("E_PROTO")) |_| {
                return out_alloc.dupe(u8, "fail:failAsync_succeeded");
            } else |err| {
                if (err != error.JsException) return std.fmt.allocPrint(out_alloc, "fail:failAsync_err:{s}", .{@errorName(err)});
                var exc = (try js.tryTakeLastError()) orelse return out_alloc.dupe(u8, "fail:failAsync_no_exc");
                defer exc.deinit();
                const code = (try exc.code(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:failAsync_no_code");
                defer tracked_alloc.free(code);
                const msg = (try exc.message(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:failAsync_no_msg");
                defer tracked_alloc.free(msg);
                if (!std.mem.eql(u8, code, "E_PROTO") or !std.mem.eql(u8, msg, "boom:E_PROTO")) {
                    return std.fmt.allocPrint(out_alloc, "fail:failAsync_meta:{s}:{s}", .{ code, msg });
                }
            }
        }

        try checkInvariants(handles_before, cbs_before, allocs_before);
        return out_alloc.dupe(u8, "async-promises-ok");
    }

    pub fn exerciseAsyncIterablesAndDisposal(out_alloc: std.mem.Allocator) ![]u8 {
        const handles_before = js.activeHandleCount();
        const cbs_before = js.activeCallbackCount();
        const allocs_before = live_allocs.load(.acquire);

        try m.resetCounters();

        {
            // AsyncIterable<string>
            const ait = try m.streamChunks("ch", 4);
            defer ait.deinit();
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(tracked_alloc);
            while (try ait.nextAlloc(tracked_alloc)) |chunk| {
                defer tracked_alloc.free(chunk);
                if (buf.items.len > 0) try buf.append(tracked_alloc, ',');
                try buf.appendSlice(tracked_alloc, chunk);
            }
            if (!std.mem.eql(u8, buf.items, "ch:0,ch:1,ch:2,ch:3")) {
                return std.fmt.allocPrint(out_alloc, "fail:streamChunks:{s}", .{buf.items});
            }

            // AsyncGenerator early `defer inf.closeAndDeinit()` triggers `finally` and releases handle
            {
                const inf = try m.infiniteAsyncCounter(100);
                defer inf.closeAndDeinit();
                const c0 = (try inf.next()) orelse return out_alloc.dupe(u8, "fail:inf0");
                const c1 = (try inf.next()) orelse return out_alloc.dupe(u8, "fail:inf1");
                if (c0 != 100 or c1 != 101) return out_alloc.dupe(u8, "fail:inf_vals");
            }
            if ((try m.getAsyncGenClosedCount()) != 1) return out_alloc.dupe(u8, "fail:async_gen_close");

            // AsyncSession: async method + `[Symbol.asyncIterator]` + `[Symbol.asyncDispose]`
            {
                const sess = try m.AsyncSession.init("S1");
                errdefer sess.deinit();
                if ((try sess.send("hello")) != 1) return out_alloc.dupe(u8, "fail:sess_send1");
                const sp = try sess.sendPromise("world");
                defer sp.deinit();
                if ((try sp.await()) != 2) return out_alloc.dupe(u8, "fail:sess_send2");

                const sit = try sess.asyncIterator();
                defer sit.deinit();
                const ev1 = (try sit.nextAlloc(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:ev1_null");
                defer js.freeDecoded(m.SessionEvent, tracked_alloc, ev1);
                const ev2 = (try sit.nextAlloc(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:ev2_null");
                defer js.freeDecoded(m.SessionEvent, tracked_alloc, ev2);
                if ((try sit.nextAlloc(tracked_alloc)) != null) return out_alloc.dupe(u8, "fail:ev3_not_null");
                if (ev1.seq != 1 or !std.mem.eql(u8, ev1.text, "S1:hello") or ev2.seq != 2 or !std.mem.eql(u8, ev2.text, "S1:world")) {
                    return out_alloc.dupe(u8, "fail:sess_events");
                }

                try sess.tryAsyncDispose();
            }

            // Legacy `Symbol.for("nodejs.asyncDispose")` via `defer lah.asyncDispose()`
            {
                const lah = try m.LegacyAsyncHandle.init("pipe9");
                defer lah.asyncDispose();
            }

            // TC39 `AsyncDisposable` fallback to sync `[Symbol.dispose]`
            {
                const fb = try m.makeSyncOnlyDisposableForAsyncFallback("fb1");
                errdefer fb.deinit();
                try fb.tryAsyncDispose();
            }

            const log = try m.getDisposeLogAlloc(tracked_alloc);
            defer js.freeDecoded([]const []const u8, tracked_alloc, log);
            if (log.len != 3 or
                !std.mem.eql(u8, log[0], "async-session:S1:2") or
                !std.mem.eql(u8, log[1], "legacy-async:pipe9") or
                !std.mem.eql(u8, log[2], "sync-fallback:fb1"))
            {
                return std.fmt.allocPrint(out_alloc, "fail:async_dispose_log:{d}", .{log.len});
            }

            // CJS async Promise + AsyncIterable
            if ((try cjs.mulAsync(6, 7)) != 42) return out_alloc.dupe(u8, "fail:cjs_mulAsync");
            const mp = try cjs.mulAsyncPromise(8, 9);
            defer mp.deinit();
            if ((try mp.await()) != 72) return out_alloc.dupe(u8, "fail:cjs_mulAsyncPromise");

            const cit = try cjs.asyncCountUp(3);
            defer cit.deinit();
            var csum: f64 = 0;
            while (try cit.next()) |v| csum += v;
            if (csum != 60) return std.fmt.allocPrint(out_alloc, "fail:cjs_asyncCountUp:{d}", .{csum});
        }

        try checkInvariants(handles_before, cbs_before, allocs_before);
        return out_alloc.dupe(u8, "async-iterables-and-disposal-ok");
    }
};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

var work_queue: if (is_wasm) void else zigar.thread.WorkQueue(worker_ns) = if (is_wasm) {} else .{};

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const runAsyncPromises = if (is_wasm) worker_ns.exerciseAsyncPromises else work_queue.promisify(worker_ns.exerciseAsyncPromises);
pub const runAsyncIterablesAndDisposal = if (is_wasm) worker_ns.exerciseAsyncIterablesAndDisposal else work_queue.promisify(worker_ns.exerciseAsyncIterablesAndDisposal);
