//! Integration tests cross-validating `adapter/abi.zig`, `bindgen.zig`, and
//! `canon.zig` across custom WIT worlds and embedded WASI 0.3.0 worlds.

const std = @import("std");
const testing = std.testing;

const root = @import("root.zig");
const wit = root.wit;
const abi = root.abi;
const canon = root.canon;
const bindgen = root.bindgen;
const core_types = root.core_types;
const adapter_decode = root.component.adapter.decode;

const sample_wit_source = @embedFile("sample_wit");

fn mapCoreValType(vt: core_types.ValType) canon.FlatValType {
    return switch (vt) {
        .i32 => .i32,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        else => unreachable,
    };
}

/// Cross-validate that `abi.classifyFunc`, `abi.classifyFuncLift`,
/// `abi.lowerCoreSigForArch`, and `abi.liftCoreSigForArch` (for both `wasm32`
/// and `wasm64`) produce the exact same Canonical ABI classification and flat
/// core signatures as `canon.classifyZigFn` and `canon.CoreFnType` for `ZigFn`.
fn expectAbiMatchesCanon(
    arena: std.mem.Allocator,
    ftr: abi.FuncTypeRef,
    comptime ZigFn: type,
    comptime is_async: bool,
) !void {
    const abi_cls = abi.classifyFunc(ftr);
    const abi_lift = abi.classifyFuncLift(ftr);

    inline for (.{ canon.Arch.wasm32, canon.Arch.wasm64 }) |arch| {
        const is_wasm64 = (arch == .wasm64);
        const core_sig = try abi.lowerCoreSigForArch(arena, ftr, is_wasm64);
        const canon_opts = canon.CallOptions{ .arch = arch, .is_async = is_async, .direction = .lower };
        const canon_cls = comptime canon.classifyZigFn(ZigFn, canon_opts);

        // Flat parameter and result counts (abi.zig saturates at 32)
        try testing.expectEqual(abi_cls.params_flat, @min(canon_cls.params_flat, 32));
        try testing.expectEqual(abi_cls.results_flat, @min(canon_cls.results_flat, 32));
        try testing.expectEqual(abi_cls.has_result, canon_cls.has_result);

        // Direct vs indirect classification & canonical options
        const expect_indirect = canon_cls.needs_memory or canon_cls.params_spill;
        try testing.expectEqual(
            if (expect_indirect) abi.Class.indirect else abi.Class.direct,
            abi_cls.class,
        );
        try testing.expectEqual(abi_cls.opts.memory, canon_cls.needs_memory);
        try testing.expectEqual(abi_cls.opts.realloc, canon_cls.lower_needs_realloc);
        try testing.expectEqual(abi_cls.opts.string_encoding, canon_cls.contains_string);

        // Lift options (post_return, memory, realloc)
        try testing.expectEqual(abi_lift.needs_post_return, canon_cls.needs_post_return);
        try testing.expectEqual(abi_lift.string_encoding, canon_cls.contains_string);
        if (!is_async) {
            try testing.expectEqual(abi_lift.memory, canon_cls.needs_memory);
            try testing.expectEqual(abi_lift.realloc, canon_cls.lift_needs_realloc);
        }

        // Exact lower core parameter sequence
        try testing.expectEqual(core_sig.params.len, canon_cls.core_param_types.len);
        for (core_sig.params, canon_cls.core_param_types) |abi_pt, canon_pt| {
            try testing.expectEqual(mapCoreValType(abi_pt), canon_pt);
        }

        // Exact lower core return sequence
        if (core_sig.results.len == 0) {
            try testing.expectEqual(@as(?canon.FlatValType, null), canon_cls.core_result_type);
        } else {
            try testing.expectEqual(@as(usize, 1), core_sig.results.len);
            try testing.expectEqual(
                @as(?canon.FlatValType, mapCoreValType(core_sig.results[0])),
                canon_cls.core_result_type,
            );
        }

        // Verify @Fn-constructed CoreFnType (.lower) matches lowerCoreSigForArch
        const CoreFn = canon.CoreFnType(ZigFn, canon_opts);
        const fn_info = @typeInfo(CoreFn).@"fn";
        try testing.expectEqual(core_sig.params.len, fn_info.param_types.len);

        // Also cross-validate liftCoreSigForArch against canon (.direction = .lift)
        const lift_sig = try abi.liftCoreSigForArch(arena, ftr, is_wasm64);
        const lift_opts = canon.CallOptions{ .arch = arch, .is_async = is_async, .direction = .lift };
        const lift_cls = comptime canon.classifyZigFn(ZigFn, lift_opts);
        try testing.expectEqual(lift_sig.params.len, lift_cls.core_param_types.len);
        for (lift_sig.params, lift_cls.core_param_types) |abi_pt, canon_pt| {
            try testing.expectEqual(mapCoreValType(abi_pt), canon_pt);
        }
        if (lift_sig.results.len == 0) {
            try testing.expectEqual(@as(?canon.FlatValType, null), lift_cls.core_result_type);
        } else {
            try testing.expectEqual(@as(usize, 1), lift_sig.results.len);
            try testing.expectEqual(
                @as(?canon.FlatValType, mapCoreValType(lift_sig.results[0])),
                lift_cls.core_result_type,
            );
        }
        const LiftCoreFn = canon.CoreFnType(ZigFn, lift_opts);
        const lift_fn_info = @typeInfo(LiftCoreFn).@"fn";
        try testing.expectEqual(lift_sig.params.len, lift_fn_info.param_types.len);
    }
}

// Companion Zig types mirroring `sample.wit` for cross-validation
const SharedTypes = struct {
    pub const Color = enum(u8) { red = 0, green = 1, blue = 2, alpha = 3 };
    pub const ErrorKind = enum(u8) { invalid_input = 0, not_found = 1, timeout = 2, overflow = 3 };
    pub const Point = extern struct { x: f32, y: f32 };
    pub const Rect = extern struct {
        origin: Point,
        extent: Point,
        id: u32,
        layer: u8,
        tag: u16,
    };
    pub const PairA = extern struct { a: f32, b: i32 };
    pub const PairB = extern struct { x: i32, y: i64 };

    pub const Flags8 = packed struct(u8) {
        b0: bool = false,
        b1: bool = false,
        b2: bool = false,
        b3: bool = false,
        b4: bool = false,
        _padding: u3 = 0,
        pub const wit_flags_count: u32 = 5;
    };

    pub const Flags16 = packed struct(u16) {
        f0: bool = false,
        f1: bool = false,
        f2: bool = false,
        f3: bool = false,
        f4: bool = false,
        f5: bool = false,
        f6: bool = false,
        f7: bool = false,
        f8: bool = false,
        f9: bool = false,
        f10: bool = false,
        f11: bool = false,
        _padding: u4 = 0,
        pub const wit_flags_count: u32 = 12;
    };

    pub const Flags32 = packed struct(u32) {
        k0: bool = false,
        k1: bool = false,
        k2: bool = false,
        k3: bool = false,
        k4: bool = false,
        k5: bool = false,
        k6: bool = false,
        k7: bool = false,
        k8: bool = false,
        k9: bool = false,
        k10: bool = false,
        k11: bool = false,
        k12: bool = false,
        k13: bool = false,
        k14: bool = false,
        k15: bool = false,
        k16: bool = false,
        k17: bool = false,
        k18: bool = false,
        k19: bool = false,
        _padding: u12 = 0,
        pub const wit_flags_count: u32 = 20;
    };

    pub const Flags64 = packed struct(u64) {
        m0: bool = false,
        _mid: u38 = 0,
        m39: bool = false,
        _padding: u24 = 0,
        pub const wit_flags_count: u32 = 40;
    };

    pub const Flags70 = extern struct {
        words: [3]u32 = @splat(0),
        pub const wit_flags_count: u32 = 70;
    };

    pub const PackedFlags70 = packed struct(u96) {
        w0: bool = false,
        _low: u30 = 0,
        w31: bool = false,
        w32: bool = false,
        _mid: u30 = 0,
        w63: bool = false,
        w64: bool = false,
        _high: u4 = 0,
        w69: bool = false,
        _padding: u26 = 0,
        pub const wit_flags_count: u32 = 70;
    };

    pub const JoinI32F32 = union(enum(u8)) {
        as_int: i32,
        as_float: f32,
        empty: void,
    };

    pub const JoinI32I64 = union(enum(u8)) {
        as_int32: i32,
        as_int64: i64,
        empty: void,
    };

    pub const JoinF32F64 = union(enum(u8)) {
        as_f32: f32,
        as_f64: f64,
        empty: void,
    };

    pub const MultiSlot = union(enum(u8)) {
        first: PairA,
        second: PairB,
        third: f64,
        empty: void,
    };

    pub const ComplexRecord = struct {
        id: u64,
        label: canon.WitString,
        points: []const Point,
        tags: []const canon.WitString,
        maybe_score: ?u64,
        maybe_note: ?canon.WitString,
        outcome: canon.Result(Point, ErrorKind),
        tint: Color,
        glyph: canon.Char,
        f8: Flags8,
        f16: Flags16,
        f32_val: Flags32,
        f64_val: Flags64,
        f70: Flags70,
        v_if: JoinI32F32,
        v_ii: JoinI32I64,
        v_ff: JoinF32F64,
        v_multi: MultiSlot,
    };

    pub const Session = struct {
        handle: i32 = 0,
        pub const wit_handle_kind = canon.HandleKind.own;
    };
};

test "cross-validate adapter/abi.zig against canon.zig on rich WIT world" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const doc = try wit.parser.parse(ar, sample_wit_source, null);
    const res = try wit.resolver.finishWithEmbedded(ar, doc, &.{});
    const ct_bytes = try wit.metadata_encode.encodeWorldFromResolver(ar, res, "sample-world");
    const adapter_world = try adapter_decode.parse(ar, ct_bytes);
    const decoded_world = try wit.metadata_decode.decode(ar, ct_bytes);

    // Find `zigar:sample/host-api@0.1.0` in adapter_world.imports
    var host_api_type_idx: ?u32 = null;
    for (adapter_world.imports) |imp| {
        if (std.mem.eql(u8, imp.name, "zigar:sample/host-api@0.1.0")) {
            host_api_type_idx = imp.body_type_idx;
            break;
        }
    }
    try testing.expect(host_api_type_idx != null);

    // 1. compute-distance: direct scalar call
    {
        const ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "compute-distance");
        const ZigFn = fn (SharedTypes.Point, SharedTypes.Point) f32;
        try expectAbiMatchesCanon(ar, ftr, ZigFn, false);
    }

    // 2. merge-handles: resource Own/Borrow + P3 Stream/Future/ErrorContext
    {
        const ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "merge-handles");
        const ZigFn = fn (
            canon.Own(SharedTypes.Session),
            canon.Borrow(SharedTypes.Session),
            canon.Stream(u8),
            canon.Future(u32),
            canon.ErrorContext,
        ) canon.Own(SharedTypes.Session);
        try expectAbiMatchesCanon(ar, ftr, ZigFn, false);
    }

    // 3. flip-flags: <=8, <=16, <=32, <=64, >64 flags
    {
        const ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "flip-flags");
        const RetTuple = struct {
            @"0": SharedTypes.Flags8,
            @"1": SharedTypes.Flags16,
            @"2": SharedTypes.Flags32,
            @"3": SharedTypes.Flags64,
            @"4": SharedTypes.Flags70,
        };
        const ZigFn = fn (
            SharedTypes.Flags8,
            SharedTypes.Flags16,
            SharedTypes.Flags32,
            SharedTypes.Flags64,
            SharedTypes.Flags70,
        ) RetTuple;
        try expectAbiMatchesCanon(ar, ftr, ZigFn, false);

        // Also verify PackedFlags70 (packed struct(u96)) produces identical classification
        const RetTuplePacked = struct {
            @"0": SharedTypes.Flags8,
            @"1": SharedTypes.Flags16,
            @"2": SharedTypes.Flags32,
            @"3": SharedTypes.Flags64,
            @"4": SharedTypes.PackedFlags70,
        };
        const ZigFnPacked = fn (
            SharedTypes.Flags8,
            SharedTypes.Flags16,
            SharedTypes.Flags32,
            SharedTypes.Flags64,
            SharedTypes.PackedFlags70,
        ) RetTuplePacked;
        try expectAbiMatchesCanon(ar, ftr, ZigFnPacked, false);
    }

    // 4. process-complex: complex record + heterogeneous variants (>16 flat params -> spill, >1 flat results -> retptr)
    {
        const ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "process-complex");
        const ZigFn = fn (
            SharedTypes.ComplexRecord,
            SharedTypes.JoinI32F32,
            SharedTypes.JoinI32I64,
            SharedTypes.JoinF32F64,
        ) canon.Result(SharedTypes.ComplexRecord, SharedTypes.ErrorKind);
        try expectAbiMatchesCanon(ar, ftr, ZigFn, false);
    }

    // 5. spill-seventeen: 17 u32 params (>16 flat params spill) -> u32
    {
        const ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "spill-seventeen");
        const ZigFn = fn (
            u32, u32, u32, u32, u32, u32, u32, u32,
            u32, u32, u32, u32, u32, u32, u32, u32,
            u32,
        ) u32;
        try expectAbiMatchesCanon(ar, ftr, ZigFn, false);
    }

    // 6. async-five: async func with 5 u32 params (>4 async flat params spill) -> u64
    {
        const ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "async-five");
        const ZigFn = fn (u32, u32, u32, u32, u32) u64;
        try expectAbiMatchesCanon(ar, ftr, ZigFn, true);
    }

    // 7. format-summary: string + list<point> -> list<string> (post_return on lift, realloc on lower)
    {
        const ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "format-summary");
        const ZigFn = fn (canon.WitString, []const SharedTypes.Point) []const canon.WitString;
        try expectAbiMatchesCanon(ar, ftr, ZigFn, false);
    }

    // 8. Resource methods on `session`: constructor, method, static async
    {
        const ctor_ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "[constructor]session");
        try expectAbiMatchesCanon(ar, ctor_ftr, fn (canon.WitString) canon.Own(SharedTypes.Session), false);

        const method_ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "[method]session.get-id");
        try expectAbiMatchesCanon(ar, method_ftr, fn (canon.Borrow(SharedTypes.Session)) u64, false);

        const static_ftr = try abi.findFuncImport(adapter_world, host_api_type_idx.?, "[static]session.connect");
        try expectAbiMatchesCanon(
            ar,
            static_ftr,
            fn (canon.WitString) canon.Result(SharedTypes.Session, canon.ErrorContext),
            true,
        );
    }

    // 9. Exported `guest-service` functions via `decoded_world`
    var guest_ext: ?wit.metadata_decode.WorldExtern = null;
    for (decoded_world.externs) |ext| {
        if (ext.is_export and std.mem.eql(u8, ext.qualified_name, "zigar:sample/guest-service@0.1.0")) {
            guest_ext = ext;
            break;
        }
    }
    try testing.expect(guest_ext != null);
    for (guest_ext.?.funcs) |fref| {
        const ftr = abi.FuncTypeRef{
            .func = fref.sig,
            .resolver = .{
                .inst_decls = guest_ext.?.inst_decls,
                .world_decls = decoded_world.world_decls,
            },
        };
        if (std.mem.eql(u8, fref.name, "transform-rect")) {
            try expectAbiMatchesCanon(ar, ftr, fn (SharedTypes.Rect, f32) SharedTypes.Rect, false);
        } else if (std.mem.eql(u8, fref.name, "inspect-record")) {
            try expectAbiMatchesCanon(
                ar,
                ftr,
                fn (SharedTypes.ComplexRecord) canon.Result(canon.WitString, SharedTypes.ErrorKind),
                false,
            );
        } else if (std.mem.eql(u8, fref.name, "async-compute")) {
            try expectAbiMatchesCanon(
                ar,
                ftr,
                fn (u32, u32, u32, u32, u32) canon.Result(SharedTypes.Point, SharedTypes.ErrorKind),
                true,
            );
        }
    }
}

test "packed struct flags across all bit-width tiers (<=8, <=16, <=32, <=64, >64) store/load and flat round-trips" {
    var mem: [4096]u8 align(8) = @splat(0);
    var bump = canon.BumpAllocator.init(128, mem.len);
    const ctx = bump.memoryContext(&mem);

    const f8 = SharedTypes.Flags8{ .b0 = true, .b2 = true, .b4 = true };
    const fl16 = SharedTypes.Flags16{ .f0 = true, .f7 = true, .f11 = true };
    const f32_val = SharedTypes.Flags32{ .k0 = true, .k10 = true, .k19 = true };
    const f64_val = SharedTypes.Flags64{ .m0 = true, .m39 = true };
    const f70_packed = SharedTypes.PackedFlags70{ .w0 = true, .w31 = true, .w32 = true, .w63 = true, .w64 = true, .w69 = true };

    // Verify layouts
    try testing.expectEqual(@as(u32, 1), canon.layoutOf(SharedTypes.Flags8, .wasm32).size);
    try testing.expectEqual(@as(u32, 2), canon.layoutOf(SharedTypes.Flags16, .wasm32).size);
    try testing.expectEqual(@as(u32, 4), canon.layoutOf(SharedTypes.Flags32, .wasm32).size);
    try testing.expectEqual(@as(u32, 8), canon.layoutOf(SharedTypes.Flags64, .wasm32).size);
    try testing.expectEqual(@as(u32, 12), canon.layoutOf(SharedTypes.PackedFlags70, .wasm32).size);
    try testing.expectEqual(@as(u32, 3), canon.layoutOf(SharedTypes.PackedFlags70, .wasm32).flat_count);

    // Memory round-trip
    try canon.storeToMemory(SharedTypes.Flags8, .wasm32, ctx, 0, f8);
    try testing.expectEqual(f8, try canon.loadFromMemory(SharedTypes.Flags8, .wasm32, ctx, 0));

    try canon.storeToMemory(SharedTypes.Flags16, .wasm32, ctx, 4, fl16);
    try testing.expectEqual(fl16, try canon.loadFromMemory(SharedTypes.Flags16, .wasm32, ctx, 4));

    try canon.storeToMemory(SharedTypes.Flags32, .wasm32, ctx, 8, f32_val);
    try testing.expectEqual(f32_val, try canon.loadFromMemory(SharedTypes.Flags32, .wasm32, ctx, 8));

    try canon.storeToMemory(SharedTypes.Flags64, .wasm32, ctx, 16, f64_val);
    try testing.expectEqual(f64_val, try canon.loadFromMemory(SharedTypes.Flags64, .wasm32, ctx, 16));

    try canon.storeToMemory(SharedTypes.PackedFlags70, .wasm32, ctx, 32, f70_packed);
    try testing.expectEqual(f70_packed, try canon.loadFromMemory(SharedTypes.PackedFlags70, .wasm32, ctx, 32));

    // Flat register round-trip for every tier
    const flat8 = try canon.lowerToFlat(SharedTypes.Flags8, .wasm32, ctx, f8);
    try testing.expectEqual(f8, try canon.liftFromFlat(SharedTypes.Flags8, .wasm32, ctx, flat8));

    const flat16 = try canon.lowerToFlat(SharedTypes.Flags16, .wasm32, ctx, fl16);
    try testing.expectEqual(fl16, try canon.liftFromFlat(SharedTypes.Flags16, .wasm32, ctx, flat16));

    const flat32 = try canon.lowerToFlat(SharedTypes.Flags32, .wasm32, ctx, f32_val);
    try testing.expectEqual(f32_val, try canon.liftFromFlat(SharedTypes.Flags32, .wasm32, ctx, flat32));

    const flat64 = try canon.lowerToFlat(SharedTypes.Flags64, .wasm32, ctx, f64_val);
    try testing.expectEqual(f64_val, try canon.liftFromFlat(SharedTypes.Flags64, .wasm32, ctx, flat64));

    const flat70 = try canon.lowerToFlat(SharedTypes.PackedFlags70, .wasm32, ctx, f70_packed);
    try testing.expectEqual(f70_packed, try canon.liftFromFlat(SharedTypes.PackedFlags70, .wasm32, ctx, flat70));
}

test "post_return invocation on CanonLower -> CanonLift round-trip" {
    var mem: [16384]u8 align(8) = @splat(0);
    var bump = canon.BumpAllocator.init(256, mem.len);

    const PostReturnTracker = struct {
        called: bool = false,
        last_ret_ptr: usize = 0,
        observed_list_len: u32 = 0,
        memory: []const u8,

        fn onPostReturn(raw_ctx: ?*anyopaque, ret_ptr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.called = true;
            self.last_ret_ptr = ret_ptr;
            self.observed_list_len = std.mem.readInt(u32, self.memory[ret_ptr + 4 ..][0..4], .little);
        }
    };

    var tracker = PostReturnTracker{ .memory = &mem };
    var ctx = bump.memoryContext(&mem);
    ctx.allocator = testing.allocator;
    ctx.post_return_ctx = &tracker;
    ctx.post_return_fn = &PostReturnTracker.onPostReturn;

    const Handlers = struct {
        fn formatSummary(prefix: []const u8, items: []const SharedTypes.Point) []const []const u8 {
            _ = prefix;
            _ = items;
            const Static = struct {
                const out = [_][]const u8{ "item-0", "item-1", "summary-ok" };
            };
            return &Static.out;
        }
    };

    const FnT = @TypeOf(Handlers.formatSummary);
    const cls = canon.classifyZigFn(FnT, .{});
    try testing.expect(cls.needs_post_return);
    try testing.expect(cls.results_indirect);

    const thunk = canon.CanonLift(FnT, .{}).thunk(&Handlers.formatSummary);
    const pts = [_]SharedTypes.Point{ .{ .x = 1.0, .y = 2.0 }, .{ .x = 3.0, .y = 4.0 } };
    const result = try canon.CanonLower(FnT, .{}).call(ctx, thunk, .{ "hdr", &pts });
    defer testing.allocator.free(result);

    try testing.expect(tracker.called);
    try testing.expect(tracker.last_ret_ptr >= 256);
    try testing.expectEqual(@as(u32, 3), tracker.observed_list_len);
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("item-0", result[0]);
    try testing.expectEqualStrings("item-1", result[1]);
    try testing.expectEqualStrings("summary-ok", result[2]);
}

test "fast_abi component integration: buildComponent with embedded zigar:abi section, detectZigarAbiInComponent, and callAuto dispatch" {
    const alloc = testing.allocator;
    const fast_abi = root.fast_abi;
    const component = root.component;

    // 1. Verify bindgen output on `sample.wit` and `wasi:cli@0.2.6` contains fast_abi constructs
    const sample_zig = try bindgen.generateFromWitSource(alloc, sample_wit_source, .{});
    defer alloc.free(sample_zig);
    try testing.expect(std.mem.indexOf(u8, sample_zig, "pub const transform_rect_zigar_abi_hash: u64 = canon.fast_abi.comptimeAbiHash(transform_rect_fn_t, false);") != null);
    try testing.expect(std.mem.indexOf(u8, sample_zig, "canon.FastLift(transform_rect_fn_t, @field(Impl, \"transform_rect\"), false)") != null);
    try testing.expect(std.mem.indexOf(u8, sample_zig, "pub const zigar_abi_entries = blk: {") != null);
    try testing.expect(std.mem.indexOf(u8, sample_zig, "pub const zigar_abi = struct {") != null);

    const cli_026_zig = try bindgen.generateWasiWorldBySpec(alloc, "wasi:cli@0.2.6", .{});
    defer alloc.free(cli_026_zig);
    try testing.expect(std.mem.indexOf(u8, cli_026_zig, "pub const run_zigar_abi_hash: u64 = canon.fast_abi.comptimeAbiHash(run_fn_t, false);") != null);
    try testing.expect(std.mem.indexOf(u8, cli_026_zig, "canon.FastLift(run_fn_t, @field(Impl, \"run\"), false)") != null);
    try testing.expect(std.mem.indexOf(u8, cli_026_zig, "pub const zigar_abi = struct {") != null);

    // 2. Build a real WebAssembly Component binary from a core Wasm module that contains
    //    both embedded WIT metadata ("wasm-v1") and a "zigar:abi" custom section.
    const adder_wit =
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\  add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\  export add;
        \\}
    ;

    const AddFn = fn (u32, u32) u32;
    const AddImpl = struct {
        fn add(x: u32, y: u32) u32 {
            return x + y;
        }
    };
    const FastAddLift = fast_abi.FastLift(AddFn, AddImpl.add, false);
    const CanonAddLift = canon.CanonLift(AddFn, false);
    const CanonAddLower = canon.CanonLower(AddFn, false);

    // Core Wasm module exporting `docs:adder/add@0.1.0#add` ((i32, i32) -> i32).
    const core_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 28,   0x01,
        24,   'd',  'o',  'c',  's',  ':',  'a',  'd',
        'd',  'e',  'r',  '/',  'a',  'd',  'd',  '@',
        '0',  '.',  '1',  '.',  '0',  '#',  'a',  'd',
        'd',  0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00,
        0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
    };

    const core_with_wit = try component.embedWorldFromSource(alloc, &core_bytes, adder_wit, "adder");
    defer alloc.free(core_with_wit);

    const zigar_entries = [_]fast_abi.ZigarFuncEntry{.{
        .interface_name = "docs:adder/add@0.1.0",
        .func_name = "add",
        .fast_export_name = "__zigar_fast_docs:adder/add@0.1.0#add",
        .abi_hash = FastAddLift.abi_hash,
        .arg_struct_size = @intCast(FastAddLift.frame_layout.frame_size),
        .arg_struct_align = @intCast(FastAddLift.frame_layout.frame_align),
        .flags = FastAddLift.frame_layout.flags,
    }};
    const zigar_meta = fast_abi.ZigarAbiMetadata{
        .world_hash = fast_abi.fnv1a64("docs:adder/adder@0.1.0"),
        .entries = &zigar_entries,
    };

    const core_with_both = try fast_abi.embedZigarAbiSection(alloc, core_with_wit, zigar_meta);
    defer alloc.free(core_with_both);

    const comp_bytes = try component.buildComponent(alloc, core_with_both);
    defer alloc.free(comp_bytes);

    // 3. Detect "zigar:abi" inside the built Component binary (`core_module` section id == 1)
    const detected = (try fast_abi.detectZigarAbiInComponent(alloc, comp_bytes)).?;
    defer detected.deinit(alloc);

    try testing.expectEqual(zigar_meta.world_hash, detected.world_hash);
    try testing.expectEqual(@as(usize, 1), detected.entries.len);
    try testing.expectEqualStrings("docs:adder/add@0.1.0", detected.entries[0].interface_name);
    try testing.expectEqualStrings("add", detected.entries[0].func_name);
    try testing.expectEqual(FastAddLift.abi_hash, detected.entries[0].abi_hash);

    // 4. Dispatch via `CanonLower.callAuto` using the detected component metadata
    var mem: [1024]u8 align(16) = @splat(0);
    var ctx = canon.MemoryContext{
        .memory = &mem,
        .fast_frame_offset = 64,
    };
    const sum = try CanonAddLower.callAuto(
        &ctx,
        detected,
        "docs:adder/add@0.1.0",
        "add",
        FastAddLift.thunk(),
        CanonAddLift.thunk(&AddImpl.add),
        .{ 19, 23 },
    );
    try testing.expectEqual(@as(u32, 42), sum);
}

