const std = @import("std");
const zigar = @import("zigar");

const js = zigar.js;
const Ref = js.Ref;

var live_allocs = std.atomic.Value(usize).init(0);

const TrackingAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ptr = std.heap.c_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = live_allocs.fetchAdd(1, .acq_rel);
        return ptr;
    }

    fn resize(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return std.heap.c_allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return std.heap.c_allocator.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        std.heap.c_allocator.rawFree(buf, alignment, ret_addr);
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

pub const Point = struct {
    x: i32,
    y: i32,
};

var work_queue: zigar.thread.WorkQueue(worker_ns) = .{};

pub const startup = work_queue.promisify(.startup);
pub const shutdown = work_queue.promisify(.shutdown);

pub const workerAwaitTwiceAndSum = work_queue.promisify(worker_ns.awaitTwiceAndSum);
pub const workerAwaitAdd = work_queue.promisify(worker_ns.awaitAdd);
pub const workerAwaitPointSum = work_queue.promisify(worker_ns.awaitPointSum);
pub const workerAwaitUpperString = work_queue.promisify(worker_ns.awaitUpperString);
pub const workerAwaitRefTag = work_queue.promisify(worker_ns.awaitRefTag);
pub const workerAwaitVoidPromise = work_queue.promisify(worker_ns.awaitVoidPromise);
pub const workerAwaitInspectRejection = work_queue.promisify(worker_ns.awaitInspectRejection);
pub const workerAwaitCatchUninspected = work_queue.promisify(worker_ns.awaitCatchUninspected);
pub const workerVerifyCleanErrorState = work_queue.promisify(worker_ns.verifyCleanErrorState);
pub const workerConsumeAsyncIterator = work_queue.promisify(worker_ns.consumeAsyncIterator);
pub const workerSyncWrappersAndAsyncDispose = work_queue.promisify(worker_ns.syncWrappersAndAsyncDispose);
pub const workerNestedSyncReentrancy = work_queue.promisify(worker_ns.nestedSyncReentrancy);
pub const workerNestedSyncPropagateError = work_queue.promisify(worker_ns.nestedSyncPropagateError);
pub const workerNestedPreserveOuterError = work_queue.promisify(worker_ns.nestedPreserveOuterError);

pub fn pushDetachedWorkerAwaitNoPromise(p: js.Promise(i32)) !void {
    try work_queue.push(worker_ns.awaitCatchUninspected, .{p}, null);
}

const NestedBoomCtx = struct {
    obj: Ref(js.Object),
};

const NestedClosureHooks = struct {
    fn infallibleBoom(ctx: *NestedBoomCtx) i32 {
        defer ctx.obj.deinit();
        _ = ctx.obj.call(fn () i32, "boom", .{});
        return 100;
    }

    fn tryCallRecover(ctx: *NestedBoomCtx) i32 {
        defer ctx.obj.deinit();
        return ctx.obj.tryCall(fn () i32, "boom", .{}) catch -1;
    }
};

pub fn syncCallInfallibleBoom(obj: Ref(js.Object)) i32 {
    defer obj.deinit();
    _ = obj.call(fn () i32, "boom", .{});
    return 100;
}

pub fn syncTryCallRecover(obj: Ref(js.Object)) i32 {
    defer obj.deinit();
    return obj.tryCall(fn () i32, "boom", .{}) catch -1;
}

pub fn makeOnceClosureInfallibleBoom(obj: Ref(js.Object)) !Ref(js.Function) {
    defer obj.deinit();
    const cloned = obj.clone();
    errdefer cloned.deinit();
    const cl = try js.Closure(NestedBoomCtx, NestedClosureHooks.infallibleBoom).tryOnceOwned(tracked_alloc, .{
        .obj = cloned,
    });
    return cl.cloneRef();
}

pub fn makeOnceClosureTryRecover(obj: Ref(js.Object)) !Ref(js.Function) {
    defer obj.deinit();
    const cloned = obj.clone();
    errdefer cloned.deinit();
    const cl = try js.Closure(NestedBoomCtx, NestedClosureHooks.tryCallRecover).tryOnceOwned(tracked_alloc, .{
        .obj = cloned,
    });
    return cl.cloneRef();
}

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

pub fn liveZigAllocs() usize {
    return live_allocs.load(.acquire);
}

// ---------------------------------------------------------------------------
// Raw OS thread guard: must ALWAYS return OffJsThread even while WorkQueue runs
// ---------------------------------------------------------------------------

pub fn probeRawThreadOffJsThread(p: js.Promise(i32)) !bool {
    defer p.deinit();
    var ok = std.atomic.Value(bool).init(false);
    const Runner = struct {
        fn run(raw_p: js.Promise(i32), out_ok: *std.atomic.Value(bool)) void {
            if (js.isJsThread()) return;
            const await_err = raw_p.await();
            if (await_err != error.OffJsThread) return;
            const buf_err = js.Buffer.alloc(4);
            if (buf_err != error.OffJsThread) return;
            const map_err = js.Map(i32, i32).init();
            if (map_err != error.OffJsThread) return;
            out_ok.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ p, &ok });
    thread.join();
    return ok.load(.acquire);
}

// ---------------------------------------------------------------------------
// Main-thread synchronous Promise & Standard Wrapper operations
// ---------------------------------------------------------------------------

pub fn mainThreadAwaitReturnsHostUnavailable(p: js.Promise(i32)) !i32 {
    defer p.deinit();
    return p.await();
}

pub fn mainThreadAsyncIterReturnsHostUnavailable(async_iterable: Ref(js.Any)) !bool {
    defer async_iterable.deinit();
    const it = try js.AsyncIterator(i32).from(async_iterable);
    defer it.deinit();
    _ = try it.next();
    return true;
}

pub fn makeResolvedPromise(val: i32) !js.Promise(i32) {
    return js.Promise(i32).resolve(val);
}

pub fn makeRejectedPromise(reason: []const u8) !js.Promise(i32) {
    return js.Promise(i32).reject(reason);
}

pub fn maybePromise(present: bool, val: i32) !?js.Promise(i32) {
    if (!present) return null;
    return try js.Promise(i32).resolve(val);
}

const ChainHooks = struct {
    pub fn triplePlusOne(x: i32) i32 {
        return x * 3 + 1;
    }

    pub fn recoverFortyTwo(reason: Ref(js.Any)) i32 {
        defer reason.deinit();
        return 42;
    }
};

pub fn chainPromiseTriple(p: js.Promise(i32)) !js.Promise(i32) {
    defer p.deinit();
    const cl = try js.Closure(void, ChainHooks.triplePlusOne).tryOnce();
    errdefer cl.deinit();
    return p.then(cl, null);
}

pub fn chainPromiseRecover(p: js.Promise(i32)) !js.Promise(i32) {
    defer p.deinit();
    const cl = try js.Closure(void, ChainHooks.recoverFortyTwo).tryOnce();
    errdefer cl.deinit();
    return p.catchError(cl);
}

pub fn createNodeBufferReversed(src: []const u8) !js.Buffer {
    const tmp = try tracked_alloc.alloc(u8, src.len);
    defer tracked_alloc.free(tmp);
    for (src, 0..) |b, i| {
        tmp[src.len - 1 - i] = b;
    }
    return js.Buffer.fromSlice(tmp);
}

pub fn checkIsNodeBuffer(val: Ref(js.Any)) !bool {
    defer val.deinit();
    return js.Buffer.isBuffer(val);
}

pub fn xorBufferInPlace(buf: js.Buffer, mask: u8) !usize {
    defer buf.deinit();
    const data = try buf.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(data);
    for (data) |*b| {
        b.* ^= mask;
    }
    try buf.writeFrom(data);
    return data.len;
}

pub fn roundtripBufferUtf8(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const buf = try js.Buffer.fromString(text);
    defer buf.deinit();
    return buf.toStringAlloc(allocator);
}

pub fn typedArraysAndViewsShowcase(payload_size: usize) !u64 {
    const empty_u8 = try js.Uint8Array.fromSlice(&.{});
    defer empty_u8.deinit();
    if ((try empty_u8.len()) != 0) return error.JsException;

    const ints = [_]i32{ -100, 50, 75, 1000 };
    const i32_arr = try js.Int32Array.fromSlice(&ints);
    defer i32_arr.deinit();
    const owned_ints = try i32_arr.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(owned_ints);
    if (owned_ints[1] != 50 or owned_ints[3] != 1000) return error.JsException;

    const floats = [_]f64{ 1.5, 2.25, -0.75 };
    const f64_arr = try js.Float64Array.fromSlice(&floats);
    defer f64_arr.deinit();
    if ((try f64_arr.get(0)) != 1.5) return error.JsException;

    const u64s = [_]u64{ 10, 20, 0x0000_0001_0000_0000 };
    const u64_arr = try js.BigUint64Array.fromSlice(&u64s);
    defer u64_arr.deinit();
    if ((try u64_arr.get(2)) != 0x0000_0001_0000_0000) return error.JsException;

    const src = try tracked_alloc.alloc(u8, payload_size);
    defer tracked_alloc.free(src);
    for (src, 0..) |*b, idx| {
        b.* = @truncate((idx *% 31 +% 7) & 0xff);
    }

    const ab = try js.ArrayBuffer.fromSlice(src);
    defer ab.deinit();
    const sliced_ab = try ab.slice(4, @intCast(payload_size - 4));
    defer sliced_ab.deinit();

    const sab = try js.SharedArrayBuffer.init(try sliced_ab.byteLength());
    defer sab.deinit();
    const mid = try sliced_ab.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(mid);
    try sab.writeFrom(mid);

    const sab_out = try sab.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(sab_out);

    var checksum: u64 = 0;
    for (sab_out, 0..) |b, i| {
        if (b != src[i + 4]) return error.JsException;
        checksum +%= b;
    }

    const dv = try js.DataView.init(ab, 8, 16);
    defer dv.deinit();
    try dv.setInt32(0, -424242, true);
    try dv.setFloat64(8, 6.25, false);
    if ((try dv.getInt32(0, true)) != -424242) return error.JsException;
    if ((try dv.getFloat64(8, false)) != 6.25) return error.JsException;

    return checksum;
}

pub fn collectionsAndIntrinsicsShowcase(allocator: std.mem.Allocator, bad_mixed_str_arr: js.Array([]const u8)) ![]u8 {
    defer bad_mixed_str_arr.deinit();

    // Array + mid-array error cleanup
    const allocs_before = live_allocs.load(.acquire);
    if (bad_mixed_str_arr.toOwnedSlice(tracked_alloc)) |unexpected| {
        for (unexpected) |s| tracked_alloc.free(s);
        tracked_alloc.free(unexpected);
        return error.JsException;
    } else |err| {
        if (err != error.JsException) return err;
        js.clearLastError();
    }
    if (live_allocs.load(.acquire) != allocs_before) return error.JsException;

    // Map, Set, Record
    const m = try js.Map([]const u8, ?i32).init();
    defer m.deinit();
    try m.set("a", 12);
    try m.set("b", null);
    if (((try m.get("b")) orelse return error.JsException) != null) return error.JsException;
    if ((try m.get("missing")) != null) return error.JsException;

    const s = try js.Set(i32).init();
    defer s.deinit();
    try s.add(3);
    try s.add(3);
    try s.add(9);

    const rec = try js.Record([]const u8, i32).init();
    defer rec.deinit();
    try rec.set("x", 55);
    const keys = try rec.keysAlloc(tracked_alloc);
    defer {
        for (keys) |k| tracked_alloc.free(k);
        tracked_alloc.free(keys);
    }

    // BigInt bounds + 256-bit
    const bi_min = try js.BigInt.fromI64(std.math.minInt(i64));
    defer bi_min.deinit();
    if (bi_min.toU64()) |_| return error.JsException else |err| {
        if (err != error.Overflow) return err;
    }
    const hex256 = "fedcba98765432100123456789abcdeffedcba98765432100123456789abcdef";
    const bi256 = try js.BigInt.fromString("0x" ++ hex256);
    defer bi256.deinit();
    if (bi256.toU128()) |_| return error.JsException else |err| {
        if (err != error.Overflow) return err;
    }
    const hex_out = try bi256.toStringAlloc(tracked_alloc, 16);
    defer tracked_alloc.free(hex_out);
    if (!std.mem.eql(u8, hex_out, hex256)) return error.JsException;

    // Date & RegExp
    const dt = try js.Date.fromIsoString("2026-05-01T12:30:00.000Z");
    defer dt.deinit();
    const iso = try dt.toIsoStringAlloc(tracked_alloc);
    defer tracked_alloc.free(iso);

    const re = try js.RegExp.init("^native-[0-9]+$", "i");
    defer re.deinit();
    const matched = try re.testMatch("NATIVE-38");

    return std.fmt.allocPrint(
        allocator,
        "set={d}|keys={d}|iso={s}|re={}",
        .{ try s.size(), keys.len, iso, matched },
    );
}

pub fn consumeSyncIteratorEarly(iterable: Ref(js.Any), limit: usize) !i32 {
    defer iterable.deinit();
    const it = try js.Iterator(i32).from(iterable);
    defer it.deinit();

    var sum: i32 = 0;
    var count: usize = 0;
    while (try it.next()) |v| {
        sum += v;
        count += 1;
        if (count >= limit) {
            try it.close();
            break;
        }
    }
    return sum;
}

// ---------------------------------------------------------------------------
// WorkQueue worker namespace: full async Promise/AsyncIterator + bridged JS ops
// ---------------------------------------------------------------------------

const worker_ns = struct {
    pub fn awaitTwiceAndSum(p: js.Promise(i32)) !i32 {
        defer p.deinit();
        const first = try p.await();
        const second = try p.wait();
        return first + second;
    }

    pub fn awaitAdd(p1: js.Promise(i32), p2: js.Promise(i32)) !i32 {
        defer p1.deinit();
        defer p2.deinit();
        const a = try p1.await();
        const b = try p2.await();
        return a + b;
    }

    pub fn awaitPointSum(p: js.Promise(Point)) !i32 {
        defer p.deinit();
        const pt = try p.await();
        return pt.x * 10 + pt.y;
    }

    pub fn awaitUpperString(allocator: std.mem.Allocator, p: js.Promise([]const u8)) ![]u8 {
        defer p.deinit();
        const raw = try p.awaitAlloc(tracked_alloc);
        defer tracked_alloc.free(raw);
        const out = try allocator.alloc(u8, raw.len);
        for (raw, 0..) |ch, i| {
            out[i] = std.ascii.toUpper(ch);
        }
        return out;
    }

    pub fn awaitRefTag(allocator: std.mem.Allocator, p: js.Promise(Ref(js.Object))) ![]u8 {
        defer p.deinit();
        const obj = try p.await();
        defer obj.deinit();
        return obj.getAlloc(allocator, js.AllocError![]u8, "tag");
    }

    pub fn awaitVoidPromise(p: js.Promise(void)) !i32 {
        defer p.deinit();
        try p.await();
        return 204;
    }

    pub fn awaitInspectRejection(allocator: std.mem.Allocator, p: js.Promise(i32)) ![]u8 {
        defer p.deinit();
        if (p.await()) |val| {
            return std.fmt.allocPrint(allocator, "resolved:{d}", .{val});
        } else |err| switch (err) {
            error.JsException => {
                var exc = (try js.tryTakeLastError()) orelse return allocator.dupe(u8, "missing-last-error");
                defer exc.deinit();
                const val_type = exc.value().typeof();
                const name_opt = try exc.name(tracked_alloc);
                defer if (name_opt) |s| tracked_alloc.free(s);
                const msg_opt = try exc.message(tracked_alloc);
                defer if (msg_opt) |s| tracked_alloc.free(s);
                const code_opt = try exc.code(tracked_alloc);
                defer if (code_opt) |s| tracked_alloc.free(s);
                return std.fmt.allocPrint(
                    allocator,
                    "type={s}|name={s}|code={s}|msg={s}",
                    .{
                        @tagName(val_type),
                        name_opt orelse "<null>",
                        code_opt orelse "<null>",
                        msg_opt orelse "<null>",
                    },
                );
            },
            else => return allocator.dupe(u8, @errorName(err)),
        }
    }

    pub fn awaitCatchUninspected(p: js.Promise(i32)) !i32 {
        defer p.deinit();
        return p.await() catch |err| switch (err) {
            error.JsException => -999,
            else => return err,
        };
    }

    pub fn verifyCleanErrorState() bool {
        return !js.hasLastError();
    }

    pub fn consumeAsyncIterator(allocator: std.mem.Allocator, async_iterable: Ref(js.Any), limit: usize) ![]u8 {
        defer async_iterable.deinit();
        const it = try js.AsyncIterator([]const u8).from(async_iterable);
        defer it.deinit();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(tracked_alloc);

        var count: usize = 0;
        while (true) {
            const next_opt = it.nextAlloc(tracked_alloc) catch |err| switch (err) {
                error.JsException => {
                    var exc = (try js.tryTakeLastError()) orelse return allocator.dupe(u8, "err:<missing>");
                    defer exc.deinit();
                    const msg = (try exc.message(tracked_alloc)) orelse try tracked_alloc.dupe(u8, "<no-msg>");
                    defer tracked_alloc.free(msg);
                    if (out.items.len > 0) try out.append(tracked_alloc, '|');
                    try out.appendSlice(tracked_alloc, "ERR:");
                    try out.appendSlice(tracked_alloc, msg);
                    return allocator.dupe(u8, out.items);
                },
                else => return err,
            };
            const item = next_opt orelse break;
            defer tracked_alloc.free(item);
            if (out.items.len > 0) try out.append(tracked_alloc, ',');
            try out.appendSlice(tracked_alloc, item);
            count += 1;
            if (limit > 0 and count >= limit) {
                try it.close();
                break;
            }
        }
        return allocator.dupe(u8, out.items);
    }

    pub fn syncWrappersAndAsyncDispose(allocator: std.mem.Allocator, async_disposable: Ref(js.Object)) ![]u8 {
        try async_disposable.tryAsyncDispose();

        const buf = try js.Buffer.fromSlice("worker-buf");
        defer buf.deinit();
        const is_buf = try js.Buffer.isBuffer(buf);

        const arr = try js.Array(i32).fromSlice(&.{ 4, 5, 6 });
        defer arr.deinit();
        var sum: i32 = 0;
        const it = try arr.iterator();
        defer it.deinit();
        while (try it.next()) |v| sum += v;

        const m = try js.Map([]const u8, i32).init();
        defer m.deinit();
        try m.set("worker", sum);
        const got = (try m.get("worker")) orelse 0;

        const bi = try js.BigInt.fromI128(-12345678901234567890);
        defer bi.deinit();
        const bi_str = try bi.toStringAlloc(tracked_alloc, 10);
        defer tracked_alloc.free(bi_str);

        return std.fmt.allocPrint(allocator, "buf={}|got={d}|bi={s}", .{ is_buf, got, bi_str });
    }

    pub fn nestedSyncReentrancy(hook: Ref(js.Function)) !i32 {
        defer hook.deinit();
        if (js.hasLastError()) return error.UnexpectedPriorWorkerError;
        const val = try hook.tryInvoke(fn () i32, .{});
        if (js.hasLastError()) return error.StaleWorkerLastError;
        return val;
    }

    pub fn nestedSyncPropagateError(allocator: std.mem.Allocator, hook: Ref(js.Function)) ![]const u8 {
        defer hook.deinit();
        if (hook.tryInvoke(fn () i32, .{})) |_| {
            return error.ExpectedJsException;
        } else |err| {
            if (err != error.JsException) return err;
            var exc = (try js.tryTakeLastError()) orelse return error.MissingCapturedError;
            defer exc.deinit();
            if (js.hasLastError()) return error.StaleWorkerLastError;
            return (try exc.message(allocator)) orelse return error.MissingMessage;
        }
    }

    pub fn nestedPreserveOuterError(
        allocator: std.mem.Allocator,
        outer_boom: Ref(js.Function),
        inner_try_recover_hook: Ref(js.Function),
    ) ![]const u8 {
        defer outer_boom.deinit();
        defer inner_try_recover_hook.deinit();
        if (outer_boom.tryInvoke(fn () i32, .{})) |_| {
            return error.ExpectedOuterJsException;
        } else |err| {
            if (err != error.JsException) return err;
        }
        if (!js.hasLastError()) return error.ExpectedOuterCapturedError;

        const inner_val = try inner_try_recover_hook.tryInvoke(fn () i32, .{});
        if (inner_val != -1) return error.UnexpectedInnerReturnValue;
        if (!js.hasLastError()) return error.LostOuterCapturedError;

        var exc = (try js.tryTakeLastError()) orelse return error.MissingOuterCapturedError;
        defer exc.deinit();
        if (js.hasLastError()) return error.StaleWorkerLastError;
        return (try exc.message(allocator)) orelse return error.MissingMessage;
    }
};

pub const AbortedJscallFn = *const fn () error{Unexpected}!void;

var aborted_jscall_ready: std.atomic.Value(u32) = .init(0);
var aborted_jscall_state: std.atomic.Value(u32) = .init(0);
var aborted_jscall_thread: ?std.Thread = null;
var aborted_jscall_fn: ?AbortedJscallFn = null;

fn runAbortedJscallWorker(cb: AbortedJscallFn) void {
    aborted_jscall_ready.store(1, .release);
    if (cb()) |_| {
        aborted_jscall_state.store(2, .release);
    } else |_| {
        aborted_jscall_state.store(1, .release);
    }
}

pub fn triggerAbortedQueuedJscall(cb: AbortedJscallFn) !void {
    aborted_jscall_ready.store(0, .release);
    aborted_jscall_state.store(0, .release);
    aborted_jscall_fn = cb;
    try zigar.thread.use();
    const t = try std.Thread.spawn(.{}, runAbortedJscallWorker, .{cb});
    aborted_jscall_thread = t;
    while (aborted_jscall_ready.load(.acquire) == 0) {
        std.atomic.spinLoopHint();
    }
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(15), .real) catch {};
    zigar.thread.end();
}

pub fn pollAndJoinAbortedQueuedJscall() u32 {
    const state = aborted_jscall_state.load(.acquire);
    if (state != 0) {
        if (aborted_jscall_thread) |t| {
            aborted_jscall_thread = null;
            t.join();
        }
        if (aborted_jscall_fn) |cb| {
            aborted_jscall_fn = null;
            zigar.function.release(cb);
        }
    }
    return state;
}

