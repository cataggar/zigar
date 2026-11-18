const std = @import("std");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const m = gen.m3_functions_esm;
const cjs = gen.m3_functions_cjs;

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

// 1. Subsumed overload dedup + semantic overload names + unified comptime dispatchers (`Buf.from`, `readFile`, `MiniEmitter`, CJS `callableToolkit`)
pub fn exerciseSmartOverloadsAndCjs(out_alloc: std.mem.Allocator) ![]const u8 {
    comptime {
        if (@hasDecl(m, "parseHexOrRadix_2")) @compileError("parseHexOrRadix_2 should be deduplicated");
        if (@hasDecl(m.Buf, "from_2") or @hasDecl(m.Buf, "from_3")) @compileError("Buf.from should have semantic names");
        if (@hasDecl(m, "readFile_2") or @hasDecl(m, "readFile_3")) @compileError("readFile should have semantic names");
        if (@hasDecl(m.MiniEmitter, "init_2") or @hasDecl(m.MiniEmitter, "on_2")) @compileError("MiniEmitter should have semantic names");
    }

    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var read_summary: [96]u8 = undefined;
    var read_len: usize = 0;

    {
        const p_hex = try m.parseHexOrRadix("ff", null);
        const p_bin = try m.parseHexOrRadix("1010", 2);
        if (p_hex != 255 or p_bin != 10) return error.Unexpected;

        // M3: Single-tuple-arg overload wrapping (`pair: [number, number]` vs `(a, b, c)`) & exact-arity bonus
        const st_pair = try m.sumTupleOrTriple(.{ @as(f64, 10), @as(f64, 32) });
        const st_triple = try m.sumTupleOrTriple(.{ @as(f64, 10), @as(f64, 20), @as(f64, 12) });
        if (st_pair != 42 or st_triple != 42) return error.Unexpected;

        const pa1 = try m.pickArity(@as(f64, 7));
        if (pa1 != 70) return error.Unexpected;
        const pa2 = try m.pickArityAlloc(tracked_alloc, .{ @as(f64, 7), @as(f64, 9) });
        defer js.freeDecoded([]const u8, tracked_alloc, pa2);
        if (!std.mem.eql(u8, pa2, "opt2:7,9")) return error.Unexpected;

        // Buf.from via unified comptime dispatch AND semantic names
        const b1 = try m.Buf.from("Zig");
        defer b1.deinit();
        const b1_hex = try b1.toHexAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, b1_hex);
        if (!std.mem.eql(u8, b1_hex, "5a6967") or (try b1.byteLength()) != 3) return error.Unexpected;

        const b2 = try m.Buf.from(.{ "deadbeef", .hex });
        defer b2.deinit();
        const b2_hex = try b2.toHexAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, b2_hex);
        if (!std.mem.eql(u8, b2_hex, "deadbeef") or (try b2.byteLength()) != 4) return error.Unexpected;

        const raw_u8 = try js.Uint8Array.fromSlice(&[_]u8{ 0xca, 0xfe });
        defer raw_u8.deinit();
        const b3 = try m.Buf.fromUint8Array(raw_u8);
        defer b3.deinit();
        const b3_hex = try b3.toHexAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, b3_hex);
        if (!std.mem.eql(u8, b3_hex, "cafe")) return error.Unexpected;

        const b4 = try m.Buf.from(&[_]f64{ 1, 2, 255 });
        defer b4.deinit();
        const b4_hex = try b4.toHexAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, b4_hex);
        if (!std.mem.eql(u8, b4_hex, "0102ff")) return error.Unexpected;

        // readFile overloads (binary callback, literal .utf8 + "utf8", missing file error, ReadOptions union)
        const ReadState = struct {
            buf: *[96]u8,
            len: *usize,

            fn append(self: *@This(), s: []const u8) void {
                const avail = self.buf.len - self.len.*;
                const n = @min(avail, s.len);
                @memcpy(self.buf[self.len.* .. self.len.* + n], s[0..n]);
                self.len.* += n;
            }

            fn onBytes(self: *@This(), err: ?[]const u8, data: js.Uint8Array) !void {
                if (err != null) return error.Unexpected;
                self.append(if ((try data.byteLength()) == 6) "bin6|" else "bad|");
            }

            fn onUtf8(self: *@This(), err: ?[]const u8, text: []const u8) void {
                if (err) |e| {
                    self.append(e);
                    self.append("|");
                } else {
                    self.append(text);
                    self.append("|");
                }
            }

            fn onOpts(self: *@This(), err: ?[]const u8, payload: m.ReadData) void {
                if (err != null) {
                    self.append("err");
                    return;
                }
                switch (payload) {
                    .str => |s| self.append(s),
                    .uint8_array => self.append("u8a"),
                }
            }
        };
        var rs: ReadState = .{ .buf = &read_summary, .len = &read_len };
        try m.readFile(.{ "hello.txt", js.closure(&rs, ReadState.onBytes) });
        try m.readFile(.{ "hello.txt", .utf8, js.closure(&rs, ReadState.onUtf8) });
        try m.readFile(.{ "missing.txt", "utf8", js.closure(&rs, ReadState.onUtf8) });
        try m.readFileWithOpts("hello.txt", .{ .encoding = "utf8" }, js.closure(&rs, ReadState.onOpts));

        // CJS `export = callableToolkit` overloaded call signatures + variadic namespace helper
        const tk_str = try cjs.callableToolkitAlloc(tracked_alloc, "zig");
        defer js.freeDecoded([]const u8, tracked_alloc, tk_str);
        if (!std.mem.eql(u8, tk_str, "TK:zig")) return error.Unexpected;

        const tk_num = try cjs.CallableToolkit.call(.{ 19, 23 });
        if (tk_num != 42) return error.Unexpected;

        const tk_join = try cjs.joinPartsAlloc(tracked_alloc, "-", .{ "m3", "3a", "ok" });
        defer js.freeDecoded([]const u8, tracked_alloc, tk_join);
        if (!std.mem.eql(u8, tk_join, "m3-3a-ok")) return error.Unexpected;

        const tk_join_sl = try cjs.CallableToolkit.joinPartsSliceAlloc(tracked_alloc, ":", &.{ "c", "j", "s" });
        defer js.freeDecoded([]const u8, tracked_alloc, tk_join_sl);
        if (!std.mem.eql(u8, tk_join_sl, "c:j:s")) return error.Unexpected;
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return std.fmt.allocPrint(out_alloc, "reads={s}", .{read_summary[0..read_len]});
}

var stateless_emitter_hits = std.atomic.Value(usize).init(0);
var stateless_deferred_ok = std.atomic.Value(bool).init(false);

fn statelessEmitterOnData(chunk: []const u8) void {
    if (std.mem.eql(u8, chunk, "a")) {
        _ = stateless_emitter_hits.fetchAdd(1, .acq_rel);
    } else if (std.mem.eql(u8, chunk, "b")) {
        _ = stateless_emitter_hits.fetchAdd(100, .acq_rel);
    }
}

fn statelessDeferredTickCb(payload: []const u8) void {
    stateless_deferred_ok.store(std.mem.eql(u8, payload, "tick:stateless-fn"), .release);
}

fn bareTriple(x: f64) f64 {
    return x * 3;
}

// 2. MiniEmitter constructor overloads + literal `on`/`off` overloads + stateless bare `fn` identity + `js.persistentClosure`
pub fn exerciseEmitterLiteralOverloadsAndReusableClosures(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var events_buf: [64]u8 = undefined;
    var events_len: usize = 0;
    stateless_emitter_hits.store(0, .release);

    {
        const e0 = try m.MiniEmitter.init(.{});
        defer e0.deinit();
        const l0 = try e0.labelAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, l0);
        if (!std.mem.eql(u8, l0, "default:10")) return error.Unexpected;

        const e1 = try m.MiniEmitter.init(24);
        defer e1.deinit();
        const l1 = try e1.labelAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, l1);
        if (!std.mem.eql(u8, l1, "anon:24")) return error.Unexpected;

        const bus = try m.MiniEmitter.init(.{ "bus", 64 });
        defer bus.deinit();
        const l2 = try bus.labelAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, l2);
        if (!std.mem.eql(u8, l2, "bus:64")) return error.Unexpected;

        const BusTrace = struct {
            buf: *[64]u8,
            len: *usize,

            fn push(self: *@This(), s: []const u8) void {
                const n = @min(self.buf.len - self.len.*, s.len);
                @memcpy(self.buf[self.len.* .. self.len.* + n], s[0..n]);
                self.len.* += n;
            }

            fn onOpen(self: *@This()) void {
                self.push("[open]");
            }

            fn onData(self: *@This(), chunk: []const u8) void {
                self.push("<");
                self.push(chunk);
                self.push(">");
            }

            fn onClose(self: *@This()) void {
                self.push("[close]");
            }
        };

        var trace: BusTrace = .{ .buf = &events_buf, .len = &events_len };
        var open_cb = try js.Closure(*BusTrace, fn () void).tryInit(&trace, BusTrace.onOpen);
        defer open_cb.deinit();
        var data_cb = try js.persistentClosure(&trace, BusTrace.onData);
        defer data_cb.deinit();
        var close_cb = try js.persistentClosure(&trace, &BusTrace.onClose);
        defer close_cb.deinit();

        if (js.activeCallbackCount() != cbs_before + 3) return error.Unexpected;

        const r_open = try bus.on(.{ .open, &open_cb });
        r_open.deinit();
        const r_data = try bus.on(.{ .data, &data_cb });
        r_data.deinit();
        const r_close = try bus.on(.{ "close", &close_cb });
        r_close.deinit();

        // H1: Stateless bare `fn` passed to `bus.on` survives after return, uses 0 dynamic slots,
        // and preserves JS Function identity for `bus.off`!
        const r_stateless_on = try bus.on(.{ .data, statelessEmitterOnData });
        r_stateless_on.deinit();
        if (js.activeCallbackCount() != cbs_before + 3) return error.Unexpected;

        try bus.emitOpen();
        try bus.emitData("a");
        if (stateless_emitter_hits.load(.acquire) != 1) return error.Unexpected;

        const r_stateless_off = try bus.off(.{ .data, statelessEmitterOnData });
        r_stateless_off.deinit();

        try bus.emitData("b");
        if (stateless_emitter_hits.load(.acquire) != 1) return error.Unexpected;
        try bus.emitClose();
        try bus.clearAll();
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return std.fmt.allocPrint(out_alloc, "{s}", .{events_buf[0..events_len]});
}

// 3. Variadic rest parameters (`...args: any[]` and typed `...nums: number[]`) via tuple, single arg, empty `.{}`, and `*Slice`
pub fn exerciseVariadicRestParameters(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var cf_tup_copy: []u8 = &.{};
    defer if (cf_tup_copy.len > 0) out_alloc.free(cf_tup_copy);

    {
        const cf_tup = try m.consoleFormatAlloc(tracked_alloc, "log", .{ "host", 8080, true });
        defer js.freeDecoded([]const u8, tracked_alloc, cf_tup);
        if (!std.mem.eql(u8, cf_tup, "log[3]=string:host,number:8080,boolean:true")) return error.Unexpected;

        const cf_one = try m.consoleFormatAlloc(tracked_alloc, "one", 99);
        defer js.freeDecoded([]const u8, tracked_alloc, cf_one);
        if (!std.mem.eql(u8, cf_one, "one[1]=number:99")) return error.Unexpected;

        const cf_empty = try m.consoleFormatAlloc(tracked_alloc, "none", .{});
        defer js.freeDecoded([]const u8, tracked_alloc, cf_empty);
        if (!std.mem.eql(u8, cf_empty, "none[0]=")) return error.Unexpected;

        const raw_str = try js.toJsRef([]const u8, "dyn");
        defer raw_str.deinit();
        const raw_num = try js.toJsRef(f64, 7);
        defer raw_num.deinit();
        const cf_slice = try m.consoleFormatSliceAlloc(tracked_alloc, "sl", &[_]js.Any{ raw_str, raw_num });
        defer js.freeDecoded([]const u8, tracked_alloc, cf_slice);
        if (!std.mem.eql(u8, cf_slice, "sl[2]=string:dyn,number:7")) return error.Unexpected;

        const s1 = try m.sumScaled(2.0, .{ 10, 20, 5 });
        const s2 = try m.sumScaled(null, .{ 3, 4 });
        const s3 = try m.sumScaled(5.0, .{});
        const s4 = try m.sumScaledSlice(10.0, &[_]f64{ 1, 2, 3 });
        if (s1 != 70 or s2 != 7 or s3 != 0 or s4 != 60) return error.Unexpected;

        cf_tup_copy = try std.fmt.allocPrint(out_alloc, "{s}|sums={d},{d},{d},{d}", .{
            cf_tup,
            @as(i64, @intFromFloat(s1)),
            @as(i64, @intFromFloat(s2)),
            @as(i64, @intFromFloat(s3)),
            @as(i64, @intFromFloat(s4)),
        });
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    const res = cf_tup_copy;
    cf_tup_copy = &.{};
    return res;
}

fn bareIsPositive(val: f64) bool {
    return val > 0;
}

fn bareMapTag(item: []const u8, idx: f64) ![]const u8 {
    _ = idx;
    return if (std.mem.eql(u8, item, "alpha")) "A" else "B";
}

fn fallibleDoubler(x: f64) error{NegativeInput}!f64 {
    if (x < 0) return error.NegativeInput;
    return x * 2;
}

// 4. Callbacks (`bare fn`, `closure`, `onceClosure` deferred invocation, `!T` error propagation) + HOF `Callable` / `CallableWithThis`
pub fn exerciseCallbacksAndHigherOrderCallables(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var tick_seen: [32]u8 = undefined;
    var tick_len: usize = 0;
    var kept_seen: f64 = -1;
    var hof_text_out: [32]u8 = undefined;
    var hof_text_len: usize = 0;
    var hof_this_sum: f64 = 0;

    {
        const mapped = try m.mapStringsAlloc(tracked_alloc, &.{ "alpha", "beta" }, bareMapTag);
        defer js.freeDecoded([]const []const u8, tracked_alloc, mapped);
        if (mapped.len != 2 or !std.mem.eql(u8, mapped[0], "A") or !std.mem.eql(u8, mapped[1], "B")) {
            return error.Unexpected;
        }

        const KeptCtx = struct {
            out: *f64,
            fn onDone(self: *@This(), kept: f64) void {
                self.out.* = kept;
            }
        };
        var kctx: KeptCtx = .{ .out = &kept_seen };
        const filtered = try m.filterNumbersAlloc(tracked_alloc, &.{ -3, 4, 0, 9 }, bareIsPositive, js.closure(&kctx, KeptCtx.onDone));
        defer js.freeDecoded([]const f64, tracked_alloc, filtered);
        if (filtered.len != 2 or filtered[0] != 4 or filtered[1] != 9 or kept_seen != 2) {
            return error.Unexpected;
        }

        // Deferred one-shot callback (`onceClosure`) + returned HOF `Callable(fn () void)`
        const TickCtx = struct {
            buf: *[32]u8,
            len: *usize,
            fn onTick(self: *@This(), payload: []const u8) void {
                const n = @min(self.buf.len, payload.len);
                @memcpy(self.buf[0..n], payload[0..n]);
                self.len.* = n;
            }
        };
        var tctx: TickCtx = .{ .buf = &tick_seen, .len = &tick_len };
        const trigger = try m.deferTick("ready", js.onceClosure(&tctx, TickCtx.onTick));
        defer trigger.deinit();
        if (js.activeCallbackCount() != cbs_before + 1) return error.Unexpected;
        try trigger.call(.{});
        if (js.activeCallbackCount() != cbs_before) return error.Unexpected;
        if (!std.mem.eql(u8, tick_seen[0..tick_len], "tick:ready")) return error.Unexpected;

        // `!T` Zig callback error propagation into JS `try/catch`
        const ok_res = try m.catchCallbackErrorAlloc(tracked_alloc, 6, fallibleDoubler);
        defer js.freeDecoded([]const u8, tracked_alloc, ok_res);
        if (!std.mem.eql(u8, ok_res, "ok:12")) return error.Unexpected;

        const err_res = try m.catchCallbackErrorAlloc(tracked_alloc, -4, fallibleDoubler);
        defer js.freeDecoded([]const u8, tracked_alloc, err_res);
        if (!std.mem.eql(u8, err_res, "caught:Negative input") and !std.mem.eql(u8, err_res, "caught:NegativeInput")) {
            return error.Unexpected;
        }

        // HOF `Callable` & `CallableWithThis`
        const pfx = try m.makePrefixer("HTTP");
        defer pfx.deinit();
        const pfx_str = try pfx.callAlloc(tracked_alloc, .{204});
        defer js.freeDecoded([]const u8, tracked_alloc, pfx_str);
        @memcpy(hof_text_out[0..pfx_str.len], pfx_str);
        hof_text_len = pfx_str.len;

        const adder = try m.makeScaledBoxAdder(3);
        defer adder.deinit();
        hof_this_sum = try adder.call(.{ .count = 100 }, .{7});
        if (hof_this_sum != 121) return error.Unexpected;

        // H1: Deferred stateless bare `fn` (survives after `deferTick` returns, 0 dynamic callback slots) + `Callable.fromFn`
        stateless_deferred_ok.store(false, .release);
        const st_trigger = try m.deferTick("stateless-fn", statelessDeferredTickCb);
        defer st_trigger.deinit();
        if (js.activeCallbackCount() != cbs_before) return error.Unexpected;
        try st_trigger.call(.{});
        if (!stateless_deferred_ok.load(.acquire)) return error.Unexpected;

        const fn_callable = try js.Callable(fn (f64) f64).fromFn(bareTriple);
        defer fn_callable.deinit();
        if ((try fn_callable.call(.{14})) != 42) return error.Unexpected;
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return std.fmt.allocPrint(out_alloc, "{s}|{s}|{d}", .{
        tick_seen[0..tick_len],
        hof_text_out[0..hof_text_len],
        @as(i64, @intFromFloat(hof_this_sum)),
    });
}

fn statelessCounterThisCb(self_cnt: m.LiveCounter, mult: f64) !f64 {
    return (try self_cnt.count()) * mult;
}

fn statelessBoxThisCb(self_box: m.CounterBox, delta: f64) f64 {
    return self_box.count + delta;
}

// 5. Explicit `this: T` vs `this: void` parameters on standalone functions and callbacks (stateless & stateful)
pub fn exerciseExplicitThisParameters(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var r_inc: f64 = 0;
    var r_void: f64 = 0;
    var r_cb_cls: f64 = 0;
    var r_cb_stateful: f64 = 0;
    var r_cb_box: f64 = 0;

    {
        const lc = try m.LiveCounter.init(10);
        defer lc.deinit();

        r_inc = try m.incrementLiveCounter(lc, 5);
        if (r_inc != 15 or (try lc.count()) != 15) return error.Unexpected;

        r_void = try m.detachedDouble(21);
        if (r_void != 42) return error.Unexpected;

        r_cb_cls = try m.invokeWithLiveCounterThis(lc, 3, statelessCounterThisCb);
        if (r_cb_cls != 45) return error.Unexpected;

        const BiasCtx = struct {
            bias: f64,
            fn apply(ctx: *@This(), self_cnt: m.LiveCounter, mult: f64) !f64 {
                return (try self_cnt.count()) * mult + ctx.bias;
            }
        };
        var bctx: BiasCtx = .{ .bias = 7 };
        var this_cl = try js.ClosureWithThis(*BiasCtx, fn (m.LiveCounter, f64) js.CallError!f64).tryInit(&bctx, BiasCtx.apply);
        defer this_cl.deinit();
        r_cb_stateful = try m.invokeWithLiveCounterThis(lc, 2, &this_cl);
        if (r_cb_stateful != 37) return error.Unexpected;

        r_cb_box = try m.invokeWithBoxThis(.{ .count = 50 }, 9, statelessBoxThisCb);
        if (r_cb_box != 59) return error.Unexpected;
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return std.fmt.allocPrint(out_alloc, "inc={d}|void={d}|cls={d}|st={d}|box={d}", .{
        @as(i64, @intFromFloat(r_inc)),
        @as(i64, @intFromFloat(r_void)),
        @as(i64, @intFromFloat(r_cb_cls)),
        @as(i64, @intFromFloat(r_cb_stateful)),
        @as(i64, @intFromFloat(r_cb_box)),
    });
}

// 6. Type predicates (`x is T` -> `as*`, `asserts x is T` -> `ensure*`, `this is T`, `asserts this is T`, `asserts cond`)
pub fn exerciseTypePredicatesAndNarrowing(out_alloc: std.mem.Allocator) ![]const u8 {
    comptime {
        if (@hasDecl(m, "ensurePositiveFlag")) @compileError("condition-only asserts should not synthesize ensure*");
    }

    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var eval_val: f64 = 0;
    var send_copy: [32]u8 = undefined;
    var send_len: usize = 0;

    {
        const bin = try m.BinaryExpr.init("+", 18, 24);
        defer bin.deinit();
        const plain = try m.AstNode.init("ident");
        defer plain.deinit();

        const bin_as_node = bin.as(m.AstNode);
        if (!(try m.isBinaryExpr(bin_as_node))) return error.Unexpected;
        if (try m.isBinaryExpr(plain)) return error.Unexpected;

        const narrowed_bin = (try m.asBinaryExpr(bin_as_node)) orelse return error.Unexpected;
        defer narrowed_bin.deinit();
        eval_val = try narrowed_bin.eval();
        if (eval_val != 42) return error.Unexpected;

        if ((try m.asBinaryExpr(plain)) != null) return error.Unexpected;

        const ensured_bin = try m.ensureBinaryExpr(bin_as_node);
        defer ensured_bin.deinit();
        if ((try ensured_bin.eval()) != 42) return error.Unexpected;

        if (m.ensureBinaryExpr(plain)) |unexpected| {
            unexpected.deinit();
            return error.Unexpected;
        } else |err| {
            if (err != error.TypeError) return error.Unexpected;
            if (js.takeLastError()) |exc| exc.deinit() else return error.Unexpected;
        }

        // `val is string` narrowing `js.Unknown` -> `?[]const u8`
        const unk_s = try m.makeUnknownValue(.str);
        defer unk_s.deinit();
        const unk_n = try m.makeUnknownValue(.num);
        defer unk_n.deinit();

        const narrowed_s = (try m.asStringPayloadAlloc(tracked_alloc, unk_s)) orelse return error.Unexpected;
        defer js.freeDecoded([]const u8, tracked_alloc, narrowed_s);
        if (!std.mem.eql(u8, narrowed_s, "narrowed-hello")) return error.Unexpected;
        if ((try m.asStringPayloadAlloc(tracked_alloc, unk_n)) != null) return error.Unexpected;

        // `asserts cond`
        try m.assertPositiveFlag(true, "boot");
        if (m.assertPositiveFlag(false, "gate")) |_| {
            return error.Unexpected;
        } else |err| {
            if (err != error.RangeError) return error.Unexpected;
            if (js.takeLastError()) |exc| exc.deinit() else return error.Unexpected;
        }

        // `this is ReadyChannel` & `asserts this is ReadyChannel`
        const ch_ready = try m.openChannel(true, "tok7");
        defer ch_ready.deinit();
        const ch_closed = try m.openChannel(false, "none");
        defer ch_closed.deinit();

        if ((try ch_closed.asReady()) != null) return error.Unexpected;
        if (ch_closed.ensureReady()) |ur| {
            ur.deinit();
            return error.Unexpected;
        } else |err| {
            if (err != error.TypeError) return error.Unexpected;
            if (js.takeLastError()) |exc| exc.deinit() else return error.Unexpected;
        }

        const r1 = (try ch_ready.asReady()) orelse return error.Unexpected;
        defer r1.deinit();
        const r2 = try ch_ready.ensureReady();
        defer r2.deinit();
        const sent = try r2.sendAlloc(tracked_alloc, "ping");
        defer js.freeDecoded([]const u8, tracked_alloc, sent);
        @memcpy(send_copy[0..sent.len], sent);
        send_len = sent.len;
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return std.fmt.allocPrint(out_alloc, "eval={d}|sent={s}", .{
        @as(i64, @intFromFloat(eval_val)),
        send_copy[0..send_len],
    });
}
