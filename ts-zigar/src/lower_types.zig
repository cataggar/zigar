//! Type-lowering classifications and helpers for Milestone 3.1a (`ts-zigar` <-> `zigar.js`).
//!
//! Centralizes:
//! - `NullishKind` (`undefined_only`, `null_only`, `null_or_undefined`) tracking for `?T` & `Nullable(T)`,
//! - All 15 JavaScript / Node.js binary view & buffer wrappers (`BinaryViewKind`),
//! - Nominal boxed/intrinsic JS wrapper mappings (`BigInt`, `String`, `Symbol`, `Object`),
//! - `@types/node` / built-in global `buffer` owner-module detection, and
//! - BigInt literal digit normalization (`_` separator stripping).

const std = @import("std");

/// Tracks whether a Zig optional (`?T`) originated from TypeScript `undefined`, `null`, or both.
pub const NullishKind = enum(u8) {
    none = 0,
    undefined_only = 1,
    null_only = 2,
    null_or_undefined = 3,

    pub fn merge(a: NullishKind, b: NullishKind) NullishKind {
        const has_u = (a == .undefined_only or a == .null_or_undefined) or
            (b == .undefined_only or b == .null_or_undefined);
        const has_n = (a == .null_only or a == .null_or_undefined) or
            (b == .null_only or b == .null_or_undefined);
        if (has_u and has_n) return .null_or_undefined;
        if (has_u) return .undefined_only;
        if (has_n) return .null_only;
        return .none;
    }

    pub fn withOptionalMarker(self: NullishKind) NullishKind {
        return self.merge(.undefined_only);
    }

    pub fn zigTagLiteral(self: NullishKind) []const u8 {
        return switch (self) {
            .none => ".none",
            .undefined_only => ".undefined_only",
            .null_only => ".null_only",
            .null_or_undefined => ".null_or_undefined",
        };
    }
};

/// All 16 JavaScript & Node.js binary buffer and typed-array wrapper types backed by `zigar.js`.
pub const BinaryViewKind = enum(u8) {
    buffer,
    uint8_array,
    uint8_clamped_array,
    int8_array,
    uint16_array,
    int16_array,
    uint32_array,
    int32_array,
    big_uint64_array,
    big_int64_array,
    float16_array,
    float32_array,
    float64_array,
    array_buffer,
    shared_array_buffer,
    data_view,

    pub const all = [_]BinaryViewKind{
        .buffer,
        .uint8_array,
        .uint8_clamped_array,
        .int8_array,
        .uint16_array,
        .int16_array,
        .uint32_array,
        .int32_array,
        .big_uint64_array,
        .big_int64_array,
        .float16_array,
        .float32_array,
        .float64_array,
        .array_buffer,
        .shared_array_buffer,
        .data_view,
    };

    pub fn zigTypeIdent(self: BinaryViewKind) []const u8 {
        return switch (self) {
            .buffer => "Buffer",
            .uint8_array => "Uint8Array",
            .uint8_clamped_array => "Uint8ClampedArray",
            .int8_array => "Int8Array",
            .uint16_array => "Uint16Array",
            .int16_array => "Int16Array",
            .uint32_array => "Uint32Array",
            .int32_array => "Int32Array",
            .big_uint64_array => "BigUint64Array",
            .big_int64_array => "BigInt64Array",
            .float16_array => "Float16Array",
            .float32_array => "Float32Array",
            .float64_array => "Float64Array",
            .array_buffer => "ArrayBuffer",
            .shared_array_buffer => "SharedArrayBuffer",
            .data_view => "DataView",
        };
    }

    pub fn fromTypeName(raw_name: []const u8) ?BinaryViewKind {
        const stripped = stripGlobalQualifier(raw_name);
        const map = std.StaticStringMap(BinaryViewKind).initComptime(.{
            .{ "Buffer", .buffer },
            .{ "NodeJS.Buffer", .buffer },
            .{ "Uint8Array", .uint8_array },
            .{ "Uint8ClampedArray", .uint8_clamped_array },
            .{ "Int8Array", .int8_array },
            .{ "Uint16Array", .uint16_array },
            .{ "Int16Array", .int16_array },
            .{ "Uint32Array", .uint32_array },
            .{ "Int32Array", .int32_array },
            .{ "BigUint64Array", .big_uint64_array },
            .{ "BigInt64Array", .big_int64_array },
            .{ "Float16Array", .float16_array },
            .{ "Float32Array", .float32_array },
            .{ "Float64Array", .float64_array },
            .{ "ArrayBuffer", .array_buffer },
            .{ "SharedArrayBuffer", .shared_array_buffer },
            .{ "DataView", .data_view },
        });
        return map.get(stripped);
    }
};

/// Nominal / boxed JS built-in interfaces (`BigInt`, `String`, `Symbol`, `Object`, `Date`, `RegExp`, `Function`, `Error`).
pub const BoxedIntrinsicKind = enum(u8) {
    bigint,
    string,
    symbol,
    object,
    date,
    regexp,
    function,

    pub fn fromTypeName(raw_name: []const u8) ?BoxedIntrinsicKind {
        const stripped = stripGlobalQualifier(raw_name);
        const map = std.StaticStringMap(BoxedIntrinsicKind).initComptime(.{
            .{ "BigInt", .bigint },
            .{ "String", .string },
            .{ "Symbol", .symbol },
            .{ "Object", .object },
            .{ "Date", .date },
            .{ "RegExp", .regexp },
            .{ "Function", .function },
            .{ "Error", .object },
            .{ "TypeError", .object },
            .{ "RangeError", .object },
            .{ "SyntaxError", .object },
            .{ "ReferenceError", .object },
            .{ "URIError", .object },
            .{ "EvalError", .object },
            .{ "AggregateError", .object },
            .{ "Number", .object },
            .{ "Boolean", .object },
            .{ "IArguments", .object },
            .{ "GeneratorFunction", .function },
            .{ "AsyncGeneratorFunction", .function },
        });
        return map.get(stripped);
    }
};

pub fn stripGlobalQualifier(raw_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw_name, "globalThis.")) {
        return raw_name["globalThis.".len..];
    }
    if (std.mem.startsWith(u8, raw_name, "zigar.js.")) {
        return raw_name["zigar.js.".len..];
    }
    return raw_name;
}

/// Returns `true` when `specifier` / `file_path` belongs to Node's built-in `buffer` or `globals`
/// ambient declaration files (such as `@types/node/buffer.d.ts`, `@types/node/buffer.buffer.d.ts`,
/// `@types/node/globals.d.ts`, `node:buffer`, or `buffer`), as opposed to an arbitrary user module.
pub fn isBuiltinBufferOrGlobalsModule(specifier: []const u8, file_path: []const u8) bool {
    if (std.mem.eql(u8, specifier, "buffer") or
        std.mem.eql(u8, specifier, "node:buffer") or
        std.mem.eql(u8, specifier, "globals") or
        std.mem.eql(u8, specifier, "node/buffer") or
        std.mem.eql(u8, specifier, "node/globals"))
    {
        return true;
    }
    if (std.mem.indexOf(u8, file_path, "@types/node/") != null) {
        if (std.mem.endsWith(u8, file_path, "/buffer.d.ts") or
            std.mem.endsWith(u8, file_path, "/buffer.buffer.d.ts") or
            std.mem.endsWith(u8, file_path, "/globals.d.ts") or
            std.mem.endsWith(u8, file_path, "/globals.global.d.ts") or
            std.mem.endsWith(u8, file_path, "/globals.typedarray.d.ts") or
            std.mem.indexOf(u8, file_path, "/compatibility/") != null)
        {
            return true;
        }
    }
    return false;
}

/// Normalizes a TypeScript `bigint` literal text (`"99_999n"` -> `"99999"`) so `std.fmt.parseInt`
/// and `zigar_js.BigInt.fromString(...)` both receive clean signed decimal/radix text.
pub fn normalizeBigIntLiteral(allocator: std.mem.Allocator, raw_text: []const u8) error{OutOfMemory}![]u8 {
    const trimmed = if (std.mem.endsWith(u8, raw_text, "n") and raw_text.len > 1)
        raw_text[0 .. raw_text.len - 1]
    else
        raw_text;
    var count: usize = 0;
    for (trimmed) |ch| {
        if (ch != '_') count += 1;
    }
    const out = try allocator.alloc(u8, count);
    var wi: usize = 0;
    for (trimmed) |ch| {
        if (ch != '_') {
            out[wi] = ch;
            wi += 1;
        }
    }
    return out;
}

test "BinaryViewKind maps all 16 JS/Node binary buffer and typed-array types" {
    try std.testing.expectEqual(@as(usize, 16), BinaryViewKind.all.len);
    for (BinaryViewKind.all) |k| {
        const ident = k.zigTypeIdent();
        try std.testing.expectEqual(@as(?BinaryViewKind, k), BinaryViewKind.fromTypeName(ident));
        const qual = try std.fmt.allocPrint(std.testing.allocator, "globalThis.{s}", .{ident});
        defer std.testing.allocator.free(qual);
        try std.testing.expectEqual(@as(?BinaryViewKind, k), BinaryViewKind.fromTypeName(qual));
    }
    try std.testing.expectEqual(@as(?BinaryViewKind, .buffer), BinaryViewKind.fromTypeName("NodeJS.Buffer"));
    try std.testing.expectEqual(@as(?BinaryViewKind, null), BinaryViewKind.fromTypeName("CustomBuffer"));
}

test "NullishKind merge preserves undefined vs null vs null_or_undefined" {
    try std.testing.expectEqual(NullishKind.none, NullishKind.merge(.none, .none));
    try std.testing.expectEqual(NullishKind.undefined_only, NullishKind.merge(.none, .undefined_only));
    try std.testing.expectEqual(NullishKind.null_only, NullishKind.merge(.null_only, .none));
    try std.testing.expectEqual(NullishKind.null_or_undefined, NullishKind.merge(.undefined_only, .null_only));
    try std.testing.expectEqual(NullishKind.null_or_undefined, NullishKind.null_only.withOptionalMarker());
}

test "BoxedIntrinsicKind, isBuiltinBufferOrGlobalsModule, and normalizeBigIntLiteral" {
    try std.testing.expectEqual(@as(?BoxedIntrinsicKind, .bigint), BoxedIntrinsicKind.fromTypeName("BigInt"));
    try std.testing.expectEqual(@as(?BoxedIntrinsicKind, .string), BoxedIntrinsicKind.fromTypeName("zigar.js.String"));
    try std.testing.expect(isBuiltinBufferOrGlobalsModule("node:buffer", "/app/index.d.ts"));
    try std.testing.expect(isBuiltinBufferOrGlobalsModule("", "/app/node_modules/@types/node/buffer.d.ts"));
    try std.testing.expect(!isBuiltinBufferOrGlobalsModule("my-pkg", "/app/src/buffer.d.ts"));

    const norm = try normalizeBigIntLiteral(std.testing.allocator, "-99_999_000_111n");
    defer std.testing.allocator.free(norm);
    try std.testing.expectEqualStrings("-99999000111", norm);
}
