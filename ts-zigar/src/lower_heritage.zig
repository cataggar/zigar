//! Issue `#49` (`M3.2b`): Single/multiple inheritance, `A & B` intersections,
//! overload-preserving method deduplication, `.bases` upcast/downcast metadata,
//! and typed dynamic index-signature accessors.

const std = @import("std");
const naming = @import("naming.zig");
const lower_objects = @import("lower_objects.zig");

pub const IndexKeyCategory = enum(u8) {
    string_key = 0,
    number_key = 1,
    symbol_key = 2,
    template_key = 3,
    other_key = 4,

    pub fn fallbackGetterRawName(self: IndexKeyCategory) []const u8 {
        return switch (self) {
            .string_key => "getEntry",
            .number_key => "getIndex",
            .symbol_key => "getSymbol",
            .template_key => "getPattern",
            .other_key => "getByKey",
        };
    }

    pub fn fallbackSetterRawName(self: IndexKeyCategory) []const u8 {
        return switch (self) {
            .string_key => "setEntry",
            .number_key => "setIndex",
            .symbol_key => "setSymbol",
            .template_key => "setPattern",
            .other_key => "setByKey",
        };
    }

    pub fn defaultKeyParamRawName(self: IndexKeyCategory) []const u8 {
        return switch (self) {
            .number_key => "index",
            .symbol_key => "sym",
            else => "key",
        };
    }
};

pub const BoundIndexAccessorNames = struct {
    getter_ident: []const u8,
    getter_logical: []const u8,
    setter_ident: ?[]const u8,
};

/// Binds non-colliding index-signature getter and optional setter identifiers in `struct_scope`.
///
/// When `allow_short_primary` is true and `"get"` (plus `"set"` when `!is_readonly`) is not
/// already taken by an explicit method/property on the struct, binds `get` / `set`.
/// Otherwise falls back to category-specific names (`getEntry`/`setEntry`, `getIndex`/`setIndex`,
/// `getSymbol`/`setSymbol`, `getPattern`/`setPattern`, `getByKey`/`setByKey`).
pub fn bindIndexAccessorNames(
    struct_scope: *naming.ScopeNamer,
    scratch: std.mem.Allocator,
    arena: std.mem.Allocator,
    category: IndexKeyCategory,
    is_readonly: bool,
    allow_short_primary: bool,
) error{OutOfMemory}!BoundIndexAccessorNames {
    const can_use_short = allow_short_primary and
        !struct_scope.isTaken("get") and
        (is_readonly or !struct_scope.isTaken("set"));

    const raw_get = if (can_use_short) "get" else category.fallbackGetterRawName();
    const gb = try struct_scope.bind(raw_get, .camel);
    const getter_ident = try arena.dupe(u8, gb.zig_ident);
    const getter_logical = try arena.dupe(u8, gb.logical_name);
    gb.deinit(scratch);

    var setter_ident: ?[]const u8 = null;
    if (!is_readonly) {
        const raw_set = if (can_use_short) "set" else category.fallbackSetterRawName();
        const sb = try struct_scope.bind(raw_set, .camel);
        setter_ident = try arena.dupe(u8, sb.zig_ident);
        sb.deinit(scratch);
    }

    return .{
        .getter_ident = getter_ident,
        .getter_logical = getter_logical,
        .setter_ident = setter_ident,
    };
}

/// Binds the optional `*Alloc` companion identifier for an index getter (`getAlloc`, `getIndexAlloc`, etc.).
pub fn bindIndexGetterAllocName(
    struct_scope: *naming.ScopeNamer,
    scratch: std.mem.Allocator,
    arena: std.mem.Allocator,
    getter_logical: []const u8,
) error{OutOfMemory}![]const u8 {
    const raw_alloc = try std.fmt.allocPrint(scratch, "{s}Alloc", .{getter_logical});
    defer scratch.free(raw_alloc);
    const ab = try struct_scope.bind(raw_alloc, .camel);
    const ident = try arena.dupe(u8, ab.zig_ident);
    ab.deinit(scratch);
    return ident;
}

/// Checks whether a handle-backed non-class interface with no constructors, call signatures,
/// class bases, non-public members, or required methods/properties can safely expose a
/// synthesized `init()` empty JS `{}` factory (either an indexed dictionary or an
/// optional-methods configuration interface such as `monaco.Environment`).
pub fn shouldSynthesizeEmptyHandleInit(
    is_class: bool,
    has_class_base: bool,
    has_non_public_members: bool,
    is_callable_handle: bool,
    ctor_count: usize,
    index_sig_count: usize,
    optional_methods_count: usize,
    required_methods_count: usize,
    required_props_count: usize,
) bool {
    return !is_class and
        !has_class_base and
        !has_non_public_members and
        !is_callable_handle and
        ctor_count == 0 and
        (index_sig_count > 0 or optional_methods_count > 0) and
        required_methods_count == 0 and
        required_props_count == 0;
}

pub fn shouldSynthesizeIndexedEmptyInit(
    is_class: bool,
    is_callable_handle: bool,
    ctor_count: usize,
    index_sig_count: usize,
    required_methods_count: usize,
    required_props_count: usize,
) bool {
    return shouldSynthesizeEmptyHandleInit(
        is_class,
        false,
        false,
        is_callable_handle,
        ctor_count,
        index_sig_count,
        0,
        required_methods_count,
        required_props_count,
    );
}

test "bindIndexAccessorNames binds primary get/set and falls back cleanly on dual or colliding indexers" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Dual `[key: string]` + `[index: number]` on a fresh struct:
    {
        var scope = naming.ScopeNamer.initContainer(alloc, null);
        defer scope.deinit();

        const str_names = try bindIndexAccessorNames(&scope, alloc, arena, .string_key, false, true);
        try std.testing.expectEqualStrings("get", str_names.getter_ident);
        try std.testing.expectEqualStrings("set", str_names.setter_ident.?);
        const str_alloc = try bindIndexGetterAllocName(&scope, alloc, arena, str_names.getter_logical);
        try std.testing.expectEqualStrings("getAlloc", str_alloc);

        const num_names = try bindIndexAccessorNames(&scope, alloc, arena, .number_key, false, false);
        try std.testing.expectEqualStrings("getIndex", num_names.getter_ident);
        try std.testing.expectEqualStrings("setIndex", num_names.setter_ident.?);
        const num_alloc = try bindIndexGetterAllocName(&scope, alloc, arena, num_names.getter_logical);
        try std.testing.expectEqualStrings("getIndexAlloc", num_alloc);
    }

    // 2. Explicit `get` method already exists (`Headers.get`): string indexer falls back to `getEntry`/`setEntry`!
    {
        var scope = naming.ScopeNamer.initContainer(alloc, null);
        defer scope.deinit();
        try scope.reserve("get");

        const str_names = try bindIndexAccessorNames(&scope, alloc, arena, .string_key, false, true);
        try std.testing.expectEqualStrings("getEntry", str_names.getter_ident);
        try std.testing.expectEqualStrings("setEntry", str_names.setter_ident.?);
    }

    // 3. Readonly `[index: number]` indexer emits getter without setter:
    {
        var scope = naming.ScopeNamer.initContainer(alloc, null);
        defer scope.deinit();

        const ro_names = try bindIndexAccessorNames(&scope, alloc, arena, .number_key, true, true);
        try std.testing.expectEqualStrings("get", ro_names.getter_ident);
        try std.testing.expect(ro_names.setter_ident == null);
    }
}

test "shouldSynthesizeIndexedEmptyInit only enables empty object factory on pure dictionary interfaces" {
    try std.testing.expect(shouldSynthesizeIndexedEmptyInit(false, false, 0, 1, 0, 0));
    try std.testing.expect(!shouldSynthesizeIndexedEmptyInit(true, false, 0, 1, 0, 0));
    try std.testing.expect(!shouldSynthesizeIndexedEmptyInit(false, true, 0, 1, 0, 0));
    try std.testing.expect(!shouldSynthesizeIndexedEmptyInit(false, false, 1, 1, 0, 0));
    try std.testing.expect(!shouldSynthesizeIndexedEmptyInit(false, false, 0, 0, 0, 0));
    try std.testing.expect(!shouldSynthesizeIndexedEmptyInit(false, false, 0, 1, 1, 0));
    try std.testing.expect(!shouldSynthesizeIndexedEmptyInit(false, false, 0, 1, 0, 1));

    // Optional-method interfaces (`monaco.Environment`) get `init()`, unless extending a class or branded:
    try std.testing.expect(shouldSynthesizeEmptyHandleInit(false, false, false, false, 0, 0, 2, 0, 0));
    try std.testing.expect(!shouldSynthesizeEmptyHandleInit(false, true, false, false, 0, 0, 2, 0, 0));
    try std.testing.expect(!shouldSynthesizeEmptyHandleInit(false, false, true, false, 0, 0, 2, 0, 0));
    try std.testing.expect(!shouldSynthesizeEmptyHandleInit(false, false, false, false, 0, 0, 2, 1, 0));
}
