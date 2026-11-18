//! TypeScript 7.1 protocol lowering helpers (`Promise<T>` / `PromiseLike<T>`,
//! `Iterable<T>` / `Iterator<T>` / `Generator<T>`, `AsyncIterable<T>` /
//! `AsyncIterator<T>` / `AsyncGenerator<T>`, and `Symbol.dispose` /
//! `Symbol.asyncDispose` resource management).

const std = @import("std");
const ts = @import("generated_ts_wasm32");
const lower_types = @import("lower_types.zig");

/// Built-in ES / TypeScript protocol interface or object types.
pub const BuiltinProtocolKind = enum {
    /// `Iterable<T>` / `IterableIterator<T>`:
    /// - input/param/field position -> `[]const T` slice
    /// - return / generic-constraint position -> `__zigar_js.Iterator(T)`
    iterable,
    /// `Iterator<T>`, `Generator<T>`, `IteratorObject<T>`, `BuiltinIterator<T>`, etc.:
    /// - always `__zigar_js.Iterator(T)`
    iterator,
    /// `AsyncIterable<T>` / `AsyncIterableIterator<T>`:
    /// - always `__zigar_js.AsyncIterator(T)`
    async_iterable,
    /// `AsyncIterator<T>`, `AsyncGenerator<T>`, `AsyncIteratorObject<T>`:
    /// - always `__zigar_js.AsyncIterator(T)`
    async_iterator,
    /// `Disposable` (`[Symbol.dispose](): void`):
    /// - `__zigar_js.Disposable`
    disposable,
    /// `AsyncDisposable` (`[Symbol.asyncDispose](): PromiseLike<void>`):
    /// - `__zigar_js.AsyncDisposable`
    async_disposable,

    pub fn takesElemTypeArg(self: BuiltinProtocolKind) bool {
        return switch (self) {
            .iterable, .iterator, .async_iterable, .async_iterator => true,
            .disposable, .async_disposable => false,
        };
    }

    pub fn isSyncDisposable(self: BuiltinProtocolKind) bool {
        return self == .disposable;
    }

    pub fn isAsyncDisposable(self: BuiltinProtocolKind) bool {
        return self == .async_disposable;
    }

    pub fn isSyncIterableOrIterator(self: BuiltinProtocolKind) bool {
        return self == .iterable or self == .iterator;
    }

    pub fn isAsyncIterableOrIterator(self: BuiltinProtocolKind) bool {
        return self == .async_iterable or self == .async_iterator;
    }
};

/// Classifies built-in ES/TS protocol type names (stripping any `globalThis.` prefix).
pub fn classifyBuiltinProtocolRef(raw_name: []const u8) ?BuiltinProtocolKind {
    const base = lower_types.stripGlobalQualifier(raw_name);
    if (std.mem.eql(u8, base, "Iterable") or
        std.mem.eql(u8, base, "IterableIterator"))
    {
        return .iterable;
    }
    if (std.mem.eql(u8, base, "Iterator") or
        std.mem.eql(u8, base, "NodeJS.Iterator") or
        std.mem.eql(u8, base, "Generator") or
        std.mem.eql(u8, base, "IteratorObject") or
        std.mem.eql(u8, base, "BuiltinIterator") or
        std.mem.eql(u8, base, "ArrayIterator") or
        std.mem.eql(u8, base, "MapIterator") or
        std.mem.eql(u8, base, "SetIterator") or
        std.mem.eql(u8, base, "StringIterator"))
    {
        return .iterator;
    }
    if (std.mem.eql(u8, base, "AsyncIterable") or
        std.mem.eql(u8, base, "AsyncIterableIterator"))
    {
        return .async_iterable;
    }
    if (std.mem.eql(u8, base, "AsyncIterator") or
        std.mem.eql(u8, base, "NodeJS.AsyncIterator") or
        std.mem.eql(u8, base, "AsyncGenerator") or
        std.mem.eql(u8, base, "AsyncIteratorObject"))
    {
        return .async_iterator;
    }
    if (std.mem.eql(u8, base, "Disposable")) {
        return .disposable;
    }
    if (std.mem.eql(u8, base, "AsyncDisposable")) {
        return .async_disposable;
    }
    return null;
}

/// Well-known ES / Node.js symbol protocols supported on handle wrapper structs.
pub const ProtocolSymbolKind = enum {
    iterator,
    async_iterator,
    dispose,
    async_dispose,
};

/// Classifies a WIT `SymbolKey` (either `well_known` or `custom`, including Node.js's
/// `Symbol.for("nodejs.dispose")` / `Symbol.for("nodejs.asyncDispose")` aliases) into
/// one of the four supported runtime protocols.
pub fn classifyProtocolSymbolKey(sym: ts.types.SymbolKey, custom_str: []const u8) ?ProtocolSymbolKind {
    return switch (sym) {
        .well_known => |wk| switch (wk) {
            .iterator => .iterator,
            .async_iterator => .async_iterator,
            .dispose => .dispose,
            .async_dispose => .async_dispose,
            else => null,
        },
        .custom => classifyCustomProtocolSymbolText(custom_str),
        .unique => null,
    };
}

pub fn classifyCustomProtocolSymbolText(raw: []const u8) ?ProtocolSymbolKind {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "Symbol.iterator") or std.mem.eql(u8, trimmed, "iterator")) {
        return .iterator;
    }
    if (std.mem.eql(u8, trimmed, "Symbol.asyncIterator") or std.mem.eql(u8, trimmed, "asyncIterator")) {
        return .async_iterator;
    }
    if (std.mem.eql(u8, trimmed, "Symbol.dispose") or
        std.mem.eql(u8, trimmed, "dispose") or
        std.mem.eql(u8, trimmed, "nodejs.dispose") or
        std.mem.indexOf(u8, trimmed, "\"nodejs.dispose\"") != null or
        std.mem.indexOf(u8, trimmed, "'nodejs.dispose'") != null)
    {
        return .dispose;
    }
    if (std.mem.eql(u8, trimmed, "Symbol.asyncDispose") or
        std.mem.eql(u8, trimmed, "asyncDispose") or
        std.mem.eql(u8, trimmed, "nodejs.asyncDispose") or
        std.mem.indexOf(u8, trimmed, "\"nodejs.asyncDispose\"") != null or
        std.mem.indexOf(u8, trimmed, "'nodejs.asyncDispose'") != null)
    {
        return .async_dispose;
    }
    return null;
}

/// Checks whether a built-in iterator result wrapper name (`IteratorResult<T>`,
/// `IteratorYieldResult<T>`) carries the yielded element `T` as its first type argument.
pub fn isIteratorResultWrapperName(raw_name: []const u8) bool {
    const base = lower_types.stripGlobalQualifier(raw_name);
    return std.mem.eql(u8, base, "IteratorResult") or
        std.mem.eql(u8, base, "IteratorYieldResult");
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "classifyBuiltinProtocolRef covers sync/async iterables, iterators, and disposables" {
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .iterable), classifyBuiltinProtocolRef("Iterable"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .iterable), classifyBuiltinProtocolRef("globalThis.IterableIterator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .iterator), classifyBuiltinProtocolRef("Iterator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .iterator), classifyBuiltinProtocolRef("NodeJS.Iterator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .iterator), classifyBuiltinProtocolRef("Generator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .iterator), classifyBuiltinProtocolRef("IteratorObject"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .async_iterable), classifyBuiltinProtocolRef("AsyncIterable"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .async_iterable), classifyBuiltinProtocolRef("AsyncIterableIterator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .async_iterator), classifyBuiltinProtocolRef("AsyncIterator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .async_iterator), classifyBuiltinProtocolRef("NodeJS.AsyncIterator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .async_iterator), classifyBuiltinProtocolRef("AsyncGenerator"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .disposable), classifyBuiltinProtocolRef("Disposable"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, .async_disposable), classifyBuiltinProtocolRef("globalThis.AsyncDisposable"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, null), classifyBuiltinProtocolRef("Array"));
    try std.testing.expectEqual(@as(?BuiltinProtocolKind, null), classifyBuiltinProtocolRef("Promise"));
}

test "classifyProtocolSymbolKey handles well-known and nodejs.dispose fallback symbols" {
    try std.testing.expectEqual(
        @as(?ProtocolSymbolKind, .iterator),
        classifyProtocolSymbolKey(.{ .well_known = .iterator }, ""),
    );
    try std.testing.expectEqual(
        @as(?ProtocolSymbolKind, .async_iterator),
        classifyProtocolSymbolKey(.{ .well_known = .async_iterator }, ""),
    );
    try std.testing.expectEqual(
        @as(?ProtocolSymbolKind, .dispose),
        classifyProtocolSymbolKey(.{ .well_known = .dispose }, ""),
    );
    try std.testing.expectEqual(
        @as(?ProtocolSymbolKind, .async_dispose),
        classifyProtocolSymbolKey(.{ .well_known = .async_dispose }, ""),
    );
    try std.testing.expectEqual(
        @as(?ProtocolSymbolKind, null),
        classifyProtocolSymbolKey(.{ .well_known = .to_string_tag }, ""),
    );
    try std.testing.expectEqual(
        @as(?ProtocolSymbolKind, .dispose),
        classifyProtocolSymbolKey(.{ .custom = 0 }, "Symbol.for(\"nodejs.dispose\")"),
    );
    try std.testing.expectEqual(
        @as(?ProtocolSymbolKind, .async_dispose),
        classifyProtocolSymbolKey(.{ .custom = 0 }, "Symbol.for('nodejs.asyncDispose')"),
    );
}
