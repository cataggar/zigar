//! Issue `#50` (`M3.3a`): Function, method, constructor, callback, explicit `this`,
//! variadic rest parameter (`*Slice` companion), and `is` / `asserts` type-predicate
//! lowering helpers.

const std = @import("std");
const naming = @import("naming.zig");

/// Identifies which runtime value is narrowed by a TypeScript type predicate
/// (`x is T`, `this is T`, `asserts x is T`, `asserts this is T`).
pub const TypePredicateSubject = union(enum) {
    /// Instance method `this is T` narrowing `self`.
    self_receiver,
    /// Standalone / call-signature `this is T` narrowing the explicit `this` parameter.
    explicit_this,
    /// Parameter `params[idx]` (`x is T` / `asserts x is T`).
    param_index: usize,
};

/// Returns true when a signature's `this: T` annotation must be emitted as an explicit
/// leading Zig parameter (`this_arg: T`) and invoked via `Reflect.apply(fn, this_arg, args)`.
///
/// Rules:
/// - TypeScript `this: void` / `this: undefined` declares that a function does NOT access
///   `this` (`undefined` receiver) and must never emit a Zig `void` parameter.
/// - Instance and static class/interface methods already bind `this` to `self` or the
///   owning constructor/namespace object on the wire.
/// - Standalone functions, callable-object call signatures (`call_sig`), and `FnPtrIr`
///   callbacks DO bind non-`void` `this: T` explicitly.
pub fn shouldBindExplicitThis(
    has_self_receiver: bool,
    is_static_member_method: bool,
    is_void_or_pure_undef: bool,
) bool {
    if (is_void_or_pure_undef) return false;
    if (has_self_receiver or is_static_member_method) return false;
    return true;
}

/// Resolves which parameter (or `self` / `this_arg`) a TypeScript type predicate narrows.
pub fn resolvePredicateSubject(
    param_name: []const u8,
    explicit_param_index: ?u32,
    param_wire_names: []const []const u8,
    has_instance_self: bool,
    has_explicit_this: bool,
) ?TypePredicateSubject {
    if (std.mem.eql(u8, param_name, "this")) {
        if (has_instance_self) return .self_receiver;
        if (has_explicit_this) return .explicit_this;
        return null;
    }
    if (explicit_param_index) |pidx| {
        const idx: usize = @intCast(pidx);
        if (idx < param_wire_names.len) return .{ .param_index = idx };
    }
    for (param_wire_names, 0..) |wname, idx| {
        if (std.mem.eql(u8, wname, param_name)) {
            return .{ .param_index = idx };
        }
    }
    return null;
}

/// Derives the idiomatic Zig narrowing companion logical name for a type predicate:
/// - `x is Foo`: `isFoo` -> `asFoo`, `is` -> `as`, `hasBody` -> `hasBodyNarrow`
/// - `asserts x is Foo`: `assertFoo` / `assertsFoo` -> `ensureFoo`, `assert` / `asserts` -> `ensure`,
///   `checkBody` -> `checkBodyEnsure`
pub fn deriveNarrowCompanionRawName(
    alloc: std.mem.Allocator,
    pred_logical_name: []const u8,
    is_asserts: bool,
) error{OutOfMemory}![]u8 {
    if (is_asserts) {
        if (std.mem.eql(u8, pred_logical_name, "assert") or std.mem.eql(u8, pred_logical_name, "asserts")) {
            return try alloc.dupe(u8, "ensure");
        }
        if (std.mem.startsWith(u8, pred_logical_name, "asserts") and
            pred_logical_name.len > 7 and
            (std.ascii.isUpper(pred_logical_name[7]) or std.ascii.isDigit(pred_logical_name[7]) or pred_logical_name[7] == '_'))
        {
            return try std.fmt.allocPrint(alloc, "ensure{s}", .{pred_logical_name[7..]});
        }
        if (std.mem.startsWith(u8, pred_logical_name, "assert") and
            pred_logical_name.len > 6 and
            (std.ascii.isUpper(pred_logical_name[6]) or std.ascii.isDigit(pred_logical_name[6]) or pred_logical_name[6] == '_'))
        {
            return try std.fmt.allocPrint(alloc, "ensure{s}", .{pred_logical_name[6..]});
        }
        return try std.fmt.allocPrint(alloc, "{s}Ensure", .{pred_logical_name});
    }
    if (std.mem.eql(u8, pred_logical_name, "is")) {
        return try alloc.dupe(u8, "as");
    }
    if (std.mem.startsWith(u8, pred_logical_name, "is") and
        pred_logical_name.len > 2 and
        (std.ascii.isUpper(pred_logical_name[2]) or std.ascii.isDigit(pred_logical_name[2]) or pred_logical_name[2] == '_'))
    {
        return try std.fmt.allocPrint(alloc, "as{s}", .{pred_logical_name[2..]});
    }
    return try std.fmt.allocPrint(alloc, "{s}Narrow", .{pred_logical_name});
}

const fallback_qualifiers = [_][]const u8{
    "",
    "Narrowed",
    "Typed",
    "Checked",
    "Cast",
    "Alt",
    "Primary",
    "Secondary",
};

/// Binds a collision-free camelCase companion identifier (such as `<name>Alloc`, `<name>Slice`,
/// `asFoo`, or `asFooAlloc`) into `scope` without ever falling back to `_2` numeric suffixes.
pub fn bindCleanCompanionIdent(
    out_alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    scope: *naming.ScopeNamer,
    desired_raw: []const u8,
) error{OutOfMemory}!struct { zig_ident: []const u8, logical_name: []const u8 } {
    for (fallback_qualifiers) |qual| {
        const cand_raw = if (qual.len == 0)
            try scratch.dupe(u8, desired_raw)
        else
            try std.fmt.allocPrint(scratch, "{s}{s}", .{ desired_raw, qual });
        defer scratch.free(cand_raw);

        const camel = try naming.toCamelCase(scratch, cand_raw);
        defer scratch.free(camel);
        if (camel.len == 0 or scope.isTaken(camel)) continue;

        const bound = try scope.bind(camel, .camel);
        defer bound.deinit(scratch);
        return .{
            .zig_ident = try out_alloc.dupe(u8, bound.zig_ident),
            .logical_name = try out_alloc.dupe(u8, bound.logical_name),
        };
    }

    // Word-ordinal fallback if all short qualifiers are already occupied in `scope`.
    const ordinals = [_][]const u8{
        "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten",
    };
    for (ordinals) |ord| {
        const cand_raw = try std.fmt.allocPrint(scratch, "{s}{s}", .{ desired_raw, ord });
        defer scratch.free(cand_raw);
        const camel = try naming.toCamelCase(scratch, cand_raw);
        defer scratch.free(camel);
        if (camel.len == 0 or scope.isTaken(camel)) continue;
        const bound = try scope.bind(camel, .camel);
        defer bound.deinit(scratch);
        return .{
            .zig_ident = try out_alloc.dupe(u8, bound.zig_ident),
            .logical_name = try out_alloc.dupe(u8, bound.logical_name),
        };
    }

    const bound = try scope.bind(desired_raw, .camel);
    defer bound.deinit(scratch);
    return .{
        .zig_ident = try out_alloc.dupe(u8, bound.zig_ident),
        .logical_name = try out_alloc.dupe(u8, bound.logical_name),
    };
}

/// Binds `<logical_name>Slice` (and optional `<logical_name>SliceAlloc`) for a callable
/// whose final parameter is a variadic rest parameter (`...args: T[]`).
pub fn bindVariadicSliceCompanions(
    out_alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    scope: *naming.ScopeNamer,
    base_logical_name: []const u8,
    may_allocate: bool,
) error{OutOfMemory}!struct {
    slice_ident: []const u8,
    slice_alloc_ident: ?[]const u8,
} {
    const raw_slice = try std.fmt.allocPrint(scratch, "{s}Slice", .{base_logical_name});
    defer scratch.free(raw_slice);
    const sl = try bindCleanCompanionIdent(out_alloc, scratch, scope, raw_slice);

    var sl_alloc: ?[]const u8 = null;
    if (may_allocate) {
        const raw_sl_alloc = try std.fmt.allocPrint(scratch, "{s}Alloc", .{sl.logical_name});
        defer scratch.free(raw_sl_alloc);
        const sla = try bindCleanCompanionIdent(out_alloc, scratch, scope, raw_sl_alloc);
        sl_alloc = sla.zig_ident;
    }

    return .{
        .slice_ident = sl.zig_ident,
        .slice_alloc_ident = sl_alloc,
    };
}

/// Binds `asFoo` / `ensureFoo` (and optional `*Alloc`) for `x is Foo` / `asserts x is Foo`
/// / `this is Foo` / `asserts this is Foo` type predicates.
pub fn bindPredicateNarrowCompanions(
    out_alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    scope: *naming.ScopeNamer,
    pred_logical_name: []const u8,
    is_asserts: bool,
    target_may_allocate: bool,
) error{OutOfMemory}!struct {
    narrow_ident: []const u8,
    narrow_alloc_ident: ?[]const u8,
} {
    const raw_narrow = try deriveNarrowCompanionRawName(scratch, pred_logical_name, is_asserts);
    defer scratch.free(raw_narrow);
    const nr = try bindCleanCompanionIdent(out_alloc, scratch, scope, raw_narrow);

    var nr_alloc: ?[]const u8 = null;
    if (target_may_allocate) {
        const raw_nr_alloc = try std.fmt.allocPrint(scratch, "{s}Alloc", .{nr.logical_name});
        defer scratch.free(raw_nr_alloc);
        const nra = try bindCleanCompanionIdent(out_alloc, scratch, scope, raw_nr_alloc);
        nr_alloc = nra.zig_ident;
    }

    return .{
        .narrow_ident = nr.zig_ident,
        .narrow_alloc_ident = nr_alloc,
    };
}

test "deriveNarrowCompanionRawName and resolvePredicateSubject cover isFoo, assertFoo, this, and collisions" {
    const alloc = std.testing.allocator;

    const n1 = try deriveNarrowCompanionRawName(alloc, "isBinaryExpression", false);
    defer alloc.free(n1);
    try std.testing.expectEqualStrings("asBinaryExpression", n1);

    const n2 = try deriveNarrowCompanionRawName(alloc, "is", false);
    defer alloc.free(n2);
    try std.testing.expectEqualStrings("as", n2);

    const n3 = try deriveNarrowCompanionRawName(alloc, "hasPayload", false);
    defer alloc.free(n3);
    try std.testing.expectEqualStrings("hasPayloadNarrow", n3);

    const n4 = try deriveNarrowCompanionRawName(alloc, "assertBinaryExpr", true);
    defer alloc.free(n4);
    try std.testing.expectEqualStrings("ensureBinaryExpr", n4);

    const n5 = try deriveNarrowCompanionRawName(alloc, "assertsReady", true);
    defer alloc.free(n5);
    try std.testing.expectEqualStrings("ensureReady", n5);

    const wires = [_][]const u8{ "ctx", "node" };
    const subj_param = resolvePredicateSubject("node", null, &wires, false, false).?;
    try std.testing.expectEqual(@as(usize, 1), subj_param.param_index);

    const subj_self = resolvePredicateSubject("this", null, &wires, true, false).?;
    try std.testing.expect(subj_self == .self_receiver);

    const subj_this = resolvePredicateSubject("this", null, &wires, false, true).?;
    try std.testing.expect(subj_this == .explicit_this);

    try std.testing.expect(resolvePredicateSubject("this", null, &wires, false, false) == null);
    try std.testing.expect(!shouldBindExplicitThis(false, false, true));
    try std.testing.expect(!shouldBindExplicitThis(true, false, false));
    try std.testing.expect(shouldBindExplicitThis(false, false, false));

    var scope = naming.ScopeNamer.initContainer(alloc, null);
    defer scope.deinit();
    try scope.reserve("asNode");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const comps = try bindPredicateNarrowCompanions(arena.allocator(), alloc, &scope, "isNode", false, true);
    try std.testing.expectEqualStrings("asNodeNarrowed", comps.narrow_ident);
    try std.testing.expectEqualStrings("asNodeNarrowedAlloc", comps.narrow_alloc_ident.?);
}
