const std = @import("std");

/// Explicit Zig 0.17 reserved keywords table (supplemented by `std.zig.Token.keywords`).
pub const zig_017_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "addrspace", {} },
    .{ "align", {} },
    .{ "allowzero", {} },
    .{ "and", {} },
    .{ "anyframe", {} },
    .{ "anytype", {} },
    .{ "asm", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "break", {} },
    .{ "callconv", {} },
    .{ "catch", {} },
    .{ "comptime", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "defer", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "errdefer", {} },
    .{ "error", {} },
    .{ "export", {} },
    .{ "extern", {} },
    .{ "false", {} },
    .{ "fn", {} },
    .{ "for", {} },
    .{ "if", {} },
    .{ "inline", {} },
    .{ "linksection", {} },
    .{ "noalias", {} },
    .{ "noinline", {} },
    .{ "nosuspend", {} },
    .{ "null", {} },
    .{ "opaque", {} },
    .{ "or", {} },
    .{ "orelse", {} },
    .{ "packed", {} },
    .{ "pub", {} },
    .{ "resume", {} },
    .{ "return", {} },
    .{ "struct", {} },
    .{ "suspend", {} },
    .{ "switch", {} },
    .{ "test", {} },
    .{ "threadlocal", {} },
    .{ "true", {} },
    .{ "try", {} },
    .{ "type", {} },
    .{ "undefined", {} },
    .{ "union", {} },
    .{ "unreachable", {} },
    .{ "var", {} },
    .{ "volatile", {} },
    .{ "while", {} },
});

/// Explicit Zig 0.17 primitive & builtin type names (supplemented by `std.zig.isPrimitive`,
/// which also covers arbitrary bit-width integers `u0`..`u65535` and `i0`..`i65535`).
pub const zig_017_primitives = std.StaticStringMap(void).initComptime(.{
    .{ "u8", {} },
    .{ "i8", {} },
    .{ "u16", {} },
    .{ "i16", {} },
    .{ "u32", {} },
    .{ "i32", {} },
    .{ "u64", {} },
    .{ "i64", {} },
    .{ "u128", {} },
    .{ "i128", {} },
    .{ "usize", {} },
    .{ "isize", {} },
    .{ "f16", {} },
    .{ "f32", {} },
    .{ "f64", {} },
    .{ "f80", {} },
    .{ "f128", {} },
    .{ "bool", {} },
    .{ "void", {} },
    .{ "noreturn", {} },
    .{ "anyerror", {} },
    .{ "anyopaque", {} },
    .{ "c_char", {} },
    .{ "c_short", {} },
    .{ "c_ushort", {} },
    .{ "c_int", {} },
    .{ "c_uint", {} },
    .{ "c_long", {} },
    .{ "c_ulong", {} },
    .{ "c_longlong", {} },
    .{ "c_ulonglong", {} },
    .{ "c_longdouble", {} },
    .{ "c_void", {} },
    .{ "comptime_int", {} },
    .{ "comptime_float", {} },
    .{ "type", {} },
});

pub fn isZigKeyword(name: []const u8) bool {
    return zig_017_keywords.has(name) or std.zig.Token.keywords.has(name);
}

pub fn isZigPrimitive(name: []const u8) bool {
    return zig_017_primitives.has(name) or std.zig.isPrimitive(name);
}

pub fn isValidBareIdentifierSyntax(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "_")) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

/// Returns true if `name` cannot be emitted as a bare Zig 0.17 identifier without `@"..."`
/// (or non-empty substitution for `""`, since `@""` is illegal in Zig 0.17).
pub fn needsEscaping(name: []const u8) bool {
    if (!isValidBareIdentifierSyntax(name)) return true;
    if (isZigKeyword(name)) return true;
    if (isZigPrimitive(name)) return true;
    return false;
}

/// Escapes `raw` as a Zig string literal body (without surrounding quotes).
pub fn appendZigStringEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
    const hex = "0123456789abcdef";
    for (raw) |byte| {
        switch (byte) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try out.append(allocator, byte),
            else => {
                try out.appendSlice(allocator, &.{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] });
            },
        }
    }
}

/// Formats `raw` as a Zig string literal `"..."`.
pub fn formatStringLiteral(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try appendZigStringEscaped(&out, allocator, raw);
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

/// Formats `name` as a valid Zig 0.17 identifier.
/// Note: Zig 0.17 rejects `@""` (`identifier cannot be empty`), so empty names map to
/// `@"_empty"` while `ScopeNamer` / `BoundName` preserves `""` as the exact JS wire name.
pub fn formatIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) {
        return try allocator.dupe(u8, "@\"_empty\"");
    }
    if (!needsEscaping(name)) {
        return try allocator.dupe(u8, name);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "@\"");
    try appendZigStringEscaped(&out, allocator, name);
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

/// Returns the logical symbol name underlying a candidate identifier before `@"..."` quoting.
/// Empty strings map to `"_empty"` to match `formatIdentifier`.
pub fn logicalSymbolName(raw: []const u8) []const u8 {
    if (raw.len == 0) return "_empty";
    return raw;
}

/// Splits an arbitrary JS/TS identifier or path into alphanumeric words.
/// Examples:
///   "XMLHttpRequest" -> ["XML", "Http", "Request"]
///   "readFileSync"   -> ["read", "File", "Sync"]
///   "@scope/my-pkg"  -> ["scope", "my", "pkg"]
///   "get2DContext"   -> ["get", "2D", "Context"]
fn splitWords(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and !std.ascii.isAlphanumeric(raw[i])) : (i += 1) {}
        if (i >= raw.len) break;

        const start = i;
        if (std.ascii.isDigit(raw[i])) {
            while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {}
            // Keep trailing lowercase/single-letter unit suffix attached to leading digits only if
            // the entire token is digits+letters like "2d" at word start; otherwise split cleanly.
            if (start == 0 and i < raw.len and std.ascii.isAlphabetic(raw[i])) {
                while (i < raw.len and std.ascii.isAlphanumeric(raw[i]) and !std.ascii.isUpper(raw[i])) : (i += 1) {}
            }
        } else if (std.ascii.isUpper(raw[i])) {
            i += 1;
            if (i < raw.len and std.ascii.isUpper(raw[i])) {
                // Acronym run: "XMLHttp" -> "XML" then "Http".
                while (i < raw.len and std.ascii.isUpper(raw[i])) : (i += 1) {}
                if (i < raw.len and std.ascii.isLower(raw[i]) and (i - start) > 1) {
                    i -= 1;
                }
            } else {
                while (i < raw.len and (std.ascii.isLower(raw[i]) or std.ascii.isDigit(raw[i]))) : (i += 1) {}
            }
        } else {
            while (i < raw.len and (std.ascii.isLower(raw[i]) or std.ascii.isDigit(raw[i]))) : (i += 1) {}
        }

        try words.append(allocator, raw[start..i]);
    }

    return try words.toOwnedSlice(allocator);
}

/// Converts `raw` to `snake_case` (without `@"..."` wrapping; pass to `formatIdentifier` when emitting).
pub fn toSnakeCase(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const words = try splitWords(allocator, raw);
    defer allocator.free(words);

    if (words.len == 0) {
        if (raw.len == 0) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, "_");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (words, 0..) |w, idx| {
        if (idx > 0) try out.append(allocator, '_');
        for (w) |ch| {
            try out.append(allocator, std.ascii.toLower(ch));
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Converts `raw` to `camelCase` (without `@"..."` wrapping; pass to `formatIdentifier` when emitting).
pub fn toCamelCase(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const words = try splitWords(allocator, raw);
    defer allocator.free(words);

    if (words.len == 0) {
        if (raw.len == 0) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, "_");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (words, 0..) |w, idx| {
        if (idx == 0) {
            for (w) |ch| try out.append(allocator, std.ascii.toLower(ch));
        } else {
            try out.append(allocator, std.ascii.toUpper(w[0]));
            for (w[1..]) |ch| try out.append(allocator, std.ascii.toLower(ch));
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Converts `raw` to `PascalCase` (without `@"..."` wrapping; pass to `formatIdentifier` when emitting).
pub fn toPascalCase(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const words = try splitWords(allocator, raw);
    defer allocator.free(words);

    if (words.len == 0) {
        if (raw.len == 0) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, "_");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (words) |w| {
        try out.append(allocator, std.ascii.toUpper(w[0]));
        for (w[1..]) |ch| try out.append(allocator, std.ascii.toLower(ch));
    }
    return try out.toOwnedSlice(allocator);
}

pub const NameStyle = enum {
    preserve,
    camel,
    pascal,
    snake,
};

pub const BoundName = struct {
    /// Valid Zig 0.17 identifier ready for emission (e.g. `readFile`, `@"type"`, `user_2`).
    zig_ident: []const u8,
    /// Unescaped Zig symbol name tracked for scope collision & shadowing checks.
    logical_name: []const u8,
    /// Exact original JS/TS wire name preserved for `zigar.js` metadata descriptors.
    wire_name: []const u8,

    pub fn deinit(self: BoundName, allocator: std.mem.Allocator) void {
        allocator.free(self.zig_ident);
        allocator.free(self.logical_name);
        allocator.free(self.wire_name);
    }
};

/// Deterministic scope-aware identifier allocator that deduplicates collisions within a scope
/// and prevents shadowing of optional parent/enclosing scope declarations while preserving exact
/// JS wire names.
pub const ScopeNamer = struct {
    allocator: std.mem.Allocator,
    used: std.StringHashMapUnmanaged(void) = .empty,
    parent: ?*const ScopeNamer = null,

    pub fn init(allocator: std.mem.Allocator, parent: ?*const ScopeNamer) ScopeNamer {
        return .{
            .allocator = allocator,
            .parent = parent,
        };
    }

    pub fn deinit(self: *ScopeNamer) void {
        var it = self.used.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.used.deinit(self.allocator);
    }

    pub fn isTaken(self: *const ScopeNamer, logical: []const u8) bool {
        if (self.used.contains(logical)) return true;
        if (self.parent) |p| return p.isTaken(logical);
        return false;
    }

    /// Reserves a logical Zig identifier in this scope (e.g. `zigar_js` or `Self`).
    pub fn reserve(self: *ScopeNamer, logical: []const u8) !void {
        if (self.used.contains(logical)) return;
        const owned = try self.allocator.dupe(u8, logical);
        errdefer self.allocator.free(owned);
        try self.used.put(self.allocator, owned, {});
    }

    /// Binds `wire_name` according to `style`, deduplicating deterministically on collision.
    pub fn bind(self: *ScopeNamer, wire_name: []const u8, style: NameStyle) !BoundName {
        return self.bindWithFallbackSuffix(wire_name, style, null);
    }

    /// Like `bind`, using `collision_suffix` (e.g. `"arg"`) on the first collision before numeric suffixes.
    pub fn bindWithFallbackSuffix(
        self: *ScopeNamer,
        wire_name: []const u8,
        style: NameStyle,
        collision_suffix: ?[]const u8,
    ) !BoundName {
        const styled = switch (style) {
            .preserve => try self.allocator.dupe(u8, wire_name),
            .camel => try toCamelCase(self.allocator, wire_name),
            .pascal => try toPascalCase(self.allocator, wire_name),
            .snake => try toSnakeCase(self.allocator, wire_name),
        };
        defer self.allocator.free(styled);

        const base = if (styled.len == 0) "_empty" else if (std.mem.eql(u8, styled, "_") and style != .preserve) "item" else styled;

        var chosen_logical: []u8 = undefined;
        if (!self.isTaken(base)) {
            chosen_logical = try self.allocator.dupe(u8, base);
        } else if (collision_suffix) |sfx| {
            const with_sfx = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ base, sfx });
            if (!self.isTaken(with_sfx)) {
                chosen_logical = with_sfx;
            } else {
                self.allocator.free(with_sfx);
                chosen_logical = try self.nextNumbered(base);
            }
        } else {
            chosen_logical = try self.nextNumbered(base);
        }
        errdefer self.allocator.free(chosen_logical);

        try self.reserve(chosen_logical);

        const zig_ident = try formatIdentifier(self.allocator, chosen_logical);
        errdefer self.allocator.free(zig_ident);

        const wire_copy = try self.allocator.dupe(u8, wire_name);

        return .{
            .zig_ident = zig_ident,
            .logical_name = chosen_logical,
            .wire_name = wire_copy,
        };
    }

    fn nextNumbered(self: *const ScopeNamer, base: []const u8) ![]u8 {
        var n: usize = 2;
        while (true) : (n += 1) {
            const candidate = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ base, n });
            if (!self.isTaken(candidate)) return candidate;
            self.allocator.free(candidate);
        }
    }
};

/// Strips common TypeScript / JavaScript / Zig file extensions from a module path.
pub fn stripModuleExtension(spec: []const u8) []const u8 {
    const suffixes = [_][]const u8{
        ".d.mts",
        ".d.cts",
        ".d.ts",
        ".mts",
        ".cts",
        ".tsx",
        ".jsx",
        ".mjs",
        ".cjs",
        ".ts",
        ".js",
        ".zig",
    };
    for (suffixes) |sfx| {
        if (spec.len > sfx.len and std.mem.endsWith(u8, spec, sfx)) {
            return spec[0 .. spec.len - sfx.len];
        }
    }
    return spec;
}

fn sanitizePathSegment(allocator: std.mem.Allocator, raw_seg: []const u8) ![]u8 {
    const snake = try toSnakeCase(allocator, raw_seg);
    defer allocator.free(snake);

    if (snake.len == 0 or std.mem.eql(u8, snake, "_")) {
        return try allocator.dupe(u8, "mod");
    }
    return try allocator.dupe(u8, snake);
}

/// Sanitizes an arbitrary module specifier or relative path into a safe POSIX relative `.zig`
/// file path under `out_dir`.
/// - Strips `node:` scheme (`"node:fs/promises"` -> `"fs/promises.zig"`).
/// - Rejects/strips `..`, `.`, leading `/`, Windows `\` and drive prefixes so output paths can
///   NEVER escape `out_dir`.
/// - Avoids clobbering `root.zig` (which is reserved for the generated package entry module) by
///   mapping bare `"root"` -> `"root_mod.zig"`.
pub fn sanitizeModuleRelPath(allocator: std.mem.Allocator, raw_specifier: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw_specifier, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "node:")) {
        trimmed = trimmed["node:".len..];
    }
    trimmed = stripModuleExtension(trimmed);

    var segments: std.ArrayList([]u8) = .empty;
    defer {
        for (segments.items) |seg| allocator.free(seg);
        segments.deinit(allocator);
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= trimmed.len) : (i += 1) {
        const is_sep = (i == trimmed.len) or (trimmed[i] == '/') or (trimmed[i] == '\\');
        if (!is_sep) continue;

        const part = trimmed[start..i];
        start = i + 1;

        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            continue;
        }
        // Strip Windows drive colon on first segment like "C:" -> skip.
        if (segments.items.len == 0 and part.len == 2 and std.ascii.isAlphabetic(part[0]) and part[1] == ':') {
            continue;
        }

        const clean = try sanitizePathSegment(allocator, part);
        try segments.append(allocator, clean);
    }

    if (segments.items.len == 0) {
        return try allocator.dupe(u8, "index.zig");
    }

    if (segments.items.len == 1 and std.mem.eql(u8, segments.items[0], "root")) {
        return try allocator.dupe(u8, "root_mod.zig");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (segments.items, 0..) |seg, idx| {
        if (idx > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    try out.appendSlice(allocator, ".zig");
    return try out.toOwnedSlice(allocator);
}

/// Computes the exact POSIX relative `@import("...")` path from `from_rel_zig_path` to
/// `to_rel_zig_path` (where both are POSIX paths relative to `out_dir`, e.g. `"fs/promises.zig"`
/// and `"events.zig"` -> `"../events.zig"`).
pub fn relativeImportPath(
    allocator: std.mem.Allocator,
    from_rel_zig_path: []const u8,
    to_rel_zig_path: []const u8,
) ![]u8 {
    var from_dirs: std.ArrayList([]const u8) = .empty;
    defer from_dirs.deinit(allocator);
    if (std.mem.lastIndexOfScalar(u8, from_rel_zig_path, '/')) |slash| {
        var it = std.mem.splitScalar(u8, from_rel_zig_path[0..slash], '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try from_dirs.append(allocator, seg);
        }
    }

    var to_parts: std.ArrayList([]const u8) = .empty;
    defer to_parts.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, to_rel_zig_path, '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try to_parts.append(allocator, seg);
        }
    }

    const to_dir_count = if (to_parts.items.len > 0) to_parts.items.len - 1 else 0;
    var common: usize = 0;
    while (common < from_dirs.items.len and common < to_dir_count and
        std.mem.eql(u8, from_dirs.items[common], to_parts.items[common])) : (common += 1)
    {}

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const up_count = from_dirs.items.len - common;
    for (0..up_count) |idx| {
        if (idx > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, "..");
    }

    for (to_parts.items[common..], 0..) |part, idx| {
        if (up_count > 0 or idx > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }

    return try out.toOwnedSlice(allocator);
}

test "all Zig 0.17 reserved keywords and primitives are escaped via @\"...\"" {
    const alloc = std.testing.allocator;

    const all_keywords = [_][]const u8{
        "addrspace", "align",    "allowzero",   "and",         "anyframe",
        "anytype",   "asm",      "async",       "await",       "break",
        "callconv",  "catch",    "comptime",    "const",       "continue",
        "defer",     "else",     "enum",        "errdefer",    "error",
        "export",    "extern",   "false",       "fn",          "for",
        "if",        "inline",   "linksection", "noalias",     "noinline",
        "nosuspend", "null",     "opaque",      "or",          "orelse",
        "packed",    "pub",      "resume",      "return",      "struct",
        "suspend",   "switch",   "test",        "threadlocal", "true",
        "try",       "type",     "undefined",   "union",       "unreachable",
        "var",       "volatile", "while",
    };

    for (all_keywords) |kw| {
        try std.testing.expect(isZigKeyword(kw));
        try std.testing.expect(needsEscaping(kw));
        const formatted = try formatIdentifier(alloc, kw);
        defer alloc.free(formatted);
        const expected = try std.fmt.allocPrint(alloc, "@\"{s}\"", .{kw});
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, formatted);
    }

    const primitives = [_][]const u8{
        "u8",    "i32",    "f64",          "usize",          "isize",
        "bool",  "void",   "noreturn",     "anyerror",       "anyopaque",
        "c_int", "c_void", "comptime_int", "comptime_float", "u0",
        "u7",    "i24",    "u65535",
    };

    for (primitives) |prim| {
        try std.testing.expect(isZigPrimitive(prim));
        try std.testing.expect(needsEscaping(prim));
        const formatted = try formatIdentifier(alloc, prim);
        defer alloc.free(formatted);
        const expected = try std.fmt.allocPrint(alloc, "@\"{s}\"", .{prim});
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, formatted);
    }
}

test "identifier escaping handles invalid chars, leading digits, empty string, underscore, and quotes" {
    const alloc = std.testing.allocator;

    {
        const id = try formatIdentifier(alloc, "");
        defer alloc.free(id);
        try std.testing.expectEqualStrings("@\"_empty\"", id);
    }
    {
        const id = try formatIdentifier(alloc, "_");
        defer alloc.free(id);
        try std.testing.expectEqualStrings("@\"_\"", id);
    }
    {
        const id = try formatIdentifier(alloc, "2d");
        defer alloc.free(id);
        try std.testing.expectEqualStrings("@\"2d\"", id);
    }
    {
        const id = try formatIdentifier(alloc, "@scope/pkg");
        defer alloc.free(id);
        try std.testing.expectEqualStrings("@\"@scope/pkg\"", id);
    }
    {
        const id = try formatIdentifier(alloc, "a\"b\\c\n");
        defer alloc.free(id);
        try std.testing.expectEqualStrings("@\"a\\\"b\\\\c\\n\"", id);

        // Verify Zig 0.17 AST parser accepts the escaped identifier!
        const src = try std.fmt.allocPrintSentinel(alloc, "pub const {s} = 1;\n", .{id}, 0);
        defer alloc.free(src);
        var tree = try std.zig.Ast.parse(alloc, src, .{ .mode = .zig });
        defer tree.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
        const rendered = try tree.renderAlloc(alloc);
        defer alloc.free(rendered);
        try std.testing.expect(rendered.len > 0);
    }
}

test "casing helpers convert camelCase, PascalCase, and snake_case deterministically" {
    const alloc = std.testing.allocator;

    {
        const s = try toSnakeCase(alloc, "XMLHttpRequest");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("xml_http_request", s);

        const c = try toCamelCase(alloc, "XMLHttpRequest");
        defer alloc.free(c);
        try std.testing.expectEqualStrings("xmlHttpRequest", c);

        const p = try toPascalCase(alloc, "xml-http_request");
        defer alloc.free(p);
        try std.testing.expectEqualStrings("XmlHttpRequest", p);
    }
    {
        const s = try toSnakeCase(alloc, "@scope/my-pkg");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("scope_my_pkg", s);
    }
}

test "ScopeNamer deduplicates collisions and prevents parent scope shadowing while preserving wire names" {
    const alloc = std.testing.allocator;

    var outer = ScopeNamer.init(alloc, null);
    defer outer.deinit();

    const outer_fn = try outer.bind("format", .camel);
    defer outer_fn.deinit(alloc);
    try std.testing.expectEqualStrings("format", outer_fn.zig_ident);

    const kw = try outer.bind("type", .snake);
    defer kw.deinit(alloc);
    try std.testing.expectEqualStrings("@\"type\"", kw.zig_ident);
    try std.testing.expectEqualStrings("type", kw.wire_name);

    const dup1 = try outer.bind("read_file", .camel);
    defer dup1.deinit(alloc);
    const dup2 = try outer.bind("read-file", .camel);
    defer dup2.deinit(alloc);
    try std.testing.expectEqualStrings("readFile", dup1.zig_ident);
    try std.testing.expectEqualStrings("readFile_2", dup2.zig_ident);
    try std.testing.expectEqualStrings("read-file", dup2.wire_name);

    var inner = ScopeNamer.init(alloc, &outer);
    defer inner.deinit();
    const param = try inner.bindWithFallbackSuffix("format", .snake, "arg");
    defer param.deinit(alloc);
    try std.testing.expectEqualStrings("format_arg", param.zig_ident);
    try std.testing.expectEqualStrings("format", param.wire_name);
}

test "sanitizeModuleRelPath and relativeImportPath prevent path traversal and compute exact imports" {
    const alloc = std.testing.allocator;

    {
        const p = try sanitizeModuleRelPath(alloc, "node:fs/promises");
        defer alloc.free(p);
        try std.testing.expectEqualStrings("fs/promises.zig", p);
    }
    {
        const p = try sanitizeModuleRelPath(alloc, "../../etc/passwd");
        defer alloc.free(p);
        try std.testing.expectEqualStrings("etc/passwd.zig", p);
        try std.testing.expect(std.mem.indexOf(u8, p, "..") == null);
    }
    {
        const p = try sanitizeModuleRelPath(alloc, "root.d.ts");
        defer alloc.free(p);
        try std.testing.expectEqualStrings("root_mod.zig", p);
    }
    {
        const rel = try relativeImportPath(alloc, "fs/promises.zig", "events.zig");
        defer alloc.free(rel);
        try std.testing.expectEqualStrings("../events.zig", rel);
    }
    {
        const rel = try relativeImportPath(alloc, "root.zig", "fs/promises.zig");
        defer alloc.free(rel);
        try std.testing.expectEqualStrings("fs/promises.zig", rel);
    }
    {
        const rel = try relativeImportPath(alloc, "a/b/c.zig", "a/d/e.zig");
        defer alloc.free(rel);
        try std.testing.expectEqualStrings("../d/e.zig", rel);
    }
}
