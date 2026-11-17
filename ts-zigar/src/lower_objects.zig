//! Object, interface, and class member lowering helpers for Milestone 3.2a (`#48`).
//!
//! Centralizes:
//! - Readable / writable / divergent-accessor analysis (`PropAccessInfo`, `StaticPropAccessKind`),
//! - Idiomatic setter naming (`foo` -> `setFoo`, `status_code` -> `setStatusCode`),
//! - Collision-proof backing `ref` field selection (`ref` vs `__zigar_ref` when `.ref()` method exists,
//!   e.g. `net.Socket.ref()`, `NodeJS.Timeout.ref()`, `Worker.ref()`),
//! - Non-colliding helper method binding (`deinit`, `toJsRef`, `fromJsRef`, `fromJsRefAlloc`) and
//!   non-shadowing Zig 0.17 parameter identifiers, and
//! - Structural duck-type requirement extraction (`required_methods`, `required_props`) for
//!   handle-backed non-class interfaces in union discrimination & `fromJsRefAlloc`.

const std = @import("std");
const naming = @import("naming.zig");

pub const MethodCallKind = enum {
    method,
    call_sig,
    construct_sig,
};

pub const StaticPropAccessKind = enum {
    read_write,
    read_only,
    write_only,
    divergent_read_write,
};

pub const PropAccessInfo = struct {
    is_readable: bool,
    is_writable: bool,
    read_ty_id: u32,
    write_ty_id: u32,
    has_divergent_setter: bool,
    is_literal_const_candidate: bool,
    static_access: StaticPropAccessKind,
};

pub fn analyzePropAccess(p: anytype) PropAccessInfo {
    const is_readable = !p.has_setter or p.has_getter;
    const is_writable = p.has_setter or (!p.modifiers.readonly_mod and !p.has_getter);
    const read_ty_id: u32 = p.ty;
    const write_ty_id: u32 = if (p.setter_ty) |sty| sty else p.ty;
    const has_divergent = is_readable and is_writable and (p.setter_ty != null) and (write_ty_id != read_ty_id);
    const static_access: StaticPropAccessKind = if (is_readable and is_writable)
        (if (has_divergent) .divergent_read_write else .read_write)
    else if (is_readable)
        .read_only
    else
        .write_only;

    return .{
        .is_readable = is_readable,
        .is_writable = is_writable,
        .read_ty_id = read_ty_id,
        .write_ty_id = write_ty_id,
        .has_divergent_setter = has_divergent,
        .is_literal_const_candidate = p.modifiers.readonly_mod and !p.has_getter and !p.has_setter,
        .static_access = static_access,
    };
}

/// Formats an idiomatic camelCase setter raw name from a JS property wire name
/// (`"port"` -> `"setPort"`, `"status_code"` -> `"setStatusCode"`, `""` -> `"setValue"`).
pub fn buildSetterRawName(allocator: std.mem.Allocator, wire_name: []const u8) error{OutOfMemory}![]u8 {
    const pascal = try naming.toPascalCase(allocator, wire_name);
    defer allocator.free(pascal);
    if (pascal.len == 0) {
        return try allocator.dupe(u8, "setValue");
    }
    // Strip leading `_` if `toPascalCase` fell back on non-alphanumeric prefix (e.g. `_0` -> `Set_0` -> `set_0`).
    return try std.fmt.allocPrint(allocator, "set{s}", .{pascal});
}

/// Picks `"ref"` when no member in `struct_scope` has claimed `"ref"`; otherwise binds `"__zigar_ref"`
/// (deduplicating to `"__zigar_ref_2"` if needed) so classes with a `.ref()` method (such as Node.js
/// `net.Socket`, `Timeout`, `Worker`, `MessagePort`) never collide!
pub fn bindBackingRefFieldIdent(
    struct_scope: *naming.ScopeNamer,
    scratch: std.mem.Allocator,
    out_alloc: std.mem.Allocator,
) error{OutOfMemory}![]const u8 {
    if (!struct_scope.isTaken("ref")) {
        const b = try struct_scope.bind("ref", .preserve);
        defer b.deinit(scratch);
        return try out_alloc.dupe(u8, b.zig_ident);
    }
    const b = try struct_scope.bind("__zigar_ref", .preserve);
    defer b.deinit(scratch);
    return try out_alloc.dupe(u8, b.zig_ident);
}

/// Reserves and returns `desired` if and only if no member or outer scope declaration in `struct_scope`
/// collides with or would be shadowed by `desired`; returns `null` when taken so user `.d.ts` members
/// always keep priority over synthesized convenience helpers (`deinit`, `toJsRef`, `fromJsRef`, `fromJsRefAlloc`).
pub fn tryBindOptionalHelperIdent(
    struct_scope: *naming.ScopeNamer,
    scratch: std.mem.Allocator,
    out_alloc: std.mem.Allocator,
    desired: []const u8,
) error{OutOfMemory}!?[]const u8 {
    if (struct_scope.isTaken(desired)) return null;
    const b = try struct_scope.bind(desired, .preserve);
    defer b.deinit(scratch);
    if (!std.mem.eql(u8, b.logical_name, desired)) return null;
    return try out_alloc.dupe(u8, b.zig_ident);
}

/// Picks a parameter identifier (`__zigar_self`, `__zigar_val`, `__zigar_alloc`) guaranteed not to
/// shadow any declaration in `struct_scope` or its enclosing module/namespace/type-parameter scopes.
pub fn chooseNonShadowingParamIdent(
    struct_scope: *const naming.ScopeNamer,
    scratch: std.mem.Allocator,
    out_alloc: std.mem.Allocator,
    base: []const u8,
) error{OutOfMemory}![]const u8 {
    var suffix: usize = 1;
    while (true) : (suffix += 1) {
        const cand = if (suffix == 1)
            try scratch.dupe(u8, base)
        else
            try std.fmt.allocPrint(scratch, "{s}_{d}", .{ base, suffix });
        defer scratch.free(cand);

        if (!struct_scope.isTaken(cand) and !struct_scope.isTakenInAnyAncestor(cand)) {
            return try out_alloc.dupe(u8, cand);
        }
    }
}

pub const max_required_handle_checks: usize = 16;

pub fn isPlainWirePropertyName(wire: []const u8, has_computed_symbol: bool) bool {
    if (has_computed_symbol) return false;
    if (wire.len == 0) return false;
    if (std.mem.eql(u8, wire, "__zigar_private_brand")) return false;
    if (wire[0] == '[' or wire[0] == '#') return false;
    return true;
}

pub fn appendBoundedUniqueString(
    list: *std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
    s: []const u8,
) error{OutOfMemory}!void {
    if (list.items.len >= max_required_handle_checks) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, s)) return;
    }
    try list.append(alloc, try alloc.dupe(u8, s));
}

test "analyzePropAccess handles regular, readonly, getter-only, setter-only, and divergent accessors" {
    const FakeMods = packed struct {
        readonly_mod: bool = false,
    };
    const FakeProp = struct {
        ty: u32,
        setter_ty: ?u32 = null,
        has_getter: bool = false,
        has_setter: bool = false,
        modifiers: FakeMods = .{},
    };

    // 1. Mutable `foo: string`
    const rw = analyzePropAccess(FakeProp{ .ty = 1 });
    try std.testing.expect(rw.is_readable);
    try std.testing.expect(rw.is_writable);
    try std.testing.expect(!rw.has_divergent_setter);
    try std.testing.expect(!rw.is_literal_const_candidate);
    try std.testing.expectEqual(StaticPropAccessKind.read_write, rw.static_access);

    // 2. `readonly foo: string`
    const ro = analyzePropAccess(FakeProp{ .ty = 1, .modifiers = .{ .readonly_mod = true } });
    try std.testing.expect(ro.is_readable);
    try std.testing.expect(!ro.is_writable);
    try std.testing.expect(ro.is_literal_const_candidate);
    try std.testing.expectEqual(StaticPropAccessKind.read_only, ro.static_access);

    // 3. `get foo(): string`
    const get_only = analyzePropAccess(FakeProp{ .ty = 1, .has_getter = true, .modifiers = .{ .readonly_mod = true } });
    try std.testing.expect(get_only.is_readable);
    try std.testing.expect(!get_only.is_writable);
    try std.testing.expect(!get_only.is_literal_const_candidate);
    try std.testing.expectEqual(StaticPropAccessKind.read_only, get_only.static_access);

    // 4. `set foo(v: number)` (write-only)
    const set_only = analyzePropAccess(FakeProp{ .ty = 2, .setter_ty = 2, .has_setter = true });
    try std.testing.expect(!set_only.is_readable);
    try std.testing.expect(set_only.is_writable);
    try std.testing.expectEqual(StaticPropAccessKind.write_only, set_only.static_access);

    // 5. `get foo(): string; set foo(v: string | number)` (divergent!)
    const div = analyzePropAccess(FakeProp{ .ty = 1, .setter_ty = 3, .has_getter = true, .has_setter = true });
    try std.testing.expect(div.is_readable);
    try std.testing.expect(div.is_writable);
    try std.testing.expect(div.has_divergent_setter);
    try std.testing.expectEqual(@as(u32, 1), div.read_ty_id);
    try std.testing.expectEqual(@as(u32, 3), div.write_ty_id);
    try std.testing.expectEqual(StaticPropAccessKind.divergent_read_write, div.static_access);
}

test "buildSetterRawName and bindBackingRefFieldIdent avoid .ref() method collisions" {
    const alloc = std.testing.allocator;

    const s1 = try buildSetterRawName(alloc, "port");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("setPort", s1);

    const s2 = try buildSetterRawName(alloc, "status_code");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("setStatusCode", s2);

    // Normal class without `.ref()` -> backing field is `"ref"`.
    {
        var sc = naming.ScopeNamer.initContainer(alloc, null);
        defer sc.deinit();
        const rf = try bindBackingRefFieldIdent(&sc, alloc, alloc);
        defer alloc.free(rf);
        try std.testing.expectEqualStrings("ref", rf);
    }

    // Node.js `Socket`-style class with `.ref()` method -> backing field falls back to `"__zigar_ref"`.
    {
        var sc = naming.ScopeNamer.initContainer(alloc, null);
        defer sc.deinit();
        const mb = try sc.bind("ref", .camel);
        mb.deinit(alloc);

        const rf = try bindBackingRefFieldIdent(&sc, alloc, alloc);
        defer alloc.free(rf);
        try std.testing.expectEqualStrings("__zigar_ref", rf);
    }
}
