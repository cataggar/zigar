const std = @import("std");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const m3_esm = gen.m3_esm;
const m3_cjs = gen.m3_cjs;
const fixture = gen.globals;

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

pub fn liveZigAllocs() usize {
    return live_allocs.load(.acquire);
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

fn checkInvariants(handles_before: u32, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (live_allocs.load(.acquire) != allocs_before) return error.Unexpected;
    if (js.hasLastError()) return error.Unexpected;
}

// 1. Primitives: void, never (throwing), bool, f64, i64, BigInt (>64-bit & >128-bit),
//    []const u8 + *Alloc, String zero-copy handle, Symbol & unique symbol, Object/Any/Unknown
pub fn exercisePrimitives(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    if (!js.has_host) return error.HostUnavailable;
    if (m3_esm.SMALL_BIGINT != -99_999_000_111) return error.Unexpected;
    if (m3_esm.HUGE_BIGINT != (@as(i128, 1) << 100) + 7) return error.Unexpected;
    if (!std.mem.eql(u8, m3_esm.ULTRA_BIGINT, "999999999999999999999999999999999999999999")) {
        return error.Unexpected;
    }

    var summary: []u8 = undefined;
    {
        // void
        try m3_esm.recordVoid(12.5);
        try m3_esm.recordVoid(7.5);
        const acc = try m3_esm.getVoidAcc();
        if (acc != 20.0) return error.Unexpected;

        // never throwing JS function -> CallError!noreturn surfaces JS error + captured message
        var caught_msg: []u8 = &.{};
        if (m3_esm.alwaysThrow("boom")) |_| {
            unreachable;
        } else |err| {
            if (err != error.JsException and err != error.TypeError) return err;
            const exc = js.takeLastError() orelse return error.Unexpected;
            defer exc.deinit();
            const msg_opt = try exc.message(tracked_alloc);
            caught_msg = if (msg_opt) |m| @constCast(m) else return error.Unexpected;
        }
        defer tracked_alloc.free(caught_msg);
        if (!std.mem.eql(u8, caught_msg, "never-error:boom")) return error.Unexpected;

        // bool, f64, i64 bigint, []const u8 UTF-8 + *Alloc companion
        const prim_default = try m3_esm.formatPrimitives(true, 3.25, m3_esm.SMALL_BIGINT, "zig⚡js");
        defer zigar.mem.allocator.free(prim_default);
        const prim_tracked = try m3_esm.formatPrimitivesAlloc(tracked_alloc, false, -1.5, 9_007_199_254_740_993, "alloc-ok");
        defer js.freeDecoded([]const u8, tracked_alloc, prim_tracked);
        if (!std.mem.eql(u8, prim_default, "true|3.25|-99999000111|zig⚡js")) return error.Unexpected;
        if (!std.mem.eql(u8, prim_tracked, "false|-1.50|9007199254740993|alloc-ok")) return error.Unexpected;

        // BigInt > 64-bit (2^100 + 7) & > 128-bit (ULTRA_BIGINT)
        const big_in = try js.BigInt.fromI128(m3_esm.HUGE_BIGINT);
        defer big_in.deinit();
        const big_out = try m3_esm.addHugeBigInt(big_in, 35);
        defer big_out.deinit();
        if ((try big_out.toI128()) != (@as(i128, 1) << 100) + 42) return error.Unexpected;

        const ultra = try js.BigInt.fromString(m3_esm.ULTRA_BIGINT);
        defer ultra.deinit();
        const ultra_plus = try m3_esm.addHugeBigInt(ultra, 1);
        defer ultra_plus.deinit();
        const ultra_str = try ultra_plus.toStringAlloc(tracked_alloc, 10);
        defer tracked_alloc.free(ultra_str);
        if (!std.mem.eql(u8, ultra_str, "1000000000000000000000000000000000000000000")) {
            return error.Unexpected;
        }

        // js.String zero-copy handle: .byteLen() vs .utf16Len() vs .toSliceAlloc()
        const js_str_in = try js.String.fromSlice("hi");
        defer js_str_in.deinit();
        const js_str_out = try m3_esm.borrowJsString(js_str_in); // "hi🚀" (6 UTF-8 bytes, 4 UTF-16 code units)
        defer js_str_out.deinit();
        const byte_len = try js_str_out.byteLen();
        const u16_len = try js_str_out.utf16Len();
        const str_slice = try js_str_out.toSliceAlloc(tracked_alloc);
        defer tracked_alloc.free(str_slice);
        if (byte_len != 6 or u16_len != 4 or !std.mem.eql(u8, str_slice, "hi🚀")) {
            return error.Unexpected;
        }

        // Symbol & unique symbol global equality
        const mod_tok = try m3_esm.UNIQUE_TOKEN.get();
        defer mod_tok.deinit();
        const reg_tok = try js.symbolFor("zigar.m3.unique_token");
        defer reg_tok.deinit();
        const fresh_sym = try js.createSymbol("ephemeral");
        defer fresh_sym.deinit();
        if (!mod_tok.eql(reg_tok)) return error.Unexpected;
        if (mod_tok.eql(fresh_sym)) return error.Unexpected;
        if (!(try m3_esm.checkUniqueSymbol(reg_tok))) return error.Unexpected;
        if (try m3_esm.checkUniqueSymbol(fresh_sym)) return error.Unexpected;

        // Object, Any, Unknown roundtrip
        const rec = try js.Record([]const u8, i32).init();
        defer rec.deinit();
        try rec.set("k", 77);
        const obj_in: js.Object = rec.toRef();
        const any_in = try js.toJsRef([]const u8, "any-payload");
        defer any_in.deinit();
        const unk_in = js.Unknown.fromBool(true);

        const intr_out = try m3_esm.roundtripIntrinsics(obj_in, any_in, unk_in);
        defer {
            intr_out.@"0".deinit();
            intr_out.@"1".deinit();
            intr_out.@"2".deinit();
        }
        if (!intr_out.@"0".eql(obj_in)) return error.Unexpected;
        const decoded_any = try js.fromJsRefAlloc([]const u8, tracked_alloc, intr_out.@"1");
        defer js.freeDecoded([]const u8, tracked_alloc, decoded_any);
        const decoded_unk = try js.fromJsRef(bool, intr_out.@"2");
        if (!std.mem.eql(u8, decoded_any, "any-payload") or !decoded_unk) return error.Unexpected;

        summary = try std.fmt.allocPrint(
            out_alloc,
            "void={d:.0}|never={s}|str={d}:{d}:{s}|ultra={s}",
            .{ acc, caught_msg, byte_len, u16_len, str_slice, ultra_str },
        );
    }

    try checkInvariants(handles_before, allocs_before);
    return summary;
}

// 2. Nullability & Optionality: trailing optional argc + default params, T|null vs T|undefined,
//    inbound null & undefined -> Zig null, and js.Nullable(f64) 3-way distinction
pub fn exerciseOptionalsAndNullable(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    var summary: []u8 = undefined;
    {
        // Trailing optional parameters: omitted trailing nulls shrink argc AND trigger JS default parameters!
        const d1 = try m3_esm.callWithDefaultsAlloc(tracked_alloc, "hi", null, null);
        defer js.freeDecoded([]const u8, tracked_alloc, d1);
        const d2 = try m3_esm.callWithDefaultsAlloc(tracked_alloc, "hi", "?", null);
        defer js.freeDecoded([]const u8, tracked_alloc, d2);
        const d3 = try m3_esm.callWithDefaultsAlloc(tracked_alloc, "hi", null, 3);
        defer js.freeDecoded([]const u8, tracked_alloc, d3);
        if (!std.mem.eql(u8, d1, "1:hi!!")) return error.Unexpected;
        if (!std.mem.eql(u8, d2, "2:hi??")) return error.Unexpected;
        if (!std.mem.eql(u8, d3, "3:hi!!!")) return error.Unexpected;

        // Outbound nullish distinction: `T | null` passes JS `null`, `T | undefined` passes JS `undefined`
        const cls_nulls = try m3_esm.classifyNullishArgsAlloc(tracked_alloc, null, null, null);
        defer js.freeDecoded([]const u8, tracked_alloc, cls_nulls);
        const cls_vals = try m3_esm.classifyNullishArgsAlloc(tracked_alloc, "a", "b", "c");
        defer js.freeDecoded([]const u8, tracked_alloc, cls_vals);
        if (!std.mem.eql(u8, cls_nulls, "null|undefined|null")) return error.Unexpected;
        if (!std.mem.eql(u8, cls_vals, "str(a)|str(b)|str(c)")) return error.Unexpected;

        // Inbound JS `null` and `undefined` BOTH map to Zig `null`
        const in_null = try m3_esm.produceInboundOptionalAlloc(tracked_alloc, 0);
        if (in_null != null) return error.Unexpected;
        const in_undef = try m3_esm.produceInboundOptionalAlloc(tracked_alloc, 1);
        if (in_undef != null) return error.Unexpected;
        const in_val = try m3_esm.produceInboundOptionalAlloc(tracked_alloc, 2);
        defer js.freeDecoded(?[]const u8, tracked_alloc, in_val);
        if (in_val == null or !std.mem.eql(u8, in_val.?, "present-value")) return error.Unexpected;

        // js.Nullable(f64) distinguishing .undefined vs .null vs .{ .value = 42.5 }
        const N = js.Nullable(f64);
        const raw0 = try m3_esm.produceRawForNullable(0);
        defer raw0.deinit();
        const raw1 = try m3_esm.produceRawForNullable(1);
        defer raw1.deinit();
        const raw2 = try m3_esm.produceRawForNullable(2);
        defer raw2.deinit();

        const n0 = try js.fromJsRef(N, raw0);
        const n1 = try js.fromJsRef(N, raw1);
        const n2 = try js.fromJsRef(N, raw2);
        if (!n0.isUndefined() or n0.isNull()) return error.Unexpected;
        if (!n1.isNull() or n1.isUndefined()) return error.Unexpected;
        if (n2.toOptional() == null or n2.toOptional().? != 42.5) return error.Unexpected;

        const out0_ref = try js.toJsRef(N, .@"undefined");
        defer out0_ref.deinit();
        const out1_ref = try js.toJsRef(N, .@"null");
        defer out1_ref.deinit();
        const out2_ref = try js.toJsRef(N, .{ .value = 42.5 });
        defer out2_ref.deinit();

        const c0 = try m3_esm.consumeRawFromNullableAlloc(tracked_alloc, out0_ref);
        defer js.freeDecoded([]const u8, tracked_alloc, c0);
        const c1 = try m3_esm.consumeRawFromNullableAlloc(tracked_alloc, out1_ref);
        defer js.freeDecoded([]const u8, tracked_alloc, c1);
        const c2 = try m3_esm.consumeRawFromNullableAlloc(tracked_alloc, out2_ref);
        defer js.freeDecoded([]const u8, tracked_alloc, c2);

        summary = try std.fmt.allocPrint(
            out_alloc,
            "{s}|{s}|{s}|{s}|{s},{s},{s}",
            .{ d1, d2, d3, cls_nulls, c0, c1, c2 },
        );
    }

    try checkInvariants(handles_before, allocs_before);
    return summary;
}

// 3. Arrays & Fixed / Optional / Labeled / Trailing-Variadic / Leading-Variadic / Middle-Variadic Tuples
//    + Malformed tuple return arity/type error cleanup with zero Zig or handle leaks!
pub fn exerciseArraysAndTuples(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    // ReadonlyArray<string> + number[] -> string[]
    {
        const arr_out = try m3_esm.transformStringArrayAlloc(
            tracked_alloc,
            &.{ "alpha", "beta" },
            &.{ 10, 20, 12 },
        );
        defer js.freeDecoded([]const []const u8, tracked_alloc, arr_out);
        if (arr_out.len != 3) return error.Unexpected;
        if (!std.mem.eql(u8, arr_out[0], "ALPHA")) return error.Unexpected;
        if (!std.mem.eql(u8, arr_out[1], "BETA")) return error.Unexpected;
        if (!std.mem.eql(u8, arr_out[2], "sum=42")) return error.Unexpected;
    }
    try checkInvariants(handles_before, allocs_before);

    // Fixed tuple [number, boolean]
    const fixed = try m3_esm.flipFixedPairAlloc(tracked_alloc, .{ .@"0" = 9.5, .@"1" = false });
    if (fixed.@"0" != 10.0 or !fixed.@"1") return error.Unexpected;

    // Labeled optional tuple [host: string, port?: number] (both omitted and present!)
    {
        const ep_omitted = try m3_esm.normalizeEndpointAlloc(tracked_alloc, .{ .host = "db.local", .port = null }, true);
        defer js.freeDecoded(m3_esm.LabeledOptEndpoint, tracked_alloc, ep_omitted);
        if (!std.mem.eql(u8, ep_omitted.host, "db.local:1") or ep_omitted.port != null) return error.Unexpected;

        const ep_filled = try m3_esm.normalizeEndpointAlloc(tracked_alloc, .{ .host = "api.local", .port = 8080 }, false);
        defer js.freeDecoded(m3_esm.LabeledOptEndpoint, tracked_alloc, ep_filled);
        if (!std.mem.eql(u8, ep_filled.host, "api.local:2") or ep_filled.port.? != 8081) return error.Unexpected;
    }
    try checkInvariants(handles_before, allocs_before);

    // Trailing-variadic tuple [host: string, port?: number, ...tags: string[]]
    {
        // With omitted optional `port` and empty `tags` -> JS receives length-1 array `["edge"]`!
        const r_min = try m3_esm.routeSummaryAlloc(tracked_alloc, .{ .host = "edge" });
        defer js.freeDecoded(m3_esm.TrailingRoute, tracked_alloc, r_min);
        if (!std.mem.eql(u8, r_min.host, "edge@1") or r_min.port.? != 8080 or r_min.tags.len != 1 or !std.mem.eql(u8, r_min.tags[0], "ok")) {
            return error.Unexpected;
        }

        // With `port` + 2 variadic `tags` -> JS receives length-4 array `["core", 9090, "v1", "blue"]`!
        const r_full = try m3_esm.routeSummaryAlloc(
            tracked_alloc,
            .{ .host = "core", .port = 9090, .tags = &.{ "v1", "blue" } },
        );
        defer js.freeDecoded(m3_esm.TrailingRoute, tracked_alloc, r_full);
        if (!std.mem.eql(u8, r_full.host, "core@4") or r_full.port.? != 9090 or r_full.tags.len != 3) {
            return error.Unexpected;
        }
        if (!std.mem.eql(u8, r_full.tags[0], "#v1") or !std.mem.eql(u8, r_full.tags[1], "#blue") or !std.mem.eql(u8, r_full.tags[2], "ok")) {
            return error.Unexpected;
        }
    }
    try checkInvariants(handles_before, allocs_before);

    // Leading-variadic tuple [...flags: boolean[], target: string]
    {
        const lead = try m3_esm.evalLeadingFlagsAlloc(
            tracked_alloc,
            .{ .flags = &.{ true, false, true }, .target = "deploy" },
        );
        defer js.freeDecoded(m3_esm.LeadingFlags, tracked_alloc, lead);
        if (lead.flags.len != 3 or lead.flags[0] != false or lead.flags[1] != true or lead.flags[2] != false) {
            return error.Unexpected;
        }
        if (!std.mem.eql(u8, lead.target, "deploy:done")) return error.Unexpected;
    }
    try checkInvariants(handles_before, allocs_before);

    // Middle-variadic tuple [head: number, ...mid: string[], tail: boolean]
    {
        const mid = try m3_esm.evalMiddleSandwichAlloc(
            tracked_alloc,
            .{ .head = 21, .mid = &.{ "left", "right" }, .tail = false },
        );
        defer js.freeDecoded(m3_esm.MiddleSandwich, tracked_alloc, mid);
        if (mid.head != 42 or !mid.tail or mid.mid.len != 2) return error.Unexpected;
        if (!std.mem.eql(u8, mid.mid[0], "LEFT") or !std.mem.eql(u8, mid.mid[1], "RIGHT")) {
            return error.Unexpected;
        }
    }
    try checkInvariants(handles_before, allocs_before);

    // Malformed tuple returns: non-array (kind=0), arity too short (kind=1), and mid-decode element TypeError
    // AFTER heap-allocating `host` and `tags[0]` (kind=2) — MUST return error.TypeError with ZERO leaks!
    for ([_]f64{ 0, 1, 2 }) |bad_kind| {
        if (m3_esm.malformedTupleReturnAlloc(tracked_alloc, bad_kind)) |unexpected| {
            js.freeDecoded(m3_esm.TrailingRoute, tracked_alloc, unexpected);
            return error.Unexpected;
        } else |err| {
            if (err != error.TypeError) return err;
        }
        try checkInvariants(handles_before, allocs_before);
    }

    return std.fmt.allocPrint(out_alloc, "tuples-and-arrays-ok", .{});
}

// 4. Binary Buffers & Views: Buffer, Uint8Array, Int32Array, Float64Array, BigInt64Array,
//    ArrayBuffer, SharedArrayBuffer, DataView — including in-place JS mutation visible to Zig!
pub fn exerciseBinaryViews(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    var out: []u8 = undefined;
    {
        const buf = try js.Buffer.fromSlice(&.{ 5, 6, 7 });
        defer buf.deinit();
        const u8_arr = try js.Uint8Array.fromSlice(&.{ 0x10, 0x20, 0x30 });
        defer u8_arr.deinit();
        const i32_arr = try js.Int32Array.fromSlice(&.{ -14, 99 });
        defer i32_arr.deinit();
        const f64_arr = try js.Float64Array.fromSlice(&.{ 1.5, 2.5 });
        defer f64_arr.deinit();
        const i64_arr = try js.BigInt64Array.fromSlice(&.{ 5000, -7000 });
        defer i64_arr.deinit();
        const ab = try js.ArrayBuffer.fromSlice(&.{ 1, 2, 3, 4 });
        defer ab.deinit();
        const sab = try js.SharedArrayBuffer.fromSlice(&.{ 10, 0, 0, 0 }); // little-endian i32 = 10
        defer sab.deinit();
        const dv = try js.DataView.fromSlice(&.{ 0, 0, 0xaa, 0xbb });
        defer dv.deinit();

        const summary_buf = try m3_esm.mutateBinaryInPlace(buf, u8_arr, i32_arr, f64_arr, i64_arr, ab, sab, dv);
        defer summary_buf.deinit();

        // Verify in-place JS mutations are visible on every handle in Zig!
        var buf_bytes: [3]u8 = undefined;
        _ = try buf.copyTo(&buf_bytes);
        if (buf_bytes[0] != 15 or buf_bytes[1] != 6) return error.Unexpected;
        if ((try u8_arr.get(1)) != 0xab) return error.Unexpected;
        if ((try i32_arr.get(0)) != -42) return error.Unexpected;
        if ((try f64_arr.get(1)) != 2.75) return error.Unexpected;
        if ((try i64_arr.get(0)) != 4000) return error.Unexpected;

        var ab_bytes: [4]u8 = undefined;
        _ = try ab.copyTo(&ab_bytes);
        if (ab_bytes[2] != 0x77) return error.Unexpected;

        var sab_bytes: [4]u8 = undefined;
        _ = try sab.copyTo(&sab_bytes);
        if (std.mem.readInt(i32, &sab_bytes, .little) != 60) return error.Unexpected;

        if ((try dv.getUint16(0, true)) != 0xbeef) return error.Unexpected;

        const sum_slice = try summary_buf.toOwnedSlice(tracked_alloc);
        defer tracked_alloc.free(sum_slice);
        if (!std.mem.eql(u8, sum_slice, &.{ 15, 0xab, 0x77, 0xef, 0xbe })) {
            return error.Unexpected;
        }

        out = try std.fmt.allocPrint(
            out_alloc,
            "buf0={d}|u8={x}|i32={d}|f64={d:.2}|i64={d}|sab={d}|dv={x}",
            .{
                buf_bytes[0],
                try u8_arr.get(1),
                try i32_arr.get(0),
                try f64_arr.get(1),
                try i64_arr.get(0),
                std.mem.readInt(i32, &sab_bytes, .little),
                try dv.getUint16(0, true),
            },
        );
    }

    try checkInvariants(handles_before, allocs_before);
    return out;
}

// 5. Module GlobalTarget .get()/.getAlloc()/.set(), nested namespace functions/globals,
//    export default, export = CJS callable + merged namespace, and declare global!
pub fn exerciseGlobalsNamespacesExports(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    var out: []u8 = undefined;
    {
        // ESM default export function (with & without optional param)
        const def1 = try m3_esm.defaultAlloc(tracked_alloc, "boot", null);
        defer js.freeDecoded([]const u8, tracked_alloc, def1);
        const def2 = try m3_esm.defaultAlloc(tracked_alloc, "boot", 201);
        defer js.freeDecoded([]const u8, tracked_alloc, def2);
        if (!std.mem.eql(u8, def1, "[1]boot#200") or !std.mem.eql(u8, def2, "[2]boot#201")) {
            return error.Unexpected;
        }

        // ESM live `export let` bindings + read-only ESM namespace set rejection
        {
            const t0 = try m3_esm.module_tag.getAlloc(tracked_alloc);
            defer js.freeDecoded([]const u8, tracked_alloc, t0);
            const c0 = try m3_esm.module_count.get();
            if (!std.mem.eql(u8, t0, "initial-tag") or c0 != 10) return error.Unexpected;

            if (m3_esm.module_count.set(99)) |_| {
                return error.Unexpected;
            } else |err| {
                if (err != error.TypeError and err != error.JsException) return err;
                js.clearLastError();
            }

            try m3_esm.mutateEsmBindings("updated-tag", 5);
            const t1 = try m3_esm.module_tag.getAlloc(tracked_alloc);
            defer js.freeDecoded([]const u8, tracked_alloc, t1);
            const c1 = try m3_esm.module_count.get();
            if (!std.mem.eql(u8, t1, "updated-tag") or c1 != 15) return error.Unexpected;
        }

        // Nested namespace global .get()/.set() + nested function
        try m3_esm.Nested.hits.set(100);
        if ((try m3_esm.Nested.hits.get()) != 100) return error.Unexpected;
        const comb1 = try m3_esm.Nested.Deep.combineAlloc(tracked_alloc, "ns", null);
        defer js.freeDecoded([]const u8, tracked_alloc, comb1);
        const comb2 = try m3_esm.Nested.Deep.combineAlloc(tracked_alloc, "ns", 4);
        defer js.freeDecoded([]const u8, tracked_alloc, comb2);
        if (!std.mem.eql(u8, comb1, "ns:9:hits=101") or !std.mem.eql(u8, comb2, "ns:4:hits=102")) {
            return error.Unexpected;
        }

        // CJS `export =` root callable + merged namespace property & method
        try m3_cjs.invocations.set(0);
        const cjs1 = try m3_cjs.cjsTransformAlloc(tracked_alloc, "req", null);
        defer js.freeDecoded(@TypeOf(cjs1), tracked_alloc, cjs1);
        const cjs2 = try m3_cjs.cjsTransformAlloc(tracked_alloc, "req", 3);
        defer js.freeDecoded(@TypeOf(cjs2), tracked_alloc, cjs2);
        if (!std.mem.eql(u8, cjs1.@"0", "req:1") or cjs1.@"1" != 71) return error.Unexpected;
        if (!std.mem.eql(u8, cjs2.@"0", "req:2") or cjs2.@"1" != 32) return error.Unexpected;
        if ((try m3_cjs.invocations.get()) != 2) return error.Unexpected;

        const cjs_desc_null = try m3_cjs.CjsTransform.describeAlloc(tracked_alloc, null);
        defer js.freeDecoded([]const u8, tracked_alloc, cjs_desc_null);
        const cjs_desc_val = try m3_cjs.CjsTransform.describeAlloc(tracked_alloc, "v2");
        defer js.freeDecoded([]const u8, tracked_alloc, cjs_desc_val);
        if (!std.mem.eql(u8, cjs_desc_null, "cjs:null") or !std.mem.eql(u8, cjs_desc_val, "cjs:v2")) {
            return error.Unexpected;
        }

        // `declare global` variable .getAlloc()/.set(), function, and global namespace!
        {
            const g_init = try fixture.m3_global_label.getAlloc(tracked_alloc);
            defer js.freeDecoded([]const u8, tracked_alloc, g_init);
            if (!std.mem.eql(u8, g_init, "seed-global")) return error.Unexpected;

            try fixture.m3_global_label.set("zig-mutated-global");
            const g_after = try fixture.m3_global_label.getAlloc(tracked_alloc);
            defer js.freeDecoded([]const u8, tracked_alloc, g_after);
            if (!std.mem.eql(u8, g_after, "zig-mutated-global")) return error.Unexpected;

            const gc1 = try fixture.m3GlobalComputeAlloc(tracked_alloc, "ada", null);
            defer js.freeDecoded(@TypeOf(gc1), tracked_alloc, gc1);
            const gc2 = try fixture.m3GlobalComputeAlloc(tracked_alloc, "ada", 25);
            defer js.freeDecoded(@TypeOf(gc2), tracked_alloc, gc2);
            if (!std.mem.eql(u8, gc1.@"0", "zig-mutated-global:ada:1") or gc1.@"1" != 10) return error.Unexpected;
            if (!std.mem.eql(u8, gc2.@"0", "zig-mutated-global:ada:2") or gc2.@"1" != 25) return error.Unexpected;

            try fixture.M3GlobalBox.count.set(50);
            const s1 = try fixture.M3GlobalBox.step(null);
            const s2 = try fixture.M3GlobalBox.step(7);
            if (s1 != 51 or s2 != 58 or (try fixture.M3GlobalBox.count.get()) != 58) {
                return error.Unexpected;
            }
        }

        out = try std.fmt.allocPrint(out_alloc, "{s}|{s}|{s}", .{ def2, comb2, cjs_desc_val });
    }
    try checkInvariants(handles_before, allocs_before);

    return out;
}

// 6. Adversarial Nullish Fidelity (PR #84 Findings 1 & 2):
//    - Required `T | null` & `T | undefined` vs optional `opt?: T` on both `interface` and inline `anon_struct`
//    - Variadic tuple `[v: number | undefined, w: string | null, ...rest: (number | null)[]]`
//    - Slices `(string | null)[]`, `(number | undefined)[]`, and `items?: (string | null)[]`
//    - Rest parameters `...args: (number | undefined)[]` vs `...args: (number | null)[]`
//    - Module/namespace/global `.set(null)` on `gUndef: string | undefined` vs `gNull: string | null`
pub fn exerciseNullishFidelity(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    var out: []u8 = undefined;
    {
        // Comptime check on top-level ESM `export let` nullish specs + runtime `.getAlloc`
        if (@TypeOf(m3_esm.g_undef).nullish_spec != .undefined_only) return error.Unexpected;
        if (@TypeOf(m3_esm.g_null).nullish_spec != .null_only) return error.Unexpected;
        const esm_u = try m3_esm.g_undef.getAlloc(tracked_alloc);
        defer js.freeDecoded(?[]const u8, tracked_alloc, esm_u);
        const esm_n = try m3_esm.g_null.getAlloc(tracked_alloc);
        defer js.freeDecoded(?[]const u8, tracked_alloc, esm_n);
        if (esm_u == null or !std.mem.eql(u8, esm_u.?, "esm-seed-undef")) return error.Unexpected;
        if (esm_n == null or !std.mem.eql(u8, esm_n.?, "esm-seed-null")) return error.Unexpected;

        // (1a) Interface required `T | null` + `T | undefined` vs omitted optionals (`'optNum' in p === false`)
        const iface_nulls = try m3_esm.inspectInterfaceNullishAlloc(tracked_alloc, .{
            .req_null = null,
            .req_undef = null,
        });
        defer js.freeDecoded([]const u8, tracked_alloc, iface_nulls);
        if (!std.mem.eql(u8, iface_nulls, "reqNull=null|reqUndef=undefined|no-optNum|no-optNull|no-items")) {
            return error.Unexpected;
        }

        // Interface with `items?: (string | null)[]` populated (`items[1] === null`)
        const iface_items = try m3_esm.inspectInterfaceNullishAlloc(tracked_alloc, .{
            .req_null = 12,
            .req_undef = 34,
            .opt_num = 56,
            .items = &.{ "keep", null },
        });
        defer js.freeDecoded([]const u8, tracked_alloc, iface_items);
        if (!std.mem.eql(u8, iface_items, "reqNull=number:12|reqUndef=number:34|optNum=number:56|no-optNull|items=[string:keep,null]")) {
            return error.Unexpected;
        }

        // (1b) Inline `{ ... }` (`anon_struct`) parameter & return, including `zigar_js` property collision
        const inline1 = try m3_esm.inspectInlineNullishAlloc(tracked_alloc, .{
            .req_null = null,
            .req_undef = null,
        });
        defer js.freeDecoded(@TypeOf(inline1), tracked_alloc, inline1);
        if (inline1.out_null == null or !std.mem.eql(u8, inline1.out_null.?, "was-null")) return error.Unexpected;
        if (inline1.out_undef != null or inline1.opt_tag != null) return error.Unexpected;

        const inline2 = try m3_esm.inspectInlineNullishAlloc(tracked_alloc, .{
            .req_null = 5,
            .req_undef = null,
            .zigar_js_2 = "ok",
        });
        defer js.freeDecoded(@TypeOf(inline2), tracked_alloc, inline2);
        if (inline2.out_null != null or inline2.out_undef != null) return error.Unexpected;
        if (inline2.opt_tag == null or !std.mem.eql(u8, inline2.opt_tag.?, "hasOpt=false:zigar_js=ok")) {
            return error.Unexpected;
        }

        // (2) Variadic tuple `[v: number | undefined, w: string | null, ...rest: (number | null)[]]`
        const tup_out = try m3_esm.inspectNullishTupleAlloc(tracked_alloc, .{
            .v = null,
            .w = null,
            .rest = &.{ 10, null, 30 },
        });
        defer js.freeDecoded(m3_esm.NullishVariadicTuple, tracked_alloc, tup_out);
        if (tup_out.v == null or tup_out.v.? != 77) return error.Unexpected;
        if (tup_out.w == null or !std.mem.eql(u8, tup_out.w.?, "from-null")) return error.Unexpected;
        if (tup_out.rest.len != 3 or tup_out.rest[0] != null or tup_out.rest[1] != 0 or tup_out.rest[2] != null) {
            return error.Unexpected;
        }

        // (3) Slices `(string | null)[]`, `(number | undefined)[]`, and `items?: (string | null)[]`
        const sl_omitted = try m3_esm.inspectNullishSlicesAlloc(
            tracked_alloc,
            &.{ "a", null },
            &.{ 1, null },
            null,
        );
        defer js.freeDecoded([]const u8, tracked_alloc, sl_omitted);
        if (!std.mem.eql(u8, sl_omitted, "sn=[string:a,null]|nu=[number:1,undefined]|argc=2:omitted")) {
            return error.Unexpected;
        }

        const sl_present = try m3_esm.inspectNullishSlicesAlloc(
            tracked_alloc,
            &.{ null, "z" },
            &.{ null, 9 },
            &.{ "x", null },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, sl_present);
        if (!std.mem.eql(u8, sl_present, "sn=[null,string:z]|nu=[undefined,number:9]|argc=3:[string:x,null]")) {
            return error.Unexpected;
        }

        // (4) Rest parameters `...args: (number | undefined)[]` vs `...args: (number | null)[]`
        const rest_u = try m3_esm.inspectRestUndefAlloc(tracked_alloc, "u", &.{ 5, null, 9 });
        defer js.freeDecoded([]const u8, tracked_alloc, rest_u);
        const rest_n = try m3_esm.inspectRestNullAlloc(tracked_alloc, "n", &.{ 5, null, 9 });
        defer js.freeDecoded([]const u8, tracked_alloc, rest_n);
        if (!std.mem.eql(u8, rest_u, "u:[number:5,undefined,number:9]")) return error.Unexpected;
        if (!std.mem.eql(u8, rest_n, "n:[number:5,null,number:9]")) return error.Unexpected;

        // (5) Global/module/namespace setter `.set(null)` on `string | undefined` (`=== undefined`) vs `string | null` (`=== null`)
        try m3_esm.Nested.g_undef.set("temp");
        try m3_esm.Nested.g_null.set("temp");
        try m3_esm.Nested.g_undef.set(null);
        try m3_esm.Nested.g_null.set(null);
        const nested_ver = try m3_esm.Nested.verifyNestedNullishGlobalsAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, nested_ver);
        if (!std.mem.eql(u8, nested_ver, "nested:undefined|null")) return error.Unexpected;

        try m3_cjs.g_undef.set("temp");
        try m3_cjs.g_null.set("temp");
        try m3_cjs.g_undef.set(null);
        try m3_cjs.g_null.set(null);
        const cjs_ver = try m3_cjs.CjsTransform.verifyCjsNullishGlobalsAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, cjs_ver);
        if (!std.mem.eql(u8, cjs_ver, "cjs:undefined|null")) return error.Unexpected;

        try fixture.m3_global_undef.set(null);
        try fixture.m3_global_null.set(null);
        if ((try fixture.m3_global_undef.getAlloc(tracked_alloc)) != null) return error.Unexpected;
        if ((try fixture.m3_global_null.getAlloc(tracked_alloc)) != null) return error.Unexpected;

        // (6) Generic nullable/undefined aliases (`Maybe<T>`, `Undef<T>`, `OptList<T>`, `GenericBox<Maybe<number>>`)
        if (@TypeOf(m3_esm.g_maybe).nullish_spec != .null_only) return error.Unexpected;
        if (@TypeOf(m3_esm.g_undef_alias).nullish_spec != .undefined_only) return error.Unexpected;
        if ((try m3_esm.g_maybe.get()) != null) return error.Unexpected;
        if ((try m3_esm.g_undef_alias.get()) != null) return error.Unexpected;
        try m3_esm.Nested.g_maybe.set(null);
        try m3_esm.Nested.g_undef_alias.set(null);
        if ((try m3_esm.Nested.g_maybe.get()) != null) return error.Unexpected;
        if ((try m3_esm.Nested.g_undef_alias.get()) != null) return error.Unexpected;

        // Case A: omitted optional fields (`opt_maybe = null`, `box.opt = null`)
        const gen_a = try m3_esm.inspectGenericAliasNullishAlloc(
            tracked_alloc,
            .{
                .req_maybe = null,
                .req_undef = null,
                .maybe_items = &.{ "ok", null },
                .pair = .{ .@"0" = null, .@"1" = null },
            },
            .{ .val = null },
            &.{ 7, null },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, gen_a);
        if (!std.mem.eql(
            u8,
            gen_a,
            "reqMaybe=null|reqUndef=undefined|no-optMaybe|no-optUndef|items=[string:ok,null]|pair=[null,undefined]|boxVal=null|no-boxOpt|rest=[number:7,undefined]",
        )) {
            return error.Unexpected;
        }

        // Case B: present outer optional with inner `null` (`opt_maybe = @as(?f64, null)` -> `optMaybe === null`,
        // `opt_undef = @as(?f64, null)` -> `optUndef === undefined`, `box.opt = @as(?f64, null)` -> `boxOpt === null`)!
        const gen_b = try m3_esm.inspectGenericAliasNullishAlloc(
            tracked_alloc,
            .{
                .req_maybe = "present",
                .req_undef = "here",
                .opt_maybe = @as(?f64, null),
                .opt_undef = @as(?f64, null),
                .maybe_items = &.{null},
                .pair = .{ .@"0" = "p", .@"1" = 3 },
            },
            .{ .val = 9, .opt = @as(?f64, null) },
            &.{null},
        );
        defer js.freeDecoded([]const u8, tracked_alloc, gen_b);
        if (!std.mem.eql(
            u8,
            gen_b,
            "reqMaybe=string:present|reqUndef=string:here|optMaybe=null|optUndef=undefined|items=[null]|pair=[string:p,number:3]|boxVal=number:9|boxOpt=null|rest=[undefined]",
        )) {
            return error.Unexpected;
        }

        // (7) Generic container call-site overrides (`GenericBox<Undef<number>>`, recursive `LinkedNode<Undef<number>>`,
        //     `PairAlias<Undef<string>>`) and pass-through generic alias slice flattening (`Id<number[]>`)!
        const tail_node: m3_esm.LinkedNode(?f64) = .{ .val = null };
        const gc_a = try m3_esm.inspectGenericContainersUndefAlloc(
            tracked_alloc,
            .{ .val = null },
            .{ .val = null, .next = &tail_node },
            .{ .@"0" = null, .@"1" = 5 },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, gc_a);
        if (!std.mem.eql(
            u8,
            gc_a,
            "box(undefined,no-opt)|nodes[undefined:next->undefined:end]|pair[undefined,number:5]",
        )) {
            return error.Unexpected;
        }

        const gc_b = try m3_esm.inspectGenericContainersUndefAlloc(
            tracked_alloc,
            .{ .val = 11, .opt = @as(?f64, null) },
            .{ .val = 22 },
            .{ .@"0" = "tag", .@"1" = 8 },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, gc_b);
        if (!std.mem.eql(
            u8,
            gc_b,
            "box(number:11,opt=undefined)|nodes[number:22:end]|pair[string:tag,number:8]",
        )) {
            return error.Unexpected;
        }

        const sum_id = try m3_esm.sumRestGenericAlias(&.{ 10, 20, 12 });
        if (sum_id != 42) return error.Unexpected;

        const var_id = try m3_esm.readVariadicGenericAliasTupleAlloc(
            tracked_alloc,
            .{ .@"0" = "head", .@"1" = &.{ 3, 6, 9 } },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, var_id);
        if (!std.mem.eql(u8, var_id, "head:[3,6,9]")) return error.Unexpected;

        // (8) Mutual generic recursion (`MutA<T> <-> MutB<T>`), inline `anon_struct` (`MetaNode<T>`),
        //     polymorphic type-arg recursion (`PolyNode<Undef>` -> `alt?: PolyNode<Maybe>`),
        //     and recursive generic type alias (`AliasTree<Undef<number>>`)!
        const mut_b2: m3_esm.MutB(?f64) = .{ .w = 99 };
        const mut_a2: m3_esm.MutA(?f64) = .{ .v = null, .b = mut_b2 };
        const mut_b1: m3_esm.MutB(?f64) = .{ .w = null, .a = &mut_a2 };

        const meta_inner: m3_esm.MetaNode(?f64) = .{ .val = null, .meta = .{} };
        const poly_same: m3_esm.PolyNode(?f64) = .{ .val = null };
        const poly_alt_same: m3_esm.PolyNode(?f64) = .{ .val = null };
        const poly_alt: m3_esm.PolyNode(?f64) = .{ .val = null, .same = &poly_alt_same };

        const tree_leaf1: m3_esm.AliasTree(?f64) = .{ .v = null };
        const tree_leaf2: m3_esm.AliasTree(?f64) = .{ .v = 7 };
        const tree_mid: m3_esm.AliasTree(?f64) = .{ .v = null, .kids = &.{ tree_leaf1, tree_leaf2 } };

        const list_end: m3_esm.NullableList(?f64) = null;
        const list_n7: m3_esm.NullableList(?f64) = .{ .head = null, .tail = &list_end };
        const list_n6: m3_esm.NullableList(?f64) = .{ .head = 60, .tail = &list_n7 };
        const list_n5: m3_esm.NullableList(?f64) = .{ .head = null, .tail = &list_n6 };
        const list_n4: m3_esm.NullableList(?f64) = .{ .head = 40, .tail = &list_n5 };
        const list_n3: m3_esm.NullableList(?f64) = .{ .head = null, .tail = &list_n4 };
        const list_n2: m3_esm.NullableList(?f64) = .{ .head = 20, .tail = &list_n3 };
        const list_n1: m3_esm.NullableList(?f64) = .{ .head = null, .tail = &list_n2 };

        const ot_n6: m3_esm.NullableTupleTree(?f64) = .{ .@"0" = null, .@"1" = &.{null} };
        const ot_n5: m3_esm.NullableTupleTree(?f64) = .{ .@"0" = 5, .@"1" = &.{ot_n6} };
        const ot_n4: m3_esm.NullableTupleTree(?f64) = .{ .@"0" = null, .@"1" = &.{ot_n5} };
        const ot_n3: m3_esm.NullableTupleTree(?f64) = .{ .@"0" = 3, .@"1" = &.{ot_n4} };
        const ot_n2: m3_esm.NullableTupleTree(?f64) = .{ .@"0" = null, .@"1" = &.{ot_n3} };
        const ot_n1: m3_esm.NullableTupleTree(?f64) = .{ .@"0" = null, .@"1" = &.{ null, ot_n2 } };

        const deep_rec = try m3_esm.inspectDeepGenericRecursionAlloc(
            tracked_alloc,
            .{ .v = null, .b = mut_b1 },
            .{ .val = null, .meta = .{ .inner = &meta_inner } },
            .{ .val = null, .alt = &poly_alt, .same = &poly_same },
            .{ .v = null, .kids = &.{tree_mid} },
            list_n1,
            ot_n1,
        );
        defer js.freeDecoded([]const u8, tracked_alloc, deep_rec);
        if (!std.mem.eql(
            u8,
            deep_rec,
            "mut=ok|meta=ok|poly=undef+null|tree=undefined[undefined[undefined,number:7]]|list=u,20,u,40,u,60,u|ot=u(null,u(3(u(5(u(null))))))",
        )) {
            return error.Unexpected;
        }

        out = try std.fmt.allocPrint(out_alloc, "{s}|{s}|{s}|{s}", .{ rest_u, rest_n, nested_ver, cjs_ver });
    }

    try checkInvariants(handles_before, allocs_before);
    return out;
}
