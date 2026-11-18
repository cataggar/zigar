//! Issue `#50` (`M3.3a`): Smart overload synthesis — structural & optional-expansion
//! signature subsumption deduplication, deterministic semantic camelCase overload
//! naming (never numeric `_2` suffixes or `__zigar_*` internal names), and primary
//! comptime-dispatcher planning across functions, methods, constructors, and callables.

const std = @import("std");
const naming = @import("naming.zig");
const lower_types = @import("lower_types.zig");

pub const OverloadDispatchMode = union(enum) {
    /// Every overload in the group has `0` type params, no rest parameter, no optional
    /// parameter arity range, and the exact same parameter count `arity >= 1`.
    /// Emits positional `arg_0: anytype, ...` directly (`sr.write("hi")`, `ee.on("data", cb)`).
    fixed_arity: usize,
    /// Overloads span multiple arities, optional parameters, variadic rest parameters,
    /// or `comptime T: type` parameters. Emits `args: anytype` accepting both direct 1-arg
    /// calls (`Buffer.from("hi")`) and tuple calls (`Buffer.from(.{ "6869", .hex })`,
    /// `http.createServer(.{})`).
    tuple_or_single,
};

pub const BoundOverloadIdent = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
};

/// Structural equality between two lowered `TypeIr` nodes, mapping signature-local
/// `type_param_ref` identifiers canonically via `tp_names_a` / `tp_names_b`.
pub fn typeIrEqlWithTypeParams(
    a: anytype,
    b: anytype,
    tp_names_a: []const []const u8,
    tp_names_b: []const []const u8,
    depth: usize,
) bool {
    if (a == b and tp_names_a.len == 0 and tp_names_b.len == 0) return true;
    if (depth > 24) return a == b;
    if (@intFromEnum(a.*) != @intFromEnum(b.*)) return false;

    return switch (a.*) {
        .void_type,
        .noreturn_type,
        .bool_type,
        .f64_type,
        .i64_type,
        .string_type,
        .bytes_type,
        .js_value,
        .js_any,
        .js_unknown,
        .js_object,
        .js_function,
        .js_symbol,
        .js_bigint,
        .js_string,
        .js_disposable,
        .js_async_disposable,
        => true,
        .typed_slice => |ea| ea == b.typed_slice,
        .binary_view => |ba| ba == b.binary_view,
        .self_type => |sa| std.mem.eql(u8, sa, b.self_type),
        .type_param_ref => |ra| blk: {
            const rb = b.type_param_ref;
            const idx_a = indexOfStr(tp_names_a, ra);
            const idx_b = indexOfStr(tp_names_b, rb);
            if (idx_a != null or idx_b != null) {
                break :blk idx_a != null and idx_b != null and idx_a.? == idx_b.?;
            }
            break :blk std.mem.eql(u8, ra, rb);
        },
        .optional => |oa| blk: {
            const ob = b.optional;
            if (oa.nullish_kind != ob.nullish_kind or oa.is_pure_nullish != ob.is_pure_nullish) break :blk false;
            break :blk typeIrEqlWithTypeParams(oa.child, ob.child, tp_names_a, tp_names_b, depth + 1);
        },
        .pointer_const => |pa| typeIrEqlWithTypeParams(pa, b.pointer_const, tp_names_a, tp_names_b, depth + 1),
        .slice => |sa| typeIrEqlWithTypeParams(sa, b.slice, tp_names_a, tp_names_b, depth + 1),
        .promise => |pa| typeIrEqlWithTypeParams(pa, b.promise, tp_names_a, tp_names_b, depth + 1),
        .js_iterator => |ia| typeIrEqlWithTypeParams(ia, b.js_iterator, tp_names_a, tp_names_b, depth + 1),
        .js_async_iterator => |ia| typeIrEqlWithTypeParams(ia, b.js_async_iterator, tp_names_a, tp_names_b, depth + 1),
        .js_map => |ma| typeIrEqlWithTypeParams(ma.key, b.js_map.key, tp_names_a, tp_names_b, depth + 1) and
            typeIrEqlWithTypeParams(ma.value, b.js_map.value, tp_names_a, tp_names_b, depth + 1),
        .js_record => |ra| typeIrEqlWithTypeParams(ra.key, b.js_record.key, tp_names_a, tp_names_b, depth + 1) and
            typeIrEqlWithTypeParams(ra.value, b.js_record.value, tp_names_a, tp_names_b, depth + 1),
        .mapped_values_op => |ma| typeIrEqlWithTypeParams(ma.target, b.mapped_values_op.target, tp_names_a, tp_names_b, depth + 1) and
            typeIrEqlWithTypeParams(ma.value, b.mapped_values_op.value, tp_names_a, tp_names_b, depth + 1),
        .unary_type_op => |ua| ua.op == b.unary_type_op.op and
            typeIrEqlWithTypeParams(ua.operand, b.unary_type_op.operand, tp_names_a, tp_names_b, depth + 1),
        .key_filter_op => |ka| blk: {
            const kb = b.key_filter_op;
            if (ka.kind != kb.kind) break :blk false;
            if (!typeIrEqlWithTypeParams(ka.target, kb.target, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            break :blk keyFilterSpecEqlWithTypeParams(ka.keys, kb.keys, tp_names_a, tp_names_b, depth + 1);
        },
        .index_access_op => |ia| blk: {
            const ib = b.index_access_op;
            if (!typeIrEqlWithTypeParams(ia.object_ty, ib.object_ty, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            break :blk indexAccessSpecEqlWithTypeParams(ia.index_spec, ib.index_spec, tp_names_a, tp_names_b, depth + 1);
        },
        .intersect_op => |ia| blk: {
            const ib = b.intersect_op;
            if (ia.len != ib.len) break :blk false;
            for (ia, ib) |pa, pb| {
                if (!typeIrEqlWithTypeParams(pa, pb, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |ta| blk: {
            const tb = b.tuple;
            if (ta.len != tb.len) break :blk false;
            for (ta, tb) |ea, eb| {
                if (ea.is_optional != eb.is_optional or ea.is_variadic != eb.is_variadic or ea.nullish_kind != eb.nullish_kind) {
                    break :blk false;
                }
                if (!typeIrEqlWithTypeParams(ea.ty, eb.ty, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .fn_ptr => |fa| blk: {
            const fb = b.fn_ptr;
            if ((fa.this_param != null) != (fb.this_param != null)) break :blk false;
            if (fa.this_param) |tpa| {
                if (!typeIrEqlWithTypeParams(tpa, fb.this_param.?, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            }
            if (fa.params.len != fb.params.len) break :blk false;
            for (fa.params, fb.params) |pa, pb| {
                if (!typeIrEqlWithTypeParams(pa, pb, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            }
            break :blk typeIrEqlWithTypeParams(fa.return_type, fb.return_type, tp_names_a, tp_names_b, depth + 1);
        },
        .anon_struct => |fa| blk: {
            const fb = b.anon_struct;
            if (fa.len != fb.len) break :blk false;
            for (fa, fb) |xa, xb| {
                if (!std.mem.eql(u8, xa.wire_name, xb.wire_name) or
                    xa.is_optional != xb.is_optional or
                    xa.nullish_kind != xb.nullish_kind)
                {
                    break :blk false;
                }
                if (!typeIrEqlWithTypeParams(xa.ty, xb.ty, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .inline_enum => |ia| blk: {
            const ib = b.inline_enum;
            if (ia.backing != ib.backing or ia.members.len != ib.members.len) break :blk false;
            for (ia.members, ib.members) |ma, mb| {
                if (!std.mem.eql(u8, ma.wire_name, mb.wire_name)) break :blk false;
            }
            break :blk true;
        },
        .open_literal_union => |oa| blk: {
            const ob = b.open_literal_union;
            if (oa.base_kind != ob.base_kind or oa.known_members.len != ob.known_members.len) break :blk false;
            for (oa.known_members, ob.known_members) |ma, mb| {
                if (!std.mem.eql(u8, ma.wire_name, mb.wire_name)) break :blk false;
            }
            break :blk typeIrEqlWithTypeParams(oa.custom_payload, ob.custom_payload, tp_names_a, tp_names_b, depth + 1);
        },
        .template_pattern => |ta| blk: {
            const tb = b.template_pattern;
            if (!std.mem.eql(u8, ta.head, tb.head) or ta.spans.len != tb.spans.len) break :blk false;
            for (ta.spans, tb.spans) |sa, sb| {
                if (sa.placeholder != sb.placeholder or !std.mem.eql(u8, sa.literal_tail, sb.literal_tail)) break :blk false;
                if (sa.choices.len != sb.choices.len) break :blk false;
                for (sa.choices, sb.choices) |ca, cb| {
                    if (!std.mem.eql(u8, ca, cb)) break :blk false;
                }
            }
            break :blk true;
        },
        .tagged_union => |ua| blk: {
            const ub = b.tagged_union;
            if ((ua.discriminant_prop != null) != (ub.discriminant_prop != null)) break :blk false;
            if (ua.discriminant_prop) |da| {
                if (!std.mem.eql(u8, da, ub.discriminant_prop.?)) break :blk false;
            }
            if (ua.variants.len != ub.variants.len) break :blk false;
            for (ua.variants, ub.variants) |va, vb| {
                if (!std.mem.eql(u8, va.zig_ident, vb.zig_ident)) break :blk false;
                if (!typeIrEqlWithTypeParams(va.payload, vb.payload, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .decl_ref => |da| blk: {
            const db = b.decl_ref;
            if (da.module_index != db.module_index or da.target_decl_id != db.target_decl_id or da.indirect != db.indirect) {
                break :blk false;
            }
            if (da.decl_zig_path.len != db.decl_zig_path.len) break :blk false;
            for (da.decl_zig_path, db.decl_zig_path) |sa, sb| {
                if (!std.mem.eql(u8, sa, sb)) break :blk false;
            }
            if (da.type_args.len != db.type_args.len) break :blk false;
            for (da.type_args, db.type_args) |taa, tab| {
                if (!typeIrEqlWithTypeParams(taa, tab, tp_names_a, tp_names_b, depth + 1)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn keyFilterSpecEqlWithTypeParams(
    a: anytype,
    b: anytype,
    tp_names_a: []const []const u8,
    tp_names_b: []const []const u8,
    depth: usize,
) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .ty => |ta| typeIrEqlWithTypeParams(ta, b.ty, tp_names_a, tp_names_b, depth),
        .str_lit => |sa| std.mem.eql(u8, sa, b.str_lit),
        .str_list => |la| blk: {
            const lb = b.str_list;
            if (la.len != lb.len) break :blk false;
            for (la, lb) |sa, sb| {
                if (!std.mem.eql(u8, sa, sb)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn indexAccessSpecEqlWithTypeParams(
    a: anytype,
    b: anytype,
    tp_names_a: []const []const u8,
    tp_names_b: []const []const u8,
    depth: usize,
) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .ty => |ta| typeIrEqlWithTypeParams(ta, b.ty, tp_names_a, tp_names_b, depth),
        .str_lit => |sa| std.mem.eql(u8, sa, b.str_lit),
        .str_list => |la| blk: {
            const lb = b.str_list;
            if (la.len != lb.len) break :blk false;
            for (la, lb) |sa, sb| {
                if (!std.mem.eql(u8, sa, sb)) break :blk false;
            }
            break :blk true;
        },
        .int_lit => |ia| ia == b.int_lit,
    };
}

fn indexOfStr(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |item, idx| {
        if (std.mem.eql(u8, item, needle)) return idx;
    }
    return null;
}

/// Checks whether signature `a` is subsumed by signature `b` (`a <= b`):
/// calling `b` (passing `null` for any trailing optional parameters of `b`) produces
/// the exact same JS wire call and Zig return/predicate contract as `a`.
pub fn signatureSubsumedBy(
    scratch: std.mem.Allocator,
    a: anytype,
    b: anytype,
) error{OutOfMemory}!bool {
    if (a.type_params.len != b.type_params.len) return false;

    const tps_a = try scratch.alloc([]const u8, a.type_params.len);
    defer scratch.free(tps_a);
    const tps_b = try scratch.alloc([]const u8, b.type_params.len);
    defer scratch.free(tps_b);
    for (a.type_params, 0..) |tp, idx| tps_a[idx] = tp.zig_ident;
    for (b.type_params, 0..) |tp, idx| tps_b[idx] = tp.zig_ident;

    for (a.type_params, b.type_params) |tpa, tpb| {
        if ((tpa.constraint != null) != (tpb.constraint != null)) return false;
        if (tpa.constraint) |ca| {
            if (!typeIrEqlWithTypeParams(ca, tpb.constraint.?, tps_a, tps_b, 0)) return false;
        }
        if (tpa.default_type) |da| {
            const db = tpb.default_type orelse return false;
            if (!typeIrEqlWithTypeParams(da, db, tps_a, tps_b, 0)) return false;
        }
    }

    if ((a.this_param != null) != (b.this_param != null)) return false;
    if (a.this_param) |tha| {
        if (!typeIrEqlWithTypeParams(tha.ty, b.this_param.?.ty, tps_a, tps_b, 0)) return false;
    }

    if (a.has_type_predicate != b.has_type_predicate or
        a.type_predicate_asserts != b.type_predicate_asserts)
    {
        return false;
    }
    if ((a.type_predicate_target != null) != (b.type_predicate_target != null)) return false;
    if (a.type_predicate_target) |pta| {
        const ptb = b.type_predicate_target.?;
        if (std.meta.activeTag(pta.subject) != std.meta.activeTag(ptb.subject)) return false;
        switch (pta.subject) {
            .param_index => |ia| if (ia != ptb.subject.param_index) return false,
            else => {},
        }
        if (!typeIrEqlWithTypeParams(pta.target_ty, ptb.target_ty, tps_a, tps_b, 0)) return false;
    }

    if (!typeIrEqlWithTypeParams(a.return_type, b.return_type, tps_a, tps_b, 0)) return false;

    const a_has_rest = a.params.len > 0 and a.params[a.params.len - 1].is_rest;
    const b_has_rest = b.params.len > 0 and b.params[b.params.len - 1].is_rest;
    if (a_has_rest != b_has_rest) return false;
    if (a_has_rest) {
        if (a.params.len != b.params.len) return false;
    } else if (a.params.len > b.params.len) {
        return false;
    }

    for (a.params, 0..) |pa, idx| {
        const pb = b.params[idx];
        if (pa.is_rest != pb.is_rest) return false;
        if (pa.is_optional == pb.is_optional and
            pa.nullish_kind == pb.nullish_kind and
            typeIrEqlWithTypeParams(pa.ty, pb.ty, tps_a, tps_b, 0))
        {
            continue;
        }
        // Required param in `a` subsumed by `T?` optional param in `b` (allowing `undefined`).
        if (!pa.is_rest and
            !pa.is_optional and
            pa.ty.* != .optional and
            pb.is_optional and
            pb.ty.* == .optional and
            pb.ty.optional.nullish_kind != .null_only and
            typeIrEqlWithTypeParams(pa.ty, pb.ty.optional.child, tps_a, tps_b, 0))
        {
            continue;
        }
        return false;
    }

    for (b.params[a.params.len..]) |extra_b| {
        if (extra_b.is_rest) return false;
        if (!extra_b.is_optional or extra_b.ty.* != .optional) return false;
        if (extra_b.ty.optional.nullish_kind == .null_only) return false;
    }

    return true;
}

/// Returns the surviving indices of `sigs` in original declaration order after removing
/// structurally duplicate and optional-expansion-subsumed signatures.
pub fn deduplicateSubsumedIndices(
    out_alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    sigs: anytype,
) error{OutOfMemory}![]usize {
    if (sigs.len == 0) return &.{};
    if (sigs.len == 1) {
        const single = try out_alloc.alloc(usize, 1);
        single[0] = 0;
        return single;
    }

    const dropped = try scratch.alloc(bool, sigs.len);
    defer scratch.free(dropped);
    @memset(dropped, false);

    for (0..sigs.len) |i| {
        if (dropped[i]) continue;
        for (0..sigs.len) |j| {
            if (i == j or dropped[j]) continue;
            const i_sub_j = try signatureSubsumedBy(scratch, sigs[i], sigs[j]);
            if (!i_sub_j) continue;
            const j_sub_i = try signatureSubsumedBy(scratch, sigs[j], sigs[i]);
            if (j_sub_i) {
                // Mutual subsumption (identical signature): keep earlier index, drop later!
                if (i > j) {
                    dropped[i] = true;
                    break;
                }
            } else {
                // Strict subsumption (`sigs[i]` strictly narrower than `sigs[j]`): drop `i`!
                dropped[i] = true;
                break;
            }
        }
    }

    var kept: std.ArrayList(usize) = .empty;
    for (0..sigs.len) |i| {
        if (!dropped[i]) try kept.append(out_alloc, i);
    }
    return try kept.toOwnedSlice(out_alloc);
}

/// Plans how the primary comptime-dispatched `<base>` wrapper accepts arguments.
pub fn planDispatchMode(sigs: anytype) OverloadDispatchMode {
    if (sigs.len == 0) return .tuple_or_single;
    var common_arity: ?usize = null;
    for (sigs) |sig| {
        if (sig.type_params.len > 0) return .tuple_or_single;
        const explicit_this: usize = if (sig.this_param != null) 1 else 0;
        if (sig.params.len > 0 and sig.params[sig.params.len - 1].is_rest) return .tuple_or_single;
        for (sig.params) |p| {
            if (p.is_optional) return .tuple_or_single;
        }
        const total = explicit_this + sig.params.len;
        if (total == 0) return .tuple_or_single;
        if (common_arity) |ca| {
            if (ca != total) return .tuple_or_single;
        } else {
            common_arity = total;
        }
    }
    if (common_arity) |ca| {
        // Cap fixed positional `anytype` parameters at 6 for clean signatures.
        if (ca >= 1 and ca <= 6) return .{ .fixed_arity = ca };
    }
    return .tuple_or_single;
}

fn appendPascalClean(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    raw: []const u8,
) error{OutOfMemory}!void {
    const p = try naming.toPascalCase(scratch, raw);
    defer scratch.free(p);
    try buf.appendSlice(alloc, p);
}

fn isInternalAnonDeclIdent(seg: []const u8) bool {
    return std.mem.startsWith(u8, seg, "__zigar_");
}

fn appendTypeSlug(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    ty: anytype,
    param_logical_hint: ?[]const u8,
    detailed: bool,
    unique_slice_in_group: bool,
    depth: usize,
) error{OutOfMemory}!void {
    if (depth > 4) {
        try buf.appendSlice(alloc, "Value");
        return;
    }
    switch (ty.*) {
        .void_type => try buf.appendSlice(alloc, "Void"),
        .noreturn_type => try buf.appendSlice(alloc, "Never"),
        .bool_type => try buf.appendSlice(alloc, "Bool"),
        .f64_type => try buf.appendSlice(alloc, "Number"),
        .i64_type => try buf.appendSlice(alloc, "BigInt"),
        .string_type, .js_string => try buf.appendSlice(alloc, "String"),
        .bytes_type => try buf.appendSlice(alloc, "Bytes"),
        .typed_slice => |ts| {
            const tag = switch (ts) {
                .i8 => "Int8Slice",
                .u16 => "Uint16Slice",
                .i16 => "Int16Slice",
                .u32 => "Uint32Slice",
                .i32 => "Int32Slice",
                .u64 => "Uint64Slice",
                .i64 => "Int64Slice",
                .f32 => "Float32Slice",
                .f64 => "Float64Slice",
            };
            try buf.appendSlice(alloc, tag);
        },
        .binary_view => |bv| try buf.appendSlice(alloc, bv.zigTypeIdent()),
        .js_any, .js_value, .js_unknown => try buf.appendSlice(alloc, "Value"),
        .js_object => try buf.appendSlice(alloc, "Object"),
        .js_function => try buf.appendSlice(alloc, "Callback"),
        .js_symbol => try buf.appendSlice(alloc, "Symbol"),
        .js_bigint => try buf.appendSlice(alloc, "JsBigInt"),
        .js_disposable => try buf.appendSlice(alloc, "Disposable"),
        .js_async_disposable => try buf.appendSlice(alloc, "AsyncDisposable"),
        .self_type => |sid| try appendPascalClean(buf, alloc, scratch, sid),
        .type_param_ref => |tp| try appendPascalClean(buf, alloc, scratch, tp),
        .optional => |opt| {
            if (opt.is_pure_nullish) {
                try buf.appendSlice(alloc, if (opt.nullish_kind == .null_only) "Null" else "Undefined");
            } else {
                try appendTypeSlug(buf, alloc, scratch, opt.child, param_logical_hint, detailed, unique_slice_in_group, depth + 1);
                if (detailed) try buf.appendSlice(alloc, "Opt");
            }
        },
        .pointer_const => |inner| {
            try appendTypeSlug(buf, alloc, scratch, inner, param_logical_hint, detailed, unique_slice_in_group, depth + 1);
        },
        .slice => |elem| {
            if (!detailed and unique_slice_in_group) {
                try buf.appendSlice(alloc, "Slice");
            } else {
                try appendTypeSlug(buf, alloc, scratch, elem, null, false, false, depth + 1);
                try buf.appendSlice(alloc, "Slice");
            }
        },
        .promise => |inner| {
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, inner, null, false, false, depth + 1);
            }
            try buf.appendSlice(alloc, "Promise");
        },
        .js_iterator => |inner| {
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, inner, null, false, false, depth + 1);
            }
            try buf.appendSlice(alloc, "Iterator");
        },
        .js_async_iterator => |inner| {
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, inner, null, false, false, depth + 1);
            }
            try buf.appendSlice(alloc, "AsyncIterator");
        },
        .js_map => |m| {
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, m.key, null, false, false, depth + 1);
                try appendTypeSlug(buf, alloc, scratch, m.value, null, false, false, depth + 1);
            }
            try buf.appendSlice(alloc, "Map");
        },
        .js_record => |r| {
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, r.key, null, false, false, depth + 1);
                try appendTypeSlug(buf, alloc, scratch, r.value, null, false, false, depth + 1);
            }
            try buf.appendSlice(alloc, "Record");
        },
        .mapped_values_op => |mv| {
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, mv.target, null, false, false, depth + 1);
                try appendTypeSlug(buf, alloc, scratch, mv.value, null, false, false, depth + 1);
            }
            try appendTypeSlug(buf, alloc, scratch, mv.target, null, false, false, depth + 1);
            try buf.appendSlice(alloc, "Mapped");
        },
        .unary_type_op => |uo| {
            try buf.appendSlice(alloc, uo.op.runtimeHelperName());
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, uo.operand, null, false, false, depth + 1);
            }
        },
        .key_filter_op => |kf| {
            try buf.appendSlice(alloc, kf.kind.runtimeHelperName());
            if (detailed) {
                try appendTypeSlug(buf, alloc, scratch, kf.target, null, false, false, depth + 1);
            }
        },
        .index_access_op => |ia| {
            try appendTypeSlug(buf, alloc, scratch, ia.object_ty, null, false, false, depth + 1);
            try buf.appendSlice(alloc, "Prop");
        },
        .intersect_op => |arms| {
            for (arms[0..@min(arms.len, 2)], 0..) |arm, idx| {
                if (idx > 0) try buf.appendSlice(alloc, "And");
                try appendTypeSlug(buf, alloc, scratch, arm, null, false, false, depth + 1);
            }
        },
        .tuple => |elems| {
            if (detailed) {
                for (elems[0..@min(elems.len, 3)]) |el| {
                    try appendTypeSlug(buf, alloc, scratch, el.ty, null, false, false, depth + 1);
                }
            }
            try buf.appendSlice(alloc, "Tuple");
        },
        .fn_ptr => |fp| {
            try buf.appendSlice(alloc, "Callback");
            if (detailed) {
                for (fp.params[0..@min(fp.params.len, 2)]) |pt| {
                    try appendTypeSlug(buf, alloc, scratch, pt, null, false, false, depth + 1);
                }
                if (fp.return_type.* != .void_type) {
                    try buf.appendSlice(alloc, "To");
                    try appendTypeSlug(buf, alloc, scratch, fp.return_type, null, false, false, depth + 1);
                }
            }
        },
        .anon_struct => {
            if (param_logical_hint) |hint| {
                if (hint.len > 0 and !std.mem.eql(u8, hint, "arg")) {
                    try appendPascalClean(buf, alloc, scratch, hint);
                    return;
                }
            }
            try buf.appendSlice(alloc, "Options");
        },
        .inline_enum => |ie| {
            if (ie.members.len == 1) {
                try appendPascalClean(buf, alloc, scratch, ie.members[0].logical_name);
            } else if (detailed and ie.members.len >= 2) {
                try appendPascalClean(buf, alloc, scratch, ie.members[0].logical_name);
                try buf.appendSlice(alloc, "Or");
                try appendPascalClean(buf, alloc, scratch, ie.members[1].logical_name);
            } else if (param_logical_hint) |hint| {
                if (hint.len > 0 and !std.mem.eql(u8, hint, "arg")) {
                    try appendPascalClean(buf, alloc, scratch, hint);
                    return;
                }
                try buf.appendSlice(alloc, "Literal");
            } else {
                try buf.appendSlice(alloc, "Literal");
            }
        },
        .open_literal_union => try buf.appendSlice(alloc, "Literal"),
        .template_pattern => try buf.appendSlice(alloc, "Pattern"),
        .tagged_union => |tu| {
            if (detailed and tu.variants.len >= 2) {
                try appendPascalClean(buf, alloc, scratch, tu.variants[0].logical_name);
                try buf.appendSlice(alloc, "Or");
                try appendPascalClean(buf, alloc, scratch, tu.variants[1].logical_name);
            } else if (param_logical_hint) |hint| {
                if (hint.len > 0 and !std.mem.eql(u8, hint, "arg")) {
                    try appendPascalClean(buf, alloc, scratch, hint);
                    return;
                }
                try buf.appendSlice(alloc, "Union");
            } else {
                try buf.appendSlice(alloc, "Union");
            }
        },
        .decl_ref => |dr| {
            if (dr.decl_zig_path.len > 0) {
                const last = dr.decl_zig_path[dr.decl_zig_path.len - 1];
                if (isInternalAnonDeclIdent(last)) {
                    if (std.mem.startsWith(u8, last, "__zigar_AnonFn")) {
                        try buf.appendSlice(alloc, "Callback");
                    } else if (param_logical_hint) |hint| {
                        if (hint.len > 0 and !std.mem.eql(u8, hint, "arg")) {
                            try appendPascalClean(buf, alloc, scratch, hint);
                        } else {
                            try buf.appendSlice(alloc, "Options");
                        }
                    } else {
                        try buf.appendSlice(alloc, "Options");
                    }
                    return;
                }
                try appendPascalClean(buf, alloc, scratch, last);
                if (detailed and dr.type_args.len > 0) {
                    for (dr.type_args[0..@min(dr.type_args.len, 2)]) |ta| {
                        try appendTypeSlug(buf, alloc, scratch, ta, null, false, false, depth + 1);
                    }
                }
                return;
            }
            try buf.appendSlice(alloc, "Ref");
        },
    }
}

fn unwrapOptType(ty: anytype) @TypeOf(ty) {
    if (ty.* == .optional and !ty.optional.is_pure_nullish) {
        return ty.optional.child;
    }
    return ty;
}

fn isSingleLiteralEnumType(ty: anytype) ?[]const u8 {
    const inner = unwrapOptType(ty);
    if (inner.* == .inline_enum and inner.inline_enum.members.len == 1) {
        return inner.inline_enum.members[0].logical_name;
    }
    return null;
}

fn paramIsCallbackLike(p: anytype) bool {
    if (p.callback_sig != null) return true;
    const inner = unwrapOptType(p.ty);
    return inner.* == .fn_ptr or inner.* == .js_function;
}

fn paramHintName(p: anytype) []const u8 {
    if (@hasField(@TypeOf(p), "wire_name")) {
        if (p.wire_name.len > 0 and !std.mem.eql(u8, p.wire_name, "_")) {
            return p.wire_name;
        }
    }
    return p.logical_name;
}

fn buildTier1Suffix(
    scratch: std.mem.Allocator,
    sigs: anytype,
    idx: usize,
    unique_slice_first_param: bool,
) error{OutOfMemory}![]u8 {
    const sig = sigs[idx];
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(scratch);

    if (sig.params.len == 0) {
        if (sig.this_param) |thp| {
            try buf.appendSlice(scratch, "On");
            try appendTypeSlug(&buf, scratch, scratch, thp.ty, null, false, false, 0);
            return try buf.toOwnedSlice(scratch);
        }
        try buf.appendSlice(scratch, "Empty");
        return try buf.toOwnedSlice(scratch);
    }

    // 1. Single-literal discriminator parameter (`on("data", cb)` -> `onData`, `readFile(p, "utf8", cb)` -> `readFileUtf8`).
    for (sig.params) |p| {
        if (isSingleLiteralEnumType(p.ty)) |lit_name| {
            try appendPascalClean(&buf, scratch, scratch, lit_name);
            return try buf.toOwnedSlice(scratch);
        }
    }

    // 2. Single-parameter overload (`from(str)` -> `fromString`, `from(arr)` -> `fromSlice`, `from(u8a)` -> `fromUint8Array`).
    if (sig.params.len == 1) {
        const p0 = sig.params[0];
        if (p0.is_rest) {
            try buf.appendSlice(scratch, "Variadic");
            return try buf.toOwnedSlice(scratch);
        }
        try appendTypeSlug(&buf, scratch, scratch, p0.ty, paramHintName(p0), false, unique_slice_first_param, 0);
        return try buf.toOwnedSlice(scratch);
    }

    // 3. Trailing-callback vs `(..., options, callback)` pattern (`readFileCallback` vs `readFileWithOptions`).
    const last_p = sig.params[sig.params.len - 1];
    if (paramIsCallbackLike(last_p)) {
        var has_longer_cb_peer = false;
        var has_shorter_cb_peer = false;
        for (sigs, 0..) |peer, pidx| {
            if (pidx == idx or peer.params.len == 0) continue;
            if (paramIsCallbackLike(peer.params[peer.params.len - 1])) {
                if (peer.params.len > sig.params.len) has_longer_cb_peer = true;
                if (peer.params.len < sig.params.len) has_shorter_cb_peer = true;
            }
        }
        if (has_longer_cb_peer and !has_shorter_cb_peer) {
            try buf.appendSlice(scratch, "Callback");
            return try buf.toOwnedSlice(scratch);
        }
        if (has_shorter_cb_peer and sig.params.len >= 2) {
            const mid = sig.params[sig.params.len - 2];
            const mid_hint = paramHintName(mid);
            if (mid_hint.len > 0 and !std.mem.eql(u8, mid_hint, "arg")) {
                try buf.appendSlice(scratch, "With");
                try appendPascalClean(&buf, scratch, scratch, mid_hint);
                return try buf.toOwnedSlice(scratch);
            }
        }
    }

    // 4. Overload extending a shorter peer's prefix (`init(endpoint)` + `init(endpoint, timeout)` -> `initWithTimeout`).
    var extends_shorter = false;
    var min_peer_len: usize = sig.params.len;
    for (sigs, 0..) |peer, pidx| {
        if (pidx == idx) continue;
        if (peer.params.len < sig.params.len and peer.params.len > 0) {
            var prefix_matches = true;
            for (0..peer.params.len) |pi| {
                if (!typeIrEqlWithTypeParams(unwrapOptType(sig.params[pi].ty), unwrapOptType(peer.params[pi].ty), &.{}, &.{}, 0)) {
                    prefix_matches = false;
                    break;
                }
            }
            if (prefix_matches) {
                extends_shorter = true;
                if (peer.params.len < min_peer_len) min_peer_len = peer.params.len;
            }
        }
    }
    if (extends_shorter) {
        const extra = sig.params[min_peer_len];
        const extra_hint = paramHintName(extra);
        if (extra.is_rest) {
            try buf.appendSlice(scratch, "Variadic");
            return try buf.toOwnedSlice(scratch);
        }
        if (extra_hint.len > 0 and !std.mem.eql(u8, extra_hint, "arg")) {
            try buf.appendSlice(scratch, "With");
            try appendPascalClean(&buf, scratch, scratch, extra_hint);
            return try buf.toOwnedSlice(scratch);
        }
        try buf.appendSlice(scratch, "With");
        try appendTypeSlug(&buf, scratch, scratch, extra.ty, extra_hint, false, false, 0);
        return try buf.toOwnedSlice(scratch);
    }

    // 5. Find first parameter index whose type differs across same-or-longer peers; otherwise summarize first param.
    var diff_idx: usize = 0;
    for (0..sig.params.len) |pi| {
        var differs = false;
        for (sigs, 0..) |peer, pidx| {
            if (pidx == idx or pi >= peer.params.len) continue;
            if (!typeIrEqlWithTypeParams(unwrapOptType(sig.params[pi].ty), unwrapOptType(peer.params[pi].ty), &.{}, &.{}, 0)) {
                differs = true;
                break;
            }
        }
        if (differs) {
            diff_idx = pi;
            break;
        }
    }
    const dp = sig.params[diff_idx];
    try appendTypeSlug(&buf, scratch, scratch, dp.ty, paramHintName(dp), false, diff_idx == 0 and unique_slice_first_param, 0);
    return try buf.toOwnedSlice(scratch);
}

fn buildTier2Suffix(scratch: std.mem.Allocator, sig: anytype) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(scratch);

    if (sig.params.len == 0) {
        try buf.appendSlice(scratch, "NoArgs");
        return try buf.toOwnedSlice(scratch);
    }
    for (sig.params) |p| {
        if (p.is_rest) try buf.appendSlice(scratch, "Rest");
        try appendTypeSlug(&buf, scratch, scratch, p.ty, paramHintName(p), true, false, 0);
    }
    return try buf.toOwnedSlice(scratch);
}

fn buildTier3Suffix(scratch: std.mem.Allocator, sig: anytype) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(scratch);

    if (sig.this_param) |thp| {
        try buf.appendSlice(scratch, "On");
        try appendTypeSlug(&buf, scratch, scratch, thp.ty, null, true, false, 0);
    }
    if (sig.type_params.len > 0) {
        try buf.appendSlice(scratch, "Generic");
        for (sig.type_params) |tp| {
            try appendPascalClean(&buf, scratch, scratch, tp.logical_name);
        }
    }
    for (sig.params) |p| {
        const p_hint = paramHintName(p);
        if (p_hint.len > 0 and !std.mem.eql(u8, p_hint, "arg")) {
            try appendPascalClean(&buf, scratch, scratch, p_hint);
        }
        if (p.callback_sig) |cbs| {
            try buf.appendSlice(scratch, "Cb");
            for (cbs.params) |cpt| {
                try appendTypeSlug(&buf, scratch, scratch, cpt, null, true, false, 0);
            }
            if (cbs.return_type.* != .void_type) {
                try buf.appendSlice(scratch, "Ret");
                try appendTypeSlug(&buf, scratch, scratch, cbs.return_type, null, true, false, 0);
            }
        } else {
            try appendTypeSlug(&buf, scratch, scratch, p.ty, p_hint, true, false, 0);
        }
    }
    if (sig.return_type.* != .void_type) {
        try buf.appendSlice(scratch, "Returning");
        try appendTypeSlug(&buf, scratch, scratch, sig.return_type, null, true, false, 0);
    }
    return try buf.toOwnedSlice(scratch);
}

const word_ordinals = [_][]const u8{
    "First",
    "Second",
    "Third",
    "Fourth",
    "Fifth",
    "Sixth",
    "Seventh",
    "Eighth",
    "Ninth",
    "Tenth",
    "Eleventh",
    "Twelfth",
    "Thirteenth",
    "Fourteenth",
    "Fifteenth",
    "Sixteenth",
    "Seventeenth",
    "Eighteenth",
    "Nineteenth",
    "Twentieth",
};

fn makeBaseWithSuffixCamel(
    scratch: std.mem.Allocator,
    base_logical: []const u8,
    suffix_pascal: []const u8,
) error{OutOfMemory}![]u8 {
    const joined = try std.fmt.allocPrint(scratch, "{s}{s}", .{ base_logical, suffix_pascal });
    defer scratch.free(joined);
    return try naming.toCamelCase(scratch, joined);
}

fn candidateCollides(
    cands: []const []u8,
    self_idx: usize,
    scope: *const naming.ScopeNamer,
    base_logical: []const u8,
) bool {
    const me = cands[self_idx];
    if (me.len == 0) return true;
    if (std.mem.eql(u8, me, base_logical)) return true;
    if (scope.isTaken(me)) return true;
    for (cands, 0..) |other, oidx| {
        if (oidx != self_idx and std.mem.eql(u8, me, other)) return true;
    }
    return false;
}

/// Assigns deterministic, human-readable, collision-free camelCase overload identifiers
/// to `sigs` (`sigs.len >= 2`) and binds them into `scope`.
///
/// Guarantees:
/// - Never produces `_2`, `_3`, or numeric collision suffixes.
/// - Never leaks `__zigar_*` internal helper names.
/// - Leaves `base_logical` free (or already bound) for the primary comptime dispatcher.
pub fn assignSemanticOverloadNames(
    out_alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    scope: *naming.ScopeNamer,
    base_logical: []const u8,
    sigs: anytype,
) error{OutOfMemory}![]BoundOverloadIdent {
    const n = sigs.len;
    var slice_first_count: usize = 0;
    for (sigs) |sig| {
        if (sig.params.len > 0 and unwrapOptType(sig.params[0].ty).* == .slice) {
            slice_first_count += 1;
        }
    }
    const unique_slice_first = slice_first_count == 1;

    var cands = try scratch.alloc([]u8, n);
    defer {
        for (cands) |c| scratch.free(c);
        scratch.free(cands);
    }

    // Tier 1: concise idiomatic names (`fromString`, `fromSlice`, `readFileCallback`, `readFileWithOptions`, `onData`).
    for (0..n) |i| {
        const suf = try buildTier1Suffix(scratch, sigs, i, unique_slice_first);
        defer scratch.free(suf);
        cands[i] = try makeBaseWithSuffixCamel(scratch, base_logical, suf);
    }

    // Tier 2: escalate only colliding indices to detailed parameter signature slugs.
    {
        const needs_t2 = try scratch.alloc(bool, n);
        defer scratch.free(needs_t2);
        for (0..n) |i| needs_t2[i] = candidateCollides(cands, i, scope, base_logical);
        for (0..n) |i| {
            if (!needs_t2[i]) continue;
            const suf = try buildTier2Suffix(scratch, sigs[i]);
            defer scratch.free(suf);
            scratch.free(cands[i]);
            cands[i] = try makeBaseWithSuffixCamel(scratch, base_logical, suf);
        }
    }

    // Tier 3: escalate remaining collisions to full param-name + callback + return + generic qualifier.
    {
        const needs_t3 = try scratch.alloc(bool, n);
        defer scratch.free(needs_t3);
        for (0..n) |i| needs_t3[i] = candidateCollides(cands, i, scope, base_logical);
        for (0..n) |i| {
            if (!needs_t3[i]) continue;
            const suf = try buildTier3Suffix(scratch, sigs[i]);
            defer scratch.free(suf);
            scratch.free(cands[i]);
            cands[i] = try makeBaseWithSuffixCamel(scratch, base_logical, suf);
        }
    }

    // Tier 4: deterministic English word-ordinal disambiguator (`First`, `Second`, ..., `VariantA`, `VariantB`, ...).
    var out = try out_alloc.alloc(BoundOverloadIdent, n);
    for (0..n) |i| {
        if (candidateCollides(cands, i, scope, base_logical)) {
            var resolved: ?[]u8 = null;
            for (word_ordinals) |ord| {
                const attempt_raw = try std.fmt.allocPrint(scratch, "{s}{s}", .{ cands[i], ord });
                defer scratch.free(attempt_raw);
                const attempt = try naming.toCamelCase(scratch, attempt_raw);
                if (attempt.len > 0 and !std.mem.eql(u8, attempt, base_logical) and !scope.isTaken(attempt)) {
                    var dup_later = false;
                    for (i + 1..n) |k| {
                        if (std.mem.eql(u8, attempt, cands[k])) {
                            dup_later = true;
                            break;
                        }
                    }
                    if (!dup_later) {
                        resolved = attempt;
                        break;
                    }
                }
                scratch.free(attempt);
            }
            if (resolved == null) {
                // Alphabetic `VariantA` .. `VariantZZ` (zero digits!).
                outer: for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |ch1| {
                    const attempt1_raw = try std.fmt.allocPrint(scratch, "{s}Variant{c}", .{ cands[i], ch1 });
                    defer scratch.free(attempt1_raw);
                    const attempt1 = try naming.toCamelCase(scratch, attempt1_raw);
                    if (!scope.isTaken(attempt1) and !std.mem.eql(u8, attempt1, base_logical)) {
                        resolved = attempt1;
                        break :outer;
                    }
                    scratch.free(attempt1);
                    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |ch2| {
                        const attempt2_raw = try std.fmt.allocPrint(scratch, "{s}Variant{c}{c}", .{ cands[i], ch1, ch2 });
                        defer scratch.free(attempt2_raw);
                        const attempt2 = try naming.toCamelCase(scratch, attempt2_raw);
                        if (!scope.isTaken(attempt2) and !std.mem.eql(u8, attempt2, base_logical)) {
                            resolved = attempt2;
                            break :outer;
                        }
                        scratch.free(attempt2);
                    }
                }
            }
            if (resolved) |res| {
                scratch.free(cands[i]);
                cands[i] = res;
            }
        }

        const bound = try scope.bind(cands[i], .camel);
        defer bound.deinit(scratch);
        out[i] = .{
            .zig_ident = try out_alloc.dupe(u8, bound.zig_ident),
            .logical_name = try out_alloc.dupe(u8, bound.logical_name),
        };
    }

    return out;
}

test "overloads: subsumption deduplication and deterministic semantic naming without _2 suffixes" {
    const alloc = std.testing.allocator;
    const MockType = union(enum) {
        const SelfT = @This();
        void_type,
        noreturn_type,
        bool_type,
        f64_type,
        i64_type,
        string_type,
        bytes_type,
        typed_slice: enum { i8, u16, i16, u32, i32, u64, i64, f32, f64 },
        js_value,
        js_any,
        js_unknown,
        js_object,
        js_function,
        js_symbol,
        js_bigint,
        js_string,
        js_disposable,
        js_async_disposable,
        binary_view: lower_types.BinaryViewKind,
        self_type: []const u8,
        type_param_ref: []const u8,
        optional: struct {
            child: *const SelfT,
            nullish_kind: lower_types.NullishKind = .null_or_undefined,
            is_pure_nullish: bool = false,
        },
        pointer_const: *const SelfT,
        slice: *const SelfT,
        promise: *const SelfT,
        js_iterator: *const SelfT,
        js_async_iterator: *const SelfT,
        js_map: struct { key: *const SelfT, value: *const SelfT },
        js_record: struct { key: *const SelfT, value: *const SelfT },
        mapped_values_op: struct { target: *const SelfT, value: *const SelfT },
        unary_type_op: struct {
            op: @import("type_ops.zig").UnaryTypeOp,
            operand: *const SelfT,
        },
        key_filter_op: struct {
            kind: @import("type_ops.zig").KeyFilterKind,
            target: *const SelfT,
            keys: union(enum) {
                ty: *const SelfT,
                str_lit: []const u8,
                str_list: []const []const u8,
            },
        },
        index_access_op: struct {
            object_ty: *const SelfT,
            index_spec: union(enum) {
                ty: *const SelfT,
                str_lit: []const u8,
                str_list: []const []const u8,
                int_lit: usize,
            },
        },
        intersect_op: []const *const SelfT,
        tuple: []const struct {
            ty: *const SelfT,
            is_optional: bool = false,
            is_variadic: bool = false,
            nullish_kind: lower_types.NullishKind = .none,
        },
        fn_ptr: struct {
            this_param: ?*const SelfT = null,
            params: []const *const SelfT,
            return_type: *const SelfT,
        },
        anon_struct: []const struct {
            wire_name: []const u8,
            ty: *const SelfT,
            is_optional: bool = false,
            nullish_kind: lower_types.NullishKind = .none,
        },
        inline_enum: struct {
            backing: u8 = 0,
            members: []const struct { logical_name: []const u8, wire_name: []const u8 },
        },
        open_literal_union: struct {
            base_kind: u8 = 0,
            known_members: []const struct { wire_name: []const u8 },
            custom_payload: *const SelfT,
        },
        template_pattern: struct {
            head: []const u8,
            spans: []const struct { placeholder: u8, choices: []const []const u8, literal_tail: []const u8 },
        },
        tagged_union: struct {
            discriminant_prop: ?[]const u8 = null,
            variants: []const struct { zig_ident: []const u8, logical_name: []const u8, payload: *const SelfT },
        },
        decl_ref: struct {
            module_index: u32 = 0,
            decl_zig_path: []const []const u8,
            target_decl_id: u32 = 1,
            type_args: []const *const SelfT = &.{},
            indirect: bool = false,
        },
    };
    const MockParam = struct {
        logical_name: []const u8,
        ty: *const MockType,
        is_optional: bool = false,
        is_rest: bool = false,
        nullish_kind: lower_types.NullishKind = .none,
        callback_sig: ?*const struct {
            params: []const *const MockType,
            return_type: *const MockType,
        } = null,
    };
    const MockTp = struct {
        zig_ident: []const u8,
        logical_name: []const u8,
        constraint: ?*const MockType = null,
        default_type: ?*const MockType = null,
    };
    const MockSig = struct {
        type_params: []const MockTp = &.{},
        this_param: ?struct { ty: *const MockType } = null,
        params: []const MockParam,
        return_type: *const MockType,
        has_type_predicate: bool = false,
        type_predicate_asserts: bool = false,
        type_predicate_target: ?struct {
            subject: union(enum) { self_receiver, explicit_this, param_index: usize },
            target_ty: *const MockType,
        } = null,
    };

    const t_str: MockType = .string_type;
    const t_num: MockType = .f64_type;
    const t_opt_num: MockType = .{ .optional = .{ .child = &t_num, .nullish_kind = .undefined_only } };
    const t_slice_num: MockType = .{ .slice = &t_num };
    const t_u8a: MockType = .{ .binary_view = .uint8_array };
    const t_buf: MockType = .{ .binary_view = .buffer };

    // `from(s: string): Buffer` is subsumed by `from(s: string, enc?: number): Buffer`!
    const sigs = [_]MockSig{
        .{
            .params = &.{.{ .logical_name = "str", .ty = &t_str }},
            .return_type = &t_buf,
        },
        .{
            .params = &.{
                .{ .logical_name = "str", .ty = &t_str },
                .{ .logical_name = "encoding", .ty = &t_opt_num, .is_optional = true, .nullish_kind = .undefined_only },
            },
            .return_type = &t_buf,
        },
        .{
            .params = &.{.{ .logical_name = "array", .ty = &t_slice_num }},
            .return_type = &t_buf,
        },
        .{
            .params = &.{.{ .logical_name = "view", .ty = &t_u8a }},
            .return_type = &t_buf,
        },
    };

    const kept = try deduplicateSubsumedIndices(alloc, alloc, &sigs);
    defer alloc.free(kept);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, kept);

    const dedup = [_]MockSig{ sigs[1], sigs[2], sigs[3] };
    var scope = naming.ScopeNamer.initContainer(alloc, null);
    defer scope.deinit();
    try scope.reserve("from");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const names = try assignSemanticOverloadNames(arena.allocator(), alloc, &scope, "from", &dedup);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("fromString", names[0].zig_ident);
    try std.testing.expectEqualStrings("fromSlice", names[1].zig_ident);
    try std.testing.expectEqualStrings("fromUint8Array", names[2].zig_ident);
}
