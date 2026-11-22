const std = @import("std");
const zigar = @import("zigar");

const js = zigar.js;
const Ref = js.Ref;

var gpa: zigar.mem.TrackingAllocator = .init(zigar.mem.allocator);
const tracked_alloc = gpa.allocator();

pub const Point = struct {
    x: i32,
    y: i32,
};

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
    return gpa.activeCount();
}

// ---------------------------------------------------------------------------
// 1. Promise(T): resolve/reject, .await() borrowing, types, concurrency, .then()
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// 2. Binary Views: Buffer, TypedArrays, ArrayBuffer, SharedArrayBuffer, DataView
// ---------------------------------------------------------------------------

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

pub fn bufferOutOfBoundsWrite(buf: js.Buffer) !bool {
    defer buf.deinit();
    const len = try buf.byteLength();
    const extra = try tracked_alloc.alloc(u8, len + 1);
    defer tracked_alloc.free(extra);
    @memset(extra, 0xaa);
    if (buf.writeFrom(extra)) |_| {
        return false;
    } else |err| {
        return err == error.JsException;
    }
}

pub fn roundtripBufferUtf8(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const buf = try js.Buffer.fromString(text);
    defer buf.deinit();
    return buf.toStringAlloc(allocator);
}

pub fn typedArraysShowcase() !f64 {
    // 0-length Uint8Array + Uint8ClampedArray
    const empty_u8 = try js.Uint8Array.fromSlice(&.{});
    defer empty_u8.deinit();
    if ((try empty_u8.len()) != 0) return error.JsException;
    const empty_copy = try empty_u8.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(empty_copy);
    if (empty_copy.len != 0) return error.JsException;

    const clamped = try js.Uint8ClampedArray.init(3);
    defer clamped.deinit();
    try clamped.set(0, 250);
    if ((try clamped.get(0)) != 250) return error.JsException;

    // Int32Array bulk roundtrip
    const ints = [_]i32{ -100, 25, 75, 1000 };
    const i32_arr = try js.Int32Array.fromSlice(&ints);
    defer i32_arr.deinit();
    try i32_arr.set(1, 50);
    const owned_ints = try i32_arr.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(owned_ints);
    var int_sum: i64 = 0;
    for (owned_ints) |v| int_sum += v;

    // Float64Array bulk roundtrip
    const floats = [_]f64{ 1.5, 2.25, -0.75 };
    const f64_arr = try js.Float64Array.fromSlice(&floats);
    defer f64_arr.deinit();
    const owned_floats = try f64_arr.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(owned_floats);
    var float_sum: f64 = 0;
    for (owned_floats) |v| float_sum += v;

    // BigUint64Array bulk roundtrip
    const u64s = [_]u64{ 10, 20, 0x0000_0001_0000_0000 };
    const u64_arr = try js.BigUint64Array.fromSlice(&u64s);
    defer u64_arr.deinit();
    if ((try u64_arr.get(2)) != 0x0000_0001_0000_0000) return error.JsException;

    return @as(f64, @floatFromInt(int_sum)) + float_sum;
}

pub fn sumUint8Subarray(view: js.Uint8Array) !u64 {
    defer view.deinit();
    const offset = try view.byteOffset();
    const ab = try view.buffer();
    defer ab.deinit();
    if ((try ab.byteLength()) < offset + (try view.byteLength())) return error.JsException;
    const owned = try view.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(owned);
    var total: u64 = 0;
    for (owned) |b| total += b;
    return total;
}

pub fn arrayBufferAndSharedRoundtrip(payload_size: usize) !u64 {
    const src = try tracked_alloc.alloc(u8, payload_size);
    defer tracked_alloc.free(src);
    for (src, 0..) |*b, idx| {
        b.* = @truncate((idx *% 31 +% 7) & 0xff);
    }

    const ab = try js.ArrayBuffer.fromSlice(src);
    defer ab.deinit();
    const sliced_ab = try ab.slice(4, @intCast(payload_size - 4));
    defer sliced_ab.deinit();

    const sab = try js.SharedArrayBuffer.init(sliced_ab.byteLength() catch return error.JsException);
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

    // DataView with non-zero offset over ArrayBuffer
    const dv = try js.DataView.init(ab, 8, 24);
    defer dv.deinit();
    if ((try dv.byteOffset()) != 8 or (try dv.byteLength()) != 24) return error.JsException;
    const backing = try dv.buffer();
    defer backing.deinit();
    if (!backing.eql(ab)) return error.JsException;

    try dv.setInt32(0, -123456, true);
    try dv.setInt32(4, 654321, false);
    try dv.setFloat64(8, 3.125, true);
    try dv.setBigUint64(16, 0x0102030405060708, true);

    if ((try dv.getInt32(0, true)) != -123456) return error.JsException;
    if ((try dv.getInt32(4, false)) != 654321) return error.JsException;
    if ((try dv.getFloat64(8, true)) != 3.125) return error.JsException;
    if ((try dv.getBigUint64(16, true)) != 0x0102030405060708) return error.JsException;

    return checksum;
}

// ---------------------------------------------------------------------------
// 3. Collections & Intrinsics: Array, Map, Set, Record, BigInt, Date, RegExp
// ---------------------------------------------------------------------------

pub fn arrayRoundtripAndMidErrorCleanup(bad_mixed_str_arr: js.Array([]const u8)) !i32 {
    defer bad_mixed_str_arr.deinit();

    const nums = [_]i32{ 10, 20, 30 };
    const arr = try js.Array(i32).fromSlice(&nums);
    defer arr.deinit();
    if (!try js.Array(i32).isArray(arr)) return error.JsException;
    _ = try arr.push(40);
    try arr.set(0, 5);
    const popped = (try arr.pop()) orelse return error.JsException;
    if (popped != 40) return error.JsException;

    const owned = try arr.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(owned);

    var sum: i32 = 0;
    const iter = try arr.iterator();
    defer iter.deinit();
    while (try iter.next()) |item| {
        sum += item;
    }

    // Verify mid-array element conversion error frees already-allocated []const u8 elements!
    const allocs_before = gpa.activeCount();
    const handles_before = js.activeHandleCount();
    if (bad_mixed_str_arr.toOwnedSlice(tracked_alloc)) |unexpected_slice| {
        for (unexpected_slice) |s| tracked_alloc.free(s);
        tracked_alloc.free(unexpected_slice);
        return error.JsException;
    } else |err| {
        if (err != error.JsException) return err;
        js.clearLastError();
    }
    if (gpa.activeCount() != allocs_before) return error.JsException;
    if (js.activeHandleCount() != handles_before) return error.JsException;

    return sum + @as(i32, @intCast(owned.len));
}

pub fn collectionsMapSetRecordShowcase(allocator: std.mem.Allocator) ![]u8 {
    // Map([]const u8, ?i32) including explicit null value vs missing key
    const m = try js.Map([]const u8, ?i32).init();
    defer m.deinit();
    try m.set("alpha", 10);
    try m.set("beta", null);
    try m.set("gamma", 30);
    if ((try m.size()) != 3) return error.JsException;
    if (!try m.has("beta")) return error.JsException;

    const got_alpha = (try m.get("alpha")) orelse return error.JsException;
    if (got_alpha == null or got_alpha.? != 10) return error.JsException;
    const got_beta = (try m.get("beta")) orelse return error.JsException;
    if (got_beta != null) return error.JsException;
    if ((try m.get("missing")) != null) return error.JsException;

    var entry_sum: i32 = 0;
    const entries_it = try m.entries();
    defer entries_it.deinit();
    while (try entries_it.nextAlloc(tracked_alloc)) |entry| {
        defer tracked_alloc.free(entry[0]);
        if (entry[1]) |v| entry_sum += v;
    }
    _ = try m.delete("alpha");

    // Set(i32)
    const s = try js.Set(i32).init();
    defer s.deinit();
    try s.add(7);
    try s.add(7);
    try s.add(11);
    if ((try s.size()) != 2 or !(try s.has(7))) return error.JsException;
    var set_sum: i32 = 0;
    const set_it = try s.values();
    defer set_it.deinit();
    while (try set_it.next()) |v| set_sum += v;

    // Record([]const u8, i32)
    const rec = try js.Record([]const u8, i32).init();
    defer rec.deinit();
    try rec.set("k1", 100);
    try rec.set("k2", 200);
    if (!(try rec.has("k1"))) return error.JsException;
    const keys = try rec.keysAlloc(tracked_alloc);
    defer {
        for (keys) |k| tracked_alloc.free(k);
        tracked_alloc.free(keys);
    }
    const k1_val = (try rec.get("k1")) orelse 0;
    _ = try rec.delete("k1");

    return std.fmt.allocPrint(
        allocator,
        "entry_sum={d}|map_rem={d}|set_sum={d}|keys={d}|k1={d}|k1_after={}",
        .{ entry_sum, try m.size(), set_sum, keys.len, k1_val, try rec.has("k1") },
    );
}

pub fn bigIntDateRegExpShowcase(allocator: std.mem.Allocator) ![]u8 {
    // 64-bit & 128-bit exact bounds + Overflow checks
    const bi_i64_min = try js.BigInt.fromI64(std.math.minInt(i64));
    defer bi_i64_min.deinit();
    if ((try bi_i64_min.toI64()) != std.math.minInt(i64)) return error.JsException;
    if (bi_i64_min.toU64()) |_| return error.JsException else |err| {
        if (err != error.Overflow) return err;
    }

    const bi_u64_max = try js.BigInt.fromU64(std.math.maxInt(u64));
    defer bi_u64_max.deinit();
    if ((try bi_u64_max.toU64()) != std.math.maxInt(u64)) return error.JsException;
    if (bi_u64_max.toI64()) |_| return error.JsException else |err| {
        if (err != error.Overflow) return err;
    }

    const bi_i128_min = try js.BigInt.fromI128(std.math.minInt(i128));
    defer bi_i128_min.deinit();
    if ((try bi_i128_min.toI128()) != std.math.minInt(i128)) return error.JsException;
    if (bi_i128_min.toI64()) |_| return error.JsException else |err| {
        if (err != error.Overflow) return err;
    }

    const bi_u128_max = try js.BigInt.fromU128(std.math.maxInt(u128));
    defer bi_u128_max.deinit();
    if ((try bi_u128_max.toU128()) != std.math.maxInt(u128)) return error.JsException;

    // 256-bit hex string roundtrip
    const hex256 = "fedcba98765432100123456789abcdeffedcba98765432100123456789abcdef";
    const bi_256 = try js.BigInt.fromString("0x" ++ hex256);
    defer bi_256.deinit();
    if (bi_256.toU128()) |_| return error.JsException else |err| {
        if (err != error.Overflow) return err;
    }
    const rendered_256 = try bi_256.toStringAlloc(tracked_alloc, 16);
    defer tracked_alloc.free(rendered_256);
    if (!std.mem.eql(u8, rendered_256, hex256)) return error.JsException;

    // Date
    const now_ms = try js.Date.now();
    if (!(now_ms > 1_600_000_000_000.0)) return error.JsException;
    const dt = try js.Date.fromIsoString("2026-05-01T12:30:00.000Z");
    defer dt.deinit();
    const iso = try dt.toIsoStringAlloc(tracked_alloc);
    defer tracked_alloc.free(iso);
    if (js.Date.fromIsoString("not-a-valid-date")) |bad_dt| {
        bad_dt.deinit();
        return error.JsException;
    } else |err| {
        if (err != error.JsException) return err;
        js.clearLastError();
    }

    // RegExp
    const re = try js.RegExp.init("^zigar-[0-9]+$", "i");
    defer re.deinit();
    const matched = try re.testMatch("ZIGAR-38");
    const non_matched = try re.@"test"("other");
    const flags = try re.flagsAlloc(tracked_alloc);
    defer tracked_alloc.free(flags);

    return std.fmt.allocPrint(allocator, "iso={s}|match={}|nomatch={}|flags={s}", .{
        iso,
        matched,
        non_matched,
        flags,
    });
}

// ---------------------------------------------------------------------------
// 4. Iteration Protocols: Iterator(T) and AsyncIterator(T)
// ---------------------------------------------------------------------------

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
