const std = @import("std");

/// TypeScript 4.7+ explicit variance annotations (`in`, `out`, `in out`).
pub const Variance = enum {
    invariant,
    covariant,
    contravariant,
    bivariant,
};

pub fn classifyVariance(in_variance: bool, out_variance: bool) Variance {
    if (in_variance and out_variance) return .bivariant;
    if (out_variance) return .covariant;
    if (in_variance) return .contravariant;
    return .invariant;
}

pub fn varianceKeyword(v: Variance) ?[]const u8 {
    return switch (v) {
        .invariant => null,
        .covariant => "out",
        .contravariant => "in",
        .bivariant => "in out",
    };
}

/// Summary of required vs. trailing-defaulted type parameters on a generic
/// declaration or signature.
pub const DefaultPrefixInfo = struct {
    /// Index past the last type parameter that has no default (`0` when all have defaults).
    required_count: usize,
    /// Number of trailing type parameters that all carry defaults.
    defaulted_count: usize,
    /// Emit `<Name>Default` / `<fn>Default` taking only `0..required_count` comptime type args.
    emit_default_companion: bool,
    /// Emit `<Name>With(comptime args_tuple: anytype) type` for multi-param partial application.
    emit_with_companion: bool,
};

pub fn analyzeDefaultPrefix(has_defaults: []const bool) DefaultPrefixInfo {
    if (has_defaults.len == 0) {
        return .{
            .required_count = 0,
            .defaulted_count = 0,
            .emit_default_companion = false,
            .emit_with_companion = false,
        };
    }
    var req_count: usize = 0;
    for (has_defaults, 0..) |has_def, idx| {
        if (!has_def) req_count = idx + 1;
    }
    const def_count = has_defaults.len - req_count;
    return .{
        .required_count = req_count,
        .defaulted_count = def_count,
        .emit_default_companion = def_count > 0,
        .emit_with_companion = has_defaults.len >= 2 and def_count > 0,
    };
}

/// How a signature's type parameter `T` can be deduced from a value argument in `<fn>Infer`.
pub const InferMode = enum {
    /// Parameter has direct type `T`; deduce via `__zigar_js.InferJsType(@TypeOf(arg))`
    /// (or `__zigar_js.InferConstJsType(@TypeOf(arg))` when `is_const` is set).
    direct,
    /// Parameter has type `?T`; deduce via `__zigar_js.InferOptionalChild(@TypeOf(arg))`.
    optional_child,
    /// Parameter has type `[]const T`; deduce via `__zigar_js.InferSliceElem(@TypeOf(arg))`.
    slice_elem,
    /// Parameter has type `Promise(T)`; deduce via `__zigar_js.Awaited(@TypeOf(arg))`.
    promise_payload,
    /// Parameter has type `Iterator(T)` or `AsyncIterator(T)`; deduce via `__zigar_js.InferIteratorElem(@TypeOf(arg))`.
    iterator_elem,
    /// Type parameter not present in value params, resolved from its TypeScript default (`= DefaultT`).
    from_default,
};

pub const ParamTypeParamShape = union(enum) {
    none,
    direct: usize,
    optional_child: usize,
    slice_elem: usize,
    promise_payload: usize,
    iterator_elem: usize,
};

pub const InferBinding = struct {
    param_index: usize,
    mode: InferMode,
};

/// Solves a complete comptime deduction plan mapping every `tp_idx` in `0..tp_count`
/// to a required value parameter (`0..required_param_shapes.len`).
/// Returns `null` when `tp_count == 0` or any type parameter cannot be deduced from
/// required value arguments (for example, return-type-only generics like `parse<T>(s: string): T`).
pub fn solveTypeParamInference(
    allocator: std.mem.Allocator,
    tp_count: usize,
    required_param_shapes: []const ParamTypeParamShape,
) error{OutOfMemory}!?[]InferBinding {
    if (tp_count == 0) return null;

    var chosen = try allocator.alloc(?InferBinding, tp_count);
    defer allocator.free(chosen);
    @memset(chosen, null);

    // Prefer `.direct` bindings over wrapper unwrapping (`.slice_elem`, `.optional_child`, `.promise_payload`).
    for (required_param_shapes, 0..) |shape, pidx| {
        switch (shape) {
            .none => {},
            .direct => |tp_idx| {
                if (tp_idx < tp_count and (chosen[tp_idx] == null or chosen[tp_idx].?.mode != .direct)) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .direct };
                }
            },
            .slice_elem => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .slice_elem };
                }
            },
            .optional_child => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .optional_child };
                }
            },
            .promise_payload => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .promise_payload };
                }
            },
            .iterator_elem => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .iterator_elem };
                }
            },
        }
    }

    for (chosen) |entry| {
        if (entry == null) return null;
    }

    const out = try allocator.alloc(InferBinding, tp_count);
    for (chosen, 0..) |entry, idx| {
        out[idx] = entry.?;
    }
    return out;
}

/// Like `solveTypeParamInference`, but also allows un-deduced type parameters that declare
/// a TypeScript default (`has_defaults[tp_idx] == true`) to fall back to `.from_default`
/// as long as at least one type parameter is genuinely deduced from a value argument.
pub fn solveTypeParamInferenceWithDefaults(
    allocator: std.mem.Allocator,
    tp_count: usize,
    has_defaults: []const bool,
    param_shapes: []const ParamTypeParamShape,
) error{OutOfMemory}!?[]InferBinding {
    if (tp_count == 0) return null;

    var chosen = try allocator.alloc(?InferBinding, tp_count);
    defer allocator.free(chosen);
    @memset(chosen, null);

    for (param_shapes, 0..) |shape, pidx| {
        switch (shape) {
            .none => {},
            .direct => |tp_idx| {
                if (tp_idx < tp_count and (chosen[tp_idx] == null or chosen[tp_idx].?.mode != .direct)) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .direct };
                }
            },
            .slice_elem => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .slice_elem };
                }
            },
            .optional_child => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .optional_child };
                }
            },
            .promise_payload => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .promise_payload };
                }
            },
            .iterator_elem => |tp_idx| {
                if (tp_idx < tp_count and chosen[tp_idx] == null) {
                    chosen[tp_idx] = .{ .param_index = pidx, .mode = .iterator_elem };
                }
            },
        }
    }

    var any_from_param = false;
    for (chosen, 0..) |*slot, idx| {
        if (slot.* != null) {
            any_from_param = true;
        } else if (idx < has_defaults.len and has_defaults[idx]) {
            slot.* = .{ .param_index = 0, .mode = .from_default };
        } else {
            return null;
        }
    }
    if (!any_from_param) return null;

    const out = try allocator.alloc(InferBinding, tp_count);
    for (chosen, 0..) |entry, idx| {
        out[idx] = entry.?;
    }
    return out;
}

/// How a fixed overload parameter references one of the candidate signature's own `type_params`
/// so `candidateScore` can validate caller arguments against explicit comptime type args.
pub const OverloadGenericParamMode = enum {
    none,
    direct,
    optional_child,
    slice_elem,
    promise_payload,
    iterator_elem,
    async_iterator_elem,
};

pub const OverloadGenericParamRef = struct {
    tp_idx: ?usize = null,
    mode: OverloadGenericParamMode = .none,
};

/// Formats an informative `@typeParam` JSDoc line when a type parameter carries `const`,
/// variance (`in`/`out`/`in out`), constraint, or default metadata.
pub fn formatTypeParamDocLine(
    allocator: std.mem.Allocator,
    zig_ident: []const u8,
    is_const: bool,
    variance: Variance,
    constraint_summary: ?[]const u8,
    default_summary: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    const v_kw = varianceKeyword(variance);
    if (!is_const and v_kw == null and constraint_summary == null and default_summary == null) {
        return null;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "@typeParam ");
    if (is_const) try buf.appendSlice(allocator, "const ");
    if (v_kw) |vk| {
        try buf.appendSlice(allocator, vk);
        try buf.append(allocator, ' ');
    }
    try buf.appendSlice(allocator, zig_ident);
    if (constraint_summary) |cs| {
        try buf.appendSlice(allocator, " extends ");
        try buf.appendSlice(allocator, cs);
    }
    if (default_summary) |ds| {
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, ds);
    }
    return try buf.toOwnedSlice(allocator);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "classifyVariance maps TypeScript in/out variance modifiers" {
    try std.testing.expectEqual(Variance.invariant, classifyVariance(false, false));
    try std.testing.expectEqual(Variance.covariant, classifyVariance(false, true));
    try std.testing.expectEqual(Variance.contravariant, classifyVariance(true, false));
    try std.testing.expectEqual(Variance.bivariant, classifyVariance(true, true));
}

test "analyzeDefaultPrefix handles required prefix and trailing defaults" {
    const none = analyzeDefaultPrefix(&.{ false, false });
    try std.testing.expectEqual(@as(usize, 2), none.required_count);
    try std.testing.expectEqual(@as(usize, 0), none.defaulted_count);
    try std.testing.expect(!none.emit_default_companion);
    try std.testing.expect(!none.emit_with_companion);

    const single_all_def = analyzeDefaultPrefix(&.{true});
    try std.testing.expectEqual(@as(usize, 0), single_all_def.required_count);
    try std.testing.expectEqual(@as(usize, 1), single_all_def.defaulted_count);
    try std.testing.expect(single_all_def.emit_default_companion);
    try std.testing.expect(!single_all_def.emit_with_companion);

    const chain = analyzeDefaultPrefix(&.{ false, true, true });
    try std.testing.expectEqual(@as(usize, 1), chain.required_count);
    try std.testing.expectEqual(@as(usize, 2), chain.defaulted_count);
    try std.testing.expect(chain.emit_default_companion);
    try std.testing.expect(chain.emit_with_companion);

    // Non-trailing default followed by required param cannot omit the first param alone.
    const non_trailing = analyzeDefaultPrefix(&.{ true, false });
    try std.testing.expectEqual(@as(usize, 2), non_trailing.required_count);
    try std.testing.expectEqual(@as(usize, 0), non_trailing.defaulted_count);
    try std.testing.expect(!non_trailing.emit_default_companion);
}

test "solveTypeParamInference deduces direct, slice, optional, and rejects return-only generics" {
    const alloc = std.testing.allocator;

    // `fn pair<A, B>(a: A, items: readonly B[]): [A, B]`
    const plan_opt = try solveTypeParamInference(alloc, 2, &.{
        .{ .direct = 0 },
        .{ .slice_elem = 1 },
    });
    try std.testing.expect(plan_opt != null);
    defer alloc.free(plan_opt.?);
    try std.testing.expectEqual(@as(usize, 0), plan_opt.?[0].param_index);
    try std.testing.expectEqual(InferMode.direct, plan_opt.?[0].mode);
    try std.testing.expectEqual(@as(usize, 1), plan_opt.?[1].param_index);
    try std.testing.expectEqual(InferMode.slice_elem, plan_opt.?[1].mode);

    // Prefer `.direct` over `.slice_elem` when `T` appears in both.
    const prefer_direct = (try solveTypeParamInference(alloc, 1, &.{
        .{ .slice_elem = 0 },
        .{ .direct = 0 },
    })).?;
    defer alloc.free(prefer_direct);
    try std.testing.expectEqual(@as(usize, 1), prefer_direct[0].param_index);
    try std.testing.expectEqual(InferMode.direct, prefer_direct[0].mode);

    // `fn parseJson<T>(raw: string): T` -> return-only `T` cannot be inferred.
    const uninferrable = try solveTypeParamInference(alloc, 1, &.{.none});
    try std.testing.expect(uninferrable == null);
}

test "formatTypeParamDocLine renders const, variance, constraint, and default" {
    const alloc = std.testing.allocator;

    const plain = try formatTypeParamDocLine(alloc, "T", false, .invariant, null, null);
    try std.testing.expect(plain == null);

    const rich = (try formatTypeParamDocLine(alloc, "T", true, .covariant, "[]const u8", "__zigar_js.Any")).?;
    defer alloc.free(rich);
    try std.testing.expectEqualStrings("@typeParam const out T extends []const u8 = __zigar_js.Any", rich);
}
