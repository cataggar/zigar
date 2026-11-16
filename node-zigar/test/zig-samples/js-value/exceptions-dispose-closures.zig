const std = @import("std");
const zigar = @import("zigar");

const js = zigar.js;
const Ref = js.Ref;

const NodeFs = js.Module("node:fs");

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

var live_box_allocs: u32 = 0;
var pool_in_use: [8]bool = @splat(false);
var pool_storage: [8][128]u8 align(16) = undefined;

const CountingPoolAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        if (len > 128) return null;
        for (&pool_in_use, 0..) |*used, idx| {
            if (!used.*) {
                used.* = true;
                live_box_allocs += 1;
                return &pool_storage[idx];
            }
        }
        return null;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const addr = @intFromPtr(buf.ptr);
        for (&pool_storage, 0..) |*slot, idx| {
            if (@intFromPtr(slot) == addr) {
                pool_in_use[idx] = false;
                live_box_allocs -= 1;
                return;
            }
        }
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

pub fn liveBoxAllocs() u32 {
    return live_box_allocs;
}

var sync_dispose_defer_runs: u32 = 0;

pub fn getSyncDisposeDeferRuns() u32 {
    return sync_dispose_defer_runs;
}

pub fn resetSyncDisposeDeferRuns() void {
    sync_dispose_defer_runs = 0;
}

// 1. Lazy zero-leak exception bridging: catch N exceptions WITHOUT calling takeLastError/lastError
pub fn catchManyWithoutTakingError(thrower: Ref(js.Function), iterations: u32) !u32 {
    defer thrower.deinit();
    const baseline_handles = js.activeHandleCount();
    var caught_count: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        if (js.callFn(fn (u32) js.Error!i32, thrower, .{i})) |_| {
            return error.JsException;
        } else |err| {
            if (err != error.JsException) return err;
            caught_count += 1;
            if (!js.hasLastError()) return error.InvalidHandle;
            if (js.activeHandleCount() != baseline_handles) return error.InvalidHandle;
        }
    }
    return caught_count;
}

fn formatExceptionSummary(alloc: std.mem.Allocator, exc: js.JsException) ![]const u8 {
    const ty = try exc.value().tryTypeof();
    const name_s = try exc.name(alloc);
    defer if (name_s) |s| alloc.free(s);
    const code_s = try exc.code(alloc);
    defer if (code_s) |s| alloc.free(s);
    const msg_s = try exc.message(alloc);
    defer if (msg_s) |s| alloc.free(s);
    const stack_s = try exc.stack(alloc);
    defer if (stack_s) |s| alloc.free(s);

    return std.fmt.allocPrint(
        alloc,
        "type={s}|name={s}|code={s}|msg={s}|stack={s}",
        .{
            @tagName(ty),
            name_s orelse "<null>",
            code_s orelse "<null>",
            msg_s orelse "<null>",
            if (stack_s != null and stack_s.?.len > 0) "yes" else "no",
        },
    );
}

// 2. Inspect thrown JS values via lastError() (peek) + takeLastError() (consume)
pub fn inspectThrownException(alloc: std.mem.Allocator, thrower: Ref(js.Function)) ![]const u8 {
    defer thrower.deinit();
    if (js.callFn(fn () js.Error!Ref(js.Any), thrower, .{})) |unexpected_val| {
        unexpected_val.deinit();
        return error.InvalidHandle;
    } else |err| {
        if (err != error.JsException) return err;
        const peeked = js.lastError() orelse return error.InvalidHandle;
        defer peeked.deinit();
        if (!js.hasLastError()) return error.InvalidHandle;

        const taken = js.takeLastError() orelse return error.InvalidHandle;
        defer taken.deinit();
        if (js.hasLastError()) return error.InvalidHandle;
        if (js.takeLastError() != null) return error.InvalidHandle;

        return formatExceptionSummary(alloc, taken);
    }
}

// 3. Real `node:fs` `readFileSync` with explicit `js.Error!Ref(js.Any)` (verifying EnsureErrorReturn)
pub fn inspectNodeFsReadMissingFile(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (NodeFs.call(fn ([]const u8) js.Error!Ref(js.Any), "readFileSync", .{path})) |buf| {
        buf.deinit();
        return error.InvalidHandle;
    } else |err| {
        const e: js.Error = err;
        if (e != error.JsException) return e;
        const info = js.takeLastError() orelse return error.InvalidHandle;
        defer info.deinit();
        return formatExceptionSummary(alloc, info);
    }
}

// 4. Explicit Resource Management: sync Symbol.dispose (`defer res.dispose()` and `try res.tryDispose()`)
pub fn useResourceWithDeferDispose(res: Ref(js.Any)) i32 {
    defer {
        sync_dispose_defer_runs += 1;
    }
    defer res.dispose();
    Ref(js.Any).null.dispose();
    Ref(js.Any).@"undefined".dispose();
    return 42;
}

pub fn useResourceWithTryDispose(alloc: std.mem.Allocator, res: Ref(js.Any)) ![]const u8 {
    if (res.tryDispose()) |_| {
        return alloc.dupe(u8, "ok");
    } else |err| {
        if (err != error.JsException) return error.InvalidHandle;
        const info = js.takeLastError() orelse return error.InvalidHandle;
        defer info.deinit();
        return formatExceptionSummary(alloc, info);
    }
}

// 5. Explicit Resource Management: Symbol.asyncDispose (`asyncDispose` and `tryAsyncDispose`)
pub fn useResourceWithDeferAsyncDispose(res: Ref(js.Any)) i32 {
    defer {
        sync_dispose_defer_runs += 1;
    }
    defer res.asyncDispose();
    Ref(js.Any).null.asyncDispose();
    Ref(js.Any).@"undefined".asyncDispose();
    return 77;
}

pub fn useResourceWithTryAsyncDispose(alloc: std.mem.Allocator, res: Ref(js.Any)) ![]const u8 {
    if (res.tryAsyncDispose()) |_| {
        return alloc.dupe(u8, "ok");
    } else |err| {
        if (err == error.HostUnavailable) {
            return alloc.dupe(u8, "HostUnavailable");
        }
        if (err != error.JsException) return err;
        const info = js.takeLastError() orelse return error.InvalidHandle;
        defer info.deinit();
        return formatExceptionSummary(alloc, info);
    }
}

// 6. Stateful Closures (`js.Closure`), `.deinit()`, re-entrant `.deinit()`, and `.once()` / `.onceOwned()`
const StackCounter = struct {
    total: i32 = 0,
    calls: u32 = 0,

    fn add(self: *StackCounter, delta: i32) i32 {
        self.calls += 1;
        self.total += delta;
        return self.total;
    }

    fn multiply(self: *StackCounter, factor: i32) i32 {
        self.calls += 1;
        self.total *= factor;
        return self.total;
    }
};

const OwnedMultiplier = struct {
    scale: i32,
    offset: i32,

    fn apply(self: *OwnedMultiplier, x: i32) i32 {
        return x * self.scale + self.offset;
    }
};

const SelfDeinitClosure = js.Closure(*SelfDeinitCtx, SelfDeinitCtx.onInvoke);
const SelfDeinitCtx = struct {
    hits: u32 = 0,
    closure: SelfDeinitClosure = .{},

    fn onInvoke(self: *SelfDeinitCtx, x: i32) i32 {
        self.hits += 1;
        self.closure.deinit();
        return x + @as(i32, @intCast(self.hits)) * 100;
    }
};

pub fn exerciseStatefulClosures(driver: Ref(js.Function)) !i32 {
    defer driver.deinit();
    const pool = CountingPoolAllocator.allocator();

    var counter: StackCounter = .{ .total = 5 };
    var add_closure = try js.Closure(*StackCounter, fn (i32) i32).tryInit(&counter, StackCounter.add);
    defer add_closure.deinit();

    var mul_closure = try js.Closure(*StackCounter, StackCounter.multiply).tryInit(&counter);
    defer mul_closure.deinit();

    var owned_closure = try js.Closure(OwnedMultiplier, OwnedMultiplier.apply).tryInit(
        pool,
        .{ .scale = 3, .offset = 7 },
    );
    defer owned_closure.deinit();

    if (live_box_allocs != 1) return error.InvalidCallback;

    const step1 = try js.callFn(
        fn (js.Closure(*StackCounter, fn (i32) i32), js.Closure(*StackCounter, StackCounter.multiply), js.Closure(OwnedMultiplier, OwnedMultiplier.apply)) js.Error!i32,
        driver,
        .{ add_closure, mul_closure, owned_closure },
    );

    const retained_fn = owned_closure.value().clone();
    defer retained_fn.deinit();
    owned_closure.deinit();
    if (live_box_allocs != 0) return error.InvalidCallback;

    if (js.callFn(fn (i32) js.Error!i32, retained_fn, .{10})) |_| {
        return error.InvalidCallback;
    } else |err| {
        if (err != error.JsException) return err;
        js.clearLastError();
    }

    var reentrant_ctx: SelfDeinitCtx = .{};
    reentrant_ctx.closure = try SelfDeinitClosure.tryInit(&reentrant_ctx);
    defer reentrant_ctx.closure.deinit();
    const reentrant_fn = reentrant_ctx.closure.value().clone();
    defer reentrant_fn.deinit();

    const r1 = try js.callFn(fn (i32) js.Error!i32, reentrant_fn, .{9});
    if (r1 != 109 or reentrant_ctx.hits != 1 or reentrant_ctx.closure.isActive()) {
        return error.InvalidCallback;
    }
    if (js.callFn(fn (i32) js.Error!i32, reentrant_fn, .{9})) |_| {
        return error.InvalidCallback;
    } else |err| {
        if (err != error.JsException) return err;
        js.clearLastError();
    }

    return step1 + @as(i32, @intCast(counter.calls));
}

const OncePayload = struct {
    bonus: i32,

    fn compute(self: *OncePayload, x: i32) i32 {
        return x + self.bonus;
    }
};

pub fn exerciseOnceClosuresAndAbaSafety(emitter: Ref(js.Object)) !i32 {
    defer emitter.deinit();
    const pool = CountingPoolAllocator.allocator();
    const baseline_handles = js.activeHandleCount();
    const baseline_cbs = js.activeCallbackCount();

    var fired_once = try js.Closure(OncePayload, OncePayload.compute).tryOnce(
        pool,
        .{ .bonus = 50 },
    );
    defer fired_once.deinit();

    if (live_box_allocs != 1) return error.InvalidCallback;
    if (js.activeCallbackCount() != baseline_cbs + 1) return error.InvalidCallback;
    if (js.activeHandleCount() != baseline_handles + 1) return error.InvalidHandle;

    try emitter.tryCall(fn (js.Closure(OncePayload, OncePayload.compute)) js.Error!void, "registerOnce", .{fired_once});

    const first_out = try emitter.tryCall(fn (i32) js.Error!i32, "fire", .{12});
    if (first_out != 62) return error.InvalidCallback;

    if (fired_once.isActive()) return error.InvalidCallback;
    if (live_box_allocs != 0) return error.InvalidCallback;
    if (js.activeCallbackCount() != baseline_cbs) return error.InvalidCallback;
    if (js.activeHandleCount() != baseline_handles) return error.InvalidHandle;

    var fresh_once_unused = try js.Closure(OncePayload, OncePayload.compute).tryOnce(
        pool,
        .{ .bonus = 999 },
    );
    defer fresh_once_unused.deinit();
    if (live_box_allocs != 1) return error.InvalidCallback;

    if (emitter.tryCall(fn (i32) js.Error!i32, "fireAgain", .{1})) |_| {
        return error.InvalidCallback;
    } else |err| {
        if (err != error.JsException) return err;
        js.clearLastError();
    }

    if (!fresh_once_unused.isActive()) return error.InvalidCallback;

    return first_out;
}
