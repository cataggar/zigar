//! Issue `#49` (`M3.2b`): Declaration-merging analysis across `interface`, `class`,
//! `namespace`, `function`, and `enum` declarations in the same scope or via
//! module augmentations (`declare module "./base" { ... }`).

const std = @import("std");
const naming = @import("naming.zig");

/// Returns true when two declarations share the same non-empty wire identifier.
/// Guards against synthetic/hostile graphs that link differently-named nodes via `merged_with`.
pub fn sameWireName(a: []const u8, b: []const u8) bool {
    return a.len > 0 and std.mem.eql(u8, a, b);
}

/// Checks whether a `function_decl` and `namespace_decl` sharing `wire_name` would bind to
/// the exact same Zig identifier in their enclosing scope (for example `$` or `_`, where
/// `.camel(wire)` == `.pascal(wire)`). When true, the top-level `function_decl` MUST be
/// consumed into the unified namespace `struct` (`call(...)`) so they do not collide as `$_2`.
pub fn fnAndNamespaceIdentCollide(alloc: std.mem.Allocator, wire_name: []const u8) error{OutOfMemory}!bool {
    const camel = try naming.toCamelCase(alloc, wire_name);
    defer alloc.free(camel);
    const pascal = try naming.toPascalCase(alloc, wire_name);
    defer alloc.free(pascal);
    return std.mem.eql(u8, camel, pascal);
}

/// Deduplicates a slice of child `DeclId`s across multiple merged `namespace Foo` blocks
/// in declaration order while preventing self-reference to any of the namespace block IDs.
pub fn mergeNamespaceChildIds(
    alloc: std.mem.Allocator,
    owner_ns_ids: []const u32,
    child_slices: []const []const u32,
) error{OutOfMemory}![]u32 {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(alloc);
    for (owner_ns_ids) |oid| {
        try seen.put(alloc, oid, {});
    }

    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(alloc);
    for (child_slices) |slice| {
        for (slice) |cid| {
            const gop = try seen.getOrPut(alloc, cid);
            if (!gop.found_existing) {
                try out.append(alloc, cid);
            }
        }
    }
    return try out.toOwnedSlice(alloc);
}

test "fnAndNamespaceIdentCollide detects symbol-only colliding names vs distinct camel/Pascal names" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try fnAndNamespaceIdentCollide(alloc, "$"));
    try std.testing.expect(try fnAndNamespaceIdentCollide(alloc, "_"));
    try std.testing.expect(!try fnAndNamespaceIdentCollide(alloc, "debug"));
    try std.testing.expect(!try fnAndNamespaceIdentCollide(alloc, "Widget"));
}

test "mergeNamespaceChildIds preserves order and drops duplicates and owner self-cycles" {
    const alloc = std.testing.allocator;
    const owners = [_]u32{ 10, 11 };
    const s1 = [_]u32{ 10, 1, 2 };
    const s2 = [_]u32{ 2, 11, 3, 1 };
    const slices = [_][]const u32{ &s1, &s2 };
    const merged = try mergeNamespaceChildIds(alloc, &owners, &slices);
    defer alloc.free(merged);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, merged);
}
