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

/// Recognizes standard ECMAScript, `Intl`, and TC39 `Temporal` built-in host object / constructor
/// interfaces that TypeScript resolves against bundled `lib.*.d.ts` and that intentionally map to
/// opaque `zigar_js.Object`.
///
/// Direct AST references to namespace-scoped built-ins (`Intl.*`, `Temporal.*`) MUST carry their
/// exact namespace prefix (after optional `globalThis.` / `zigar.js.` stripping) so bare unresolved
/// names like `Duration` or `Locale` are never misclassified as built-in globals.
pub fn isStandardBuiltinGlobalType(raw_name: []const u8) bool {
    const stripped = stripGlobalQualifier(raw_name);
    return standard_builtin_global_types.has(stripped);
}

/// When TypeScript's Go typechecker synthesizes a `resolved_type` for `typeof globalThis` or
/// `typeof globalThis extends { Temporal: { Instant: ... } }`, it emits the leaf symbol's `Name()`
/// (`"Instant"`, `"Locale"`, `"CollatorConstructor"`) without the enclosing `Intl.`/`Temporal.`
/// namespace qualifier. Only match these inside compiler-synthesized `resolved_type` subtrees!
pub fn isSynthesizedIntlOrTemporalMember(raw_name: []const u8) bool {
    const stripped = stripGlobalQualifier(raw_name);
    return synthesized_intl_temporal_members.has(stripped);
}

const standard_builtin_global_types = std.StaticStringMap(void).initComptime(.{
    // Core ECMAScript opaque host / iterator / disposable / reflection interfaces
    .{ "IteratorResult", {} },
    .{ "IteratorYieldResult", {} },
    .{ "IteratorReturnResult", {} },
    .{ "IteratorObject", {} },
    .{ "AsyncIteratorObject", {} },
    .{ "BuiltinIteratorReturn", {} },
    .{ "WeakMap", {} },
    .{ "WeakSet", {} },
    .{ "WeakRef", {} },
    .{ "FinalizationRegistry", {} },
    .{ "Atomics", {} },
    .{ "Math", {} },
    .{ "JSON", {} },
    .{ "Reflect", {} },
    .{ "DisposableStack", {} },
    .{ "AsyncDisposableStack", {} },
    .{ "SuppressedError", {} },
    // Standard ECMAScript global `*Constructor` interfaces
    .{ "SymbolConstructor", {} },
    .{ "ObjectConstructor", {} },
    .{ "FunctionConstructor", {} },
    .{ "StringConstructor", {} },
    .{ "BooleanConstructor", {} },
    .{ "NumberConstructor", {} },
    .{ "BigIntConstructor", {} },
    .{ "DateConstructor", {} },
    .{ "RegExpConstructor", {} },
    .{ "ErrorConstructor", {} },
    .{ "EvalErrorConstructor", {} },
    .{ "RangeErrorConstructor", {} },
    .{ "ReferenceErrorConstructor", {} },
    .{ "SyntaxErrorConstructor", {} },
    .{ "TypeErrorConstructor", {} },
    .{ "URIErrorConstructor", {} },
    .{ "AggregateErrorConstructor", {} },
    .{ "SuppressedErrorConstructor", {} },
    .{ "ArrayConstructor", {} },
    .{ "PromiseConstructor", {} },
    .{ "ArrayBufferConstructor", {} },
    .{ "SharedArrayBufferConstructor", {} },
    .{ "DataViewConstructor", {} },
    .{ "Int8ArrayConstructor", {} },
    .{ "Uint8ArrayConstructor", {} },
    .{ "Uint8ClampedArrayConstructor", {} },
    .{ "Int16ArrayConstructor", {} },
    .{ "Uint16ArrayConstructor", {} },
    .{ "Int32ArrayConstructor", {} },
    .{ "Uint32ArrayConstructor", {} },
    .{ "Float16ArrayConstructor", {} },
    .{ "Float32ArrayConstructor", {} },
    .{ "Float64ArrayConstructor", {} },
    .{ "BigInt64ArrayConstructor", {} },
    .{ "BigUint64ArrayConstructor", {} },
    .{ "MapConstructor", {} },
    .{ "WeakMapConstructor", {} },
    .{ "SetConstructor", {} },
    .{ "WeakSetConstructor", {} },
    .{ "WeakRefConstructor", {} },
    .{ "FinalizationRegistryConstructor", {} },
    .{ "IteratorConstructor", {} },
    .{ "ProxyConstructor", {} },
    .{ "DisposableStackConstructor", {} },
    .{ "AsyncDisposableStackConstructor", {} },
    // Standard ECMA-402 `Intl.*` built-in interfaces & options (must be `Intl.`-qualified)
    .{ "Intl.Collator", {} },
    .{ "Intl.CollatorOptions", {} },
    .{ "Intl.CollatorConstructor", {} },
    .{ "Intl.NumberFormat", {} },
    .{ "Intl.NumberFormatOptions", {} },
    .{ "Intl.NumberFormatConstructor", {} },
    .{ "Intl.DateTimeFormat", {} },
    .{ "Intl.DateTimeFormatOptions", {} },
    .{ "Intl.DateTimeFormatConstructor", {} },
    .{ "Intl.PluralRules", {} },
    .{ "Intl.PluralRulesOptions", {} },
    .{ "Intl.PluralRulesConstructor", {} },
    .{ "Intl.LocalesArgument", {} },
    .{ "Intl.UnicodeBCP47LocaleIdentifier", {} },
    .{ "Intl.RelativeTimeFormat", {} },
    .{ "Intl.RelativeTimeFormatOptions", {} },
    .{ "Intl.RelativeTimeFormatLocaleMatcher", {} },
    .{ "Intl.Locale", {} },
    .{ "Intl.LocaleOptions", {} },
    .{ "Intl.DisplayNames", {} },
    .{ "Intl.DisplayNamesOptions", {} },
    .{ "Intl.ListFormat", {} },
    .{ "Intl.ListFormatOptions", {} },
    .{ "Intl.Segmenter", {} },
    .{ "Intl.SegmenterOptions", {} },
    .{ "Intl.DurationFormat", {} },
    .{ "Intl.DurationFormatLocaleMatcher", {} },
    .{ "Intl.DurationFormatOptions", {} },
    // Standard TC39 `Temporal.*` built-in interfaces & constructors (must be `Temporal.`-qualified)
    .{ "Temporal.Instant", {} },
    .{ "Temporal.InstantConstructor", {} },
    .{ "Temporal.TimeZoneLike", {} },
    .{ "Temporal.PlainDate", {} },
    .{ "Temporal.PlainDateConstructor", {} },
    .{ "Temporal.PlainTime", {} },
    .{ "Temporal.PlainTimeConstructor", {} },
    .{ "Temporal.PlainDateTime", {} },
    .{ "Temporal.PlainDateTimeConstructor", {} },
    .{ "Temporal.ZonedDateTime", {} },
    .{ "Temporal.ZonedDateTimeConstructor", {} },
    .{ "Temporal.Duration", {} },
    .{ "Temporal.DurationConstructor", {} },
    .{ "Temporal.PlainYearMonth", {} },
    .{ "Temporal.PlainYearMonthConstructor", {} },
    .{ "Temporal.PlainMonthDay", {} },
    .{ "Temporal.PlainMonthDayConstructor", {} },
});

const synthesized_intl_temporal_members = std.StaticStringMap(void).initComptime(.{
    .{ "Collator", {} },
    .{ "CollatorOptions", {} },
    .{ "CollatorConstructor", {} },
    .{ "NumberFormat", {} },
    .{ "NumberFormatOptions", {} },
    .{ "NumberFormatConstructor", {} },
    .{ "DateTimeFormat", {} },
    .{ "DateTimeFormatOptions", {} },
    .{ "DateTimeFormatConstructor", {} },
    .{ "PluralRules", {} },
    .{ "PluralRulesOptions", {} },
    .{ "PluralRulesConstructor", {} },
    .{ "LocalesArgument", {} },
    .{ "UnicodeBCP47LocaleIdentifier", {} },
    .{ "RelativeTimeFormat", {} },
    .{ "RelativeTimeFormatOptions", {} },
    .{ "RelativeTimeFormatLocaleMatcher", {} },
    .{ "Locale", {} },
    .{ "LocaleOptions", {} },
    .{ "DisplayNames", {} },
    .{ "DisplayNamesOptions", {} },
    .{ "ListFormat", {} },
    .{ "ListFormatOptions", {} },
    .{ "Segmenter", {} },
    .{ "SegmenterOptions", {} },
    .{ "DurationFormat", {} },
    .{ "DurationFormatLocaleMatcher", {} },
    .{ "DurationFormatOptions", {} },
    .{ "Instant", {} },
    .{ "InstantConstructor", {} },
    .{ "TimeZoneLike", {} },
    .{ "PlainDate", {} },
    .{ "PlainDateConstructor", {} },
    .{ "PlainTime", {} },
    .{ "PlainTimeConstructor", {} },
    .{ "PlainDateTime", {} },
    .{ "PlainDateTimeConstructor", {} },
    .{ "ZonedDateTime", {} },
    .{ "ZonedDateTimeConstructor", {} },
    .{ "Duration", {} },
    .{ "DurationConstructor", {} },
    .{ "PlainYearMonth", {} },
    .{ "PlainYearMonthConstructor", {} },
    .{ "PlainMonthDay", {} },
    .{ "PlainMonthDayConstructor", {} },
});

fn isTsIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isTsIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

const TsLexToken = union(enum) {
    ident: []const u8,
    punct: u8,
    str_lit: []const u8,
    eof,
};

const TsImportLexer = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *TsImportLexer) TsLexToken {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len) {
                if (self.src[self.pos + 1] == '/') {
                    self.pos += 2;
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
                    continue;
                }
                if (self.src[self.pos + 1] == '*') {
                    self.pos += 2;
                    while (self.pos + 1 < self.src.len) : (self.pos += 1) {
                        if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                            self.pos += 2;
                            break;
                        }
                    } else {
                        self.pos = self.src.len;
                    }
                    continue;
                }
            }
            if (c == '\'' or c == '"' or c == '`') {
                const quote = c;
                self.pos += 1;
                const content_start = self.pos;
                var content_end = self.pos;
                while (self.pos < self.src.len) {
                    const sc = self.src[self.pos];
                    self.pos += 1;
                    if (sc == '\\' and self.pos < self.src.len) {
                        self.pos += 1;
                        content_end = self.pos;
                        continue;
                    }
                    if (sc == quote) break;
                    content_end = self.pos;
                }
                return .{ .str_lit = self.src[content_start..content_end] };
            }
            if (isTsIdentStart(c)) {
                const start = self.pos;
                self.pos += 1;
                while (self.pos < self.src.len and isTsIdentContinue(self.src[self.pos])) : (self.pos += 1) {}
                return .{ .ident = self.src[start..self.pos] };
            }
            self.pos += 1;
            return .{ .punct = c };
        }
        return .eof;
    }

    fn peek(self: *const TsImportLexer) TsLexToken {
        var copy = self.*;
        return copy.next();
    }
};

fn restOfImportTargetsBuiltinBufferOrGlobal(lex: *const TsImportLexer) bool {
    var scan = lex.*;
    var steps: usize = 0;
    while (steps < 256) : (steps += 1) {
        const tok = scan.next();
        switch (tok) {
            .eof => return false,
            .punct => |p| {
                if (p == ';') return false;
                if (p == '=') {
                    const rhs = scan.next();
                    if (rhs == .ident and std.mem.eql(u8, rhs.ident, "globalThis")) return true;
                    if (rhs == .ident and std.mem.eql(u8, rhs.ident, "require")) {
                        const lp = scan.next();
                        if (lp == .punct and lp.punct == '(') {
                            const sp = scan.next();
                            if (sp == .str_lit and isBuiltinBufferOrGlobalsModule(sp.str_lit, "")) return true;
                        }
                    }
                    return false;
                }
            },
            .ident => |w| {
                if (std.mem.eql(u8, w, "from")) {
                    const sp = scan.next();
                    if (sp == .str_lit and isBuiltinBufferOrGlobalsModule(sp.str_lit, "")) return true;
                    return false;
                }
            },
            .str_lit => {},
        }
    }
    return false;
}

/// Returns `true` if `source_text` binds `ident` via a local `import` declaration
/// (`import Ident from ...`, `import * as Ident from ...`, `import { X as Ident } from ...`,
/// `import { Ident } from ...`, or `import Ident = ...`). Used to ensure unresolved imports
/// from missing packages are never silently treated as `globalThis` built-in types.
pub fn sourceHasLocalImportBinding(source_text: []const u8, ident: []const u8) bool {
    if (ident.len == 0) return false;
    var lex = TsImportLexer{ .src = source_text };
    var prev_was_dot = false;

    while (true) {
        const tok = lex.next();
        switch (tok) {
            .eof => return false,
            .punct => |p| {
                prev_was_dot = (p == '.');
            },
            .str_lit => {
                prev_was_dot = false;
            },
            .ident => |word| {
                const after_dot = prev_was_dot;
                prev_was_dot = false;
                if (after_dot or !std.mem.eql(u8, word, "import")) continue;

                var t1 = lex.peek();
                // Ignore `import("pkg")` type expressions and `import.meta`.
                if (t1 == .punct and (t1.punct == '(' or t1.punct == '.')) continue;
                // Side-effect `import "pkg";` binds nothing.
                if (t1 == .str_lit) continue;

                // Optional `import type ...` (unless `import type from "pkg"` or `import type = ...`).
                if (t1 == .ident and std.mem.eql(u8, t1.ident, "type")) {
                    var after_type_lex = lex;
                    _ = after_type_lex.next();
                    const t2 = after_type_lex.peek();
                    const type_is_binding = (t2 == .ident and std.mem.eql(u8, t2.ident, "from")) or
                        (t2 == .punct and (t2.punct == '=' or t2.punct == ','));
                    if (!type_is_binding) {
                        _ = lex.next();
                        t1 = lex.peek();
                    }
                }

                // 1. `import * as Ns from "..."`
                if (t1 == .punct and t1.punct == '*') {
                    _ = lex.next();
                    const maybe_as = lex.next();
                    if (maybe_as == .ident and std.mem.eql(u8, maybe_as.ident, "as")) {
                        const ns_tok = lex.next();
                        if (ns_tok == .ident and std.mem.eql(u8, ns_tok.ident, ident)) {
                            if (!restOfImportTargetsBuiltinBufferOrGlobal(&lex)) return true;
                        }
                    }
                    continue;
                }

                // 2. Default binding `import Def from "..."`, `import Def, { ... } from "..."`,
                //    `import Def, * as Ns from "..."`, or `import Alias = ...`.
                if (t1 == .ident) {
                    const first_ident = lex.next().ident;
                    const next_tok = lex.peek();
                    if (next_tok == .punct and next_tok.punct == '=') {
                        if (std.mem.eql(u8, first_ident, ident)) {
                            if (!restOfImportTargetsBuiltinBufferOrGlobal(&lex)) return true;
                        }
                        continue;
                    }
                    if (std.mem.eql(u8, first_ident, ident)) {
                        if (!restOfImportTargetsBuiltinBufferOrGlobal(&lex)) return true;
                    }
                    if (next_tok == .punct and next_tok.punct == ',') {
                        _ = lex.next();
                        t1 = lex.peek();
                        if (t1 == .punct and t1.punct == '*') {
                            _ = lex.next();
                            const maybe_as = lex.next();
                            if (maybe_as == .ident and std.mem.eql(u8, maybe_as.ident, "as")) {
                                const ns_tok = lex.next();
                                if (ns_tok == .ident and std.mem.eql(u8, ns_tok.ident, ident)) {
                                    if (!restOfImportTargetsBuiltinBufferOrGlobal(&lex)) return true;
                                }
                            }
                            continue;
                        }
                    } else {
                        continue;
                    }
                }

                // 3. Named bindings `import { A, type B, C as D, type E as F } from "..."`
                if (t1 == .punct and t1.punct == '{') {
                    _ = lex.next();
                    var matched_in_braces = false;
                    while (true) {
                        const elem = lex.next();
                        switch (elem) {
                            .eof => return false,
                            .punct => |p| {
                                if (p == '}') break;
                                continue;
                            },
                            .str_lit => {
                                // `import { "x" as Local } from "..."`
                                const maybe_as = lex.peek();
                                if (maybe_as == .ident and std.mem.eql(u8, maybe_as.ident, "as")) {
                                    _ = lex.next();
                                    const local_tok = lex.next();
                                    if (local_tok == .ident and std.mem.eql(u8, local_tok.ident, ident)) {
                                        matched_in_braces = true;
                                    }
                                }
                            },
                            .ident => |first_name| {
                                var imported_name = first_name;
                                // Inline `type` modifier: `type Foo` or `type Foo as Bar` (vs `{ type }` / `{ type as T }`)
                                if (std.mem.eql(u8, first_name, "type")) {
                                    const peek_after = lex.peek();
                                    if (peek_after == .ident and !std.mem.eql(u8, peek_after.ident, "as")) {
                                        imported_name = lex.next().ident;
                                    }
                                }
                                const after_imp = lex.peek();
                                if (after_imp == .ident and std.mem.eql(u8, after_imp.ident, "as")) {
                                    _ = lex.next();
                                    const local_tok = lex.next();
                                    if (local_tok == .ident and std.mem.eql(u8, local_tok.ident, ident)) {
                                        matched_in_braces = true;
                                    }
                                } else {
                                    if (std.mem.eql(u8, imported_name, ident)) {
                                        matched_in_braces = true;
                                    }
                                }
                            },
                        }
                    }
                    if (matched_in_braces and !restOfImportTargetsBuiltinBufferOrGlobal(&lex)) return true;
                }
            },
        }
    }
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

    try std.testing.expect(isStandardBuiltinGlobalType("WeakRef"));
    try std.testing.expect(isStandardBuiltinGlobalType("Intl.DateTimeFormat"));
    try std.testing.expect(isStandardBuiltinGlobalType("Temporal.Instant"));
    try std.testing.expect(isStandardBuiltinGlobalType("globalThis.Temporal.Duration"));
    try std.testing.expect(!isStandardBuiltinGlobalType("Duration"));
    try std.testing.expect(!isStandardBuiltinGlobalType("Locale"));
    try std.testing.expect(!isStandardBuiltinGlobalType("PropertyKey"));
    try std.testing.expect(!isStandardBuiltinGlobalType("ArrayBufferView"));
    try std.testing.expect(!isStandardBuiltinGlobalType("CustomNs.WeakRef"));
    try std.testing.expect(!isStandardBuiltinGlobalType("MissingUserType"));

    const sample_dts =
        \\// import { FakeComment } from "commented";
        \\/* import * as FakeBlock from "commented"; */
        \\import type { Duration, Orig as Renamed, type InlineT } from "luxon-missing";
        \\import DefImport, * as StarNs from "other-missing";
        \\import ReqAlias = require("cjs-missing");
        \\export type Dyn = import("not-local").WeakRef;
    ;
    try std.testing.expect(sourceHasLocalImportBinding(sample_dts, "Duration"));
    try std.testing.expect(sourceHasLocalImportBinding(sample_dts, "Renamed"));
    try std.testing.expect(!sourceHasLocalImportBinding(sample_dts, "Orig"));
    try std.testing.expect(sourceHasLocalImportBinding(sample_dts, "InlineT"));
    try std.testing.expect(sourceHasLocalImportBinding(sample_dts, "DefImport"));
    try std.testing.expect(sourceHasLocalImportBinding(sample_dts, "StarNs"));
    try std.testing.expect(sourceHasLocalImportBinding(sample_dts, "ReqAlias"));
    try std.testing.expect(!sourceHasLocalImportBinding(sample_dts, "FakeComment"));
    try std.testing.expect(!sourceHasLocalImportBinding(sample_dts, "FakeBlock"));
    try std.testing.expect(!sourceHasLocalImportBinding(sample_dts, "WeakRef"));
}
