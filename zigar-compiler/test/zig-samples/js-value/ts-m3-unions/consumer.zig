const std = @import("std");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const m = gen.m3_unions_esm;

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

// 1. Enums (i32, aliases, const enum, i64, mixed, ambient unknown-value) & closed literal unions
pub fn exerciseEnumsAndClosedLiterals(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        if (m.HttpStatus.ok != m.HttpStatus.success_alias) return error.Unexpected;
        if (m.LogLevel.info != m.LogLevel.info_alias) return error.Unexpected;
        if (!m.LogLevel.zigar_js.is_const) return error.Unexpected;

        const stepped = try m.stepStatus(.success_alias, .info_alias, .zero);
        if (stepped.@"0" != .created or stepped.@"1" != .warn or stepped.@"2" != .five_billion) {
            return error.Unexpected;
        }
        if (stepped.@"2".toInt() != 5_000_000_000) return error.Unexpected;

        // Invalid enum values (unknown int, float, string, huge string) must fail with pure TypeError and zero JS exception
        for ([_]f64{ 0, 1, 2, 3 }) |mode| {
            try std.testing.expectError(error.TypeError, m.badStatusReturn(mode));
            if (js.hasLastError()) return error.Unexpected;
        }

        const desc1 = try m.echoMixedAndClosedAlloc(tracked_alloc, .auto, .utf_8, .neg_1, .n_1_5, .bi_20, .bool_false);
        defer js.freeDecoded([]const u8, tracked_alloc, desc1);
        if (!std.mem.eql(u8, desc1, "auto|utf-8|-1|1.5|20n|false")) return error.Unexpected;

        const desc2 = try m.echoMixedAndClosedAlloc(tracked_alloc, .one, .hex, .n_0, .n_0_5, .bi_10, .bi_1);
        defer js.freeDecoded([]const u8, tracked_alloc, desc2);
        if (!std.mem.eql(u8, desc2, "1|hex|0|0.5|10n|1n")) return error.Unexpected;

        // Out-of-range BigInts congruent mod 2^64 MUST be rejected even in ReleaseSmall / ReleaseFast!
        try std.testing.expectError(error.TypeError, m.badBigChoiceWrapReturn());
        try std.testing.expectError(error.TypeError, m.badMixedWrapReturn());
        if (m.badBigDiscWrapReturnAlloc(tracked_alloc)) |bad_bd| {
            js.freeDecoded(m.BigDiscUnion, tracked_alloc, bad_bd);
            return error.Unexpected;
        } else |err| {
            if (err != error.TypeError) return err;
        }

        // `string | true | false` promotes `true | false` to `.boolean: bool` while keeping `.str: []const u8`
        const sbp1 = try m.echoStrOrBoolPairAlloc(tracked_alloc, .{ .str = "hello" });
        defer js.freeDecoded(m.StrOrBoolPair, tracked_alloc, sbp1);
        if (std.meta.activeTag(sbp1) != .boolean or !sbp1.boolean) return error.Unexpected;
        const sbp2 = try m.echoStrOrBoolPairAlloc(tracked_alloc, .{ .boolean = false });
        defer js.freeDecoded(m.StrOrBoolPair, tracked_alloc, sbp2);
        if (std.meta.activeTag(sbp2) != .str or !std.mem.eql(u8, sbp2.str, "was-bool")) return error.Unexpected;

        // Ambient unknown-value enum (`RuntimeFlags`) live handle lookup + roundtrip
        const f_read = try m.RuntimeFlags.read.get();
        defer f_read.deinit();
        const f_write = try m.RuntimeFlags.write.get();
        defer f_write.deinit();
        const combined = try m.combineRuntimeFlags(f_read, f_write);
        if (combined != 12) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "enums-and-closed-literals-ok");
}

// 2. Open literal unions & finite/open template literal patterns
pub fn exerciseOpenLiteralsAndTemplates(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        // Known unit literal -> custom literal roundtrip
        const r1 = try m.inspectOpenLiteralsAlloc(tracked_alloc, .application_json, .n_443);
        defer js.freeDecoded(@TypeOf(r1), tracked_alloc, r1);
        if (std.meta.activeTag(r1.@"0") != .custom or !std.mem.eql(u8, r1.@"0".custom, "image/webp")) {
            return error.Unexpected;
        }
        if (std.meta.activeTag(r1.@"1") != .custom or r1.@"1".custom != 8080) {
            return error.Unexpected;
        }

        // Custom literal -> known unit literal roundtrip (known unit arm allocates 0 bytes!)
        const r2 = try m.inspectOpenLiteralsAlloc(
            tracked_alloc,
            m.OpenMime.from("video/mp4"),
            m.OpenPort.from(9090),
        );
        defer js.freeDecoded(@TypeOf(r2), tracked_alloc, r2);
        if (r2.@"0" != .text_plain or r2.@"1" != .n_80) return error.Unexpected;

        // Finite (`HookEvent`) and open (`SemVer`, `RouteUrl`) template literals
        const ver_in = comptime m.SemVer.initComptime("v26.1.0");
        const route_in = try m.RouteUrl.from("https://zigar.dev/api/-42");
        const ver_out = try m.inspectTemplatesAlloc(tracked_alloc, .on_open, ver_in, route_in);
        defer js.freeDecoded(m.SemVer, tracked_alloc, ver_out);
        if (!std.mem.eql(u8, ver_out.raw, "v26.2.0")) return error.Unexpected;

        // Inbound invalid template literal strings/numbers must free decoded buffer and return TypeError
        for ([_]f64{ 0, 1, 2 }) |mode| {
            try std.testing.expectError(error.TypeError, m.badSemVerReturnAlloc(tracked_alloc, mode));
            if (js.hasLastError()) return error.Unexpected;
        }

        // Outbound forged template literal `.raw` bypassing `from` must be rejected by `toJsRef`!
        const forged_ver = m.SemVer{ .raw = "not-a-semver" };
        try std.testing.expectError(
            error.TypeError,
            m.inspectTemplatesAlloc(tracked_alloc, .on_close, forged_ver, route_in),
        );
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "open-literals-and-templates-ok");
}

// 3. Discriminated unions (single-tag, multi-tag, boolean, enum-member, non-fallthrough & outbound guard)
pub fn exerciseDiscriminatedUnions(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        const ev1 = try m.processAuditEventAlloc(tracked_alloc, .{
            .created = .{ .trace_id = "t1", .id = "item-9" },
        });
        defer js.freeDecoded(m.AuditEvent, tracked_alloc, ev1);
        if (std.meta.activeTag(ev1) != .updated_or_patched) return error.Unexpected;
        if (!std.mem.eql(u8, ev1.updated_or_patched.trace_id, "t1:ack")) return error.Unexpected;
        if (ev1.updated_or_patched.kind != .patched or ev1.updated_or_patched.rev != 7) return error.Unexpected;

        const ev2 = try m.processAuditEventAlloc(tracked_alloc, ev1);
        defer js.freeDecoded(m.AuditEvent, tracked_alloc, ev2);
        if (std.meta.activeTag(ev2) != .deleted or ev2.deleted.soft != null) return error.Unexpected;

        const ev3 = try m.processAuditEventAlloc(tracked_alloc, .{
            .deleted = .{ .trace_id = "t3", .soft = true },
        });
        defer js.freeDecoded(m.AuditEvent, tracked_alloc, ev3);
        if (std.meta.activeTag(ev3) != .created or !std.mem.eql(u8, ev3.created.id, "soft-id")) {
            return error.Unexpected;
        }

        // Non-fallthrough payload TypeError (mode 0), unknown tag (mode 1), non-object array (mode 2)
        for ([_]f64{ 0, 1, 2 }) |mode| {
            try std.testing.expectError(error.TypeError, m.badAuditEventReturnAlloc(tracked_alloc, mode));
            if (js.hasLastError()) return error.Unexpected;
        }

        // Outbound forged discriminant field `.kind = "WRONG"` must be rejected before calling JS!
        try std.testing.expectError(error.TypeError, m.processAuditEventAlloc(tracked_alloc, .{
            .created = .{ .trace_id = "forged", .kind = "deleted", .id = "x" },
        }));

        // Boolean discriminant (`Outcome`) + enum-member discriminant (`OpCmd`) + null-only field preservation
        const res1 = try m.processOutcomeAndCmdAlloc(
            tracked_alloc,
            .{ .ok_false = .{ .code = 503, .detail = null } },
            .{ .add = .{ .amount = 15 } },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, res1);
        if (!std.mem.eql(u8, res1, "err:503:null|add:15")) return error.Unexpected;

        const res2 = try m.processOutcomeAndCmdAlloc(
            tracked_alloc,
            .{ .ok_true = .{ .value = "ready" } },
            .{ .reset = .{} },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, res2);
        if (!std.mem.eql(u8, res2, "ok:ready|reset")) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "discriminated-unions-ok");
}

// 4. Heterogeneous specificity, CJS `export =` class instanceof, recursive JsonValue, and generic union nullish
pub fn exerciseHeteroRecursiveAndGenericUnions(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        // Exercise all 11 heterogeneous arms inbound + outbound
        const expected_descs = [_][]const u8{
            "arr:1:only-one",
            "arr:2:two-items,42",
            "arr:3:a,b,c",
            "buf:3:10",
            "u8:2:99",
            "chan:pong:alpha",
            "string:v3.4.5",
            "string:plain-text",
            "host:zigar.dev:omitted",
            "number:123.5",
            "boolean:true",
        };

        for (expected_descs, 0..) |exp, idx| {
            const p = try m.produceHeteroAlloc(tracked_alloc, @floatFromInt(idx));
            defer js.freeDecoded(m.HeteroPayload, tracked_alloc, p);

            switch (idx) {
                0 => if (std.meta.activeTag(p) != .tuple) return std.fmt.allocPrint(out_alloc, "tag-mismatch:0:{s}", .{@tagName(p)}),
                1 => if (std.meta.activeTag(p) != .tuple_2) return std.fmt.allocPrint(out_alloc, "tag-mismatch:1:{s}", .{@tagName(p)}),
                2 => if (std.meta.activeTag(p) != .array) return std.fmt.allocPrint(out_alloc, "tag-mismatch:2:{s}", .{@tagName(p)}),
                3 => if (std.meta.activeTag(p) != .buffer) return std.fmt.allocPrint(out_alloc, "tag-mismatch:3:{s}", .{@tagName(p)}),
                4 => if (std.meta.activeTag(p) != .uint8_array) return std.fmt.allocPrint(out_alloc, "tag-mismatch:4:{s}", .{@tagName(p)}),
                5 => {
                    if (std.meta.activeTag(p) != .mini_channel) return std.fmt.allocPrint(out_alloc, "tag-mismatch:5:{s}", .{@tagName(p)});
                    const chan_label = try p.mini_channel.labelAlloc(tracked_alloc);
                    defer js.freeDecoded([]const u8, tracked_alloc, chan_label);
                    if (!std.mem.eql(u8, chan_label, "alpha")) return std.fmt.allocPrint(out_alloc, "label-mismatch:5:{s}", .{chan_label});
                    const ping_res = try p.mini_channel.pingAlloc(tracked_alloc);
                    defer js.freeDecoded([]const u8, tracked_alloc, ping_res);
                    if (!std.mem.eql(u8, ping_res, "pong:alpha")) return std.fmt.allocPrint(out_alloc, "ping-mismatch:5:{s}", .{ping_res});
                },
                6 => if (std.meta.activeTag(p) != .sem_ver) return std.fmt.allocPrint(out_alloc, "tag-mismatch:6:{s}", .{@tagName(p)}),
                7 => if (std.meta.activeTag(p) != .str) return std.fmt.allocPrint(out_alloc, "tag-mismatch:7:{s}", .{@tagName(p)}),
                8 => if (std.meta.activeTag(p) != .record) return std.fmt.allocPrint(out_alloc, "tag-mismatch:8:{s}", .{@tagName(p)}),
                9 => if (std.meta.activeTag(p) != .num) return std.fmt.allocPrint(out_alloc, "tag-mismatch:9:{s}", .{@tagName(p)}),
                10 => if (std.meta.activeTag(p) != .boolean) return std.fmt.allocPrint(out_alloc, "tag-mismatch:10:{s}", .{@tagName(p)}),
                else => unreachable,
            }

            const echoed = try m.describeHeteroAlloc(tracked_alloc, p);
            defer js.freeDecoded([]const u8, tracked_alloc, echoed);
            if (!std.mem.eql(u8, echoed, exp)) return std.fmt.allocPrint(out_alloc, "echo-mismatch:{d}:{s}!={s}", .{ idx, echoed, exp });
        }

        // Plain object `{ label: "impostor-not-minichannel" }` MUST be rejected by `instanceof MiniChannel`
        if (m.produceImpostorChannelAlloc(tracked_alloc)) |bad_imp| {
            const bad_tag = @tagName(bad_imp);
            js.freeDecoded(m.HeteroPayload, tracked_alloc, bad_imp);
            return std.fmt.allocPrint(out_alloc, "impostor-accepted:{s}", .{bad_tag});
        } else |err| {
            if (err != error.TypeError) return err;
        }

        // Recursive `JsonValue` (`?JsonValue_inner`): null -> array, object -> nested object
        const j_null_out = try m.transformJsonAlloc(tracked_alloc, null);
        defer js.freeDecoded(m.JsonValue, tracked_alloc, j_null_out);
        if (j_null_out == null or std.meta.activeTag(j_null_out.?) != .array) return out_alloc.dupe(u8, "fail:j_null_out");
        if (j_null_out.?.array.len != 3) return out_alloc.dupe(u8, "fail:j_null_len");

        const j_rec = try js.Record([]const u8, js.Any).init();
        defer j_rec.deinit();
        const title_ref = try js.toJsRef(m.JsonValue, .{ .str = "hello-json" });
        defer title_ref.deinit();
        const flag_ref = try js.toJsRef(m.JsonValue, .{ .boolean = true });
        defer flag_ref.deinit();
        try j_rec.set("title", title_ref);
        try j_rec.set("flag", flag_ref);
        const j_obj_out = try m.transformJsonAlloc(tracked_alloc, .{ .object = j_rec.toRef() });
        defer js.freeDecoded(m.JsonValue, tracked_alloc, j_obj_out);
        if (j_obj_out == null or std.meta.activeTag(j_obj_out.?) != .object) return out_alloc.dupe(u8, "fail:j_obj_out");
        const out_rec = js.Record([]const u8, js.Any).fromRef(j_obj_out.?.object);
        const seen_raw = (try out_rec.get("seenKeys")) orelse return out_alloc.dupe(u8, "fail:seen_missing");
        defer seen_raw.deinit();
        const seen = try js.fromJsRefAlloc(m.JsonValue, tracked_alloc, seen_raw);
        defer js.freeDecoded(m.JsonValue, tracked_alloc, seen);
        if (seen == null or !std.mem.eql(u8, seen.?.str, "flag,title")) return out_alloc.dupe(u8, "fail:seen_val");
        const nested_null_raw = (try out_rec.get("nestedNull")) orelse return out_alloc.dupe(u8, "fail:nestedNull_missing");
        defer nested_null_raw.deinit();
        const nested_null = try js.fromJsRefAlloc(m.JsonValue, tracked_alloc, nested_null_raw);
        defer js.freeDecoded(m.JsonValue, tracked_alloc, nested_null);
        if (nested_null != null) return out_alloc.dupe(u8, "fail:nestedNull_not_null");

        // Generic discriminated union nullish override (`GenericEnvelope<number | undefined>`):
        // `.val.item = null` MUST serialize to JS `{ tag: "val", item: undefined }` (NOT `null`),
        // while `.empty.reason = null` MUST serialize to JS `{ tag: "empty", reason: null }`!
        const env1 = try m.unwrapEnvelopeAlloc(tracked_alloc, .{ .val = .{ .item = null } });
        defer js.freeDecoded(@TypeOf(env1), tracked_alloc, env1);
        if (!std.mem.eql(u8, env1.@"0", "val:true:undefined")) return std.fmt.allocPrint(out_alloc, "fail:env1_0:{s}", .{env1.@"0"});
        if (std.meta.activeTag(env1.@"1") != .val or env1.@"1".val.item != null) return out_alloc.dupe(u8, "fail:env1_1");

        const env2 = try m.unwrapEnvelopeAlloc(tracked_alloc, .{ .empty = .{ .reason = null } });
        defer js.freeDecoded(@TypeOf(env2), tracked_alloc, env2);
        if (!std.mem.eql(u8, env2.@"0", "empty:null")) return std.fmt.allocPrint(out_alloc, "fail:env2_0:{s}", .{env2.@"0"});
        if (std.meta.activeTag(env2.@"1") != .val or !std.mem.eql(u8, env2.@"1".val.item.?, "recovered")) {
            return out_alloc.dupe(u8, "fail:env2_1");
        }

        // Promises/A+ thenables (`Promise(T)` / `PromiseLike<T>`) & union disambiguation:
        // mode 0: plain object `{ immediate: 42 }` -> `.record`
        const soa0 = try m.produceSyncOrAsyncAlloc(tracked_alloc, 0);
        defer js.freeDecoded(m.SyncOrAsync, tracked_alloc, soa0);
        if (std.meta.activeTag(soa0) != .record or soa0.record.immediate != 42) return out_alloc.dupe(u8, "fail:soa0");
        const soa0_desc = try m.inspectSyncOrAsyncAlloc(tracked_alloc, soa0);
        defer tracked_alloc.free(soa0_desc);
        if (!std.mem.eql(u8, soa0_desc, "sync:42")) return std.fmt.allocPrint(out_alloc, "fail:soa0_desc:{s}", .{soa0_desc});

        // mode 1: custom object thenable (`!(v instanceof Promise)`) -> `.promise_like`
        const soa1 = try m.produceSyncOrAsyncAlloc(tracked_alloc, 1);
        defer js.freeDecoded(m.SyncOrAsync, tracked_alloc, soa1);
        if (std.meta.activeTag(soa1) != .promise_like) return std.fmt.allocPrint(out_alloc, "fail:soa1:{s}", .{@tagName(std.meta.activeTag(soa1))});
        const soa1_desc = try m.inspectSyncOrAsyncAlloc(tracked_alloc, soa1);
        defer tracked_alloc.free(soa1_desc);
        if (!std.mem.eql(u8, soa1_desc, "thenable:object:false")) return std.fmt.allocPrint(out_alloc, "fail:soa1_desc:{s}", .{soa1_desc});

        // mode 2: function-typed thenable -> `.promise_like` (higher priority than `.func`)
        const soa2 = try m.produceSyncOrAsyncAlloc(tracked_alloc, 2);
        defer js.freeDecoded(m.SyncOrAsync, tracked_alloc, soa2);
        if (std.meta.activeTag(soa2) != .promise_like) return std.fmt.allocPrint(out_alloc, "fail:soa2:{s}", .{@tagName(std.meta.activeTag(soa2))});
        const soa2_desc = try m.inspectSyncOrAsyncAlloc(tracked_alloc, soa2);
        defer tracked_alloc.free(soa2_desc);
        if (!std.mem.eql(u8, soa2_desc, "thenable:function:false")) return std.fmt.allocPrint(out_alloc, "fail:soa2_desc:{s}", .{soa2_desc});

        // mode 3: plain function (no `.then`) -> `.object`
        const soa3 = try m.produceSyncOrAsyncAlloc(tracked_alloc, 3);
        defer js.freeDecoded(m.SyncOrAsync, tracked_alloc, soa3);
        if (std.meta.activeTag(soa3) != .object) return std.fmt.allocPrint(out_alloc, "fail:soa3:{s}", .{@tagName(std.meta.activeTag(soa3))});
        const soa3_desc = try m.inspectSyncOrAsyncAlloc(tracked_alloc, soa3);
        defer tracked_alloc.free(soa3_desc);
        if (!std.mem.eql(u8, soa3_desc, "func:plain-fn")) return std.fmt.allocPrint(out_alloc, "fail:soa3_desc:{s}", .{soa3_desc});

        // mode 4: cross-realm Promise (`vm.runInNewContext`, `!(v instanceof Promise)`) -> `.promise_like`
        const soa4 = try m.produceSyncOrAsyncAlloc(tracked_alloc, 4);
        defer js.freeDecoded(m.SyncOrAsync, tracked_alloc, soa4);
        if (std.meta.activeTag(soa4) != .promise_like) return std.fmt.allocPrint(out_alloc, "fail:soa4:{s}", .{@tagName(std.meta.activeTag(soa4))});
        const soa4_desc = try m.inspectSyncOrAsyncAlloc(tracked_alloc, soa4);
        defer tracked_alloc.free(soa4_desc);
        if (!std.mem.eql(u8, soa4_desc, "thenable:object:false")) return std.fmt.allocPrint(out_alloc, "fail:soa4_desc:{s}", .{soa4_desc});

        // mode 5: native Promise.resolve(99) -> `.promise_like`
        const soa5 = try m.produceSyncOrAsyncAlloc(tracked_alloc, 5);
        defer js.freeDecoded(m.SyncOrAsync, tracked_alloc, soa5);
        if (std.meta.activeTag(soa5) != .promise_like) return std.fmt.allocPrint(out_alloc, "fail:soa5:{s}", .{@tagName(std.meta.activeTag(soa5))});
        const soa5_desc = try m.inspectSyncOrAsyncAlloc(tracked_alloc, soa5);
        defer tracked_alloc.free(soa5_desc);
        if (!std.mem.eql(u8, soa5_desc, "thenable:object:true")) return std.fmt.allocPrint(out_alloc, "fail:soa5_desc:{s}", .{soa5_desc});

        // `{ then: "not-a-function" }` MUST be rejected for `PromiseLike<number>` without leaking handles
        if (m.badPromiseLikeReturn()) |bad_p| {
            bad_p.deinit();
            return out_alloc.dupe(u8, "fail:bad_promise_accepted");
        } else |err| {
            if (err != error.TypeError) return out_alloc.dupe(u8, "fail:bad_promise_wrong_err");
        }
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "hetero-recursive-and-generic-unions-ok");
}
