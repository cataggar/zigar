const std = @import("std");
const builtin = @import("builtin");
const E = std.os.wasi.errno_t;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const arg_struct = @import("arg-struct.zig");
const signature = @import("signature.zig");
const util = @import("util.zig");
const module = @This();

pub const JsType = enum(u8) {
    @"undefined" = 0,
    object = 1,
    boolean = 2,
    number = 3,
    bigint = 4,
    string = 5,
    symbol = 6,
    function = 7,
};

pub const Error = error{
    OffJsThread,
    JsException,
    HostUnavailable,
};

pub const CallError = Error || error{
    NotCallable,
    ModuleNotFound,
    TypeError,
    RangeError,
    ReferenceError,
    SyntaxError,
    Overflow,
    OutOfMemory,
    Unexpected,
};

pub const OverflowError = Error || error{Overflow};

pub const AllocError = Error || std.mem.Allocator.Error;

pub const NullishKind = enum {
    none,
    undefined_only,
    null_only,
    null_or_undefined,
};

pub const TemplatePlaceholderKind = enum {
    any_string,
    number,
    bigint,
    boolean,
    literal_set,
};

fn resolveTemplatePlaceholderKind(comptime raw: anytype) TemplatePlaceholderKind {
    const RawT = @TypeOf(raw);
    if (RawT == TemplatePlaceholderKind) return raw;
    return switch (@typeInfo(RawT)) {
        .enum_literal, .@"enum" => @field(TemplatePlaceholderKind, @tagName(raw)),
        else => @compileError("Invalid template placeholder kind: " ++ @typeName(RawT)),
    };
}

fn slotMatchesBytes(comptime raw_kind: anytype, comptime choices: anytype, seg: []const u8) bool {
    const kind = comptime resolveTemplatePlaceholderKind(raw_kind);
    return switch (kind) {
        .any_string => true,
        .boolean => std.mem.eql(u8, seg, "true") or std.mem.eql(u8, seg, "false"),
        .bigint => blk: {
            if (seg.len == 0) break :blk false;
            const digits = if (seg[0] == '-') seg[1..] else seg;
            if (digits.len == 0 or std.mem.eql(u8, seg, "-0")) break :blk false;
            for (digits) |ch| {
                if (ch < '0' or ch > '9') break :blk false;
            }
            break :blk true;
        },
        .number => blk: {
            if (seg.len == 0) break :blk false;
            if (std.mem.eql(u8, seg, "NaN") or
                std.mem.eql(u8, seg, "Infinity") or
                std.mem.eql(u8, seg, "-Infinity") or
                std.mem.eql(u8, seg, "+Infinity")) break :blk true;
            for (seg) |ch| {
                if (ch <= ' ' or ch == '_') break :blk false;
            }
            if (std.mem.startsWith(u8, seg, "0x") or std.mem.startsWith(u8, seg, "0X") or
                std.mem.startsWith(u8, seg, "0o") or std.mem.startsWith(u8, seg, "0O") or
                std.mem.startsWith(u8, seg, "0b") or std.mem.startsWith(u8, seg, "0B"))
            {
                _ = std.fmt.parseInt(u64, seg, 0) catch break :blk false;
                break :blk true;
            }
            for (seg) |ch| {
                if (std.ascii.isAlphabetic(ch) and ch != 'e' and ch != 'E') break :blk false;
            }
            _ = std.fmt.parseFloat(f64, seg) catch break :blk false;
            break :blk true;
        },
        .literal_set => blk: {
            inline for (choices) |c| {
                if (std.mem.eql(u8, seg, c)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn matchTemplateSpansAt(
    comptime spans: anytype,
    comptime idx: usize,
    rem: []const u8,
    failed_bits: ?*[spans.len][8]u64,
    steps_left: *usize,
) bool {
    if (idx >= spans.len) return rem.len == 0;
    if (steps_left.* == 0) return false;
    steps_left.* -= 1;
    if (failed_bits) |fb| {
        if (rem.len < 512) {
            const word = rem.len >> 6;
            const bit: u6 = @intCast(rem.len & 63);
            if ((fb[idx][word] & (@as(u64, 1) << bit)) != 0) return false;
        }
    }
    const sp = spans[idx];
    const sep: []const u8 = sp.literal_tail;
    if (idx + 1 == spans.len) {
        if (!std.mem.endsWith(u8, rem, sep)) return false;
        const ok = slotMatchesBytes(sp.placeholder, sp.choices, rem[0 .. rem.len - sep.len]);
        if (!ok) {
            if (failed_bits) |fb| {
                if (rem.len < 512) fb[idx][rem.len >> 6] |= (@as(u64, 1) << @intCast(rem.len & 63));
            }
        }
        return ok;
    }
    if (sep.len == 0) {
        if (comptime (resolveTemplatePlaceholderKind(sp.placeholder) == .any_string and
            resolveTemplatePlaceholderKind(spans[idx + 1].placeholder) == .any_string))
        {
            return matchTemplateSpansAt(spans, idx + 1, rem, failed_bits, steps_left);
        }
        var split: usize = 0;
        while (split <= rem.len) : (split += 1) {
            if (slotMatchesBytes(sp.placeholder, sp.choices, rem[0..split]) and
                matchTemplateSpansAt(spans, idx + 1, rem[split..], failed_bits, steps_left))
            {
                return true;
            }
        }
        if (failed_bits) |fb| {
            if (rem.len < 512) fb[idx][rem.len >> 6] |= (@as(u64, 1) << @intCast(rem.len & 63));
        }
        return false;
    }
    var search_from: usize = 0;
    while (search_from + sep.len <= rem.len) {
        const rel = std.mem.indexOfPos(u8, rem, search_from, sep) orelse break;
        if (slotMatchesBytes(sp.placeholder, sp.choices, rem[0..rel]) and
            matchTemplateSpansAt(spans, idx + 1, rem[rel + sep.len ..], failed_bits, steps_left))
        {
            return true;
        }
        search_from = rel + 1;
    }
    if (failed_bits) |fb| {
        if (rem.len < 512) fb[idx][rem.len >> 6] |= (@as(u64, 1) << @intCast(rem.len & 63));
    }
    return false;
}

pub fn matchTemplatePattern(comptime spec: anytype, s: []const u8) bool {
    const head: []const u8 = spec.head;
    if (!std.mem.startsWith(u8, s, head)) return false;
    var pos: usize = head.len;
    inline for (spec.spans) |sp| {
        if (sp.literal_tail.len > 0) {
            const found = std.mem.indexOfPos(u8, s, pos, sp.literal_tail) orelse return false;
            pos = found + sp.literal_tail.len;
        }
    }
    var steps_left: usize = 65_536;
    if (comptime (spec.spans.len > 0 and spec.spans.len <= 32)) {
        var fb: [spec.spans.len][8]u64 = @splat(@splat(0));
        return matchTemplateSpansAt(spec.spans, 0, s[head.len..], &fb, &steps_left);
    }
    return matchTemplateSpansAt(spec.spans, 0, s[head.len..], null, &steps_left);
}

fn isStringSliceCoercible(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .array and @typeInfo(pt.child).array.child == u8,
        else => false,
    };
}

pub fn coerceUnion(comptime U: type, val: anytype) U {
    @setEvalBranchQuota(200_000);
    const ValT = @TypeOf(val);
    if (ValT == U) return val;
    const un = @typeInfo(U).@"union";
    comptime var exact_idx: ?usize = null;
    comptime var exact_count: usize = 0;
    inline for (un.field_names, 0..) |_, i| {
        const FT = un.field_types[i];
        if (FT != void and FT == ValT) {
            exact_idx = i;
            exact_count += 1;
        }
    }
    if (exact_count == 1) {
        return @unionInit(U, un.field_names[exact_idx.?], val);
    }
    if (comptime isStringSliceCoercible(ValT)) {
        const slice_val: []const u8 = val;
        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
            inline for (U.zigar_js.variants) |v| {
                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "str_value")) {
                    if (std.mem.eql(u8, slice_val, v.str_value)) {
                        return @unionInit(U, v.tag, {});
                    }
                }
            }
        }
        comptime var str_idx: ?usize = null;
        comptime var str_count: usize = 0;
        inline for (un.field_names, 0..) |_, i| {
            if (un.field_types[i] == []const u8) {
                str_idx = i;
                str_count += 1;
            }
        }
        if (str_count == 1) {
            return @unionInit(U, un.field_names[str_idx.?], slice_val);
        }
    }
    if (ValT == bool) {
        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
            inline for (U.zigar_js.variants) |v| {
                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "bool_value")) {
                    if (val == v.bool_value) {
                        return @unionInit(U, v.tag, {});
                    }
                }
            }
        }
    }
    if (ValT == f64) {
        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
            inline for (U.zigar_js.variants) |v| {
                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "num_value")) {
                    if (val == v.num_value) {
                        return @unionInit(U, v.tag, {});
                    }
                }
            }
        }
    }
    if (ValT == i64) {
        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
            inline for (U.zigar_js.variants) |v| {
                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "bigint_value")) {
                    if (comptime @as(?i64, std.fmt.parseInt(i64, v.bigint_value, 0) catch null)) |iv| {
                        if (val == iv) return @unionInit(U, v.tag, {});
                    }
                }
            }
        }
    }
    const val_info = @typeInfo(ValT);
    if (val_info == .comptime_int or val_info == .comptime_float) {
        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
            inline for (U.zigar_js.variants) |v| {
                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "num_value")) {
                    if (@as(f64, val) == v.num_value) {
                        return @unionInit(U, v.tag, {});
                    }
                }
            }
            if (val_info == .comptime_int) {
                inline for (U.zigar_js.variants) |v| {
                    if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "bigint_value")) {
                        if (comptime @as(?i64, std.fmt.parseInt(i64, v.bigint_value, 0) catch null)) |iv| {
                            if (val == @as(comptime_int, iv)) return @unionInit(U, v.tag, {});
                        }
                    }
                }
            }
        }
        comptime var num_idx: ?usize = null;
        comptime var num_count: usize = 0;
        inline for (un.field_names, 0..) |_, i| {
            const FT = un.field_types[i];
            if (FT == f64 or (val_info == .comptime_int and (FT == i64 or FT == i32))) {
                num_idx = i;
                num_count += 1;
            }
        }
        if (num_count == 1) {
            const TargetNum = un.field_types[num_idx.?];
            return @unionInit(U, un.field_names[num_idx.?], @as(TargetNum, val));
        }
    }
    @compileError("Cannot unambiguously coerce value of type " ++ @typeName(ValT) ++ " into union " ++ @typeName(U));
}

pub fn Nullable(comptime T: type) type {
    return union(enum) {
        @"undefined",
        @"null",
        value: T,

        pub const Value = T;
        pub const is_zigar_nullable = true;

        pub inline fn isUndefined(self: @This()) bool {
            return self == .@"undefined";
        }

        pub inline fn isNull(self: @This()) bool {
            return self == .@"null";
        }

        pub inline fn isNullOrUndefined(self: @This()) bool {
            return self != .value;
        }

        pub inline fn toOptional(self: @This()) ?T {
            return switch (self) {
                .value => |v| v,
                else => null,
            };
        }

        pub inline fn fromOptional(opt: ?T) @This() {
            return if (opt) |v| .{ .value = v } else .@"null";
        }

        pub inline fn fromOptionalUndefined(opt: ?T) @This() {
            return if (opt) |v| .{ .value = v } else .@"undefined";
        }

        pub fn deinit(self: @This()) void {
            switch (self) {
                .value => |v| {
                    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
                        const DeinitFn = @TypeOf(T.deinit);
                        if (@typeInfo(DeinitFn) == .@"fn" and @typeInfo(DeinitFn).@"fn".param_types.len == 1) {
                            v.deinit();
                        }
                    }
                },
                else => {},
            }
        }
    };
}

pub const HostOp = enum(u32) {
    import_module = 1,
    get_global = 2,
    get_prop = 3,
    set_prop = 4,
    delete_prop = 5,
    has_prop = 6,
    call_fn = 7,
    call_method = 8,
    construct = 9,
    binary_create = 10,
    binary_read = 11,
    binary_write = 12,
    binary_info = 13,
    bigint_from_words = 14,
    bigint_from_string = 15,
    bigint_to_words = 16,
    bigint_to_string = 17,
    get_iterator = 18,
    iterator_next = 19,
    iterator_return = 20,
    promise_settle = 21,
    collection_op = 22,
};

pub const AwaitMode = enum(u32) {
    promise = 0,
    async_iterator_next = 1,
    async_iterator_return = 2,
};

pub const BinaryKind = enum(u32) {
    array_buffer = 0,
    shared_array_buffer = 1,
    data_view = 2,
    buffer = 3,
    uint8_array = 4,
    int8_array = 5,
    uint8_clamped_array = 6,
    uint16_array = 7,
    int16_array = 8,
    uint32_array = 9,
    int32_array = 10,
    big_uint64_array = 11,
    big_int64_array = 12,
    float32_array = 13,
    float64_array = 14,
};

pub const BinaryInfoKind = enum(u32) {
    byte_length = 0,
    byte_offset = 1,
    element_length = 2,
    is_buffer = 3,
    is_array = 4,
};

pub const CollectionSubOp = enum(u32) {
    array_init = 0,
    array_with_capacity = 1,
    array_len = 2,
    array_get = 3,
    array_set = 4,
    array_push = 5,
    array_pop = 6,
    map_init = 7,
    map_size = 8,
    map_get = 9,
    map_set = 10,
    map_has = 11,
    map_delete = 12,
    map_clear = 13,
    map_keys = 14,
    map_values = 15,
    map_entries = 16,
    set_init = 17,
    set_size = 18,
    set_add = 19,
    set_has = 20,
    set_delete = 21,
    set_clear = 22,
    set_values = 23,
    record_init = 24,
    record_get = 25,
    record_set = 26,
    record_has = 27,
    record_delete = 28,
    record_keys = 29,
    typed_array_get = 30,
    typed_array_set = 31,
    data_view_init = 32,
    binary_slice = 33,
    binary_get_buffer = 34,
    buffer_from_string = 35,
    buffer_to_string = 36,
    date_now = 37,
    date_from_ms = 38,
    date_from_iso = 39,
    date_get_ms = 40,
    date_to_iso = 41,
    regexp_init = 42,
    regexp_test = 43,
    regexp_source = 44,
    regexp_flags = 45,
    string_from_utf8 = 46,
    string_to_utf8 = 47,
    string_byte_len = 48,
    string_utf16_len = 49,
    string_is_string = 50,
    value_identity = 51,
    binary_is_kind = 52,
};

pub const HostOpFlags = packed struct(u32) {
    dynamic_key: bool = false,
    module_default: bool = false,
    _: u30 = 0,
};

pub const JsModuleNode = struct {
    key: []const u8,
    registered: bool = false,
    next: ?*JsModuleNode = null,
};

pub const CallbackFlags = packed struct(u32) {
    async_call: bool = false,
    once: bool = false,
    pass_this: bool = false,
    ref_codec: bool = false,
    stateless: bool = false,
    _: u27 = 0,
};

pub const LastErrorOp = enum(u32) {
    peek = 0,
    take = 1,
    has = 2,
    clear = 3,
};

pub const HostOpDescriptor = extern struct {
    signature: u64,
    op: u32,
    flags: u32,
    key_ptr: ?[*]const u8,
    key_len: usize,
    register_thunk: usize,
    arg_size: usize,
};

pub const CallbackDescriptor = extern struct {
    signature: u64,
    flags: u32 = 0,
    reserved: u32 = 0,
    trampoline_thunk: usize = 0,
    register_thunk: usize = 0,
    cancel_thunk: usize = 0,
};

pub const Any = opaque {};
pub const Unknown = opaque {};
pub const Object = opaque {};
pub const Symbol = opaque {};
pub const Function = opaque {};

pub const reserved_undefined_handle: u32 = 0;
pub const reserved_null_handle: u32 = 1;
pub const reserved_false_handle: u32 = 2;
pub const reserved_true_handle: u32 = 3;
pub const reserved_global_this_handle: u32 = 4;
pub const no_captured_error_handle: u32 = 7;
pub const first_dynamic_slot: u32 = 8;

pub const hidden_meta_field_name = "__zigar_js_meta";

pub fn isHiddenMetaField(comptime fname: []const u8) bool {
    return std.mem.eql(u8, fname, hidden_meta_field_name);
}

pub fn hasStructZigarJsMeta(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "zigar_js")) return true;
    if (@hasField(T, hidden_meta_field_name)) {
        const Carrier = @FieldType(T, hidden_meta_field_name);
        return @typeInfo(Carrier) == .@"struct" and @hasDecl(Carrier, "zigar_js");
    }
    return false;
}

fn StructZigarJsMetaType(comptime T: type) type {
    if (@hasDecl(T, "zigar_js")) return @TypeOf(T.zigar_js);
    return @TypeOf(@FieldType(T, hidden_meta_field_name).zigar_js);
}

pub fn getStructZigarJsMeta(comptime T: type) StructZigarJsMetaType(T) {
    if (@hasDecl(T, "zigar_js")) return T.zigar_js;
    return @FieldType(T, hidden_meta_field_name).zigar_js;
}

fn isModuleNullableType(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasDecl(T, "is_zigar_nullable") and T.is_zigar_nullable;
}

fn isPlainValueStructForTransform(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@typeInfo(T).@"struct".is_tuple) return false;
    if (util.getInternalType(T) == .js_value) return false;
    if (isGeneratedHandleStruct(T)) return false;
    if (@hasDecl(T, "is_zig_callback") and T.is_zig_callback) return false;
    if (@hasDecl(T, "is_zigar_once_fn") and T.is_zigar_once_fn) return false;
    if (@hasDecl(T, "is_zigar_inline_closure") and T.is_zigar_inline_closure) return false;
    if (@hasDecl(T, "is_zigar_intersect_handle") and T.is_zigar_intersect_handle) return false;
    if (@hasDecl(T, "is_js_module_descriptor") and T.is_js_module_descriptor) return false;
    if (@hasDecl(T, "zigar_js_tuple")) return false;
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        const MetaT = @TypeOf(meta);
        if (@hasField(MetaT, "is_template_literal") and meta.is_template_literal) return false;
        if (@hasField(MetaT, "is_enum") and meta.is_enum) return false;
        if (@hasField(MetaT, "is_open_literal") and meta.is_open_literal) return false;
    }
    return true;
}

fn topStructFieldWireName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (@hasField(@TypeOf(meta), "fields")) {
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, field_name)) {
                    if (@hasField(@TypeOf(fm), "js_name")) return fm.js_name;
                    return field_name;
                }
            }
        }
    }
    return field_name;
}

fn topStructFieldIsOptional(comptime T: type, comptime field_name: []const u8, comptime has_default: bool) bool {
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (@hasField(@TypeOf(meta), "fields")) {
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, field_name)) {
                    if (@hasField(@TypeOf(fm), "is_optional")) return fm.is_optional;
                    return has_default;
                }
            }
        }
    }
    return has_default;
}

const TransformMetaMode = enum {
    preserve,
    make_partial,
    make_required,
};

fn specTopSelfNullish(comptime spec: anytype) NullishKind {
    const SpecT = @TypeOf(spec);
    if (SpecT == NullishKind) return spec;
    return switch (@typeInfo(SpecT)) {
        .enum_literal => @field(NullishKind, @tagName(spec)),
        .@"struct" => if (@hasField(SpecT, "self")) specTopSelfNullish(spec.self) else .none,
        else => .none,
    };
}

fn RebuildSpecWithSelfType(comptime SpecT: type) type {
    if (@typeInfo(SpecT) != .@"struct" or !@hasField(SpecT, "self")) return NullishKind;
    if (@hasField(SpecT, "child")) {
        return if (@hasField(SpecT, "id"))
            struct { id: @FieldType(SpecT, "id"), self: NullishKind, child: @FieldType(SpecT, "child") }
        else
            struct { self: NullishKind, child: @FieldType(SpecT, "child") };
    }
    if (@hasField(SpecT, "elem")) {
        return struct { self: NullishKind, elem: @FieldType(SpecT, "elem") };
    }
    if (@hasField(SpecT, "fields")) {
        return if (@hasField(SpecT, "id"))
            struct { id: @FieldType(SpecT, "id"), self: NullishKind, fields: @FieldType(SpecT, "fields") }
        else
            struct { self: NullishKind, fields: @FieldType(SpecT, "fields") };
    }
    if (@hasField(SpecT, "variants")) {
        return if (@hasField(SpecT, "id"))
            struct { id: @FieldType(SpecT, "id"), self: NullishKind, variants: @FieldType(SpecT, "variants") }
        else
            struct { self: NullishKind, variants: @FieldType(SpecT, "variants") };
    }
    if (@hasField(SpecT, "tuple")) {
        return if (@hasField(SpecT, "id"))
            struct { id: @FieldType(SpecT, "id"), self: NullishKind, tuple: @FieldType(SpecT, "tuple") }
        else
            struct { self: NullishKind, tuple: @FieldType(SpecT, "tuple") };
    }
    return NullishKind;
}

fn rebuildSpecWithSelf(comptime spec: anytype, comptime new_self: NullishKind) RebuildSpecWithSelfType(@TypeOf(spec)) {
    const SpecT = @TypeOf(spec);
    if (@typeInfo(SpecT) != .@"struct" or !@hasField(SpecT, "self")) return new_self;
    if (@hasField(SpecT, "child")) {
        return if (@hasField(SpecT, "id"))
            .{ .id = spec.id, .self = new_self, .child = spec.child }
        else
            .{ .self = new_self, .child = spec.child };
    }
    if (@hasField(SpecT, "elem")) {
        return .{ .self = new_self, .elem = spec.elem };
    }
    if (@hasField(SpecT, "fields")) {
        return if (@hasField(SpecT, "id"))
            .{ .id = spec.id, .self = new_self, .fields = spec.fields }
        else
            .{ .self = new_self, .fields = spec.fields };
    }
    if (@hasField(SpecT, "variants")) {
        return if (@hasField(SpecT, "id"))
            .{ .id = spec.id, .self = new_self, .variants = spec.variants }
        else
            .{ .self = new_self, .variants = spec.variants };
    }
    if (@hasField(SpecT, "tuple")) {
        return if (@hasField(SpecT, "id"))
            .{ .id = spec.id, .self = new_self, .tuple = spec.tuple }
        else
            .{ .self = new_self, .tuple = spec.tuple };
    }
    return new_self;
}

fn UnwrapSpecChildType(comptime SpecT: type) type {
    if (@typeInfo(SpecT) == .@"struct" and @hasField(SpecT, "child")) {
        return @FieldType(SpecT, "child");
    }
    return NullishKind;
}

fn unwrapSpecChild(comptime spec: anytype) UnwrapSpecChildType(@TypeOf(spec)) {
    const SpecT = @TypeOf(spec);
    if (@typeInfo(SpecT) == .@"struct" and @hasField(SpecT, "child")) {
        return spec.child;
    }
    return .none;
}

fn WrapSpecAsOptionalType(comptime spec: anytype) type {
    const SpecT = @TypeOf(spec);
    if (@typeInfo(SpecT) == .@"struct") {
        return struct { self: NullishKind, child: SpecT };
    }
    const cur = specTopSelfNullish(spec);
    if (cur == .none) return NullishKind;
    return struct { self: NullishKind, child: NullishKind };
}

fn wrapSpecAsOptional(comptime spec: anytype, comptime outer_self: NullishKind) WrapSpecAsOptionalType(spec) {
    const SpecT = @TypeOf(spec);
    if (@typeInfo(SpecT) == .@"struct") {
        return .{ .self = outer_self, .child = spec };
    }
    const cur = specTopSelfNullish(spec);
    if (cur == .none) return outer_self;
    return .{ .self = outer_self, .child = cur };
}

fn ComputedTransformedNullishType(comptime T: type, comptime fname: []const u8, comptime mode: TransformMetaMode) type {
    const OrigFT = @FieldType(T, fname);
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (@hasField(@TypeOf(meta), "fields")) {
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, fname)) {
                    const FmT = @TypeOf(fm);
                    const has_nullish = @hasField(FmT, "nullish");
                    if (!has_nullish) return NullishKind;
                    const fm_is_opt = @hasField(FmT, "is_optional") and fm.is_optional;
                    const cur_self = specTopSelfNullish(fm.nullish);
                    return switch (mode) {
                        .preserve => @TypeOf(fm.nullish),
                        .make_partial => if (@typeInfo(OrigFT) == .optional or isModuleNullableType(OrigFT))
                            RebuildSpecWithSelfType(@TypeOf(fm.nullish))
                        else
                            WrapSpecAsOptionalType(fm.nullish),
                        .make_required => if (!fm_is_opt)
                            @TypeOf(fm.nullish)
                        else if (isModuleNullableType(OrigFT) or cur_self == .null_only or cur_self == .null_or_undefined)
                            RebuildSpecWithSelfType(@TypeOf(fm.nullish))
                        else
                            UnwrapSpecChildType(@TypeOf(fm.nullish)),
                    };
                }
            }
        }
    }
    return NullishKind;
}

fn computeTransformedNullish(
    comptime T: type,
    comptime fname: []const u8,
    comptime mode: TransformMetaMode,
) ComputedTransformedNullishType(T, fname, mode) {
    const OrigFT = @FieldType(T, fname);
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (@hasField(@TypeOf(meta), "fields")) {
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, fname)) {
                    const FmT = @TypeOf(fm);
                    const has_nullish = @hasField(FmT, "nullish");
                    if (!has_nullish) {
                        return if (mode == .make_partial) NullishKind.undefined_only else NullishKind.none;
                    }
                    const fm_is_opt = @hasField(FmT, "is_optional") and fm.is_optional;
                    const cur_self = specTopSelfNullish(fm.nullish);
                    return switch (mode) {
                        .preserve => fm.nullish,
                        .make_partial => blk: {
                            if (@typeInfo(OrigFT) == .optional or isModuleNullableType(OrigFT)) {
                                const merged_self: NullishKind = if (cur_self == .null_only or cur_self == .null_or_undefined)
                                    .null_or_undefined
                                else
                                    .undefined_only;
                                break :blk rebuildSpecWithSelf(fm.nullish, merged_self);
                            }
                            break :blk wrapSpecAsOptional(fm.nullish, .undefined_only);
                        },
                        .make_required => blk: {
                            if (!fm_is_opt) break :blk fm.nullish;
                            if (isModuleNullableType(OrigFT) or cur_self == .null_only or cur_self == .null_or_undefined) {
                                break :blk rebuildSpecWithSelf(fm.nullish, .null_only);
                            }
                            break :blk unwrapSpecChild(fm.nullish);
                        },
                    };
                }
            }
        }
    }
    return if (mode == .make_partial) NullishKind.undefined_only else NullishKind.none;
}

fn requiredFieldResolution(comptime T: type, comptime fname: []const u8, comptime OrigFT: type) struct {
    ty: type,
    preserve_default: bool,
} {
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (@hasField(@TypeOf(meta), "fields")) {
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, fname)) {
                    const FmT = @TypeOf(fm);
                    const fm_is_opt = @hasField(FmT, "is_optional") and fm.is_optional;
                    if (!fm_is_opt) {
                        return .{ .ty = OrigFT, .preserve_default = true };
                    }
                    if (isModuleNullableType(OrigFT)) {
                        return .{ .ty = ?OrigFT.Value, .preserve_default = false };
                    }
                    const cur_self = if (@hasField(FmT, "nullish")) specTopSelfNullish(fm.nullish) else NullishKind.none;
                    if (cur_self == .null_only or cur_self == .null_or_undefined) {
                        return .{ .ty = OrigFT, .preserve_default = false };
                    }
                    const unwrapped = if (@typeInfo(OrigFT) == .optional) @typeInfo(OrigFT).optional.child else OrigFT;
                    return .{ .ty = unwrapped, .preserve_default = false };
                }
            }
        }
    }
    if (@typeInfo(OrigFT) == .optional) {
        return .{ .ty = @typeInfo(OrigFT).optional.child, .preserve_default = false };
    }
    if (isModuleNullableType(OrigFT)) {
        return .{ .ty = OrigFT.Value, .preserve_default = false };
    }
    return .{ .ty = OrigFT, .preserve_default = true };
}

fn TransformFieldEntryType(comptime T: type, comptime fname: []const u8, comptime mode: TransformMetaMode) type {
    const wire = topStructFieldWireName(T, fname);
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (@hasField(@TypeOf(meta), "fields")) {
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, fname)) {
                    if (mode == .preserve) return @TypeOf(fm);
                    const FmT = @TypeOf(fm);
                    const NullishT = ComputedTransformedNullishType(T, fname, mode);
                    return buildConstraintPreservingDescriptorType(FmT, NullishT);
                }
            }
        }
    }
    _ = wire;
    return struct {
        name: []const u8,
        js_name: []const u8,
        is_optional: bool,
        nullish: NullishKind,
    };
}

fn buildConstraintPreservingDescriptorType(comptime FmT: type, comptime NullishT: type) type {
    comptime var fnames: [10][]const u8 = undefined;
    comptime var ftypes: [10]type = undefined;
    comptime var fattrs: [10]std.builtin.Type.Struct.FieldAttributes = undefined;
    comptime var n: usize = 0;

    fnames[n] = "name";
    ftypes[n] = []const u8;
    fattrs[n] = .{};
    n += 1;

    fnames[n] = "js_name";
    ftypes[n] = []const u8;
    fattrs[n] = .{};
    n += 1;

    fnames[n] = "is_optional";
    ftypes[n] = bool;
    fattrs[n] = .{};
    n += 1;

    fnames[n] = "nullish";
    ftypes[n] = NullishT;
    fattrs[n] = .{};
    n += 1;

    const extras = [_][]const u8{
        "expected_str",
        "expected_num",
        "expected_bool",
        "expected_bigint_i64",
        "expected_bigint_str",
        "expected_enum_tag",
    };
    inline for (extras) |ex| {
        if (@hasField(FmT, ex)) {
            fnames[n] = ex;
            ftypes[n] = @FieldType(FmT, ex);
            fattrs[n] = .{};
            n += 1;
        }
    }
    const names_fin = fnames[0..n].*;
    const types_fin = ftypes[0..n].*;
    const attrs_fin = fattrs[0..n].*;
    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
}

fn transformOneFieldDescriptor(
    comptime T: type,
    comptime fname: []const u8,
    comptime mode: TransformMetaMode,
) TransformFieldEntryType(T, fname, mode) {
    const OutT = TransformFieldEntryType(T, fname, mode);
    const wire = topStructFieldWireName(T, fname);
    if (hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (@hasField(@TypeOf(meta), "fields")) {
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, fname)) {
                    if (mode == .preserve) return fm;
                    const FmT = @TypeOf(fm);
                    var out: OutT = undefined;
                    out.name = fname;
                    out.js_name = wire;
                    out.is_optional = (mode == .make_partial);
                    out.nullish = computeTransformedNullish(T, fname, mode);
                    const extras = [_][]const u8{
                        "expected_str",
                        "expected_num",
                        "expected_bool",
                        "expected_bigint_i64",
                        "expected_bigint_str",
                        "expected_enum_tag",
                    };
                    inline for (extras) |ex| {
                        if (@hasField(FmT, ex)) {
                            @field(out, ex) = @field(fm, ex);
                        }
                    }
                    return out;
                }
            }
        }
    }
    return .{
        .name = fname,
        .js_name = wire,
        .is_optional = (mode == .make_partial),
        .nullish = if (mode == .make_partial) NullishKind.undefined_only else NullishKind.none,
    };
}

fn buildStructMetaCarrier(
    comptime T: type,
    comptime kept_names: []const []const u8,
    comptime mode: TransformMetaMode,
) type {
    comptime var entry_types: [kept_names.len]type = undefined;
    inline for (kept_names, 0..) |fname, i| {
        entry_types[i] = TransformFieldEntryType(T, fname, mode);
    }
    const FieldsTuple = @Tuple(&entry_types);
    const fields_val = comptime blk: {
        var tup: FieldsTuple = undefined;
        for (kept_names, 0..) |fname, i| {
            tup[i] = transformOneFieldDescriptor(T, fname, mode);
        }
        break :blk tup;
    };
    return struct {
        pub const zigar_js = .{
            .fields = fields_val,
        };
    };
}

fn defaultPtrForValue(comptime FieldT: type, comptime val: FieldT) *const anyopaque {
    const Holder = struct {
        const stored: FieldT = val;
    };
    return @ptrCast(&Holder.stored);
}

fn isComptimeKeyStringType(comptime KT: type) bool {
    if (KT == []const u8) return true;
    return switch (@typeInfo(KT)) {
        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .array and @typeInfo(pt.child).array.child == u8,
        else => false,
    };
}

fn formatComptimeJsNumberKey(comptime n_any: anytype) []const u8 {
    const NT = @TypeOf(n_any);
    if (@typeInfo(NT) == .int or @typeInfo(NT) == .comptime_int) {
        return std.fmt.comptimePrint("{d}", .{n_any});
    }
    const n: f64 = @floatCast(n_any);
    if (n == 0.0) return "0";
    if (std.math.isFinite(n) and @trunc(n) == n and @abs(n) <= 9007199254740991.0) {
        return std.fmt.comptimePrint("{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.comptimePrint("{d}", .{n});
}

fn enumMemberWireKey(comptime m: anytype) []const u8 {
    const MT = @TypeOf(m);
    if (@hasField(MT, "str_value")) return m.str_value;
    if (@hasField(MT, "num_value")) return formatComptimeJsNumberKey(m.num_value);
    if (@hasField(MT, "int_value")) return formatComptimeJsNumberKey(m.int_value);
    if (@hasField(MT, "float_value")) return formatComptimeJsNumberKey(m.float_value);
    if (@hasField(MT, "bool_value")) return if (m.bool_value) "true" else "false";
    if (@hasField(MT, "bigint_value")) return m.bigint_value;
    if (@hasField(MT, "js_name")) return m.js_name;
    return m.tag;
}

fn comptimeSnakeFieldName(comptime raw: []const u8) []const u8 {
    if (raw.len == 0) return "_empty";
    comptime var buf: [raw.len * 2 + 1]u8 = undefined;
    comptime var out_len: usize = 0;
    comptime var word_count: usize = 0;
    comptime var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and !std.ascii.isAlphanumeric(raw[i])) : (i += 1) {}
        if (i >= raw.len) break;
        const start = i;
        if (std.ascii.isDigit(raw[i])) {
            while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {}
            if (start == 0 and i < raw.len and std.ascii.isAlphabetic(raw[i])) {
                while (i < raw.len and std.ascii.isAlphanumeric(raw[i]) and !std.ascii.isUpper(raw[i])) : (i += 1) {}
            }
        } else if (std.ascii.isUpper(raw[i])) {
            i += 1;
            if (i < raw.len and std.ascii.isUpper(raw[i])) {
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
        if (word_count > 0) {
            buf[out_len] = '_';
            out_len += 1;
        }
        for (raw[start..i]) |ch| {
            buf[out_len] = std.ascii.toLower(ch);
            out_len += 1;
        }
        word_count += 1;
    }
    if (word_count == 0) return "_";
    const fin = buf[0..out_len].*;
    return &fin;
}

fn isReservedRecordFieldName(comptime cand: []const u8, comptime used: []const []const u8) bool {
    if (isHiddenMetaField(cand) or std.mem.eql(u8, cand, "zigar_js") or std.mem.eql(u8, cand, "zigar_js_tuple")) {
        return true;
    }
    for (used) |u| {
        if (std.mem.eql(u8, u, cand)) return true;
    }
    return false;
}

fn dedupeComptimeFieldName(comptime base: []const u8, comptime used: []const []const u8) []const u8 {
    if (!isReservedRecordFieldName(base, used)) return base;
    comptime var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const cand = std.fmt.comptimePrint("{s}_{d}", .{ base, suffix });
        if (!isReservedRecordFieldName(cand, used)) return cand;
    }
}

fn canExtractSingleComptimeKey(comptime ItemT: type) bool {
    if (isComptimeKeyStringType(ItemT)) return true;
    return switch (@typeInfo(ItemT)) {
        .enum_literal, .int, .comptime_int, .float, .comptime_float, .bool, .@"enum" => true,
        else => false,
    };
}

fn extractSingleComptimeKey(comptime item: anytype) []const u8 {
    const ItemT = @TypeOf(item);
    if (isComptimeKeyStringType(ItemT)) return item;
    return switch (@typeInfo(ItemT)) {
        .enum_literal => @tagName(item),
        .int, .comptime_int, .float, .comptime_float => formatComptimeJsNumberKey(item),
        .bool => if (item) "true" else "false",
        .@"enum" => blk: {
            @setEvalBranchQuota(200_000);
            if (@hasDecl(ItemT, "zigar_js") and @hasField(@TypeOf(ItemT.zigar_js), "members")) {
                for (ItemT.zigar_js.members) |m| {
                    if (std.mem.eql(u8, m.tag, @tagName(item))) {
                        break :blk enumMemberWireKey(m);
                    }
                }
            }
            break :blk @tagName(item);
        },
        else => @compileError("Unsupported key item for Pick/Omit/IndexAccess: " ++ @typeName(ItemT)),
    };
}

fn isNumericPropertyKeyString(comptime s: []const u8) bool {
    if (s.len == 0) return false;
    const parsed = std.fmt.parseFloat(f64, s) catch return false;
    return std.mem.eql(u8, formatComptimeJsNumberKey(parsed), s);
}

fn extractKeyListFromSpec(comptime keys_spec: anytype) []const []const u8 {
    @setEvalBranchQuota(200_000);
    const SpecT = @TypeOf(keys_spec);
    if (SpecT == type) {
        if (keys_spec == void or keys_spec == noreturn) return &.{};
        if (keys_spec == []const u8) return &.{};
        switch (@typeInfo(keys_spec)) {
            .@"enum" => |en| {
                if (@hasDecl(keys_spec, "zigar_js") and @hasField(@TypeOf(keys_spec.zigar_js), "members")) {
                    comptime var count: usize = 0;
                    for (keys_spec.zigar_js.members) |m| {
                        if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
                        count += 1;
                    }
                    comptime var arr: [count][]const u8 = undefined;
                    comptime var idx: usize = 0;
                    for (keys_spec.zigar_js.members) |m| {
                        if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
                        arr[idx] = enumMemberWireKey(m);
                        idx += 1;
                    }
                    const fin = arr;
                    return &fin;
                }
                return en.field_names;
            },
            .@"union" => {
                if (@hasDecl(keys_spec, "zigar_js") and @hasField(@TypeOf(keys_spec.zigar_js), "variants")) {
                    comptime var count: usize = 0;
                    for (keys_spec.zigar_js.variants) |v| {
                        if (@hasField(@TypeOf(v), "is_unit_literal") and v.is_unit_literal) {
                            count += 1;
                        }
                    }
                    comptime var arr: [count][]const u8 = undefined;
                    comptime var idx: usize = 0;
                    for (keys_spec.zigar_js.variants) |v| {
                        if (@hasField(@TypeOf(v), "is_unit_literal") and v.is_unit_literal) {
                            arr[idx] = enumMemberWireKey(v);
                            idx += 1;
                        }
                    }
                    const fin = arr;
                    return &fin;
                }
                return &.{};
            },
            else => return &.{},
        }
    }
    if (canExtractSingleComptimeKey(SpecT)) {
        const fin = [_][]const u8{extractSingleComptimeKey(keys_spec)};
        return &fin;
    }
    switch (@typeInfo(SpecT)) {
        .pointer => |pt| {
            if (pt.size == .slice and canExtractSingleComptimeKey(pt.child)) {
                comptime var arr: [keys_spec.len][]const u8 = undefined;
                for (keys_spec, 0..) |item, i| {
                    arr[i] = extractSingleComptimeKey(item);
                }
                const fin = arr;
                return &fin;
            }
            if (pt.size == .one and @typeInfo(pt.child) == .@"struct" and @typeInfo(pt.child).@"struct".is_tuple) {
                return extractKeyListFromSpec(keys_spec.*);
            }
            if (pt.size == .one and @typeInfo(pt.child) == .array) {
                const ElemT = @typeInfo(pt.child).array.child;
                if (canExtractSingleComptimeKey(ElemT)) {
                    comptime var arr: [keys_spec.len][]const u8 = undefined;
                    for (keys_spec, 0..) |item, i| {
                        arr[i] = extractSingleComptimeKey(item);
                    }
                    const fin = arr;
                    return &fin;
                }
            }
        },
        .@"struct" => |st| {
            if (st.is_tuple) {
                comptime var arr: [st.field_types.len][]const u8 = undefined;
                inline for (0..st.field_types.len) |i| {
                    arr[i] = extractSingleComptimeKey(keys_spec[i]);
                }
                const fin = arr;
                return &fin;
            }
        },
        else => {},
    }
    @compileError("Unsupported key specification for Pick/Omit/IndexAccess: " ++ @typeName(SpecT));
}

fn structHasExactWireKey(comptime T: type, comptime target_wire: []const u8) bool {
    const st = @typeInfo(T).@"struct";
    for (st.field_names) |other_fname| {
        if (isHiddenMetaField(other_fname)) continue;
        if (std.mem.eql(u8, topStructFieldWireName(T, other_fname), target_wire)) return true;
    }
    return false;
}

fn fieldMatchesAnyKey(comptime T: type, comptime fname: []const u8, comptime keys: []const []const u8) bool {
    const wire = topStructFieldWireName(T, fname);
    for (keys) |k| {
        if (std.mem.eql(u8, wire, k)) return true;
        if (!structHasExactWireKey(T, k) and std.mem.eql(u8, fname, k)) return true;
    }
    return false;
}

pub fn Partial(comptime T: type) type {
    @setEvalBranchQuota(200_000);
    if (!isPlainValueStructForTransform(T)) return T;
    const st = @typeInfo(T).@"struct";
    const need_meta = hasStructZigarJsMeta(T);
    comptime var real_count: usize = 0;
    for (st.field_names) |fname| {
        if (!isHiddenMetaField(fname)) real_count += 1;
    }
    const total_count = real_count + @intFromBool(need_meta);
    comptime var kept_names: [real_count][]const u8 = undefined;
    comptime var fnames: [total_count][]const u8 = undefined;
    comptime var ftypes: [total_count]type = undefined;
    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;

    comptime var out_i: usize = 0;
    inline for (st.field_names, 0..) |fname, fi| {
        if (comptime isHiddenMetaField(fname)) continue;
        const OrigFT = st.field_types[fi];
        const NewFT = if (@typeInfo(OrigFT) == .optional or isModuleNullableType(OrigFT)) OrigFT else ?OrigFT;
        const def_ptr: *const anyopaque = if (isModuleNullableType(NewFT))
            defaultPtrForValue(NewFT, .@"undefined")
        else
            defaultPtrForValue(NewFT, null);

        kept_names[out_i] = fname;
        fnames[out_i] = fname;
        ftypes[out_i] = NewFT;
        fattrs[out_i] = .{
            .default_value_ptr = def_ptr,
            .@"comptime" = false,
            .@"align" = @alignOf(NewFT),
        };
        out_i += 1;
    }

    if (need_meta) {
        const Carrier = buildStructMetaCarrier(T, &kept_names, .make_partial);
        fnames[real_count] = hidden_meta_field_name;
        ftypes[real_count] = Carrier;
        fattrs[real_count] = .{
            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
            .@"comptime" = false,
            .@"align" = @alignOf(Carrier),
        };
    }

    const names_fin = fnames;
    const types_fin = ftypes;
    const attrs_fin = fattrs;
    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
}

pub fn Required(comptime T: type) type {
    @setEvalBranchQuota(200_000);
    if (!isPlainValueStructForTransform(T)) return T;
    const st = @typeInfo(T).@"struct";
    const need_meta = hasStructZigarJsMeta(T);
    comptime var real_count: usize = 0;
    for (st.field_names) |fname| {
        if (!isHiddenMetaField(fname)) real_count += 1;
    }
    const total_count = real_count + @intFromBool(need_meta);
    comptime var kept_names: [real_count][]const u8 = undefined;
    comptime var fnames: [total_count][]const u8 = undefined;
    comptime var ftypes: [total_count]type = undefined;
    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;

    comptime var out_i: usize = 0;
    inline for (st.field_names, 0..) |fname, fi| {
        if (comptime isHiddenMetaField(fname)) continue;
        const OrigFT = st.field_types[fi];
        const req_res = comptime requiredFieldResolution(T, fname, OrigFT);
        const NewFT = req_res.ty;
        const preserve_default = req_res.preserve_default;

        kept_names[out_i] = fname;
        fnames[out_i] = fname;
        ftypes[out_i] = NewFT;
        fattrs[out_i] = .{
            .default_value_ptr = if (preserve_default) st.field_attrs[fi].default_value_ptr else null,
            .@"comptime" = false,
            .@"align" = @alignOf(NewFT),
        };
        out_i += 1;
    }

    if (need_meta) {
        const Carrier = buildStructMetaCarrier(T, &kept_names, .make_required);
        fnames[real_count] = hidden_meta_field_name;
        ftypes[real_count] = Carrier;
        fattrs[real_count] = .{
            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
            .@"comptime" = false,
            .@"align" = @alignOf(Carrier),
        };
    }

    const names_fin = fnames;
    const types_fin = ftypes;
    const attrs_fin = fattrs;
    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
}

pub fn Readonly(comptime T: type) type {
    @setEvalBranchQuota(200_000);
    return switch (@typeInfo(T)) {
        .pointer => |pt| switch (pt.size) {
            .slice => if (pt.attrs.@"const") T else []const pt.child,
            .one => if (pt.attrs.@"const") T else *const pt.child,
            else => T,
        },
        .@"struct" => |st| blk: {
            if (!isPlainValueStructForTransform(T)) break :blk T;
            const need_meta = hasStructZigarJsMeta(T);
            comptime var real_count: usize = 0;
            for (st.field_names) |fname| {
                if (!isHiddenMetaField(fname)) real_count += 1;
            }
            const total_count = real_count + @intFromBool(need_meta);
            comptime var kept_names: [real_count][]const u8 = undefined;
            comptime var fnames: [total_count][]const u8 = undefined;
            comptime var ftypes: [total_count]type = undefined;
            comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;

            comptime var out_i: usize = 0;
            inline for (st.field_names, 0..) |fname, fi| {
                if (comptime isHiddenMetaField(fname)) continue;
                const OrigFT = st.field_types[fi];
                kept_names[out_i] = fname;
                fnames[out_i] = fname;
                ftypes[out_i] = OrigFT;
                fattrs[out_i] = st.field_attrs[fi];
                out_i += 1;
            }

            if (need_meta) {
                const Carrier = buildStructMetaCarrier(T, &kept_names, .preserve);
                fnames[real_count] = hidden_meta_field_name;
                ftypes[real_count] = Carrier;
                fattrs[real_count] = .{
                    .default_value_ptr = defaultPtrForValue(Carrier, .{}),
                    .@"comptime" = false,
                    .@"align" = @alignOf(Carrier),
                };
            }

            const names_fin = fnames;
            const types_fin = ftypes;
            const attrs_fin = fattrs;
            break :blk @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        },
        else => T,
    };
}

fn filterStructFields(comptime T: type, comptime keys_spec: anytype, comptime include_matched: bool) type {
    @setEvalBranchQuota(200_000);
    if (!isPlainValueStructForTransform(T)) return T;
    const st = @typeInfo(T).@"struct";
    const keys = comptime extractKeyListFromSpec(keys_spec);
    const need_meta = hasStructZigarJsMeta(T);

    comptime var real_count: usize = 0;
    inline for (st.field_names) |fname| {
        if (comptime isHiddenMetaField(fname)) continue;
        const matched = comptime fieldMatchesAnyKey(T, fname, keys);
        if (matched == include_matched) real_count += 1;
    }

    const total_count = real_count + @intFromBool(need_meta and real_count > 0);
    comptime var kept_names: [real_count][]const u8 = undefined;
    comptime var fnames: [total_count][]const u8 = undefined;
    comptime var ftypes: [total_count]type = undefined;
    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;

    comptime var out_i: usize = 0;
    inline for (st.field_names, 0..) |fname, fi| {
        if (comptime isHiddenMetaField(fname)) continue;
        const matched = comptime fieldMatchesAnyKey(T, fname, keys);
        if (matched != include_matched) continue;
        kept_names[out_i] = fname;
        fnames[out_i] = fname;
        ftypes[out_i] = st.field_types[fi];
        fattrs[out_i] = st.field_attrs[fi];
        out_i += 1;
    }

    if (need_meta and real_count > 0) {
        const Carrier = buildStructMetaCarrier(T, &kept_names, .preserve);
        fnames[real_count] = hidden_meta_field_name;
        ftypes[real_count] = Carrier;
        fattrs[real_count] = .{
            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
            .@"comptime" = false,
            .@"align" = @alignOf(Carrier),
        };
    }

    const names_fin = fnames;
    const types_fin = ftypes;
    const attrs_fin = fattrs;
    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
}

pub fn Pick(comptime T: type, comptime keys_spec: anytype) type {
    return filterStructFields(T, keys_spec, true);
}

pub fn Omit(comptime T: type, comptime keys_spec: anytype) type {
    return filterStructFields(T, keys_spec, false);
}

fn mergePlainValueStructArms(comptime arms: []const type) type {
    @setEvalBranchQuota(200_000);
    if (arms.len == 0) return struct {};
    if (arms.len == 1 and isPlainValueStructForTransform(arms[0])) return arms[0];

    const PickedField = struct {
        arm_idx: usize,
        field_idx: usize,
        fname: []const u8,
        wire: []const u8,
    };
    comptime var max_fields: usize = 0;
    inline for (arms) |ArmT| {
        max_fields += @typeInfo(ArmT).@"struct".field_names.len;
    }
    if (max_fields == 0) return struct {};

    comptime var picked_buf: [max_fields]PickedField = undefined;
    comptime var real_count: usize = 0;
    comptime var need_meta = false;

    inline for (arms, 0..) |ArmT, arm_i| {
        if (hasStructZigarJsMeta(ArmT)) need_meta = true;
        const st = @typeInfo(ArmT).@"struct";
        inline for (st.field_names, 0..) |fname, fi| {
            if (comptime isHiddenMetaField(fname)) continue;
            const wire = topStructFieldWireName(ArmT, fname);
            if (!std.mem.eql(u8, fname, wire) or @typeInfo(st.field_types[fi]) == .optional or isModuleNullableType(st.field_types[fi])) {
                need_meta = true;
            }
            comptime var existing_slot: ?usize = null;
            for (0..real_count) |k| {
                if (std.mem.eql(u8, picked_buf[k].fname, fname) or std.mem.eql(u8, picked_buf[k].wire, wire)) {
                    existing_slot = k;
                    break;
                }
            }
            if (existing_slot) |slot| {
                picked_buf[slot] = .{ .arm_idx = arm_i, .field_idx = fi, .fname = fname, .wire = wire };
            } else {
                picked_buf[real_count] = .{ .arm_idx = arm_i, .field_idx = fi, .fname = fname, .wire = wire };
                real_count += 1;
            }
        }
    }

    const total_count = real_count + @intFromBool(need_meta and real_count > 0);
    comptime var fnames: [total_count][]const u8 = undefined;
    comptime var ftypes: [total_count]type = undefined;
    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;

    for (0..real_count) |out_i| {
        const pf = picked_buf[out_i];
        const ArmT = arms[pf.arm_idx];
        const st = @typeInfo(ArmT).@"struct";
        fnames[out_i] = pf.fname;
        ftypes[out_i] = st.field_types[pf.field_idx];
        fattrs[out_i] = st.field_attrs[pf.field_idx];
    }

    if (need_meta and real_count > 0) {
        comptime var entry_types: [real_count]type = undefined;
        for (0..real_count) |out_i| {
            const pf = picked_buf[out_i];
            entry_types[out_i] = TransformFieldEntryType(arms[pf.arm_idx], pf.fname, .preserve);
        }
        const FieldsTuple = @Tuple(&entry_types);
        const fields_val = comptime blk: {
            var tup: FieldsTuple = undefined;
            for (0..real_count) |out_i| {
                const pf = picked_buf[out_i];
                tup[out_i] = transformOneFieldDescriptor(arms[pf.arm_idx], pf.fname, .preserve);
            }
            break :blk tup;
        };
        const Carrier = struct {
            pub const zigar_js = .{
                .fields = fields_val,
            };
        };
        fnames[real_count] = hidden_meta_field_name;
        ftypes[real_count] = Carrier;
        fattrs[real_count] = .{
            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
            .@"comptime" = false,
            .@"align" = @alignOf(Carrier),
        };
    }

    const names_fin = fnames;
    const types_fin = ftypes;
    const attrs_fin = fattrs;
    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
}

const IntersectScalarKind = enum {
    none,
    string,
    number,
    bigint,
    boolean,
    symbol,
    sequence,
    other_enum,
};

fn classifyIntersectScalarKind(comptime T: type) IntersectScalarKind {
    if (T == []const u8) return .string;
    if (T == bool) return .boolean;
    if (isJsSymbolConstraintMarker(T)) return .symbol;
    return switch (@typeInfo(T)) {
        .float, .comptime_float => .number,
        .comptime_int => .number,
        .int => |it| if (it.bits >= 64) .bigint else .number,
        .pointer => |pt| if (pt.size == .slice) (if (pt.child == u8) .string else .sequence) else .none,
        .array => .sequence,
        .@"enum" => blk: {
            const has_slice = @hasDecl(T, "fromSlice");
            const has_num = @hasDecl(T, "toInt") or @hasDecl(T, "toFloat");
            if (has_slice and !has_num) break :blk .string;
            if (has_num and !has_slice) break :blk .number;
            break :blk .other_enum;
        },
        .@"struct" => blk: {
            if (isTemplateLiteralStruct(T)) break :blk .string;
            if (@hasDecl(T, "is_js_string") and T.is_js_string) break :blk .string;
            if (@hasDecl(T, "is_js_bigint") and T.is_js_bigint) break :blk .bigint;
            break :blk .none;
        },
        else => .none,
    };
}

fn intersectScalarSpecificity(comptime T: type) u8 {
    return switch (@typeInfo(T)) {
        .@"enum" => 3,
        .@"struct" => if (isTemplateLiteralStruct(T)) 2 else 1,
        else => 1,
    };
}

fn armIsReachableInHandleBases(comptime T: type, comptime Target: type, comptime depth: usize) bool {
    if (T == Target) return true;
    if (depth >= 32) return false;
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "zigar_js")) return false;
    if (!@hasField(@TypeOf(T.zigar_js), "bases")) return false;
    inline for (T.zigar_js.bases) |BaseT| {
        if (@TypeOf(BaseT) == type) {
            if (armIsReachableInHandleBases(BaseT, Target, depth + 1)) return true;
        }
    }
    return false;
}

const HostlessHandleRef = extern struct {
    pub const Target = Any;
    pub const is_js_value = true;
    handle: u32 = 0,
};

fn IntersectHandleWrapper(
    comptime HostJsOpt: ?type,
    comptime n_bases: usize,
    comptime bases_arr: [n_bases]type,
    comptime PlainOverlay: type,
) type {
    @setEvalBranchQuota(200_000);
    const RefT = if (HostJsOpt) |HJ| HJ.Ref(Any) else HostlessHandleRef;

    comptime var base_meta_types: [n_bases]type = undefined;
    for (0..n_bases) |bi| base_meta_types[bi] = type;
    const BasesTuple = @Tuple(&base_meta_types);
    const bases_val: BasesTuple = comptime blk: {
        var bt: BasesTuple = undefined;
        for (0..n_bases) |bi| bt[bi] = bases_arr[bi];
        break :blk bt;
    };

    const overlay_st = @typeInfo(PlainOverlay).@"struct";
    const plain_real_count = comptime blk: {
        var rc: usize = 0;
        for (overlay_st.field_names) |fnm| {
            if (!isHiddenMetaField(fnm)) rc += 1;
        }
        break :blk rc;
    };

    comptime var entry_types: [plain_real_count]type = undefined;
    comptime var req_props_buf: [plain_real_count][]const u8 = undefined;
    comptime var req_props_count: usize = 0;
    {
        comptime var oi: usize = 0;
        for (overlay_st.field_names, 0..) |fname, fi| {
            if (isHiddenMetaField(fname)) continue;
            entry_types[oi] = TransformFieldEntryType(PlainOverlay, fname, .preserve);
            const ft = overlay_st.field_types[fi];
            const is_opt = topStructFieldIsOptional(PlainOverlay, fname, overlay_st.field_attrs[fi].default_value_ptr != null) or
                @typeInfo(ft) == .optional or isModuleNullableType(ft);
            if (!is_opt) {
                req_props_buf[req_props_count] = topStructFieldWireName(PlainOverlay, fname);
                req_props_count += 1;
            }
            oi += 1;
        }
    }
    const FieldsTuple = @Tuple(&entry_types);
    const fields_val: FieldsTuple = comptime blk: {
        var tup: FieldsTuple = undefined;
        var oi: usize = 0;
        for (overlay_st.field_names) |fname| {
            if (isHiddenMetaField(fname)) continue;
            tup[oi] = transformOneFieldDescriptor(PlainOverlay, fname, .preserve);
            oi += 1;
        }
        break :blk tup;
    };
    const req_props_fin: [req_props_count][]const u8 = req_props_buf[0..req_props_count].*;

    const any_callable = comptime blk: {
        for (bases_arr) |B| {
            if (isJsFunctionConstraintMarker(B) or isCallbackWrapper(B)) break :blk true;
            if (@typeInfo(B) == .@"struct" and @hasDecl(B, "Target") and B.Target == Function) break :blk true;
            if (isGeneratedHandleStruct(B) and @hasField(@TypeOf(B.zigar_js), "is_callable_handle") and B.zigar_js.is_callable_handle) break :blk true;
        }
        break :blk false;
    };
    const any_iter = comptime blk: {
        for (bases_arr) |B| {
            if ((@typeInfo(B) == .@"struct" and @hasDecl(B, "is_js_iterator") and B.is_js_iterator) or structHasProtocolFlag(B, "has_iterator", 0)) break :blk true;
        }
        break :blk false;
    };
    const any_async_iter = comptime blk: {
        for (bases_arr) |B| {
            if ((@typeInfo(B) == .@"struct" and @hasDecl(B, "is_js_async_iterator") and B.is_js_async_iterator) or structHasProtocolFlag(B, "has_async_iterator", 0)) break :blk true;
        }
        break :blk false;
    };
    const any_disp = comptime blk: {
        for (bases_arr) |B| {
            if ((@typeInfo(B) == .@"struct" and @hasDecl(B, "is_js_disposable") and B.is_js_disposable) or structHasProtocolFlag(B, "has_dispose", 0)) break :blk true;
        }
        break :blk false;
    };
    const any_async_disp = comptime blk: {
        for (bases_arr) |B| {
            if ((@typeInfo(B) == .@"struct" and @hasDecl(B, "is_js_async_disposable") and B.is_js_async_disposable) or structHasProtocolFlag(B, "has_async_dispose", 0)) break :blk true;
        }
        break :blk false;
    };

    return struct {
        const Self = @This();

        ref: RefT = .{ .handle = 0 },

        pub const is_zigar_intersect_handle = true;
        pub const PlainFields = PlainOverlay;

        pub const zigar_js = .{
            .js_name = "Intersect",
            .is_handle = true,
            .is_class = false,
            .ref_field = "ref",
            .bases = bases_val,
            .fields = fields_val,
            .required_props = &req_props_fin,
            .is_callable_handle = any_callable,
            .has_iterator = any_iter,
            .has_async_iterator = any_async_iter,
            .has_dispose = any_disp,
            .has_async_dispose = any_async_disp,
        };

        pub fn zigNameForField(comptime field_name: []const u8) []const u8 {
            const pst = @typeInfo(PlainOverlay).@"struct";
            inline for (pst.field_names) |fname| {
                if (comptime isHiddenMetaField(fname)) continue;
                if (comptime std.mem.eql(u8, fname, field_name)) return fname;
                const wire = comptime topStructFieldWireName(PlainOverlay, fname);
                if (comptime std.mem.eql(u8, wire, field_name)) return fname;
            }
            @compileError("Field '" ++ field_name ++ "' is not a plain-struct property of " ++ @typeName(Self));
        }

        pub fn wireNameForField(comptime field_name: []const u8) []const u8 {
            const zname = comptime zigNameForField(field_name);
            return comptime topStructFieldWireName(PlainOverlay, zname);
        }

        pub fn FieldType(comptime field_name: []const u8) type {
            const zname = comptime zigNameForField(field_name);
            return @FieldType(PlainOverlay, zname);
        }

        pub fn deinit(self: Self) void {
            if (HostJsOpt != null) {
                self.ref.deinit();
            }
        }

        pub fn dispose(self: Self) void {
            if (HostJsOpt) |HJ| {
                HJ.dispose(self);
            }
        }

        pub fn tryDispose(self: Self) CallError!void {
            if (HostJsOpt) |HJ| {
                return HJ.tryDispose(self);
            }
            return error.HostUnavailable;
        }

        pub fn asyncDispose(self: Self) void {
            if (HostJsOpt) |HJ| {
                HJ.asyncDispose(self);
            }
        }

        pub fn tryAsyncDispose(self: Self) CallError!void {
            if (HostJsOpt) |HJ| {
                return HJ.tryAsyncDispose(self);
            }
            return error.HostUnavailable;
        }

        pub fn clone(self: Self) CallError!Self {
            if (HostJsOpt) |HJ| {
                return HJ.cloneHandle(Self, self);
            }
            return error.HostUnavailable;
        }

        pub fn toJsRef(self: Self) RefT {
            return .{ .handle = self.ref.handle };
        }

        pub const toRef = toJsRef;

        pub fn fromJsRef(raw: anytype) CallError!Self {
            if (HostJsOpt) |HJ| {
                return HJ.fromJsRef(Self, raw);
            }
            return error.HostUnavailable;
        }

        pub fn fromJsRefAlloc(allocator: std.mem.Allocator, raw: anytype) CallError!Self {
            if (HostJsOpt) |HJ| {
                return HJ.fromJsRefAlloc(Self, allocator, raw);
            }
            return error.HostUnavailable;
        }

        pub fn as(self: Self, comptime ArmT: type) ArmT {
            if (ArmT == Self) return self;
            if (comptime isGeneratedHandleStruct(ArmT)) {
                comptime {
                    if (!armIsReachableInHandleBases(Self, ArmT, 0)) {
                        @compileError(@typeName(Self) ++ " does not include handle arm " ++ @typeName(ArmT));
                    }
                }
                const rf = comptime generatedHandleRefFieldName(ArmT);
                var out_h: ArmT = undefined;
                @field(out_h, rf) = .{ .handle = self.ref.handle };
                return out_h;
            }
            if (comptime (@typeInfo(ArmT) == .@"struct" and @hasDecl(ArmT, "is_zig_callback") and ArmT.is_zig_callback)) {
                comptime {
                    if (!armIsReachableInHandleBases(Self, ArmT, 0)) {
                        @compileError(@typeName(Self) ++ " does not include callback arm " ++ @typeName(ArmT));
                    }
                }
                var out_cb: ArmT = .{};
                out_cb.func = .{ .handle = self.ref.handle };
                return out_cb;
            }
            if (comptime (@typeInfo(ArmT) == .@"struct" and @hasField(ArmT, "handle"))) {
                comptime {
                    const is_generic_ref = (ArmT == RefT or ArmT == Any or
                        (@hasDecl(ArmT, "Target") and (ArmT.Target == Any or ArmT.Target == Unknown or ArmT.Target == Object or (any_callable and ArmT.Target == Function))));
                    if (!is_generic_ref and !armIsReachableInHandleBases(Self, ArmT, 0)) {
                        @compileError(@typeName(Self) ++ " does not include JS handle arm " ++ @typeName(ArmT));
                    }
                }
                return .{ .handle = self.ref.handle };
            }
            @compileError("Plain-struct or value intersection arm " ++ @typeName(ArmT) ++ " must be decoded from JS via .project(" ++ @typeName(ArmT) ++ "), .projectAlloc(" ++ @typeName(ArmT) ++ ", allocator), or .get(\"field\")");
        }

        pub fn cloneAs(self: Self, comptime ArmT: type) CallError!ArmT {
            const cloned = try self.clone();
            return cloned.as(ArmT);
        }

        pub fn tryAs(self: Self, comptime Sub: type) CallError!?Sub {
            if (HostJsOpt) |HJ| {
                return HJ.downcastHandle(Sub, self.ref);
            }
            return error.HostUnavailable;
        }

        pub fn get(self: Self, comptime field_name: []const u8) CallError!FieldType(field_name) {
            const FT = FieldType(field_name);
            const wire = comptime wireNameForField(field_name);
            if (HostJsOpt) |HJ| {
                const raw = try HJ.getProp(CallError!HJ.Ref(Any), self.ref, wire);
                defer raw.deinit();
                return HJ.fromJsRef(FT, raw);
            }
            return error.HostUnavailable;
        }

        pub fn getAlloc(self: Self, allocator: std.mem.Allocator, comptime field_name: []const u8) CallError!FieldType(field_name) {
            const FT = FieldType(field_name);
            const wire = comptime wireNameForField(field_name);
            if (HostJsOpt) |HJ| {
                const raw = try HJ.getProp(CallError!HJ.Ref(Any), self.ref, wire);
                defer raw.deinit();
                return HJ.fromJsRefAlloc(FT, allocator, raw);
            }
            return error.HostUnavailable;
        }

        pub fn set(self: Self, comptime field_name: []const u8, value: FieldType(field_name)) CallError!void {
            const FT = FieldType(field_name);
            const zname = comptime zigNameForField(field_name);
            const wire = comptime wireNameForField(field_name);
            const spec = comptime transformOneFieldDescriptor(PlainOverlay, zname, .preserve).nullish;
            if (HostJsOpt) |HJ| {
                const encoded = try HJ.toJsRefWithSpec(FT, value, spec);
                defer encoded.deinit();
                try HJ.trySetProp(self.ref, wire, encoded);
                return;
            }
            return error.HostUnavailable;
        }

        pub fn project(self: Self, comptime ArmT: type) CallError!ArmT {
            comptime {
                if (ArmT != PlainOverlay and !armIsReachableInHandleBases(Self, ArmT, 0) and !satisfiesTypeConstraint(PlainOverlay, ArmT, 0)) {
                    @compileError(@typeName(ArmT) ++ " is not a plain-struct or value arm of " ++ @typeName(Self));
                }
            }
            if (HostJsOpt) |HJ| {
                return HJ.fromJsRef(ArmT, self.ref);
            }
            return error.HostUnavailable;
        }

        pub fn projectAlloc(self: Self, comptime ArmT: type, allocator: std.mem.Allocator) CallError!ArmT {
            comptime {
                if (ArmT != PlainOverlay and !armIsReachableInHandleBases(Self, ArmT, 0) and !satisfiesTypeConstraint(PlainOverlay, ArmT, 0)) {
                    @compileError(@typeName(ArmT) ++ " is not a plain-struct or value arm of " ++ @typeName(Self));
                }
            }
            if (HostJsOpt) |HJ| {
                return HJ.fromJsRefAlloc(ArmT, allocator, self.ref);
            }
            return error.HostUnavailable;
        }
    };
}

pub fn IntersectWithHost(comptime HostJsOpt: ?type, comptime parts: anytype) type {
    @setEvalBranchQuota(200_000);
    const PartsInfo = @typeInfo(@TypeOf(parts)).@"struct";
    if (PartsInfo.field_types.len == 0) return Object;

    inline for (0..PartsInfo.field_types.len) |pi| {
        const ArmT = parts[pi];
        if (ArmT == noreturn) return noreturn;
    }
    if (parts[0] == void) return void;

    comptime var raw_non_vacuous: usize = 0;
    comptime var any_non_nullable = false;
    inline for (0..PartsInfo.field_types.len) |pi| {
        const ArmT = parts[pi];
        if (pi > 0 and ArmT == void) continue;
        if (isUnconstrainedJsAnyOrUnknown(ArmT) or isJsObjectConstraintMarker(ArmT)) continue;
        raw_non_vacuous += 1;
        if (@typeInfo(ArmT) != .optional and !isModuleNullableType(ArmT)) {
            any_non_nullable = true;
        }
    }
    if (raw_non_vacuous == 0) return parts[0];

    comptime var unique_buf: [PartsInfo.field_types.len]type = undefined;
    comptime var unique_count: usize = 0;
    inline for (0..PartsInfo.field_types.len) |pi| {
        const OrigArm = parts[pi];
        if (pi > 0 and OrigArm == void) continue;
        if (isUnconstrainedJsAnyOrUnknown(OrigArm) or isJsObjectConstraintMarker(OrigArm)) continue;
        const ArmT = if (@typeInfo(OrigArm) == .optional or isModuleNullableType(OrigArm))
            NonNullable(OrigArm)
        else
            OrigArm;
        if (isUnconstrainedJsAnyOrUnknown(ArmT) or isJsObjectConstraintMarker(ArmT)) continue;
        var seen = false;
        for (unique_buf[0..unique_count]) |prev| {
            if (prev == ArmT) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            unique_buf[unique_count] = ArmT;
            unique_count += 1;
        }
    }
    if (unique_count == 0) return parts[0];
    if (unique_count == 1) {
        return if (!any_non_nullable) ?unique_buf[0] else unique_buf[0];
    }

    // Check scalar / primitive / sequence / enum arms (`string & Brand`, `number & Brand`, conflicting primitives).
    comptime var found_scalar_kind: IntersectScalarKind = .none;
    comptime var best_scalar_arm: ?type = null;
    comptime var best_scalar_spec: u8 = 0;
    inline for (unique_buf[0..unique_count]) |ArmT| {
        const sk = classifyIntersectScalarKind(ArmT);
        if (sk != .none) {
            if (found_scalar_kind == .none) {
                found_scalar_kind = sk;
            } else if (found_scalar_kind != sk and found_scalar_kind != .other_enum and sk != .other_enum) {
                return noreturn;
            }
            const spec = intersectScalarSpecificity(ArmT);
            if (best_scalar_arm == null or spec > best_scalar_spec) {
                best_scalar_arm = ArmT;
                best_scalar_spec = spec;
            }
        }
    }
    if (best_scalar_arm) |ScalarT| {
        return if (!any_non_nullable) ?ScalarT else ScalarT;
    }

    comptime var all_plain = true;
    inline for (unique_buf[0..unique_count]) |ArmT| {
        if (!isPlainValueStructForTransform(ArmT)) {
            all_plain = false;
        }
    }
    if (all_plain) {
        const MergedPlain = mergePlainValueStructArms(unique_buf[0..unique_count]);
        return if (!any_non_nullable) ?MergedPlain else MergedPlain;
    }

    // Mixed handle/JS-wrapper + plain-struct (or multi-handle) intersection:
    // collect all plain-struct overlays (including nested IntersectHandleWrapper.PlainFields)
    // and flatten bases so every arm remains accessible!
    comptime var plain_arms_buf: [unique_count]type = undefined;
    comptime var plain_arms_count: usize = 0;
    comptime var max_flat_bases: usize = unique_count;
    inline for (unique_buf[0..unique_count]) |ArmT| {
        if (@typeInfo(ArmT) == .@"struct" and @hasDecl(ArmT, "is_zigar_intersect_handle") and ArmT.is_zigar_intersect_handle) {
            max_flat_bases += ArmT.zigar_js.bases.len;
        }
    }
    comptime var flat_bases_buf: [max_flat_bases]type = undefined;
    comptime var flat_bases_count: usize = 0;

    inline for (unique_buf[0..unique_count]) |ArmT| {
        if (isPlainValueStructForTransform(ArmT)) {
            plain_arms_buf[plain_arms_count] = ArmT;
            plain_arms_count += 1;
        } else if (@typeInfo(ArmT) == .@"struct" and @hasDecl(ArmT, "is_zigar_intersect_handle") and ArmT.is_zigar_intersect_handle) {
            if (@typeInfo(ArmT.PlainFields).@"struct".field_names.len > 0) {
                plain_arms_buf[plain_arms_count] = ArmT.PlainFields;
                plain_arms_count += 1;
            }
        }

        var dup_base = false;
        for (flat_bases_buf[0..flat_bases_count]) |pb| {
            if (pb == ArmT) {
                dup_base = true;
                break;
            }
        }
        if (!dup_base) {
            flat_bases_buf[flat_bases_count] = ArmT;
            flat_bases_count += 1;
        }
        if (@typeInfo(ArmT) == .@"struct" and @hasDecl(ArmT, "is_zigar_intersect_handle") and ArmT.is_zigar_intersect_handle) {
            inline for (ArmT.zigar_js.bases) |NestedB| {
                var dup_nested = false;
                for (flat_bases_buf[0..flat_bases_count]) |pb| {
                    if (pb == NestedB) {
                        dup_nested = true;
                        break;
                    }
                }
                if (!dup_nested) {
                    flat_bases_buf[flat_bases_count] = NestedB;
                    flat_bases_count += 1;
                }
            }
        }
    }

    const PlainOverlay = mergePlainValueStructArms(plain_arms_buf[0..plain_arms_count]);
    const bases_fin: [flat_bases_count]type = flat_bases_buf[0..flat_bases_count].*;
    const Wrapper = IntersectHandleWrapper(HostJsOpt, flat_bases_count, bases_fin, PlainOverlay);
    return if (!any_non_nullable) ?Wrapper else Wrapper;
}

pub fn Intersect(comptime parts: anytype) type {
    return IntersectWithHost(null, parts);
}

pub fn EnumRecord(comptime K: type, comptime V: type) type {
    @setEvalBranchQuota(200_000);
    const en = @typeInfo(K).@"enum";
    const ValIsOptional = (@typeInfo(V) == .optional or isModuleNullableType(V));

    const MetaEntry = struct {
        name: []const u8,
        js_name: []const u8,
        is_optional: bool,
        nullish: NullishKind,
    };

    if (@hasDecl(K, "zigar_js") and @hasField(@TypeOf(K.zigar_js), "members")) {
        comptime var real_count: usize = 0;
        for (K.zigar_js.members) |m| {
            if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
            real_count += 1;
        }
        comptime var chosen_names: [real_count][]const u8 = undefined;
        comptime var chosen_wires: [real_count][]const u8 = undefined;
        comptime var any_renamed = false;
        comptime var pass_i: usize = 0;
        for (K.zigar_js.members) |m| {
            if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
            const wire = enumMemberWireKey(m);
            const fname = dedupeComptimeFieldName(comptimeSnakeFieldName(wire), chosen_names[0..pass_i]);
            chosen_names[pass_i] = fname;
            chosen_wires[pass_i] = wire;
            if (!std.mem.eql(u8, wire, fname)) {
                any_renamed = true;
            }
            pass_i += 1;
        }
        const need_meta = any_renamed or ValIsOptional;
        const total_count = real_count + @intFromBool(need_meta);
        comptime var fnames: [total_count][]const u8 = undefined;
        comptime var ftypes: [total_count]type = undefined;
        comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;

        comptime var meta_entries: [real_count]MetaEntry = undefined;
        for (0..real_count) |out_i| {
            const fname = chosen_names[out_i];
            const wire = chosen_wires[out_i];
            fnames[out_i] = fname;
            ftypes[out_i] = V;
            fattrs[out_i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(V),
            };
            meta_entries[out_i] = .{
                .name = fname,
                .js_name = wire,
                .is_optional = false,
                .nullish = if (ValIsOptional) NullishKind.null_only else NullishKind.none,
            };
        }
        if (need_meta) {
            const entries_fin = meta_entries;
            const Carrier = struct {
                pub const zigar_js = .{
                    .fields = entries_fin,
                };
            };
            fnames[real_count] = hidden_meta_field_name;
            ftypes[real_count] = Carrier;
            fattrs[real_count] = .{
                .default_value_ptr = defaultPtrForValue(Carrier, .{}),
                .@"comptime" = false,
                .@"align" = @alignOf(Carrier),
            };
        }
        const names_fin = fnames;
        const types_fin = ftypes;
        const attrs_fin = fattrs;
        return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
    }

    const real_count = en.field_names.len;
    const need_meta = ValIsOptional;
    const total_count = real_count + @intFromBool(need_meta);
    comptime var fnames: [total_count][]const u8 = undefined;
    comptime var ftypes: [total_count]type = undefined;
    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
    comptime var meta_entries: [real_count]MetaEntry = undefined;
    for (en.field_names, 0..) |fname, i| {
        fnames[i] = fname;
        ftypes[i] = V;
        fattrs[i] = .{
            .default_value_ptr = null,
            .@"comptime" = false,
            .@"align" = @alignOf(V),
        };
        meta_entries[i] = .{
            .name = fname,
            .js_name = fname,
            .is_optional = false,
            .nullish = if (ValIsOptional) NullishKind.null_only else NullishKind.none,
        };
    }
    if (need_meta) {
        const entries_fin = meta_entries;
        const Carrier = struct {
            pub const zigar_js = .{
                .fields = entries_fin,
            };
        };
        fnames[real_count] = hidden_meta_field_name;
        ftypes[real_count] = Carrier;
        fattrs[real_count] = .{
            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
            .@"comptime" = false,
            .@"align" = @alignOf(Carrier),
        };
    }
    const names_fin = fnames;
    const types_fin = ftypes;
    const attrs_fin = fattrs;
    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
}

pub fn MappedValuesSpecWithFallback(
    comptime FallbackRecordFn: fn (comptime type, comptime type) type,
    comptime T: type,
    comptime V: type,
    comptime v_spec: anytype,
) type {
    @setEvalBranchQuota(200_000);
    switch (@typeInfo(T)) {
        .pointer => |pt| {
            if (pt.size == .slice) {
                if (pt.child == u8) return T;
                return if (pt.attrs.@"const") []const V else []V;
            }
            return FallbackRecordFn(KeyOf(T), V);
        },
        .array => |ar| return [ar.len]V,
        .int, .float, .bool, .void => return T,
        .@"struct" => |st| {
            if (st.is_tuple) return [st.field_types.len]V;
            if (@hasDecl(T, "is_js_array") and T.is_js_array) return []const V;
            if (@hasDecl(T, "is_js_bigint") and T.is_js_bigint) return T;
            if (@hasDecl(T, "zigar_js_tuple")) {
                const has_var = @hasField(@TypeOf(T.zigar_js_tuple), "variadic_index") and T.zigar_js_tuple.variadic_index != null;
                const has_opt = blk: {
                    for (st.field_attrs) |fa| {
                        if (fa.default_value_ptr != null) break :blk true;
                    }
                    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "fields")) {
                        inline for (T.zigar_js.fields) |fm| {
                            if (@hasField(@TypeOf(fm), "is_optional") and fm.is_optional) break :blk true;
                        }
                    }
                    break :blk false;
                };
                if (has_var or has_opt) return []const V;
                return [st.field_types.len]V;
            }
            if (isPlainValueStructForTransform(T)) {
                comptime var real_count: usize = 0;
                for (st.field_names) |fname| {
                    if (!isHiddenMetaField(fname)) real_count += 1;
                }
                if (real_count == 0) return struct {};

                const req_spec = comptime blk: {
                    const VSpecT = @TypeOf(v_spec);
                    if (@typeInfo(VSpecT) == .enum_literal) {
                        if (v_spec == .auto) {
                            break :blk if (isModuleNullableType(V))
                                NullishKind.null_or_undefined
                            else if (@typeInfo(V) == .optional)
                                NullishKind.null_only
                            else
                                NullishKind.none;
                        }
                        break :blk @as(NullishKind, v_spec);
                    }
                    break :blk v_spec;
                };
                const opt_spec = comptime blk: {
                    if (@typeInfo(V) == .optional or isModuleNullableType(V)) {
                        const cur_self = specTopSelfNullish(req_spec);
                        const merged_self: NullishKind = if (isModuleNullableType(V) or cur_self == .null_only or cur_self == .null_or_undefined)
                            .null_or_undefined
                        else
                            .undefined_only;
                        break :blk rebuildSpecWithSelf(req_spec, merged_self);
                    }
                    break :blk wrapSpecAsOptional(req_spec, .undefined_only);
                };

                const ReqEntryT = struct {
                    name: []const u8,
                    js_name: []const u8,
                    is_optional: bool,
                    nullish: @TypeOf(req_spec),
                };
                const OptEntryT = struct {
                    name: []const u8,
                    js_name: []const u8,
                    is_optional: bool,
                    nullish: @TypeOf(opt_spec),
                };

                comptime var any_opt = false;
                inline for (st.field_names, 0..) |fname, fi| {
                    if (comptime isHiddenMetaField(fname)) continue;
                    if (comptime topStructFieldIsOptional(T, fname, st.field_attrs[fi].default_value_ptr != null)) {
                        any_opt = true;
                    }
                }

                const req_needs_meta = (@TypeOf(req_spec) != NullishKind) or (req_spec != NullishKind.none);
                const need_meta = hasStructZigarJsMeta(T) or any_opt or req_needs_meta;
                const total_count = real_count + @intFromBool(need_meta);

                comptime var fnames: [total_count][]const u8 = undefined;
                comptime var ftypes: [total_count]type = undefined;
                comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
                comptime var entry_types: [real_count]type = undefined;

                comptime var out_i: usize = 0;
                inline for (st.field_names, 0..) |fname, fi| {
                    if (comptime isHiddenMetaField(fname)) continue;
                    const src_is_opt = comptime topStructFieldIsOptional(T, fname, st.field_attrs[fi].default_value_ptr != null);
                    if (src_is_opt) {
                        const NewFT = if (@typeInfo(V) == .optional or isModuleNullableType(V)) V else ?V;
                        const def_ptr: *const anyopaque = if (isModuleNullableType(NewFT))
                            defaultPtrForValue(NewFT, .@"undefined")
                        else
                            defaultPtrForValue(NewFT, null);
                        fnames[out_i] = fname;
                        ftypes[out_i] = NewFT;
                        fattrs[out_i] = .{
                            .default_value_ptr = def_ptr,
                            .@"comptime" = false,
                            .@"align" = @alignOf(NewFT),
                        };
                        entry_types[out_i] = OptEntryT;
                    } else {
                        fnames[out_i] = fname;
                        ftypes[out_i] = V;
                        fattrs[out_i] = .{
                            .default_value_ptr = null,
                            .@"comptime" = false,
                            .@"align" = @alignOf(V),
                        };
                        entry_types[out_i] = ReqEntryT;
                    }
                    out_i += 1;
                }

                if (need_meta) {
                    const FieldsTuple = @Tuple(&entry_types);
                    const fields_val = comptime blk: {
                        var tup: FieldsTuple = undefined;
                        var ti: usize = 0;
                        for (st.field_names, 0..) |fname, fi| {
                            if (isHiddenMetaField(fname)) continue;
                            const wire = topStructFieldWireName(T, fname);
                            const src_is_opt = topStructFieldIsOptional(T, fname, st.field_attrs[fi].default_value_ptr != null);
                            if (src_is_opt) {
                                tup[ti] = OptEntryT{
                                    .name = fname,
                                    .js_name = wire,
                                    .is_optional = true,
                                    .nullish = opt_spec,
                                };
                            } else {
                                tup[ti] = ReqEntryT{
                                    .name = fname,
                                    .js_name = wire,
                                    .is_optional = false,
                                    .nullish = req_spec,
                                };
                            }
                            ti += 1;
                        }
                        break :blk tup;
                    };
                    const Carrier = struct {
                        pub const zigar_js = .{
                            .fields = fields_val,
                        };
                    };
                    fnames[real_count] = hidden_meta_field_name;
                    ftypes[real_count] = Carrier;
                    fattrs[real_count] = .{
                        .default_value_ptr = defaultPtrForValue(Carrier, .{}),
                        .@"comptime" = false,
                        .@"align" = @alignOf(Carrier),
                    };
                }

                const names_fin = fnames;
                const types_fin = ftypes;
                const attrs_fin = fattrs;
                return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
            }
            return FallbackRecordFn(KeyOf(T), V);
        },
        else => return FallbackRecordFn(KeyOf(T), V),
    }
}

pub fn NonNullable(comptime T: type) type {
    if (@typeInfo(T) == .optional) return NonNullable(@typeInfo(T).optional.child);
    if (isModuleNullableType(T)) return NonNullable(T.Value);
    return T;
}

pub fn Awaited(comptime T: type) type {
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        const Aw = Awaited(Child);
        return if (Aw == Child) T else ?Aw;
    }
    if (isModuleNullableType(T)) {
        const Aw = Awaited(T.Value);
        return if (Aw == T.Value) T else Nullable(Aw);
    }
    if (@typeInfo(T) == .@"struct") {
        if (@hasDecl(T, "is_js_promise") and T.is_js_promise and @hasDecl(T, "Payload")) {
            return Awaited(T.Payload);
        }
        if (@hasDecl(T, "Target") and @TypeOf(T.Target) == type and @typeInfo(T.Target) == .@"struct") {
            if (@hasDecl(T.Target, "is_js_promise") and T.Target.is_js_promise and @hasDecl(T.Target, "Payload")) {
                return Awaited(T.Target.Payload);
            }
        }
    }
    if (@typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type != null and !isModuleNullableType(T)) {
        const un = @typeInfo(T).@"union";
        comptime var any_changed = false;
        comptime var distinct: [un.field_types.len]type = undefined;
        comptime var d_len: usize = 0;
        for (un.field_types) |ft| {
            const aw = Awaited(ft);
            if (aw != ft) any_changed = true;
            var seen = false;
            for (distinct[0..d_len]) | prev | {
                if (prev == aw) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                distinct[d_len] = aw;
                d_len += 1;
            }
        }
        if (any_changed) {
            if (d_len == 1) return distinct[0];
            return buildSynthesizedUnion(distinct[0..d_len]);
        }
    }
    return T;
}

fn buildSynthesizedUnion(comptime member_types: []const type) type {
    const count = member_types.len;
    if (count == 0) return noreturn;
    if (count == 1) return member_types[0];
    const TagInt = std.math.IntFittingRange(0, count - 1);
    comptime var fnames: [count][]const u8 = undefined;
    comptime var ftypes: [count]type = undefined;
    comptime var fattrs: [count]std.builtin.Type.Union.FieldAttributes = undefined;
    comptime var tag_vals: [count]TagInt = undefined;
    for (member_types, 0..) |mt, i| {
        fnames[i] = std.fmt.comptimePrint("v{d}", .{i});
        ftypes[i] = mt;
        fattrs[i] = .{};
        tag_vals[i] = i;
    }
    const names_fin = fnames;
    const types_fin = ftypes;
    const attrs_fin = fattrs;
    const vals_fin = tag_vals;
    const Tag = @Enum(TagInt, .exhaustive, &names_fin, &vals_fin);
    return @Union(.auto, Tag, &names_fin, &types_fin, &attrs_fin);
}

pub fn KeyOf(comptime T: type) type {
    @setEvalBranchQuota(200_000);
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            if (isPlainValueStructForTransform(T)) {
                comptime var max_count: usize = 0;
                for (st.field_names) |fname| {
                    if (!isHiddenMetaField(fname)) max_count += 1;
                }
                if (max_count == 0) return noreturn;
                comptime var names_buf: [max_count][]const u8 = undefined;
                comptime var count: usize = 0;
                for (st.field_names) |fname| {
                    if (isHiddenMetaField(fname)) continue;
                    const w = topStructFieldWireName(T, fname);
                    var dup = false;
                    for (names_buf[0..count]) |prev| {
                        if (std.mem.eql(u8, prev, w)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        names_buf[count] = w;
                        count += 1;
                    }
                }
                if (count == 0) return noreturn;
                const TagInt = std.math.IntFittingRange(0, count - 1);
                comptime var vals: [count]TagInt = undefined;
                for (0..count) |i| vals[i] = i;
                const names_fin = names_buf[0..count].*;
                const vals_fin = vals;
                return @Enum(TagInt, .exhaustive, &names_fin, &vals_fin);
            }
            if (isGeneratedHandleStruct(T) and (@hasField(@TypeOf(T.zigar_js), "fields") or @hasField(@TypeOf(T.zigar_js), "bases"))) {
                const fmeta = if (@hasField(@TypeOf(T.zigar_js), "fields")) T.zigar_js.fields else .{};
                const mmeta = if (@hasField(@TypeOf(T.zigar_js), "methods")) T.zigar_js.methods else .{};
                const bmeta = if (@hasField(@TypeOf(T.zigar_js), "bases")) T.zigar_js.bases else .{};
                const base_extra = comptime blk: {
                    var be: usize = 0;
                    for (bmeta) |BaseT| {
                        if (@TypeOf(BaseT) == type and BaseT != T) {
                            const BK = KeyOf(BaseT);
                            if (@typeInfo(BK) == .@"enum") {
                                be += @typeInfo(BK).@"enum".field_names.len;
                            }
                        }
                    }
                    break :blk be;
                };
                const max_len = fmeta.len + mmeta.len + base_extra;
                if (max_len == 0) return []const u8;
                comptime var names_buf: [max_len][]const u8 = undefined;
                comptime var count: usize = 0;
                for (fmeta) |fm| {
                    const w = if (@hasField(@TypeOf(fm), "js_name")) fm.js_name else fm.name;
                    var dup = false;
                    for (names_buf[0..count]) |prev| {
                        if (std.mem.eql(u8, prev, w)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        names_buf[count] = w;
                        count += 1;
                    }
                }
                for (mmeta) |mm| {
                    if (@hasField(@TypeOf(mm), "is_static") and mm.is_static) continue;
                    const w = if (@hasField(@TypeOf(mm), "js_name")) mm.js_name else mm.name;
                    var dup = false;
                    for (names_buf[0..count]) |prev| {
                        if (std.mem.eql(u8, prev, w)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        names_buf[count] = w;
                        count += 1;
                    }
                }
                for (bmeta) |BaseT| {
                    if (@TypeOf(BaseT) == type and BaseT != T) {
                        const BK = KeyOf(BaseT);
                        if (@typeInfo(BK) == .@"enum") {
                            for (@typeInfo(BK).@"enum".field_names) |bw| {
                                var dup = false;
                                for (names_buf[0..count]) |prev| {
                                    if (std.mem.eql(u8, prev, bw)) {
                                        dup = true;
                                        break;
                                    }
                                }
                                if (!dup) {
                                    names_buf[count] = bw;
                                    count += 1;
                                }
                            }
                        }
                    }
                }
                if (count == 0) return []const u8;
                const TagInt = std.math.IntFittingRange(0, count - 1);
                comptime var vals: [count]TagInt = undefined;
                for (0..count) |i| vals[i] = i;
                const names_fin = names_buf[0..count].*;
                const vals_fin = vals;
                return @Enum(TagInt, .exhaustive, &names_fin, &vals_fin);
            }
            if (@hasDecl(T, "is_js_record") and T.is_js_record and @hasDecl(T, "Key")) {
                return T.Key;
            }
            return []const u8;
        },
        .pointer => |pt| {
            if (pt.size == .slice) return f64;
            return []const u8;
        },
        else => return []const u8,
    }
}

fn isNumericIndexKeySpec(comptime keys_spec: anytype) ?usize {
    const SpecT = @TypeOf(keys_spec);
    if (SpecT == comptime_int or @typeInfo(SpecT) == .int) {
        if (keys_spec < 0) @compileError("Negative tuple/array index in IndexAccess");
        return @intCast(keys_spec);
    }
    return null;
}

fn isBroadNumericIndexType(comptime keys_spec: anytype) bool {
    if (@TypeOf(keys_spec) != type) return false;
    return switch (@typeInfo(keys_spec)) {
        .int, .float => true,
        else => false,
    };
}

pub fn IndexAccessWithFallback(comptime FallbackValue: type, comptime T: type, comptime keys_spec: anytype) type {
    @setEvalBranchQuota(200_000);
    switch (@typeInfo(T)) {
        .pointer => |pt| {
            if (pt.size == .slice) {
                if (isNumericIndexKeySpec(keys_spec) != null or isBroadNumericIndexType(keys_spec)) {
                    return pt.child;
                }
            }
        },
        .array => |ar| {
            if (isNumericIndexKeySpec(keys_spec) != null or isBroadNumericIndexType(keys_spec)) {
                return ar.child;
            }
        },
        .@"struct" => |st| {
            if (@hasDecl(T, "is_js_record") and T.is_js_record and @hasDecl(T, "Value")) {
                return T.Value;
            }
            if (@hasDecl(T, "is_js_array") and T.is_js_array and (@hasDecl(T, "Elem") or @hasDecl(T, "Element"))) {
                if (isNumericIndexKeySpec(keys_spec) != null or isBroadNumericIndexType(keys_spec)) {
                    return if (@hasDecl(T, "Elem")) T.Elem else T.Element;
                }
            }
            if (st.is_tuple or @hasDecl(T, "zigar_js_tuple")) {
                if (isNumericIndexKeySpec(keys_spec)) |idx| {
                    if (idx < st.field_types.len) return st.field_types[idx];
                    @compileError("Tuple index out of bounds in IndexAccess");
                }
                if (isBroadNumericIndexType(keys_spec)) {
                    comptime var distinct: [st.field_types.len]type = undefined;
                    comptime var d_len: usize = 0;
                    for (st.field_types, 0..) |ft, fi| {
                        const elem_t = if (@hasDecl(T, "zigar_js_tuple") and @hasField(@TypeOf(T.zigar_js_tuple), "variadic_index") and T.zigar_js_tuple.variadic_index != null and T.zigar_js_tuple.variadic_index.? == fi and @typeInfo(ft) == .pointer and @typeInfo(ft).pointer.size == .slice)
                            @typeInfo(ft).pointer.child
                        else
                            ft;
                        var seen = false;
                        for (distinct[0..d_len]) |prev| {
                            if (prev == elem_t) {
                                seen = true;
                                break;
                            }
                        }
                        if (!seen) {
                            distinct[d_len] = elem_t;
                            d_len += 1;
                        }
                    }
                    return buildSynthesizedUnion(distinct[0..d_len]);
                }
            }
            if (isPlainValueStructForTransform(T)) {
                if (@TypeOf(keys_spec) == type and keys_spec == []const u8) {
                    return FallbackValue;
                }
                if (isBroadNumericIndexType(keys_spec)) {
                    comptime var distinct_num: [st.field_types.len]type = undefined;
                    comptime var dn_len: usize = 0;
                    for (st.field_names, 0..) |fname, fi| {
                        if (isHiddenMetaField(fname)) continue;
                        if (!isNumericPropertyKeyString(topStructFieldWireName(T, fname))) continue;
                        const ft = st.field_types[fi];
                        var seen = false;
                        for (distinct_num[0..dn_len]) |prev| {
                            if (prev == ft) {
                                seen = true;
                                break;
                            }
                        }
                        if (!seen) {
                            distinct_num[dn_len] = ft;
                            dn_len += 1;
                        }
                    }
                    if (dn_len > 0) return buildSynthesizedUnion(distinct_num[0..dn_len]);
                    return FallbackValue;
                }
                const keys = comptime extractKeyListFromSpec(keys_spec);
                if (keys.len == 0) return noreturn;
                comptime var distinct: [st.field_types.len]type = undefined;
                comptime var d_len: usize = 0;
                for (st.field_names, 0..) |fname, fi| {
                    if (isHiddenMetaField(fname)) continue;
                    if (!fieldMatchesAnyKey(T, fname, keys)) continue;
                    const ft = st.field_types[fi];
                    var seen = false;
                    for (distinct[0..d_len]) |prev| {
                        if (prev == ft) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) {
                        distinct[d_len] = ft;
                        d_len += 1;
                    }
                }
                    if (d_len > 0) return buildSynthesizedUnion(distinct[0..d_len]);
                return FallbackValue;
            }
            if (@hasDecl(T, "is_zigar_intersect_handle") and T.is_zigar_intersect_handle) {
                const Sentinel = opaque {};
                const PlainRes = IndexAccessWithFallback(Sentinel, T.PlainFields, keys_spec);
                if (PlainRes != Sentinel) return PlainRes;
                inline for (T.zigar_js.bases) |BaseT| {
                    if (BaseT != T and !isPlainValueStructForTransform(BaseT)) {
                        const BaseRes = IndexAccessWithFallback(Sentinel, BaseT, keys_spec);
                        if (BaseRes != Sentinel) return BaseRes;
                    }
                }
                return FallbackValue;
            }
        },
        else => {},
    }
    return FallbackValue;
}

pub fn IndexAccess(comptime T: type, comptime keys_spec: anytype) type {
    return IndexAccessWithFallback(Any, T, keys_spec);
}

/// Normalizes a caller value argument type `Arg` (`@TypeOf(arg)`) into a runtime-representable
/// Zig parameter type for generic `<fn>Infer` deduction (`"hi"` -> `[]const u8`, `42` -> `f64`,
/// `&[_]T{...}` -> `[]const T`).
pub fn InferJsTypeWithFallback(comptime FallbackValue: type, comptime Arg: type) type {
    if (Arg == comptime_int or Arg == comptime_float) return f64;
    if (Arg == @TypeOf(null) or Arg == @TypeOf(undefined)) return FallbackValue;
    return switch (@typeInfo(Arg)) {
        .enum_literal => @compileError("zigar.js: pass a concrete enum value or string slice instead of an untyped enum literal"),
        .pointer => |pt| blk: {
            if (pt.size == .one and @typeInfo(pt.child) == .array) {
                const elem = @typeInfo(pt.child).array.child;
                if (elem == comptime_int or elem == comptime_float) break :blk []const f64;
                break :blk []const elem;
            }
            break :blk Arg;
        },
        else => Arg,
    };
}

pub fn InferJsType(comptime Arg: type) type {
    return InferJsTypeWithFallback(Any, Arg);
}

/// Normalizes a caller value argument type `Arg` (`@TypeOf(arg)`) into a runtime-representable
/// Zig parameter type for `const T` TypeScript 5.0 type parameters, preserving fixed-length
/// non-string tuple arrays (`&[_]f64{ 1, 2 }` -> `[2]f64`) while normalizing string literals
/// (`"hi"` -> `[]const u8`) and comptime scalars (`42` -> `f64`).
pub fn InferConstJsTypeWithFallback(comptime FallbackValue: type, comptime Arg: type) type {
    if (Arg == comptime_int or Arg == comptime_float) return f64;
    if (Arg == @TypeOf(null) or Arg == @TypeOf(undefined)) return FallbackValue;
    return switch (@typeInfo(Arg)) {
        .enum_literal => @compileError("zigar.js: pass a concrete enum value or string slice instead of an untyped enum literal"),
        .pointer => |pt| blk: {
            if (pt.size == .one and @typeInfo(pt.child) == .array) {
                const ar = @typeInfo(pt.child).array;
                if (ar.child == u8 and ar.sentinel() != null) break :blk []const u8;
                const elem = if (ar.child == comptime_int or ar.child == comptime_float) f64 else ar.child;
                break :blk [ar.len]elem;
            }
            break :blk Arg;
        },
        .array => |ar| blk: {
            const elem = if (ar.child == comptime_int or ar.child == comptime_float) f64 else ar.child;
            break :blk [ar.len]elem;
        },
        else => Arg,
    };
}

pub fn InferConstJsType(comptime Arg: type) type {
    return InferConstJsTypeWithFallback(Any, Arg);
}

/// Returns true when `Arg` is `*const [N]Elem` for a non-sentinel-`u8` array so `const T`
/// inference companions can dereference `&[_]Elem{ ... }` into `[N]Elem`.
pub fn isConstArrayPtr(comptime Arg: type) bool {
    return switch (@typeInfo(Arg)) {
        .pointer => |pt| blk: {
            if (pt.size == .one and @typeInfo(pt.child) == .array) {
                const ar = @typeInfo(pt.child).array;
                if (ar.child == u8 and ar.sentinel() != null) break :blk false;
                break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Deduces `T` from a slice, array, or pointer-to-array argument passed for `[]const T`.
pub fn InferSliceElem(comptime S: type) type {
    return switch (@typeInfo(S)) {
        .pointer => |pt| blk: {
            if (pt.size == .slice) {
                if (pt.child == comptime_int or pt.child == comptime_float) break :blk f64;
                break :blk pt.child;
            }
            if (pt.size == .one and @typeInfo(pt.child) == .array) {
                const elem = @typeInfo(pt.child).array.child;
                if (elem == comptime_int or elem == comptime_float) break :blk f64;
                break :blk elem;
            }
            @compileError("zigar.js: expected slice or array pointer argument for generic element inference, got " ++ @typeName(S));
        },
        .array => |ar| if (ar.child == comptime_int or ar.child == comptime_float) f64 else ar.child,
        else => @compileError("zigar.js: expected slice or array argument for generic element inference, got " ++ @typeName(S)),
    };
}

fn structProtocolElemForInfer(comptime T: type, comptime depth: usize) ?type {
    if (depth >= 16 or @typeInfo(T) != .@"struct") return null;
    if (@hasDecl(T, "zigar_js") and @TypeOf(T.zigar_js) != type) {
        const MetaT = @TypeOf(T.zigar_js);
        if (@hasField(MetaT, "iterator_elem")) return T.zigar_js.iterator_elem;
        if (@hasField(MetaT, "async_iterator_elem")) return T.zigar_js.async_iterator_elem;
        if (@hasField(MetaT, "set_elem")) return T.zigar_js.set_elem;
        if (@hasField(MetaT, "bases")) {
            inline for (T.zigar_js.bases) |BaseT| {
                if (structProtocolElemForInfer(BaseT, depth + 1)) |et| return et;
            }
        }
    }
    return null;
}

/// Deduces `T` from an iterator, async iterator, iterable handle, Set, Array, or slice argument.
pub fn InferIteratorElem(comptime IterT: type) type {
    return switch (@typeInfo(IterT)) {
        .pointer => InferSliceElem(IterT),
        .array => InferSliceElem(IterT),
        .@"struct" => blk: {
            if ((@hasDecl(IterT, "is_js_iterator") and IterT.is_js_iterator) or
                (@hasDecl(IterT, "is_js_async_iterator") and IterT.is_js_async_iterator) or
                (@hasDecl(IterT, "is_js_array") and IterT.is_js_array) or
                (@hasDecl(IterT, "is_js_set") and IterT.is_js_set))
            {
                break :blk if (@hasDecl(IterT, "Elem")) IterT.Elem else IterT.Element;
            }
            if (structProtocolElemForInfer(IterT, 0)) |et| break :blk et;
            @compileError("zigar.js: expected Iterator, AsyncIterator, Iterable, or slice argument for generic element inference, got " ++ @typeName(IterT));
        },
        else => @compileError("zigar.js: expected Iterator, AsyncIterator, Iterable, or slice argument for generic element inference, got " ++ @typeName(IterT)),
    };
}

/// Deduces `T` from a nullable/non-nullable argument passed for `?T`.
pub fn InferOptionalChildWithFallback(comptime FallbackValue: type, comptime Opt: type) type {
    if (Opt == @TypeOf(null) or Opt == @TypeOf(undefined)) return FallbackValue;
    return switch (@typeInfo(Opt)) {
        .optional => |op| InferJsTypeWithFallback(FallbackValue, op.child),
        else => InferJsTypeWithFallback(FallbackValue, Opt),
    };
}

pub fn InferOptionalChild(comptime Opt: type) type {
    return InferOptionalChildWithFallback(Any, Opt);
}

fn isRefToTarget(comptime T: type, comptime TargetMarker: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Target") and @TypeOf(T.Target) == type and T.Target == TargetMarker;
}

fn isUnconstrainedJsAnyOrUnknown(comptime T: type) bool {
    if (T == Any or T == Unknown) return true;
    if (isRefToTarget(T, Any) or isRefToTarget(T, Unknown)) return true;
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_any_or_unknown") and T.is_js_any_or_unknown) return true;
    return false;
}

fn isJsObjectConstraintMarker(comptime T: type) bool {
    if (T == Object or isRefToTarget(T, Object)) return true;
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_object") and T.is_js_object;
}

fn isJsFunctionConstraintMarker(comptime T: type) bool {
    if (T == Function or isRefToTarget(T, Function)) return true;
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_function") and T.is_js_function;
}

fn isJsSymbolConstraintMarker(comptime T: type) bool {
    if (T == Symbol or isRefToTarget(T, Symbol)) return true;
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_symbol") and T.is_js_symbol;
}

fn isStringLikeConstraintCandidate(comptime T: type) bool {
    if (T == []const u8 or T == []u8 or T == [:0]const u8 or T == [:0]u8) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pt| (pt.size == .slice and pt.child == u8) or
            (pt.size == .one and @typeInfo(pt.child) == .array and @typeInfo(pt.child).array.child == u8),
        .@"enum" => @hasDecl(T, "toSlice"),
        .@"struct" => isTemplateLiteralStruct(T) or (@hasDecl(T, "is_js_string") and T.is_js_string),
        .@"union" => @hasDecl(T, "zigar_js") and
            @hasField(@TypeOf(T.zigar_js), "is_open_literal") and
            T.zigar_js.is_open_literal and
            @hasDecl(T, "fromSlice"),
        else => false,
    };
}

fn isNumberLikeConstraintCandidate(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .comptime_float, .int, .comptime_int => true,
        .@"enum" => !@hasDecl(T, "toSlice"),
        .@"union" => @hasDecl(T, "zigar_js") and
            @hasField(@TypeOf(T.zigar_js), "is_open_literal") and
            T.zigar_js.is_open_literal and
            !@hasDecl(T, "fromSlice"),
        else => false,
    };
}

fn isFunctionLikeConstraintCandidate(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"fn" => true,
        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .@"fn",
        .@"struct" => isCallbackWrapper(T) or
            isJsFunctionConstraintMarker(T) or
            (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_callable_handle") and T.zigar_js.is_callable_handle),
        else => false,
    };
}

fn structDerivesFrom(comptime T: type, comptime Base: type, comptime depth: usize) bool {
    if (T == Base) return true;
    if (depth > 8) return false;
    if (@typeInfo(T) != .@"struct") return false;
    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "bases"))) {
        const bases = T.zigar_js.bases;
        inline for (@typeInfo(@TypeOf(bases)).@"struct".field_names) |bf_name| {
            const B = @field(bases, bf_name);
            if (comptime (@TypeOf(B) == type)) {
                if (B == Base or structDerivesFrom(B, Base, depth + 1)) return true;
            }
        }
    }
    return false;
}

fn structProvidesMember(comptime T: type, comptime wire_or_zig: []const u8) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasField(T, wire_or_zig) or @hasDecl(T, wire_or_zig)) return true;
    if (comptime hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (comptime @hasField(@TypeOf(meta), "fields")) {
            inline for (@typeInfo(@TypeOf(meta.fields)).@"struct".field_names) |mf_name| {
                const entry = @field(meta.fields, mf_name);
                if (comptime @hasField(@TypeOf(entry), "js_name")) {
                    if (std.mem.eql(u8, entry.js_name, wire_or_zig)) return true;
                }
                if (comptime @hasField(@TypeOf(entry), "name")) {
                    if (std.mem.eql(u8, entry.name, wire_or_zig)) return true;
                }
            }
        }
        if (comptime @hasField(@TypeOf(meta), "methods")) {
            inline for (@typeInfo(@TypeOf(meta.methods)).@"struct".field_names) |mf_name| {
                const entry = @field(meta.methods, mf_name);
                if (comptime @hasField(@TypeOf(entry), "js_name")) {
                    if (std.mem.eql(u8, entry.js_name, wire_or_zig)) return true;
                }
                if (comptime @hasField(@TypeOf(entry), "name")) {
                    if (std.mem.eql(u8, entry.name, wire_or_zig)) return true;
                }
            }
        }
        if (comptime @hasField(@TypeOf(meta), "bases")) {
            inline for (@typeInfo(@TypeOf(meta.bases)).@"struct".field_names) |bf_name| {
                const B = @field(meta.bases, bf_name);
                if (comptime (@TypeOf(B) == type)) {
                    if (structProvidesMember(B, wire_or_zig)) return true;
                }
            }
        }
    }
    return false;
}

fn lookupStructFieldType(comptime T: type, comptime zig_name: []const u8, comptime wire_name: []const u8) ?type {
    if (@typeInfo(T) != .@"struct") return null;
    if (@hasDecl(T, "is_zigar_intersect_handle") and T.is_zigar_intersect_handle) {
        return lookupStructFieldType(T.PlainFields, zig_name, wire_name);
    }
    if (@hasField(T, zig_name)) return @FieldType(T, zig_name);
    if (!std.mem.eql(u8, wire_name, zig_name) and @hasField(T, wire_name)) return @FieldType(T, wire_name);
    if (comptime hasStructZigarJsMeta(T)) {
        const meta = getStructZigarJsMeta(T);
        if (comptime @hasField(@TypeOf(meta), "fields")) {
            inline for (@typeInfo(@TypeOf(meta.fields)).@"struct".field_names) |mf_name| {
                const entry = @field(meta.fields, mf_name);
                if (comptime (@hasField(@TypeOf(entry), "js_name") and @hasField(@TypeOf(entry), "name"))) {
                    if (comptime (std.mem.eql(u8, entry.js_name, wire_name) and @hasField(T, entry.name))) {
                        return @FieldType(T, entry.name);
                    }
                }
            }
        }
    }
    return null;
}

fn enumMemberWireName(comptime EnumT: type, comptime field_name: []const u8) []const u8 {
    if (comptime (@hasDecl(EnumT, "zigar_js") and @hasField(@TypeOf(EnumT.zigar_js), "members"))) {
        const members = EnumT.zigar_js.members;
        inline for (@typeInfo(@TypeOf(members)).@"struct".field_names) |mf_name| {
            const entry = @field(members, mf_name);
            if (comptime @hasField(@TypeOf(entry), "tag")) {
                if (std.mem.eql(u8, entry.tag, field_name)) {
                    if (comptime @hasField(@TypeOf(entry), "str_value")) return entry.str_value;
                    if (comptime @hasField(@TypeOf(entry), "js_name")) return entry.js_name;
                }
            }
        }
    }
    return field_name;
}

fn unitLiteralSatisfiesConstraint(comptime vd: anytype, comptime Constraint: type, comptime depth: usize) bool {
    if (depth > 8) return true;
    const VD = @TypeOf(vd);
    if (@typeInfo(Constraint) == .optional) {
        return unitLiteralSatisfiesConstraint(vd, @typeInfo(Constraint).optional.child, depth + 1);
    }
    if (@typeInfo(Constraint) == .@"union") {
        if (comptime (@hasDecl(Constraint, "is_zigar_nullable") and Constraint.is_zigar_nullable)) {
            return unitLiteralSatisfiesConstraint(vd, Constraint.Value, depth + 1);
        }
        if (comptime (@hasDecl(Constraint, "zigar_js") and
            @hasField(@TypeOf(Constraint.zigar_js), "is_open_literal") and
            Constraint.zigar_js.is_open_literal))
        {
            if (comptime @hasDecl(Constraint, "fromSlice")) return @hasField(VD, "str_value");
            return @hasField(VD, "int_value") or @hasField(VD, "float_value");
        }
        const c_types = @typeInfo(Constraint).@"union".field_types;
        if (comptime (@hasDecl(Constraint, "zigar_js") and @hasField(@TypeOf(Constraint.zigar_js), "variants"))) {
            const cvs = Constraint.zigar_js.variants;
            inline for (c_types, 0..) |cf_ty, ci| {
                if (ci < cvs.len and @hasField(@TypeOf(cvs[ci]), "is_unit_literal") and cvs[ci].is_unit_literal) {
                    const cvd = cvs[ci];
                    const CVD = @TypeOf(cvd);
                    if (@hasField(VD, "str_value") and @hasField(CVD, "str_value") and std.mem.eql(u8, vd.str_value, cvd.str_value)) return true;
                    if (@hasField(VD, "bool_value") and @hasField(CVD, "bool_value") and vd.bool_value == cvd.bool_value) return true;
                    const v_num: ?f64 = if (@hasField(VD, "num_value")) @floatCast(vd.num_value) else if (@hasField(VD, "int_value")) @floatFromInt(vd.int_value) else if (@hasField(VD, "float_value")) @floatCast(vd.float_value) else null;
                    const c_num: ?f64 = if (@hasField(CVD, "num_value")) @floatCast(cvd.num_value) else if (@hasField(CVD, "int_value")) @floatFromInt(cvd.int_value) else if (@hasField(CVD, "float_value")) @floatCast(cvd.float_value) else null;
                    if (v_num != null and c_num != null and v_num.? == c_num.?) return true;
                    if (@hasField(VD, "bigint_value") and @hasField(CVD, "bigint_value") and std.mem.eql(u8, vd.bigint_value, cvd.bigint_value)) return true;
                } else if (cf_ty != void and unitLiteralSatisfiesConstraint(vd, cf_ty, depth + 1)) {
                    return true;
                }
            }
            return false;
        }
        inline for (c_types) |cf_ty| {
            if (cf_ty != void and unitLiteralSatisfiesConstraint(vd, cf_ty, depth + 1)) return true;
        }
        return false;
    }
    if (@hasField(VD, "str_value")) {
        if (@typeInfo(Constraint) == .@"enum") {
            inline for (@typeInfo(Constraint).@"enum".field_names) |cf_name| {
                if (std.mem.eql(u8, vd.str_value, comptime enumMemberWireName(Constraint, cf_name))) return true;
            }
            return false;
        }
        return satisfiesTypeConstraint([]const u8, Constraint, depth + 1);
    }
    if (@hasField(VD, "bool_value")) return satisfiesTypeConstraint(bool, Constraint, depth + 1);
    if (@hasField(VD, "num_value") or @hasField(VD, "int_value") or @hasField(VD, "float_value")) {
        if (@typeInfo(Constraint) == .@"enum") {
            if (comptime (@hasDecl(Constraint, "toInt") and @hasDecl(Constraint, "fromInt") and !@hasDecl(Constraint, "fromSlice"))) {
                const CInt = @typeInfo(@TypeOf(Constraint.toInt)).@"fn".return_type.?;
                if (@hasField(VD, "int_value")) {
                    const cv = std.math.cast(CInt, vd.int_value) orelse return false;
                    return Constraint.fromInt(cv) != null;
                }
                const vf: f64 = if (@hasField(VD, "num_value")) @floatCast(vd.num_value) else @floatCast(vd.float_value);
                if (!std.math.isFinite(vf) or @trunc(vf) != vf or @abs(vf) > 9007199254740991.0) return false;
                const cv = std.math.cast(CInt, @as(i64, @intFromFloat(vf))) orelse return false;
                return Constraint.fromInt(cv) != null;
            }
            if (comptime (@hasDecl(Constraint, "fromFloat") and !@hasDecl(Constraint, "fromSlice"))) {
                const vf: f64 = if (@hasField(VD, "int_value")) @floatFromInt(vd.int_value) else if (@hasField(VD, "num_value")) @floatCast(vd.num_value) else @floatCast(vd.float_value);
                return Constraint.fromFloat(vf) != null;
            }
            return false;
        }
        return satisfiesTypeConstraint(f64, Constraint, depth + 1);
    }
    if (@hasField(VD, "bigint_value")) return satisfiesTypeConstraint(i64, Constraint, depth + 1);
    return false;
}

fn structHasProtocolFlag(comptime T: type, comptime flag_field: []const u8, comptime depth: usize) bool {
    if (depth >= 16 or @typeInfo(T) != .@"struct") return false;
    if (!isGeneratedHandleStruct(T)) return false;
    const MetaT = @TypeOf(T.zigar_js);
    if (@hasField(MetaT, flag_field) and @field(T.zigar_js, flag_field)) return true;
    if (@hasField(MetaT, "bases")) {
        inline for (T.zigar_js.bases) |BaseT| {
            if (structHasProtocolFlag(BaseT, flag_field, depth + 1)) return true;
        }
    }
    return false;
}

fn structProtocolElemType(comptime T: type, comptime elem_field: []const u8, comptime depth: usize) ?type {
    if (depth >= 16 or @typeInfo(T) != .@"struct") return null;
    if (!isGeneratedHandleStruct(T)) return null;
    const MetaT = @TypeOf(T.zigar_js);
    if (@hasField(MetaT, elem_field)) return @field(T.zigar_js, elem_field);
    if (@hasField(MetaT, "bases")) {
        inline for (T.zigar_js.bases) |BaseT| {
            if (structProtocolElemType(BaseT, elem_field, depth + 1)) |et| return et;
        }
    }
    return null;
}

pub fn satisfiesTypeConstraint(comptime T: type, comptime Constraint: type, comptime depth: usize) bool {
    @setEvalBranchQuota(200_000);
    if (T == Constraint or T == noreturn) return true;
    if (depth > 8) return true;
    // Check `T` BEFORE `Constraint` so mutually-recursive generic type aliases
    // instantiated with `Any` / `Unknown` short-circuit without querying `@typeInfo(Constraint)`
    // while `Constraint` is still resolving its own fields.
    if (comptime isUnconstrainedJsAnyOrUnknown(T)) return true;
    if (comptime isUnconstrainedJsAnyOrUnknown(Constraint)) return true;

    // `T extends object`: reject scalar primitives (`bool`, numbers), allow structs, handles, slices, arrays, functions.
    if (comptime isJsObjectConstraintMarker(Constraint)) {
        return switch (@typeInfo(T)) {
            .bool, .int, .comptime_int, .float, .comptime_float, .void => false,
            else => true,
        };
    }

    // `T extends symbol`
    if (comptime isJsSymbolConstraintMarker(Constraint)) {
        return isJsSymbolConstraintMarker(T);
    }

    // `T extends Function` / callback signature constraint
    if (comptime (isJsFunctionConstraintMarker(Constraint) or
        isCallbackWrapper(Constraint) or
        (@typeInfo(Constraint) == .@"struct" and @hasDecl(Constraint, "zigar_js") and @hasField(@TypeOf(Constraint.zigar_js), "is_callable_handle") and Constraint.zigar_js.is_callable_handle) or
        @typeInfo(Constraint) == .@"fn" or
        (@typeInfo(Constraint) == .pointer and @typeInfo(Constraint).pointer.size == .one and @typeInfo(@typeInfo(Constraint).pointer.child) == .@"fn")))
    {
        return isFunctionLikeConstraintCandidate(T);
    }

    // `T extends string` or template-literal / `js.String`
    if (comptime (Constraint == []const u8 or isTemplateLiteralStruct(Constraint) or
        (@typeInfo(Constraint) == .@"struct" and @hasDecl(Constraint, "is_js_string") and Constraint.is_js_string)))
    {
        return isStringLikeConstraintCandidate(T);
    }

    // `T extends boolean`
    if (Constraint == bool) return T == bool;

    // `T extends bigint`
    if (comptime (Constraint == i64 or Constraint == u64 or
        (@typeInfo(Constraint) == .@"struct" and @hasDecl(Constraint, "is_js_bigint") and Constraint.is_js_bigint)))
    {
        return switch (@typeInfo(T)) {
            .int, .comptime_int => true,
            .@"struct" => @hasDecl(T, "is_js_bigint") and T.is_js_bigint,
            else => false,
        };
    }

    // `T extends number`
    if (comptime (@typeInfo(Constraint) == .float or @typeInfo(Constraint) == .int)) {
        return isNumberLikeConstraintCandidate(T);
    }

    // If `T` itself is a tagged union, every variant payload must satisfy `Constraint`.
    if (comptime (@typeInfo(T) == .@"union")) {
        if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_open_literal") and T.zigar_js.is_open_literal)) {
            // Handled below if Constraint is open literal or union.
        } else if (comptime (@hasDecl(T, "is_zigar_nullable") and T.is_zigar_nullable)) {
            return satisfiesTypeConstraint(@TypeOf(null), Constraint, depth + 1) and
                satisfiesTypeConstraint(T.Value, Constraint, depth + 1);
        } else {
            const u_types = @typeInfo(T).@"union".field_types;
            if (comptime (u_types.len > 0)) {
                const has_t_vars = comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "variants"));
                inline for (u_types, 0..) |uf_ty, ui| {
                    if (uf_ty != void) {
                        if (!satisfiesTypeConstraint(uf_ty, Constraint, depth + 1)) return false;
                    } else if (has_t_vars and ui < T.zigar_js.variants.len and
                        @hasField(@TypeOf(T.zigar_js.variants[ui]), "is_unit_literal") and
                        T.zigar_js.variants[ui].is_unit_literal)
                    {
                        if (!unitLiteralSatisfiesConstraint(T.zigar_js.variants[ui], Constraint, depth + 1)) return false;
                    } else {
                        if (!satisfiesTypeConstraint(void, Constraint, depth + 1)) return false;
                    }
                }
                return true;
            }
        }
    }

    return switch (@typeInfo(Constraint)) {
        .optional => |op| blk: {
            if (T == @TypeOf(null) or T == @TypeOf(undefined) or T == void) break :blk true;
            if (@typeInfo(T) == .optional) {
                break :blk satisfiesTypeConstraint(@typeInfo(T).optional.child, op.child, depth + 1);
            }
            break :blk satisfiesTypeConstraint(T, op.child, depth + 1);
        },
        .pointer => |cpt| blk: {
            if (cpt.size == .slice) {
                if (cpt.child == u8) {
                    if (isStringLikeConstraintCandidate(T)) break :blk true;
                    if (@typeInfo(T) == .@"struct" and isGeneratedHandleStruct(T)) break :blk true;
                }
                break :blk switch (@typeInfo(T)) {
                    .pointer => |tpt| if (tpt.size == .slice)
                        satisfiesTypeConstraint(tpt.child, cpt.child, depth + 1)
                    else if (tpt.size == .one and @typeInfo(tpt.child) == .array)
                        satisfiesTypeConstraint(@typeInfo(tpt.child).array.child, cpt.child, depth + 1)
                    else
                        false,
                    .array => |tar| satisfiesTypeConstraint(tar.child, cpt.child, depth + 1),
                    .@"struct" => if (@hasDecl(T, "is_js_array") and T.is_js_array) blk_arr: {
                        const TElem = if (@hasDecl(T, "Elem")) T.Elem else T.Element;
                        break :blk_arr satisfiesTypeConstraint(TElem, cpt.child, depth + 1);
                    } else false,
                    else => false,
                };
            }
            break :blk false;
        },
        .@"enum" => |cen| blk: {
            if (@typeInfo(T) != .@"enum") break :blk false;
            const ten = @typeInfo(T).@"enum";
            if (comptime (@hasDecl(T, "toInt") and @hasDecl(Constraint, "toInt") and @hasDecl(Constraint, "fromInt") and
                !@hasDecl(T, "fromSlice") and !@hasDecl(Constraint, "fromSlice")))
            {
                const CInt = @typeInfo(@TypeOf(Constraint.toInt)).@"fn".return_type.?;
                inline for (ten.field_names) |tf_name| {
                    const tv = @field(T, tf_name).toInt();
                    const cv = std.math.cast(CInt, tv) orelse break :blk false;
                    if (Constraint.fromInt(cv) == null) break :blk false;
                }
                break :blk true;
            }
            if (comptime (@hasDecl(T, "toFloat") and @hasDecl(Constraint, "fromFloat") and
                !@hasDecl(T, "fromSlice") and !@hasDecl(Constraint, "fromSlice")))
            {
                inline for (ten.field_names) |tf_name| {
                    const tv: f64 = @floatCast(@field(T, tf_name).toFloat());
                    if (Constraint.fromFloat(tv) == null) break :blk false;
                }
                break :blk true;
            }
            inline for (ten.field_names) |tf_name| {
                const tw = comptime enumMemberWireName(T, tf_name);
                var found = false;
                inline for (cen.field_names) |cf_name| {
                    const cw = comptime enumMemberWireName(Constraint, cf_name);
                    if (std.mem.eql(u8, tw, cw)) {
                        found = true;
                        break;
                    }
                }
                if (!found) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |cun| blk: {
            if (comptime (@hasDecl(Constraint, "is_zigar_nullable") and Constraint.is_zigar_nullable)) {
                if (T == @TypeOf(null) or T == @TypeOf(undefined) or T == void) break :blk true;
                if (@typeInfo(T) == .optional) {
                    break :blk satisfiesTypeConstraint(@typeInfo(T).optional.child, Constraint.Value, depth + 1);
                }
                break :blk satisfiesTypeConstraint(T, Constraint.Value, depth + 1);
            }
            if (comptime (@hasDecl(Constraint, "zigar_js") and
                @hasField(@TypeOf(Constraint.zigar_js), "is_open_literal") and
                Constraint.zigar_js.is_open_literal))
            {
                if (comptime @hasDecl(Constraint, "fromSlice")) break :blk isStringLikeConstraintCandidate(T);
                break :blk isNumberLikeConstraintCandidate(T);
            }
            const has_c_vars = comptime (@hasDecl(Constraint, "zigar_js") and @hasField(@TypeOf(Constraint.zigar_js), "variants"));
            inline for (cun.field_types, 0..) |cf_ty, ci| {
                if (cf_ty != void) {
                    if (satisfiesTypeConstraint(T, cf_ty, depth + 1)) break :blk true;
                } else if (T == void) {
                    const is_ul = has_c_vars and ci < Constraint.zigar_js.variants.len and
                        @hasField(@TypeOf(Constraint.zigar_js.variants[ci]), "is_unit_literal") and
                        Constraint.zigar_js.variants[ci].is_unit_literal;
                    if (!is_ul) break :blk true;
                }
            }
            if (@typeInfo(T) == .@"enum") {
                const ten = @typeInfo(T).@"enum";
                if (ten.field_names.len > 0) {
                    var all_ok = true;
                    if (comptime (@hasDecl(T, "toInt") and !@hasDecl(T, "fromSlice"))) {
                        inline for (ten.field_names) |tf_name| {
                            const tv = @field(T, tf_name).toInt();
                            if (!unitLiteralSatisfiesConstraint(.{ .int_value = tv }, Constraint, depth + 1)) {
                                all_ok = false;
                                break;
                            }
                        }
                    } else if (comptime (@hasDecl(T, "toFloat") and !@hasDecl(T, "fromSlice"))) {
                        inline for (ten.field_names) |tf_name| {
                            const tv: f64 = @floatCast(@field(T, tf_name).toFloat());
                            if (!unitLiteralSatisfiesConstraint(.{ .float_value = tv }, Constraint, depth + 1)) {
                                all_ok = false;
                                break;
                            }
                        }
                    } else {
                        inline for (ten.field_names) |tf_name| {
                            const tw = comptime enumMemberWireName(T, tf_name);
                            if (!unitLiteralSatisfiesConstraint(.{ .str_value = tw }, Constraint, depth + 1)) {
                                all_ok = false;
                                break;
                            }
                        }
                    }
                    if (all_ok) break :blk true;
                }
            }
            break :blk false;
        },
        .@"struct" => |cst| blk: {
            // `Record<string, V>` / `Map<K, V>` constraint: any struct / object / map / handle satisfies object-record constraints.
            if (comptime ((@hasDecl(Constraint, "is_js_map") and Constraint.is_js_map) or
                (@hasDecl(Constraint, "is_js_record") and Constraint.is_js_record)))
            {
                break :blk @typeInfo(T) == .@"struct";
            }
            if (comptime (@hasDecl(Constraint, "is_js_set") and Constraint.is_js_set)) {
                if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_set") and T.is_js_set)) {
                    const TElem = if (@hasDecl(T, "Elem")) T.Elem else T.Element;
                    const CElem = if (@hasDecl(Constraint, "Elem")) Constraint.Elem else Constraint.Element;
                    break :blk satisfiesTypeConstraint(TElem, CElem, depth + 1);
                }
                break :blk false;
            }
            if (comptime (@hasDecl(Constraint, "is_js_disposable") and Constraint.is_js_disposable)) {
                if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_disposable") and T.is_js_disposable)) break :blk true;
                if (comptime structHasProtocolFlag(T, "has_dispose", 0)) break :blk true;
                break :blk false;
            }
            if (comptime (@hasDecl(Constraint, "is_js_async_disposable") and Constraint.is_js_async_disposable)) {
                if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_async_disposable") and T.is_js_async_disposable)) break :blk true;
                if (comptime structHasProtocolFlag(T, "has_async_dispose", 0)) break :blk true;
                break :blk false;
            }
            if (comptime (@hasDecl(Constraint, "is_js_iterator") and Constraint.is_js_iterator)) {
                const CElem = if (@hasDecl(Constraint, "Elem")) Constraint.Elem else Constraint.Element;
                if (comptime (@typeInfo(T) == .@"struct" and ((@hasDecl(T, "is_js_iterator") and T.is_js_iterator) or
                    (@hasDecl(T, "is_js_array") and T.is_js_array) or
                    (@hasDecl(T, "is_js_set") and T.is_js_set))))
                {
                    const TElem = if (@hasDecl(T, "Elem")) T.Elem else T.Element;
                    break :blk satisfiesTypeConstraint(TElem, CElem, depth + 1);
                }
                if (comptime (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice)) {
                    const ChildT = @typeInfo(T).pointer.child;
                    if (ChildT == u8) {
                        break :blk satisfiesTypeConstraint([]const u8, CElem, depth + 1) or satisfiesTypeConstraint(u8, CElem, depth + 1);
                    }
                    break :blk satisfiesTypeConstraint(ChildT, CElem, depth + 1);
                }
                if (comptime (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one and @typeInfo(@typeInfo(T).pointer.child) == .array)) {
                    break :blk satisfiesTypeConstraint(@typeInfo(@typeInfo(T).pointer.child).array.child, CElem, depth + 1);
                }
                if (comptime (@typeInfo(T) == .array)) {
                    break :blk satisfiesTypeConstraint(@typeInfo(T).array.child, CElem, depth + 1);
                }
                if (comptime structHasProtocolFlag(T, "has_iterator", 0)) {
                    if (comptime structProtocolElemType(T, "iterator_elem", 0)) |te| {
                        break :blk satisfiesTypeConstraint(te, CElem, depth + 1);
                    }
                    break :blk true;
                }
                break :blk false;
            }
            if (comptime (@hasDecl(Constraint, "is_js_async_iterator") and Constraint.is_js_async_iterator)) {
                const CElem = if (@hasDecl(Constraint, "Elem")) Constraint.Elem else Constraint.Element;
                if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_async_iterator") and T.is_js_async_iterator)) {
                    const TElem = if (@hasDecl(T, "Elem")) T.Elem else T.Element;
                    break :blk satisfiesTypeConstraint(TElem, CElem, depth + 1);
                }
                if (comptime structHasProtocolFlag(T, "has_async_iterator", 0)) {
                    if (comptime structProtocolElemType(T, "async_iterator_elem", 0)) |te| {
                        break :blk satisfiesTypeConstraint(te, CElem, depth + 1);
                    }
                    break :blk true;
                }
                break :blk false;
            }
            // `Promise<U>` constraint: accept `Promise<X>` where `X` satisfies `U`, or structural `then` handle.
            if (comptime (@hasDecl(Constraint, "is_js_promise") and Constraint.is_js_promise)) {
                if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_promise") and T.is_js_promise)) {
                    if (comptime (@hasDecl(T, "Payload") and @hasDecl(Constraint, "Payload"))) {
                        break :blk satisfiesTypeConstraint(T.Payload, Constraint.Payload, depth + 1);
                    }
                    break :blk true;
                }
                break :blk structProvidesMember(T, "then");
            }
            // Tuple constraint (`zigar_js_tuple`): check fixed array or tuple struct.
            if (comptime @hasDecl(Constraint, "zigar_js_tuple")) {
                if (@typeInfo(T) != .@"struct" and @typeInfo(T) != .array) break :blk false;
                break :blk true;
            }
            // Nominal JS class (`is_handle && is_class`) or structural handle interface:
            if (comptime isGeneratedHandleStruct(Constraint)) {
                if (structDerivesFrom(T, Constraint, 0)) break :blk true;
                const is_nom_class = comptime (@hasField(@TypeOf(Constraint.zigar_js), "is_class") and Constraint.zigar_js.is_class);
                if (is_nom_class) {
                    const has_priv = comptime ((@hasField(@TypeOf(Constraint.zigar_js), "has_private_constructor") and Constraint.zigar_js.has_private_constructor) or
                        (@hasField(@TypeOf(Constraint.zigar_js), "has_non_public_members") and Constraint.zigar_js.has_non_public_members));
                    if (has_priv or !isGeneratedHandleStruct(T)) break :blk false;
                    if (comptime @hasField(@TypeOf(Constraint.zigar_js), "fields")) {
                        inline for (@typeInfo(@TypeOf(Constraint.zigar_js.fields)).@"struct".field_names) |mf_name| {
                            const entry = @field(Constraint.zigar_js.fields, mf_name);
                            const opt = comptime (@hasField(@TypeOf(entry), "is_optional") and entry.is_optional);
                            if (!opt and !structProvidesMember(T, entry.js_name)) break :blk false;
                        }
                    }
                    if (comptime @hasField(@TypeOf(Constraint.zigar_js), "methods")) {
                        inline for (@typeInfo(@TypeOf(Constraint.zigar_js.methods)).@"struct".field_names) |mf_name| {
                            const entry = @field(Constraint.zigar_js.methods, mf_name);
                            const is_stat = comptime (@hasField(@TypeOf(entry), "is_static") and entry.is_static);
                            if (!is_stat and !structProvidesMember(T, entry.js_name)) break :blk false;
                        }
                    }
                    break :blk true;
                }
                if (@typeInfo(T) != .@"struct") break :blk false;
                if (isJsObjectConstraintMarker(T)) break :blk true;
                if (comptime @hasField(@TypeOf(Constraint.zigar_js), "required_methods")) {
                    inline for (Constraint.zigar_js.required_methods) |rm| {
                        if (!structProvidesMember(T, rm)) break :blk false;
                    }
                }
                if (comptime @hasField(@TypeOf(Constraint.zigar_js), "required_props")) {
                    inline for (Constraint.zigar_js.required_props) |rp| {
                        if (!structProvidesMember(T, rp)) break :blk false;
                    }
                }
                if (comptime structHasProtocolFlag(Constraint, "has_dispose", 0)) {
                    if (!((@hasDecl(T, "is_js_disposable") and T.is_js_disposable) or structHasProtocolFlag(T, "has_dispose", 0))) break :blk false;
                }
                if (comptime structHasProtocolFlag(Constraint, "has_async_dispose", 0)) {
                    if (!((@hasDecl(T, "is_js_async_disposable") and T.is_js_async_disposable) or structHasProtocolFlag(T, "has_async_dispose", 0))) break :blk false;
                }
                if (comptime structHasProtocolFlag(Constraint, "has_iterator", 0)) {
                    if (!((@hasDecl(T, "is_js_iterator") and T.is_js_iterator) or structHasProtocolFlag(T, "has_iterator", 0))) break :blk false;
                }
                if (comptime structHasProtocolFlag(Constraint, "has_async_iterator", 0)) {
                    if (!((@hasDecl(T, "is_js_async_iterator") and T.is_js_async_iterator) or structHasProtocolFlag(T, "has_async_iterator", 0))) break :blk false;
                }
                break :blk true;
            }
            // Plain value struct constraint (`T extends HasId`):
            if (@typeInfo(T) != .@"struct") break :blk false;
            if (isJsObjectConstraintMarker(T)) break :blk true;
            inline for (cst.field_names, 0..) |cf_name, cf_idx| {
                if (comptime isHiddenMetaField(cf_name)) continue;
                const cf_ty = cst.field_types[cf_idx];
                const cf_attr = cst.field_attrs[cf_idx];
                const is_opt = comptime (cf_attr.default_value_ptr != null or @typeInfo(cf_ty) == .optional or isModuleNullableType(cf_ty));
                if (!is_opt) {
                    const wire = comptime topStructFieldWireName(Constraint, cf_name);
                    if (comptime lookupStructFieldType(T, cf_name, wire)) |tf_ty| {
                        if (!satisfiesTypeConstraint(tf_ty, cf_ty, depth + 1)) break :blk false;
                    } else if (comptime (isGeneratedHandleStruct(T) and structProvidesMember(T, wire))) {
                        // Handle struct exposes this property via getter/accessor.
                    } else {
                        break :blk false;
                    }
                }
            }
            break :blk true;
        },
        else => true,
    };
}

/// Enforces TypeScript `T extends Constraint` at Zig `comptime` with a clear diagnostic.
pub fn checkTypeConstraint(comptime T: type, comptime Constraint: type) void {
    if (!comptime satisfiesTypeConstraint(T, Constraint, 0)) {
        @compileError("zigar.js: type '" ++ @typeName(T) ++ "' does not satisfy TypeScript constraint '" ++ @typeName(Constraint) ++ "'");
    }
}

fn isCallbackWrapper(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "is_zig_callback") and T.is_zig_callback,
        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .@"struct" and @hasDecl(pt.child, "is_zig_callback") and pt.child.is_zig_callback,
        else => false,
    };
}

fn isGeneratedHandleStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_handle") and T.zigar_js.is_handle,
        else => false,
    };
}

fn generatedHandleRefFieldName(comptime T: type) []const u8 {
    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "ref_field")) {
        return T.zigar_js.ref_field;
    }
    return "ref";
}

fn isTemplateLiteralStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "zigar_js") and
            @hasField(@TypeOf(T.zigar_js), "is_template_literal") and
            T.zigar_js.is_template_literal and
            @hasField(T, "raw"),
        else => false,
    };
}

fn extractHandle(value: anytype) u32 {
    const V = @TypeOf(value);
    if (V == @TypeOf(null)) return reserved_null_handle;
    if (V == @TypeOf(undefined)) return reserved_undefined_handle;
    if (V == bool) return if (value) reserved_true_handle else reserved_false_handle;
    if (comptime isCallbackWrapper(V)) {
        return switch (@typeInfo(V)) {
            .pointer => value.*.func.handle,
            else => value.func.handle,
        };
    }
    if (comptime util.getInternalType(V) == .js_value) {
        return value.handle;
    }
    if (comptime isGeneratedHandleStruct(V)) {
        return @field(value, generatedHandleRefFieldName(V)).handle;
    }
    switch (@typeInfo(V)) {
        .pointer => |pt| {
            if (pt.size == .one and comptime util.getInternalType(pt.child) == .js_value) {
                return value.*.handle;
            }
            if (pt.size == .one and comptime isGeneratedHandleStruct(pt.child)) {
                return @field(value.*, generatedHandleRefFieldName(pt.child)).handle;
            }
        },
        else => {},
    }
    @compileError("Expected zigar.js.Ref(T), received " ++ @typeName(V));
}

fn isStringLiteralPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pt| pt.size == .one and switch (@typeInfo(pt.child)) {
            .array => |arr| arr.child == u8,
            else => false,
        },
        else => false,
    };
}

fn buildFnType(comptime params: []const type, comptime RT: type) type {
    var param_types: [params.len]type = undefined;
    var param_attrs: [params.len]std.lang.Type.Fn.ParamAttributes = undefined;
    for (params, 0..) |pt, i| {
        param_types[i] = pt;
        param_attrs[i] = .{};
    }
    return @Fn(&param_types, &param_attrs, RT, .{});
}

fn PrependParamsFn(comptime prefix: []const type, comptime FnSig: type, comptime CallbackRefT: type) type {
    const f = switch (@typeInfo(FnSig)) {
        .@"fn" => |fi| fi,
        else => @compileError("Expected a Zig function signature `fn (...) ...`, received " ++ @typeName(FnSig)),
    };
    var has_alloc = false;
    for (f.param_types, 0..) |maybe_pt, idx| {
        const pt = maybe_pt orelse @compileError("Host function signature cannot use `anytype` parameters");
        if (pt == std.mem.Allocator) {
            if (idx != 0) @compileError("std.mem.Allocator must be the first parameter in host function signature");
            has_alloc = true;
        }
    }
    const extra_start: usize = if (has_alloc) 1 else 0;
    const total = f.param_types.len + prefix.len;
    var param_types: [total]type = undefined;
    var param_attrs: [total]std.lang.Type.Fn.ParamAttributes = undefined;
    var out: usize = 0;
    if (has_alloc) {
        param_types[0] = f.param_types[0].?;
        param_attrs[0] = .{};
        out = 1;
    }
    for (prefix) |pre_t| {
        param_types[out] = pre_t;
        param_attrs[out] = .{};
        out += 1;
    }
    for (f.param_types[extra_start..]) |maybe_pt| {
        const pt = maybe_pt.?;
        param_types[out] = if (isCallbackWrapper(pt)) CallbackRefT else pt;
        param_attrs[out] = .{};
        out += 1;
    }
    return @Fn(&param_types, &param_attrs, f.return_type orelse void, .{});
}

fn FnReturnType(comptime FnSig: type) type {
    return switch (@typeInfo(FnSig)) {
        .@"fn" => |fi| fi.return_type orelse void,
        else => @compileError("Expected a Zig function signature `fn (...) ...`, received " ++ @typeName(FnSig)),
    };
}

fn errorSetContains(comptime ESet: type, comptime name: []const u8) bool {
    const names = @typeInfo(ESet).error_set.error_names orelse return true;
    for (names) |err_name| {
        if (std.mem.eql(u8, err_name, name)) return true;
    }
    return false;
}

fn pointerAlign(comptime pt: anytype) usize {
    const child_align: usize = if (@typeInfo(pt.child) == .@"opaque") 1 else @alignOf(pt.child);
    const explicit_align: usize = if (pt.attrs.@"align") |al| @intCast(al) else child_align;
    return @max(explicit_align, child_align, 1);
}

fn defaultFallbackValue(comptime T: type) T {
    if (comptime util.getInternalType(T) == .js_value) {
        return .{ .handle = reserved_undefined_handle };
    }
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => false,
        .int, .float => 0,
        .optional, .null => null,
        .undefined => undefined,
        .pointer => |pt| switch (pt.size) {
            .slice => init: {
                const a = comptime pointerAlign(pt);
                if (pt.sentinel_ptr) |sp| {
                    const s_val = @as(*const pt.child, @ptrCast(@alignCast(sp))).*;
                    if (pt.attrs.@"const") {
                        const S = struct {
                            const buf: [0:s_val]pt.child align(a) = .{};
                        };
                        break :init &S.buf;
                    } else {
                        const S = struct {
                            var buf: [0:s_val]pt.child align(a) = .{};
                        };
                        break :init &S.buf;
                    }
                }
                const dangling: [*]align(a) pt.child = @ptrFromInt(a);
                break :init dangling[0..0];
            },
            .c => null,
            .many => init: {
                const a = comptime pointerAlign(pt);
                if (pt.sentinel_ptr) |sp| {
                    const s_val = @as(*const pt.child, @ptrCast(@alignCast(sp))).*;
                    if (pt.attrs.@"const") {
                        const S = struct {
                            const buf: [0:s_val]pt.child align(a) = .{};
                        };
                        break :init &S.buf;
                    } else {
                        const S = struct {
                            var buf: [0:s_val]pt.child align(a) = .{};
                        };
                        break :init &S.buf;
                    }
                }
                const child_size = comptime if (@typeInfo(pt.child) == .@"opaque" or @typeInfo(pt.child) == .@"fn") 1 else @max(@sizeOf(pt.child), 1);
                const S = struct {
                    var bytes: [child_size]u8 align(a) = std.mem.zeroes([child_size]u8);
                };
                break :init @ptrCast(&S.bytes);
            },
            .one => init: {
                const a = comptime pointerAlign(pt);
                if (@typeInfo(pt.child) == .@"fn") {
                    break :init @ptrFromInt(a);
                }
                const child_size = comptime if (@typeInfo(pt.child) == .@"opaque") 1 else @max(@sizeOf(pt.child), 1);
                const S = struct {
                    var bytes: [child_size]u8 align(a) = std.mem.zeroes([child_size]u8);
                };
                break :init @ptrCast(&S.bytes);
            },
        },
        .@"enum" => |en| if (en.field_names.len > 0) @field(T, en.field_names[0]) else @enumFromInt(0),
        .@"struct" => |st| init: {
            var s: T = undefined;
            inline for (st.field_names, 0..) |field_name, index| {
                if (!st.field_attrs[index].@"comptime") {
                    @field(s, field_name) = defaultFallbackValue(st.field_types[index]);
                }
            }
            break :init s;
        },
        .@"union" => |un| if (un.field_names.len > 0)
            @unionInit(T, un.field_names[0], defaultFallbackValue(un.field_types[0]))
        else
            undefined,
        .array => |ar| init: {
            var arr: T = undefined;
            for (&arr) |*elem| {
                elem.* = defaultFallbackValue(ar.child);
            }
            if (ar.sentinel_ptr) |sp| {
                const s_val = @as(*const ar.child, @ptrCast(@alignCast(sp))).*;
                @as([*]ar.child, @ptrCast(&arr))[ar.len] = s_val;
            }
            break :init arr;
        },
        .vector => |vec| @splat(defaultFallbackValue(vec.child)),
        .error_union => |eu| init: {
            if (@typeInfo(eu.error_set).error_set.error_names) |names| {
                if (names.len > 0) break :init @field(eu.error_set, names[0]);
            }
            break :init defaultFallbackValue(eu.payload);
        },
        .error_set => |es| init: {
            if (es.error_names) |names| {
                if (names.len > 0) break :init @field(T, names[0]);
            }
            @panic("Uncaught JS exception in empty error set host operation");
        },
        else => init: {
            var zeroed: T = undefined;
            @memset(std.mem.asBytes(&zeroed), 0);
            break :init zeroed;
        },
    };
}

pub fn Js(comptime host: type) type {
    return struct {
        const JsNs = @This();

        pub const Error = module.Error;
        pub const CallError = module.CallError;
        pub const OverflowError = module.OverflowError;
        pub const AllocError = module.AllocError;
        pub const JsType = module.JsType;
        pub const HostOp = module.HostOp;
        pub const AwaitMode = module.AwaitMode;
        pub const BinaryKind = module.BinaryKind;
        pub const BinaryInfoKind = module.BinaryInfoKind;
        pub const CollectionSubOp = module.CollectionSubOp;
        pub const HostOpFlags = module.HostOpFlags;
        pub const JsModuleNode = module.JsModuleNode;
        pub const CallbackFlags = module.CallbackFlags;
        pub const HostOpDescriptor = module.HostOpDescriptor;
        pub const CallbackDescriptor = module.CallbackDescriptor;
        pub const Any = module.Any;
        pub const Unknown = module.Unknown;
        pub const Object = module.Object;
        pub const Symbol = module.Symbol;
        pub const Function = module.Function;
        pub const NullishKind = module.NullishKind;
        pub const Nullable = module.Nullable;
        pub const TemplatePlaceholderKind = module.TemplatePlaceholderKind;
        pub const matchTemplatePattern = module.matchTemplatePattern;
        pub const coerceUnion = module.coerceUnion;
        pub const Partial = module.Partial;
        pub const Required = module.Required;
        pub const Readonly = module.Readonly;
        pub const Pick = module.Pick;
        pub const Omit = module.Omit;
        pub fn Intersect(comptime parts: anytype) type {
            return module.IntersectWithHost(@This(), parts);
        }
        pub const EnumRecord = module.EnumRecord;
        pub fn MappedValues(comptime T: type, comptime V: type) type {
            return module.MappedValuesSpecWithFallback(Record, T, V, .auto);
        }
        pub fn MappedValuesSpec(comptime T: type, comptime V: type, comptime v_spec: anytype) type {
            return module.MappedValuesSpecWithFallback(Record, T, V, v_spec);
        }
        pub const NonNullable = module.NonNullable;
        pub const Awaited = module.Awaited;
        pub const KeyOf = module.KeyOf;
        pub fn IndexAccess(comptime T: type, comptime keys_spec: anytype) type {
            return module.IndexAccessWithFallback(Ref(module.Any), T, keys_spec);
        }
        pub fn InferJsType(comptime Arg: type) type {
            return module.InferJsTypeWithFallback(Ref(module.Any), Arg);
        }
        pub fn InferConstJsType(comptime Arg: type) type {
            return module.InferConstJsTypeWithFallback(Ref(module.Any), Arg);
        }
        pub const isConstArrayPtr = module.isConstArrayPtr;
        pub const InferSliceElem = module.InferSliceElem;
        pub const InferIteratorElem = module.InferIteratorElem;
        pub fn InferOptionalChild(comptime Opt: type) type {
            return module.InferOptionalChildWithFallback(Ref(module.Any), Opt);
        }
        pub const satisfiesTypeConstraint = module.satisfiesTypeConstraint;
        pub const checkTypeConstraint = module.checkTypeConstraint;

        pub const reserved_undefined_handle = module.reserved_undefined_handle;
        pub const reserved_null_handle = module.reserved_null_handle;
        pub const reserved_false_handle = module.reserved_false_handle;
        pub const reserved_true_handle = module.reserved_true_handle;
        pub const reserved_global_this_handle = module.reserved_global_this_handle;
        pub const no_captured_error_handle = module.no_captured_error_handle;
        pub const first_dynamic_slot = module.first_dynamic_slot;

        fn TypeRegistration(comptime T: type) type {
            return struct {
                fn registerTypeExport() callconv(.c) void {
                    if (@hasDecl(host, "registerType")) {
                        host.registerType(T);
                    }
                }
                comptime {
                    @setEvalBranchQuota(2_000_000);
                    if (builtin.target.cpu.arch.isWasm() and @hasDecl(host, "registerType")) {
                        const sig = signature.get(T);
                        const h0 = std.hash.Wyhash.hash(sig, @typeName(T));
                        const h1 = std.hash.Wyhash.hash(~sig, @typeName(T));
                        const export_name = std.fmt.comptimePrint("__zigar_js_reg_{x:0>16}{x:0>16}", .{ h0, h1 });
                        @export(&registerTypeExport, .{ .name = export_name });
                    }
                }
            };
        }

        fn ModuleRegistration(comptime len: usize, comptime bytes: [len]u8) type {
            return struct {
                const prefix = "__zigar_js_mod:";
                const key_arr: [prefix.len + len]u8 = prefix.* ++ bytes;
                var node: module.JsModuleNode = .{ .key = &key_arr };

                fn registerModuleExport() callconv(.c) void {
                    if (@hasDecl(host, "registerJsModule")) {
                        host.registerJsModule(&key_arr);
                    }
                }

                fn registerModuleInit() callconv(.c) void {
                    if (@hasDecl(host, "registerJsModuleNode")) {
                        host.registerJsModuleNode(&node);
                    }
                }

                comptime {
                    const h0 = std.hash.Wyhash.hash(0x6a73_6d6f_6475_6c65, &bytes);
                    const h1 = std.hash.Wyhash.hash(~@as(u64, 0x6a73_6d6f_6475_6c65), &bytes);
                    const export_name = std.fmt.comptimePrint("__zigar_js_mod_{x:0>16}{x:0>16}", .{ h0, h1 });
                    if (builtin.target.cpu.arch.isWasm() and @hasDecl(host, "registerJsModule")) {
                        @export(&registerModuleExport, .{ .name = export_name });
                    } else if (!builtin.target.cpu.arch.isWasm() and @hasDecl(host, "registerJsModuleNode")) {
                        const init_section = switch (builtin.target.os.tag) {
                            .macos, .ios, .tvos, .watchos, .visionos, .driverkit => "__DATA,__mod_init_func",
                            .windows => ".CRT$XCU",
                            else => ".init_array",
                        };
                        const Holder = struct {
                            const ctor_ptr: *const fn () callconv(.c) void linksection(init_section) = &registerModuleInit;
                        };
                        @export(&Holder.ctor_ptr, .{ .name = export_name });
                    }
                }
            };
        }

        pub fn DynamicKeyArgType(comptime K: type) type {
            if (K == []const u8 or K == []u8 or isStringLiteralPtr(K) or isTemplateLiteralStruct(K)) {
                return []const u8;
            }
            if (util.getInternalType(K) == .js_value or isGeneratedHandleStruct(K)) {
                return Ref(module.Any);
            }
            switch (@typeInfo(K)) {
                .float, .comptime_float, .int, .comptime_int => return f64,
                .@"enum" => {
                    if (@hasDecl(K, "toSlice")) return []const u8;
                    if (@hasDecl(K, "toInt")) return f64;
                },
                .pointer => |pt| {
                    if (pt.size == .slice and pt.child == u8) return []const u8;
                    if (pt.size == .many and pt.sentinel_ptr != null and pt.child == u8) return []const u8;
                    if (pt.size == .one and (util.getInternalType(pt.child) == .js_value or isGeneratedHandleStruct(pt.child))) return Ref(module.Any);
                    if (pt.size == .one and isTemplateLiteralStruct(pt.child)) return []const u8;
                },
                else => {},
            }
            @compileError("Dynamic JS property key must be `[]const u8`, numeric, template literal, or `zigar.js.Ref(...)`, received " ++ @typeName(K));
        }

        pub fn coerceDynamicKey(key: anytype) DynamicKeyArgType(@TypeOf(key)) {
            const K = @TypeOf(key);
            const OutT = DynamicKeyArgType(K);
            if (OutT == []const u8) {
                if (@typeInfo(K) == .@"enum") return key.toSlice();
                if (comptime isStringLiteralPtr(K)) return key[0..];
                if (comptime isTemplateLiteralStruct(K)) return key.raw;
                switch (@typeInfo(K)) {
                    .pointer => |pt| {
                        if (pt.size == .many and pt.sentinel_ptr != null) return std.mem.span(key);
                        if (pt.size == .one and comptime isTemplateLiteralStruct(pt.child)) return key.*.raw;
                    },
                    else => {},
                }
                return key;
            }
            if (OutT == f64) {
                return switch (@typeInfo(K)) {
                    .@"enum" => @as(f64, @floatFromInt(key.toInt())),
                    .int => @as(f64, @floatFromInt(key)),
                    else => @as(f64, key),
                };
            }
            return .{ .handle = extractHandle(key) };
        }

        fn NormalizedValueType(comptime V: type) type {
            if (V == comptime_int) return i64;
            if (V == comptime_float) return f64;
            if (V == @TypeOf(null) or V == @TypeOf(undefined)) return Ref(module.Any);
            if (comptime isStringLiteralPtr(V)) return []const u8;
            if (comptime isCallbackWrapper(V)) return Ref(module.Function);
            return V;
        }

        fn normalizeValue(value: anytype) NormalizedValueType(@TypeOf(value)) {
            const V = @TypeOf(value);
            if (V == comptime_int) return @as(i64, value);
            if (V == comptime_float) return @as(f64, value);
            if (V == @TypeOf(null)) return Ref(module.Any).@"null";
            if (V == @TypeOf(undefined)) return Ref(module.Any).@"undefined";
            if (comptime isStringLiteralPtr(V)) return value[0..];
            if (comptime isCallbackWrapper(V)) return switch (@typeInfo(V)) {
                .pointer => value.*.func,
                else => value.func,
            };
            return value;
        }

        fn coerceToParam(comptime ParamT: type, value: anytype) ParamT {
            const V = @TypeOf(value);
            if (V == ParamT) return value;
            if (comptime util.getInternalType(ParamT) == .js_value) {
                return .{ .handle = extractHandle(value) };
            }
            if (ParamT == []const u8 and comptime isStringLiteralPtr(V)) {
                return value[0..];
            }
            return @as(ParamT, value);
        }

        fn mapHostFailure(comptime RT: type, status: E) RT {
            switch (@typeInfo(RT)) {
                .error_union => |eu| {
                    const ESet = eu.error_set;
                    switch (status) {
                        .PERM => if (comptime errorSetContains(ESet, "OffJsThread")) return @field(anyerror, "OffJsThread"),
                        .NOSYS => if (comptime errorSetContains(ESet, "HostUnavailable")) return @field(anyerror, "HostUnavailable"),
                        else => {
                            if (comptime errorSetContains(ESet, "JsException")) return @field(anyerror, "JsException");
                            if (comptime errorSetContains(ESet, "Unexpected")) return @field(anyerror, "Unexpected");
                            if (@typeInfo(ESet).error_set.error_names) |names| {
                                if (names.len > 0) return @field(anyerror, names[0]);
                            }
                        },
                    }
                },
                else => {},
            }
            switch (status) {
                .PERM => @panic("JsValue operations require the JS thread"),
                .NOSYS => @panic("JsValue host imports unavailable"),
                else => return defaultFallbackValue(RT),
            }
        }

        fn dispatchHostOpRawFlags(
            comptime op: module.HostOp,
            comptime raw_flags: u32,
            comptime key_name: []const u8,
            comptime HostFn: type,
            args_tuple: std.meta.ArgsTuple(HostFn),
        ) FnReturnType(HostFn) {
            const Args = arg_struct.ArgStruct(HostFn);
            const RT = FnReturnType(HostFn);
            const reg = TypeRegistration(Args);
            _ = reg;
            const flag_bits: module.HostOpFlags = @bitCast(raw_flags);
            if (comptime (op == .import_module and !flag_bits.dynamic_key)) {
                const mod_reg = ModuleRegistration(key_name.len, key_name[0..key_name.len].*);
                _ = &mod_reg.key_arr;
            }

            const Site = struct {
                var descriptor: module.HostOpDescriptor = .{
                    .signature = signature.get(Args),
                    .op = @intFromEnum(op),
                    .flags = raw_flags,
                    .key_ptr = if (key_name.len > 0) key_name.ptr else null,
                    .key_len = key_name.len,
                    .register_thunk = 0,
                    .arg_size = @sizeOf(Args),
                };
            };

            if (!builtin.target.cpu.arch.isWasm() and @hasDecl(host, "getTypeFactoryThunk")) {
                if (Site.descriptor.register_thunk == 0) {
                    Site.descriptor.register_thunk = @intFromPtr(host.getTypeFactoryThunk(Args));
                }
            }

            var frame: Args = undefined;
            @memset(std.mem.asBytes(&frame), 0);
            inline for (0..args_tuple.len) |i| {
                const field_name = std.fmt.comptimePrint("{d}", .{i});
                @field(frame, field_name) = args_tuple[i];
            }

            const status: E = if (@hasDecl(host, "invokeJsHostOp"))
                host.invokeJsHostOp(&Site.descriptor, @ptrCast(&frame), @sizeOf(Args))
            else
                .NOSYS;

            if (status != .SUCCESS) {
                return mapHostFailure(RT, status);
            }
            return frame.retval;
        }

        fn dispatchHostOp(
            comptime op: module.HostOp,
            comptime flags: module.HostOpFlags,
            comptime key_name: []const u8,
            comptime HostFn: type,
            args_tuple: std.meta.ArgsTuple(HostFn),
        ) FnReturnType(HostFn) {
            return dispatchHostOpRawFlags(op, @bitCast(flags), key_name, HostFn, args_tuple);
        }

        fn dispatchHostOpOptionalFlag(
            comptime op: module.HostOp,
            comptime raw_flags: u32,
            comptime PayloadT: type,
            comptime ErrSet: type,
            comptime ParamTypes: []const type,
            args_tuple: std.meta.ArgsTuple(buildFnType(ParamTypes, ErrSet!PayloadT)),
            missing_flag: *u8,
        ) ErrSet!?PayloadT {
            const HostFn = buildFnType(ParamTypes, ErrSet!PayloadT);
            const Args = arg_struct.ArgStruct(HostFn);
            const reg = TypeRegistration(Args);
            _ = reg;

            const Site = struct {
                var descriptor: module.HostOpDescriptor = .{
                    .signature = signature.get(Args),
                    .op = @intFromEnum(op),
                    .flags = raw_flags,
                    .key_ptr = null,
                    .key_len = 0,
                    .register_thunk = 0,
                    .arg_size = @sizeOf(Args),
                };
            };

            if (!builtin.target.cpu.arch.isWasm() and @hasDecl(host, "getTypeFactoryThunk")) {
                if (Site.descriptor.register_thunk == 0) {
                    Site.descriptor.register_thunk = @intFromPtr(host.getTypeFactoryThunk(Args));
                }
            }

            missing_flag.* = 0;
            var frame: Args = undefined;
            @memset(std.mem.asBytes(&frame), 0);
            inline for (0..args_tuple.len) |i| {
                const field_name = std.fmt.comptimePrint("{d}", .{i});
                @field(frame, field_name) = args_tuple[i];
            }

            const status: E = if (@hasDecl(host, "invokeJsHostOp"))
                host.invokeJsHostOp(&Site.descriptor, @ptrCast(&frame), @sizeOf(Args))
            else
                .NOSYS;

            if (status != .SUCCESS) {
                return mapHostFailure(ErrSet!?PayloadT, status);
            }
            if (missing_flag.* != 0) {
                return null;
            }
            return try frame.retval;
        }

        fn dispatchAwaitOp(
            comptime mode: module.AwaitMode,
            comptime PayloadT: type,
            comptime has_alloc: bool,
            handle: u32,
            allocator: if (has_alloc) std.mem.Allocator else void,
            done_flag_ptr: ?*u8,
        ) (if (has_alloc) module.AllocError else module.Error)!(if (mode == .async_iterator_next) ?PayloadT else PayloadT) {
            const ErrSet = if (has_alloc) module.AllocError else module.Error;
            const OutPayload = if (mode == .async_iterator_next) ?PayloadT else PayloadT;
            const OutRT = ErrSet!OutPayload;

            if (!isJsThread()) return error.OffJsThread;
            if (!@hasDecl(host, "awaitJsPromise")) return error.HostUnavailable;

            const HostFn = if (has_alloc)
                buildFnType(&.{std.mem.Allocator}, ErrSet!PayloadT)
            else
                buildFnType(&.{}, ErrSet!PayloadT);
            const Args = arg_struct.ArgStruct(HostFn);
            const reg = TypeRegistration(Args);
            _ = reg;

            const Site = struct {
                var descriptor: module.HostOpDescriptor = .{
                    .signature = signature.get(Args),
                    .op = 0,
                    .flags = 0,
                    .key_ptr = null,
                    .key_len = 0,
                    .register_thunk = 0,
                    .arg_size = @sizeOf(Args),
                };
            };

            if (!builtin.target.cpu.arch.isWasm() and @hasDecl(host, "getTypeFactoryThunk")) {
                if (Site.descriptor.register_thunk == 0) {
                    Site.descriptor.register_thunk = @intFromPtr(host.getTypeFactoryThunk(Args));
                }
            }

            if (done_flag_ptr) |ptr| {
                ptr.* = 0;
            }
            var frame: Args = undefined;
            @memset(std.mem.asBytes(&frame), 0);
            if (has_alloc) {
                frame.@"0" = allocator;
            }

            const done_addr: usize = if (done_flag_ptr) |ptr| @intFromPtr(ptr) else 0;
            const status = host.awaitJsPromise(
                handle,
                @intFromEnum(mode),
                &Site.descriptor,
                @ptrCast(&frame),
                @sizeOf(Args),
                done_addr,
            );
            if (status != .SUCCESS) {
                return mapHostFailure(OutRT, status);
            }
            if (mode == .async_iterator_next) {
                if (done_flag_ptr != null and done_flag_ptr.?.* != 0) {
                    return null;
                }
            }
            return try frame.retval;
        }

        fn dispatchWithPrependedArgs(
            comptime op: module.HostOp,
            comptime flags: module.HostOpFlags,
            comptime key_name: []const u8,
            comptime FnSig: type,
            prefix_args: anytype,
            user_args: anytype,
        ) FnReturnType(FnSig) {
            const prefix_info = @typeInfo(@TypeOf(prefix_args)).@"struct";
            comptime var prefix_types: [prefix_info.field_types.len]type = undefined;
            inline for (prefix_info.field_types, 0..) |pt, i| {
                prefix_types[i] = pt;
            }
            const HostFn = PrependParamsFn(&prefix_types, FnSig, Ref(module.Function));
            const sig_info = @typeInfo(FnSig).@"fn";
            const user_info = switch (@typeInfo(@TypeOf(user_args))) {
                .@"struct" => |si| si,
                else => @compileError("Expected tuple of arguments `.{ ... }`, received " ++ @typeName(@TypeOf(user_args))),
            };
            if (user_info.field_types.len != sig_info.param_types.len) {
                @compileError(std.fmt.comptimePrint(
                    "Expected {d} argument(s) for `{s}`, received {d}",
                    .{ sig_info.param_types.len, @typeName(FnSig), user_info.field_types.len },
                ));
            }
            const has_alloc = comptime (sig_info.param_types.len > 0 and sig_info.param_types[0].? == std.mem.Allocator);
            const extra_start: usize = if (has_alloc) 1 else 0;

            var combined: std.meta.ArgsTuple(HostFn) = undefined;
            comptime var out_idx: usize = 0;
            if (has_alloc) {
                combined[0] = coerceToParam(sig_info.param_types[0].?, user_args[0]);
                out_idx = 1;
            }
            inline for (0..prefix_info.field_types.len) |pi| {
                combined[out_idx] = prefix_args[pi];
                out_idx += 1;
            }
            inline for (extra_start..sig_info.param_types.len) |ui| {
                const RawParamT = sig_info.param_types[ui].?;
                const HostParamT = if (comptime isCallbackWrapper(RawParamT)) Ref(module.Function) else RawParamT;
                combined[out_idx] = coerceToParam(HostParamT, user_args[ui]);
                out_idx += 1;
            }
            return dispatchHostOp(op, flags, key_name, HostFn, combined);
        }

        pub fn isJsThread() bool {
            return if (@hasDecl(host, "isJsThread")) host.isJsThread() else true;
        }

        pub fn activeHandleCount() u32 {
            return host.getJsValueCount();
        }

        pub fn tryActiveHandleCount() module.Error!u32 {
            if (@hasDecl(host, "tryGetJsValueCount")) {
                return host.tryGetJsValueCount();
            }
            if (!isJsThread()) return error.OffJsThread;
            return host.getJsValueCount();
        }

        pub const JsException = struct {
            const Self = @This();

            raw: Ref(module.Any) = Ref(module.Any).@"undefined",

            pub inline fn value(self: Self) Ref(module.Any) {
                return self.raw;
            }

            pub inline fn intoValue(self: *Self) Ref(module.Any) {
                const taken = self.raw;
                self.raw = Ref(module.Any).@"undefined";
                return taken;
            }

            pub fn deinit(self: anytype) void {
                const T = @TypeOf(self);
                switch (@typeInfo(T)) {
                    .pointer => |pt| {
                        if (pt.attrs.@"const") {
                            self.raw.deinit();
                        } else {
                            const taken = self.raw;
                            self.raw = Ref(module.Any).@"undefined";
                            taken.deinit();
                        }
                    },
                    else => self.raw.deinit(),
                }
            }

            fn stringifyRefAlloc(allocator: std.mem.Allocator, val: Ref(module.Any)) module.Error![]const u8 {
                return JsNs.callMethod(
                    fn (std.mem.Allocator, Ref(module.Any)) module.Error![]const u8,
                    Ref(module.Object).globalThis,
                    "String",
                    .{ allocator, val },
                );
            }

            pub fn message(self: Self, allocator: std.mem.Allocator) module.Error!?[]const u8 {
                if (!isJsThread()) return error.OffJsThread;
                if (self.raw.isUndefined() or self.raw.isNull()) return null;
                const ty = try self.raw.tryTypeof();
                if (ty == .object or ty == .function) {
                    const prop_ref = try JsNs.getProp(module.Error!Ref(module.Any), self.raw, "message");
                    defer prop_ref.deinit();
                    if (prop_ref.isUndefined() or prop_ref.isNull()) return null;
                    return try stringifyRefAlloc(allocator, prop_ref);
                }
                return try stringifyRefAlloc(allocator, self.raw);
            }

            pub fn name(self: Self, allocator: std.mem.Allocator) module.Error!?[]const u8 {
                if (!isJsThread()) return error.OffJsThread;
                if (self.raw.isUndefined() or self.raw.isNull()) return null;
                const ty = try self.raw.tryTypeof();
                if (ty != .object and ty != .function) return null;
                const prop_ref = try JsNs.getProp(module.Error!Ref(module.Any), self.raw, "name");
                defer prop_ref.deinit();
                if ((try prop_ref.tryTypeof()) != .string) return null;
                return try stringifyRefAlloc(allocator, prop_ref);
            }

            pub fn code(self: Self, allocator: std.mem.Allocator) module.Error!?[]const u8 {
                if (!isJsThread()) return error.OffJsThread;
                if (self.raw.isUndefined() or self.raw.isNull()) return null;
                const ty = try self.raw.tryTypeof();
                if (ty != .object and ty != .function) return null;
                const prop_ref = try JsNs.getProp(module.Error!Ref(module.Any), self.raw, "code");
                defer prop_ref.deinit();
                const prop_ty = try prop_ref.tryTypeof();
                if (prop_ty != .string and prop_ty != .number and prop_ty != .bigint) return null;
                return try stringifyRefAlloc(allocator, prop_ref);
            }

            pub fn stack(self: Self, allocator: std.mem.Allocator) module.Error!?[]const u8 {
                if (!isJsThread()) return error.OffJsThread;
                if (self.raw.isUndefined() or self.raw.isNull()) return null;
                const ty = try self.raw.tryTypeof();
                if (ty != .object and ty != .function) return null;
                const prop_ref = try JsNs.getProp(module.Error!Ref(module.Any), self.raw, "stack");
                defer prop_ref.deinit();
                if ((try prop_ref.tryTypeof()) != .string) return null;
                return try stringifyRefAlloc(allocator, prop_ref);
            }
        };

        pub const CapturedError = JsException;

        fn controlLastErrorImpl(op: module.LastErrorOp) module.Error!u32 {
            if (@hasDecl(host, "tryControlLastJsError")) {
                return host.tryControlLastJsError(@intFromEnum(op));
            }
            if (!isJsThread()) return error.OffJsThread;
            if (@hasDecl(host, "controlLastJsError")) {
                return host.controlLastJsError(@intFromEnum(op));
            }
            return error.HostUnavailable;
        }

        pub fn tryLastError() module.Error!?JsException {
            const handle = try controlLastErrorImpl(.peek);
            if (handle == module.no_captured_error_handle) return null;
            return .{ .raw = .{ .handle = handle } };
        }

        pub fn lastError() ?JsException {
            const handle = controlLastErrorImpl(.peek) catch |err| switch (err) {
                error.OffJsThread => @panic("JsValue operations require the JS thread"),
                else => return null,
            };
            if (handle == module.no_captured_error_handle) return null;
            return .{ .raw = .{ .handle = handle } };
        }

        pub fn tryTakeLastError() module.Error!?JsException {
            const handle = try controlLastErrorImpl(.take);
            if (handle == module.no_captured_error_handle) return null;
            return .{ .raw = .{ .handle = handle } };
        }

        pub fn takeLastError() ?JsException {
            const handle = controlLastErrorImpl(.take) catch |err| switch (err) {
                error.OffJsThread => @panic("JsValue operations require the JS thread"),
                else => return null,
            };
            if (handle == module.no_captured_error_handle) return null;
            return .{ .raw = .{ .handle = handle } };
        }

        pub fn tryHasLastError() module.Error!bool {
            return (try controlLastErrorImpl(.has)) != 0;
        }

        pub fn hasLastError() bool {
            const res = controlLastErrorImpl(.has) catch |err| switch (err) {
                error.OffJsThread => @panic("JsValue operations require the JS thread"),
                else => return false,
            };
            return res != 0;
        }

        pub fn tryClearLastError() module.Error!void {
            _ = try controlLastErrorImpl(.clear);
        }

        pub fn clearLastError() void {
            _ = controlLastErrorImpl(.clear) catch |err| switch (err) {
                error.OffJsThread => @panic("JsValue operations require the JS thread"),
                else => {},
            };
        }

        pub fn dispose(resource: anytype) void {
            const r: Ref(module.Any) = .{ .handle = extractHandle(resource) };
            r.dispose();
        }

        pub fn tryDispose(resource: anytype) module.Error!void {
            const r: Ref(module.Any) = .{ .handle = extractHandle(resource) };
            return r.tryDispose();
        }

        pub fn asyncDispose(resource: anytype) void {
            const r: Ref(module.Any) = .{ .handle = extractHandle(resource) };
            r.asyncDispose();
        }

        pub fn tryAsyncDispose(resource: anytype) module.Error!void {
            const r: Ref(module.Any) = .{ .handle = extractHandle(resource) };
            return r.tryAsyncDispose();
        }

        pub fn openIterator(comptime ElemT: type, target: anytype) module.CallError!Iterator(ElemT) {
            return try Iterator(ElemT).from(target);
        }

        pub fn openAsyncIterator(comptime ElemT: type, target: anytype) module.CallError!AsyncIterator(ElemT) {
            return try AsyncIterator(ElemT).from(target);
        }

        fn PromisePayloadOf(comptime P: type) type {
            if (@typeInfo(P) == .@"struct" and @hasDecl(P, "is_js_promise") and P.is_js_promise and @hasDecl(P, "Payload")) {
                return P.Payload;
            }
            @compileError("Expected a js.Promise(T) type in promiseAll, received " ++ @typeName(P));
        }

        pub fn PromiseAllResult(comptime PromisesT: type) type {
            return switch (@typeInfo(PromisesT)) {
                .@"struct" => |st| blk: {
                    comptime var payloads: [st.field_types.len]type = undefined;
                    for (st.field_types, 0..) |FT, i| {
                        payloads[i] = PromisePayloadOf(FT);
                    }
                    break :blk @Tuple(&payloads);
                },
                .array => |ar| [ar.len]PromisePayloadOf(ar.child),
                .pointer => |pt| switch (pt.size) {
                    .slice => []PromisePayloadOf(pt.child),
                    .one => if (@typeInfo(pt.child) == .array)
                        [@typeInfo(pt.child).array.len]PromisePayloadOf(@typeInfo(pt.child).array.child)
                    else
                        @compileError("Unsupported pointer input to promiseAll: " ++ @typeName(PromisesT)),
                    else => @compileError("Unsupported pointer input to promiseAll: " ++ @typeName(PromisesT)),
                },
                else => @compileError("Expected tuple, array, or slice of js.Promise(T) in promiseAll, received " ++ @typeName(PromisesT)),
            };
        }

        fn promiseAllNeedsAllocator(comptime PromisesT: type) bool {
            return switch (@typeInfo(PromisesT)) {
                .@"struct" => |st| blk: {
                    for (st.field_types) |FT| {
                        if (needsDecodeAllocator(PromisePayloadOf(FT))) break :blk true;
                    }
                    break :blk false;
                },
                .array => |ar| needsDecodeAllocator(PromisePayloadOf(ar.child)),
                .pointer => |pt| switch (pt.size) {
                    .slice => true,
                    .one => if (@typeInfo(pt.child) == .array)
                        needsDecodeAllocator(PromisePayloadOf(@typeInfo(pt.child).array.child))
                    else
                        true,
                    else => true,
                },
                else => true,
            };
        }

        pub fn promiseAllAlloc(
            allocator: std.mem.Allocator,
            promises: anytype,
        ) module.CallError!PromiseAllResult(@TypeOf(promises)) {
            const PromisesT = @TypeOf(promises);
            const OutT = PromiseAllResult(PromisesT);
            switch (@typeInfo(PromisesT)) {
                .@"struct" => |st| {
                    const count = st.field_types.len;
                    if (comptime count == 0) {
                        var empty_out: OutT = undefined;
                        _ = &empty_out;
                        return empty_out;
                    }
                    const js_arr = try Array(Ref(module.Any)).withCapacity(count);
                    defer js_arr.deinit();
                    inline for (0..count) |i| {
                        try js_arr.set(i, promises[i].toRef().cast(module.Any));
                    }
                    const promise_ctor = try getGlobal(module.CallError!Ref(module.Any), "Promise");
                    defer promise_ctor.deinit();
                    const combined = try callMethod(
                        fn (Array(Ref(module.Any))) module.CallError!Promise(Ref(module.Any)),
                        promise_ctor,
                        "all",
                        .{js_arr},
                    );
                    defer combined.deinit();
                    const res_ref = try combined.@"await"();
                    defer res_ref.deinit();
                    const res_arr = Array(Ref(module.Any)).fromRef(res_ref);
                    var out: OutT = undefined;
                    var decoded_mask: [count]bool = @splat(false);
                    errdefer {
                        inline for (0..count) |i| {
                            if (decoded_mask[i]) {
                                const ElemPayload = PromisePayloadOf(st.field_types[i]);
                                freeDecoded(ElemPayload, allocator, out[i]);
                            }
                        }
                    }
                    inline for (0..count) |i| {
                        const ElemPayload = PromisePayloadOf(st.field_types[i]);
                        const elem_ref = try res_arr.get(i);
                        defer elem_ref.deinit();
                        out[i] = try fromJsRefAlloc(ElemPayload, allocator, elem_ref);
                        decoded_mask[i] = true;
                    }
                    return out;
                },
                .array => |ar| {
                    const ElemPayload = PromisePayloadOf(ar.child);
                    if (comptime ar.len == 0) return .{};
                    const js_arr = try Array(Ref(module.Any)).withCapacity(ar.len);
                    defer js_arr.deinit();
                    for (promises, 0..) |p, i| {
                        try js_arr.set(i, p.toRef().cast(module.Any));
                    }
                    const promise_ctor = try getGlobal(module.CallError!Ref(module.Any), "Promise");
                    defer promise_ctor.deinit();
                    const combined = try callMethod(
                        fn (Array(Ref(module.Any))) module.CallError!Promise(Ref(module.Any)),
                        promise_ctor,
                        "all",
                        .{js_arr},
                    );
                    defer combined.deinit();
                    const res_ref = try combined.@"await"();
                    defer res_ref.deinit();
                    const res_arr = Array(Ref(module.Any)).fromRef(res_ref);
                    var out: OutT = undefined;
                    var initialized: usize = 0;
                    errdefer {
                        for (out[0..initialized]) |elem| {
                            freeDecoded(ElemPayload, allocator, elem);
                        }
                    }
                    while (initialized < ar.len) : (initialized += 1) {
                        const elem_ref = try res_arr.get(initialized);
                        defer elem_ref.deinit();
                        out[initialized] = try fromJsRefAlloc(ElemPayload, allocator, elem_ref);
                    }
                    return out;
                },
                .pointer => |pt| switch (pt.size) {
                    .one => return promiseAllAlloc(allocator, promises.*),
                    .slice => {
                        const ElemPayload = PromisePayloadOf(pt.child);
                        if (promises.len == 0) return try allocator.alloc(ElemPayload, 0);
                        const js_arr = try Array(Ref(module.Any)).withCapacity(promises.len);
                        defer js_arr.deinit();
                        for (promises, 0..) |p, i| {
                            try js_arr.set(i, p.toRef().cast(module.Any));
                        }
                        const promise_ctor = try getGlobal(module.CallError!Ref(module.Any), "Promise");
                        defer promise_ctor.deinit();
                        const combined = try callMethod(
                            fn (Array(Ref(module.Any))) module.CallError!Promise(Ref(module.Any)),
                            promise_ctor,
                            "all",
                            .{js_arr},
                        );
                        defer combined.deinit();
                        const res_ref = try combined.@"await"();
                        defer res_ref.deinit();
                        const res_arr = Array(Ref(module.Any)).fromRef(res_ref);
                        const out = try allocator.alloc(ElemPayload, promises.len);
                        var initialized: usize = 0;
                        errdefer {
                            for (out[0..initialized]) |elem| {
                                freeDecoded(ElemPayload, allocator, elem);
                            }
                            allocator.free(out);
                        }
                        while (initialized < promises.len) : (initialized += 1) {
                            const elem_ref = try res_arr.get(initialized);
                            defer elem_ref.deinit();
                            out[initialized] = try fromJsRefAlloc(ElemPayload, allocator, elem_ref);
                        }
                        return out;
                    },
                    else => unreachable,
                },
                else => unreachable,
            }
        }

        pub fn promiseAll(promises: anytype) module.CallError!PromiseAllResult(@TypeOf(promises)) {
            if (comptime promiseAllNeedsAllocator(@TypeOf(promises))) {
                if (@hasDecl(host, "default_allocator")) {
                    return promiseAllAlloc(host.default_allocator, promises);
                }
                return error.HostUnavailable;
            }
            var stack_buf: [512]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
            return promiseAllAlloc(fba.allocator(), promises);
        }

        pub inline fn global() Ref(module.Object) {
            return Ref(module.Object).globalThis;
        }

        pub fn getGlobal(comptime RT: type, comptime name: []const u8) RT {
            const HostFn = buildFnType(&.{}, RT);
            return dispatchHostOp(.get_global, .{}, name, HostFn, .{});
        }

        pub fn getGlobalAlloc(allocator: std.mem.Allocator, comptime RT: type, comptime name: []const u8) RT {
            const HostFn = buildFnType(&.{std.mem.Allocator}, RT);
            return dispatchHostOp(.get_global, .{}, name, HostFn, .{allocator});
        }

        pub fn getGlobalDynamic(comptime RT: type, key: anytype) RT {
            const KeyT = DynamicKeyArgType(@TypeOf(key));
            const HostFn = buildFnType(&.{KeyT}, RT);
            return dispatchHostOp(.get_global, .{ .dynamic_key = true }, "", HostFn, .{coerceDynamicKey(key)});
        }

        pub fn importModuleAs(comptime RT: type, comptime specifier: []const u8) RT {
            const HostFn = buildFnType(&.{}, RT);
            return dispatchHostOp(.import_module, .{}, specifier, HostFn, .{});
        }

        pub fn importModuleDefaultAs(comptime RT: type, comptime specifier: []const u8) RT {
            const HostFn = buildFnType(&.{}, RT);
            return dispatchHostOp(.import_module, .{ .module_default = true }, specifier, HostFn, .{});
        }

        pub fn importModuleDefaultAllocAs(allocator: std.mem.Allocator, comptime RT: type, comptime specifier: []const u8) RT {
            const HostFn = buildFnType(&.{std.mem.Allocator}, RT);
            return dispatchHostOp(.import_module, .{ .module_default = true }, specifier, HostFn, .{allocator});
        }

        pub fn importModule(comptime specifier: []const u8) module.CallError!Ref(module.Object) {
            return importModuleAs(module.CallError!Ref(module.Object), specifier);
        }

        pub fn importModuleDynamicAs(comptime RT: type, specifier: []const u8) RT {
            const HostFn = buildFnType(&.{[]const u8}, RT);
            return dispatchHostOp(.import_module, .{ .dynamic_key = true }, "", HostFn, .{specifier});
        }

        pub fn importModuleDynamic(specifier: []const u8) module.CallError!Ref(module.Object) {
            return importModuleDynamicAs(module.CallError!Ref(module.Object), specifier);
        }

        pub fn tryImportModule(comptime specifier: []const u8) module.CallError!Ref(module.Object) {
            return importModule(specifier);
        }

        pub fn Module(comptime specifier: []const u8) type {
            return struct {
                const ModNs = @This();
                pub const module_specifier = specifier;
                pub const is_js_module_descriptor = true;

                fn resolveAs(comptime ESet: type) ESet!Ref(module.Object) {
                    return JsNs.importModuleAs(ESet!Ref(module.Object), specifier);
                }

                pub fn resolve() module.CallError!Ref(module.Object) {
                    return JsNs.importModule(specifier);
                }

                pub fn namespace() module.CallError!Ref(module.Object) {
                    return resolve();
                }

                pub fn default(comptime RT: type) EnsureErrorReturn(RT) {
                    return JsNs.importModuleDefaultAs(EnsureErrorReturn(RT), specifier);
                }

                pub fn defaultAlloc(allocator: std.mem.Allocator, comptime RT: type) EnsureErrorReturn(RT) {
                    return JsNs.importModuleDefaultAllocAs(allocator, EnsureErrorReturn(RT), specifier);
                }

                pub fn callDefault(comptime FnSig: type, args: anytype) EnsureErrorReturn(FnReturnType(FnSig)) {
                    const ESet = ErrorSetOf(FnReturnType(FnSig));
                    const callee = try JsNs.importModuleDefaultAs(ESet!Ref(module.Function), specifier);
                    defer callee.deinit();
                    return JsNs.callFn(WrapFnWithCallError(FnSig), callee, args);
                }

                pub fn callExportEquals(comptime FnSig: type, args: anytype) EnsureErrorReturn(FnReturnType(FnSig)) {
                    return ModNs.callDefault(FnSig, args);
                }

                pub fn constructDefault(comptime CtorSig: type, args: anytype) EnsureErrorReturn(FnReturnType(CtorSig)) {
                    const ESet = ErrorSetOf(FnReturnType(CtorSig));
                    const ctor = try JsNs.importModuleDefaultAs(ESet!Ref(module.Function), specifier);
                    defer ctor.deinit();
                    return JsNs.construct(WrapFnWithCallError(CtorSig), ctor, args);
                }

                pub fn constructExportEquals(comptime CtorSig: type, args: anytype) EnsureErrorReturn(FnReturnType(CtorSig)) {
                    return ModNs.constructDefault(CtorSig, args);
                }

                pub fn getProp(comptime RT: type, comptime name: []const u8) EnsureErrorReturn(RT) {
                    const ESet = ErrorSetOf(RT);
                    const mod = try resolveAs(ESet);
                    defer mod.deinit();
                    return JsNs.getProp(EnsureErrorReturn(RT), mod, name);
                }

                pub fn get(comptime RT: type, comptime name: []const u8) EnsureErrorReturn(RT) {
                    return ModNs.getProp(RT, name);
                }

                pub fn getAlloc(allocator: std.mem.Allocator, comptime RT: type, comptime name: []const u8) EnsureErrorReturn(RT) {
                    const ESet = ErrorSetOf(RT);
                    const mod = try resolveAs(ESet);
                    defer mod.deinit();
                    return JsNs.getPropAlloc(allocator, EnsureErrorReturn(RT), mod, name);
                }

                pub fn set(comptime name: []const u8, value: anytype) module.CallError!void {
                    const mod = try resolve();
                    defer mod.deinit();
                    try JsNs.trySetProp(mod, name, value);
                }

                pub fn has(comptime name: []const u8) module.CallError!bool {
                    const mod = try resolve();
                    defer mod.deinit();
                    return JsNs.tryHasProp(mod, name);
                }

                pub fn delete(comptime name: []const u8) module.CallError!bool {
                    const mod = try resolve();
                    defer mod.deinit();
                    return JsNs.tryDeleteProp(mod, name);
                }

                pub fn call(comptime FnSig: type, comptime name: []const u8, args: anytype) EnsureErrorReturn(FnReturnType(FnSig)) {
                    const ESet = ErrorSetOf(FnReturnType(FnSig));
                    const mod = try resolveAs(ESet);
                    defer mod.deinit();
                    return JsNs.callMethod(WrapFnWithCallError(FnSig), mod, name, args);
                }

                pub fn construct(comptime CtorSig: type, comptime name: []const u8, args: anytype) EnsureErrorReturn(FnReturnType(CtorSig)) {
                    const ESet = ErrorSetOf(FnReturnType(CtorSig));
                    const ctor = try ModNs.getProp(ESet!Ref(module.Function), name);
                    defer ctor.deinit();
                    return JsNs.construct(WrapFnWithCallError(CtorSig), ctor, args);
                }
            };
        }

        fn ErrorSetOf(comptime T: type) type {
            return switch (@typeInfo(T)) {
                .error_union => |eu| eu.error_set,
                else => module.CallError,
            };
        }

        fn EnsureErrorReturn(comptime RT: type) type {
            return switch (@typeInfo(RT)) {
                .error_union => RT,
                else => module.CallError!RT,
            };
        }

        fn EnsureJsErrorReturn(comptime RT: type) type {
            return switch (@typeInfo(RT)) {
                .error_union => RT,
                else => module.Error!RT,
            };
        }

        fn WrapFnWithJsError(comptime FnSig: type) type {
            const f = @typeInfo(FnSig).@"fn";
            const rt = f.return_type orelse void;
            if (@typeInfo(rt) == .error_union) return FnSig;
            var param_types: [f.param_types.len]type = undefined;
            var param_attrs: [f.param_types.len]std.lang.Type.Fn.ParamAttributes = undefined;
            for (f.param_types, 0..) |pt, i| {
                param_types[i] = pt.?;
                param_attrs[i] = .{};
            }
            return @Fn(&param_types, &param_attrs, module.Error!rt, .{});
        }

        fn WrapFnWithCallError(comptime FnSig: type) type {
            const f = @typeInfo(FnSig).@"fn";
            const rt = f.return_type orelse void;
            if (@typeInfo(rt) == .error_union) return FnSig;
            var param_types: [f.param_types.len]type = undefined;
            var param_attrs: [f.param_types.len]std.lang.Type.Fn.ParamAttributes = undefined;
            for (f.param_types, 0..) |pt, i| {
                param_types[i] = pt.?;
                param_attrs[i] = .{};
            }
            return @Fn(&param_types, &param_attrs, module.CallError!rt, .{});
        }

        pub fn getProp(comptime RT: type, target: anytype, comptime name: []const u8) RT {
            const HostFn = buildFnType(&.{Ref(module.Any)}, RT);
            return dispatchHostOp(.get_prop, .{}, name, HostFn, .{.{ .handle = extractHandle(target) }});
        }

        pub fn getPropAlloc(allocator: std.mem.Allocator, comptime RT: type, target: anytype, comptime name: []const u8) RT {
            const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any) }, RT);
            return dispatchHostOp(.get_prop, .{}, name, HostFn, .{ allocator, .{ .handle = extractHandle(target) } });
        }

        pub fn getPropDynamic(comptime RT: type, target: anytype, key: anytype) RT {
            const KeyT = DynamicKeyArgType(@TypeOf(key));
            const HostFn = buildFnType(&.{ Ref(module.Any), KeyT }, RT);
            return dispatchHostOp(.get_prop, .{ .dynamic_key = true }, "", HostFn, .{
                .{ .handle = extractHandle(target) },
                coerceDynamicKey(key),
            });
        }

        pub fn getPropDynamicAlloc(allocator: std.mem.Allocator, comptime RT: type, target: anytype, key: anytype) RT {
            const KeyT = DynamicKeyArgType(@TypeOf(key));
            const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any), KeyT }, RT);
            return dispatchHostOp(.get_prop, .{ .dynamic_key = true }, "", HostFn, .{
                allocator,
                .{ .handle = extractHandle(target) },
                coerceDynamicKey(key),
            });
        }

        pub fn getPropSym(comptime RT: type, target: anytype, sym: anytype) RT {
            return getPropDynamic(RT, target, sym);
        }

        pub fn setPropAs(comptime RT: type, target: anytype, comptime name: []const u8, value: anytype) RT {
            const ValT = NormalizedValueType(@TypeOf(value));
            const HostFn = buildFnType(&.{ Ref(module.Any), ValT }, RT);
            return dispatchHostOp(.set_prop, .{}, name, HostFn, .{
                .{ .handle = extractHandle(target) },
                normalizeValue(value),
            });
        }

        pub fn setProp(target: anytype, comptime name: []const u8, value: anytype) void {
            setPropAs(void, target, name, value);
        }

        pub fn trySetProp(target: anytype, comptime name: []const u8, value: anytype) module.CallError!void {
            return setPropAs(module.CallError!void, target, name, value);
        }

        pub fn setPropDynamicAs(comptime RT: type, target: anytype, key: anytype, value: anytype) RT {
            const KeyT = DynamicKeyArgType(@TypeOf(key));
            const ValT = NormalizedValueType(@TypeOf(value));
            const HostFn = buildFnType(&.{ Ref(module.Any), KeyT, ValT }, RT);
            return dispatchHostOp(.set_prop, .{ .dynamic_key = true }, "", HostFn, .{
                .{ .handle = extractHandle(target) },
                coerceDynamicKey(key),
                normalizeValue(value),
            });
        }

        pub fn setPropDynamic(target: anytype, key: anytype, value: anytype) void {
            setPropDynamicAs(void, target, key, value);
        }

        pub fn trySetPropDynamic(target: anytype, key: anytype, value: anytype) module.CallError!void {
            return setPropDynamicAs(module.CallError!void, target, key, value);
        }

        pub fn setPropSym(target: anytype, sym: anytype, value: anytype) void {
            setPropDynamic(target, sym, value);
        }

        pub fn deletePropAs(comptime RT: type, target: anytype, comptime name: []const u8) RT {
            const HostFn = buildFnType(&.{Ref(module.Any)}, RT);
            return dispatchHostOp(.delete_prop, .{}, name, HostFn, .{.{ .handle = extractHandle(target) }});
        }

        pub fn deleteProp(target: anytype, comptime name: []const u8) bool {
            return deletePropAs(bool, target, name);
        }

        pub fn tryDeleteProp(target: anytype, comptime name: []const u8) module.CallError!bool {
            return deletePropAs(module.CallError!bool, target, name);
        }

        pub fn deletePropDynamicAs(comptime RT: type, target: anytype, key: anytype) RT {
            const KeyT = DynamicKeyArgType(@TypeOf(key));
            const HostFn = buildFnType(&.{ Ref(module.Any), KeyT }, RT);
            return dispatchHostOp(.delete_prop, .{ .dynamic_key = true }, "", HostFn, .{
                .{ .handle = extractHandle(target) },
                coerceDynamicKey(key),
            });
        }

        pub fn deletePropDynamic(target: anytype, key: anytype) bool {
            return deletePropDynamicAs(bool, target, key);
        }

        pub fn tryDeletePropDynamic(target: anytype, key: anytype) module.CallError!bool {
            return deletePropDynamicAs(module.CallError!bool, target, key);
        }

        pub fn hasPropAs(comptime RT: type, target: anytype, comptime name: []const u8) RT {
            const HostFn = buildFnType(&.{Ref(module.Any)}, RT);
            return dispatchHostOp(.has_prop, .{}, name, HostFn, .{.{ .handle = extractHandle(target) }});
        }

        pub fn hasProp(target: anytype, comptime name: []const u8) bool {
            return hasPropAs(bool, target, name);
        }

        pub fn tryHasProp(target: anytype, comptime name: []const u8) module.CallError!bool {
            return hasPropAs(module.CallError!bool, target, name);
        }

        pub fn hasPropDynamicAs(comptime RT: type, target: anytype, key: anytype) RT {
            const KeyT = DynamicKeyArgType(@TypeOf(key));
            const HostFn = buildFnType(&.{ Ref(module.Any), KeyT }, RT);
            return dispatchHostOp(.has_prop, .{ .dynamic_key = true }, "", HostFn, .{
                .{ .handle = extractHandle(target) },
                coerceDynamicKey(key),
            });
        }

        pub fn hasPropDynamic(target: anytype, key: anytype) bool {
            return hasPropDynamicAs(bool, target, key);
        }

        pub fn tryHasPropDynamic(target: anytype, key: anytype) module.CallError!bool {
            return hasPropDynamicAs(module.CallError!bool, target, key);
        }

        pub fn callFn(comptime FnSig: type, callee: anytype, args: anytype) FnReturnType(FnSig) {
            return dispatchWithPrependedArgs(
                .call_fn,
                .{},
                "",
                FnSig,
                .{@as(Ref(module.Any), .{ .handle = extractHandle(callee) })},
                args,
            );
        }

        pub fn callMethod(comptime FnSig: type, receiver: anytype, comptime name: []const u8, args: anytype) FnReturnType(FnSig) {
            return dispatchWithPrependedArgs(
                .call_method,
                .{},
                name,
                FnSig,
                .{@as(Ref(module.Any), .{ .handle = extractHandle(receiver) })},
                args,
            );
        }

        pub fn callMethodDynamic(comptime FnSig: type, receiver: anytype, key: anytype, args: anytype) FnReturnType(FnSig) {
            return dispatchWithPrependedArgs(
                .call_method,
                .{ .dynamic_key = true },
                "",
                FnSig,
                .{
                    @as(Ref(module.Any), .{ .handle = extractHandle(receiver) }),
                    coerceDynamicKey(key),
                },
                args,
            );
        }

        pub fn callMethodSym(comptime FnSig: type, receiver: anytype, sym: anytype, args: anytype) FnReturnType(FnSig) {
            return callMethodDynamic(FnSig, receiver, sym, args);
        }

        pub fn construct(comptime CtorSig: type, ctor: anytype, args: anytype) FnReturnType(CtorSig) {
            return dispatchWithPrependedArgs(
                .construct,
                .{},
                "",
                CtorSig,
                .{@as(Ref(module.Any), .{ .handle = extractHandle(ctor) })},
                args,
            );
        }

        const CallbackRegistry = struct {
            const slab_capacity: usize = 64;
            const initial_table_capacity: usize = 16;
            const null_index: u32 = std.math.maxInt(u32);
            const max_slot_index: u32 = (1 << 20) - 2;
            const max_generation: u16 = 0x0FFF;
            const InvokerFn = *const fn (*anyopaque, *anyopaque) anyerror!void;
            const DeinitCtxFn = *const fn (*anyopaque) void;

            const SlotEntry = struct {
                ctx_ptr: *anyopaque = undefined,
                invoker: ?InvokerFn = null,
                deinit_ctx: ?DeinitCtxFn = null,
                sig_hash: u64 = 0,
                fn_handle: u32 = module.reserved_undefined_handle,
                generation: u16 = 1,
                active_calls: u32 = 0,
                once: bool = false,
                pending_release: bool = false,
                next_free: u32 = null_index,
            };

            const Slab = struct {
                entries: [slab_capacity]SlotEntry = @splat(.{}),
            };

            var inline_slab: Slab = .{};
            var inline_slab_table: [initial_table_capacity]*Slab = init: {
                var table: [initial_table_capacity]*Slab = undefined;
                table[0] = &inline_slab;
                break :init table;
            };
            var slabs: []*Slab = inline_slab_table[0..];
            var slabs_heap_allocated: bool = false;
            var slab_count: usize = 1;
            var high_water_in_tail: usize = 0;
            var free_head: u32 = null_index;
            var free_tail: u32 = null_index;
            var active_count: u32 = 0;

            fn backingAllocator() std.mem.Allocator {
                if (@hasDecl(host, "default_allocator")) {
                    return host.default_allocator;
                }
                if (builtin.target.cpu.arch.isWasm()) {
                    return std.heap.wasm_allocator;
                }
                return std.heap.page_allocator;
            }

            fn entryAt(slot_index: u32) ?*SlotEntry {
                const slab_idx: usize = @intCast(slot_index / slab_capacity);
                if (slab_idx >= slab_count) return null;
                const offset: usize = @intCast(slot_index % slab_capacity);
                return &slabs[slab_idx].entries[offset];
            }

            fn allocate(ctx_ptr: *anyopaque, invoker: InvokerFn, deinit_ctx: ?DeinitCtxFn, is_once: bool, sig_hash: u64) !u32 {
                var slot_index: u32 = undefined;
                var entry_ptr: *SlotEntry = undefined;

                if (free_head != null_index) {
                    slot_index = free_head;
                    entry_ptr = entryAt(slot_index) orelse return error.Unexpected;
                    free_head = entry_ptr.next_free;
                    if (free_head == null_index) {
                        free_tail = null_index;
                    }
                    entry_ptr.next_free = null_index;
                } else {
                    if (high_water_in_tail >= slab_capacity) {
                        const next_global_usize: usize = slab_count * slab_capacity;
                        if (next_global_usize > max_slot_index) return error.OutOfMemory;
                        const alloc = backingAllocator();
                        if (slab_count >= slabs.len) {
                            const max_slabs: usize = @intCast((max_slot_index / slab_capacity) + 1);
                            const new_cap = @min(slabs.len * 2, max_slabs);
                            if (new_cap <= slab_count) return error.OutOfMemory;
                            const new_table = try alloc.alloc(*Slab, new_cap);
                            @memcpy(new_table[0..slab_count], slabs[0..slab_count]);
                            if (slabs_heap_allocated) {
                                alloc.free(slabs);
                            }
                            slabs = new_table;
                            slabs_heap_allocated = true;
                        }
                        const new_slab = try alloc.create(Slab);
                        new_slab.* = .{};
                        slabs[slab_count] = new_slab;
                        slab_count += 1;
                        high_water_in_tail = 0;
                    }
                    slot_index = @as(u32, @intCast((slab_count - 1) * slab_capacity + high_water_in_tail));
                    if (slot_index > max_slot_index) return error.OutOfMemory;
                    entry_ptr = &slabs[slab_count - 1].entries[high_water_in_tail];
                    high_water_in_tail += 1;
                }

                entry_ptr.ctx_ptr = ctx_ptr;
                entry_ptr.invoker = invoker;
                entry_ptr.deinit_ctx = deinit_ctx;
                entry_ptr.sig_hash = sig_hash;
                entry_ptr.fn_handle = module.reserved_undefined_handle;
                entry_ptr.active_calls = 0;
                entry_ptr.once = is_once;
                entry_ptr.pending_release = false;
                entry_ptr.next_free = null_index;
                active_count += 1;

                const gen12: u32 = @as(u32, entry_ptr.generation & 0x0FFF);
                return (gen12 << 20) | (slot_index + 1);
            }

            fn setHandle(callback_id: u32, handle: u32) void {
                if (resolve(callback_id)) |resolved| {
                    resolved.entry.fn_handle = handle;
                }
            }

            fn isActive(callback_id: u32) bool {
                return resolve(callback_id) != null;
            }

            const ResolvedSlot = struct {
                slot_index: u32,
                entry: *SlotEntry,
            };

            fn resolve(callback_id: u32) ?ResolvedSlot {
                const raw = callback_id & 0x000F_FFFF;
                if (raw == 0) return null;
                const slot_index = raw - 1;
                const gen12: u16 = @intCast((callback_id >> 20) & 0x0FFF);
                if (gen12 == 0) return null;
                const entry = entryAt(slot_index) orelse return null;
                if (entry.generation == 0 or entry.invoker == null or entry.pending_release) return null;
                if ((entry.generation & 0x0FFF) != gen12) return null;
                return .{ .slot_index = slot_index, .entry = entry };
            }

            fn finalizeSlotRelease(slot_index: u32, entry: *SlotEntry) void {
                const deinit_ctx = entry.deinit_ctx;
                const ctx_ptr = entry.ctx_ptr;
                entry.deinit_ctx = null;
                entry.ctx_ptr = undefined;
                entry.sig_hash = 0;
                entry.fn_handle = module.reserved_undefined_handle;
                entry.once = false;
                entry.pending_release = false;
                entry.next_free = null_index;
                if (entry.generation != 0) {
                    if (free_tail != null_index) {
                        if (entryAt(free_tail)) |tail_entry| {
                            tail_entry.next_free = slot_index;
                        }
                        free_tail = slot_index;
                    } else {
                        free_head = slot_index;
                        free_tail = slot_index;
                    }
                }
                if (deinit_ctx) |cleanup| {
                    cleanup(ctx_ptr);
                }
            }

            fn finishCall(slot_index: u32, entry: *SlotEntry) void {
                entry.active_calls -= 1;
                if (entry.active_calls == 0 and entry.pending_release) {
                    finalizeSlotRelease(slot_index, entry);
                }
            }

            fn release(callback_id: u32) bool {
                const raw = callback_id & 0x000F_FFFF;
                if (raw == 0) return false;
                const slot_index = raw - 1;
                const gen12: u16 = @intCast((callback_id >> 20) & 0x0FFF);
                if (gen12 == 0) return false;
                const entry = entryAt(slot_index) orelse return false;
                if (entry.generation == 0 or entry.invoker == null or entry.pending_release or (entry.generation & 0x0FFF) != gen12) return false;

                entry.invoker = null;
                entry.sig_hash = 0;
                // Permanently retire slots once their 12-bit generation reaches 0x0FFF (4095)
                // so a (gen, slot) CallbackId can never wrap around and alias a future callback.
                entry.generation = if (entry.generation >= max_generation) 0 else (entry.generation + 1);
                active_count -= 1;

                if (entry.active_calls > 0) {
                    entry.pending_release = true;
                } else {
                    finalizeSlotRelease(slot_index, entry);
                }
                return true;
            }
        };

        /// Intern table for runtime stateless `*const fn` addresses so persistent/async
        /// stateless function pointers can pass a compact 32-bit `id` across host-op ABI
        /// without consuming `CallbackRegistry` slots or user-tracked heap allocations.
        const StatelessFnPtrRegistry = struct {
            const inline_cap: u32 = 256;
            var inline_addrs: [inline_cap]usize = @splat(0);
            var inline_count: u32 = 0;
            var overflow_addrs: []usize = &.{};
            var overflow_len: u32 = 0;

            fn backingAllocator() std.mem.Allocator {
                return if (builtin.target.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;
            }

            fn intern(addr: usize) error{OutOfMemory}!u32 {
                var i: u32 = 0;
                while (i < inline_count) : (i += 1) {
                    if (inline_addrs[i] == addr) return i + 1;
                }
                var j: u32 = 0;
                while (j < overflow_len) : (j += 1) {
                    if (overflow_addrs[j] == addr) return inline_cap + j + 1;
                }
                if (inline_count < inline_cap) {
                    const id = inline_count + 1;
                    inline_addrs[inline_count] = addr;
                    inline_count += 1;
                    return id;
                }
                if (overflow_len >= overflow_addrs.len) {
                    const alloc = backingAllocator();
                    const new_cap: usize = if (overflow_addrs.len == 0) 256 else overflow_addrs.len * 2;
                    if (new_cap + inline_cap >= std.math.maxInt(u32)) return error.OutOfMemory;
                    const new_buf = try alloc.alloc(usize, new_cap);
                    if (overflow_len > 0) {
                        @memcpy(new_buf[0..overflow_len], overflow_addrs[0..overflow_len]);
                        alloc.free(overflow_addrs);
                    }
                    overflow_addrs = new_buf;
                }
                const id = inline_cap + overflow_len + 1;
                overflow_addrs[overflow_len] = addr;
                overflow_len += 1;
                return id;
            }

            fn lookup(id: u32) ?usize {
                if (id == 0) return null;
                const idx = id - 1;
                if (idx < inline_count) return inline_addrs[idx];
                if (idx < inline_cap) return null;
                const ov_idx = idx - inline_cap;
                if (ov_idx < overflow_len) return overflow_addrs[ov_idx];
                return null;
            }
        };

        fn cancelCallbackThunk(raw_id_ptr: *const anyopaque, _: *anyopaque) anyerror!void {
            const callback_id: u32 = @truncate(@intFromPtr(raw_id_ptr));
            const fn_handle = if (CallbackRegistry.resolve(callback_id)) |r| r.entry.fn_handle else module.reserved_undefined_handle;
            if (CallbackRegistry.release(callback_id)) {
                if (@hasDecl(host, "releaseZigCallback")) {
                    host.releaseZigCallback(callback_id);
                } else if (fn_handle > module.reserved_global_this_handle) {
                    host.releaseJsValue(fn_handle);
                }
            }
        }

        pub fn activeCallbackCount() u32 {
            return CallbackRegistry.active_count;
        }

        pub fn Callback(comptime JsFnSig: type) type {
            return CallbackWithOptions(JsFnSig, .{});
        }

        pub fn AsyncCallback(comptime JsFnSig: type) type {
            return CallbackWithOptions(JsFnSig, .{ .async_call = true });
        }

        fn isValidatedProtocolJsValue(comptime T: type) bool {
            if (@typeInfo(T) != .@"struct") return false;
            return (@hasDecl(T, "is_js_iterator") and T.is_js_iterator) or
                (@hasDecl(T, "is_js_async_iterator") and T.is_js_async_iterator) or
                (@hasDecl(T, "is_js_disposable") and T.is_js_disposable) or
                (@hasDecl(T, "is_js_async_disposable") and T.is_js_async_disposable) or
                (@hasDecl(T, "is_js_promise") and T.is_js_promise);
        }

        fn typeNeedsRefDecode(comptime T: type, comptime depth: usize) bool {
            if (depth >= 16 or T == void) return false;
            if (comptime util.getInternalType(T) == .js_value) return isValidatedProtocolJsValue(T);
            if (comptime isNullableType(T)) return true;
            return switch (@typeInfo(T)) {
                .optional => |op| typeNeedsRefDecode(op.child, depth + 1),
                .@"struct" => |st| blk: {
                    if (isTupleStructType(T) or module.hasStructZigarJsMeta(T)) break :blk true;
                    for (st.field_types) |ft| {
                        if (typeNeedsRefDecode(ft, depth + 1)) break :blk true;
                    }
                    break :blk false;
                },
                .@"union" => |un| blk: {
                    if (@hasDecl(T, "zigar_js")) break :blk true;
                    if (un.field_names.len >= 2 and std.mem.eql(u8, un.field_names[0], "v0") and std.mem.eql(u8, un.field_names[1], "v1")) {
                        break :blk true;
                    }
                    for (un.field_types) |ft| {
                        if (typeNeedsRefDecode(ft, depth + 1)) break :blk true;
                    }
                    break :blk false;
                },
                .@"enum" => @hasDecl(T, "zigar_js"),
                .pointer => |pt| switch (pt.size) {
                    .slice, .one => if (pt.child == u8) false else typeNeedsRefDecode(pt.child, depth + 1),
                    else => false,
                },
                .array => |ar| typeNeedsRefDecode(ar.child, depth + 1),
                .error_union => |eu| typeNeedsRefDecode(eu.payload, depth + 1),
                else => false,
            };
        }

        fn typeUsesTsZigarCallbackCodec(comptime T: type, comptime depth: usize) bool {
            if (depth >= 16 or T == void) return false;
            if (comptime util.getInternalType(T) == .js_value) return isValidatedProtocolJsValue(T);
            if (comptime isNullableType(T)) return true;
            return switch (@typeInfo(T)) {
                .optional => true,
                .@"struct" => |st| blk: {
                    if (isTupleStructType(T) or module.hasStructZigarJsMeta(T)) break :blk true;
                    for (st.field_types) |ft| {
                        if (typeUsesTsZigarCallbackCodec(ft, depth + 1)) break :blk true;
                    }
                    break :blk false;
                },
                .@"union" => |un| blk: {
                    if (@hasDecl(T, "zigar_js")) break :blk true;
                    if (un.field_names.len >= 2 and std.mem.eql(u8, un.field_names[0], "v0") and std.mem.eql(u8, un.field_names[1], "v1")) {
                        break :blk true;
                    }
                    for (un.field_types) |ft| {
                        if (typeUsesTsZigarCallbackCodec(ft, depth + 1)) break :blk true;
                    }
                    break :blk false;
                },
                .@"enum" => @hasDecl(T, "zigar_js"),
                .pointer => |pt| switch (pt.size) {
                    .slice, .one => if (pt.child == u8) false else typeUsesTsZigarCallbackCodec(pt.child, depth + 1),
                    else => false,
                },
                .array => |ar| typeUsesTsZigarCallbackCodec(ar.child, depth + 1),
                .error_union => |eu| typeUsesTsZigarCallbackCodec(eu.payload, depth + 1),
                else => false,
            };
        }

        fn valueContainsHandle(comptime T: type, value: T, target_handle: u32) bool {
            if (target_handle < 8) return false;
            if (comptime util.getInternalType(T) == .js_value) {
                return extractHandle(value) == target_handle;
            }
            return switch (@typeInfo(T)) {
                .optional => if (value) |v| valueContainsHandle(@TypeOf(v), v, target_handle) else false,
                .@"union" => if (comptime isNullableType(T)) switch (value) {
                    .value => |v| valueContainsHandle(T.Value, v, target_handle),
                    else => false,
                } else switch (value) {
                    inline else => |payload| valueContainsHandle(@TypeOf(payload), payload, target_handle),
                },
                .@"struct" => |st| blk: {
                    inline for (st.field_names, 0..) |fname, fi| {
                        if (valueContainsHandle(st.field_types[fi], @field(value, fname), target_handle)) break :blk true;
                    }
                    break :blk false;
                },
                .pointer => |pt| switch (pt.size) {
                    .slice => blk: {
                        if (pt.child == u8) break :blk false;
                        for (value) |elem| {
                            if (valueContainsHandle(pt.child, elem, target_handle)) break :blk true;
                        }
                        break :blk false;
                    },
                    .one => if (@typeInfo(pt.child) != .@"fn") valueContainsHandle(pt.child, value.*, target_handle) else false,
                    else => false,
                },
                .array => |ar| blk: {
                    for (value) |elem| {
                        if (valueContainsHandle(ar.child, elem, target_handle)) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
        }

        fn releaseReturnedHandlesIfNotAliased(comptime T: type, value: T, alias_ctx: anytype) void {
            if (comptime util.getInternalType(T) == .js_value) {
                const h = extractHandle(value);
                if (h >= 8 and !alias_ctx.contains(h)) {
                    (Ref(module.Any){ .handle = h }).deinit();
                }
                return;
            }
            switch (@typeInfo(T)) {
                .optional => if (value) |v| releaseReturnedHandlesIfNotAliased(@TypeOf(v), v, alias_ctx),
                .@"union" => if (comptime isNullableType(T)) switch (value) {
                    .value => |v| releaseReturnedHandlesIfNotAliased(T.Value, v, alias_ctx),
                    else => {},
                } else switch (value) {
                    inline else => |payload| releaseReturnedHandlesIfNotAliased(@TypeOf(payload), payload, alias_ctx),
                },
                .@"struct" => |st| {
                    inline for (st.field_names, 0..) |fname, fi| {
                        releaseReturnedHandlesIfNotAliased(st.field_types[fi], @field(value, fname), alias_ctx);
                    }
                },
                .pointer => |pt| switch (pt.size) {
                    .slice => if (pt.child != u8) {
                        for (value) |elem| releaseReturnedHandlesIfNotAliased(pt.child, elem, alias_ctx);
                    },
                    .one => if (@typeInfo(pt.child) != .@"fn") releaseReturnedHandlesIfNotAliased(pt.child, value.*, alias_ctx),
                    else => {},
                },
                else => {},
            }
        }

        fn sigUsesTsZigarCallbackCodec(comptime JsFnSig: type, comptime cb_flags: module.CallbackFlags) bool {
            if (cb_flags.ref_codec) return true;
            const fi = @typeInfo(JsFnSig).@"fn";
            for (fi.param_types) |maybe_pt| {
                if (maybe_pt) |pt| {
                    if (typeUsesTsZigarCallbackCodec(pt, 0)) return true;
                }
            }
            if (fi.return_type) |rt| {
                if (typeUsesTsZigarCallbackCodec(rt, 0)) return true;
            }
            return false;
        }

        pub fn CallbackWithOptions(comptime JsFnSig: type, comptime cb_flags: module.CallbackFlags) type {
            const fn_info = switch (@typeInfo(JsFnSig)) {
                .@"fn" => |fi| fi,
                else => @compileError("Expected a Zig function signature `fn (...) ...`, received " ++ @typeName(JsFnSig)),
            };
            const RT = fn_info.return_type orelse void;
            const UnwrappedRT = switch (@typeInfo(RT)) {
                .error_union => |eu| eu.payload,
                else => RT,
            };
            const use_ref_codec = comptime sigUsesTsZigarCallbackCodec(JsFnSig, cb_flags);
            const WirePayload = if (UnwrappedRT == void) void else Ref(module.Any);
            const WireRT = comptime blk: {
                if (!use_ref_codec) break :blk RT;
                break :blk switch (@typeInfo(RT)) {
                    .error_union => |eu| if (@typeInfo(eu.error_set).error_set.error_names == null)
                        WirePayload
                    else
                        (eu.error_set || module.CallError)!WirePayload,
                    else => WirePayload,
                };
            };
            const WireFnSig = comptime blk: {
                if (!use_ref_codec) break :blk JsFnSig;
                const wire_params: [fn_info.param_types.len]type = @splat(Ref(module.Any));
                break :blk buildFnType(&wire_params, WireRT);
            };
            const Args = arg_struct.ArgStruct(WireFnSig);

            return struct {
                const Self = @This();
                pub const is_zig_callback = true;
                pub const Signature = JsFnSig;
                pub const ReturnType = RT;

                id: u32 = 0,
                func: Ref(module.Function) = Ref(module.Function).@"undefined",

                const reg = TypeRegistration(Args);

                var descriptor: module.CallbackDescriptor = .{
                    .signature = signature.get(Args),
                    .flags = @bitCast(cb_flags),
                };

                var descriptor_once: module.CallbackDescriptor = .{
                    .signature = signature.get(Args),
                    .flags = @bitCast(module.CallbackFlags{
                        .async_call = cb_flags.async_call,
                        .once = true,
                        .pass_this = cb_flags.pass_this,
                        .ref_codec = cb_flags.ref_codec,
                    }),
                };

                fn trampolineThunk(raw_id_ptr: *const anyopaque, arg_ptr: *anyopaque) anyerror!void {
                    const callback_id: u32 = @truncate(@intFromPtr(raw_id_ptr));
                    const resolved = CallbackRegistry.resolve(callback_id) orelse return error.InvalidCallback;
                    const entry = resolved.entry;
                    if (entry.sig_hash != descriptor.signature) return error.SignatureMismatch;
                    const invoker = entry.invoker orelse return error.InvalidCallback;
                    const ctx_ptr = entry.ctx_ptr;
                    const is_once = entry.once;
                    const once_handle = entry.fn_handle;
                    entry.active_calls += 1;
                    const consumed_once = if (is_once) CallbackRegistry.release(callback_id) else false;
                    if (consumed_once) {
                        if (@hasDecl(host, "releaseZigCallback")) {
                            host.releaseZigCallback(callback_id);
                        }
                    }
                    defer {
                        CallbackRegistry.finishCall(resolved.slot_index, entry);
                        if (consumed_once and !@hasDecl(host, "releaseZigCallback")) {
                            if (once_handle > module.reserved_global_this_handle) {
                                host.releaseJsValue(once_handle);
                            }
                        }
                    }
                    return invoker(ctx_ptr, arg_ptr);
                }

                fn ensureDescriptor(is_once: bool) *const module.CallbackDescriptor {
                    _ = reg;
                    const target_desc = if (is_once or cb_flags.once) &descriptor_once else &descriptor;
                    if (target_desc.trampoline_thunk == 0) {
                        target_desc.trampoline_thunk = @intFromPtr(&trampolineThunk);
                        target_desc.cancel_thunk = @intFromPtr(&cancelCallbackThunk);
                        if (!builtin.target.cpu.arch.isWasm() and @hasDecl(host, "getTypeFactoryThunk")) {
                            target_desc.register_thunk = @intFromPtr(host.getTypeFactoryThunk(Args));
                        }
                    }
                    return target_desc;
                }

                fn invokeWithFrame(
                    comptime CallFnT: type,
                    callee: anytype,
                    prefix_args: anytype,
                    frame: *Args,
                ) anyerror!void {
                    const c_info = @typeInfo(CallFnT).@"fn";
                    const prefix_len = prefix_args.len;
                    const CRet = c_info.return_type orelse void;
                    if (comptime use_ref_codec) {
                        defer {
                            inline for (0..fn_info.param_types.len) |i| {
                                const field_name = std.fmt.comptimePrint("{d}", .{i});
                                const wire_ref: Ref(module.Any) = @field(frame, field_name);
                                wire_ref.deinit();
                            }
                        }
                        var cb_arena = std.heap.ArenaAllocator.init(CallbackRegistry.backingAllocator());
                        defer cb_arena.deinit();
                        const cb_alloc = cb_arena.allocator();

                        var call_args: std.meta.ArgsTuple(CallFnT) = undefined;
                        inline for (0..prefix_len) |pi| {
                            call_args[pi] = prefix_args[pi];
                        }
                        var decoded_mask: [fn_info.param_types.len]bool = @splat(false);
                        defer {
                            inline for (0..fn_info.param_types.len) |i| {
                                if (decoded_mask[i]) {
                                    const TargetParamT = c_info.param_types[prefix_len + i].?;
                                    freeDecoded(TargetParamT, cb_alloc, call_args[prefix_len + i]);
                                }
                            }
                        }
                        const wire_has_err_union = comptime (@typeInfo(WireRT) == .error_union);
                        inline for (0..fn_info.param_types.len) |i| {
                            const field_name = std.fmt.comptimePrint("{d}", .{i});
                            const raw_ref: Ref(module.Any) = @field(frame, field_name);
                            const TargetParamT = c_info.param_types[prefix_len + i].?;
                            if (fromJsRefAlloc(TargetParamT, cb_alloc, raw_ref)) |dec_v| {
                                call_args[prefix_len + i] = dec_v;
                                decoded_mask[i] = true;
                            } else |dec_err| {
                                if (comptime wire_has_err_union) {
                                    frame.retval = dec_err;
                                    return;
                                }
                                return dec_err;
                            }
                        }
                        const val = if (comptime (@typeInfo(CRet) == .error_union)) blk_call: {
                            if (@call(.auto, callee, call_args)) |ok_v| {
                                break :blk_call ok_v;
                            } else |call_err| {
                                if (comptime wire_has_err_union) {
                                    const WireErrSet = @typeInfo(WireRT).error_union.error_set;
                                    if (comptime (@typeInfo(@typeInfo(CRet).error_union.error_set).error_set.error_names != null)) {
                                        frame.retval = @as(WireErrSet, call_err);
                                        return;
                                    }
                                }
                                return call_err;
                            }
                        } else @call(.auto, callee, call_args);
                        if (comptime (UnwrappedRT != void)) {
                            const AliasCheck = struct {
                                args_ptr: *const std.meta.ArgsTuple(CallFnT),
                                fn contains(self_chk: @This(), h: u32) bool {
                                    inline for (0..fn_info.param_types.len) |i| {
                                        const TargetParamT = c_info.param_types[prefix_len + i].?;
                                        if (valueContainsHandle(TargetParamT, self_chk.args_ptr[prefix_len + i], h)) return true;
                                    }
                                    return false;
                                }
                            };
                            defer releaseReturnedHandlesIfNotAliased(@TypeOf(val), val, AliasCheck{ .args_ptr = &call_args });
                            const enc_ref = toJsRef(@TypeOf(val), val) catch |enc_err| {
                                if (comptime wire_has_err_union) {
                                    frame.retval = enc_err;
                                    return;
                                }
                                return enc_err;
                            };
                            frame.retval = enc_ref;
                        } else if (comptime wire_has_err_union) {
                            frame.retval = {};
                        }
                    } else {
                        var call_args: std.meta.ArgsTuple(CallFnT) = undefined;
                        inline for (0..prefix_len) |pi| {
                            call_args[pi] = prefix_args[pi];
                        }
                        inline for (0..fn_info.param_types.len) |i| {
                            const field_name = std.fmt.comptimePrint("{d}", .{i});
                            call_args[prefix_len + i] = @field(frame, field_name);
                        }
                        if (@typeInfo(CRet) == .error_union and @typeInfo(RT) != .error_union) {
                            frame.retval = try @call(.auto, callee, call_args);
                        } else {
                            frame.retval = @call(.auto, callee, call_args);
                        }
                    }
                }

                fn makeInvoker(comptime CtxPtrT: type, comptime handler: anytype) CallbackRegistry.InvokerFn {
                    const HandlerT = @TypeOf(handler);
                    const h_info = @typeInfo(HandlerT).@"fn";
                    if (h_info.param_types.len != fn_info.param_types.len + 1) {
                        @compileError(std.fmt.comptimePrint(
                            "Callback handler expects {d} parameters (context + {d} JS args), received {d}",
                            .{ fn_info.param_types.len + 1, fn_info.param_types.len, h_info.param_types.len },
                        ));
                    }
                    const Wrapper = struct {
                        fn invoke(raw_ctx: *anyopaque, raw_arg: *anyopaque) anyerror!void {
                            const typed_ctx: CtxPtrT = @ptrCast(@alignCast(raw_ctx));
                            const frame: *Args = @ptrCast(@alignCast(raw_arg));
                            return invokeWithFrame(HandlerT, handler, .{typed_ctx}, frame);
                        }
                    };
                    return &Wrapper.invoke;
                }

                fn registerSlot(ctx_ptr: *anyopaque, invoker: CallbackRegistry.InvokerFn, deinit_ctx: ?CallbackRegistry.DeinitCtxFn, is_once: bool) module.CallError!Self {
                    if (!isJsThread()) return error.OffJsThread;
                    if (!@hasDecl(host, "createZigCallback")) return error.HostUnavailable;
                    const effective_once = is_once or cb_flags.once;
                    const desc = ensureDescriptor(effective_once);
                    const slot_id = try CallbackRegistry.allocate(ctx_ptr, invoker, deinit_ctx, effective_once, desc.signature);
                    errdefer _ = CallbackRegistry.release(slot_id);
                    const handle = try host.createZigCallback(desc, slot_id);
                    CallbackRegistry.setHandle(slot_id, handle);
                    return .{
                        .id = slot_id,
                        .func = .{ .handle = handle },
                    };
                }

                fn tryInitMode(ctx_ptr: anytype, comptime handler: anytype, is_once: bool) module.CallError!Self {
                    const CtxPtrT = @TypeOf(ctx_ptr);
                    switch (@typeInfo(CtxPtrT)) {
                        .pointer => |pt| if (pt.size != .one) @compileError("Callback context must be a single-item pointer `*Ctx` or `*const Ctx`"),
                        else => @compileError("Callback context must be a pointer `*Ctx` or `*const Ctx`, received " ++ @typeName(CtxPtrT)),
                    }
                    const opaque_ctx: *anyopaque = @ptrCast(@constCast(ctx_ptr));
                    return registerSlot(opaque_ctx, makeInvoker(CtxPtrT, handler), null, is_once);
                }

                pub fn tryInit(ctx_ptr: anytype, comptime handler: anytype) module.CallError!Self {
                    return tryInitMode(ctx_ptr, handler, false);
                }

                pub fn init(ctx_ptr: anytype, comptime handler: anytype) Self {
                    return tryInit(ctx_ptr, handler) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize Zig JS callback"),
                    };
                }

                pub fn tryOnce(ctx_ptr: anytype, comptime handler: anytype) module.CallError!Self {
                    return tryInitMode(ctx_ptr, handler, true);
                }

                pub fn once(ctx_ptr: anytype, comptime handler: anytype) Self {
                    return tryOnce(ctx_ptr, handler) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize one-shot Zig JS callback"),
                    };
                }

                fn tryInitOwnedMode(allocator: std.mem.Allocator, ctx_value: anytype, comptime handler: anytype, is_once: bool) module.CallError!Self {
                    const Ctx = @TypeOf(ctx_value);
                    const HeapBox = struct {
                        alloc: std.mem.Allocator,
                        ctx: Ctx,

                        fn destroyBox(raw_ptr: *anyopaque) void {
                            const box: *@This() = @ptrCast(@alignCast(raw_ptr));
                            const alloc = box.alloc;
                            alloc.destroy(box);
                        }
                    };
                    const HandlerT = @TypeOf(handler);
                    const h_info = @typeInfo(HandlerT).@"fn";
                    if (h_info.param_types.len != fn_info.param_types.len + 1) {
                        @compileError(std.fmt.comptimePrint(
                            "Callback handler expects {d} parameters (context + {d} JS args), received {d}",
                            .{ fn_info.param_types.len + 1, fn_info.param_types.len, h_info.param_types.len },
                        ));
                    }
                    const BoxedInvoker = struct {
                        fn invoke(raw_ptr: *anyopaque, raw_arg: *anyopaque) anyerror!void {
                            const box: *HeapBox = @ptrCast(@alignCast(raw_ptr));
                            const frame: *Args = @ptrCast(@alignCast(raw_arg));
                            const FirstParamT = h_info.param_types[0].?;
                            if (comptime FirstParamT == Ctx) {
                                return invokeWithFrame(HandlerT, handler, .{box.ctx}, frame);
                            } else {
                                return invokeWithFrame(HandlerT, handler, .{&box.ctx}, frame);
                            }
                        }
                    };
                    const box = try allocator.create(HeapBox);
                    box.* = .{ .alloc = allocator, .ctx = ctx_value };
                    if (!isJsThread()) {
                        allocator.destroy(box);
                        return error.OffJsThread;
                    }
                    if (!@hasDecl(host, "createZigCallback")) {
                        allocator.destroy(box);
                        return error.HostUnavailable;
                    }
                    const effective_once = is_once or cb_flags.once;
                    const desc = ensureDescriptor(effective_once);
                    const slot_id = CallbackRegistry.allocate(@ptrCast(box), &BoxedInvoker.invoke, &HeapBox.destroyBox, effective_once, desc.signature) catch |err| {
                        allocator.destroy(box);
                        return err;
                    };
                    const handle = host.createZigCallback(desc, slot_id) catch |err| {
                        _ = CallbackRegistry.release(slot_id);
                        return err;
                    };
                    CallbackRegistry.setHandle(slot_id, handle);
                    return .{
                        .id = slot_id,
                        .func = .{ .handle = handle },
                    };
                }

                pub fn tryInitOwned(allocator: std.mem.Allocator, ctx_value: anytype, comptime handler: anytype) module.CallError!Self {
                    return tryInitOwnedMode(allocator, ctx_value, handler, false);
                }

                pub fn initOwned(allocator: std.mem.Allocator, ctx_value: anytype, comptime handler: anytype) Self {
                    return tryInitOwned(allocator, ctx_value, handler) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize owned Zig JS callback"),
                    };
                }

                pub fn tryOnceOwned(allocator: std.mem.Allocator, ctx_value: anytype, comptime handler: anytype) module.CallError!Self {
                    return tryInitOwnedMode(allocator, ctx_value, handler, true);
                }

                pub fn onceOwned(allocator: std.mem.Allocator, ctx_value: anytype, comptime handler: anytype) Self {
                    return tryOnceOwned(allocator, ctx_value, handler) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize owned one-shot Zig JS callback"),
                    };
                }

                fn tryInitFnMode(comptime plain_fn: anytype, is_once: bool) module.CallError!Self {
                    const PlainFnT = @TypeOf(plain_fn);
                    const p_info = @typeInfo(PlainFnT).@"fn";
                    if (p_info.param_types.len != fn_info.param_types.len) {
                        @compileError("Stateless callback parameter count mismatch");
                    }
                    const Stateless = struct {
                        var dummy: u8 = 0;
                        fn invoke(_: *anyopaque, raw_arg: *anyopaque) anyerror!void {
                            const frame: *Args = @ptrCast(@alignCast(raw_arg));
                            return invokeWithFrame(PlainFnT, plain_fn, .{}, frame);
                        }
                    };
                    return registerSlot(@ptrCast(&Stateless.dummy), &Stateless.invoke, null, is_once);
                }

                fn tryInitFnPtrMode(fn_ptr: anytype, is_once: bool) module.CallError!Self {
                    const PtrT = @TypeOf(fn_ptr);
                    const PlainFnT = switch (@typeInfo(PtrT)) {
                        .pointer => |pt| if (pt.size == .one and @typeInfo(pt.child) == .@"fn") pt.child else @compileError("Expected `*const fn (...) ...`, received " ++ @typeName(PtrT)),
                        else => @compileError("Expected `*const fn (...) ...`, received " ++ @typeName(PtrT)),
                    };
                    const p_info = @typeInfo(PlainFnT).@"fn";
                    if (p_info.param_types.len != fn_info.param_types.len) {
                        @compileError("Stateless callback pointer parameter count mismatch");
                    }
                    const Box = struct {
                        alloc: std.mem.Allocator,
                        f: *const PlainFnT,

                        fn destroy(raw_ptr: *anyopaque) void {
                            const b: *@This() = @ptrCast(@alignCast(raw_ptr));
                            const a = b.alloc;
                            a.destroy(b);
                        }
                        fn invoke(raw_ptr: *anyopaque, raw_arg: *anyopaque) anyerror!void {
                            const b: *@This() = @ptrCast(@alignCast(raw_ptr));
                            const frame: *Args = @ptrCast(@alignCast(raw_arg));
                            return invokeWithFrame(PlainFnT, b.f, .{}, frame);
                        }
                    };
                    const alloc = CallbackRegistry.backingAllocator();
                    const box = try alloc.create(Box);
                    box.* = .{ .alloc = alloc, .f = fn_ptr };
                    if (!isJsThread()) {
                        alloc.destroy(box);
                        return error.OffJsThread;
                    }
                    if (!@hasDecl(host, "createZigCallback")) {
                        alloc.destroy(box);
                        return error.HostUnavailable;
                    }
                    const effective_once = is_once or cb_flags.once;
                    const desc = ensureDescriptor(effective_once);
                    const slot_id = CallbackRegistry.allocate(@ptrCast(box), &Box.invoke, &Box.destroy, effective_once, desc.signature) catch |err| {
                        alloc.destroy(box);
                        return err;
                    };
                    const handle = host.createZigCallback(desc, slot_id) catch |err| {
                        _ = CallbackRegistry.release(slot_id);
                        return err;
                    };
                    CallbackRegistry.setHandle(slot_id, handle);
                    return .{
                        .id = slot_id,
                        .func = .{ .handle = handle },
                    };
                }

                pub fn tryInitFnPtr(fn_ptr: anytype) module.CallError!Self {
                    return tryInitFnPtrMode(fn_ptr, false);
                }

                pub fn initFnPtr(fn_ptr: anytype) Self {
                    return tryInitFnPtr(fn_ptr) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize Zig JS callback pointer"),
                    };
                }

                pub fn tryOnceFnPtr(fn_ptr: anytype) module.CallError!Self {
                    return tryInitFnPtrMode(fn_ptr, true);
                }

                pub fn onceFnPtr(fn_ptr: anytype) Self {
                    return tryOnceFnPtr(fn_ptr) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize one-shot Zig JS callback pointer"),
                    };
                }

                pub fn tryInitFn(comptime plain_fn: anytype) module.CallError!Self {
                    return tryInitFnMode(plain_fn, false);
                }

                pub fn initFn(comptime plain_fn: anytype) Self {
                    return tryInitFn(plain_fn) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize stateless Zig JS callback"),
                    };
                }

                pub fn tryOnceFn(comptime plain_fn: anytype) module.CallError!Self {
                    return tryInitFnMode(plain_fn, true);
                }

                pub fn onceFn(comptime plain_fn: anytype) Self {
                    return tryOnceFn(plain_fn) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize stateless one-shot Zig JS callback"),
                    };
                }

                /// Create an un-revoked stateless JS function handle for a comptime Zig function.
                /// Safe for sync, async, and multi-shot event listeners (`EventEmitter.on`/`off`)
                /// without allocating a `CallbackRegistry` slot; caller releases only the temporary `Ref`.
                pub fn tryStatelessFn(comptime plain_fn: anytype) module.CallError!Ref(module.Function) {
                    const PlainFnT = @TypeOf(plain_fn);
                    const p_info = @typeInfo(PlainFnT).@"fn";
                    if (p_info.param_types.len != fn_info.param_types.len) {
                        @compileError("Stateless callback parameter count mismatch");
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    if (!@hasDecl(host, "createZigCallback")) return error.HostUnavailable;
                    const StatelessHolder = struct {
                        var desc: module.CallbackDescriptor = .{
                            .signature = signature.get(Args),
                            .flags = @bitCast(module.CallbackFlags{
                                .async_call = cb_flags.async_call,
                                .once = false,
                                .pass_this = cb_flags.pass_this,
                                .ref_codec = cb_flags.ref_codec,
                                .stateless = true,
                            }),
                        };
                        fn trampoline(_: *const anyopaque, raw_arg: *anyopaque) anyerror!void {
                            const frame: *Args = @ptrCast(@alignCast(raw_arg));
                            return invokeWithFrame(PlainFnT, plain_fn, .{}, frame);
                        }
                        fn ensure() *const module.CallbackDescriptor {
                            _ = reg;
                            if (desc.trampoline_thunk == 0) {
                                desc.trampoline_thunk = @intFromPtr(&trampoline);
                                if (!builtin.target.cpu.arch.isWasm() and @hasDecl(host, "getTypeFactoryThunk")) {
                                    desc.register_thunk = @intFromPtr(host.getTypeFactoryThunk(Args));
                                }
                            }
                            return &desc;
                        }
                    };
                    const handle = try host.createZigCallback(StatelessHolder.ensure(), 1);
                    return .{ .handle = handle };
                }

                pub fn statelessFn(comptime plain_fn: anytype) Ref(module.Function) {
                    return tryStatelessFn(plain_fn) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize stateless Zig JS callback"),
                    };
                }

                /// Create an un-revoked stateless JS function handle for a runtime `*const fn` pointer.
                /// Safe for sync, async, and multi-shot event listeners (`EventEmitter.on`/`off`)
                /// without consuming `CallbackRegistry` slots; caller releases only the temporary `Ref`.
                pub fn tryStatelessFnPtr(fn_ptr: anytype) module.CallError!Ref(module.Function) {
                    const PtrT = @TypeOf(fn_ptr);
                    const PlainFnT = switch (@typeInfo(PtrT)) {
                        .pointer => |pt| if (pt.size == .one and @typeInfo(pt.child) == .@"fn") pt.child else @compileError("Expected `*const fn (...) ...`, received " ++ @typeName(PtrT)),
                        else => @compileError("Expected `*const fn (...) ...`, received " ++ @typeName(PtrT)),
                    };
                    const p_info = @typeInfo(PlainFnT).@"fn";
                    if (p_info.param_types.len != fn_info.param_types.len) {
                        @compileError("Stateless callback pointer parameter count mismatch");
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    if (!@hasDecl(host, "createZigCallback")) return error.HostUnavailable;
                    const fn_id = try StatelessFnPtrRegistry.intern(@intFromPtr(fn_ptr));
                    const PtrStatelessHolder = struct {
                        var desc: module.CallbackDescriptor = .{
                            .signature = signature.get(Args),
                            .flags = @bitCast(module.CallbackFlags{
                                .async_call = cb_flags.async_call,
                                .once = false,
                                .pass_this = cb_flags.pass_this,
                                .ref_codec = cb_flags.ref_codec,
                                .stateless = true,
                            }),
                        };
                        fn trampoline(raw_id_ptr: *const anyopaque, raw_arg: *anyopaque) anyerror!void {
                            const id: u32 = @truncate(@intFromPtr(raw_id_ptr));
                            const addr = StatelessFnPtrRegistry.lookup(id) orelse return error.InvalidCallback;
                            const typed_fn: *const PlainFnT = @ptrFromInt(addr);
                            const frame: *Args = @ptrCast(@alignCast(raw_arg));
                            return invokeWithFrame(PlainFnT, typed_fn, .{}, frame);
                        }
                        fn ensure() *const module.CallbackDescriptor {
                            _ = reg;
                            if (desc.trampoline_thunk == 0) {
                                desc.trampoline_thunk = @intFromPtr(&trampoline);
                                if (!builtin.target.cpu.arch.isWasm() and @hasDecl(host, "getTypeFactoryThunk")) {
                                    desc.register_thunk = @intFromPtr(host.getTypeFactoryThunk(Args));
                                }
                            }
                            return &desc;
                        }
                    };
                    const handle = try host.createZigCallback(PtrStatelessHolder.ensure(), fn_id);
                    return .{ .handle = handle };
                }

                pub fn statelessFnPtr(fn_ptr: anytype) Ref(module.Function) {
                    return tryStatelessFnPtr(fn_ptr) catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize stateless Zig JS callback pointer"),
                    };
                }

                pub inline fn ref(self: Self) Ref(module.Function) {
                    return self.func;
                }

                pub inline fn toRef(self: Self) Ref(module.Function) {
                    return self.func;
                }

                pub inline fn value(self: Self) Ref(module.Function) {
                    return self.func;
                }

                pub inline fn cloneRef(self: Self) Ref(module.Function) {
                    return self.func.clone();
                }

                pub inline fn isValid(self: Self) bool {
                    return self.id != 0 and !self.func.isUndefined();
                }

                pub inline fn isActive(self: Self) bool {
                    return self.id != 0 and CallbackRegistry.isActive(self.id);
                }

                pub fn deinit(self: anytype) void {
                    const SelfArgT = @TypeOf(self);
                    const slot_id, const fn_ref = switch (@typeInfo(SelfArgT)) {
                        .pointer => |pt| blk: {
                            const sid = self.id;
                            const fref = self.func;
                            if (!pt.attrs.@"const") {
                                self.id = 0;
                                self.func = Ref(module.Function).@"undefined";
                            }
                            break :blk .{ sid, fref };
                        },
                        else => .{ self.id, self.func },
                    };
                    if (slot_id == 0) return;
                    if (CallbackRegistry.release(slot_id)) {
                        if (@hasDecl(host, "releaseZigCallback")) {
                            host.releaseZigCallback(slot_id);
                        } else {
                            fn_ref.deinit();
                        }
                    }
                }
            };
        }

        fn unwrapFnType(comptime T: type) type {
            return switch (@typeInfo(T)) {
                .@"fn" => T,
                .pointer => |pt| if (pt.size == .one and @typeInfo(pt.child) == .@"fn")
                    pt.child
                else
                    @compileError("Expected a Zig function or function signature, received " ++ @typeName(T)),
                else => @compileError("Expected a Zig function or function signature, received " ++ @typeName(T)),
            };
        }

        fn normalizeClosureReturn(comptime RT: type) type {
            return switch (@typeInfo(RT)) {
                .error_union => |eu| if (@typeInfo(eu.error_set).error_set.error_names == null) eu.payload else RT,
                else => RT,
            };
        }

        fn StripFirstFnParam(comptime FnT: type) type {
            const f = @typeInfo(unwrapFnType(FnT)).@"fn";
            if (f.param_types.len == 0) {
                @compileError("Expected handler function with context parameter, received zero-parameter " ++ @typeName(FnT));
            }
            const rem = f.param_types.len - 1;
            var param_types: [rem]type = undefined;
            var param_attrs: [rem]std.lang.Type.Fn.ParamAttributes = undefined;
            for (f.param_types[1..], 0..) |maybe_pt, i| {
                param_types[i] = maybe_pt orelse @compileError("Closure JS parameter types cannot be `anytype`");
                param_attrs[i] = .{};
            }
            return @Fn(&param_types, &param_attrs, normalizeClosureReturn(f.return_type orelse void), .{});
        }

        fn NormalizePlainFnSig(comptime FnT: type) type {
            const f = @typeInfo(unwrapFnType(FnT)).@"fn";
            var param_types: [f.param_types.len]type = undefined;
            var param_attrs: [f.param_types.len]std.lang.Type.Fn.ParamAttributes = undefined;
            for (f.param_types, 0..) |maybe_pt, i| {
                param_types[i] = maybe_pt orelse @compileError("Closure JS parameter types cannot be `anytype`");
                param_attrs[i] = .{};
            }
            return @Fn(&param_types, &param_attrs, normalizeClosureReturn(f.return_type orelse void), .{});
        }

        fn isSingleItemPointer(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .pointer => |pt| pt.size == .one,
                else => false,
            };
        }

        pub fn Closure(comptime Ctx: type, comptime FnOrSig: anytype) type {
            return ClosureWithOptions(Ctx, FnOrSig, .{});
        }

        pub fn ClosureWithThis(comptime Ctx: type, comptime FnOrSig: anytype) type {
            return ClosureWithOptions(Ctx, FnOrSig, .{ .pass_this = true, .ref_codec = true });
        }

        pub fn AsyncClosure(comptime Ctx: type, comptime FnOrSig: anytype) type {
            return ClosureWithOptions(Ctx, FnOrSig, .{ .async_call = true });
        }

        pub fn ClosureWithOptions(comptime Ctx: type, comptime FnOrSig: anytype, comptime cb_flags: module.CallbackFlags) type {
            const is_sig_type = (@TypeOf(FnOrSig) == type);
            const is_ptr_ctx = isSingleItemPointer(Ctx);

            return struct {
                const Self = @This();
                pub const is_zig_callback = true;
                pub const Context = Ctx;
                pub const ReturnType = blk: {
                    const FnT = if (is_sig_type) unwrapFnType(FnOrSig) else unwrapFnType(@TypeOf(FnOrSig));
                    break :blk @typeInfo(FnT).@"fn".return_type orelse void;
                };

                id: u32 = 0,
                func: Ref(module.Function) = Ref(module.Function).@"undefined",

                fn resolveJsSigForHandler(comptime HandlerValT: type) type {
                    const HandlerFnT = unwrapFnType(HandlerValT);
                    const h_info = @typeInfo(HandlerFnT).@"fn";
                    if (!is_sig_type) {
                        return if (Ctx == void) NormalizePlainFnSig(HandlerFnT) else StripFirstFnParam(HandlerFnT);
                    }
                    const SigFnT = unwrapFnType(FnOrSig);
                    const s_info = @typeInfo(SigFnT).@"fn";
                    if (Ctx == void) {
                        return SigFnT;
                    }
                    if (h_info.param_types.len == s_info.param_types.len + 1) {
                        return SigFnT;
                    }
                    if (h_info.param_types.len == s_info.param_types.len and s_info.param_types.len >= 1) {
                        return StripFirstFnParam(SigFnT);
                    }
                    @compileError(std.fmt.comptimePrint(
                        "Closure handler parameter count ({d}) does not match signature `{s}`",
                        .{ h_info.param_types.len, @typeName(SigFnT) },
                    ));
                }

                fn BackendFor(comptime handler: anytype) type {
                    const JsSig = resolveJsSigForHandler(@TypeOf(handler));
                    return CallbackWithOptions(JsSig, cb_flags);
                }

                fn fromBackend(cb: anytype) Self {
                    return .{ .id = cb.id, .func = cb.func };
                }

                fn derefHandler(comptime h: anytype) switch (@typeInfo(@TypeOf(h))) {
                    .pointer => |pt| pt.child,
                    else => @TypeOf(h),
                } {
                    return switch (@typeInfo(@TypeOf(h))) {
                        .pointer => h.*,
                        else => h,
                    };
                }

                fn tryCreatePtr(ctx_ptr: Ctx, comptime handler: anytype, is_once: bool) module.CallError!Self {
                    const fn_val = comptime derefHandler(handler);
                    const Backend = BackendFor(fn_val);
                    const cb = if (is_once)
                        try Backend.tryOnce(ctx_ptr, fn_val)
                    else
                        try Backend.tryInit(ctx_ptr, fn_val);
                    return fromBackend(cb);
                }

                fn tryCreateOwned(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype, is_once: bool) module.CallError!Self {
                    const fn_val = comptime derefHandler(handler);
                    const Backend = BackendFor(fn_val);
                    const cb = if (is_once)
                        try Backend.tryOnceOwned(allocator, ctx_value, fn_val)
                    else
                        try Backend.tryInitOwned(allocator, ctx_value, fn_val);
                    return fromBackend(cb);
                }

                fn tryCreateVoid(comptime plain_fn: anytype, is_once: bool) module.CallError!Self {
                    const fn_val = comptime derefHandler(plain_fn);
                    const Backend = BackendFor(fn_val);
                    const cb = if (is_once)
                        try Backend.tryOnceFn(fn_val)
                    else
                        try Backend.tryInitFn(fn_val);
                    return fromBackend(cb);
                }

                fn unwrapOrPanic(res: module.CallError!Self) Self {
                    return res catch |err| switch (err) {
                        error.OffJsThread => @panic("JsValue operations require the JS thread"),
                        error.HostUnavailable => @panic("JsValue host imports unavailable"),
                        else => @panic("Failed to initialize Zig JS closure"),
                    };
                }

                pub const tryInit = if (is_sig_type)
                    (if (Ctx == void)
                        struct {
                            pub fn call(comptime plain_fn: anytype) module.CallError!Self {
                                return tryCreateVoid(plain_fn, false);
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx, comptime handler: anytype) module.CallError!Self {
                                return tryCreatePtr(ctx_ptr, handler, false);
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) module.CallError!Self {
                                return tryCreateOwned(allocator, ctx_value, handler, false);
                            }
                        }.call)
                else
                    (if (Ctx == void)
                        struct {
                            pub fn call() module.CallError!Self {
                                return tryCreateVoid(FnOrSig, false);
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx) module.CallError!Self {
                                return tryCreatePtr(ctx_ptr, FnOrSig, false);
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) module.CallError!Self {
                                return tryCreateOwned(allocator, ctx_value, FnOrSig, false);
                            }
                        }.call);

                pub const init = if (is_sig_type)
                    (if (Ctx == void)
                        struct {
                            pub fn call(comptime plain_fn: anytype) Self {
                                return unwrapOrPanic(tryCreateVoid(plain_fn, false));
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx, comptime handler: anytype) Self {
                                return unwrapOrPanic(tryCreatePtr(ctx_ptr, handler, false));
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) Self {
                                return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, handler, false));
                            }
                        }.call)
                else
                    (if (Ctx == void)
                        struct {
                            pub fn call() Self {
                                return unwrapOrPanic(tryCreateVoid(FnOrSig, false));
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx) Self {
                                return unwrapOrPanic(tryCreatePtr(ctx_ptr, FnOrSig, false));
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) Self {
                                return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, FnOrSig, false));
                            }
                        }.call);

                pub const tryOnce = if (is_sig_type)
                    (if (Ctx == void)
                        struct {
                            pub fn call(comptime plain_fn: anytype) module.CallError!Self {
                                return tryCreateVoid(plain_fn, true);
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx, comptime handler: anytype) module.CallError!Self {
                                return tryCreatePtr(ctx_ptr, handler, true);
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) module.CallError!Self {
                                return tryCreateOwned(allocator, ctx_value, handler, true);
                            }
                        }.call)
                else
                    (if (Ctx == void)
                        struct {
                            pub fn call() module.CallError!Self {
                                return tryCreateVoid(FnOrSig, true);
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx) module.CallError!Self {
                                return tryCreatePtr(ctx_ptr, FnOrSig, true);
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) module.CallError!Self {
                                return tryCreateOwned(allocator, ctx_value, FnOrSig, true);
                            }
                        }.call);

                pub const once = if (is_sig_type)
                    (if (Ctx == void)
                        struct {
                            pub fn call(comptime plain_fn: anytype) Self {
                                return unwrapOrPanic(tryCreateVoid(plain_fn, true));
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx, comptime handler: anytype) Self {
                                return unwrapOrPanic(tryCreatePtr(ctx_ptr, handler, true));
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) Self {
                                return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, handler, true));
                            }
                        }.call)
                else
                    (if (Ctx == void)
                        struct {
                            pub fn call() Self {
                                return unwrapOrPanic(tryCreateVoid(FnOrSig, true));
                            }
                        }.call
                    else if (is_ptr_ctx)
                        struct {
                            pub fn call(ctx_ptr: Ctx) Self {
                                return unwrapOrPanic(tryCreatePtr(ctx_ptr, FnOrSig, true));
                            }
                        }.call
                    else
                        struct {
                            pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) Self {
                                return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, FnOrSig, true));
                            }
                        }.call);

                pub const tryInitOwned = if (is_sig_type)
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) module.CallError!Self {
                            return tryCreateOwned(allocator, ctx_value, handler, false);
                        }
                    }.call
                else
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) module.CallError!Self {
                            return tryCreateOwned(allocator, ctx_value, FnOrSig, false);
                        }
                    }.call;

                pub const initOwned = if (is_sig_type)
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) Self {
                            return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, handler, false));
                        }
                    }.call
                else
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) Self {
                            return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, FnOrSig, false));
                        }
                    }.call;

                pub const tryOnceOwned = if (is_sig_type)
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) module.CallError!Self {
                            return tryCreateOwned(allocator, ctx_value, handler, true);
                        }
                    }.call
                else
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) module.CallError!Self {
                            return tryCreateOwned(allocator, ctx_value, FnOrSig, true);
                        }
                    }.call;

                pub const onceOwned = if (is_sig_type)
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx, comptime handler: anytype) Self {
                            return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, handler, true));
                        }
                    }.call
                else
                    struct {
                        pub fn call(allocator: std.mem.Allocator, ctx_value: Ctx) Self {
                            return unwrapOrPanic(tryCreateOwned(allocator, ctx_value, FnOrSig, true));
                        }
                    }.call;

                pub inline fn ref(self: Self) Ref(module.Function) {
                    return self.func;
                }

                pub inline fn toRef(self: Self) Ref(module.Function) {
                    return self.func;
                }

                pub inline fn value(self: Self) Ref(module.Function) {
                    return self.func;
                }

                pub inline fn cloneRef(self: Self) Ref(module.Function) {
                    return self.func.clone();
                }

                pub inline fn isValid(self: Self) bool {
                    return self.id != 0 and !self.func.isUndefined();
                }

                pub inline fn isActive(self: Self) bool {
                    return self.id != 0 and CallbackRegistry.isActive(self.id);
                }

                pub fn deinit(self: anytype) void {
                    const SelfArgT = @TypeOf(self);
                    const slot_id, const fn_ref = switch (@typeInfo(SelfArgT)) {
                        .pointer => |pt| blk: {
                            const sid = self.id;
                            const fref = self.func;
                            if (!pt.attrs.@"const") {
                                self.id = 0;
                                self.func = Ref(module.Function).@"undefined";
                            }
                            break :blk .{ sid, fref };
                        },
                        else => .{ self.id, self.func },
                    };
                    if (slot_id == 0) return;
                    if (CallbackRegistry.release(slot_id)) {
                        if (@hasDecl(host, "releaseZigCallback")) {
                            host.releaseZigCallback(slot_id);
                        } else {
                            fn_ref.deinit();
                        }
                    }
                }
            };
        }

        pub fn PersistentClosureType(comptime CtxPtrT: type, comptime handler: anytype) type {
            const h_fn = switch (@typeInfo(@TypeOf(handler))) {
                .pointer => handler.*,
                .@"fn" => handler,
                else => @compileError("Expected handler function in persistentClosure(), received " ++ @typeName(@TypeOf(handler))),
            };
            return ClosureWithOptions(CtxPtrT, h_fn, .{ .ref_codec = true });
        }

        pub fn PersistentClosureWithThisType(comptime CtxPtrT: type, comptime handler: anytype) type {
            const h_fn = switch (@typeInfo(@TypeOf(handler))) {
                .pointer => handler.*,
                .@"fn" => handler,
                else => @compileError("Expected handler function in persistentClosureWithThis(), received " ++ @typeName(@TypeOf(handler))),
            };
            return ClosureWithThis(CtxPtrT, h_fn);
        }

        pub fn persistentClosure(ctx_ptr: anytype, comptime handler: anytype) module.CallError!PersistentClosureType(@TypeOf(ctx_ptr), handler) {
            return PersistentClosureType(@TypeOf(ctx_ptr), handler).tryInit(ctx_ptr);
        }

        pub fn persistentClosureWithThis(ctx_ptr: anytype, comptime handler: anytype) module.CallError!PersistentClosureWithThisType(@TypeOf(ctx_ptr), handler) {
            return PersistentClosureWithThisType(@TypeOf(ctx_ptr), handler).tryInit(ctx_ptr);
        }

        pub fn Ref(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Target = T;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };
                pub const @"false": Self = .{ .handle = module.reserved_false_handle };
                pub const @"true": Self = .{ .handle = module.reserved_true_handle };
                pub const globalThis: Self = .{ .handle = module.reserved_global_this_handle };
                pub const global_this: Self = .{ .handle = module.reserved_global_this_handle };

                pub inline fn fromBool(value: bool) Self {
                    return .{ .handle = if (value) module.reserved_true_handle else module.reserved_false_handle };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    if (self.handle <= module.reserved_global_this_handle) return self;
                    return .{ .handle = host.cloneJsValue(self.handle) };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    if (self.handle <= module.reserved_global_this_handle) {
                        if (!isJsThread()) return error.OffJsThread;
                        return self;
                    }
                    if (@hasDecl(host, "tryCloneJsValue")) {
                        return .{ .handle = try host.tryCloneJsValue(self.handle) };
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    return .{ .handle = host.cloneJsValue(self.handle) };
                }

                pub fn deinit(self: Self) void {
                    if (self.handle <= module.reserved_global_this_handle) return;
                    host.releaseJsValue(self.handle);
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    if (self.handle <= module.reserved_global_this_handle) {
                        if (!isJsThread()) return error.OffJsThread;
                        return;
                    }
                    if (@hasDecl(host, "tryReleaseJsValue")) {
                        return host.tryReleaseJsValue(self.handle);
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    host.releaseJsValue(self.handle);
                }

                pub fn tryDispose(self: Self) module.Error!void {
                    if (self.isNullOrUndefined()) {
                        if (!isJsThread()) return error.OffJsThread;
                        return;
                    }
                    if (@hasDecl(host, "tryDisposeJsValue")) {
                        return host.tryDisposeJsValue(self.handle);
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    if (@hasDecl(host, "disposeJsValue")) {
                        host.disposeJsValue(self.handle);
                        return;
                    }
                    self.deinit();
                    return error.HostUnavailable;
                }

                pub fn dispose(self: Self) void {
                    if (self.isNullOrUndefined()) {
                        if (!isJsThread()) @panic("JsValue operations require the JS thread");
                        return;
                    }
                    if (@hasDecl(host, "disposeJsValue")) {
                        host.disposeJsValue(self.handle);
                        return;
                    }
                    if (!isJsThread()) @panic("JsValue operations require the JS thread");
                    self.deinit();
                    @panic("JsValue host imports unavailable");
                }

                pub fn tryAsyncDispose(self: Self) module.Error!void {
                    if (self.isNullOrUndefined()) {
                        if (!isJsThread()) return error.OffJsThread;
                        return;
                    }
                    if (@hasDecl(host, "tryAsyncDisposeJsValue")) {
                        return host.tryAsyncDisposeJsValue(self.handle);
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    if (@hasDecl(host, "asyncDisposeJsValue")) {
                        host.asyncDisposeJsValue(self.handle);
                        return;
                    }
                    self.deinit();
                    return error.HostUnavailable;
                }

                pub fn asyncDispose(self: Self) void {
                    if (self.isNullOrUndefined()) {
                        if (!isJsThread()) @panic("JsValue operations require the JS thread");
                        return;
                    }
                    if (@hasDecl(host, "asyncDisposeJsValue")) {
                        host.asyncDisposeJsValue(self.handle);
                        return;
                    }
                    if (@hasDecl(host, "tryAsyncDisposeJsValue")) {
                        host.tryAsyncDisposeJsValue(self.handle) catch |err| switch (err) {
                            error.JsException => {},
                            error.OffJsThread => @panic("JsValue operations require the JS thread"),
                            error.HostUnavailable => @panic("Async disposal of Promise-returning [Symbol.asyncDispose] requires an async/JSPI context"),
                        };
                        return;
                    }
                    if (!isJsThread()) @panic("JsValue operations require the JS thread");
                    self.deinit();
                    @panic("JsValue host imports unavailable");
                }

                pub fn typeof(self: Self) module.JsType {
                    return switch (self.handle) {
                        module.reserved_undefined_handle => .@"undefined",
                        module.reserved_null_handle, module.reserved_global_this_handle => .object,
                        module.reserved_false_handle, module.reserved_true_handle => .boolean,
                        else => host.typeofJsValue(self.handle),
                    };
                }

                pub fn tryTypeof(self: Self) module.Error!module.JsType {
                    if (self.handle <= module.reserved_global_this_handle) {
                        if (!isJsThread()) return error.OffJsThread;
                        return self.typeof();
                    }
                    if (@hasDecl(host, "tryTypeofJsValue")) {
                        return host.tryTypeofJsValue(self.handle);
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    return host.typeofJsValue(self.handle);
                }

                pub fn instanceof(self: Self, ctor: anytype) bool {
                    return host.instanceofJsValue(self.handle, extractHandle(ctor));
                }

                pub fn tryInstanceof(self: Self, ctor: anytype) module.Error!bool {
                    if (@hasDecl(host, "tryInstanceofJsValue")) {
                        return host.tryInstanceofJsValue(self.handle, extractHandle(ctor));
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    return host.instanceofJsValue(self.handle, extractHandle(ctor));
                }

                pub fn eql(self: Self, other: anytype) bool {
                    const rhs_handle = extractHandle(other);
                    if (self.handle <= module.reserved_global_this_handle and rhs_handle <= module.reserved_global_this_handle) {
                        return self.handle == rhs_handle;
                    }
                    return host.equalJsValue(self.handle, rhs_handle);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    const rhs_handle = extractHandle(other);
                    if (self.handle <= module.reserved_global_this_handle and rhs_handle <= module.reserved_global_this_handle) {
                        if (!isJsThread()) return error.OffJsThread;
                        return self.handle == rhs_handle;
                    }
                    if (@hasDecl(host, "tryEqualJsValue")) {
                        return host.tryEqualJsValue(self.handle, rhs_handle);
                    }
                    if (!isJsThread()) return error.OffJsThread;
                    return host.equalJsValue(self.handle, rhs_handle);
                }

                pub inline fn cast(self: Self, comptime U: type) Ref(U) {
                    return .{ .handle = self.handle };
                }

                pub fn get(self: Self, comptime RT: type, comptime name: []const u8) RT {
                    return JsNs.getProp(RT, self, name);
                }

                pub fn getAlloc(self: Self, allocator: std.mem.Allocator, comptime RT: type, comptime name: []const u8) RT {
                    return JsNs.getPropAlloc(allocator, RT, self, name);
                }

                pub fn getDynamic(self: Self, comptime RT: type, key: anytype) RT {
                    return JsNs.getPropDynamic(RT, self, key);
                }

                pub fn getDynamicAlloc(self: Self, allocator: std.mem.Allocator, comptime RT: type, key: anytype) RT {
                    return JsNs.getPropDynamicAlloc(allocator, RT, self, key);
                }

                pub fn getSym(self: Self, comptime RT: type, sym: anytype) RT {
                    return JsNs.getPropSym(RT, self, sym);
                }

                pub fn set(self: Self, comptime name: []const u8, value: anytype) void {
                    JsNs.setProp(self, name, value);
                }

                pub fn trySet(self: Self, comptime name: []const u8, value: anytype) module.CallError!void {
                    return JsNs.trySetProp(self, name, value);
                }

                pub fn setDynamic(self: Self, key: anytype, value: anytype) void {
                    JsNs.setPropDynamic(self, key, value);
                }

                pub fn trySetDynamic(self: Self, key: anytype, value: anytype) module.CallError!void {
                    return JsNs.trySetPropDynamic(self, key, value);
                }

                pub fn setSym(self: Self, sym: anytype, value: anytype) void {
                    JsNs.setPropSym(self, sym, value);
                }

                pub fn has(self: Self, comptime name: []const u8) bool {
                    return JsNs.hasProp(self, name);
                }

                pub fn tryHas(self: Self, comptime name: []const u8) module.CallError!bool {
                    return JsNs.tryHasProp(self, name);
                }

                pub fn hasDynamic(self: Self, key: anytype) bool {
                    return JsNs.hasPropDynamic(self, key);
                }

                pub fn delete(self: Self, comptime name: []const u8) bool {
                    return JsNs.deleteProp(self, name);
                }

                pub fn tryDelete(self: Self, comptime name: []const u8) module.CallError!bool {
                    return JsNs.tryDeleteProp(self, name);
                }

                pub fn deleteDynamic(self: Self, key: anytype) bool {
                    return JsNs.deletePropDynamic(self, key);
                }

                pub fn call(self: Self, comptime FnSig: type, comptime name: []const u8, args: anytype) FnReturnType(FnSig) {
                    return JsNs.callMethod(FnSig, self, name, args);
                }

                pub fn tryCall(self: Self, comptime FnSig: type, comptime name: []const u8, args: anytype) EnsureJsErrorReturn(FnReturnType(FnSig)) {
                    return JsNs.callMethod(WrapFnWithJsError(FnSig), self, name, args);
                }

                pub fn callDynamic(self: Self, comptime FnSig: type, key: anytype, args: anytype) FnReturnType(FnSig) {
                    return JsNs.callMethodDynamic(FnSig, self, key, args);
                }

                pub fn tryCallDynamic(self: Self, comptime FnSig: type, key: anytype, args: anytype) EnsureJsErrorReturn(FnReturnType(FnSig)) {
                    return JsNs.callMethodDynamic(WrapFnWithJsError(FnSig), self, key, args);
                }

                pub fn callSym(self: Self, comptime FnSig: type, sym: anytype, args: anytype) FnReturnType(FnSig) {
                    return JsNs.callMethodSym(FnSig, self, sym, args);
                }

                pub fn tryCallSym(self: Self, comptime FnSig: type, sym: anytype, args: anytype) EnsureJsErrorReturn(FnReturnType(FnSig)) {
                    return JsNs.callMethodSym(WrapFnWithJsError(FnSig), self, sym, args);
                }

                pub fn invoke(self: Self, comptime FnSig: type, args: anytype) FnReturnType(FnSig) {
                    return JsNs.callFn(FnSig, self, args);
                }

                pub fn tryInvoke(self: Self, comptime FnSig: type, args: anytype) EnsureJsErrorReturn(FnReturnType(FnSig)) {
                    return JsNs.callFn(WrapFnWithJsError(FnSig), self, args);
                }

                pub fn new(self: Self, comptime CtorSig: type, args: anytype) FnReturnType(CtorSig) {
                    return JsNs.construct(CtorSig, self, args);
                }

                pub fn tryNew(self: Self, comptime CtorSig: type, args: anytype) EnsureJsErrorReturn(FnReturnType(CtorSig)) {
                    return JsNs.construct(WrapFnWithJsError(CtorSig), self, args);
                }

                pub fn construct(self: Self, comptime CtorSig: type, args: anytype) FnReturnType(CtorSig) {
                    return JsNs.construct(CtorSig, self, args);
                }

                pub fn tryConstruct(self: Self, comptime CtorSig: type, args: anytype) EnsureJsErrorReturn(FnReturnType(CtorSig)) {
                    return JsNs.construct(WrapFnWithJsError(CtorSig), self, args);
                }
            };
        }

        fn needsAllocatorForRead(comptime T: type) bool {
            if (comptime util.getInternalType(T) == .js_value) return false;
            return switch (@typeInfo(T)) {
                .pointer => |pt| pt.size == .slice,
                .optional => |opt| needsAllocatorForRead(opt.child),
                .@"struct" => |st| blk: {
                    for (st.field_types, 0..) |ft, i| {
                        if (!st.field_attrs[i].@"comptime" and needsAllocatorForRead(ft)) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
        }

        fn deinitOwnedElement(comptime ElemT: type, allocator: std.mem.Allocator, value: ElemT) void {
            if (comptime util.getInternalType(ElemT) == .js_value) {
                const r: Ref(module.Any) = .{ .handle = value.handle };
                r.deinit();
                return;
            }
            switch (@typeInfo(ElemT)) {
                .pointer => |pt| if (pt.size == .slice) {
                    for (value) |sub| {
                        deinitOwnedElement(pt.child, allocator, sub);
                    }
                    allocator.free(value);
                },
                .optional => |opt| if (value) |inner| {
                    deinitOwnedElement(opt.child, allocator, inner);
                },
                .@"struct" => |st| {
                    inline for (st.field_names, 0..) |fname, i| {
                        if (!st.field_attrs[i].@"comptime") {
                            deinitOwnedElement(st.field_types[i], allocator, @field(value, fname));
                        }
                    }
                },
                else => {},
            }
        }

        fn unwrapPromiseOrErrorPayload(comptime RawT: type) type {
            const NoErrT = switch (@typeInfo(RawT)) {
                .error_union => |eu| eu.payload,
                else => RawT,
            };
            return switch (@typeInfo(NoErrT)) {
                .@"struct" => if (@hasDecl(NoErrT, "is_js_promise") and NoErrT.is_js_promise) NoErrT.Payload else NoErrT,
                else => NoErrT,
            };
        }

        fn extractHandlerPayloadType(comptime H: type) ?type {
            const BaseT = switch (@typeInfo(H)) {
                .pointer => |pt| if (pt.size == .one) pt.child else H,
                else => H,
            };
            return switch (@typeInfo(BaseT)) {
                .@"struct" => if (@hasDecl(BaseT, "is_zig_callback") and BaseT.is_zig_callback and @hasDecl(BaseT, "ReturnType"))
                    unwrapPromiseOrErrorPayload(BaseT.ReturnType)
                else
                    null,
                else => null,
            };
        }

        fn coerceOptionalHandler(h: anytype) Ref(module.Any) {
            const H = @TypeOf(h);
            if (H == @TypeOf(null) or H == @TypeOf(undefined)) {
                return Ref(module.Any).@"undefined";
            }
            return .{ .handle = extractHandle(h) };
        }

        fn binaryCreateCall(comptime OutT: type, comptime kind: module.BinaryKind, ptr_addr: usize, len_or_count: usize, copy_from_zig: bool) module.Error!OutT {
            const HostFn = buildFnType(&.{ usize, usize, bool }, module.Error!OutT);
            return dispatchHostOpRawFlags(.binary_create, @intFromEnum(kind), "", HostFn, .{ ptr_addr, len_or_count, copy_from_zig });
        }

        fn binaryReadCall(handle: u32, dest_bytes: []u8, src_byte_offset: usize) module.Error!usize {
            const dest_addr: usize = if (dest_bytes.len > 0) @intFromPtr(dest_bytes.ptr) else 0;
            const HostFn = buildFnType(&.{ Ref(module.Any), usize, usize, usize }, module.Error!usize);
            return dispatchHostOpRawFlags(
                .binary_read,
                0,
                "",
                HostFn,
                .{ .{ .handle = handle }, dest_addr, dest_bytes.len, src_byte_offset },
            );
        }

        fn binaryWriteCall(handle: u32, src_bytes: []const u8, dst_byte_offset: usize) module.Error!void {
            const src_addr: usize = if (src_bytes.len > 0) @intFromPtr(src_bytes.ptr) else 0;
            const HostFn = buildFnType(&.{ Ref(module.Any), usize, usize, usize }, module.Error!void);
            return dispatchHostOpRawFlags(
                .binary_write,
                0,
                "",
                HostFn,
                .{ .{ .handle = handle }, src_addr, src_bytes.len, dst_byte_offset },
            );
        }

        fn binarySizeInfoCall(comptime info_kind: module.BinaryInfoKind, handle: u32) module.Error!usize {
            const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!usize);
            return dispatchHostOpRawFlags(.binary_info, @intFromEnum(info_kind), "", HostFn, .{.{ .handle = handle }});
        }

        fn binaryBoolInfoCall(comptime info_kind: module.BinaryInfoKind, handle: u32) module.Error!bool {
            const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!bool);
            return dispatchHostOpRawFlags(.binary_info, @intFromEnum(info_kind), "", HostFn, .{.{ .handle = handle }});
        }

        /// Strongly typed wrapper for a JS `Promise<T>` (or thenable).
        ///
        /// Ownership: `.await()` and `.awaitAlloc()` borrow `self` without consuming its handle,
        /// so `defer p.deinit()` works uniformly whether awaiting succeeds or fails, and the same
        /// `Promise(T)` may be awaited multiple times (matching JS `await p; await p;`).
        pub fn Promise(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Payload = T;
                pub const is_js_promise = true;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub const AwaitError = if (typeNeedsRefDecode(T, 0)) module.CallError else module.Error;
                pub const AwaitAllocError = if (typeNeedsRefDecode(T, 0)) module.CallError else module.AllocError;

                pub fn @"await"(self: Self) AwaitError!T {
                    if (comptime typeNeedsRefDecode(T, 0)) {
                        const raw = try dispatchAwaitOp(.promise, Ref(module.Any), false, self.handle, {}, null);
                        defer raw.deinit();
                        return try fromJsRef(T, raw);
                    }
                    return dispatchAwaitOp(.promise, T, false, self.handle, {}, null);
                }

                pub const wait = @"await";

                pub fn awaitAlloc(self: Self, allocator: std.mem.Allocator) AwaitAllocError!T {
                    if (comptime typeNeedsRefDecode(T, 0)) {
                        const raw = try dispatchAwaitOp(.promise, Ref(module.Any), false, self.handle, {}, null);
                        defer raw.deinit();
                        return try fromJsRefAlloc(T, allocator, raw);
                    }
                    return dispatchAwaitOp(.promise, T, true, self.handle, allocator, null);
                }

                pub const waitAlloc = awaitAlloc;

                pub fn resolve(value: anytype) module.Error!Self {
                    if (@TypeOf(value) == void) {
                        const HostFn = buildFnType(&.{}, module.Error!Self);
                        return dispatchHostOpRawFlags(.promise_settle, 2, "", HostFn, .{});
                    }
                    const ValT = NormalizedValueType(@TypeOf(value));
                    const HostFn = buildFnType(&.{ValT}, module.Error!Self);
                    return dispatchHostOpRawFlags(.promise_settle, 0, "", HostFn, .{normalizeValue(value)});
                }

                pub fn resolveVoid() module.Error!Promise(void) {
                    const HostFn = buildFnType(&.{}, module.Error!Promise(void));
                    return dispatchHostOpRawFlags(.promise_settle, 2, "", HostFn, .{});
                }

                pub fn reject(reason: anytype) module.Error!Self {
                    const ValT = NormalizedValueType(@TypeOf(reason));
                    const HostFn = buildFnType(&.{ValT}, module.Error!Self);
                    return dispatchHostOpRawFlags(.promise_settle, 1, "", HostFn, .{normalizeValue(reason)});
                }

                fn InferThenPayload(comptime FulfilledT: type, comptime RejectedT: type) type {
                    if (FulfilledT == @TypeOf(null) or FulfilledT == @TypeOf(undefined)) {
                        if (T == void) {
                            if (extractHandlerPayloadType(RejectedT)) |rej_t| return rej_t;
                        }
                        return T;
                    }
                    if (extractHandlerPayloadType(FulfilledT)) |ful_t| {
                        return ful_t;
                    }
                    return Ref(module.Any);
                }

                pub fn thenAs(self: Self, comptime R: type, on_fulfilled: anytype, on_rejected: anytype) module.Error!Promise(R) {
                    const HostFn = buildFnType(&.{ Ref(module.Any), Ref(module.Any), Ref(module.Any) }, module.Error!Promise(R));
                    return dispatchHostOp(
                        .call_method,
                        .{},
                        "then",
                        HostFn,
                        .{
                            .{ .handle = self.handle },
                            coerceOptionalHandler(on_fulfilled),
                            coerceOptionalHandler(on_rejected),
                        },
                    );
                }

                pub fn then(self: Self, on_fulfilled: anytype, on_rejected: anytype) module.Error!Promise(InferThenPayload(@TypeOf(on_fulfilled), @TypeOf(on_rejected))) {
                    const R = InferThenPayload(@TypeOf(on_fulfilled), @TypeOf(on_rejected));
                    return self.thenAs(R, on_fulfilled, on_rejected);
                }

                pub fn catchError(self: Self, on_rejected: anytype) module.Error!Promise(T) {
                    return self.thenAs(T, null, on_rejected);
                }
            };
        }

        fn ByteBufferLike(comptime kind: module.BinaryKind) type {
            return extern struct {
                const Self = @This();
                pub const binary_kind = kind;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn init(byte_len: usize) module.Error!Self {
                    return binaryCreateCall(Self, kind, 0, byte_len, false);
                }

                pub fn fromSlice(bytes: []const u8) module.Error!Self {
                    const ptr_addr: usize = if (bytes.len > 0) @intFromPtr(bytes.ptr) else 0;
                    return binaryCreateCall(Self, kind, ptr_addr, bytes.len, true);
                }

                pub fn byteLength(self: Self) module.Error!usize {
                    return binarySizeInfoCall(.byte_length, self.handle);
                }

                pub const len = byteLength;

                pub fn slice(self: Self, begin: isize, end: ?isize) module.Error!Self {
                    const HostFn = buildFnType(&.{ Ref(module.Any), isize, bool, isize }, module.Error!Self);
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.binary_slice),
                        "",
                        HostFn,
                        .{ .{ .handle = self.handle }, begin, end != null, end orelse 0 },
                    );
                }

                pub fn copyTo(self: Self, dest: []u8) module.Error!usize {
                    return binaryReadCall(self.handle, dest, 0);
                }

                pub fn copyToOffset(self: Self, dest: []u8, src_byte_offset: usize) module.Error!usize {
                    return binaryReadCall(self.handle, dest, src_byte_offset);
                }

                pub fn writeFrom(self: Self, src: []const u8) module.Error!void {
                    return binaryWriteCall(self.handle, src, 0);
                }

                pub fn writeFromOffset(self: Self, src: []const u8, dst_byte_offset: usize) module.Error!void {
                    return binaryWriteCall(self.handle, src, dst_byte_offset);
                }

                pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                    const total = try self.byteLength();
                    const out = try allocator.alloc(u8, total);
                    errdefer allocator.free(out);
                    if (total > 0) {
                        const n = try self.copyTo(out);
                        if (n != total) return error.JsException;
                    }
                    return out;
                }
            };
        }

        pub const ArrayBuffer = ByteBufferLike(.array_buffer);
        pub const SharedArrayBuffer = ByteBufferLike(.shared_array_buffer);

        pub const DataView = extern struct {
            const Self = @This();
            pub const binary_kind: module.BinaryKind = .data_view;
            pub const internal_type: util.InternalType = .js_value;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }

            pub fn init(ab: anytype, byte_offset: usize, maybe_byte_len: ?usize) module.Error!Self {
                const HostFn = buildFnType(&.{ Ref(module.Any), usize, bool, usize }, module.Error!Self);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.data_view_init),
                    "",
                    HostFn,
                    .{ .{ .handle = extractHandle(ab) }, byte_offset, maybe_byte_len != null, maybe_byte_len orelse 0 },
                );
            }

            pub fn fromSlice(bytes: []const u8) module.Error!Self {
                const ptr_addr: usize = if (bytes.len > 0) @intFromPtr(bytes.ptr) else 0;
                return binaryCreateCall(Self, .data_view, ptr_addr, bytes.len, true);
            }

            pub fn byteLength(self: Self) module.Error!usize {
                return binarySizeInfoCall(.byte_length, self.handle);
            }

            pub fn byteOffset(self: Self) module.Error!usize {
                return binarySizeInfoCall(.byte_offset, self.handle);
            }

            pub fn buffer(self: Self) module.Error!ArrayBuffer {
                const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!ArrayBuffer);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.binary_get_buffer),
                    "",
                    HostFn,
                    .{.{ .handle = self.handle }},
                );
            }

            pub fn getUint8(self: Self, offset: usize) module.Error!u8 {
                return self.ref().tryCall(fn (usize) u8, "getUint8", .{offset});
            }

            pub fn setUint8(self: Self, offset: usize, value: u8) module.Error!void {
                return self.ref().tryCall(fn (usize, u8) void, "setUint8", .{ offset, value });
            }

            pub fn getInt8(self: Self, offset: usize) module.Error!i8 {
                return self.ref().tryCall(fn (usize) i8, "getInt8", .{offset});
            }

            pub fn setInt8(self: Self, offset: usize, value: i8) module.Error!void {
                return self.ref().tryCall(fn (usize, i8) void, "setInt8", .{ offset, value });
            }

            pub fn getUint16(self: Self, offset: usize, little_endian: bool) module.Error!u16 {
                return self.ref().tryCall(fn (usize, bool) u16, "getUint16", .{ offset, little_endian });
            }

            pub fn setUint16(self: Self, offset: usize, value: u16, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, u16, bool) void, "setUint16", .{ offset, value, little_endian });
            }

            pub fn getInt16(self: Self, offset: usize, little_endian: bool) module.Error!i16 {
                return self.ref().tryCall(fn (usize, bool) i16, "getInt16", .{ offset, little_endian });
            }

            pub fn setInt16(self: Self, offset: usize, value: i16, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, i16, bool) void, "setInt16", .{ offset, value, little_endian });
            }

            pub fn getUint32(self: Self, offset: usize, little_endian: bool) module.Error!u32 {
                return self.ref().tryCall(fn (usize, bool) u32, "getUint32", .{ offset, little_endian });
            }

            pub fn setUint32(self: Self, offset: usize, value: u32, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, u32, bool) void, "setUint32", .{ offset, value, little_endian });
            }

            pub fn getInt32(self: Self, offset: usize, little_endian: bool) module.Error!i32 {
                return self.ref().tryCall(fn (usize, bool) i32, "getInt32", .{ offset, little_endian });
            }

            pub fn setInt32(self: Self, offset: usize, value: i32, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, i32, bool) void, "setInt32", .{ offset, value, little_endian });
            }

            pub fn getBigUint64(self: Self, offset: usize, little_endian: bool) module.Error!u64 {
                return self.ref().tryCall(fn (usize, bool) u64, "getBigUint64", .{ offset, little_endian });
            }

            pub fn setBigUint64(self: Self, offset: usize, value: u64, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, u64, bool) void, "setBigUint64", .{ offset, value, little_endian });
            }

            pub fn getBigInt64(self: Self, offset: usize, little_endian: bool) module.Error!i64 {
                return self.ref().tryCall(fn (usize, bool) i64, "getBigInt64", .{ offset, little_endian });
            }

            pub fn setBigInt64(self: Self, offset: usize, value: i64, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, i64, bool) void, "setBigInt64", .{ offset, value, little_endian });
            }

            pub fn getFloat32(self: Self, offset: usize, little_endian: bool) module.Error!f32 {
                return self.ref().tryCall(fn (usize, bool) f32, "getFloat32", .{ offset, little_endian });
            }

            pub fn setFloat32(self: Self, offset: usize, value: f32, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, f32, bool) void, "setFloat32", .{ offset, value, little_endian });
            }

            pub fn getFloat64(self: Self, offset: usize, little_endian: bool) module.Error!f64 {
                return self.ref().tryCall(fn (usize, bool) f64, "getFloat64", .{ offset, little_endian });
            }

            pub fn setFloat64(self: Self, offset: usize, value: f64, little_endian: bool) module.Error!void {
                return self.ref().tryCall(fn (usize, f64, bool) void, "setFloat64", .{ offset, value, little_endian });
            }

            pub fn copyTo(self: Self, dest: []u8) module.Error!usize {
                return binaryReadCall(self.handle, dest, 0);
            }

            pub fn writeFrom(self: Self, src: []const u8) module.Error!void {
                return binaryWriteCall(self.handle, src, 0);
            }

            pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                const total = try self.byteLength();
                const out = try allocator.alloc(u8, total);
                errdefer allocator.free(out);
                if (total > 0) {
                    const n = try self.copyTo(out);
                    if (n != total) return error.JsException;
                }
                return out;
            }
        };

        pub const Uint8Clamped = enum(u8) { _ };

        fn typedArrayKindForElem(comptime Elem: type) module.BinaryKind {
            return switch (Elem) {
                u8 => .uint8_array,
                i8 => .int8_array,
                Uint8Clamped => .uint8_clamped_array,
                u16 => .uint16_array,
                i16 => .int16_array,
                u32 => .uint32_array,
                i32 => .int32_array,
                u64 => .big_uint64_array,
                i64 => .big_int64_array,
                f32 => .float32_array,
                f64 => .float64_array,
                else => @compileError("Unsupported TypedArray element type: " ++ @typeName(Elem)),
            };
        }

        pub fn TypedArrayKind(comptime Elem: type, comptime kind: module.BinaryKind) type {
            return extern struct {
                const Self = @This();
                pub const Element = Elem;
                pub const binary_kind = kind;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn init(length: usize) module.Error!Self {
                    return binaryCreateCall(Self, kind, 0, length, false);
                }

                pub fn fromSlice(items: []const Elem) module.Error!Self {
                    const ptr_addr: usize = if (items.len > 0) @intFromPtr(items.ptr) else 0;
                    return binaryCreateCall(Self, kind, ptr_addr, items.len, true);
                }

                pub fn len(self: Self) module.Error!usize {
                    return binarySizeInfoCall(.element_length, self.handle);
                }

                pub fn byteLength(self: Self) module.Error!usize {
                    return binarySizeInfoCall(.byte_length, self.handle);
                }

                pub fn byteOffset(self: Self) module.Error!usize {
                    return binarySizeInfoCall(.byte_offset, self.handle);
                }

                pub fn buffer(self: Self) module.Error!ArrayBuffer {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!ArrayBuffer);
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.binary_get_buffer),
                        "",
                        HostFn,
                        .{.{ .handle = self.handle }},
                    );
                }

                pub fn get(self: Self, index: usize) module.Error!Elem {
                    const WireElem = if (Elem == Uint8Clamped) u8 else Elem;
                    const HostFn = buildFnType(&.{ Ref(module.Any), usize }, module.Error!WireElem);
                    const raw = try dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.typed_array_get),
                        "",
                        HostFn,
                        .{ .{ .handle = self.handle }, index },
                    );
                    return if (Elem == Uint8Clamped) @enumFromInt(raw) else raw;
                }

                pub fn set(self: Self, index: usize, value: Elem) module.Error!void {
                    const WireElem = if (Elem == Uint8Clamped) u8 else Elem;
                    const wire_val: WireElem = if (Elem == Uint8Clamped) @intFromEnum(value) else value;
                    const HostFn = buildFnType(&.{ Ref(module.Any), usize, WireElem }, module.Error!void);
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.typed_array_set),
                        "",
                        HostFn,
                        .{ .{ .handle = self.handle }, index, wire_val },
                    );
                }

                pub fn subarray(self: Self, start: usize, end: ?usize) module.Error!Self {
                    if (end) |end_idx| {
                        return callMethod(fn (usize, usize) module.Error!Self, self, "subarray", .{ start, end_idx });
                    } else {
                        return callMethod(fn (usize) module.Error!Self, self, "subarray", .{start});
                    }
                }

                pub fn copyTo(self: Self, dest: []Elem) module.Error!usize {
                    _ = try self.len();
                    const dest_bytes: []u8 = std.mem.sliceAsBytes(dest);
                    const copied_bytes = try binaryReadCall(self.handle, dest_bytes, 0);
                    return copied_bytes / @sizeOf(Elem);
                }

                pub fn writeFrom(self: Self, src: []const Elem) module.Error!void {
                    _ = try self.len();
                    const src_bytes: []const u8 = std.mem.sliceAsBytes(src);
                    return binaryWriteCall(self.handle, src_bytes, 0);
                }

                pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) module.AllocError![]Elem {
                    const count = try self.len();
                    const out = try allocator.alloc(Elem, count);
                    errdefer allocator.free(out);
                    if (count > 0) {
                        const dest_bytes: []u8 = std.mem.sliceAsBytes(out);
                        const copied_bytes = try binaryReadCall(self.handle, dest_bytes, 0);
                        if (copied_bytes != count * @sizeOf(Elem)) return error.JsException;
                    }
                    return out;
                }
            };
        }

        pub fn TypedArray(comptime Elem: type) type {
            const ActualElem = if (Elem == Uint8Clamped) u8 else Elem;
            return TypedArrayKind(ActualElem, typedArrayKindForElem(Elem));
        }

        pub const Uint8Array = TypedArray(u8);
        pub const Int8Array = TypedArray(i8);
        pub const Uint8ClampedArray = TypedArrayKind(u8, .uint8_clamped_array);
        pub const Uint16Array = TypedArray(u16);
        pub const Int16Array = TypedArray(i16);
        pub const Uint32Array = TypedArray(u32);
        pub const Int32Array = TypedArray(i32);
        pub const BigUint64Array = TypedArray(u64);
        pub const BigInt64Array = TypedArray(i64);
        pub const Float32Array = TypedArray(f32);
        pub const Float64Array = TypedArray(f64);

        pub const Buffer = extern struct {
            const Self = @This();
            pub const binary_kind: module.BinaryKind = .buffer;
            pub const internal_type: util.InternalType = .js_value;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }

            pub fn alloc(size: usize) module.Error!Self {
                return binaryCreateCall(Self, .buffer, 0, size, false);
            }

            pub fn fromSlice(bytes: []const u8) module.Error!Self {
                const ptr_addr: usize = if (bytes.len > 0) @intFromPtr(bytes.ptr) else 0;
                return binaryCreateCall(Self, .buffer, ptr_addr, bytes.len, true);
            }

            pub fn fromString(str: []const u8) module.Error!Self {
                const HostFn = buildFnType(&.{[]const u8}, module.Error!Self);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.buffer_from_string),
                    "",
                    HostFn,
                    .{str},
                );
            }

            pub fn byteLength(self: Self) module.Error!usize {
                return binarySizeInfoCall(.byte_length, self.handle);
            }

            pub const len = byteLength;

            pub fn byteOffset(self: Self) module.Error!usize {
                return binarySizeInfoCall(.byte_offset, self.handle);
            }

            pub fn buffer(self: Self) module.Error!ArrayBuffer {
                const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!ArrayBuffer);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.binary_get_buffer),
                    "",
                    HostFn,
                    .{.{ .handle = self.handle }},
                );
            }

            pub fn get(self: Self, index: usize) module.Error!u8 {
                const HostFn = buildFnType(&.{ Ref(module.Any), usize }, module.Error!u8);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.typed_array_get),
                    "",
                    HostFn,
                    .{ .{ .handle = self.handle }, index },
                );
            }

            pub fn set(self: Self, index: usize, value: u8) module.Error!void {
                const HostFn = buildFnType(&.{ Ref(module.Any), usize, u8 }, module.Error!void);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.typed_array_set),
                    "",
                    HostFn,
                    .{ .{ .handle = self.handle }, index, value },
                );
            }

            pub fn subarray(self: Self, start: usize, end: ?usize) module.Error!Self {
                if (end) |end_idx| {
                    return callMethod(fn (usize, usize) module.Error!Self, self, "subarray", .{ start, end_idx });
                } else {
                    return callMethod(fn (usize) module.Error!Self, self, "subarray", .{start});
                }
            }

            pub fn copyTo(self: Self, dest: []u8) module.Error!usize {
                return binaryReadCall(self.handle, dest, 0);
            }

            pub fn copyToAt(self: Self, dest: []u8, offset: usize) module.Error!usize {
                return binaryReadCall(self.handle, dest, offset);
            }

            pub fn writeFrom(self: Self, src: []const u8) module.Error!void {
                return binaryWriteCall(self.handle, src, 0);
            }

            pub fn writeFromAt(self: Self, src: []const u8, offset: usize) module.Error!void {
                return binaryWriteCall(self.handle, src, offset);
            }

            pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                const total = try self.byteLength();
                const out = try allocator.alloc(u8, total);
                errdefer allocator.free(out);
                if (total > 0) {
                    const n = try self.copyTo(out);
                    if (n != total) return error.JsException;
                }
                return out;
            }

            pub fn toStringAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any) }, module.AllocError![]u8);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.buffer_to_string),
                    "",
                    HostFn,
                    .{ allocator, .{ .handle = self.handle } },
                );
            }

            pub fn isBuffer(value: anytype) module.Error!bool {
                return binaryBoolInfoCall(.is_buffer, extractHandle(value));
            }
        };

        pub const Disposable = extern struct {
            const Self = @This();
            pub const is_js_disposable = true;
            pub const internal_type: util.InternalType = .js_value;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn dispose(self: Self) void {
                self.ref().dispose();
            }

            pub fn tryDispose(self: Self) module.Error!void {
                return self.ref().tryDispose();
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn releaseHandleOnly(self: Self) void {
                self.ref().deinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }
        };

        pub const AsyncDisposable = extern struct {
            const Self = @This();
            pub const is_js_async_disposable = true;
            pub const internal_type: util.InternalType = .js_value;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn asyncDispose(self: Self) void {
                self.ref().asyncDispose();
            }

            pub fn tryAsyncDispose(self: Self) module.Error!void {
                return self.ref().tryAsyncDispose();
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }
        };

        pub fn Iterator(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Element = T;
                pub const Elem = T;
                pub const is_js_iterator = true;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn from(iterable: anytype) module.Error!Self {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Self);
                    return dispatchHostOpRawFlags(.get_iterator, 0, "", HostFn, .{.{ .handle = extractHandle(iterable) }});
                }

                pub const NextError = if (typeNeedsRefDecode(T, 0)) module.CallError else module.Error;
                pub const NextAllocError = if (typeNeedsRefDecode(T, 0)) module.CallError else module.AllocError;

                pub fn next(self: Self) NextError!?T {
                    var done_flag: u8 = 0;
                    if (comptime typeNeedsRefDecode(T, 0)) {
                        const maybe_raw = try dispatchHostOpOptionalFlag(
                            .iterator_next,
                            0,
                            Ref(module.Any),
                            module.Error,
                            &.{ Ref(module.Any), usize },
                            .{ .{ .handle = self.handle }, @intFromPtr(&done_flag) },
                            &done_flag,
                        );
                        const raw = maybe_raw orelse return null;
                        defer raw.deinit();
                        return try fromJsRef(T, raw);
                    }
                    return dispatchHostOpOptionalFlag(
                        .iterator_next,
                        0,
                        T,
                        module.Error,
                        &.{ Ref(module.Any), usize },
                        .{ .{ .handle = self.handle }, @intFromPtr(&done_flag) },
                        &done_flag,
                    );
                }

                pub fn nextAlloc(self: Self, allocator: std.mem.Allocator) NextAllocError!?T {
                    var done_flag: u8 = 0;
                    if (comptime typeNeedsRefDecode(T, 0)) {
                        const maybe_raw = try dispatchHostOpOptionalFlag(
                            .iterator_next,
                            0,
                            Ref(module.Any),
                            module.Error,
                            &.{ Ref(module.Any), usize },
                            .{ .{ .handle = self.handle }, @intFromPtr(&done_flag) },
                            &done_flag,
                        );
                        const raw = maybe_raw orelse return null;
                        defer raw.deinit();
                        return try fromJsRefAlloc(T, allocator, raw);
                    }
                    return dispatchHostOpOptionalFlag(
                        .iterator_next,
                        0,
                        T,
                        module.AllocError,
                        &.{ std.mem.Allocator, Ref(module.Any), usize },
                        .{ allocator, .{ .handle = self.handle }, @intFromPtr(&done_flag) },
                        &done_flag,
                    );
                }

                pub fn returnEarly(self: Self) module.Error!void {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!void);
                    return dispatchHostOpRawFlags(.iterator_return, 0, "", HostFn, .{.{ .handle = self.handle }});
                }

                pub const close = returnEarly;

                pub fn closeAndDeinit(self: Self) void {
                    self.returnEarly() catch {};
                    self.deinit();
                }
            };
        }

        pub fn AsyncIterator(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Element = T;
                pub const Elem = T;
                pub const is_js_async_iterator = true;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn from(async_iterable: anytype) module.Error!Self {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Self);
                    return dispatchHostOpRawFlags(.get_iterator, 1, "", HostFn, .{.{ .handle = extractHandle(async_iterable) }});
                }

                pub const NextError = if (typeNeedsRefDecode(T, 0)) module.CallError else module.Error;
                pub const NextAllocError = if (typeNeedsRefDecode(T, 0)) module.CallError else module.AllocError;

                pub fn next(self: Self) NextError!?T {
                    var done_flag: u8 = 0;
                    if (comptime typeNeedsRefDecode(T, 0)) {
                        const maybe_raw = try dispatchAwaitOp(.async_iterator_next, Ref(module.Any), false, self.handle, {}, &done_flag);
                        const raw = maybe_raw orelse return null;
                        defer raw.deinit();
                        return try fromJsRef(T, raw);
                    }
                    return dispatchAwaitOp(.async_iterator_next, T, false, self.handle, {}, &done_flag);
                }

                pub fn nextAlloc(self: Self, allocator: std.mem.Allocator) NextAllocError!?T {
                    var done_flag: u8 = 0;
                    if (comptime typeNeedsRefDecode(T, 0)) {
                        const maybe_raw = try dispatchAwaitOp(.async_iterator_next, Ref(module.Any), false, self.handle, {}, &done_flag);
                        const raw = maybe_raw orelse return null;
                        defer raw.deinit();
                        return try fromJsRefAlloc(T, allocator, raw);
                    }
                    return dispatchAwaitOp(.async_iterator_next, T, true, self.handle, allocator, &done_flag);
                }

                pub fn returnEarly(self: Self) module.Error!void {
                    return dispatchAwaitOp(.async_iterator_return, void, false, self.handle, {}, null);
                }

                pub const close = returnEarly;

                pub fn closeAndDeinit(self: Self) void {
                    self.returnEarly() catch {};
                    self.deinit();
                }
            };
        }

        pub fn Array(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Element = T;
                pub const Elem = T;
                pub const is_js_array = true;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn init() module.Error!Self {
                    const HostFn = buildFnType(&.{}, module.Error!Self);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.array_init), "", HostFn, .{});
                }

                pub fn withCapacity(capacity: usize) module.Error!Self {
                    const HostFn = buildFnType(&.{usize}, module.Error!Self);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.array_with_capacity), "", HostFn, .{capacity});
                }

                pub fn fromSlice(items: []const T) module.Error!Self {
                    const arr = try Self.withCapacity(items.len);
                    errdefer arr.deinit();
                    for (items, 0..) |item, idx| {
                        try arr.set(idx, item);
                    }
                    return arr;
                }

                pub fn isArray(value: anytype) module.Error!bool {
                    return binaryBoolInfoCall(.is_array, extractHandle(value));
                }

                pub fn len(self: Self) module.Error!usize {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!usize);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.array_len), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn get(self: Self, index: usize) module.Error!T {
                    const HostFn = buildFnType(&.{ Ref(module.Any), usize }, module.Error!T);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.array_get), "", HostFn, .{ .{ .handle = self.handle }, index });
                }

                pub fn getAlloc(self: Self, allocator: std.mem.Allocator, index: usize) module.AllocError!T {
                    const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any), usize }, module.AllocError!T);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.array_get), "", HostFn, .{ allocator, .{ .handle = self.handle }, index });
                }

                pub fn set(self: Self, index: usize, value: T) module.Error!void {
                    const HostFn = buildFnType(&.{ Ref(module.Any), usize, T }, module.Error!void);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.array_set), "", HostFn, .{ .{ .handle = self.handle }, index, value });
                }

                pub fn push(self: Self, value: T) module.Error!usize {
                    const HostFn = buildFnType(&.{ Ref(module.Any), T }, module.Error!usize);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.array_push), "", HostFn, .{ .{ .handle = self.handle }, value });
                }

                pub fn pop(self: Self) module.Error!?T {
                    var empty_flag: u8 = 0;
                    return dispatchHostOpOptionalFlag(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.array_pop),
                        T,
                        module.Error,
                        &.{ Ref(module.Any), usize },
                        .{ .{ .handle = self.handle }, @intFromPtr(&empty_flag) },
                        &empty_flag,
                    );
                }

                pub fn popAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError!?T {
                    var empty_flag: u8 = 0;
                    return dispatchHostOpOptionalFlag(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.array_pop),
                        T,
                        module.AllocError,
                        &.{ std.mem.Allocator, Ref(module.Any), usize },
                        .{ allocator, .{ .handle = self.handle }, @intFromPtr(&empty_flag) },
                        &empty_flag,
                    );
                }

                pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) module.AllocError![]T {
                    const count = try self.len();
                    const buf = try allocator.alloc(T, count);
                    var initialized: usize = 0;
                    errdefer {
                        for (buf[0..initialized]) |elem| {
                            deinitOwnedElement(T, allocator, elem);
                        }
                        allocator.free(buf);
                    }
                    while (initialized < count) : (initialized += 1) {
                        buf[initialized] = if (comptime needsAllocatorForRead(T))
                            try self.getAlloc(allocator, initialized)
                        else
                            try self.get(initialized);
                    }
                    return buf;
                }

                pub fn iterator(self: Self) module.Error!Iterator(T) {
                    return Iterator(T).from(self);
                }
            };
        }

        pub fn Map(comptime K: type, comptime V: type) type {
            return extern struct {
                const Self = @This();
                pub const Key = K;
                pub const Value = V;
                pub const Entry = struct { K, V };
                pub const is_js_map = true;
                pub const js_builtin_ctor = "Map";
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn init() module.Error!Self {
                    const HostFn = buildFnType(&.{}, module.Error!Self);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_init), "", HostFn, .{});
                }

                pub fn size(self: Self) module.Error!usize {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!usize);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_size), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn get(self: Self, key: K) module.Error!?V {
                    var missing_flag: u8 = 0;
                    return dispatchHostOpOptionalFlag(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.map_get),
                        V,
                        module.Error,
                        &.{ Ref(module.Any), K, usize },
                        .{ .{ .handle = self.handle }, key, @intFromPtr(&missing_flag) },
                        &missing_flag,
                    );
                }

                pub fn getAlloc(self: Self, allocator: std.mem.Allocator, key: K) module.AllocError!?V {
                    var missing_flag: u8 = 0;
                    return dispatchHostOpOptionalFlag(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.map_get),
                        V,
                        module.AllocError,
                        &.{ std.mem.Allocator, Ref(module.Any), K, usize },
                        .{ allocator, .{ .handle = self.handle }, key, @intFromPtr(&missing_flag) },
                        &missing_flag,
                    );
                }

                pub fn set(self: Self, key: K, value: V) module.Error!void {
                    const HostFn = buildFnType(&.{ Ref(module.Any), K, V }, module.Error!void);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_set), "", HostFn, .{ .{ .handle = self.handle }, key, value });
                }

                pub fn has(self: Self, key: K) module.Error!bool {
                    const HostFn = buildFnType(&.{ Ref(module.Any), K }, module.Error!bool);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_has), "", HostFn, .{ .{ .handle = self.handle }, key });
                }

                pub fn delete(self: Self, key: K) module.Error!bool {
                    const HostFn = buildFnType(&.{ Ref(module.Any), K }, module.Error!bool);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_delete), "", HostFn, .{ .{ .handle = self.handle }, key });
                }

                pub fn clear(self: Self) module.Error!void {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!void);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_clear), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn keys(self: Self) module.Error!Iterator(K) {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Iterator(K));
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_keys), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn values(self: Self) module.Error!Iterator(V) {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Iterator(V));
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_values), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn entries(self: Self) module.Error!Iterator(Entry) {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Iterator(Entry));
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.map_entries), "", HostFn, .{.{ .handle = self.handle }});
                }
            };
        }

        pub fn Set(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Element = T;
                pub const Elem = T;
                pub const is_js_set = true;
                pub const js_builtin_ctor = "Set";
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn init() module.Error!Self {
                    const HostFn = buildFnType(&.{}, module.Error!Self);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.set_init), "", HostFn, .{});
                }

                pub fn size(self: Self) module.Error!usize {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!usize);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.set_size), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn add(self: Self, value: T) module.Error!void {
                    const HostFn = buildFnType(&.{ Ref(module.Any), T }, module.Error!void);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.set_add), "", HostFn, .{ .{ .handle = self.handle }, value });
                }

                pub fn has(self: Self, value: T) module.Error!bool {
                    const HostFn = buildFnType(&.{ Ref(module.Any), T }, module.Error!bool);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.set_has), "", HostFn, .{ .{ .handle = self.handle }, value });
                }

                pub fn delete(self: Self, value: T) module.Error!bool {
                    const HostFn = buildFnType(&.{ Ref(module.Any), T }, module.Error!bool);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.set_delete), "", HostFn, .{ .{ .handle = self.handle }, value });
                }

                pub fn clear(self: Self) module.Error!void {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!void);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.set_clear), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn values(self: Self) module.Error!Iterator(T) {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Iterator(T));
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.set_values), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub const iterator = values;
            };
        }

        pub fn Record(comptime K: type, comptime V: type) type {
            if (@typeInfo(K) == .@"enum" and @typeInfo(K).@"enum".mode == .exhaustive) {
                return module.EnumRecord(K, V);
            }
            return extern struct {
                const Self = @This();
                pub const Key = K;
                pub const Value = V;
                pub const is_js_record = true;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };

                pub inline fn ref(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn toRef(self: Self) Ref(module.Object) {
                    return .{ .handle = self.handle };
                }

                pub inline fn fromRef(value: anytype) Self {
                    return .{ .handle = extractHandle(value) };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    return .{ .handle = self.ref().clone().handle };
                }

                pub fn tryClone(self: Self) module.Error!Self {
                    return .{ .handle = (try self.ref().tryClone()).handle };
                }

                pub fn deinit(self: Self) void {
                    self.ref().deinit();
                }

                pub fn tryDeinit(self: Self) module.Error!void {
                    return self.ref().tryDeinit();
                }

                pub fn eql(self: Self, other: anytype) bool {
                    return self.ref().eql(other);
                }

                pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                    return self.ref().tryEql(other);
                }

                pub fn init() module.Error!Self {
                    const HostFn = buildFnType(&.{}, module.Error!Self);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.record_init), "", HostFn, .{});
                }

                pub fn get(self: Self, key: K) module.Error!?V {
                    var missing_flag: u8 = 0;
                    return dispatchHostOpOptionalFlag(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.record_get),
                        V,
                        module.Error,
                        &.{ Ref(module.Any), K, usize },
                        .{ .{ .handle = self.handle }, key, @intFromPtr(&missing_flag) },
                        &missing_flag,
                    );
                }

                pub fn getAlloc(self: Self, allocator: std.mem.Allocator, key: K) module.AllocError!?V {
                    var missing_flag: u8 = 0;
                    return dispatchHostOpOptionalFlag(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.record_get),
                        V,
                        module.AllocError,
                        &.{ std.mem.Allocator, Ref(module.Any), K, usize },
                        .{ allocator, .{ .handle = self.handle }, key, @intFromPtr(&missing_flag) },
                        &missing_flag,
                    );
                }

                pub fn set(self: Self, key: K, value: V) module.Error!void {
                    const HostFn = buildFnType(&.{ Ref(module.Any), K, V }, module.Error!void);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.record_set), "", HostFn, .{ .{ .handle = self.handle }, key, value });
                }

                pub fn has(self: Self, key: K) module.Error!bool {
                    const HostFn = buildFnType(&.{ Ref(module.Any), K }, module.Error!bool);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.record_has), "", HostFn, .{ .{ .handle = self.handle }, key });
                }

                pub fn delete(self: Self, key: K) module.Error!bool {
                    const HostFn = buildFnType(&.{ Ref(module.Any), K }, module.Error!bool);
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.record_delete), "", HostFn, .{ .{ .handle = self.handle }, key });
                }

                pub fn keys(self: Self) module.Error!Array([]const u8) {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Array([]const u8));
                    return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.record_keys), "", HostFn, .{.{ .handle = self.handle }});
                }

                pub fn keysAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError![][]u8 {
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!Array([]u8));
                    const key_arr = try dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.record_keys), "", HostFn, .{.{ .handle = self.handle }});
                    defer key_arr.deinit();
                    return key_arr.toOwnedSlice(allocator);
                }
            };
        }

        pub const BigInt = extern struct {
            const Self = @This();
            pub const internal_type: util.InternalType = .js_value;
            pub const is_js_bigint = true;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Any) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Any) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }

            pub fn fromU64(v: u64) module.Error!Self {
                const HostFn = buildFnType(&.{ bool, u64, u64 }, module.Error!Self);
                return dispatchHostOpRawFlags(.bigint_from_words, 0, "", HostFn, .{ false, v, 0 });
            }

            pub fn fromI64(v: i64) module.Error!Self {
                const mag: u64 = @abs(v);
                const HostFn = buildFnType(&.{ bool, u64, u64 }, module.Error!Self);
                return dispatchHostOpRawFlags(.bigint_from_words, 0, "", HostFn, .{ v < 0, mag, 0 });
            }

            pub fn fromU128(v: u128) module.Error!Self {
                const lo: u64 = @truncate(v);
                const hi: u64 = @truncate(v >> 64);
                const HostFn = buildFnType(&.{ bool, u64, u64 }, module.Error!Self);
                return dispatchHostOpRawFlags(.bigint_from_words, 0, "", HostFn, .{ false, lo, hi });
            }

            pub fn fromI128(v: i128) module.Error!Self {
                const mag: u128 = @abs(v);
                const lo: u64 = @truncate(mag);
                const hi: u64 = @truncate(mag >> 64);
                const HostFn = buildFnType(&.{ bool, u64, u64 }, module.Error!Self);
                return dispatchHostOpRawFlags(.bigint_from_words, 0, "", HostFn, .{ v < 0, lo, hi });
            }

            pub fn fromString(s: []const u8) module.Error!Self {
                const HostFn = buildFnType(&.{[]const u8}, module.Error!Self);
                return dispatchHostOpRawFlags(.bigint_from_string, 0, "", HostFn, .{s});
            }

            fn extractWords(self: Self, comptime bit_width: u32, comptime is_signed: bool) module.OverflowError![2]u64 {
                var words: [2]u64 = .{ 0, 0 };
                const HostFn = buildFnType(&.{ Ref(module.Any), u32, bool, usize }, module.Error!u32);
                const status_code = try dispatchHostOpRawFlags(
                    .bigint_to_words,
                    0,
                    "",
                    HostFn,
                    .{ .{ .handle = self.handle }, bit_width, is_signed, @intFromPtr(&words) },
                );
                if (status_code != 0) return error.Overflow;
                return words;
            }

            pub fn toI64(self: Self) module.OverflowError!i64 {
                const words = try self.extractWords(64, true);
                return @bitCast(words[0]);
            }

            pub fn toU64(self: Self) module.OverflowError!u64 {
                const words = try self.extractWords(64, false);
                return words[0];
            }

            pub fn toI128(self: Self) module.OverflowError!i128 {
                const words = try self.extractWords(128, true);
                const combined: u128 = (@as(u128, words[1]) << 64) | @as(u128, words[0]);
                return @bitCast(combined);
            }

            pub fn toU128(self: Self) module.OverflowError!u128 {
                const words = try self.extractWords(128, false);
                return (@as(u128, words[1]) << 64) | @as(u128, words[0]);
            }

            pub fn toStringAlloc(self: Self, allocator: std.mem.Allocator, radix: u8) module.AllocError![]u8 {
                const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any), u32 }, module.AllocError![]u8);
                return dispatchHostOpRawFlags(
                    .bigint_to_string,
                    0,
                    "",
                    HostFn,
                    .{ allocator, .{ .handle = self.handle }, @as(u32, radix) },
                );
            }
        };

        pub const Date = extern struct {
            const Self = @This();
            pub const js_builtin_ctor = "Date";
            pub const internal_type: util.InternalType = .js_value;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }

            pub fn now() module.Error!f64 {
                const HostFn = buildFnType(&.{}, module.Error!f64);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.date_now), "", HostFn, .{});
            }

            pub fn fromTimestampMs(ms: f64) module.Error!Self {
                const HostFn = buildFnType(&.{f64}, module.Error!Self);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.date_from_ms), "", HostFn, .{ms});
            }

            pub fn fromIsoString(s: []const u8) module.Error!Self {
                const HostFn = buildFnType(&.{[]const u8}, module.Error!Self);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.date_from_iso), "", HostFn, .{s});
            }

            pub fn timestampMs(self: Self) module.Error!f64 {
                const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!f64);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.date_get_ms), "", HostFn, .{.{ .handle = self.handle }});
            }

            pub fn toIsoStringAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any) }, module.AllocError![]u8);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.date_to_iso), "", HostFn, .{ allocator, .{ .handle = self.handle } });
            }
        };

        pub const RegExp = extern struct {
            const Self = @This();
            pub const js_builtin_ctor = "RegExp";
            pub const internal_type: util.InternalType = .js_value;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Object) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }

            pub fn init(pattern: []const u8, flags: []const u8) module.Error!Self {
                const HostFn = buildFnType(&.{ []const u8, []const u8 }, module.Error!Self);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.regexp_init), "", HostFn, .{ pattern, flags });
            }

            pub fn testMatch(self: Self, input: []const u8) module.Error!bool {
                const HostFn = buildFnType(&.{ Ref(module.Any), []const u8 }, module.Error!bool);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.regexp_test), "", HostFn, .{ .{ .handle = self.handle }, input });
            }

            pub const @"test" = testMatch;

            pub fn sourceAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any) }, module.AllocError![]u8);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.regexp_source), "", HostFn, .{ allocator, .{ .handle = self.handle } });
            }

            pub fn flagsAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any) }, module.AllocError![]u8);
                return dispatchHostOpRawFlags(.collection_op, @intFromEnum(module.CollectionSubOp.regexp_flags), "", HostFn, .{ allocator, .{ .handle = self.handle } });
            }
        };

        pub const String = extern struct {
            const Self = @This();
            pub const internal_type: util.InternalType = .js_value;
            pub const is_js_string = true;

            handle: u32,

            pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
            pub const @"null": Self = .{ .handle = module.reserved_null_handle };

            pub inline fn ref(self: Self) Ref(module.Any) {
                return .{ .handle = self.handle };
            }

            pub inline fn toRef(self: Self) Ref(module.Any) {
                return .{ .handle = self.handle };
            }

            pub inline fn fromRef(value: anytype) Self {
                return .{ .handle = extractHandle(value) };
            }

            pub inline fn isUndefined(self: Self) bool {
                return self.handle == module.reserved_undefined_handle;
            }

            pub inline fn isNull(self: Self) bool {
                return self.handle == module.reserved_null_handle;
            }

            pub inline fn isNullOrUndefined(self: Self) bool {
                return self.handle <= module.reserved_null_handle;
            }

            pub inline fn isReserved(self: Self) bool {
                return self.handle < module.first_dynamic_slot;
            }

            pub fn clone(self: Self) Self {
                return .{ .handle = self.ref().clone().handle };
            }

            pub fn tryClone(self: Self) module.Error!Self {
                return .{ .handle = (try self.ref().tryClone()).handle };
            }

            pub fn deinit(self: Self) void {
                self.ref().deinit();
            }

            pub fn tryDeinit(self: Self) module.Error!void {
                return self.ref().tryDeinit();
            }

            pub fn eql(self: Self, other: anytype) bool {
                return self.ref().eql(other);
            }

            pub fn tryEql(self: Self, other: anytype) module.Error!bool {
                return self.ref().tryEql(other);
            }

            pub fn isString(value: anytype) module.Error!bool {
                const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!bool);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.string_is_string),
                    "",
                    HostFn,
                    .{.{ .handle = extractHandle(value) }},
                );
            }

            pub fn fromSlice(utf8: []const u8) module.Error!Self {
                const HostFn = buildFnType(&.{[]const u8}, module.Error!Self);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.string_from_utf8),
                    "",
                    HostFn,
                    .{utf8},
                );
            }

            pub fn empty() module.Error!Self {
                return fromSlice("");
            }

            pub fn byteLen(self: Self) module.Error!usize {
                const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!usize);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.string_byte_len),
                    "",
                    HostFn,
                    .{.{ .handle = self.handle }},
                );
            }

            pub const len = byteLen;

            pub fn utf16Len(self: Self) module.Error!usize {
                const HostFn = buildFnType(&.{Ref(module.Any)}, module.Error!usize);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.string_utf16_len),
                    "",
                    HostFn,
                    .{.{ .handle = self.handle }},
                );
            }

            pub fn toSliceAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError![]u8 {
                const HostFn = buildFnType(&.{ std.mem.Allocator, Ref(module.Any) }, module.AllocError![]u8);
                return dispatchHostOpRawFlags(
                    .collection_op,
                    @intFromEnum(module.CollectionSubOp.string_to_utf8),
                    "",
                    HostFn,
                    .{ allocator, .{ .handle = self.handle } },
                );
            }

            pub const toOwnedSlice = toSliceAlloc;
        };

        pub fn isNullableType(comptime T: type) bool {
            return @typeInfo(T) == .@"union" and @hasDecl(T, "is_zigar_nullable") and T.is_zigar_nullable;
        }

        pub fn isTupleStructType(comptime T: type) bool {
            return @typeInfo(T) == .@"struct" and util.getInternalType(T) == null and @hasDecl(T, "zigar_js_tuple");
        }

        fn seenContainsType(comptime seen: anytype, comptime T: type) bool {
            inline for (seen) |S| {
                if (S == T) return true;
            }
            return false;
        }

        fn needsDecodeAllocatorInner(comptime T: type, comptime seen: anytype) bool {
            if (comptime seenContainsType(seen, T)) return false;
            if (comptime util.getInternalType(T) == .js_value) return false;
            const next_seen = seen ++ .{T};
            return switch (@typeInfo(T)) {
                .void, .bool, .int, .float, .@"enum" => false,
                .pointer => |pt| switch (pt.size) {
                    .slice => true,
                    .one => @typeInfo(pt.child) != .@"fn",
                    else => false,
                },
                .optional => |op| needsDecodeAllocatorInner(op.child, next_seen),
                .array => |ar| needsDecodeAllocatorInner(ar.child, next_seen),
                .@"union" => |un| blk: {
                    if (isNullableType(T)) {
                        break :blk needsDecodeAllocatorInner(T.Value, next_seen);
                    }
                    inline for (un.field_types) |FieldType| {
                        if (needsDecodeAllocatorInner(FieldType, next_seen)) break :blk true;
                    }
                    break :blk false;
                },
                .@"struct" => |st| blk: {
                    inline for (st.field_types) |FieldType| {
                        if (needsDecodeAllocatorInner(FieldType, next_seen)) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
        }

        pub fn needsDecodeAllocator(comptime T: type) bool {
            return needsDecodeAllocatorInner(T, .{});
        }

        pub fn freeDecoded(comptime T: type, allocator: std.mem.Allocator, value: T) void {
            if (comptime util.getInternalType(T) == .js_value) {
                (Ref(module.Any){ .handle = extractHandle(value) }).deinit();
                return;
            }
            switch (@typeInfo(T)) {
                .void, .bool, .int, .float, .@"enum" => {},
                .pointer => |pt| switch (pt.size) {
                    .slice => {
                        if (pt.child != u8) {
                            for (value) |elem| {
                                freeDecoded(pt.child, allocator, elem);
                            }
                        }
                        allocator.free(value);
                    },
                    .one => {
                        if (comptime (@typeInfo(pt.child) != .@"fn")) {
                            freeDecoded(pt.child, allocator, value.*);
                            allocator.destroy(@constCast(value));
                        }
                    },
                    else => {},
                },
                .optional => |op| {
                    if (value) |v| {
                        freeDecoded(op.child, allocator, v);
                    }
                },
                .array => |ar| {
                    for (value) |elem| {
                        freeDecoded(ar.child, allocator, elem);
                    }
                },
                .@"union" => {
                    if (comptime isNullableType(T)) {
                        switch (value) {
                            .value => |v| freeDecoded(T.Value, allocator, v),
                            else => {},
                        }
                    } else {
                        switch (value) {
                            inline else => |payload| freeDecoded(@TypeOf(payload), allocator, payload),
                        }
                    }
                },
                .@"struct" => |st| {
                    inline for (st.field_names, 0..) |fname, fi| {
                        freeDecoded(st.field_types[fi], allocator, @field(value, fname));
                    }
                },
                else => {},
            }
        }

        fn resolveNullishTag(comptime raw: anytype) module.NullishKind {
            const RawT = @TypeOf(raw);
            if (RawT == module.NullishKind) return raw;
            return switch (@typeInfo(RawT)) {
                .enum_literal, .@"enum" => @field(module.NullishKind, @tagName(raw)),
                else => @compileError("Invalid nullish tag type: " ++ @typeName(RawT)),
            };
        }

        fn specSelfNullish(comptime spec: anytype) module.NullishKind {
            const SpecT = @TypeOf(spec);
            if (SpecT == module.NullishKind) return spec;
            return switch (@typeInfo(SpecT)) {
                .enum_literal, .@"enum" => resolveNullishTag(spec),
                .@"struct" => if (@hasField(SpecT, "self")) resolveNullishTag(spec.self) else .none,
                else => .none,
            };
        }

        fn tupleFieldIsOptional(comptime T: type, comptime idx: usize) bool {
            const meta = T.zigar_js_tuple;
            if (@hasField(@TypeOf(meta), "variadic_index")) {
                if (meta.variadic_index) |vi| {
                    if (idx == vi) return false;
                }
            }
            if (@hasField(@TypeOf(meta), "fields")) {
                if (idx < meta.fields.len) {
                    const fm = meta.fields[idx];
                    if (@hasField(@TypeOf(fm), "is_optional")) return fm.is_optional;
                }
                return false;
            }
            if (@hasField(@TypeOf(meta), "optional_mask") and idx < 64) {
                return ((meta.optional_mask >> @intCast(idx)) & 1) != 0;
            }
            const st = @typeInfo(T).@"struct";
            return st.field_attrs[idx].default_value_ptr != null and @typeInfo(st.field_types[idx]) == .optional;
        }

        fn tupleFieldNullishKind(comptime T: type, comptime idx: usize) module.NullishKind {
            const meta = T.zigar_js_tuple;
            if (@hasField(@TypeOf(meta), "null_only_mask") and idx < 64) {
                if (((meta.null_only_mask >> @intCast(idx)) & 1) != 0) {
                    return .null_only;
                }
            }
            if (tupleFieldIsOptional(T, idx)) return .undefined_only;
            return .null_or_undefined;
        }

        fn structFieldWireName(comptime T: type, comptime field_name: []const u8) []const u8 {
            if (module.hasStructZigarJsMeta(T)) {
                const meta = module.getStructZigarJsMeta(T);
                if (@hasField(@TypeOf(meta), "fields")) {
                    @setEvalBranchQuota(meta.fields.len * 64 + 4096);
                    inline for (meta.fields) |fm| {
                        if (std.mem.eql(u8, fm.name, field_name)) {
                            if (@hasField(@TypeOf(fm), "js_name")) return fm.js_name;
                            return field_name;
                        }
                    }
                }
            }
            return field_name;
        }

        fn structFieldWireNameAt(comptime T: type, comptime field_idx: usize, comptime field_name: []const u8) []const u8 {
            if (module.hasStructZigarJsMeta(T)) {
                const meta = module.getStructZigarJsMeta(T);
                if (@hasField(@TypeOf(meta), "fields")) {
                    @setEvalBranchQuota(meta.fields.len * 64 + 4096);
                    if (field_idx < meta.fields.len) {
                        const fm0 = meta.fields[field_idx];
                        if (std.mem.eql(u8, fm0.name, field_name)) {
                            if (@hasField(@TypeOf(fm0), "js_name")) return fm0.js_name;
                            return field_name;
                        }
                    }
                    inline for (meta.fields) |fm| {
                        if (std.mem.eql(u8, fm.name, field_name)) {
                            if (@hasField(@TypeOf(fm), "js_name")) return fm.js_name;
                            return field_name;
                        }
                    }
                }
            }
            return field_name;
        }

        fn structFieldIsOptional(comptime T: type, comptime field_idx: usize) bool {
            const st = @typeInfo(T).@"struct";
            const field_name = st.field_names[field_idx];
            if (module.hasStructZigarJsMeta(T)) {
                const meta = module.getStructZigarJsMeta(T);
                if (@hasField(@TypeOf(meta), "fields")) {
                    @setEvalBranchQuota(meta.fields.len * 64 + 4096);
                    if (field_idx < meta.fields.len) {
                        const fm0 = meta.fields[field_idx];
                        if (std.mem.eql(u8, fm0.name, field_name)) {
                            if (@hasField(@TypeOf(fm0), "is_optional")) return fm0.is_optional;
                        }
                    }
                    inline for (meta.fields) |fm| {
                        if (std.mem.eql(u8, fm.name, field_name)) {
                            if (@hasField(@TypeOf(fm), "is_optional")) return fm.is_optional;
                            break;
                        }
                    }
                }
            }
            return @typeInfo(st.field_types[field_idx]) == .optional and st.field_attrs[field_idx].default_value_ptr != null;
        }

        fn binaryIsKind(value: Ref(module.Any), kind: module.BinaryKind) module.Error!bool {
            const HostFn = buildFnType(&.{ Ref(module.Any), u32 }, module.Error!bool);
            return dispatchHostOpRawFlags(
                .collection_op,
                @intFromEnum(module.CollectionSubOp.binary_is_kind),
                "",
                HostFn,
                .{ value, @intFromEnum(kind) },
            );
        }

        fn structHasWireField(comptime T: type, comptime wire_target: []const u8) bool {
            const st = @typeInfo(T).@"struct";
            @setEvalBranchQuota(st.field_names.len * 128 + 4096);
            inline for (st.field_names, 0..) |fname, fi| {
                if (comptime module.isHiddenMetaField(fname)) continue;
                if (std.mem.eql(u8, structFieldWireNameAt(T, fi, fname), wire_target)) return true;
            }
            return false;
        }

        fn structFieldHasConstraint(comptime T: type, comptime field_name: []const u8) bool {
            if (!module.hasStructZigarJsMeta(T)) return false;
            const meta = module.getStructZigarJsMeta(T);
            if (!@hasField(@TypeOf(meta), "fields")) return false;
            @setEvalBranchQuota(meta.fields.len * 64 + 4096);
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, field_name)) {
                    const FmT = @TypeOf(fm);
                    return @hasField(FmT, "expected_str") or
                        @hasField(FmT, "expected_num") or
                        @hasField(FmT, "expected_bool") or
                        @hasField(FmT, "expected_bigint_i64") or
                        @hasField(FmT, "expected_bigint_str") or
                        @hasField(FmT, "expected_enum_tag");
                }
            }
            return false;
        }

        fn structFieldDisallowsNull(comptime T: type, comptime field_name: []const u8) bool {
            if (!module.hasStructZigarJsMeta(T)) return false;
            const meta = module.getStructZigarJsMeta(T);
            if (!@hasField(@TypeOf(meta), "fields")) return false;
            @setEvalBranchQuota(meta.fields.len * 64 + 4096);
            inline for (meta.fields) |fm| {
                if (std.mem.eql(u8, fm.name, field_name)) {
                    if (@hasField(@TypeOf(fm), "nullish")) {
                        const nk = specSelfNullish(fm.nullish);
                        return nk == .none or nk == .undefined_only;
                    }
                    return false;
                }
            }
            return false;
        }

        fn validateConcreteFieldConstraint(comptime fm: anytype, val: anytype) module.CallError!bool {
            const FmT = @TypeOf(fm);
            const ValT = @TypeOf(val);
            if (comptime @hasField(FmT, "expected_str")) {
                if (ValT == []const u8 or ValT == []u8) {
                    return std.mem.eql(u8, val, fm.expected_str);
                }
                return false;
            }
            if (comptime @hasField(FmT, "expected_num")) {
                if (@typeInfo(ValT) == .float) {
                    const expected: ValT = @floatCast(fm.expected_num);
                    return (val == expected) or (std.math.isNan(val) and std.math.isNan(expected));
                }
                if (@typeInfo(ValT) == .int) {
                    return @as(f64, @floatFromInt(val)) == fm.expected_num;
                }
                return false;
            }
            if (comptime @hasField(FmT, "expected_bool")) {
                if (ValT == bool) return val == fm.expected_bool;
                return false;
            }
            if (comptime @hasField(FmT, "expected_bigint_i64")) {
                if (ValT == i64) return val == fm.expected_bigint_i64;
                if (ValT == BigInt) {
                    const iv = val.toI64() catch return false;
                    return iv == fm.expected_bigint_i64;
                }
                return false;
            }
            if (comptime @hasField(FmT, "expected_bigint_str")) {
                if (ValT == BigInt) {
                    const expected_bi = try BigInt.fromString(fm.expected_bigint_str);
                    defer expected_bi.deinit();
                    return try val.tryEql(expected_bi);
                }
                if (ValT == i64) {
                    if (comptime @as(?i64, std.fmt.parseInt(i64, fm.expected_bigint_str, 0) catch null)) |iv| {
                        return val == iv;
                    }
                    return false;
                }
                return false;
            }
            if (comptime @hasField(FmT, "expected_enum_tag")) {
                if (@typeInfo(ValT) == .@"enum") {
                    return val == @field(ValT, fm.expected_enum_tag);
                }
                return false;
            }
            return true;
        }

        fn validateStructFieldConstraint(comptime T: type, comptime field_name: []const u8, val: anytype) module.CallError!bool {
            if (comptime !structFieldHasConstraint(T, field_name)) return true;
            const ValT = @TypeOf(val);
            if (comptime (@typeInfo(ValT) == .optional)) {
                if (val) |inner| {
                    return validateStructFieldConstraint(T, field_name, inner);
                }
                return true;
            }
            if (comptime isNullableType(ValT)) {
                return switch (val) {
                    .value => |inner| validateStructFieldConstraint(T, field_name, inner),
                    else => true,
                };
            }
            const meta = module.getStructZigarJsMeta(T);
            @setEvalBranchQuota(meta.fields.len * 64 + 4096);
            inline for (meta.fields) |fm| {
                if (comptime std.mem.eql(u8, fm.name, field_name)) {
                    return validateConcreteFieldConstraint(fm, val);
                }
            }
            return true;
        }

        fn resolveTargetCtorRef(comptime target: anytype) module.CallError!?Ref(module.Any) {
            const TargetT = @TypeOf(target);
            const mod_spec_opt: ?[]const u8 = comptime blk: {
                if (!@hasField(TargetT, "module")) break :blk null;
                const ModFieldT = @TypeOf(target.module);
                if (@typeInfo(ModFieldT) == .optional) break :blk target.module;
                break :blk target.module;
            };
            const is_def = comptime (@hasField(TargetT, "is_default") and target.is_default);
            const from_def = comptime (@hasField(TargetT, "from_default") and target.from_default);
            const has_ns = comptime (@hasField(TargetT, "ns_path") and target.ns_path.len > 0);

            if (comptime (is_def and mod_spec_opt != null and !has_ns)) {
                return try importModuleDefaultAs(module.CallError!Ref(module.Any), mod_spec_opt.?);
            }

            var cur: Ref(module.Any) = if (comptime (from_def and mod_spec_opt != null))
                try importModuleDefaultAs(module.CallError!Ref(module.Any), mod_spec_opt.?)
            else if (comptime (mod_spec_opt != null))
                .{ .handle = (try importModule(mod_spec_opt.?)).handle }
            else
                Ref(module.Any).globalThis;
            errdefer cur.deinit();

            if (comptime has_ns) {
                inline for (target.ns_path) |seg| {
                    if (cur.isNullOrUndefined()) {
                        cur.deinit();
                        return null;
                    }
                    const next = try getProp(module.CallError!Ref(module.Any), cur, seg);
                    cur.deinit();
                    cur = next;
                }
            }
            if (cur.isNullOrUndefined()) {
                cur.deinit();
                return null;
            }
            const out = try getProp(module.CallError!Ref(module.Any), cur, target.name);
            cur.deinit();
            return out;
        }

        fn encodeUnitLiteralDescriptor(comptime desc: anytype) module.CallError!Ref(module.Any) {
            const DescT = @TypeOf(desc);
            if (comptime @hasField(DescT, "str_value")) {
                return (try String.fromSlice(desc.str_value)).toRef();
            }
            if (comptime @hasField(DescT, "num_value")) {
                return toJsRefWithSpecImpl(f64, desc.num_value, module.NullishKind.none, .{});
            }
            if (comptime @hasField(DescT, "bool_value")) {
                return Ref(module.Any).fromBool(desc.bool_value);
            }
            if (comptime @hasField(DescT, "bigint_value")) {
                if (comptime @as(?i64, std.fmt.parseInt(i64, desc.bigint_value, 0) catch null)) |iv| {
                    return toJsRefWithSpecImpl(i64, iv, module.NullishKind.none, .{});
                }
                return (try BigInt.fromString(desc.bigint_value)).toRef();
            }
            return Ref(module.Any).@"undefined";
        }

        fn bigintRefMatchesLiteral(
            raw: Ref(module.Any),
            _: std.mem.Allocator,
            comptime lit: []const u8,
        ) module.CallError!bool {
            const expected_bi = try BigInt.fromString(lit);
            defer expected_bi.deinit();
            return try raw.tryEql(expected_bi);
        }

        fn maxEnumStrLen(comptime T: type) usize {
            @setEvalBranchQuota(T.zigar_js.members.len * 32 + 4096);
            var max_len: usize = 0;
            for (T.zigar_js.members) |m| {
                if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
                if (@hasField(@TypeOf(m), "str_value")) {
                    if (m.str_value.len > max_len) max_len = m.str_value.len;
                }
            }
            return max_len;
        }

        fn enumHasFieldKind(comptime T: type, comptime field_name: []const u8) bool {
            @setEvalBranchQuota(T.zigar_js.members.len * 32 + 4096);
            for (T.zigar_js.members) |m| {
                if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
                if (@hasField(@TypeOf(m), field_name)) return true;
            }
            return false;
        }

        fn enumIsPureIntBacked(comptime T: type) bool {
            const en_info = @typeInfo(T).@"enum";
            if (en_info.mode != .exhaustive) return false;
            if (en_info.tag_type != i32 and en_info.tag_type != i64) return false;
            if (!@hasDecl(T, "toInt") or !@hasDecl(T, "fromInt")) return false;
            @setEvalBranchQuota(T.zigar_js.members.len * 32 + 4096);
            var has_primary = false;
            for (T.zigar_js.members) |m| {
                if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
                has_primary = true;
                if (!@hasField(@TypeOf(m), "num_value")) return false;
                const tag_val = @field(T, m.tag);
                if (@as(f64, @floatFromInt(@intFromEnum(tag_val))) != m.num_value) return false;
            }
            return has_primary;
        }

        fn enumIsPureStrBacked(comptime T: type) bool {
            if (!@hasDecl(T, "toSlice") or !@hasDecl(T, "fromSlice")) return false;
            @setEvalBranchQuota(T.zigar_js.members.len * 32 + 4096);
            var has_primary = false;
            for (T.zigar_js.members) |m| {
                if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
                has_primary = true;
                if (!@hasField(@TypeOf(m), "str_value")) return false;
            }
            return has_primary;
        }

        fn unionHasUnitLiterals(comptime T: type) bool {
            if (!@hasDecl(T, "zigar_js")) return false;
            const meta = T.zigar_js;
            if (!@hasField(@TypeOf(meta), "variants")) return false;
            @setEvalBranchQuota(meta.variants.len * 32 + 4096);
            for (meta.variants) |vm| {
                if (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal) return true;
            }
            return false;
        }

        fn unionIsUnitLiteralField(comptime T: type, comptime fname: []const u8) bool {
            if (!@hasDecl(T, "zigar_js")) return false;
            const meta = T.zigar_js;
            if (!@hasField(@TypeOf(meta), "variants")) return false;
            @setEvalBranchQuota(meta.variants.len * 32 + 4096);
            for (meta.variants) |vm| {
                if (std.mem.eql(u8, vm.tag, fname)) {
                    return @hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal;
                }
            }
            return false;
        }

        fn maxUnionUnitStrLen(comptime T: type) usize {
            @setEvalBranchQuota(T.zigar_js.variants.len * 32 + 4096);
            var max_len: usize = 0;
            for (T.zigar_js.variants) |vm| {
                if (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal and @hasField(@TypeOf(vm), "str_value")) {
                    if (vm.str_value.len > max_len) max_len = vm.str_value.len;
                }
            }
            return max_len;
        }

        fn unionHasUnitKind(comptime T: type, comptime field_name: []const u8) bool {
            @setEvalBranchQuota(T.zigar_js.variants.len * 32 + 4096);
            for (T.zigar_js.variants) |vm| {
                if (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal and @hasField(@TypeOf(vm), field_name)) {
                    return true;
                }
            }
            return false;
        }

        fn tryMatchUnitLiteralVariant(
            comptime T: type,
            raw: Ref(module.Any),
            jt: module.JsType,
            allocator: std.mem.Allocator,
        ) module.CallError!?T {
            if (comptime !unionHasUnitLiterals(T)) return null;
            switch (jt) {
                .string => {
                    if (comptime !unionHasUnitKind(T, "str_value")) return null;
                    const max_len = comptime maxUnionUnitStrLen(T);
                    const js_str = String{ .handle = raw.handle };
                    const byte_len = try js_str.byteLen();
                    if (byte_len > max_len) return null;
                    if (comptime (max_len <= 4096)) {
                        var stack_buf: [if (max_len == 0) 16 else max_len + 16]u8 = undefined;
                        var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
                        const s = try js_str.toSliceAlloc(fba.allocator());
                        inline for (T.zigar_js.variants) |vm| {
                            if (comptime (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal and @hasField(@TypeOf(vm), "str_value"))) {
                                if (std.mem.eql(u8, s, vm.str_value)) return @unionInit(T, vm.tag, {});
                            }
                        }
                        return null;
                    } else {
                        const s = try js_str.toSliceAlloc(allocator);
                        defer allocator.free(s);
                        inline for (T.zigar_js.variants) |vm| {
                            if (comptime (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal and @hasField(@TypeOf(vm), "str_value"))) {
                                if (std.mem.eql(u8, s, vm.str_value)) return @unionInit(T, vm.tag, {});
                            }
                        }
                        return null;
                    }
                },
                .number => {
                    if (comptime !unionHasUnitKind(T, "num_value")) return null;
                    const n = try fromJsRefAlloc(f64, allocator, raw);
                    inline for (T.zigar_js.variants) |vm| {
                        if (comptime (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal and @hasField(@TypeOf(vm), "num_value"))) {
                            if (n == vm.num_value) return @unionInit(T, vm.tag, {});
                        }
                    }
                    return null;
                },
                .boolean => {
                    if (comptime !unionHasUnitKind(T, "bool_value")) return null;
                    const b = try fromJsRefAlloc(bool, allocator, raw);
                    inline for (T.zigar_js.variants) |vm| {
                        if (comptime (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal and @hasField(@TypeOf(vm), "bool_value"))) {
                            if (b == vm.bool_value) return @unionInit(T, vm.tag, {});
                        }
                    }
                    return null;
                },
                .bigint => {
                    if (comptime !unionHasUnitKind(T, "bigint_value")) return null;
                    inline for (T.zigar_js.variants) |vm| {
                        if (comptime (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal and @hasField(@TypeOf(vm), "bigint_value"))) {
                            if (try bigintRefMatchesLiteral(raw, allocator, vm.bigint_value)) {
                                return @unionInit(T, vm.tag, {});
                            }
                        }
                    }
                    return null;
                },
                else => return null,
            }
        }

        fn maxUnionDiscStrLen(comptime T: type) usize {
            @setEvalBranchQuota(T.zigar_js.variants.len * 64 + 4096);
            var max_len: usize = 0;
            for (T.zigar_js.variants) |vm| {
                if (@hasField(@TypeOf(vm), "disc_values")) {
                    for (vm.disc_values) |dv| {
                        if (@hasField(@TypeOf(dv), "str_value")) {
                            if (dv.str_value.len > max_len) max_len = dv.str_value.len;
                        }
                    }
                }
            }
            return max_len;
        }

        fn unionHasDiscKind(comptime T: type, comptime field_name: []const u8) bool {
            @setEvalBranchQuota(T.zigar_js.variants.len * 64 + 4096);
            for (T.zigar_js.variants) |vm| {
                if (@hasField(@TypeOf(vm), "disc_values")) {
                    for (vm.disc_values) |dv| {
                        if (@hasField(@TypeOf(dv), field_name)) return true;
                    }
                }
            }
            return false;
        }

        const max_tracked_decode_types: usize = 128;

        const TypeReachState = struct {
            visited: [max_tracked_decode_types]type = undefined,
            len: usize = 0,
            found: bool = false,
        };

        fn typeStateMarkOrSeen(comptime state_in: TypeReachState, comptime Cur: type) struct { seen: bool, state: TypeReachState } {
            for (state_in.visited[0..state_in.len]) |seen_t| {
                if (seen_t == Cur) return .{ .seen = true, .state = state_in };
            }
            var next = state_in;
            if (next.len >= max_tracked_decode_types) {
                next.found = true;
                return .{ .seen = true, .state = next };
            }
            next.visited[next.len] = Cur;
            next.len += 1;
            return .{ .seen = false, .state = next };
        }

        fn typeCanReachDecodeTarget(
            comptime Cur: type,
            comptime Target: type,
            comptime state_in: TypeReachState,
            comptime has_stepped: bool,
        ) TypeReachState {
            if (state_in.found or Cur == void) return state_in;
            if (isNullableType(Cur)) {
                return typeCanReachDecodeTarget(Cur.Value, Target, state_in, has_stepped);
            }
            if (util.getInternalType(Cur) == .js_value) return state_in;

            return switch (@typeInfo(Cur)) {
                .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .@"fn", .void, .noreturn, .null, .undefined => state_in,
                .optional => |opt| typeCanReachDecodeTarget(opt.child, Target, state_in, has_stepped),
                .pointer => |pt| switch (pt.size) {
                    .slice => blk: {
                        if (pt.child == u8) break :blk state_in;
                        if (has_stepped and Cur == Target) {
                            var hit = state_in;
                            hit.found = true;
                            break :blk hit;
                        }
                        const marked = typeStateMarkOrSeen(state_in, Cur);
                        if (marked.seen) break :blk marked.state;
                        break :blk typeCanReachDecodeTarget(pt.child, Target, marked.state, true);
                    },
                    .one => if (@typeInfo(pt.child) == .@"fn") state_in else typeCanReachDecodeTarget(pt.child, Target, state_in, has_stepped),
                    else => state_in,
                },
                .array => |ar| blk: {
                    if (has_stepped and Cur == Target) {
                        var hit = state_in;
                        hit.found = true;
                        break :blk hit;
                    }
                    const marked = typeStateMarkOrSeen(state_in, Cur);
                    if (marked.seen) break :blk marked.state;
                    break :blk typeCanReachDecodeTarget(ar.child, Target, marked.state, true);
                },
                .@"struct" => |st| blk: {
                    if (@hasDecl(Cur, "zigar_js")) {
                        const Meta = @TypeOf(Cur.zigar_js);
                        if (@hasField(Meta, "is_handle") and Cur.zigar_js.is_handle) break :blk state_in;
                        if (@hasField(Meta, "is_template_literal") and Cur.zigar_js.is_template_literal) break :blk state_in;
                        if (@hasField(Meta, "is_enum") and Cur.zigar_js.is_enum) break :blk state_in;
                    }
                    if (has_stepped and Cur == Target) {
                        var hit = state_in;
                        hit.found = true;
                        break :blk hit;
                    }
                    const marked = typeStateMarkOrSeen(state_in, Cur);
                    if (marked.seen) break :blk marked.state;
                    @setEvalBranchQuota(32_768);
                    var cur_state = marked.state;
                    for (st.field_names, st.field_types) |fname, ftype| {
                        if (module.isHiddenMetaField(fname)) continue;
                        cur_state = typeCanReachDecodeTarget(ftype, Target, cur_state, true);
                        if (cur_state.found) break :blk cur_state;
                    }
                    break :blk cur_state;
                },
                .@"union" => |un| blk: {
                    if (@hasDecl(Cur, "zigar_js")) {
                        const Meta = @TypeOf(Cur.zigar_js);
                        if (@hasField(Meta, "is_open_literal") and Cur.zigar_js.is_open_literal) break :blk state_in;
                    }
                    if (has_stepped and Cur == Target) {
                        var hit = state_in;
                        hit.found = true;
                        break :blk hit;
                    }
                    const marked = typeStateMarkOrSeen(state_in, Cur);
                    if (marked.seen) break :blk marked.state;
                    var cur_state = marked.state;
                    for (un.field_types) |ftype| {
                        cur_state = typeCanReachDecodeTarget(ftype, Target, cur_state, true);
                        if (cur_state.found) break :blk cur_state;
                    }
                    break :blk cur_state;
                },
                else => state_in,
            };
        }

        fn TypeSelfRecursionMemo(comptime T: type) type {
            return struct {
                const value: bool = blk: {
                    @setEvalBranchQuota(1_000_000);
                    break :blk typeCanReachDecodeTarget(T, T, .{}, false).found;
                };
            };
        }

        fn typeCanSelfRecurse(comptime T: type) bool {
            return TypeSelfRecursionMemo(T).value;
        }

        fn isContainerDecodeType(comptime T: type) bool {
            if (T == void) return false;
            if (isNullableType(T)) return false;
            if (util.getInternalType(T) == .js_value) return false;
            return switch (@typeInfo(T)) {
                .pointer => |pt| pt.size == .slice and pt.child != u8,
                .array => true,
                .@"struct" => |st| blk: {
                    if (st.field_names.len == 0) break :blk false;
                    if (isTupleStructType(T)) break :blk true;
                    if (@hasDecl(T, "zigar_js")) {
                        const Meta = @TypeOf(T.zigar_js);
                        if (@hasField(Meta, "is_template_literal") and T.zigar_js.is_template_literal) break :blk false;
                        if (@hasField(Meta, "is_enum") and T.zigar_js.is_enum) break :blk false;
                        if (@hasField(Meta, "is_handle") and T.zigar_js.is_handle) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            };
        }

        const DecodeAncestor = struct {
            anchor_handle: ?u32 = null,
            steps_since_teleport: usize = 0,
            teleport_limit: usize = 1,
        };

        const max_decode_depth: usize = 512;

        fn advanceDecodeCycle(
            comptime ContainerT: type,
            raw: Ref(module.Any),
            ancestor: DecodeAncestor,
        ) module.CallError!DecodeAncestor {
            if (comptime !typeCanSelfRecurse(ContainerT)) return ancestor;
            const anchor_h = ancestor.anchor_handle orelse return .{
                .anchor_handle = raw.handle,
                .steps_since_teleport = 0,
                .teleport_limit = 1,
            };
            if (anchor_h == raw.handle) return error.Overflow;
            const anc_ref: Ref(module.Any) = .{ .handle = anchor_h };
            if (try anc_ref.tryEql(raw)) return error.Overflow;
            const next_steps = ancestor.steps_since_teleport + 1;
            if (next_steps >= ancestor.teleport_limit) {
                return .{
                    .anchor_handle = raw.handle,
                    .steps_since_teleport = 0,
                    .teleport_limit = ancestor.teleport_limit *| 2,
                };
            }
            return .{
                .anchor_handle = anchor_h,
                .steps_since_teleport = next_steps,
                .teleport_limit = ancestor.teleport_limit,
            };
        }

        fn decodeDiscriminatedUnion(
            comptime T: type,
            allocator: std.mem.Allocator,
            raw: Ref(module.Any),
            jt: module.JsType,
            depth: usize,
            ancestor: DecodeAncestor,
        ) module.CallError!T {
            if (raw.isNullOrUndefined()) return error.TypeError;
            if (jt != .object and jt != .function) return error.TypeError;
            if (Array(Ref(module.Any)).isArray(raw) catch false) return error.TypeError;

            const disc_ref = try getProp(module.CallError!Ref(module.Any), raw.cast(module.Object), T.zigar_js.discriminant);
            defer disc_ref.deinit();
            if (disc_ref.isNullOrUndefined()) return error.TypeError;
            const disc_jt = try disc_ref.tryTypeof();

            switch (disc_jt) {
                .string => {
                    if (comptime !unionHasDiscKind(T, "str_value")) return error.TypeError;
                    const max_len = comptime maxUnionDiscStrLen(T);
                    const js_str = String{ .handle = disc_ref.handle };
                    const byte_len = try js_str.byteLen();
                    if (byte_len > max_len) return error.TypeError;
                    if (comptime (max_len <= 4096)) {
                        var stack_buf: [if (max_len == 0) 16 else max_len + 16]u8 = undefined;
                        var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
                        const s = try js_str.toSliceAlloc(fba.allocator());
                        inline for (T.zigar_js.variants) |vm| {
                            if (comptime @hasField(@TypeOf(vm), "disc_values")) {
                                inline for (vm.disc_values) |dv| {
                                    if (comptime @hasField(@TypeOf(dv), "str_value")) {
                                        if (std.mem.eql(u8, s, dv.str_value)) {
                                            const PayloadT = @FieldType(T, vm.tag);
                                            return @unionInit(T, vm.tag, try fromJsRefAllocInner(PayloadT, allocator, raw, depth, ancestor));
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        const s = try js_str.toSliceAlloc(allocator);
                        defer allocator.free(s);
                        inline for (T.zigar_js.variants) |vm| {
                            if (comptime @hasField(@TypeOf(vm), "disc_values")) {
                                inline for (vm.disc_values) |dv| {
                                    if (comptime @hasField(@TypeOf(dv), "str_value")) {
                                        if (std.mem.eql(u8, s, dv.str_value)) {
                                            const PayloadT = @FieldType(T, vm.tag);
                                            return @unionInit(T, vm.tag, try fromJsRefAllocInner(PayloadT, allocator, raw, depth, ancestor));
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return error.TypeError;
                },
                .number => {
                    if (comptime !unionHasDiscKind(T, "num_value")) return error.TypeError;
                    const n = try fromJsRefAlloc(f64, allocator, disc_ref);
                    inline for (T.zigar_js.variants) |vm| {
                        if (comptime @hasField(@TypeOf(vm), "disc_values")) {
                            inline for (vm.disc_values) |dv| {
                                if (comptime @hasField(@TypeOf(dv), "num_value")) {
                                    if (n == dv.num_value) {
                                        const PayloadT = @FieldType(T, vm.tag);
                                        return @unionInit(T, vm.tag, try fromJsRefAllocInner(PayloadT, allocator, raw, depth, ancestor));
                                    }
                                }
                            }
                        }
                    }
                    return error.TypeError;
                },
                .boolean => {
                    if (comptime !unionHasDiscKind(T, "bool_value")) return error.TypeError;
                    const b = try fromJsRefAlloc(bool, allocator, disc_ref);
                    inline for (T.zigar_js.variants) |vm| {
                        if (comptime @hasField(@TypeOf(vm), "disc_values")) {
                            inline for (vm.disc_values) |dv| {
                                if (comptime @hasField(@TypeOf(dv), "bool_value")) {
                                    if (b == dv.bool_value) {
                                        const PayloadT = @FieldType(T, vm.tag);
                                        return @unionInit(T, vm.tag, try fromJsRefAllocInner(PayloadT, allocator, raw, depth, ancestor));
                                    }
                                }
                            }
                        }
                    }
                    return error.TypeError;
                },
                .bigint => {
                    if (comptime !unionHasDiscKind(T, "bigint_value")) return error.TypeError;
                    inline for (T.zigar_js.variants) |vm| {
                        if (comptime @hasField(@TypeOf(vm), "disc_values")) {
                            inline for (vm.disc_values) |dv| {
                                if (comptime @hasField(@TypeOf(dv), "bigint_value")) {
                                    if (try bigintRefMatchesLiteral(disc_ref, allocator, dv.bigint_value)) {
                                        const PayloadT = @FieldType(T, vm.tag);
                                        return @unionInit(T, vm.tag, try fromJsRefAllocInner(PayloadT, allocator, raw, depth, ancestor));
                                    }
                                }
                            }
                        }
                    }
                    return error.TypeError;
                },
                else => return error.TypeError,
            }
        }

        fn computeTypeDecodeRank(comptime FieldT: type) u8 {
            if (FieldT == void) return 10;
            if (util.getInternalType(FieldT) == .js_value) {
                if (FieldT == BigInt) return 41;
                if (@hasDecl(FieldT, "binary_kind")) {
                    return switch (FieldT.binary_kind) {
                        .buffer => 50,
                        .array_buffer, .shared_array_buffer => 52,
                        else => 51,
                    };
                }
                if (@hasDecl(FieldT, "is_js_array") and FieldT.is_js_array) return 56;
                if (FieldT == String) return 60;
                if (@hasDecl(FieldT, "is_js_promise") and FieldT.is_js_promise) return 65;
                if (@hasDecl(FieldT, "js_builtin_ctor")) return 65;
                if (@hasDecl(FieldT, "is_js_async_iterator") and FieldT.is_js_async_iterator) return 73;
                if (@hasDecl(FieldT, "is_js_async_disposable") and FieldT.is_js_async_disposable) return 73;
                if (@hasDecl(FieldT, "is_js_iterator") and FieldT.is_js_iterator) return 74;
                if (@hasDecl(FieldT, "is_js_disposable") and FieldT.is_js_disposable) return 74;
                if (@hasDecl(FieldT, "is_js_record") and FieldT.is_js_record) return 90;
                if (@hasDecl(FieldT, "Target")) {
                    if (FieldT.Target == module.Symbol) return 45;
                    if (FieldT.Target == module.Function) return 75;
                    if (FieldT.Target == module.Object) return 90;
                }
                return 99;
            }
            if (isNullableType(FieldT)) return 95;
            return switch (@typeInfo(FieldT)) {
                .@"enum" => 20,
                .bool => 30,
                .int => |it| if (it.bits <= 32) 34 else 40,
                .float => 35,
                .pointer => |pt| switch (pt.size) {
                    .slice => if (pt.child == u8) 60 else 55,
                    .one => if (@typeInfo(pt.child) == .@"fn") 75 else computeTypeDecodeRank(pt.child),
                    else => 90,
                },
                .@"struct" => |st| blk: {
                    if (isTupleStructType(FieldT)) break :blk 54;
                    if (@hasDecl(FieldT, "zigar_js")) {
                        const meta = FieldT.zigar_js;
                        if (@hasField(@TypeOf(meta), "is_template_literal") and meta.is_template_literal) break :blk 25;
                        if (@hasField(@TypeOf(meta), "is_enum") and meta.is_enum) break :blk 98;
                        if (@hasField(@TypeOf(meta), "is_class") and meta.is_class) break :blk 70;
                        if (@hasField(@TypeOf(meta), "is_handle") and meta.is_handle) {
                            if (@hasField(@TypeOf(meta), "is_callable_handle") and meta.is_callable_handle) break :blk 71;
                            const has_proto = (module.structHasProtocolFlag(FieldT, "has_iterator", 0) or
                                module.structHasProtocolFlag(FieldT, "has_async_iterator", 0) or
                                module.structHasProtocolFlag(FieldT, "has_dispose", 0) or
                                module.structHasProtocolFlag(FieldT, "has_async_dispose", 0));
                            const has_methods = (@hasField(@TypeOf(meta), "required_methods") and meta.required_methods.len > 0);
                            const has_props = (@hasField(@TypeOf(meta), "required_props") and meta.required_props.len > 0);
                            const has_bases = (@hasField(@TypeOf(meta), "bases") and meta.bases.len > 0);
                            if (has_methods) break :blk 72;
                            if (has_proto and (has_props or has_bases)) break :blk 72;
                            if (has_proto) break :blk 74;
                            if (has_props) break :blk 79;
                            break :blk 86;
                        }
                    }
                    var has_constraint = false;
                    var has_required = false;
                    @setEvalBranchQuota(st.field_names.len * st.field_names.len * 32 + 4096);
                    for (st.field_names, 0..) |fname, fi| {
                        if (structFieldHasConstraint(FieldT, fname)) has_constraint = true;
                        if (!structFieldIsOptional(FieldT, fi)) has_required = true;
                    }
                    if (has_constraint) break :blk 78;
                    if (has_required) break :blk 80;
                    break :blk 85;
                },
                .@"union" => blk: {
                    if (@hasDecl(FieldT, "zigar_js") and @hasField(@TypeOf(FieldT.zigar_js), "is_open_literal") and FieldT.zigar_js.is_open_literal) {
                        break :blk 62;
                    }
                    if (@hasDecl(FieldT, "zigar_js") and @hasField(@TypeOf(FieldT.zigar_js), "discriminant")) {
                        break :blk 77;
                    }
                    break :blk 88;
                },
                .optional => 95,
                else => 95,
            };
        }

        fn nonUnitUnionFieldCount(comptime T: type) usize {
            const un = @typeInfo(T).@"union";
            var count: usize = 0;
            for (un.field_names, 0..) |fname, fi| {
                if (un.field_types[fi] == void and unionIsUnitLiteralField(T, fname)) continue;
                count += 1;
            }
            return count;
        }

        fn computeUnionDecodeOrder(comptime T: type) [nonUnitUnionFieldCount(T)]usize {
            const un = @typeInfo(T).@"union";
            const N = nonUnitUnionFieldCount(T);
            var indices: [N]usize = undefined;
            var ranks: [N]u8 = undefined;
            var pos: usize = 0;
            for (un.field_names, 0..) |fname, fi| {
                if (un.field_types[fi] == void and unionIsUnitLiteralField(T, fname)) continue;
                indices[pos] = fi;
                ranks[pos] = computeTypeDecodeRank(un.field_types[fi]);
                pos += 1;
            }
            var i: usize = 1;
            while (i < N) : (i += 1) {
                const key_idx = indices[i];
                const key_rank = ranks[i];
                var j: usize = i;
                while (j > 0 and ranks[j - 1] > key_rank) : (j -= 1) {
                    indices[j] = indices[j - 1];
                    ranks[j] = ranks[j - 1];
                }
                indices[j] = key_idx;
                ranks[j] = key_rank;
            }
            return indices;
        }

        fn stackHasSpecId(comptime stack: anytype, comptime target_id: []const u8) bool {
            inline for (stack) |entry| {
                if (@typeInfo(@TypeOf(entry)) == .@"struct" and
                    @hasField(@TypeOf(entry), "id") and
                    std.mem.eql(u8, entry.id, target_id))
                {
                    return true;
                }
            }
            return false;
        }

        fn ResolveSpecType(comptime raw_spec: anytype, comptime stack: anytype) type {
            if (@typeInfo(@TypeOf(raw_spec)) == .@"struct" and @hasField(@TypeOf(raw_spec), "recurse")) {
                for (stack) |entry| {
                    if (@typeInfo(@TypeOf(entry)) == .@"struct" and
                        @hasField(@TypeOf(entry), "id") and
                        std.mem.eql(u8, entry.id, raw_spec.recurse))
                    {
                        return @TypeOf(entry);
                    }
                }
                @compileError("unresolved nullish recurse id: " ++ raw_spec.recurse);
            }
            return @TypeOf(raw_spec);
        }

        fn resolveSpecFromStack(comptime raw_spec: anytype, comptime stack: anytype) ResolveSpecType(raw_spec, stack) {
            if (comptime (@typeInfo(@TypeOf(raw_spec)) == .@"struct" and @hasField(@TypeOf(raw_spec), "recurse"))) {
                inline for (stack) |entry| {
                    if (comptime (@typeInfo(@TypeOf(entry)) == .@"struct" and
                        @hasField(@TypeOf(entry), "id") and
                        std.mem.eql(u8, entry.id, raw_spec.recurse)))
                    {
                        return entry;
                    }
                }
                @compileError("unresolved nullish recurse id: " ++ raw_spec.recurse);
            }
            return raw_spec;
        }

        fn toJsRefWithSpecImpl(
            comptime T: type,
            value: T,
            comptime raw_spec: anytype,
            comptime ancestor_stack: anytype,
        ) module.CallError!Ref(module.Any) {
            const spec = comptime resolveSpecFromStack(raw_spec, ancestor_stack);
            const next_stack = comptime if (@typeInfo(@TypeOf(spec)) == .@"struct" and
                @hasField(@TypeOf(spec), "id") and
                !stackHasSpecId(ancestor_stack, spec.id))
                ancestor_stack ++ .{spec}
            else
                ancestor_stack;

            if (T == void) return Ref(module.Any).@"undefined";
            if (T == bool) return Ref(module.Any).fromBool(value);
            if (comptime util.getInternalType(T) == .js_value) {
                const r: Ref(module.Any) = .{ .handle = extractHandle(value) };
                return try r.tryClone();
            }
            if (comptime isNullableType(T)) {
                const child_spec = comptime if (@typeInfo(@TypeOf(spec)) == .@"struct" and @hasField(@TypeOf(spec), "child"))
                    spec.child
                else
                    module.NullishKind.none;
                return switch (value) {
                    .@"undefined" => Ref(module.Any).@"undefined",
                    .@"null" => Ref(module.Any).@"null",
                    .value => |v| toJsRefWithSpecImpl(T.Value, v, child_spec, next_stack),
                };
            }
            switch (@typeInfo(T)) {
                .optional => |op| {
                    if (value) |v| {
                        const child_spec = comptime if (@typeInfo(@TypeOf(spec)) == .@"struct" and @hasField(@TypeOf(spec), "child"))
                            spec.child
                        else
                            module.NullishKind.none;
                        return toJsRefWithSpecImpl(op.child, v, child_spec, next_stack);
                    }
                    return switch (comptime specSelfNullish(spec)) {
                        .undefined_only => Ref(module.Any).@"undefined",
                        .none, .null_only, .null_or_undefined => Ref(module.Any).@"null",
                    };
                },
                .comptime_int => {
                    if (comptime (value >= -9007199254740991 and value <= 9007199254740991)) {
                        return toJsRefWithSpecImpl(f64, @as(f64, @floatFromInt(value)), module.NullishKind.none, .{});
                    }
                    if (comptime (value >= std.math.minInt(i64) and value <= std.math.maxInt(i64))) {
                        return toJsRefWithSpecImpl(i64, @as(i64, value), module.NullishKind.none, .{});
                    }
                    return toJsRefWithSpecImpl(i128, @as(i128, value), module.NullishKind.none, .{});
                },
                .comptime_float => {
                    return toJsRefWithSpecImpl(f64, @as(f64, value), module.NullishKind.none, .{});
                },
                .null => {
                    return switch (comptime specSelfNullish(spec)) {
                        .undefined_only => Ref(module.Any).@"undefined",
                        .none, .null_only, .null_or_undefined => Ref(module.Any).@"null",
                    };
                },
                .int => |it| {
                    if (comptime (it.bits <= 32)) {
                        return toJsRefWithSpecImpl(f64, @floatFromInt(value), module.NullishKind.none, .{});
                    }
                    const HostFn = buildFnType(&.{T}, module.CallError!Ref(module.Any));
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.value_identity),
                        "",
                        HostFn,
                        .{value},
                    );
                },
                .float => {
                    const HostFn = buildFnType(&.{T}, module.CallError!Ref(module.Any));
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.value_identity),
                        "",
                        HostFn,
                        .{value},
                    );
                },
                .pointer => |pt| switch (pt.size) {
                    .slice => {
                        if (pt.child == u8) {
                            const str = try String.fromSlice(value);
                            return str.toRef();
                        }
                        const elem_spec = comptime if (@typeInfo(@TypeOf(spec)) == .@"struct" and @hasField(@TypeOf(spec), "elem"))
                            spec.elem
                        else
                            module.NullishKind.none;
                        const js_arr = try Array(Ref(module.Any)).withCapacity(value.len);
                        errdefer js_arr.deinit();
                        for (value, 0..) |elem, idx| {
                            const elem_ref = try toJsRefWithSpecImpl(pt.child, elem, elem_spec, next_stack);
                            defer elem_ref.deinit();
                            try js_arr.set(idx, elem_ref);
                        }
                        return .{ .handle = js_arr.handle };
                    },
                    .one => {
                        if (comptime (@typeInfo(pt.child) == .@"fn")) {
                            return error.TypeError;
                        }
                        if (comptime (@typeInfo(pt.child) == .array and @typeInfo(pt.child).array.child == u8)) {
                            const str = try String.fromSlice(value);
                            return str.toRef();
                        }
                        return toJsRefWithSpecImpl(pt.child, value.*, spec, next_stack);
                    },
                    else => @compileError("Unsupported pointer type for JS conversion: " ++ @typeName(T)),
                },
                .@"struct" => |st| {
                    if (comptime isTupleStructType(T)) {
                        const meta = T.zigar_js_tuple;
                        const var_idx_opt: ?usize = if (@hasField(@TypeOf(meta), "variadic_index")) meta.variadic_index else null;
                        const has_tuple_override = comptime (@typeInfo(@TypeOf(spec)) == .@"struct" and @hasField(@TypeOf(spec), "tuple"));
                        const js_arr = try Array(Ref(module.Any)).init();
                        errdefer js_arr.deinit();

                        if (comptime (var_idx_opt == null)) {
                            var effective_len: usize = st.field_names.len;
                            inline for (0..st.field_names.len) |rev_step| {
                                const fi = st.field_names.len - 1 - rev_step;
                                if (effective_len == fi + 1 and comptime tupleFieldIsOptional(T, fi) and @typeInfo(st.field_types[fi]) == .optional) {
                                    if (@field(value, st.field_names[fi]) == null) {
                                        effective_len = fi;
                                    }
                                }
                            }
                            inline for (st.field_names, 0..) |fname, fi| {
                                if (fi < effective_len) {
                                    const fspec = comptime blk: {
                                        if (has_tuple_override and fi < spec.tuple.len) {
                                            break :blk spec.tuple[fi];
                                        }
                                        if (@hasField(@TypeOf(meta), "fields") and fi < meta.fields.len and @hasField(@TypeOf(meta.fields[fi]), "nullish")) {
                                            break :blk meta.fields[fi].nullish;
                                        }
                                        break :blk tupleFieldNullishKind(T, fi);
                                    };
                                    const elem_ref = try toJsRefWithSpecImpl(st.field_types[fi], @field(value, fname), fspec, next_stack);
                                    defer elem_ref.deinit();
                                    _ = try js_arr.push(elem_ref);
                                }
                            }
                            return .{ .handle = js_arr.handle };
                        } else {
                            const v_idx: usize = comptime var_idx_opt.?;
                            const trailing_count: usize = comptime (st.field_names.len - 1 - v_idx);
                            const rest_slice = @field(value, st.field_names[v_idx]);
                            var leading_len: usize = v_idx;
                            if (trailing_count == 0 and rest_slice.len == 0) {
                                inline for (0..v_idx) |rev_step| {
                                    const fi = v_idx - 1 - rev_step;
                                    if (leading_len == fi + 1 and comptime tupleFieldIsOptional(T, fi) and @typeInfo(st.field_types[fi]) == .optional) {
                                        if (@field(value, st.field_names[fi]) == null) {
                                            leading_len = fi;
                                        }
                                    }
                                }
                            }
                            inline for (st.field_names, 0..) |fname, fi| {
                                const ftype = st.field_types[fi];
                                if (comptime (fi < v_idx)) {
                                    if (fi < leading_len) {
                                        const fspec = comptime blk: {
                                            if (has_tuple_override and fi < spec.tuple.len) {
                                                break :blk spec.tuple[fi];
                                            }
                                            if (@hasField(@TypeOf(meta), "fields") and fi < meta.fields.len and @hasField(@TypeOf(meta.fields[fi]), "nullish")) {
                                                break :blk meta.fields[fi].nullish;
                                            }
                                            break :blk tupleFieldNullishKind(T, fi);
                                        };
                                        const elem_ref = try toJsRefWithSpecImpl(ftype, @field(value, fname), fspec, next_stack);
                                        defer elem_ref.deinit();
                                        _ = try js_arr.push(elem_ref);
                                    }
                                } else if (comptime (fi == v_idx)) {
                                    const RestElem = @typeInfo(ftype).pointer.child;
                                    const rest_elem_spec = comptime blk: {
                                        if (has_tuple_override and fi < spec.tuple.len) {
                                            break :blk spec.tuple[fi];
                                        }
                                        if (@hasField(@TypeOf(meta), "fields") and fi < meta.fields.len and @hasField(@TypeOf(meta.fields[fi]), "nullish")) {
                                            break :blk meta.fields[fi].nullish;
                                        }
                                        break :blk module.NullishKind.none;
                                    };
                                    for (rest_slice) |re| {
                                        const elem_ref = try toJsRefWithSpecImpl(RestElem, re, rest_elem_spec, next_stack);
                                        defer elem_ref.deinit();
                                        _ = try js_arr.push(elem_ref);
                                    }
                                } else {
                                    const fspec = comptime blk: {
                                        if (has_tuple_override and fi < spec.tuple.len) {
                                            break :blk spec.tuple[fi];
                                        }
                                        if (@hasField(@TypeOf(meta), "fields") and fi < meta.fields.len and @hasField(@TypeOf(meta.fields[fi]), "nullish")) {
                                            break :blk meta.fields[fi].nullish;
                                        }
                                        break :blk tupleFieldNullishKind(T, fi);
                                    };
                                    const elem_ref = try toJsRefWithSpecImpl(ftype, @field(value, fname), fspec, next_stack);
                                    defer elem_ref.deinit();
                                    _ = try js_arr.push(elem_ref);
                                }
                            }
                            return .{ .handle = js_arr.handle };
                        }
                    }

                    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_template_literal") and T.zigar_js.is_template_literal)) {
                        if (!module.matchTemplatePattern(T.zigar_js, value.raw)) return error.TypeError;
                        return (try String.fromSlice(value.raw)).toRef();
                    }

                    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_enum") and T.zigar_js.is_enum and @hasField(T, "__zigar_value")) {
                        return toJsRefWithSpecImpl(@TypeOf(value.__zigar_value), value.__zigar_value, module.NullishKind.none, .{});
                    }

                    if (comptime (@hasDecl(T, "is_zig_callback") and T.is_zig_callback)) {
                        return .{ .handle = (try (@as(Ref(module.Any), .{ .handle = value.func.handle })).tryClone()).handle };
                    }

                    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_handle") and T.zigar_js.is_handle)) {
                        const ref_fname = comptime if (@hasField(@TypeOf(T.zigar_js), "ref_field")) T.zigar_js.ref_field else "ref";
                        const inner_ref = @field(value, ref_fname);
                        return .{ .handle = (try (@as(Ref(module.Any), .{ .handle = inner_ref.handle })).tryClone()).handle };
                    }

                    const has_fields_override = comptime (@typeInfo(@TypeOf(spec)) == .@"struct" and @hasField(@TypeOf(spec), "fields"));

                    const rec = try Record([]const u8, Ref(module.Any)).init();
                    errdefer rec.deinit();
                    const is_cls_out = comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_class") and T.zigar_js.is_class);
                    if (comptime (is_cls_out and @hasField(@TypeOf(T.zigar_js), "ctor_target"))) {
                        if (resolveTargetCtorRef(T.zigar_js.ctor_target)) |ctor_opt| {
                            if (ctor_opt) |ctor| {
                                defer ctor.deinit();
                                if (!ctor.isNullOrUndefined() and (try ctor.tryTypeof()) == .function) {
                                    const proto = try getProp(module.CallError!Ref(module.Any), ctor, "prototype");
                                    defer proto.deinit();
                                    if (!proto.isNullOrUndefined() and (try proto.tryTypeof()) == .object) {
                                        const obj_ctor = try getGlobal(module.CallError!Ref(module.Object), "Object");
                                        defer obj_ctor.deinit();
                                        try callMethod(
                                            fn (Ref(module.Any), Ref(module.Any)) module.CallError!void,
                                            obj_ctor,
                                            "setPrototypeOf",
                                            .{ @as(Ref(module.Any), .{ .handle = rec.handle }), proto },
                                        );
                                    }
                                }
                            }
                        } else |err| switch (err) {
                            error.OffJsThread, error.OutOfMemory => return err,
                            else => clearLastError(),
                        }
                    }
                    inline for (st.field_names, 0..) |fname, fi| {
                        if (comptime module.isHiddenMetaField(fname)) continue;
                        const ftype = st.field_types[fi];
                        const fval = @field(value, fname);
                        if (!(try validateStructFieldConstraint(T, fname, fval))) return error.TypeError;
                        const wire_key = comptime structFieldWireNameAt(T, fi, fname);
                        const is_opt = comptime structFieldIsOptional(T, fi);
                        const field_spec = comptime blk: {
                            @setEvalBranchQuota(st.field_names.len * 64 + 4096);
                            if (has_fields_override) {
                                if (fi < spec.fields.len and std.mem.eql(u8, spec.fields[fi].name, fname)) {
                                    if (@hasField(@TypeOf(spec.fields[fi]), "nullish")) break :blk spec.fields[fi].nullish;
                                } else {
                                    for (spec.fields) |fm| {
                                        if (std.mem.eql(u8, fm.name, fname)) {
                                            if (@hasField(@TypeOf(fm), "nullish")) break :blk fm.nullish;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (module.hasStructZigarJsMeta(T)) {
                                const meta = module.getStructZigarJsMeta(T);
                                if (@hasField(@TypeOf(meta), "fields")) {
                                    @setEvalBranchQuota(meta.fields.len * 64 + 4096);
                                    if (fi < meta.fields.len and std.mem.eql(u8, meta.fields[fi].name, fname)) {
                                        if (@hasField(@TypeOf(meta.fields[fi]), "nullish")) break :blk meta.fields[fi].nullish;
                                    } else {
                                        for (meta.fields) |fm| {
                                            if (std.mem.eql(u8, fm.name, fname)) {
                                                if (@hasField(@TypeOf(fm), "nullish")) break :blk fm.nullish;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                            break :blk module.NullishKind.null_or_undefined;
                        };
                        if (comptime (is_opt and isNullableType(ftype))) {
                            if (fval != .@"undefined") {
                                const prop_ref = try toJsRefWithSpecImpl(ftype, fval, field_spec, next_stack);
                                defer prop_ref.deinit();
                                try rec.set(wire_key, prop_ref);
                            }
                        } else if (comptime (is_opt and @typeInfo(ftype) == .optional)) {
                            if (fval != null) {
                                const prop_ref = try toJsRefWithSpecImpl(ftype, fval, field_spec, next_stack);
                                defer prop_ref.deinit();
                                try rec.set(wire_key, prop_ref);
                            }
                        } else {
                            const prop_ref = try toJsRefWithSpecImpl(ftype, fval, field_spec, next_stack);
                            defer prop_ref.deinit();
                            try rec.set(wire_key, prop_ref);
                        }
                    }
                    return .{ .handle = rec.handle };
                },
                .@"enum" => {
                    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "members")) {
                        if (comptime enumIsPureIntBacked(T)) {
                            return toJsRefWithSpecImpl(f64, @floatFromInt(value.toInt()), .none, next_stack);
                        }
                        if (comptime enumIsPureStrBacked(T)) {
                            return (try String.fromSlice(value.toSlice())).toRef();
                        }
                        @setEvalBranchQuota(T.zigar_js.members.len * 32 + 4096);
                        inline for (T.zigar_js.members) |m| {
                            if (comptime (@hasField(@TypeOf(m), "is_alias") and m.is_alias)) continue;
                            if (value == @field(T, m.tag)) {
                                return encodeUnitLiteralDescriptor(m);
                            }
                        }
                    }
                    return (try String.fromSlice(@tagName(value))).toRef();
                },
                .@"union" => |un| {
                    const has_variants_override = comptime (@typeInfo(@TypeOf(spec)) == .@"struct" and @hasField(@TypeOf(spec), "variants"));
                    inline for (un.field_names, 0..) |fname, fi| {
                        if (std.mem.eql(u8, @tagName(value), fname)) {
                            const PayloadT = un.field_types[fi];
                            if (comptime (PayloadT == void and @hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "variants"))) {
                                inline for (T.zigar_js.variants) |vm| {
                                    if (comptime std.mem.eql(u8, vm.tag, fname)) {
                                        if (comptime (@hasField(@TypeOf(vm), "is_unit_literal") and vm.is_unit_literal)) {
                                            return encodeUnitLiteralDescriptor(vm);
                                        }
                                    }
                                }
                            }
                            const variant_spec = comptime blk: {
                                if (has_variants_override) {
                                    for (spec.variants) |vo| {
                                        if (std.mem.eql(u8, vo.name, fname)) {
                                            if (@hasField(@TypeOf(vo), "nullish")) break :blk vo.nullish;
                                            break;
                                        }
                                    }
                                }
                                if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "variants")) {
                                    for (T.zigar_js.variants) |vm| {
                                        if (std.mem.eql(u8, vm.tag, fname)) {
                                            if (@hasField(@TypeOf(vm), "nullish")) break :blk vm.nullish;
                                            break;
                                        }
                                    }
                                }
                                break :blk module.NullishKind.null_or_undefined;
                            };
                            return toJsRefWithSpecImpl(PayloadT, @field(value, fname), variant_spec, next_stack);
                        }
                    }
                    unreachable;
                },
                .array => |ar| {
                    const elem_spec = comptime blk: {
                        if (@typeInfo(@TypeOf(spec)) == .@"struct" and @hasField(@TypeOf(spec), "elem")) {
                            break :blk spec.elem;
                        }
                        break :blk module.NullishKind.none;
                    };
                    const js_arr = try Array(Ref(module.Any)).withCapacity(ar.len);
                    errdefer js_arr.deinit();
                    for (value, 0..) |elem, idx| {
                        const elem_ref = try toJsRefWithSpecImpl(ar.child, elem, elem_spec, next_stack);
                        defer elem_ref.deinit();
                        try js_arr.set(idx, elem_ref);
                    }
                    return .{ .handle = js_arr.handle };
                },
                else => @compileError("Unsupported Zig type for JS conversion: " ++ @typeName(T)),
            }
        }

        pub fn toJsRefWithSpec(
            comptime T: type,
            value: T,
            comptime spec: anytype,
        ) module.CallError!Ref(module.Any) {
            return toJsRefWithSpecImpl(T, value, spec, .{});
        }

        pub fn toJsRefWithNullish(
            comptime T: type,
            value: T,
            comptime nullish_kind: module.NullishKind,
        ) module.CallError!Ref(module.Any) {
            return toJsRefWithSpec(T, value, nullish_kind);
        }

        pub fn toJsRef(comptime T: type, value: T) module.CallError!Ref(module.Any) {
            return toJsRefWithSpec(T, value, module.NullishKind.none);
        }

        fn hasCallableStringProp(raw: Ref(module.Any), comptime prop_name: []const u8) module.CallError!bool {
            if (raw.isNullOrUndefined()) return false;
            const jt = try raw.tryTypeof();
            if (jt != .object and jt != .function) return false;
            if (!(try raw.tryHas(prop_name))) return false;
            const fn_ref = try getProp(module.CallError!Ref(module.Any), raw, prop_name);
            defer fn_ref.deinit();
            return !fn_ref.isNullOrUndefined() and (try fn_ref.tryTypeof()) == .function;
        }

        pub fn hasProtocolSymbolMethod(
            raw: Ref(module.Any),
            comptime symbol_prop: []const u8,
            comptime fallback_for_key: ?[]const u8,
        ) module.CallError!bool {
            if (raw.isNullOrUndefined()) return false;
            const jt = try raw.tryTypeof();
            if (jt != .object and jt != .function) return false;
            const sym_ctor = getGlobal(module.CallError!Ref(module.Any), "Symbol") catch |err| switch (err) {
                error.OffJsThread, error.OutOfMemory, error.HostUnavailable => return err,
                else => {
                    clearLastError();
                    return false;
                },
            };
            defer sym_ctor.deinit();
            if (sym_ctor.isNullOrUndefined()) return false;

            if (getProp(module.CallError!Ref(module.Any), sym_ctor, symbol_prop)) |sym| {
                defer sym.deinit();
                if (!sym.isNullOrUndefined() and (try sym.tryTypeof()) == .symbol) {
                    const fn_ref = try getPropDynamic(module.CallError!Ref(module.Any), raw, sym);
                    defer fn_ref.deinit();
                    if (!fn_ref.isNullOrUndefined() and (try fn_ref.tryTypeof()) == .function) {
                        return true;
                    }
                }
            } else |err| switch (err) {
                error.OffJsThread, error.OutOfMemory, error.HostUnavailable => return err,
                else => clearLastError(),
            }

            if (comptime fallback_for_key) |fb_key| {
                if (callMethod(fn ([]const u8) module.CallError!Ref(module.Symbol), sym_ctor, "for", .{fb_key})) |fb_sym| {
                    defer fb_sym.deinit();
                    if (!fb_sym.isNullOrUndefined()) {
                        const fn_ref = try getPropDynamic(module.CallError!Ref(module.Any), raw, fb_sym);
                        defer fn_ref.deinit();
                        if (!fn_ref.isNullOrUndefined() and (try fn_ref.tryTypeof()) == .function) {
                            return true;
                        }
                    }
                } else |err| switch (err) {
                    error.OffJsThread, error.OutOfMemory, error.HostUnavailable => return err,
                    else => clearLastError(),
                }
            }
            return false;
        }

        pub fn fromJsRefAlloc(
            comptime T: type,
            allocator: std.mem.Allocator,
            value: anytype,
        ) module.CallError!T {
            const raw: Ref(module.Any) = .{ .handle = extractHandle(value) };
            return fromJsRefAllocInner(T, allocator, raw, 0, .{});
        }

        fn fromJsRefAllocInner(
            comptime T: type,
            allocator: std.mem.Allocator,
            raw: Ref(module.Any),
            depth: usize,
            ancestor: DecodeAncestor,
        ) module.CallError!T {
            if (T == void) return {};
            if (depth > max_decode_depth) return error.Overflow;
            if (comptime isNullableType(T)) {
                if (raw.isUndefined()) return .@"undefined";
                if (raw.isNull()) return .@"null";
                return .{ .value = try fromJsRefAllocInner(T.Value, allocator, raw, depth, ancestor) };
            }
            if (@typeInfo(T) == .optional) {
                if (raw.isNullOrUndefined()) return null;
                return try fromJsRefAllocInner(@typeInfo(T).optional.child, allocator, raw, depth, ancestor);
            }
            if (comptime util.getInternalType(T) == .js_value) {
                if (T == String) {
                    if (!(try String.isString(raw))) return error.TypeError;
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (T == BigInt) {
                    if ((try raw.tryTypeof()) != .bigint) return error.TypeError;
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "binary_kind")) {
                    if (!(try binaryIsKind(raw, T.binary_kind))) return error.TypeError;
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "is_js_array") and T.is_js_array) {
                    if (!(try Array(Ref(module.Any)).isArray(raw))) return error.TypeError;
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "is_js_record") and T.is_js_record) {
                    if (raw.isNullOrUndefined()) return error.TypeError;
                    const jt = try raw.tryTypeof();
                    if (jt != .object) return error.TypeError;
                    if (Array(Ref(module.Any)).isArray(raw) catch false) return error.TypeError;
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "is_js_promise") and T.is_js_promise) {
                    if (raw.isNullOrUndefined()) return error.TypeError;
                    const jt = try raw.tryTypeof();
                    if (jt != .object and jt != .function) return error.TypeError;
                    const then_ref = try getProp(module.CallError!Ref(module.Any), raw, "then");
                    defer then_ref.deinit();
                    if (then_ref.isNullOrUndefined() or (try then_ref.tryTypeof()) != .function) {
                        return error.TypeError;
                    }
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "is_js_disposable") and T.is_js_disposable) {
                    if (!(try hasProtocolSymbolMethod(raw, "dispose", "nodejs.dispose"))) {
                        return error.TypeError;
                    }
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "is_js_async_disposable") and T.is_js_async_disposable) {
                    if (!(try hasProtocolSymbolMethod(raw, "asyncDispose", "nodejs.asyncDispose")) and
                        !(try hasProtocolSymbolMethod(raw, "dispose", "nodejs.dispose")))
                    {
                        return error.TypeError;
                    }
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "is_js_iterator") and T.is_js_iterator) {
                    if (raw.isNullOrUndefined()) return error.TypeError;
                    const jt = try raw.tryTypeof();
                    if (jt != .object and jt != .function) return error.TypeError;
                    if (try hasProtocolSymbolMethod(raw, "iterator", null)) {
                        const ElemT = if (@hasDecl(T, "Elem")) T.Elem else T.Element;
                        const iter = try Iterator(ElemT).from(raw);
                        return .{ .handle = iter.handle };
                    }
                    if (try hasProtocolSymbolMethod(raw, "asyncIterator", null)) {
                        return error.TypeError;
                    }
                    if (try hasCallableStringProp(raw, "next")) {
                        return .{ .handle = (try raw.tryClone()).handle };
                    }
                    return error.TypeError;
                }
                if (@hasDecl(T, "is_js_async_iterator") and T.is_js_async_iterator) {
                    if (raw.isNullOrUndefined()) return error.TypeError;
                    const jt = try raw.tryTypeof();
                    if (jt != .object and jt != .function) return error.TypeError;
                    if (try hasProtocolSymbolMethod(raw, "asyncIterator", null)) {
                        const ElemT = if (@hasDecl(T, "Elem")) T.Elem else T.Element;
                        const iter = try AsyncIterator(ElemT).from(raw);
                        return .{ .handle = iter.handle };
                    }
                    if (try hasProtocolSymbolMethod(raw, "iterator", null)) {
                        return error.TypeError;
                    }
                    if (try hasCallableStringProp(raw, "next")) {
                        return .{ .handle = (try raw.tryClone()).handle };
                    }
                    return error.TypeError;
                }
                if (@hasDecl(T, "js_builtin_ctor")) {
                    if (raw.isNullOrUndefined()) return error.TypeError;
                    const jt = try raw.tryTypeof();
                    if (jt != .object) return error.TypeError;
                    if (getGlobal(module.CallError!Ref(module.Any), T.js_builtin_ctor)) |ctor| {
                        defer ctor.deinit();
                        if (!ctor.isNullOrUndefined() and (try ctor.tryTypeof()) == .function) {
                            if (!(try raw.tryInstanceof(ctor))) return error.TypeError;
                        }
                    } else |err| switch (err) {
                        error.OffJsThread, error.OutOfMemory => return err,
                        else => clearLastError(),
                    }
                    return .{ .handle = (try raw.tryClone()).handle };
                }
                if (@hasDecl(T, "Target")) {
                    if (T.Target == module.Symbol) {
                        if ((try raw.tryTypeof()) != .symbol) return error.TypeError;
                    } else if (T.Target == module.Function) {
                        if ((try raw.tryTypeof()) != .function) return error.TypeError;
                    } else if (T.Target == module.Object) {
                        if (raw.isNullOrUndefined()) return error.TypeError;
                        const jt = try raw.tryTypeof();
                        if (jt != .object and jt != .function) return error.TypeError;
                    }
                }
                return .{ .handle = (try raw.tryClone()).handle };
            }

            switch (@typeInfo(T)) {
                .bool => {
                    if ((try raw.tryTypeof()) != .boolean) return error.TypeError;
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.CallError!bool);
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.value_identity),
                        "",
                        HostFn,
                        .{raw},
                    );
                },
                .float => {
                    if ((try raw.tryTypeof()) != .number) return error.TypeError;
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.CallError!T);
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.value_identity),
                        "",
                        HostFn,
                        .{raw},
                    );
                },
                .int => |it| {
                    if (comptime (it.bits <= 32)) {
                        if ((try raw.tryTypeof()) != .number) return error.TypeError;
                        const n = try fromJsRefAlloc(f64, allocator, raw);
                        if (!std.math.isFinite(n) or @trunc(n) != n) return error.TypeError;
                        const min_f: f64 = @floatFromInt(std.math.minInt(T));
                        const max_f: f64 = @floatFromInt(std.math.maxInt(T));
                        if (n < min_f or n > max_f) return error.TypeError;
                        return @intFromFloat(n);
                    }
                    if ((try raw.tryTypeof()) != .bigint) return error.TypeError;
                    if (comptime (it.bits <= 64)) {
                        const bi: BigInt = .{ .handle = raw.handle };
                        if (comptime (it.signedness == .signed)) {
                            const v64 = bi.toI64() catch |err| return switch (err) {
                                error.Overflow => error.TypeError,
                                else => |e| e,
                            };
                            if (v64 < std.math.minInt(T) or v64 > std.math.maxInt(T)) return error.TypeError;
                            return @intCast(v64);
                        } else {
                            const v64 = bi.toU64() catch |err| return switch (err) {
                                error.Overflow => error.TypeError,
                                else => |e| e,
                            };
                            if (v64 > std.math.maxInt(T)) return error.TypeError;
                            return @intCast(v64);
                        }
                    }
                    if (comptime (it.bits <= 128)) {
                        const bi: BigInt = .{ .handle = raw.handle };
                        if (comptime (it.signedness == .signed)) {
                            const v128 = bi.toI128() catch |err| return switch (err) {
                                error.Overflow => error.TypeError,
                                else => |e| e,
                            };
                            if (v128 < std.math.minInt(T) or v128 > std.math.maxInt(T)) return error.TypeError;
                            return @intCast(v128);
                        } else {
                            const v128 = bi.toU128() catch |err| return switch (err) {
                                error.Overflow => error.TypeError,
                                else => |e| e,
                            };
                            if (v128 > std.math.maxInt(T)) return error.TypeError;
                            return @intCast(v128);
                        }
                    }
                    const HostFn = buildFnType(&.{Ref(module.Any)}, module.CallError!T);
                    return dispatchHostOpRawFlags(
                        .collection_op,
                        @intFromEnum(module.CollectionSubOp.value_identity),
                        "",
                        HostFn,
                        .{raw},
                    );
                },
                .pointer => |pt| switch (pt.size) {
                    .slice => {
                        if (pt.child == u8) {
                            if (!(try String.isString(raw))) return error.TypeError;
                            const str = String{ .handle = raw.handle };
                            return try str.toSliceAlloc(allocator);
                        }
                        if (!(try Array(Ref(module.Any)).isArray(raw))) return error.TypeError;
                        const next_anc = try advanceDecodeCycle(T, raw, ancestor);
                        const arr = Array(Ref(module.Any)).fromRef(raw);
                        const count = try arr.len();
                        const buf = try allocator.alloc(pt.child, count);
                        var initialized: usize = 0;
                        errdefer {
                            for (buf[0..initialized]) |elem| {
                                freeDecoded(pt.child, allocator, elem);
                            }
                            allocator.free(buf);
                        }
                        while (initialized < count) : (initialized += 1) {
                            const elem_ref = try arr.get(initialized);
                            defer elem_ref.deinit();
                            buf[initialized] = try fromJsRefAllocInner(pt.child, allocator, elem_ref, depth + 1, next_anc);
                        }
                        return buf;
                    },
                    .one => {
                        if (comptime (@typeInfo(pt.child) == .@"fn")) {
                            return error.TypeError;
                        }
                        const ptr = try allocator.create(pt.child);
                        errdefer allocator.destroy(ptr);
                        const child_depth = if (comptime isContainerDecodeType(pt.child)) depth else depth + 1;
                        ptr.* = try fromJsRefAllocInner(pt.child, allocator, raw, child_depth, ancestor);
                        return ptr;
                    },
                    else => @compileError("Unsupported pointer type for JS decode: " ++ @typeName(T)),
                },
                .@"struct" => |st| {
                    if (comptime isTupleStructType(T)) {
                        if (!(try Array(Ref(module.Any)).isArray(raw))) return error.TypeError;
                        if (st.field_names.len == 0) return .{};

                        const next_anc = try advanceDecodeCycle(T, raw, ancestor);
                        const arr = Array(Ref(module.Any)).fromRef(raw);
                        const arr_len = try arr.len();
                        const meta = T.zigar_js_tuple;
                        const var_idx_opt: ?usize = if (@hasField(@TypeOf(meta), "variadic_index")) meta.variadic_index else null;

                        var out: T = undefined;
                        var field_init: [st.field_names.len]bool = @splat(false);
                        errdefer {
                            inline for (st.field_names, 0..) |fname, fi| {
                                if (field_init[fi]) {
                                    freeDecoded(st.field_types[fi], allocator, @field(out, fname));
                                }
                            }
                        }

                        if (comptime (var_idx_opt == null)) {
                            const min_req = comptime blk: {
                                var req: usize = 0;
                                for (0..st.field_names.len) |fi| {
                                    if (!tupleFieldIsOptional(T, fi)) req = fi + 1;
                                }
                                break :blk req;
                            };
                            if (arr_len < min_req or arr_len > st.field_names.len) return error.TypeError;
                            inline for (st.field_names, 0..) |fname, fi| {
                                const ftype = st.field_types[fi];
                                if (fi < arr_len) {
                                    const elem_ref = try arr.get(fi);
                                    defer elem_ref.deinit();
                                    @field(out, fname) = try fromJsRefAllocInner(ftype, allocator, elem_ref, depth + 1, next_anc);
                                    field_init[fi] = true;
                                } else if (comptime (@typeInfo(ftype) == .optional)) {
                                    @field(out, fname) = null;
                                    field_init[fi] = true;
                                } else {
                                    return error.TypeError;
                                }
                            }
                            return out;
                        } else {
                            const v_idx: usize = comptime var_idx_opt.?;
                            const trailing_count: usize = comptime (st.field_names.len - 1 - v_idx);
                            const req_leading: usize = comptime blk: {
                                if (trailing_count > 0) break :blk v_idx;
                                var req: usize = 0;
                                for (0..v_idx) |fi| {
                                    if (!tupleFieldIsOptional(T, fi)) req = fi + 1;
                                }
                                break :blk req;
                            };
                            if (arr_len < req_leading + trailing_count) return error.TypeError;
                            const avail_before_trailing = arr_len - trailing_count;
                            const leading_present = @min(v_idx, avail_before_trailing);
                            const rest_start = leading_present;
                            const rest_len = avail_before_trailing - rest_start;

                            inline for (st.field_names, 0..) |fname, fi| {
                                const ftype = st.field_types[fi];
                                if (comptime (fi < v_idx)) {
                                    if (fi < leading_present) {
                                        const elem_ref = try arr.get(fi);
                                        defer elem_ref.deinit();
                                        @field(out, fname) = try fromJsRefAllocInner(ftype, allocator, elem_ref, depth + 1, next_anc);
                                        field_init[fi] = true;
                                    } else if (comptime (@typeInfo(ftype) == .optional)) {
                                        @field(out, fname) = null;
                                        field_init[fi] = true;
                                    } else {
                                        return error.TypeError;
                                    }
                                } else if (comptime (fi == v_idx)) {
                                    const RestElem = @typeInfo(ftype).pointer.child;
                                    const rest_buf = try allocator.alloc(RestElem, rest_len);
                                    var ri: usize = 0;
                                    errdefer {
                                        for (rest_buf[0..ri]) |re| freeDecoded(RestElem, allocator, re);
                                        allocator.free(rest_buf);
                                    }
                                    while (ri < rest_len) : (ri += 1) {
                                        const elem_ref = try arr.get(rest_start + ri);
                                        defer elem_ref.deinit();
                                        rest_buf[ri] = try fromJsRefAllocInner(RestElem, allocator, elem_ref, depth + 1, next_anc);
                                    }
                                    @field(out, fname) = rest_buf;
                                    field_init[fi] = true;
                                } else {
                                    const trail_offset = comptime (fi - (v_idx + 1));
                                    const elem_ref = try arr.get(avail_before_trailing + trail_offset);
                                    defer elem_ref.deinit();
                                    @field(out, fname) = try fromJsRefAllocInner(ftype, allocator, elem_ref, depth + 1, next_anc);
                                    field_init[fi] = true;
                                }
                            }
                            return out;
                        }
                    }

                    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_template_literal") and T.zigar_js.is_template_literal)) {
                        if (!(try String.isString(raw))) return error.TypeError;
                        const decoded = try (String{ .handle = raw.handle }).toSliceAlloc(allocator);
                        if (!module.matchTemplatePattern(T.zigar_js, decoded)) {
                            allocator.free(decoded);
                            return error.TypeError;
                        }
                        return .{ .raw = decoded };
                    }

                    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_enum") and T.zigar_js.is_enum and @hasField(T, "__zigar_value")) {
                        return .{ .__zigar_value = try fromJsRefAllocInner(@FieldType(T, "__zigar_value"), allocator, raw, depth, ancestor) };
                    }

                    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_handle") and T.zigar_js.is_handle)) {
                        if (!(try matchesHandleTypeImpl(T, raw, false, 0))) return error.TypeError;

                        const ref_fname = comptime if (@hasField(@TypeOf(T.zigar_js), "ref_field")) T.zigar_js.ref_field else "ref";
                        var out_h: T = undefined;
                        @field(out_h, ref_fname) = .{ .handle = (try raw.tryClone()).handle };
                        return out_h;
                    }

                    if (raw.isNullOrUndefined()) return error.TypeError;
                    const jt = try raw.tryTypeof();
                    if (jt != .object and jt != .function) return error.TypeError;

                    const is_cls = comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_class") and T.zigar_js.is_class);
                    if (comptime (is_cls and @hasField(@TypeOf(T.zigar_js), "ctor_target"))) {
                        if (resolveTargetCtorRef(T.zigar_js.ctor_target)) |ctor_opt| {
                            if (ctor_opt) |ctor| {
                                defer ctor.deinit();
                                if (!ctor.isNullOrUndefined() and (try ctor.tryTypeof()) == .function) {
                                    if (!(try raw.tryInstanceof(ctor))) return error.TypeError;
                                }
                            }
                        } else |err| switch (err) {
                            error.OffJsThread, error.OutOfMemory, error.HostUnavailable, error.JsException => return err,
                            else => clearLastError(),
                        }
                    } else if (comptime (!is_cls and !structHasWireField(T, "length"))) {
                        if (jt == .object and (Array(Ref(module.Any)).isArray(raw) catch false)) {
                            return error.TypeError;
                        }
                    }

                    if (st.field_names.len == 0) return .{};

                    const next_anc = try advanceDecodeCycle(T, raw, ancestor);
                    const obj = raw.cast(module.Object);
                    var out: T = undefined;
                    var field_init: [st.field_names.len]bool = @splat(false);
                    errdefer {
                        inline for (st.field_names, 0..) |fname, fi| {
                            if (field_init[fi]) {
                                freeDecoded(st.field_types[fi], allocator, @field(out, fname));
                            }
                        }
                    }
                    inline for (st.field_names, 0..) |fname, fi| {
                        if (comptime module.isHiddenMetaField(fname)) {
                            @field(out, fname) = .{};
                            continue;
                        }
                        const ftype = st.field_types[fi];
                        const wire_key = comptime structFieldWireNameAt(T, fi, fname);
                        const prop_ref = try getProp(module.CallError!Ref(module.Any), obj, wire_key);
                        defer prop_ref.deinit();
                        if (comptime (structFieldHasConstraint(T, fname) and structFieldDisallowsNull(T, fname))) {
                            if (prop_ref.isNull()) return error.TypeError;
                        }
                        @field(out, fname) = try fromJsRefAllocInner(ftype, allocator, prop_ref, depth + 1, next_anc);
                        field_init[fi] = true;
                        if (!(try validateStructFieldConstraint(T, fname, @field(out, fname)))) {
                            return error.TypeError;
                        }
                    }
                    return out;
                },
                .@"enum" => |en_info| {
                    const jt = try raw.tryTypeof();
                    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "members")) {
                        if (comptime enumIsPureIntBacked(T)) {
                            if (jt != .number) return error.TypeError;
                            const n = try fromJsRefAlloc(f64, allocator, raw);
                            if (!std.math.isFinite(n) or @trunc(n) != n or n < -9007199254740991.0 or n > 9007199254740991.0) {
                                return error.TypeError;
                            }
                            const IntTag = en_info.tag_type;
                            const iv = std.math.lossyCast(IntTag, n);
                            if (@as(f64, @floatFromInt(iv)) != n) return error.TypeError;
                            return T.fromInt(iv) orelse error.TypeError;
                        }
                        if (comptime enumIsPureStrBacked(T)) {
                            if (jt != .string) return error.TypeError;
                            const max_len = comptime maxEnumStrLen(T);
                            const js_str = String{ .handle = raw.handle };
                            const byte_len = try js_str.byteLen();
                            if (byte_len > max_len) return error.TypeError;
                            if (comptime (max_len <= 4096)) {
                                var stack_buf: [if (max_len == 0) 16 else max_len + 16]u8 = undefined;
                                var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
                                const s = try js_str.toSliceAlloc(fba.allocator());
                                return T.fromSlice(s) orelse error.TypeError;
                            } else {
                                const s = try js_str.toSliceAlloc(allocator);
                                defer allocator.free(s);
                                return T.fromSlice(s) orelse error.TypeError;
                            }
                        }
                        @setEvalBranchQuota(T.zigar_js.members.len * 32 + 4096);
                        if (jt == .string) {
                            if (comptime !enumHasFieldKind(T, "str_value")) return error.TypeError;
                            const max_len = comptime maxEnumStrLen(T);
                            const js_str = String{ .handle = raw.handle };
                            const byte_len = try js_str.byteLen();
                            if (byte_len > max_len) return error.TypeError;
                            if (comptime (max_len <= 4096)) {
                                var stack_buf: [if (max_len == 0) 16 else max_len + 16]u8 = undefined;
                                var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
                                const s = try js_str.toSliceAlloc(fba.allocator());
                                inline for (T.zigar_js.members) |m| {
                                    if (comptime (@hasField(@TypeOf(m), "is_alias") and m.is_alias)) continue;
                                    if (comptime @hasField(@TypeOf(m), "str_value")) {
                                        if (std.mem.eql(u8, s, m.str_value)) return @field(T, m.tag);
                                    }
                                }
                                return error.TypeError;
                            } else {
                                const s = try js_str.toSliceAlloc(allocator);
                                defer allocator.free(s);
                                inline for (T.zigar_js.members) |m| {
                                    if (comptime (@hasField(@TypeOf(m), "is_alias") and m.is_alias)) continue;
                                    if (comptime @hasField(@TypeOf(m), "str_value")) {
                                        if (std.mem.eql(u8, s, m.str_value)) return @field(T, m.tag);
                                    }
                                }
                                return error.TypeError;
                            }
                        }
                        if (jt == .number) {
                            if (comptime !enumHasFieldKind(T, "num_value")) return error.TypeError;
                            const n = try fromJsRefAlloc(f64, allocator, raw);
                            inline for (T.zigar_js.members) |m| {
                                if (comptime (@hasField(@TypeOf(m), "is_alias") and m.is_alias)) continue;
                                if (comptime @hasField(@TypeOf(m), "num_value")) {
                                    if (n == m.num_value) return @field(T, m.tag);
                                }
                            }
                            return error.TypeError;
                        }
                        if (jt == .boolean) {
                            if (comptime !enumHasFieldKind(T, "bool_value")) return error.TypeError;
                            const b = try fromJsRefAlloc(bool, allocator, raw);
                            inline for (T.zigar_js.members) |m| {
                                if (comptime (@hasField(@TypeOf(m), "is_alias") and m.is_alias)) continue;
                                if (comptime @hasField(@TypeOf(m), "bool_value")) {
                                    if (b == m.bool_value) return @field(T, m.tag);
                                }
                            }
                            return error.TypeError;
                        }
                        if (jt == .bigint) {
                            if (comptime !enumHasFieldKind(T, "bigint_value")) return error.TypeError;
                            inline for (T.zigar_js.members) |m| {
                                if (comptime (@hasField(@TypeOf(m), "is_alias") and m.is_alias)) continue;
                                if (comptime @hasField(@TypeOf(m), "bigint_value")) {
                                    if (try bigintRefMatchesLiteral(raw, allocator, m.bigint_value)) {
                                        return @field(T, m.tag);
                                    }
                                }
                            }
                            return error.TypeError;
                        }
                        return error.TypeError;
                    }
                    if (jt == .string) {
                        const max_tag_len = comptime blk: {
                            var ml: usize = 0;
                            for (en_info.field_names) |fname| {
                                if (fname.len > ml) ml = fname.len;
                            }
                            break :blk ml;
                        };
                        const js_str = String{ .handle = raw.handle };
                        const byte_len = try js_str.byteLen();
                        if (byte_len > max_tag_len) return error.TypeError;
                        if (comptime (max_tag_len <= 4096)) {
                            var stack_buf: [if (max_tag_len == 0) 16 else max_tag_len + 16]u8 = undefined;
                            var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
                            const s = try js_str.toSliceAlloc(fba.allocator());
                            if (std.meta.stringToEnum(T, s)) |tag| return tag;
                        } else {
                            const s = try js_str.toSliceAlloc(allocator);
                            defer allocator.free(s);
                            if (std.meta.stringToEnum(T, s)) |tag| return tag;
                        }
                    }
                    return error.TypeError;
                },
                .@"union" => |un| {
                    const jt = try raw.tryTypeof();

                    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_open_literal") and T.zigar_js.is_open_literal)) {
                        if (try tryMatchUnitLiteralVariant(T, raw, jt, allocator)) |matched| {
                            return matched;
                        }
                        inline for (T.zigar_js.variants) |vm| {
                            if (comptime (@hasField(@TypeOf(vm), "is_custom") and vm.is_custom)) {
                                const PayloadT = @FieldType(T, vm.tag);
                                return @unionInit(T, vm.tag, try fromJsRefAllocInner(PayloadT, allocator, raw, depth, ancestor));
                            }
                        }
                        return error.TypeError;
                    }

                    if (try tryMatchUnitLiteralVariant(T, raw, jt, allocator)) |matched| {
                        return matched;
                    }

                    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "discriminant"))) {
                        return decodeDiscriminatedUnion(T, allocator, raw, jt, depth, ancestor);
                    }

                    const decode_order = comptime computeUnionDecodeOrder(T);
                    inline for (decode_order) |fi| {
                        const fname = un.field_names[fi];
                        if (fromJsRefAllocInner(un.field_types[fi], allocator, raw, depth, ancestor)) |decoded| {
                            return @unionInit(T, fname, decoded);
                        } else |err| switch (err) {
                            error.TypeError, error.RangeError => {},
                            else => return err,
                        }
                    }
                    return error.TypeError;
                },
                .array => |ar| {
                    if (!(try Array(Ref(module.Any)).isArray(raw))) return error.TypeError;
                    const next_anc = try advanceDecodeCycle(T, raw, ancestor);
                    const arr = Array(Ref(module.Any)).fromRef(raw);
                    const count = try arr.len();
                    if (count != ar.len) return error.TypeError;
                    var out: T = undefined;
                    var initialized: usize = 0;
                    errdefer {
                        for (out[0..initialized]) |elem| {
                            freeDecoded(ar.child, allocator, elem);
                        }
                    }
                    while (initialized < ar.len) : (initialized += 1) {
                        const elem_ref = try arr.get(initialized);
                        defer elem_ref.deinit();
                        out[initialized] = try fromJsRefAllocInner(ar.child, allocator, elem_ref, depth + 1, next_anc);
                    }
                    return out;
                },
                else => @compileError("Unsupported Zig type for JS decode: " ++ @typeName(T)),
            }
        }

        pub fn fromJsRef(comptime T: type, value: anytype) module.CallError!T {
            if (comptime needsDecodeAllocator(T)) {
                if (@hasDecl(host, "default_allocator")) {
                    return fromJsRefAlloc(T, host.default_allocator, value);
                }
                return error.HostUnavailable;
            }
            var stack_buf: [512]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
            return fromJsRefAlloc(T, fba.allocator(), value);
        }

        fn matchesHandleTypeImpl(
            comptime T: type,
            raw: Ref(module.Any),
            comptime require_live_ctor: bool,
            comptime depth: usize,
        ) module.CallError!bool {
            if (depth >= 32) return true;
            if (raw.isNullOrUndefined()) return false;
            const jt = try raw.tryTypeof();
            const is_callable_h = comptime (@hasField(@TypeOf(T.zigar_js), "is_callable_handle") and T.zigar_js.is_callable_handle);
            if (comptime is_callable_h) {
                if (jt != .function) return false;
            } else {
                if (jt != .object and jt != .function) return false;
            }

            const is_cls_h = comptime (@hasField(@TypeOf(T.zigar_js), "is_class") and T.zigar_js.is_class);
            if (comptime is_cls_h) {
                if (comptime !@hasField(@TypeOf(T.zigar_js), "ctor_target")) {
                    return !require_live_ctor;
                }
                if (resolveTargetCtorRef(T.zigar_js.ctor_target)) |ctor_opt| {
                    if (ctor_opt) |ctor| {
                        defer ctor.deinit();
                        if (!ctor.isNullOrUndefined() and (try ctor.tryTypeof()) == .function) {
                            return try raw.tryInstanceof(ctor);
                        }
                    }
                    return !require_live_ctor;
                } else |err| switch (err) {
                    error.OffJsThread, error.OutOfMemory => return err,
                    else => {
                        clearLastError();
                        return !require_live_ctor;
                    },
                }
            } else {
                const has_bases = comptime (@hasField(@TypeOf(T.zigar_js), "bases") and T.zigar_js.bases.len > 0);
                if (comptime has_bases) {
                    inline for (T.zigar_js.bases) |BaseT| {
                        if (comptime isGeneratedHandleStruct(BaseT)) {
                            if (!(try matchesHandleTypeImpl(BaseT, raw, require_live_ctor, depth + 1))) {
                                return false;
                            }
                        } else if (comptime (@typeInfo(BaseT) == .@"struct" and @hasDecl(BaseT, "is_js_promise") and BaseT.is_js_promise)) {
                            if (!(try hasCallableStringProp(raw, "then"))) return false;
                        } else if (comptime (@typeInfo(BaseT) == .@"struct" and @hasDecl(BaseT, "is_js_array") and BaseT.is_js_array)) {
                            if (!(try Array(Ref(module.Any)).isArray(raw))) return false;
                        } else if (comptime (@typeInfo(BaseT) == .@"struct" and @hasDecl(BaseT, "is_js_map") and BaseT.is_js_map)) {
                            if (!(try Map(Ref(module.Any), Ref(module.Any)).isMap(raw))) return false;
                        } else if (comptime (@typeInfo(BaseT) == .@"struct" and @hasDecl(BaseT, "is_js_set") and BaseT.is_js_set)) {
                            if (!(try Set(Ref(module.Any)).isSet(raw))) return false;
                        }
                    }
                }

                const req_methods = comptime if (@hasField(@TypeOf(T.zigar_js), "required_methods")) T.zigar_js.required_methods else &[_][]const u8{};
                const req_props = comptime if (@hasField(@TypeOf(T.zigar_js), "required_props")) T.zigar_js.required_props else &[_][]const u8{};
                const has_iter = comptime (@hasField(@TypeOf(T.zigar_js), "has_iterator") and T.zigar_js.has_iterator);
                const has_async_iter = comptime (@hasField(@TypeOf(T.zigar_js), "has_async_iterator") and T.zigar_js.has_async_iterator);
                const has_disp = comptime (@hasField(@TypeOf(T.zigar_js), "has_dispose") and T.zigar_js.has_dispose);
                const has_async_disp = comptime (@hasField(@TypeOf(T.zigar_js), "has_async_dispose") and T.zigar_js.has_async_dispose);
                const has_length_prop = comptime blk: {
                    for (req_props) |rp| {
                        if (std.mem.eql(u8, rp, "length")) break :blk true;
                    }
                    break :blk false;
                };
                if (comptime (!is_callable_h and !has_bases and req_methods.len == 0 and !has_length_prop and !has_iter)) {
                    if (jt == .object and (Array(Ref(module.Any)).isArray(raw) catch false)) {
                        return false;
                    }
                }
                if (comptime has_iter) {
                    if (!(try hasProtocolSymbolMethod(raw, "iterator", null))) return false;
                }
                if (comptime has_async_iter) {
                    if (!(try hasProtocolSymbolMethod(raw, "asyncIterator", null))) return false;
                }
                if (comptime has_disp) {
                    if (!(try hasProtocolSymbolMethod(raw, "dispose", "nodejs.dispose"))) return false;
                }
                if (comptime has_async_disp) {
                    if (!(try hasProtocolSymbolMethod(raw, "asyncDispose", "nodejs.asyncDispose")) and
                        !(try hasProtocolSymbolMethod(raw, "dispose", "nodejs.dispose")))
                    {
                        return false;
                    }
                }
                inline for (req_methods) |m_name| {
                    if (!(try raw.tryHas(m_name))) return false;
                    const m_ref = try getProp(module.CallError!Ref(module.Any), raw, m_name);
                    defer m_ref.deinit();
                    if (m_ref.isNullOrUndefined() or (try m_ref.tryTypeof()) != .function) {
                        return false;
                    }
                }
                inline for (req_props) |p_name| {
                    if (!(try raw.tryHas(p_name))) return false;
                }
                return true;
            }
        }

        pub fn isAssignableType(comptime Derived: type, comptime Base: type) bool {
            return isAssignableTypeDepth(Derived, Base, 0);
        }

        fn isAssignableTypeDepth(comptime Derived: type, comptime Base: type, comptime depth: usize) bool {
            @setEvalBranchQuota(10_000);
            if (Derived == Base) return true;
            if (depth >= 32) return false;
            if (@typeInfo(Derived) != .@"struct") return false;
            if (!@hasDecl(Derived, "zigar_js")) return false;
            if (!@hasField(@TypeOf(Derived.zigar_js), "bases")) return false;
            inline for (Derived.zigar_js.bases) |DirectBase| {
                if (isAssignableTypeDepth(DirectBase, Base, depth + 1)) return true;
            }
            return false;
        }

        fn structWireNameForField(comptime T: type, comptime zig_field_name: []const u8) []const u8 {
            if (module.hasStructZigarJsMeta(T)) {
                const meta = module.getStructZigarJsMeta(T);
                if (@hasField(@TypeOf(meta), "fields")) {
                    @setEvalBranchQuota(meta.fields.len * 64 + 4096);
                    for (meta.fields) |fm| {
                        const fm_zig = if (@hasField(@TypeOf(fm), "zig_name")) fm.zig_name else fm.name;
                        if (std.mem.eql(u8, fm_zig, zig_field_name)) {
                            return if (@hasField(@TypeOf(fm), "js_name")) fm.js_name else fm.name;
                        }
                    }
                }
            }
            return zig_field_name;
        }

        fn findStructFieldByWireName(comptime T: type, comptime wire_name: []const u8) ?[]const u8 {
            if (module.hasStructZigarJsMeta(T)) {
                const meta = module.getStructZigarJsMeta(T);
                if (@hasField(@TypeOf(meta), "fields")) {
                    @setEvalBranchQuota(meta.fields.len * 64 + 4096);
                    for (meta.fields) |fm| {
                        const fm_wire = if (@hasField(@TypeOf(fm), "js_name")) fm.js_name else fm.name;
                        if (std.mem.eql(u8, fm_wire, wire_name)) {
                            return if (@hasField(@TypeOf(fm), "zig_name")) fm.zig_name else fm.name;
                        }
                    }
                }
            }
            if (@hasField(T, wire_name)) return wire_name;
            return null;
        }

        fn projectFieldValue(comptime DstT: type, src_val: anytype) DstT {
            const SrcT = @TypeOf(src_val);
            if (SrcT == DstT) return src_val;
            if (@typeInfo(DstT) == .optional and @typeInfo(SrcT) == .optional) {
                const ChildT = @typeInfo(DstT).optional.child;
                return if (src_val) |sv| projectFieldValue(ChildT, sv) else null;
            }
            if (@typeInfo(DstT) == .optional) {
                const ChildT = @typeInfo(DstT).optional.child;
                return projectFieldValue(ChildT, src_val);
            }
            if (@typeInfo(DstT) == .@"enum" and @typeInfo(SrcT) == .@"enum") {
                return switch (src_val) {
                    inline else => |tag| @field(DstT, @tagName(tag)),
                };
            }
            if (@typeInfo(DstT) == .@"union") {
                if (@typeInfo(SrcT) == .@"union" and @typeInfo(SrcT).@"union".tag_type != null and @typeInfo(DstT).@"union".tag_type != null) {
                    return switch (src_val) {
                        inline else => |payload, tag| @unionInit(
                            DstT,
                            @tagName(tag),
                            projectFieldValue(@FieldType(DstT, @tagName(tag)), payload),
                        ),
                    };
                }
                return module.coerceUnion(DstT, src_val);
            }
            if (@typeInfo(DstT) == .@"struct" and @typeInfo(SrcT) == .@"struct") {
                if (comptime (util.getInternalType(SrcT) == .js_value and util.getInternalType(DstT) == .js_value)) {
                    return .{ .handle = src_val.handle };
                }
                if (comptime (isGeneratedHandleStruct(SrcT) and isGeneratedHandleStruct(DstT))) {
                    const src_rf = comptime generatedHandleRefFieldName(SrcT);
                    const dst_rf = comptime generatedHandleRefFieldName(DstT);
                    var out_h: DstT = undefined;
                    @field(out_h, dst_rf) = .{ .handle = @field(src_val, src_rf).handle };
                    return out_h;
                }
                var out_s: DstT = undefined;
                const dst_info = @typeInfo(DstT).@"struct";
                inline for (dst_info.field_names, 0..) |df_name, dfi| {
                    if (comptime module.isHiddenMetaField(df_name)) {
                        @field(out_s, df_name) = .{};
                        continue;
                    }
                    const FieldT = dst_info.field_types[dfi];
                    const wire = comptime structWireNameForField(DstT, df_name);
                    if (comptime findStructFieldByWireName(SrcT, wire)) |src_fname| {
                        @field(out_s, df_name) = projectFieldValue(FieldT, @field(src_val, src_fname));
                    } else if (dst_info.field_attrs[dfi].default_value_ptr) |opaque_ptr| {
                        const def_ptr: *const FieldT = @ptrCast(@alignCast(opaque_ptr));
                        @field(out_s, df_name) = def_ptr.*;
                    } else if (@typeInfo(FieldT) == .optional) {
                        @field(out_s, df_name) = null;
                    } else {
                        @compileError("Cannot project missing required base field '" ++ df_name ++ "' from " ++ @typeName(SrcT) ++ " to " ++ @typeName(DstT));
                    }
                }
                return out_s;
            }
            return src_val;
        }

        pub fn upcastValue(comptime SelfT: type, self: SelfT, comptime Base: type) Base {
            comptime {
                if (!isAssignableType(SelfT, Base)) {
                    @compileError(@typeName(SelfT) ++ " does not inherit from or implement " ++ @typeName(Base));
                }
            }
            return projectFieldValue(Base, self);
        }

        pub fn cloneHandle(comptime SelfT: type, self: SelfT) module.CallError!SelfT {
            comptime {
                if (!isGeneratedHandleStruct(SelfT)) {
                    @compileError("cloneHandle requires a JS handle wrapper struct, received " ++ @typeName(SelfT));
                }
            }
            const rf = comptime generatedHandleRefFieldName(SelfT);
            const cloned = try @field(self, rf).tryClone();
            var out: SelfT = undefined;
            @field(out, rf) = .{ .handle = cloned.handle };
            return out;
        }

        pub fn downcastHandle(comptime Sub: type, self_ref: anytype) module.CallError!?Sub {
            comptime {
                if (!isGeneratedHandleStruct(Sub)) {
                    @compileError("tryAs target " ++ @typeName(Sub) ++ " must be a JS handle wrapper struct");
                }
            }
            const raw: Ref(module.Any) = .{ .handle = extractHandle(self_ref) };
            if (!(try matchesHandleTypeImpl(Sub, raw, true, 0))) {
                return null;
            }
            const cloned = try raw.tryClone();
            const sub_rf = comptime generatedHandleRefFieldName(Sub);
            var out: Sub = undefined;
            @field(out, sub_rf) = .{ .handle = cloned.handle };
            return out;
        }

        pub fn initEmptyHandle(comptime SelfT: type) module.CallError!SelfT {
            comptime {
                if (!isGeneratedHandleStruct(SelfT)) {
                    @compileError("initEmptyHandle requires a JS handle wrapper struct, received " ++ @typeName(SelfT));
                }
            }
            const rec = try Record([]const u8, Ref(module.Any)).init();
            const rf = comptime generatedHandleRefFieldName(SelfT);
            var out: SelfT = undefined;
            @field(out, rf) = .{ .handle = rec.handle };
            return out;
        }

        pub fn getIndexedProp(
            comptime T: type,
            self_ref: anytype,
            key: anytype,
            comptime strict_undefined_missing: bool,
        ) module.CallError!T {
            const recv: Ref(module.Any) = .{ .handle = extractHandle(self_ref) };
            const raw = try getPropDynamic(module.CallError!Ref(module.Any), recv, key);
            defer raw.deinit();
            if (comptime (strict_undefined_missing and @typeInfo(T) == .optional)) {
                if (raw.isUndefined()) return null;
                return try fromJsRef(@typeInfo(T).optional.child, raw);
            }
            return try fromJsRef(T, raw);
        }

        pub fn getIndexedPropAlloc(
            comptime T: type,
            allocator: std.mem.Allocator,
            self_ref: anytype,
            key: anytype,
            comptime strict_undefined_missing: bool,
        ) module.CallError!T {
            const recv: Ref(module.Any) = .{ .handle = extractHandle(self_ref) };
            const raw = try getPropDynamic(module.CallError!Ref(module.Any), recv, key);
            defer raw.deinit();
            if (comptime (strict_undefined_missing and @typeInfo(T) == .optional)) {
                if (raw.isUndefined()) return null;
                return try fromJsRefAlloc(@typeInfo(T).optional.child, allocator, raw);
            }
            return try fromJsRefAlloc(T, allocator, raw);
        }

        pub fn setIndexedProp(
            comptime T: type,
            self_ref: anytype,
            key: anytype,
            value: T,
            comptime spec: anytype,
        ) module.CallError!void {
            const recv: Ref(module.Any) = .{ .handle = extractHandle(self_ref) };
            const encoded = try toJsRefWithSpec(T, value, spec);
            defer encoded.deinit();
            try trySetPropDynamic(recv, key, encoded);
        }
    };
}

test "Js.Ref layout, reserved handles, and host dispatch" {
    const MockHost = struct {
        var active: u32 = 0;
        var next_slot: u32 = 9;

        pub fn cloneJsValue(handle: u32) u32 {
            std.debug.assert(handle >= 8);
            active += 1;
            defer next_slot += 1;
            return (1 << 20) | next_slot;
        }

        pub fn releaseJsValue(handle: u32) void {
            std.debug.assert(handle >= 8);
            active -= 1;
        }

        pub fn typeofJsValue(handle: u32) JsType {
            return if ((handle & 0xFFFFF) == 8) .function else .symbol;
        }

        pub fn instanceofJsValue(handle: u32, ctor_handle: u32) bool {
            return (handle & 0xFFFFF) == 9 and (ctor_handle & 0xFFFFF) == 8;
        }

        pub fn equalJsValue(lhs: u32, rhs: u32) bool {
            return (lhs & 0xFFFFF) == (rhs & 0xFFFFF) or ((lhs & 0xFFFFF) == 8 and (rhs & 0xFFFFF) == 9);
        }

        pub fn getJsValueCount() u32 {
            return active;
        }
    };

    const js = Js(MockHost);
    const ObjRef = js.Ref(js.Object);
    const AnyRef = js.Ref(js.Any);

    try expectEqual(4, @sizeOf(ObjRef));
    try expectEqual(4, @alignOf(ObjRef));
    try expectEqual(.js_value, util.getInternalType(ObjRef));

    try expect(ObjRef.@"undefined".isUndefined());
    try expect(!ObjRef.@"undefined".isNull());
    try expect(ObjRef.@"undefined".isNullOrUndefined());
    try expect(ObjRef.@"null".isNull());
    try expect(ObjRef.@"null".isNullOrUndefined());
    try expect(!ObjRef.globalThis.isNullOrUndefined());
    try expectEqual(@as(u32, 2), AnyRef.fromBool(false).handle);
    try expectEqual(@as(u32, 3), AnyRef.fromBool(true).handle);

    try expectEqual(JsType.@"undefined", AnyRef.@"undefined".typeof());
    try expectEqual(JsType.object, ObjRef.@"null".typeof());
    try expectEqual(JsType.boolean, AnyRef.fromBool(true).typeof());
    try expectEqual(JsType.object, ObjRef.globalThis.typeof());

    ObjRef.@"undefined".deinit();
    ObjRef.@"null".deinit();
    ObjRef.globalThis.deinit();
    try expectEqual(@as(u32, 4), ObjRef.globalThis.clone().handle);
    try expect(ObjRef.@"null".eql(null));
    try expect(AnyRef.fromBool(true).eql(true));
    try expect(!AnyRef.fromBool(true).eql(false));
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    MockHost.active = 1;
    const dyn: ObjRef = .{ .handle = (1 << 20) | 8 };
    const cloned = dyn.clone();
    try expectEqual(@as(u32, 2), js.activeHandleCount());
    try expectEqual(JsType.function, dyn.typeof());
    try expect(cloned.instanceof(dyn));
    try expect(dyn.eql(cloned));
    const casted = cloned.cast(js.Symbol);
    try expectEqual(cloned.handle, casted.handle);
    casted.deinit();
    dyn.deinit();
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}

test "Js.Ref fallible try* methods surface error.OffJsThread off JS thread" {
    const OffThreadHost = struct {
        var on_js_thread: bool = false;

        pub fn isJsThread() bool {
            return on_js_thread;
        }

        pub fn cloneJsValue(_: u32) u32 {
            unreachable;
        }

        pub fn releaseJsValue(_: u32) void {
            unreachable;
        }

        pub fn typeofJsValue(_: u32) JsType {
            unreachable;
        }

        pub fn instanceofJsValue(_: u32, _: u32) bool {
            unreachable;
        }

        pub fn equalJsValue(_: u32, _: u32) bool {
            unreachable;
        }

        pub fn getJsValueCount() u32 {
            unreachable;
        }
    };

    const js = Js(OffThreadHost);
    const ObjRef = js.Ref(js.Object);
    const dyn: ObjRef = .{ .handle = (1 << 20) | 8 };

    try expect(!js.isJsThread());
    try std.testing.expectError(error.OffJsThread, js.tryActiveHandleCount());
    try std.testing.expectError(error.OffJsThread, dyn.tryClone());
    try std.testing.expectError(error.OffJsThread, dyn.tryDeinit());
    try std.testing.expectError(error.OffJsThread, dyn.tryTypeof());
    try std.testing.expectError(error.OffJsThread, dyn.tryInstanceof(dyn));
    try std.testing.expectError(error.OffJsThread, dyn.tryEql(dyn));
    try std.testing.expectError(error.OffJsThread, ObjRef.@"null".tryClone());
    try std.testing.expectError(error.OffJsThread, ObjRef.@"null".tryDeinit());
    try std.testing.expectError(error.OffJsThread, ObjRef.@"null".tryTypeof());
    try std.testing.expectError(error.OffJsThread, ObjRef.@"null".tryEql(null));
}

test "HostOpDescriptor ABI layout, 9 host operations, Ref helpers, and 160 stateful callbacks" {
    try expectEqual(@as(usize, 0), @offsetOf(HostOpDescriptor, "signature"));
    try expectEqual(@as(usize, 8), @offsetOf(HostOpDescriptor, "op"));
    try expectEqual(@as(usize, 12), @offsetOf(HostOpDescriptor, "flags"));
    try expectEqual(@as(usize, 16), @offsetOf(HostOpDescriptor, "key_ptr"));
    try expectEqual(@as(usize, 16 + 4 * @sizeOf(usize)), @sizeOf(HostOpDescriptor));

    try expectEqual(@as(usize, 0), @offsetOf(CallbackDescriptor, "signature"));
    try expectEqual(@as(usize, 8), @offsetOf(CallbackDescriptor, "flags"));
    try expectEqual(@as(usize, 16), @offsetOf(CallbackDescriptor, "trampoline_thunk"));
    try expectEqual(@as(usize, 16 + @sizeOf(usize)), @offsetOf(CallbackDescriptor, "register_thunk"));
    try expectEqual(@as(usize, 16 + 2 * @sizeOf(usize)), @offsetOf(CallbackDescriptor, "cancel_thunk"));
    try expectEqual(std.mem.alignForward(usize, 16 + 3 * @sizeOf(usize), 8), @sizeOf(CallbackDescriptor));

    const DispatchMockHost = struct {
        var active_handles: u32 = 0;
        var active_callbacks: u32 = 0;
        var next_handle_slot: u32 = 16;
        var last_op: u32 = 0;
        var last_flags: u32 = 0;
        var last_key: []const u8 = "";
        var stored_trampoline: usize = 0;

        pub fn allocHandle() u32 {
            active_handles += 1;
            defer next_handle_slot += 1;
            return (1 << 20) | next_handle_slot;
        }

        pub fn cloneJsValue(handle: u32) u32 {
            _ = handle;
            return allocHandle();
        }

        pub fn releaseJsValue(_: u32) void {
            active_handles -= 1;
        }

        pub fn typeofJsValue(_: u32) JsType {
            return .object;
        }

        pub fn instanceofJsValue(_: u32, _: u32) bool {
            return true;
        }

        pub fn equalJsValue(lhs: u32, rhs: u32) bool {
            return lhs == rhs;
        }

        pub fn getJsValueCount() u32 {
            return active_handles;
        }

        pub fn invokeJsHostOp(desc_ptr: *const anyopaque, arg_ptr: *anyopaque, _: usize) E {
            const desc: *const HostOpDescriptor = @ptrCast(@alignCast(desc_ptr));
            last_op = desc.op;
            last_flags = desc.flags;
            last_key = if (desc.key_ptr) |kp| kp[0..desc.key_len] else "";
            const op: HostOp = @enumFromInt(desc.op);
            switch (op) {
                .import_module => {
                    const Frame = arg_struct.ArgStruct(fn () CallError!Js(@This()).Ref(Object));
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    f.retval = .{ .handle = allocHandle() };
                },
                .get_global => {
                    const Frame = arg_struct.ArgStruct(fn () i32);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    f.retval = 99;
                },
                .get_prop => {
                    if (desc.flags == 0) {
                        const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any)) i32);
                        const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                        f.retval = @intCast((f.@"0".handle & 0xFFFFF) + 100);
                    } else {
                        const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any), []const u8) i32);
                        const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                        f.retval = @intCast(f.@"1".len * 10);
                    }
                },
                .set_prop => {},
                .delete_prop, .has_prop => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any)) bool);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    f.retval = f.@"0".handle != 0;
                },
                .call_fn => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any), i32, i32) i32);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    f.retval = f.@"1" + f.@"2";
                },
                .call_method => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any), i32) i32);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    f.retval = f.@"1" * 3;
                },
                .construct => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any), i32) Js(@This()).Ref(Object));
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    _ = f.@"1";
                    f.retval = .{ .handle = allocHandle() };
                },
                else => return .FAULT,
            }
            return .SUCCESS;
        }

        pub fn createZigCallback(desc_ptr: *const anyopaque, _: u32) Error!u32 {
            const desc: *const CallbackDescriptor = @ptrCast(@alignCast(desc_ptr));
            stored_trampoline = desc.trampoline_thunk;
            active_callbacks += 1;
            return allocHandle();
        }

        pub fn releaseZigCallback(_: u32) void {
            active_callbacks -= 1;
            active_handles -= 1;
        }
    };

    const js = Js(DispatchMockHost);

    const mod_handle = try js.importModule("node:path");
    try expectEqual(@as(u32, @intFromEnum(HostOp.import_module)), DispatchMockHost.last_op);
    try std.testing.expectEqualStrings("node:path", DispatchMockHost.last_key);

    try expectEqual(@as(i32, 99), js.getGlobal(i32, "answer"));
    try std.testing.expectEqualStrings("answer", DispatchMockHost.last_key);

    const prop_v = mod_handle.get(i32, "depth");
    try expect(prop_v > 100);
    try expectEqual(@as(i32, 50), mod_handle.getDynamic(i32, "hello"));

    mod_handle.set("label", "zigar");
    try expectEqual(@as(u32, @intFromEnum(HostOp.set_prop)), DispatchMockHost.last_op);
    try expect(mod_handle.has("label"));
    try expect(mod_handle.delete("label"));

    const fn_ref = mod_handle.cast(js.Function);
    try expectEqual(@as(i32, 42), fn_ref.invoke(fn (i32, i32) i32, .{ 19, 23 }));
    try expectEqual(@as(i32, 21), mod_handle.call(fn (i32) i32, "triple", .{7}));

    const constructed = fn_ref.new(fn (i32) js.Ref(js.Object), .{123});
    constructed.deinit();
    mod_handle.deinit();
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    const State = struct {
        bias: i32,
        calls: u32 = 0,

        fn compute(self: *@This(), x: i32) i32 {
            self.calls += 1;
            return self.bias + x * 2;
        }
    };

    const cb_count = 160;
    var states: [cb_count]State = undefined;
    var callbacks: [cb_count]js.Callback(fn (i32) i32) = undefined;
    for (0..cb_count) |i| {
        states[i] = .{ .bias = @intCast(i * 10) };
        callbacks[i] = try js.Callback(fn (i32) i32).tryInit(&states[i], State.compute);
    }
    try expectEqual(@as(u32, cb_count), js.activeCallbackCount());
    try expectEqual(@as(u32, cb_count), js.activeHandleCount());

    const TrampolineThunk = *const fn (*const anyopaque, *anyopaque) anyerror!void;
    const thunk: TrampolineThunk = @ptrFromInt(DispatchMockHost.stored_trampoline);
    const CbArgs = arg_struct.ArgStruct(fn (i32) i32);
    for (0..cb_count) |i| {
        var frame: CbArgs = .{ .retval = 0, .@"0" = 5 };
        try thunk(@ptrFromInt(callbacks[i].id), @ptrCast(&frame));
        try expectEqual(@as(i32, @intCast(i * 10 + 10)), frame.retval);
        try expectEqual(@as(u32, 1), states[i].calls);
    }

    for (&callbacks) |*cb| {
        cb.deinit();
    }
    try expectEqual(@as(u32, 0), js.activeCallbackCount());
    try expectEqual(@as(u32, 0), js.activeHandleCount());
    try expectEqual(@as(u32, 0), DispatchMockHost.active_callbacks);

    var owned_cb = try js.Callback(fn (i32) i32).tryInitOwned(
        std.testing.allocator,
        State{ .bias = 77 },
        State.compute,
    );
    var owned_frame: CbArgs = .{ .retval = 0, .@"0" = 3 };
    try thunk(@ptrFromInt(owned_cb.id), @ptrCast(&owned_frame));
    try expectEqual(@as(i32, 83), owned_frame.retval);
    owned_cb.deinit();
    try expectEqual(@as(u32, 0), js.activeCallbackCount());
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // Self-disposing one-shot owned callback (`deinit()` called while handler is still active on stack)
    const OneShot = struct {
        cb_slot: *js.Callback(fn (i32) i32),
        secret: i32,

        fn runOnce(self: *@This(), x: i32) i32 {
            self.cb_slot.deinit();
            // `self` must remain live until `runOnce` returns even though `deinit()` already ran!
            return self.secret + x;
        }
    };
    var once_cb: js.Callback(fn (i32) i32) = .{};
    once_cb = try js.Callback(fn (i32) i32).tryInitOwned(
        std.testing.allocator,
        OneShot{ .cb_slot = &once_cb, .secret = 500 },
        OneShot.runOnce,
    );
    const saved_once_id = once_cb.id;
    var once_frame: CbArgs = .{ .retval = 0, .@"0" = 25 };
    try thunk(@ptrFromInt(saved_once_id), @ptrCast(&once_frame));
    try expectEqual(@as(i32, 525), once_frame.retval);
    try expectEqual(@as(u32, 0), js.activeCallbackCount());
    try expectEqual(@as(u32, 0), js.activeHandleCount());
    try std.testing.expectError(error.InvalidCallback, thunk(@ptrFromInt(saved_once_id), @ptrCast(&once_frame)));
}

test "defaultFallbackValue and mapHostFailure safely construct all Zig return types on FAULT" {
    const FaultHost = struct {
        pub fn invokeJsHostOp(_: *const anyopaque, _: *anyopaque, _: usize) E {
            return .FAULT;
        }
    };
    const js = Js(FaultHost);
    const NonZeroEnum = enum(i32) { alpha = 7, beta = 9 };
    const OpenEnum = enum(u8) { first = 3, _ };
    const RecursiveNode = struct {
        next: *@This(),
        value: i32,
    };
    const SampleUnion = union(enum) {
        num: i32,
        flag: bool,
    };
    const Composite = struct {
        ptr: *i32,
        node: *RecursiveNode,
        opaque_ptr: *anyopaque,
        fn_ptr: *const fn () void,
        slice: []u8,
        const_slice: []const u8,
        z_slice: [:0]const u8,
        mut_z_slice: [:0]u8,
        many_z: [*:0]const u8,
        c_ptr: [*c]u8,
        en: NonZeroEnum,
        open_en: OpenEnum,
        un: SampleUnion,
        arr: [3]NonZeroEnum,
        z_arr: [2:0]u8,
        vec: @Vector(4, i32),
        ref: js.Ref(js.Object),
        opt: ?*i32,
    };

    js.setProp(js.Ref(js.Object).undefined, "noop", @as(i32, 1));
    try std.testing.expectEqual(@as(i32, 0), js.getGlobal(i32, "x"));
    try std.testing.expectEqual(false, js.getGlobal(bool, "x"));
    try std.testing.expectEqual(@as(f64, 0), js.getGlobal(f64, "x"));
    try std.testing.expectEqual(NonZeroEnum.alpha, js.getGlobal(NonZeroEnum, "x"));
    try std.testing.expectEqual(OpenEnum.first, js.getGlobal(OpenEnum, "x"));
    try std.testing.expect(js.getGlobal(js.Ref(js.Object), "x").isUndefined());
    try std.testing.expectError(error.Other, js.getGlobal(error{Other}!i32, "x"));
    try std.testing.expectEqual(@as(i32, 0), try js.getGlobal(error{}!i32, "x"));

    const comp = defaultFallbackValue(Composite);
    try std.testing.expectEqual(@as(i32, 0), comp.ptr.*);
    try std.testing.expectEqual(@as(usize, 0), comp.slice.len);
    try std.testing.expectEqual(@as(usize, 0), comp.const_slice.len);
    try std.testing.expectEqual(@as(usize, 0), comp.z_slice.len);
    try std.testing.expectEqual(@as(usize, 0), comp.mut_z_slice.len);
    try std.testing.expectEqual(@as(u8, 0), comp.many_z[0]);
    try std.testing.expectEqual(@as([*c]u8, null), comp.c_ptr);
    try std.testing.expectEqual(NonZeroEnum.alpha, comp.en);
    try std.testing.expectEqual(OpenEnum.first, comp.open_en);
    try std.testing.expectEqual(SampleUnion{ .num = 0 }, comp.un);
    try std.testing.expectEqual(NonZeroEnum.alpha, comp.arr[2]);
    try std.testing.expectEqual(@as(u8, 0), comp.z_arr[0]);
    try std.testing.expect(comp.ref.isUndefined());
    try std.testing.expectEqual(@as(?*i32, null), comp.opt);
}

test "Js.Module descriptor markers and default/export= interop flags" {
    const ModMockHost = struct {
        var active_handles: u32 = 0;
        var next_slot: u32 = 32;
        var last_op: u32 = 0;
        var last_flags: u32 = 0;
        var last_key: []const u8 = "";

        fn allocHandle() u32 {
            active_handles += 1;
            defer next_slot += 1;
            return (1 << 20) | next_slot;
        }

        pub fn releaseJsValue(handle: u32) void {
            if (handle >= 8) active_handles -= 1;
        }

        pub fn getJsValueCount() u32 {
            return active_handles;
        }

        pub fn invokeJsHostOp(desc_ptr: *const anyopaque, arg_ptr: *anyopaque, _: usize) E {
            const desc: *const HostOpDescriptor = @ptrCast(@alignCast(desc_ptr));
            last_op = desc.op;
            last_flags = desc.flags;
            last_key = if (desc.key_ptr) |p| p[0..desc.key_len] else "";
            const op: HostOp = @enumFromInt(desc.op);
            switch (op) {
                .import_module => {
                    const out_bytes: [*]u8 = @ptrCast(arg_ptr);
                    const handle_out: *u32 = @ptrCast(@alignCast(out_bytes));
                    handle_out.* = allocHandle();
                    out_bytes[4] = 0;
                },
                .call_fn => {
                    const Frame = arg_struct.ArgStruct(WrapFn(fn (Js(@This()).Ref(Function), i32) i32));
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    frame.retval = frame.@"1" * 3;
                },
                .construct => {
                    const Frame = arg_struct.ArgStruct(WrapFn(fn (Js(@This()).Ref(Function), i32) Js(@This()).Ref(Object)));
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    frame.retval = .{ .handle = allocHandle() };
                },
                else => return .FAULT,
            }
            return .SUCCESS;
        }

        fn WrapFn(comptime FnSig: type) type {
            const f = @typeInfo(FnSig).@"fn";
            var param_types: [f.param_types.len]type = undefined;
            var param_attrs: [f.param_types.len]std.lang.Type.Fn.ParamAttributes = undefined;
            for (f.param_types, 0..) |pt, i| {
                param_types[i] = pt.?;
                param_attrs[i] = .{};
            }
            return @Fn(&param_types, &param_attrs, CallError!(f.return_type orelse void), .{});
        }
    };

    const js = Js(ModMockHost);
    const UnusedMod = js.Module("pkg-unused");
    const ExportEqMod = js.Module("./cjs-fn.cjs");
    try expect(UnusedMod.is_js_module_descriptor);
    try expect(ExportEqMod.is_js_module_descriptor);
    try std.testing.expectEqualStrings("./cjs-fn.cjs", ExportEqMod.module_specifier);

    const ns = try ExportEqMod.namespace();
    try expectEqual(@as(u32, @intFromEnum(HostOp.import_module)), ModMockHost.last_op);
    try expectEqual(@as(u32, 0), ModMockHost.last_flags);
    ns.deinit();

    const def_fn = try ExportEqMod.default(js.Ref(js.Function));
    try expectEqual(@as(u32, @intFromEnum(HostOp.import_module)), ModMockHost.last_op);
    try expectEqual(@as(u32, @bitCast(HostOpFlags{ .module_default = true })), ModMockHost.last_flags);
    def_fn.deinit();

    const call_res = try ExportEqMod.callExportEquals(fn (i32) i32, .{14});
    try expectEqual(@as(i32, 42), call_res);

    const inst = try ExportEqMod.constructExportEquals(fn (i32) js.Ref(js.Object), .{7});
    inst.deinit();
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}

test "JsException lazy capture, Module exact Error!T preservation, Ref dispose/asyncDispose, and Closure/once" {
    const LifecycleMockHost = struct {
        var active_handles: u32 = 0;
        var next_slot: u32 = 16;
        var active_callbacks: u32 = 0;
        var stored_trampoline: usize = 0;
        var stored_cancel_thunk: usize = 0;
        var last_cb_flags: u32 = 0;

        var has_captured_err: bool = false;
        var captured_kind: enum { none, sys_err, plain_str, null_val, undef_val } = .none;

        var dispose_calls: u32 = 0;
        var async_dispose_calls: u32 = 0;
        var fail_next_dispose: bool = false;

        fn allocTagged(tag_slot: u32) u32 {
            active_handles += 1;
            const gen = next_slot;
            next_slot += 1;
            return (gen << 20) | tag_slot;
        }

        pub fn cloneJsValue(handle: u32) u32 {
            if (handle <= reserved_global_this_handle) return handle;
            return allocTagged(handle & 0xFFFFF);
        }

        pub fn releaseJsValue(handle: u32) void {
            if (handle >= first_dynamic_slot) {
                std.debug.assert(active_handles > 0);
                active_handles -= 1;
            }
        }

        pub fn typeofJsValue(handle: u32) JsType {
            return switch (handle & 0xFFFFF) {
                10 => .object, // Error object
                11, 20, 21, 22, 23 => .string,
                12 => .number,
                else => .object,
            };
        }

        pub fn getJsValueCount() u32 {
            return active_handles;
        }

        pub fn tryControlLastJsError(mode: u32) Error!u32 {
            const op: LastErrorOp = @enumFromInt(mode);
            switch (op) {
                .peek => {
                    if (!has_captured_err) return no_captured_error_handle;
                    return materializeCaptured();
                },
                .take => {
                    if (!has_captured_err) return no_captured_error_handle;
                    defer {
                        has_captured_err = false;
                        captured_kind = .none;
                    }
                    return materializeCaptured();
                },
                .has => return if (has_captured_err) 1 else 0,
                .clear => {
                    has_captured_err = false;
                    captured_kind = .none;
                    return 0;
                },
            }
        }

        fn materializeCaptured() u32 {
            return switch (captured_kind) {
                .none => no_captured_error_handle,
                .sys_err => allocTagged(10),
                .plain_str => allocTagged(11),
                .null_val => reserved_null_handle,
                .undef_val => reserved_undefined_handle,
            };
        }

        pub fn tryDisposeJsValue(handle: u32) Error!void {
            defer releaseJsValue(handle);
            dispose_calls += 1;
            if (fail_next_dispose) {
                fail_next_dispose = false;
                has_captured_err = true;
                captured_kind = .sys_err;
                return error.JsException;
            }
        }

        pub fn disposeJsValue(handle: u32) void {
            tryDisposeJsValue(handle) catch {};
        }

        pub fn tryAsyncDisposeJsValue(handle: u32) Error!void {
            defer releaseJsValue(handle);
            async_dispose_calls += 1;
            if (fail_next_dispose) {
                fail_next_dispose = false;
                has_captured_err = true;
                captured_kind = .sys_err;
                return error.JsException;
            }
        }

        pub fn asyncDisposeJsValue(handle: u32) void {
            tryAsyncDisposeJsValue(handle) catch {};
        }

        pub fn invokeJsHostOp(desc_ptr: *const anyopaque, arg_ptr: *anyopaque, _: usize) E {
            const desc: *const HostOpDescriptor = @ptrCast(@alignCast(desc_ptr));
            const key = if (desc.key_ptr) |p| p[0..desc.key_len] else "";
            const op: HostOp = @enumFromInt(desc.op);
            switch (op) {
                .import_module => {
                    const out_bytes: [*]u8 = @ptrCast(arg_ptr);
                    const handle_out: *u32 = @ptrCast(@alignCast(out_bytes));
                    handle_out.* = allocTagged(30);
                    out_bytes[4] = 0;
                },
                .get_prop => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any)) Error!Js(@This()).Ref(Any));
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    if (std.mem.eql(u8, key, "message")) {
                        frame.retval = .{ .handle = allocTagged(20) };
                    } else if (std.mem.eql(u8, key, "name")) {
                        frame.retval = .{ .handle = allocTagged(21) };
                    } else if (std.mem.eql(u8, key, "code")) {
                        frame.retval = .{ .handle = allocTagged(22) };
                    } else if (std.mem.eql(u8, key, "stack")) {
                        frame.retval = .{ .handle = allocTagged(23) };
                    } else {
                        frame.retval = .@"undefined";
                    }
                },
                .call_method => {
                    if (std.mem.eql(u8, key, "String")) {
                        const Frame = arg_struct.ArgStruct(fn (std.mem.Allocator, Js(@This()).Ref(Any), Js(@This()).Ref(Any)) Error![]const u8);
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        const text: []const u8 = switch (frame.@"2".handle & 0xFFFFF) {
                            11 => "plain thrown string",
                            20 => "ENOENT: no such file or directory",
                            21 => "Error",
                            22 => "ENOENT",
                            23 => "Error: ENOENT\n    at readFileSync",
                            else => "unknown",
                        };
                        frame.retval = frame.@"0".dupe(u8, text) catch return .FAULT;
                        return .SUCCESS;
                    }
                    // Simulate `fs.readFileSync("/nonexistent")` throwing ENOENT -> lazy capture (0 handles!)
                    has_captured_err = true;
                    captured_kind = .sys_err;
                    return .FAULT;
                },
                else => return .FAULT,
            }
            return .SUCCESS;
        }

        pub fn createZigCallback(desc_ptr: *const anyopaque, _: u32) Error!u32 {
            const desc: *const CallbackDescriptor = @ptrCast(@alignCast(desc_ptr));
            stored_trampoline = desc.trampoline_thunk;
            stored_cancel_thunk = desc.cancel_thunk;
            last_cb_flags = desc.flags;
            active_callbacks += 1;
            return allocTagged(40);
        }

        pub fn releaseZigCallback(_: u32) void {
            std.debug.assert(active_callbacks > 0);
            std.debug.assert(active_handles > 0);
            active_callbacks -= 1;
            active_handles -= 1;
        }
    };

    const js = Js(LifecycleMockHost);
    const Fs = js.Module("node:fs");

    // 1. Module.call with explicit `js.Error!T` preserves exact error set (`js.Error!Ref(Any)`)
    const CallRetT = @TypeOf(Fs.call(fn ([]const u8) js.Error!js.Ref(js.Any), "readFileSync", .{"/nonexistent"}));
    try expectEqual(js.Error!js.Ref(js.Any), CallRetT);

    // Catching `error.JsException` WITHOUT calling `takeLastError()` allocates ZERO handles!
    try std.testing.expectError(
        error.JsException,
        Fs.call(fn ([]const u8) js.Error!js.Ref(js.Any), "readFileSync", .{"/nonexistent"}),
    );
    try expectEqual(@as(u32, 0), js.activeHandleCount());
    try expect(js.hasLastError());

    // `lastError()` peeks (allocates 1 handle) while keeping error pending; `takeLastError()` consumes it
    {
        const peeked = js.lastError().?;
        defer peeked.deinit();
        try expectEqual(@as(u32, 1), js.activeHandleCount());
        try expect(js.hasLastError());
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    {
        const err_info = js.takeLastError().?;
        defer err_info.deinit();
        try expect(!js.hasLastError());
        try expect(js.takeLastError() == null);

        const msg = (try err_info.message(std.testing.allocator)).?;
        defer std.testing.allocator.free(msg);
        try std.testing.expectEqualStrings("ENOENT: no such file or directory", msg);

        const nm = (try err_info.name(std.testing.allocator)).?;
        defer std.testing.allocator.free(nm);
        try std.testing.expectEqualStrings("Error", nm);

        const cd = (try err_info.code(std.testing.allocator)).?;
        defer std.testing.allocator.free(cd);
        try std.testing.expectEqualStrings("ENOENT", cd);

        const st = (try err_info.stack(std.testing.allocator)).?;
        defer std.testing.allocator.free(st);
        try expect(std.mem.indexOf(u8, st, "readFileSync") != null);
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // Primitive string, null, and undefined thrown values
    LifecycleMockHost.has_captured_err = true;
    LifecycleMockHost.captured_kind = .plain_str;
    {
        var prim_err = js.takeLastError().?;
        defer prim_err.deinit();
        const msg = (try prim_err.message(std.testing.allocator)).?;
        defer std.testing.allocator.free(msg);
        try std.testing.expectEqualStrings("plain thrown string", msg);
        try expect((try prim_err.name(std.testing.allocator)) == null);
        try expect((try prim_err.code(std.testing.allocator)) == null);
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    LifecycleMockHost.has_captured_err = true;
    LifecycleMockHost.captured_kind = .null_val;
    {
        const null_err = js.takeLastError().?;
        defer null_err.deinit();
        try expect(null_err.value().isNull());
        try expect((try null_err.message(std.testing.allocator)) == null);
    }

    LifecycleMockHost.has_captured_err = true;
    LifecycleMockHost.captured_kind = .undef_val;
    {
        const undef_err = js.takeLastError().?;
        defer undef_err.deinit();
        try expect(undef_err.value().isUndefined());
        try expect((try undef_err.message(std.testing.allocator)) == null);
    }

    // 2. Ref.dispose / tryDispose / asyncDispose / tryAsyncDispose
    js.Ref(js.Object).@"null".dispose();
    js.Ref(js.Object).@"undefined".asyncDispose();
    try js.Ref(js.Object).@"null".tryDispose();
    try js.Ref(js.Object).@"undefined".tryAsyncDispose();
    try expectEqual(@as(u32, 0), LifecycleMockHost.dispose_calls);

    {
        const res: js.Ref(js.Object) = .{ .handle = LifecycleMockHost.allocTagged(50) };
        res.dispose();
        try expectEqual(@as(u32, 1), LifecycleMockHost.dispose_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());
    }
    {
        const res: js.Ref(js.Object) = .{ .handle = LifecycleMockHost.allocTagged(51) };
        LifecycleMockHost.fail_next_dispose = true;
        try std.testing.expectError(error.JsException, res.tryDispose());
        // Handle MUST still be released even when [Symbol.dispose]() threw!
        try expectEqual(@as(u32, 0), js.activeHandleCount());
        js.clearLastError();
    }
    {
        const res: js.Ref(js.Object) = .{ .handle = LifecycleMockHost.allocTagged(52) };
        try res.tryAsyncDispose();
        try expectEqual(@as(u32, 1), LifecycleMockHost.async_dispose_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());
    }

    // 3. Closure (*Ctx, owned Ctx, void, type-sig & comptime-fn forms, .once(), ABA-safe defer deinit)
    const Counter = struct {
        total: i32 = 0,
        fn add(self: *@This(), delta: i32) i32 {
            self.total += delta;
            return self.total;
        }
        fn double(x: i32) i32 {
            return x * 2;
        }
    };

    const TrampolineThunk = *const fn (*const anyopaque, *anyopaque) anyerror!void;
    const CbArgs = arg_struct.ArgStruct(fn (i32) i32);

    var ctr: Counter = .{ .total = 10 };
    // Form A: `Closure(*Counter, fn (i32) i32).init(&ctr, Counter.add)`
    var cl_sig = js.Closure(*Counter, fn (i32) i32).init(&ctr, Counter.add);
    try expect(isCallbackWrapper(@TypeOf(cl_sig)));
    try expect(cl_sig.isActive());
    const thunk_a: TrampolineThunk = @ptrFromInt(LifecycleMockHost.stored_trampoline);
    var frame_a: CbArgs = .{ .retval = 0, .@"0" = 5 };
    try thunk_a(@ptrFromInt(cl_sig.id), @ptrCast(&frame_a));
    try expectEqual(@as(i32, 15), frame_a.retval);
    cl_sig.deinit();
    try expect(!cl_sig.isActive());

    // Form B: `Closure(*Counter, Counter.add).once(&ctr)` (one-shot auto-release + subsequent `defer deinit()`)
    {
        const cl_once = js.Closure(*Counter, Counter.add).once(&ctr);
        defer cl_once.deinit();
        try expectEqual(@as(u32, @bitCast(CallbackFlags{ .once = true })), LifecycleMockHost.last_cb_flags);
        try expect(cl_once.isActive());

        const thunk_b: TrampolineThunk = @ptrFromInt(LifecycleMockHost.stored_trampoline);
        var frame_b: CbArgs = .{ .retval = 0, .@"0" = 7 };
        try thunk_b(@ptrFromInt(cl_once.id), @ptrCast(&frame_b));
        try expectEqual(@as(i32, 22), frame_b.retval);

        // Immediately after `.once()` fires once, BOTH callback slot AND JS handle are already released!
        try expect(!cl_once.isActive());
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
        try expectEqual(@as(u32, 0), js.activeHandleCount());
        try expectEqual(@as(u32, 0), LifecycleMockHost.active_callbacks);

        // Second invocation must fail with `error.InvalidCallback`
        try std.testing.expectError(error.InvalidCallback, thunk_b(@ptrFromInt(cl_once.id), @ptrCast(&frame_b)));

        // Allocate another closure into the recycled slot BEFORE `defer cl_once.deinit()` runs to prove ABA safety!
        var cl_newer = js.Closure(void, Counter.double).init();
        defer cl_newer.deinit();
        try expectEqual(@as(u32, 1), js.activeCallbackCount());
        try expectEqual(@as(u32, 1), js.activeHandleCount());
    }
    try expectEqual(@as(u32, 0), js.activeCallbackCount());
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // Form C: Owned value closure `Closure(Counter, Counter.add).once(allocator, val)` both fired and unfired
    {
        const cl_owned_fired = try js.Closure(Counter, Counter.add).tryOnce(std.testing.allocator, .{ .total = 100 });
        defer cl_owned_fired.deinit();
        const thunk_c: TrampolineThunk = @ptrFromInt(LifecycleMockHost.stored_trampoline);
        var frame_c: CbArgs = .{ .retval = 0, .@"0" = 23 };
        try thunk_c(@ptrFromInt(cl_owned_fired.id), @ptrCast(&frame_c));
        try expectEqual(@as(i32, 123), frame_c.retval);
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
        try expectEqual(@as(u32, 0), js.activeHandleCount());
    }
    {
        var cl_owned_unfired = try js.Closure(Counter, fn (i32) i32).tryOnce(
            std.testing.allocator,
            .{ .total = 200 },
            Counter.add,
        );
        try expectEqual(@as(u32, 1), js.activeCallbackCount());
        try expectEqual(@as(u32, 1), js.activeHandleCount());
        cl_owned_unfired.deinit();
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
        try expectEqual(@as(u32, 0), js.activeHandleCount());
    }

    // Form D: Pre-trampoline JS arg conversion throw cancel via `cancel_thunk` both WITH and WITHOUT `deinit()`
    {
        var empty_byte: u8 = 0;
        const cl_cancelled_with_deinit = try js.Closure(Counter, Counter.add).tryOnce(
            std.testing.allocator,
            .{ .total = 300 },
        );
        defer cl_cancelled_with_deinit.deinit();
        const cancel_fn: TrampolineThunk = @ptrFromInt(LifecycleMockHost.stored_cancel_thunk);
        try cancel_fn(@ptrFromInt(cl_cancelled_with_deinit.id), @ptrCast(&empty_byte));
        try expect(!cl_cancelled_with_deinit.isActive());
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
        try expectEqual(@as(u32, 0), js.activeHandleCount());
        try expectEqual(@as(u32, 0), LifecycleMockHost.active_callbacks);
    }
    {
        var empty_byte: u8 = 0;
        const cl_cancelled_without_deinit = try js.Closure(Counter, Counter.add).tryOnce(
            std.testing.allocator,
            .{ .total = 400 },
        );
        const cancel_fn: TrampolineThunk = @ptrFromInt(LifecycleMockHost.stored_cancel_thunk);
        try cancel_fn(@ptrFromInt(cl_cancelled_without_deinit.id), @ptrCast(&empty_byte));
        // `std.testing.allocator` verifies HeapBox was freed even though `.deinit()` is never called!
        try expect(!cl_cancelled_without_deinit.isActive());
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
        try expectEqual(@as(u32, 0), js.activeHandleCount());
        try expectEqual(@as(u32, 0), LifecycleMockHost.active_callbacks);
    }
}

test "Js(#48): handle wrapper structs validate duck-typed methods/props without invoking getters, clone refs, and free cleanly" {
    const HandleMockHost = struct {
        var next_slot: u32 = 16;
        var active_handles: u32 = 0;
        var getter_reads_for_status: u32 = 0;

        // Tag encoding in low 20 bits:
        // 0x10 = class instance (`instanceof` = true)
        // 0x20 = duck-typed stateful service (`has("ping")`, `typeof ping == function`, `has("status")`)
        // 0x30 = callable function (`typeof == function`, `has("version")`)
        // 0x40 = JS Array (`typeof == object`, `Array.isArray == true`)
        // 0x50 = impostor object (`has("ping")` = true, but `typeof ping == string`!)
        fn allocKind(kind_tag: u32) u32 {
            active_handles += 1;
            const gen = next_slot;
            next_slot += 1;
            return (gen << 20) | kind_tag;
        }

        fn kindOf(h: u32) u32 {
            return h & 0xFFFFF;
        }

        pub fn releaseJsValue(h: u32) void {
            if (h >= first_dynamic_slot) {
                std.debug.assert(active_handles > 0);
                active_handles -= 1;
            }
        }

        pub fn cloneJsValue(h: u32) u32 {
            if (h <= reserved_global_this_handle) return h;
            return allocKind(kindOf(h));
        }

        pub fn getJsValueCount() u32 {
            return active_handles;
        }

        pub fn typeofJsValue(h: u32) JsType {
            if (h == reserved_undefined_handle) return .undefined;
            if (h == reserved_null_handle) return .object;
            return switch (kindOf(h)) {
                0x30, 0x90, 0x91 => .function,
                0x92 => .string,
                else => .object,
            };
        }

        pub fn instanceofJsValue(inst: u32, ctor: u32) bool {
            return kindOf(inst) == 0x10 and kindOf(ctor) == 0x90;
        }

        pub fn tryControlLastJsError(_: u32) Error!u32 {
            return no_captured_error_handle;
        }

        pub fn invokeJsHostOp(desc_ptr: *const anyopaque, arg_ptr: *anyopaque, _: usize) E {
            const desc: *const HostOpDescriptor = @ptrCast(@alignCast(desc_ptr));
            const key = if (desc.key_ptr) |p| p[0..desc.key_len] else "";
            const op: HostOp = @enumFromInt(desc.op);
            switch (op) {
                .import_module => {
                    const out_bytes: [*]u8 = @ptrCast(arg_ptr);
                    const handle_out: *u32 = @ptrCast(@alignCast(out_bytes));
                    handle_out.* = allocKind(0x80);
                    out_bytes[4] = 0;
                    return .SUCCESS;
                },
                .has_prop => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any)) Error!bool);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const k = kindOf(frame.@"0".handle);
                    frame.retval = switch (k) {
                        0x20 => std.mem.eql(u8, key, "ping") or std.mem.eql(u8, key, "status"),
                        0x30 => std.mem.eql(u8, key, "version"),
                        0x50 => std.mem.eql(u8, key, "ping") or std.mem.eql(u8, key, "status"),
                        else => false,
                    };
                    return .SUCCESS;
                },
                .get_prop => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any)) Error!Js(@This()).Ref(Any));
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const k = kindOf(frame.@"0".handle);
                    if (std.mem.eql(u8, key, "status")) {
                        getter_reads_for_status += 1;
                    }
                    if (k == 0x80 and std.mem.eql(u8, key, "MyClass")) {
                        frame.retval = .{ .handle = allocKind(0x90) };
                    } else if (k == 0x20 and std.mem.eql(u8, key, "ping")) {
                        frame.retval = .{ .handle = allocKind(0x91) };
                    } else if (k == 0x50 and std.mem.eql(u8, key, "ping")) {
                        frame.retval = .{ .handle = allocKind(0x92) };
                    } else if (hIsGlobal(frame.@"0".handle) and std.mem.eql(u8, key, "Array")) {
                        frame.retval = .{ .handle = allocKind(0x91) };
                    } else {
                        frame.retval = .@"undefined";
                    }
                    return .SUCCESS;
                },
                .binary_info => {
                    const Frame = arg_struct.ArgStruct(fn (Js(@This()).Ref(Any)) Error!bool);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    frame.retval = (kindOf(frame.@"0".handle) == 0x40);
                    return .SUCCESS;
                },
                else => return .FAULT,
            }
        }

        fn hIsGlobal(h: u32) bool {
            return h == reserved_global_this_handle;
        }
    };

    const js = Js(HandleMockHost);

    const ClassHandle = struct {
        ref: js.Ref(js.Object),
        pub fn deinit(self: @This()) void {
            self.ref.deinit();
        }
        pub const zigar_js = .{
            .js_name = "MyClass",
            .is_handle = true,
            .is_class = true,
            .is_callable_handle = false,
            .ref_field = "ref",
            .ctor_target = .{
                .module = @as(?[]const u8, "pkg"),
                .ns_path = &[_][]const u8{},
                .name = "MyClass",
                .is_default = false,
                .from_default = false,
            },
        };
    };

    const CallableHandle = struct {
        __zigar_ref: js.Ref(js.Function),
        pub fn deinit(self: @This()) void {
            self.__zigar_ref.deinit();
        }
        pub const zigar_js = .{
            .js_name = "CallableApi",
            .is_handle = true,
            .is_class = false,
            .is_callable_handle = true,
            .ref_field = "__zigar_ref",
            .required_methods = &[_][]const u8{},
            .required_props = &[_][]const u8{"version"},
        };
    };

    const ServiceHandle = struct {
        ref: js.Ref(js.Object),
        pub fn deinit(self: @This()) void {
            self.ref.deinit();
        }
        pub const zigar_js = .{
            .js_name = "Service",
            .is_handle = true,
            .is_class = false,
            .is_callable_handle = false,
            .ref_field = "ref",
            .required_methods = &[_][]const u8{"ping"},
            .required_props = &[_][]const u8{"status"},
        };
    };

    const UnconstrainedHandle = struct {
        ref: js.Ref(js.Object),
        pub fn deinit(self: @This()) void {
            self.ref.deinit();
        }
        pub const zigar_js = .{
            .js_name = "OptionalOnly",
            .is_handle = true,
            .is_class = false,
            .is_callable_handle = false,
            .ref_field = "ref",
            .required_methods = &[_][]const u8{},
            .required_props = &[_][]const u8{},
        };
    };

    try expect(!js.needsDecodeAllocator(ClassHandle));
    try expect(!js.needsDecodeAllocator(CallableHandle));
    try expect(!js.needsDecodeAllocator(ServiceHandle));

    // Verify union rank ordering: ClassHandle (70) < CallableHandle (71) < ServiceHandle (72) < UnconstrainedHandle (86)
    const MixedUnion = union(enum) {
        unconstrained: UnconstrainedHandle,
        service: ServiceHandle,
        callable: CallableHandle,
        cls: ClassHandle,
    };

    // 1. ClassHandle matches `0x10` (`instanceof MyClass`) and clones handle cleanly
    {
        const raw_cls: js.Ref(js.Any) = .{ .handle = HandleMockHost.allocKind(0x10) };
        defer raw_cls.deinit();
        const u = try js.fromJsRefAlloc(MixedUnion, std.testing.allocator, raw_cls);
        defer js.freeDecoded(MixedUnion, std.testing.allocator, u);
        try expectEqual(std.meta.Tag(MixedUnion).cls, std.meta.activeTag(u));

        const outbound = try js.toJsRef(ClassHandle, u.cls);
        defer outbound.deinit();
        try expectEqual(@as(u32, 0x10), HandleMockHost.kindOf(outbound.handle));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 2. ServiceHandle matches `0x20` WITHOUT invoking `.status` getter (`getter_reads_for_status == 0`)!
    {
        HandleMockHost.getter_reads_for_status = 0;
        const raw_svc: js.Ref(js.Any) = .{ .handle = HandleMockHost.allocKind(0x20) };
        defer raw_svc.deinit();
        const svc = try js.fromJsRef(ServiceHandle, raw_svc);
        defer svc.deinit();
        try expectEqual(@as(u32, 0), HandleMockHost.getter_reads_for_status);
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 3. Impostor object (`0x50`, `typeof ping == "string"`) is rejected by `ServiceHandle`
    {
        const raw_imp: js.Ref(js.Any) = .{ .handle = HandleMockHost.allocKind(0x50) };
        defer raw_imp.deinit();
        try std.testing.expectError(error.TypeError, js.fromJsRef(ServiceHandle, raw_imp));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 4. CallableHandle matches `0x30` (`typeof == "function"` + `has("version")`) and rejects plain objects
    {
        const raw_fn: js.Ref(js.Any) = .{ .handle = HandleMockHost.allocKind(0x30) };
        defer raw_fn.deinit();
        const u = try js.fromJsRefAlloc(MixedUnion, std.testing.allocator, raw_fn);
        defer js.freeDecoded(MixedUnion, std.testing.allocator, u);
        try expectEqual(std.meta.Tag(MixedUnion).callable, std.meta.activeTag(u));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 5. JS Array (`0x40`) is rejected by `UnconstrainedHandle` (`required_methods.len == 0`)
    {
        const raw_arr: js.Ref(js.Any) = .{ .handle = HandleMockHost.allocKind(0x40) };
        defer raw_arr.deinit();
        try std.testing.expectError(error.TypeError, js.fromJsRef(UnconstrainedHandle, raw_arr));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 6. Issue #49: comptime `.bases` assignability, non-owning `upcastValue`, `cloneHandle`,
    //    runtime `downcastHandle` (`tryAs`), value-struct projection, and numeric/template dynamic keys
    {
        const GrandBaseHandle = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{
                .js_name = "EventEmitter",
                .is_handle = true,
                .is_class = true,
                .ref_field = "ref",
            };
        };
        const MidBaseHandle = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{
                .js_name = "Stream",
                .is_handle = true,
                .is_class = true,
                .ref_field = "ref",
                .bases = .{GrandBaseHandle},
            };
        };
        const MixinHandle = struct {
            __zigar_ref: js.Ref(js.Object),
            pub const zigar_js = .{
                .js_name = "ServiceMixin",
                .is_handle = true,
                .is_class = false,
                .ref_field = "__zigar_ref",
                .required_methods = &[_][]const u8{"ping"},
                .required_props = &[_][]const u8{"status"},
            };
        };
        const DerivedHandle = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{
                .js_name = "ServerResponse",
                .is_handle = true,
                .is_class = true,
                .ref_field = "ref",
                .bases = .{ MidBaseHandle, MixinHandle },
                .ctor_target = .{
                    .module = @as(?[]const u8, "pkg"),
                    .ns_path = &[_][]const u8{},
                    .name = "MyClass",
                    .is_default = false,
                    .from_default = false,
                },
            };
        };
        const IntersectionHandle = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{
                .js_name = "ClassAndService",
                .is_handle = true,
                .is_class = false,
                .ref_field = "ref",
                .bases = .{ ClassHandle, ServiceHandle },
                .required_methods = &[_][]const u8{},
                .required_props = &[_][]const u8{},
            };
        };
        const UnrelatedHandle = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{
                .js_name = "Unrelated",
                .is_handle = true,
                .is_class = true,
                .ref_field = "ref",
            };
        };

        try expect(comptime js.isAssignableType(DerivedHandle, DerivedHandle));
        try expect(comptime js.isAssignableType(DerivedHandle, MidBaseHandle));
        try expect(comptime js.isAssignableType(DerivedHandle, GrandBaseHandle));
        try expect(comptime js.isAssignableType(DerivedHandle, MixinHandle));
        try expect(comptime !js.isAssignableType(DerivedHandle, UnrelatedHandle));

        const raw_inst: js.Ref(js.Object) = .{ .handle = HandleMockHost.allocKind(0x10) };
        const derived: DerivedHandle = .{ .ref = raw_inst };
        defer derived.ref.deinit();

        const as_grand = js.upcastValue(DerivedHandle, derived, GrandBaseHandle);
        const as_mixin = js.upcastValue(DerivedHandle, derived, MixinHandle);
        try expectEqual(derived.ref.handle, as_grand.ref.handle);
        try expectEqual(derived.ref.handle, as_mixin.__zigar_ref.handle);
        // Zero-cost non-owning upcast: active handle count remains 1!
        try expectEqual(@as(u32, 1), js.activeHandleCount());

        const cloned_derived = try js.cloneHandle(DerivedHandle, derived);
        try expectEqual(@as(u32, 2), js.activeHandleCount());
        cloned_derived.ref.deinit();
        try expectEqual(@as(u32, 1), js.activeHandleCount());

        // `downcastHandle` (`tryAs`) clones an owned handle on match (`0x10` -> `ClassHandle`), returns `null` (0 new handles) on mismatch
        const down_ok = try js.downcastHandle(ClassHandle, as_grand.ref);
        try expect(down_ok != null);
        try expect(derived.ref.handle != down_ok.?.ref.handle);
        try expectEqual(@as(u32, 2), js.activeHandleCount());
        down_ok.?.ref.deinit();
        try expectEqual(@as(u32, 1), js.activeHandleCount());

        const down_miss = try js.downcastHandle(ServiceHandle, as_grand.ref);
        try expect(down_miss == null);
        const down_inter_miss = try js.downcastHandle(IntersectionHandle, as_grand.ref);
        try expect(down_inter_miss == null);

        // Value-struct `.as(BaseOpts)` field projection (including optional widening & wire-name matching)
        const BaseOpts = struct {
            host: []const u8,
            port: ?f64 = null,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "host", .zig_name = "host" },
                    .{ .name = "port", .zig_name = "port" },
                },
            };
        };
        const SubOpts = struct {
            host_name: []const u8,
            port: f64,
            tls: bool,
            pub const zigar_js = .{
                .bases = .{BaseOpts},
                .fields = .{
                    .{ .name = "host", .zig_name = "host_name" },
                    .{ .name = "port", .zig_name = "port" },
                    .{ .name = "tls", .zig_name = "tls" },
                },
            };
        };
        const sub_opts: SubOpts = .{ .host_name = "localhost", .port = 8080, .tls = true };
        const base_opts = js.upcastValue(SubOpts, sub_opts, BaseOpts);
        try std.testing.expectEqualStrings("localhost", base_opts.host);
        try expectEqual(@as(?f64, 8080), base_opts.port);

        // Numeric and template-literal dynamic keys normalize cleanly
        const TplKey = struct {
            raw: []const u8,
            pub const zigar_js = .{ .is_template_literal = true };
        };
        try expectEqual(f64, js.DynamicKeyArgType(usize));
        try expectEqual(f64, js.DynamicKeyArgType(comptime_int));
        try expectEqual(f64, js.DynamicKeyArgType(f64));
        try expectEqual([]const u8, js.DynamicKeyArgType(TplKey));
        try expectEqual(@as(f64, 7.0), js.coerceDynamicKey(@as(usize, 7)));
        try std.testing.expectEqualStrings("x-test", js.coerceDynamicKey(TplKey{ .raw = "x-test" }));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}


test "Standard wrappers: ABI layout, Promise, binary views, collections, BigInt, Date, RegExp, and Iterators" {
    const WrapperMockHost = struct {
        const SelfHost = @This();
        var active_handles: u32 = 0;
        var next_slot: u32 = 16;
        var active_callbacks: u32 = 0;
        var await_unavailable: bool = false;
        var storage_bytes: [64]u8 = @splat(0);
        var storage_len: usize = 0;
        var view_offset: [128]usize = @splat(0);
        var view_len: [128]usize = @splat(0);
        var bigint_negative: bool = false;
        var bigint_lo: u64 = 0;
        var bigint_hi: u64 = 0;
        var bigint_overflow_64: bool = false;
        var iter_step: u32 = 0;
        var iter_closed: bool = false;
        var fail_array_index: ?usize = null;

        fn allocSlot(tag: u32) u32 {
            active_handles += 1;
            const gen = next_slot;
            next_slot += 1;
            const slot: usize = @intCast(gen & 127);
            view_offset[slot] = 0;
            view_len[slot] = storage_len;
            return (gen << 20) | tag;
        }

        pub fn cloneJsValue(handle: u32) u32 {
            if (handle <= reserved_global_this_handle) return handle;
            const out = allocSlot(handle & 0xFFFFF);
            const src_slot: usize = @intCast((handle >> 20) & 127);
            const dst_slot: usize = @intCast((out >> 20) & 127);
            view_offset[dst_slot] = view_offset[src_slot];
            view_len[dst_slot] = view_len[src_slot];
            return out;
        }

        pub fn releaseJsValue(handle: u32) void {
            if (handle >= first_dynamic_slot) {
                std.debug.assert(active_handles > 0);
                active_handles -= 1;
            }
        }

        pub fn equalJsValue(a: u32, b: u32) bool {
            return (a & 0xFFFFF) == (b & 0xFFFFF);
        }

        pub fn getJsValueCount() u32 {
            return active_handles;
        }

        pub fn createZigCallback(_: *const anyopaque, _: u32) Error!u32 {
            active_callbacks += 1;
            return allocSlot(90);
        }

        pub fn releaseZigCallback(_: u32) void {
            active_callbacks -= 1;
            active_handles -= 1;
        }

        pub fn awaitJsPromise(
            handle: u32,
            mode_raw: u32,
            _: *const anyopaque,
            arg_ptr: *anyopaque,
            _: usize,
            done_flag_addr: usize,
        ) E {
            if (await_unavailable) return .NOSYS;
            const mode: AwaitMode = @enumFromInt(mode_raw);
            const tag = handle & 0xFFFFF;
            switch (mode) {
                .promise => {
                    if (tag == 71) {
                        const Frame = arg_struct.ArgStruct(fn () Error!i32);
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        frame.retval = error.JsException;
                        return .SUCCESS;
                    }
                    if (tag == 72) {
                        const Frame = arg_struct.ArgStruct(fn (std.mem.Allocator) AllocError![]const u8);
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        frame.retval = frame.@"0".dupe(u8, "async-text") catch return .FAULT;
                        return .SUCCESS;
                    }
                    if (tag == 73) {
                        const Frame = arg_struct.ArgStruct(fn () Error!void);
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        frame.retval = {};
                        return .SUCCESS;
                    }
                    const Frame = arg_struct.ArgStruct(fn () Error!i32);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    frame.retval = 1234;
                    return .SUCCESS;
                },
                .async_iterator_next => {
                    const Frame = arg_struct.ArgStruct(fn () Error!?i32);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    defer iter_step += 1;
                    if (iter_step == 0) {
                        frame.retval = @as(?i32, 77);
                    } else if (iter_step == 1) {
                        // Yielding explicit JS `null` while `done == false`!
                        frame.retval = @as(?i32, null);
                    } else {
                        const done_ptr: *u8 = @ptrFromInt(done_flag_addr);
                        done_ptr.* = 1;
                    }
                    return .SUCCESS;
                },
                .async_iterator_return => {
                    iter_closed = true;
                    const Frame = arg_struct.ArgStruct(fn () Error!void);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    frame.retval = {};
                    return .SUCCESS;
                },
            }
        }

        pub fn invokeJsHostOp(desc_ptr: *const anyopaque, arg_ptr: *anyopaque, _: usize) E {
            const desc: *const HostOpDescriptor = @ptrCast(@alignCast(desc_ptr));
            const op: HostOp = @enumFromInt(desc.op);
            const J = Js(SelfHost);
            switch (op) {
                .promise_settle => {
                    if (desc.flags == 2) {
                        const Frame = arg_struct.ArgStruct(fn () Error!J.Promise(void));
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        frame.retval = .{ .handle = allocSlot(73) };
                    } else if (desc.flags == 1) {
                        const Frame = arg_struct.ArgStruct(fn ([]const u8) Error!J.Promise(i32));
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        frame.retval = .{ .handle = allocSlot(71) };
                    } else {
                        const Frame = arg_struct.ArgStruct(fn (i64) Error!J.Promise(i32));
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        frame.retval = .{ .handle = allocSlot(70) };
                    }
                    return .SUCCESS;
                },
                .call_method => {
                    const key = if (desc.key_ptr) |p| p[0..desc.key_len] else "";
                    if (std.mem.eql(u8, key, "then")) {
                        const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), J.Ref(Any), J.Ref(Any)) Error!J.Promise(i32));
                        const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                        frame.retval = .{ .handle = allocSlot(70) };
                        return .SUCCESS;
                    }
                    if (std.mem.eql(u8, key, "subarray")) {
                        const Sub2Fn = fn (J.Ref(Any), usize, usize) Error!J.Buffer;
                        const Sub1Fn = fn (J.Ref(Any), usize) Error!J.Buffer;
                        if (desc.signature == signature.get(arg_struct.ArgStruct(Sub2Fn))) {
                            const Frame = arg_struct.ArgStruct(Sub2Fn);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const src_slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                            const parent_len = view_len[src_slot];
                            const s = @min(frame.@"1", parent_len);
                            const e = @max(s, @min(frame.@"2", parent_len));
                            const out = allocSlot(frame.@"0".handle & 0xFFFFF);
                            const dst_slot: usize = @intCast((out >> 20) & 127);
                            view_offset[dst_slot] = view_offset[src_slot] + s;
                            view_len[dst_slot] = e - s;
                            frame.retval = .{ .handle = out };
                            return .SUCCESS;
                        } else if (desc.signature == signature.get(arg_struct.ArgStruct(Sub1Fn))) {
                            const Frame = arg_struct.ArgStruct(Sub1Fn);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const src_slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                            const parent_len = view_len[src_slot];
                            const s = @min(frame.@"1", parent_len);
                            const out = allocSlot(frame.@"0".handle & 0xFFFFF);
                            const dst_slot: usize = @intCast((out >> 20) & 127);
                            view_offset[dst_slot] = view_offset[src_slot] + s;
                            view_len[dst_slot] = parent_len - s;
                            frame.retval = .{ .handle = out };
                            return .SUCCESS;
                        }
                    }
                    return .FAULT;
                },
                .binary_create => {
                    const Frame = arg_struct.ArgStruct(fn (usize, usize, bool) Error!J.Ref(Object));
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const kind: BinaryKind = @enumFromInt(desc.flags);
                    const elem_size: usize = switch (kind) {
                        .int32_array, .uint32_array, .float32_array => 4,
                        .big_uint64_array, .big_int64_array, .float64_array => 8,
                        .uint16_array, .int16_array => 2,
                        else => 1,
                    };
                    const byte_len = frame.@"1" * elem_size;
                    storage_len = byte_len;
                    if (frame.@"2" and byte_len > 0) {
                        const src: [*]const u8 = @ptrFromInt(frame.@"0");
                        @memcpy(storage_bytes[0..byte_len], src[0..byte_len]);
                    } else if (byte_len > 0) {
                        @memset(storage_bytes[0..byte_len], 0);
                    }
                    frame.retval = .{ .handle = allocSlot(50 + desc.flags) };
                    return .SUCCESS;
                },
                .binary_read => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize, usize, usize) Error!usize);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                    const base_off = view_offset[slot];
                    const v_len = view_len[slot];
                    const offset = frame.@"3";
                    const copy_len = if (offset >= v_len) 0 else @min(frame.@"2", v_len - offset);
                    if (copy_len > 0) {
                        const dst: [*]u8 = @ptrFromInt(frame.@"1");
                        @memcpy(dst[0..copy_len], storage_bytes[base_off + offset .. base_off + offset + copy_len]);
                    }
                    frame.retval = copy_len;
                    return .SUCCESS;
                },
                .binary_write => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize, usize, usize) Error!void);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                    const base_off = view_offset[slot];
                    const v_len = view_len[slot];
                    const copy_len = frame.@"2";
                    const offset = frame.@"3";
                    if (offset + copy_len > v_len) {
                        frame.retval = error.JsException;
                        return .SUCCESS;
                    }
                    if (copy_len > 0) {
                        const src: [*]const u8 = @ptrFromInt(frame.@"1");
                        @memcpy(storage_bytes[base_off + offset .. base_off + offset + copy_len], src[0..copy_len]);
                    }
                    frame.retval = {};
                    return .SUCCESS;
                },
                .binary_info => {
                    const info_kind: BinaryInfoKind = @enumFromInt(desc.flags);
                    switch (info_kind) {
                        .byte_length => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                            frame.retval = view_len[slot];
                        },
                        .byte_offset => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                            frame.retval = view_offset[slot];
                        },
                        .element_length => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                            const tag = frame.@"0".handle & 0xFFFFF;
                            const elem_size: usize = if (tag == 50 + @intFromEnum(BinaryKind.int32_array)) 4 else 1;
                            frame.retval = view_len[slot] / elem_size;
                        },
                        .is_buffer => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!bool);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = (frame.@"0".handle & 0xFFFFF) == 50 + @intFromEnum(BinaryKind.buffer);
                        },
                        .is_array => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!bool);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = (frame.@"0".handle & 0xFFFFF) == 80;
                        },
                    }
                    return .SUCCESS;
                },
                .bigint_from_words => {
                    const Frame = arg_struct.ArgStruct(fn (bool, u64, u64) Error!J.BigInt);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    bigint_negative = frame.@"0";
                    bigint_lo = frame.@"1";
                    bigint_hi = frame.@"2";
                    bigint_overflow_64 = (bigint_hi != 0);
                    frame.retval = .{ .handle = allocSlot(65) };
                    return .SUCCESS;
                },
                .bigint_from_string => {
                    const Frame = arg_struct.ArgStruct(fn ([]const u8) Error!J.BigInt);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    bigint_overflow_64 = frame.@"0".len > 20;
                    frame.retval = .{ .handle = allocSlot(66) };
                    return .SUCCESS;
                },
                .bigint_to_words => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), u32, bool, usize) Error!u32);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const width = frame.@"1";
                    const is_signed = frame.@"2";
                    if (width == 64 and (bigint_overflow_64 or (!is_signed and bigint_negative))) {
                        frame.retval = 1;
                        return .SUCCESS;
                    }
                    if (!is_signed and bigint_negative) {
                        frame.retval = 1;
                        return .SUCCESS;
                    }
                    const out_words: *[2]u64 = @ptrFromInt(frame.@"3");
                    const mag: u128 = (@as(u128, bigint_hi) << 64) | @as(u128, bigint_lo);
                    const twos: u128 = if (bigint_negative) (0 -% mag) else mag;
                    out_words[0] = @truncate(twos);
                    out_words[1] = @truncate(twos >> 64);
                    frame.retval = 0;
                    return .SUCCESS;
                },
                .bigint_to_string => {
                    const Frame = arg_struct.ArgStruct(fn (std.mem.Allocator, J.Ref(Any), u32) AllocError![]u8);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    frame.retval = frame.@"0".dupe(u8, "0xffffffffffffffffffffffffffffffff") catch return .FAULT;
                    return .SUCCESS;
                },
                .get_iterator => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!J.Ref(Object));
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    iter_step = 0;
                    iter_closed = false;
                    frame.retval = .{ .handle = allocSlot(88) };
                    return .SUCCESS;
                },
                .iterator_next => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize) Error!?i32);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    defer iter_step += 1;
                    if (iter_step == 0) {
                        frame.retval = @as(?i32, 11);
                    } else if (iter_step == 1) {
                        frame.retval = @as(?i32, null);
                    } else {
                        const done_ptr: *u8 = @ptrFromInt(frame.@"1");
                        done_ptr.* = 1;
                    }
                    return .SUCCESS;
                },
                .iterator_return => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!void);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    iter_closed = true;
                    frame.retval = {};
                    return .SUCCESS;
                },
                .collection_op => {
                    const sub: CollectionSubOp = @enumFromInt(desc.flags);
                    switch (sub) {
                        .array_init => {
                            const Frame = arg_struct.ArgStruct(fn () Error!J.Ref(Object));
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = .{ .handle = allocSlot(80) };
                        },
                        .array_len => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = 3;
                        },
                        .array_get => {
                            const tag_check: *const J.Ref(Any) = @ptrCast(@alignCast(arg_ptr));
                            _ = tag_check;
                            // Distinguish Ref-element array vs string-element array via signature
                            const RefGetFn = fn (J.Ref(Any), usize) Error!J.Ref(Object);
                            const StrGetFn = fn (std.mem.Allocator, J.Ref(Any), usize) AllocError![]const u8;
                            if (desc.signature == signature.get(arg_struct.ArgStruct(RefGetFn))) {
                                const Frame = arg_struct.ArgStruct(RefGetFn);
                                const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                                if (fail_array_index != null and frame.@"1" == fail_array_index.?) {
                                    frame.retval = error.JsException;
                                } else {
                                    frame.retval = .{ .handle = allocSlot(81) };
                                }
                            } else if (desc.signature == signature.get(arg_struct.ArgStruct(StrGetFn))) {
                                const Frame = arg_struct.ArgStruct(StrGetFn);
                                const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                                if (fail_array_index != null and frame.@"2" == fail_array_index.?) {
                                    frame.retval = error.JsException;
                                } else {
                                    frame.retval = frame.@"0".dupe(u8, "elem") catch return .FAULT;
                                }
                            } else {
                                return .FAULT;
                            }
                        },
                        .map_init => {
                            const Frame = arg_struct.ArgStruct(fn () Error!J.Ref(Object));
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = .{ .handle = allocSlot(82) };
                        },
                        .map_get => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), []const u8, usize) Error!?i32);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            if (std.mem.eql(u8, frame.@"1", "present_val")) {
                                frame.retval = @as(?i32, 42);
                            } else if (std.mem.eql(u8, frame.@"1", "present_null")) {
                                frame.retval = @as(?i32, null);
                            } else {
                                const miss_ptr: *u8 = @ptrFromInt(frame.@"2");
                                miss_ptr.* = 1;
                            }
                        },
                        .date_now => {
                            const Frame = arg_struct.ArgStruct(fn () Error!f64);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = 1700000000000.0;
                        },
                        .regexp_init => {
                            const Frame = arg_struct.ArgStruct(fn ([]const u8, []const u8) Error!J.RegExp);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = .{ .handle = allocSlot(85) };
                        },
                        .regexp_test => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), []const u8) Error!bool);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = std.mem.indexOf(u8, frame.@"1", "zig") != null;
                        },
                        .binary_get_buffer => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!J.ArrayBuffer);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = .{ .handle = allocSlot(50 + @intFromEnum(BinaryKind.array_buffer)) };
                        },
                        .typed_array_get => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize) Error!u8);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                            if (frame.@"1" >= view_len[slot]) {
                                frame.retval = error.JsException;
                            } else {
                                frame.retval = storage_bytes[view_offset[slot] + frame.@"1"];
                            }
                        },
                        .typed_array_set => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize, u8) Error!void);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const slot: usize = @intCast((frame.@"0".handle >> 20) & 127);
                            if (frame.@"1" >= view_len[slot]) {
                                frame.retval = error.JsException;
                            } else {
                                storage_bytes[view_offset[slot] + frame.@"1"] = frame.@"2";
                                frame.retval = {};
                            }
                        },
                        else => return .FAULT,
                    }
                    return .SUCCESS;
                },
                else => return .FAULT,
            }
        }
    };

    const js = Js(WrapperMockHost);

    // 1. Verify 4-byte handle layout and `.js_value` internal_type on both 32-bit wasm and 64-bit native
    inline for (.{
        js.Promise(i32),
        js.Promise(void),
        js.ArrayBuffer,
        js.SharedArrayBuffer,
        js.DataView,
        js.Buffer,
        js.Uint8Array,
        js.Uint8ClampedArray,
        js.Int32Array,
        js.Float64Array,
        js.BigUint64Array,
        js.Array(i32),
        js.Map([]const u8, i32),
        js.Set(i32),
        js.Record([]const u8, i32),
        js.BigInt,
        js.Date,
        js.RegExp,
        js.Iterator(i32),
        js.AsyncIterator(i32),
        js.Disposable,
        js.AsyncDisposable,
    }) |WrapperT| {
        try expectEqual(@as(usize, 4), @sizeOf(WrapperT));
        try expectEqual(@as(usize, 4), @alignOf(WrapperT));
        try expectEqual(util.InternalType.js_value, util.getInternalType(WrapperT));
    }

    // 2. Promise(T): resolve, multiple borrows in `.await()`, `.then(closure, null)` type inference, reject, HostUnavailable
    {
        const p = try js.Promise(i32).resolve(1234);
        defer p.deinit();
        try expectEqual(@as(i32, 1234), try p.await());
        try expectEqual(@as(i32, 1234), try p.wait());

        const Adder = struct {
            fn addOne(x: i32) i32 {
                return x + 1;
            }
        };
        const cl = try js.Closure(void, Adder.addOne).tryInit();
        defer cl.deinit();
        const p_chained = try p.then(cl, null);
        defer p_chained.deinit();
        try expectEqual(js.Promise(i32), @TypeOf(p_chained));

        WrapperMockHost.await_unavailable = true;
        try std.testing.expectError(error.HostUnavailable, p.await());
        WrapperMockHost.await_unavailable = false;

        const p_rej = try js.Promise(i32).reject("boom");
        defer p_rej.deinit();
        try std.testing.expectError(error.JsException, p_rej.await());

        const p_void = try js.Promise(void).resolve({});
        defer p_void.deinit();
        try p_void.await();

        const p_str: js.Promise([]const u8) = .{ .handle = WrapperMockHost.allocSlot(72) };
        defer p_str.deinit();
        const text = try p_str.awaitAlloc(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("async-text", text);
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());
    try expectEqual(@as(u32, 0), js.activeCallbackCount());

    // 3. Binary views: 0-length & bulk roundtrips for Buffer, Int32Array, ArrayBuffer
    {
        const empty_buf = try js.Buffer.fromSlice(&.{});
        defer empty_buf.deinit();
        try expect(try js.Buffer.isBuffer(empty_buf));
        try expectEqual(@as(usize, 0), try empty_buf.byteLength());
        const empty_owned = try empty_buf.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(empty_owned);
        try expectEqual(@as(usize, 0), empty_owned.len);

        const src_ints = [_]i32{ -10, 20, -30, 4096 };
        const i32_ta = try js.Int32Array.fromSlice(&src_ints);
        defer i32_ta.deinit();
        try expect(!try js.Buffer.isBuffer(i32_ta));
        try expectEqual(@as(usize, 4), try i32_ta.len());
        try expectEqual(@as(usize, 16), try i32_ta.byteLength());
        const owned_ints = try i32_ta.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(owned_ints);
        try std.testing.expectEqualSlices(i32, &src_ints, owned_ints);

        // Zero-copy Buffer.subarray + byteOffset + get/set + copyToAt/writeFromAt + backing ArrayBuffer
        const full_buf = try js.Buffer.fromSlice("hello world");
        defer full_buf.deinit();
        try expectEqual(@as(usize, 11), try full_buf.byteLength());
        try expectEqual(@as(usize, 0), try full_buf.byteOffset());
        const backing_ab = try full_buf.buffer();
        defer backing_ab.deinit();
        try expectEqual(@as(usize, 11), try backing_ab.byteLength());

        const sub_buf = try full_buf.subarray(6, 11);
        defer sub_buf.deinit();
        try expect(try js.Buffer.isBuffer(sub_buf));
        try expectEqual(@as(usize, 5), try sub_buf.byteLength());
        try expectEqual(@as(usize, 6), try sub_buf.byteOffset());
        try expectEqual(@as(u8, 'w'), try sub_buf.get(0));
        try sub_buf.set(0, 'W');
        try sub_buf.writeFromAt("ORLD", 1);

        var tail_check: [5]u8 = undefined;
        try expectEqual(@as(usize, 5), try full_buf.copyToAt(&tail_check, 6));
        try std.testing.expectEqualStrings("WORLD", &tail_check);

        const mutated = try full_buf.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(mutated);
        try std.testing.expectEqualStrings("hello WORLD", mutated);

        // Open-ended TypedArray.subarray(start, null)
        const u8_ta = try js.Uint8Array.fromSlice("abcdef");
        defer u8_ta.deinit();
        const u8_tail = try u8_ta.subarray(2, null);
        defer u8_tail.deinit();
        try expectEqual(@as(usize, 4), try u8_tail.len());
        try expectEqual(@as(usize, 2), try u8_tail.byteOffset());
        try u8_tail.set(0, 'C');
        try expectEqual(@as(u8, 'C'), try u8_ta.get(2));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 4. Array.toOwnedSlice mid-array error cleanup (zero leaked handles AND zero leaked allocations!)
    {
        const ref_arr = try js.Array(js.Ref(js.Object)).init();
        defer ref_arr.deinit();
        try expect(try js.Array(i32).isArray(ref_arr));
        WrapperMockHost.fail_array_index = 2;
        try std.testing.expectError(error.JsException, ref_arr.toOwnedSlice(std.testing.allocator));
        WrapperMockHost.fail_array_index = null;
        // Elements 0 and 1 must have been `.deinit()`ed by `errdefer`; only `ref_arr` remains live!
        try expectEqual(@as(u32, 1), js.activeHandleCount());

        const str_arr: js.Array([]const u8) = .{ .handle = WrapperMockHost.allocSlot(80) };
        defer str_arr.deinit();
        WrapperMockHost.fail_array_index = 2;
        try std.testing.expectError(error.JsException, str_arr.toOwnedSlice(std.testing.allocator));
        WrapperMockHost.fail_array_index = null;
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 5. Map(?i32) missing vs explicit null value, BigInt bounds/overflow, Date, RegExp
    {
        const m = try js.Map([]const u8, ?i32).init();
        defer m.deinit();
        const v_present = try m.get("present_val");
        try expectEqual(@as(??i32, @as(?i32, 42)), v_present);
        const v_null = try m.get("present_null");
        try expect(v_null != null and v_null.? == null);
        const v_missing = try m.get("missing");
        try expect(v_missing == null);

        const bi_min = try js.BigInt.fromI128(std.math.minInt(i128));
        defer bi_min.deinit();
        try expectEqual(std.math.minInt(i128), try bi_min.toI128());
        try std.testing.expectError(error.Overflow, bi_min.toI64());
        try std.testing.expectError(error.Overflow, bi_min.toU128());

        const bi_huge = try js.BigInt.fromString("0xffffffffffffffffffffffffffffffff");
        defer bi_huge.deinit();
        const hex = try bi_huge.toStringAlloc(std.testing.allocator, 16);
        defer std.testing.allocator.free(hex);
        try std.testing.expectEqualStrings("0xffffffffffffffffffffffffffffffff", hex);

        try expectEqual(@as(f64, 1700000000000.0), try js.Date.now());
        const re = try js.RegExp.init("zig", "i");
        defer re.deinit();
        try expect(try re.testMatch("hello zigar"));
        try expect(!try re.@"test"("hello world"));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 6. Iterator(?i32) and AsyncIterator(?i32) distinguishing `{ value: null, done: false }` from `{ done: true }`
    {
        const src: js.Ref(js.Object) = .{ .handle = WrapperMockHost.allocSlot(87) };
        defer src.deinit();

        const it = try js.Iterator(?i32).from(src);
        defer it.deinit();
        try expectEqual(@as(??i32, @as(?i32, 11)), try it.next());
        const step_null = try it.next();
        try expect(step_null != null and step_null.? == null);
        try expect((try it.next()) == null);
        try it.close();
        try expect(WrapperMockHost.iter_closed);

        const ait = try js.AsyncIterator(?i32).from(src);
        defer ait.deinit();
        try expectEqual(@as(??i32, @as(?i32, 77)), try ait.next());
        const astep_null = try ait.next();
        try expect(astep_null != null and astep_null.? == null);
        try expect((try ait.next()) == null);
        try ait.returnEarly();
        try expect(WrapperMockHost.iter_closed);
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}

test "CallbackRegistry: FIFO reuse, permanent retirement at 0xFFF, multi-slab O(1) lookup, and signature check" {
    const RegistryAuditMockHost = struct {
        var active_handles: u32 = 0;
        var active_callbacks: u32 = 0;
        var stored_trampoline: usize = 0;
        var next_handle_id: u32 = first_dynamic_slot;

        pub fn cloneJsValue(handle: u32) u32 {
            if (handle <= reserved_global_this_handle) return handle;
            active_handles += 1;
            const out = next_handle_id;
            next_handle_id += 1;
            return out;
        }

        pub fn releaseJsValue(handle: u32) void {
            if (handle >= first_dynamic_slot) {
                std.debug.assert(active_handles > 0);
                active_handles -= 1;
            }
        }

        pub fn equalJsValue(a: u32, b: u32) bool {
            return a == b;
        }

        pub fn getJsValueCount() u32 {
            return active_handles;
        }

        pub fn createZigCallback(desc_ptr: *const anyopaque, _: u32) Error!u32 {
            const desc: *const CallbackDescriptor = @ptrCast(@alignCast(desc_ptr));
            stored_trampoline = desc.trampoline_thunk;
            active_callbacks += 1;
            active_handles += 1;
            const out = next_handle_id;
            next_handle_id += 1;
            return out;
        }

        pub fn releaseZigCallback(_: u32) void {
            std.debug.assert(active_callbacks > 0);
            std.debug.assert(active_handles > 0);
            active_callbacks -= 1;
            active_handles -= 1;
        }
    };

    const js = Js(RegistryAuditMockHost);
    const TrampolineThunk = *const fn (*const anyopaque, *anyopaque) anyerror!void;

    const Fns = struct {
        fn addOne(x: i32) i32 {
            return x + 1;
        }
        fn addTwoU32(x: u32) u32 {
            return x + 2;
        }
    };

    // 1. Verify FIFO free-queue ordering across freed callback slots
    {
        var c1 = js.Closure(void, Fns.addOne).init();
        var c2 = js.Closure(void, Fns.addOne).init();
        var c3 = js.Closure(void, Fns.addOne).init();
        try expectEqual(@as(u32, 1), c1.id & 0x000F_FFFF);
        try expectEqual(@as(u32, 2), c2.id & 0x000F_FFFF);
        try expectEqual(@as(u32, 3), c3.id & 0x000F_FFFF);
        c1.deinit();
        c2.deinit();
        c3.deinit();

        var r1 = js.Closure(void, Fns.addOne).init();
        var r2 = js.Closure(void, Fns.addOne).init();
        var r3 = js.Closure(void, Fns.addOne).init();
        try expectEqual(@as(u32, 1), r1.id & 0x000F_FFFF);
        try expectEqual(@as(u32, 2), r2.id & 0x000F_FFFF);
        try expectEqual(@as(u32, 3), r3.id & 0x000F_FFFF);
        try expectEqual(@as(u32, 2), r1.id >> 20);
        try expectEqual(@as(u32, 2), r2.id >> 20);
        try expectEqual(@as(u32, 2), r3.id >> 20);
        r1.deinit();
        r2.deinit();
        r3.deinit();
    }

    // 2. Run 13,000 Closure alloc/deinit cycles across the 3 FIFO-queued slots:
    // verify fair FIFO rotation across slots 1..3, permanent retirement of all 3 slots at 0xFFF (4095),
    // automatic advancement to slot 4, and zero wraparound / zero ABA reuse!
    var seen_ids = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen_ids.deinit();
    var stale_first_id: u32 = 0;
    var stale_max_gen_id: u32 = 0;
    var retired_count: u32 = 0;
    const i32_thunk_capture = blk: {
        var tmp = js.Closure(void, Fns.addOne).init();
        stale_first_id = tmp.id;
        const thunk_ptr = RegistryAuditMockHost.stored_trampoline;
        try seen_ids.putNoClobber(tmp.id, {});
        tmp.deinit();
        break :blk @as(TrampolineThunk, @ptrFromInt(thunk_ptr));
    };

    const I32Args = arg_struct.ArgStruct(fn (i32) i32);
    var cycle: usize = 0;
    while (cycle < 13000) : (cycle += 1) {
        var cl = js.Closure(void, Fns.addOne).init();
        const gen = cl.id >> 20;
        try expect(gen >= 1 and gen <= 0x0FFF);
        // Every issued CallbackId across all 6,000 cycles MUST be globally unique!
        try seen_ids.putNoClobber(cl.id, {});
        if (gen == 0x0FFF) {
            retired_count += 1;
            if (stale_max_gen_id == 0) stale_max_gen_id = cl.id;
        }
        var call_frame: I32Args = .{ .retval = 0, .@"0" = @intCast(cycle) };
        try i32_thunk_capture(@ptrFromInt(cl.id), @ptrCast(&call_frame));
        try expectEqual(@as(i32, @intCast(cycle + 1)), call_frame.retval);

        // Stale IDs must NEVER resolve to a live callback!
        try std.testing.expectError(error.InvalidCallback, i32_thunk_capture(@ptrFromInt(stale_first_id), @ptrCast(&call_frame)));
        if (stale_max_gen_id != 0 and stale_max_gen_id != cl.id) {
            try std.testing.expectError(error.InvalidCallback, i32_thunk_capture(@ptrFromInt(stale_max_gen_id), @ptrCast(&call_frame)));
        }
        cl.deinit();
    }
    try expect(retired_count >= 1);
    try expectEqual(@as(u32, 0), js.activeCallbackCount());
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 3. Multi-slab O(1) lookup across >200 simultaneous live callbacks (4+ slabs of 64 entries)
    {
        var live: [220]js.Closure(void, Fns.addOne) = undefined;
        for (&live, 0..) |*slot, idx| {
            slot.* = js.Closure(void, Fns.addOne).init();
            var frame: I32Args = .{ .retval = 0, .@"0" = @intCast(idx * 3) };
            try i32_thunk_capture(@ptrFromInt(slot.id), @ptrCast(&frame));
            try expectEqual(@as(i32, @intCast(idx * 3 + 1)), frame.retval);
        }
        try expectEqual(@as(u32, 220), js.activeCallbackCount());
        for (&live, 0..) |*slot, idx| {
            var frame: I32Args = .{ .retval = 0, .@"0" = @intCast(idx + 10) };
            try i32_thunk_capture(@ptrFromInt(slot.id), @ptrCast(&frame));
            try expectEqual(@as(i32, @intCast(idx + 11)), frame.retval);
            slot.deinit();
        }
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
    }

    // 4. Signature hash verification in trampolineThunk rejects mismatched callback signatures
    {
        var i32_cb = js.Closure(void, Fns.addOne).init();
        defer i32_cb.deinit();
        var u32_cb = js.Closure(void, Fns.addTwoU32).init();
        defer u32_cb.deinit();
        const u32_thunk: TrampolineThunk = @ptrFromInt(RegistryAuditMockHost.stored_trampoline);
        const U32Args = arg_struct.ArgStruct(fn (u32) u32);
        var u32_frame: U32Args = .{ .retval = 0, .@"0" = 40 };

        // Valid signature succeeds
        try u32_thunk(@ptrFromInt(u32_cb.id), @ptrCast(&u32_frame));
        try expectEqual(@as(u32, 42), u32_frame.retval);

        // Dispatching `i32_cb.id` (`fn (i32) i32`) through `u32_thunk` (`fn (u32) u32`) MUST fail with `error.SignatureMismatch`!
        try std.testing.expectError(error.SignatureMismatch, u32_thunk(@ptrFromInt(i32_cb.id), @ptrCast(&u32_frame)));
    }
    try expectEqual(@as(u32, 0), js.activeCallbackCount());
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}

test "Js.String, Nullable(T), needsDecodeAllocator, and tuple/slice marshaling helpers" {
    const RecProp = struct {
        key: []u8,
        val: u32,
    };

    const ValEntry = union(enum) {
        unused,
        str: []u8,
        num: f64,
        bi: i64,
        arr: std.ArrayList(u32),
        rec: std.ArrayList(RecProp),
        buf: usize,
        cb_fn: u32,
    };

    const MarshalingMockHost = struct {
        pub const default_allocator = std.testing.allocator;
        var entries: [256]ValEntry = @splat(.unused);
        var refcounts: [256]u32 = @splat(0);
        var cb_handles: [64]struct { cid: u32 = 0, handle: u32 = 0 } = @splat(.{});

        fn reset() void {
            for (&entries, 0..) |*e, idx| {
                switch (e.*) {
                    .str => |s| std.testing.allocator.free(s),
                    .arr => |*a| a.deinit(std.testing.allocator),
                    .rec => |*r| {
                        for (r.items) |kv| std.testing.allocator.free(kv.key);
                        r.deinit(std.testing.allocator);
                    },
                    else => {},
                }
                e.* = .unused;
                refcounts[idx] = 0;
            }
        }

        fn allocVal(v: ValEntry) u32 {
            for (8..entries.len) |idx| {
                if (refcounts[idx] == 0) {
                    entries[idx] = v;
                    refcounts[idx] = 1;
                    return @intCast((1 << 20) | idx);
                }
            }
            unreachable;
        }

        pub fn cloneJsValue(handle: u32) u32 {
            if (handle < 8) return handle;
            const slot = handle & 0xFFFFF;
            std.debug.assert(refcounts[slot] > 0);
            refcounts[slot] += 1;
            return handle;
        }

        pub fn releaseJsValue(handle: u32) void {
            if (handle < 8) return;
            const slot = handle & 0xFFFFF;
            std.debug.assert(refcounts[slot] > 0);
            refcounts[slot] -= 1;
            if (refcounts[slot] == 0) {
                switch (entries[slot]) {
                    .str => |s| std.testing.allocator.free(s),
                    .arr => |*a| {
                        for (a.items) |child_h| releaseJsValue(child_h);
                        a.deinit(std.testing.allocator);
                    },
                    .rec => |*r| {
                        for (r.items) |kv| {
                            std.testing.allocator.free(kv.key);
                            releaseJsValue(kv.val);
                        }
                        r.deinit(std.testing.allocator);
                    },
                    else => {},
                }
                entries[slot] = .unused;
            }
        }

        pub fn typeofJsValue(handle: u32) JsType {
            if (handle == 0) return .@"undefined";
            if (handle == 1 or handle == 4) return .object;
            if (handle == 2 or handle == 3) return .boolean;
            const slot = handle & 0xFFFFF;
            return switch (entries[slot]) {
                .str => .string,
                .num => .number,
                .bi => .bigint,
                .arr, .rec, .buf => .object,
                .cb_fn => .function,
                .unused => .@"undefined",
            };
        }

        pub fn createZigCallback(_: *const anyopaque, callback_id: u32) CallError!u32 {
            const h = allocVal(.{ .cb_fn = callback_id });
            for (&cb_handles) |*slot| {
                if (slot.cid == 0) {
                    slot.* = .{ .cid = callback_id, .handle = h };
                    break;
                }
            }
            return h;
        }

        pub fn releaseZigCallback(callback_id: u32) void {
            for (&cb_handles) |*slot| {
                if (slot.cid == callback_id) {
                    const h = slot.handle;
                    slot.* = .{};
                    releaseJsValue(h);
                    break;
                }
            }
        }

        pub fn instanceofJsValue(_: u32, _: u32) bool {
            return false;
        }

        pub fn equalJsValue(lhs: u32, rhs: u32) bool {
            return lhs == rhs;
        }

        pub fn getJsValueCount() u32 {
            var total: u32 = 0;
            for (refcounts) |rc| total += rc;
            return total;
        }

        pub fn invokeJsHostOp(desc_ptr: *const anyopaque, arg_ptr: *anyopaque, _: usize) E {
            const desc: *const HostOpDescriptor = @ptrCast(@alignCast(desc_ptr));
            const op: HostOp = @enumFromInt(desc.op);
            const J = Js(@This());
            switch (op) {
                .get_prop => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) CallError!J.Ref(Any));
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const h = f.@"0".handle;
                    const key = if (desc.key_ptr) |kp| kp[0..desc.key_len] else "";
                    if (h >= 8 and entries[h & 0xFFFFF] == .rec) {
                        for (entries[h & 0xFFFFF].rec.items) |kv| {
                            if (std.mem.eql(u8, kv.key, key)) {
                                f.retval = .{ .handle = cloneJsValue(kv.val) };
                                return .SUCCESS;
                            }
                        }
                        f.retval = .{ .handle = 0 };
                        return .SUCCESS;
                    }
                    return .FAULT;
                },
                .has_prop => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) CallError!bool);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const h = f.@"0".handle;
                    const key = if (desc.key_ptr) |kp| kp[0..desc.key_len] else "";
                    if (h >= 8 and entries[h & 0xFFFFF] == .rec) {
                        var found = false;
                        for (entries[h & 0xFFFFF].rec.items) |kv| {
                            if (std.mem.eql(u8, kv.key, key)) {
                                found = true;
                                break;
                            }
                        }
                        f.retval = found;
                        return .SUCCESS;
                    }
                    return .FAULT;
                },
                .set_prop => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), J.Ref(Any)) CallError!void);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const h = f.@"0".handle;
                    const key = if (desc.key_ptr) |kp| kp[0..desc.key_len] else "";
                    if (h >= 8 and entries[h & 0xFFFFF] == .rec) {
                        const rec_ptr = &entries[h & 0xFFFFF].rec;
                        for (rec_ptr.items) |*kv| {
                            if (std.mem.eql(u8, kv.key, key)) {
                                releaseJsValue(kv.val);
                                kv.val = cloneJsValue(f.@"1".handle);
                                f.retval = {};
                                return .SUCCESS;
                            }
                        }
                        const k_copy = std.testing.allocator.dupe(u8, key) catch return .FAULT;
                        rec_ptr.append(std.testing.allocator, .{ .key = k_copy, .val = cloneJsValue(f.@"1".handle) }) catch {
                            std.testing.allocator.free(k_copy);
                            return .FAULT;
                        };
                        f.retval = {};
                        return .SUCCESS;
                    }
                    return .FAULT;
                },
                .binary_create => {
                    const Frame = arg_struct.ArgStruct(fn (usize, usize, bool) Error!J.Buffer);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    f.retval = .{ .handle = allocVal(.{ .buf = f.@"1" }) };
                },
                .binary_info => {
                    const info: BinaryInfoKind = @enumFromInt(desc.flags);
                    switch (info) {
                        .is_array => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!bool);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const h = f.@"0".handle;
                            f.retval = h >= 8 and entries[h & 0xFFFFF] == .arr;
                        },
                        else => return .FAULT,
                    }
                },
                .collection_op => {
                    const sub: CollectionSubOp = @enumFromInt(desc.flags);
                    switch (sub) {
                        .string_from_utf8 => {
                            const Frame = arg_struct.ArgStruct(fn ([]const u8) Error!J.String);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const copy = std.testing.allocator.dupe(u8, f.@"0") catch return .FAULT;
                            f.retval = .{ .handle = allocVal(.{ .str = copy }) };
                        },
                        .string_to_utf8 => {
                            const Frame = arg_struct.ArgStruct(fn (std.mem.Allocator, J.Ref(Any)) AllocError![]u8);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const h = f.@"1".handle;
                            if (h < 8 or entries[h & 0xFFFFF] != .str) {
                                f.retval = error.JsException;
                            } else {
                                f.retval = f.@"0".dupe(u8, entries[h & 0xFFFFF].str);
                            }
                        },
                        .string_byte_len => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const h = f.@"0".handle;
                            if (h < 8 or entries[h & 0xFFFFF] != .str) {
                                f.retval = error.JsException;
                            } else {
                                f.retval = entries[h & 0xFFFFF].str.len;
                            }
                        },
                        .string_utf16_len => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const h = f.@"0".handle;
                            if (h < 8 or entries[h & 0xFFFFF] != .str) {
                                f.retval = error.JsException;
                            } else {
                                f.retval = std.unicode.calcUtf16LeLen(entries[h & 0xFFFFF].str) catch return .FAULT;
                            }
                        },
                        .string_is_string => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!bool);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const h = f.@"0".handle;
                            f.retval = h >= 8 and entries[h & 0xFFFFF] == .str;
                        },
                        .binary_is_kind => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), u32) Error!bool);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const h = f.@"0".handle;
                            f.retval = h >= 8 and entries[h & 0xFFFFF] == .buf and f.@"1" == @intFromEnum(BinaryKind.buffer);
                        },
                        .value_identity => {
                            // Discriminate signature hash for f64/i64/bool box & unbox
                            const BoxF64 = fn (f64) CallError!J.Ref(Any);
                            const UnboxF64 = fn (J.Ref(Any)) CallError!f64;
                            const BoxI64 = fn (i64) CallError!J.Ref(Any);
                            const UnboxI64 = fn (J.Ref(Any)) CallError!i64;
                            const UnboxBool = fn (J.Ref(Any)) CallError!bool;
                            if (desc.signature == signature.get(arg_struct.ArgStruct(BoxF64))) {
                                const f: *arg_struct.ArgStruct(BoxF64) = @ptrCast(@alignCast(arg_ptr));
                                f.retval = .{ .handle = allocVal(.{ .num = f.@"0" }) };
                            } else if (desc.signature == signature.get(arg_struct.ArgStruct(UnboxF64))) {
                                const f: *arg_struct.ArgStruct(UnboxF64) = @ptrCast(@alignCast(arg_ptr));
                                f.retval = entries[f.@"0".handle & 0xFFFFF].num;
                            } else if (desc.signature == signature.get(arg_struct.ArgStruct(BoxI64))) {
                                const f: *arg_struct.ArgStruct(BoxI64) = @ptrCast(@alignCast(arg_ptr));
                                f.retval = .{ .handle = allocVal(.{ .bi = f.@"0" }) };
                            } else if (desc.signature == signature.get(arg_struct.ArgStruct(UnboxI64))) {
                                const f: *arg_struct.ArgStruct(UnboxI64) = @ptrCast(@alignCast(arg_ptr));
                                f.retval = entries[f.@"0".handle & 0xFFFFF].bi;
                            } else if (desc.signature == signature.get(arg_struct.ArgStruct(UnboxBool))) {
                                const f: *arg_struct.ArgStruct(UnboxBool) = @ptrCast(@alignCast(arg_ptr));
                                f.retval = (f.@"0".handle == 3);
                            } else return .FAULT;
                        },
                        .array_init => {
                            const Frame = arg_struct.ArgStruct(fn () Error!J.Array(J.Ref(Any)));
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            f.retval = .{ .handle = allocVal(.{ .arr = .empty }) };
                        },
                        .array_with_capacity => {
                            const Frame = arg_struct.ArgStruct(fn (usize) Error!J.Array(J.Ref(Any)));
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            var list: std.ArrayList(u32) = .empty;
                            list.appendNTimes(std.testing.allocator, 0, f.@"0") catch return .FAULT;
                            f.retval = .{ .handle = allocVal(.{ .arr = list }) };
                        },
                        .array_len => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            f.retval = entries[f.@"0".handle & 0xFFFFF].arr.items.len;
                        },
                        .array_get => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize) Error!J.Ref(Any));
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const items = entries[f.@"0".handle & 0xFFFFF].arr.items;
                            const elem_h = if (f.@"1" < items.len) cloneJsValue(items[f.@"1"]) else 0;
                            f.retval = .{ .handle = elem_h };
                        },
                        .array_set => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize, J.Ref(Any)) Error!void);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            var arr_ptr = &entries[f.@"0".handle & 0xFFFFF].arr;
                            releaseJsValue(arr_ptr.items[f.@"1"]);
                            arr_ptr.items[f.@"1"] = cloneJsValue(f.@"2".handle);
                            f.retval = {};
                        },
                        .array_push => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), J.Ref(Any)) Error!usize);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            var arr_ptr = &entries[f.@"0".handle & 0xFFFFF].arr;
                            arr_ptr.append(std.testing.allocator, cloneJsValue(f.@"1".handle)) catch return .FAULT;
                            f.retval = arr_ptr.items.len;
                        },
                        .record_init => {
                            const Frame = arg_struct.ArgStruct(fn () Error!J.Record([]const u8, J.Ref(Any)));
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            f.retval = .{ .handle = allocVal(.{ .rec = .empty }) };
                        },
                        .record_set => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), []const u8, J.Ref(Any)) Error!void);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            var rec_ptr = &entries[f.@"0".handle & 0xFFFFF].rec;
                            for (rec_ptr.items) |*kv| {
                                if (std.mem.eql(u8, kv.key, f.@"1")) {
                                    releaseJsValue(kv.val);
                                    kv.val = cloneJsValue(f.@"2".handle);
                                    f.retval = {};
                                    return .SUCCESS;
                                }
                            }
                            const k_copy = std.testing.allocator.dupe(u8, f.@"1") catch return .FAULT;
                            rec_ptr.append(std.testing.allocator, .{ .key = k_copy, .val = cloneJsValue(f.@"2".handle) }) catch {
                                std.testing.allocator.free(k_copy);
                                return .FAULT;
                            };
                            f.retval = {};
                        },
                        .record_get => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), []const u8, usize) Error!J.Ref(Any));
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const rec_items = entries[f.@"0".handle & 0xFFFFF].rec.items;
                            const missing_ptr: *u8 = @ptrFromInt(f.@"2");
                            for (rec_items) |kv| {
                                if (std.mem.eql(u8, kv.key, f.@"1")) {
                                    missing_ptr.* = 0;
                                    f.retval = .{ .handle = cloneJsValue(kv.val) };
                                    return .SUCCESS;
                                }
                            }
                            missing_ptr.* = 1;
                            f.retval = .{ .handle = 0 };
                        },
                        .record_has => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), []const u8) Error!bool);
                            const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const rec_items = entries[f.@"0".handle & 0xFFFFF].rec.items;
                            var found = false;
                            for (rec_items) |kv| {
                                if (std.mem.eql(u8, kv.key, f.@"1")) {
                                    found = true;
                                    break;
                                }
                            }
                            f.retval = found;
                        },
                        else => return .FAULT,
                    }
                },
                .bigint_to_words => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), u32, bool, usize) Error!u32);
                    const f: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const h = f.@"0".handle;
                    if (h < 8 or entries[h & 0xFFFFF] != .bi) return .FAULT;
                    const v: i128 = entries[h & 0xFFFFF].bi;
                    const words_ptr: *[2]u64 = @ptrFromInt(f.@"3");
                    const bits: u128 = @bitCast(v);
                    words_ptr[0] = @truncate(bits);
                    words_ptr[1] = @truncate(bits >> 64);
                    f.retval = 0;
                },
                else => return .FAULT,
            }
            return .SUCCESS;
        }
    };
    defer MarshalingMockHost.reset();

    const js = Js(MarshalingMockHost);
    const alloc = std.testing.allocator;

    // 1. Js.String layout, UTF-8 / UTF-16 lengths, and roundtrip
    try expectEqual(@as(usize, 4), @sizeOf(js.String));
    try expectEqual(util.InternalType.js_value, util.getInternalType(js.String));
    const s_emoji = try js.String.fromSlice("hi 🚀");
    try expect(try js.String.isString(s_emoji));
    try expect(!try js.String.isString(js.Ref(js.Any).@"null"));
    try expectEqual(@as(usize, 7), try s_emoji.byteLen());
    try expectEqual(@as(usize, 5), try s_emoji.utf16Len());
    const s_back = try s_emoji.toSliceAlloc(alloc);
    try std.testing.expectEqualStrings("hi 🚀", s_back);
    alloc.free(s_back);
    s_emoji.deinit();
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 2. Nullable(T) tri-state semantics & deinit
    const NBuf = js.Nullable(js.Buffer);
    const n_undef: NBuf = .@"undefined";
    const n_null: NBuf = .@"null";
    try expect(n_undef.isUndefined() and n_undef.isNullOrUndefined());
    try expect(n_null.isNull() and n_null.isNullOrUndefined());
    try expectEqual(@as(?js.Buffer, null), n_undef.toOptional());
    try expectEqual(NBuf.@"null", NBuf.fromOptional(null));
    try expectEqual(NBuf.@"undefined", NBuf.fromOptionalUndefined(null));
    const buf_v = try js.Buffer.alloc(16);
    const n_val: NBuf = .{ .value = buf_v };
    try expect(!n_val.isNullOrUndefined());
    n_val.deinit();
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 3. needsDecodeAllocator traits
    try expect(!js.needsDecodeAllocator(f64));
    try expect(!js.needsDecodeAllocator(js.Buffer));
    try expect(!js.needsDecodeAllocator(js.Nullable(js.String)));
    try expect(js.needsDecodeAllocator([]const u8));
    try expect(js.needsDecodeAllocator(?[]const u8));

    // 4. Optional & Nullable NullishKind marshaling
    const r_opt_undef = try js.toJsRefWithNullish(?f64, null, .undefined_only);
    try expect(r_opt_undef.isUndefined());
    const r_opt_null = try js.toJsRefWithNullish(?f64, null, .null_only);
    try expect(r_opt_null.isNull());
    try expectEqual(js.Nullable(f64).@"undefined", try js.fromJsRef(js.Nullable(f64), r_opt_undef));
    try expectEqual(js.Nullable(f64).@"null", try js.fromJsRef(js.Nullable(f64), r_opt_null));

    // 5. Tuple marshaling: trailing-null omission, leading/middle/trailing variadic, and errdefer leak cleanup
    const OptTuple = struct {
        host: []const u8,
        port: ?f64 = null,
        pub const zigar_js_tuple = .{
            .variadic_index = @as(?usize, null),
            .optional_mask = @as(u64, 0b10),
        };
    };
    const t1_ref = try js.toJsRef(OptTuple, .{ .host = "localhost" });
    try expectEqual(@as(usize, 1), try js.Array(js.Ref(js.Any)).fromRef(t1_ref).len());
    const t1_dec = try js.fromJsRefAlloc(OptTuple, alloc, t1_ref);
    t1_ref.deinit();
    try std.testing.expectEqualStrings("localhost", t1_dec.host);
    try expectEqual(@as(?f64, null), t1_dec.port);
    js.freeDecoded(OptTuple, alloc, t1_dec);
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    const MidVarTuple = struct {
        head: i64,
        mid: []const []const u8 = &.{},
        tail: bool,
        pub const zigar_js_tuple = .{
            .variadic_index = @as(?usize, 1),
            .optional_mask = @as(u64, 0),
        };
    };
    const mv_ref = try js.toJsRef(MidVarTuple, .{ .head = -99, .mid = &.{ "alpha", "beta" }, .tail = true });
    try expectEqual(@as(usize, 4), try js.Array(js.Ref(js.Any)).fromRef(mv_ref).len());
    const mv_dec = try js.fromJsRefAlloc(MidVarTuple, alloc, mv_ref);
    mv_ref.deinit();
    try expectEqual(@as(i64, -99), mv_dec.head);
    try expectEqual(@as(usize, 2), mv_dec.mid.len);
    try std.testing.expectEqualStrings("alpha", mv_dec.mid[0]);
    try std.testing.expectEqualStrings("beta", mv_dec.mid[1]);
    try expect(mv_dec.tail);
    js.freeDecoded(MidVarTuple, alloc, mv_dec);

    // Partial-decode failure on element 2 AFTER element 0 allocated []const u8 and element 1 cloned Buffer:
    // std.testing.allocator + activeHandleCount() verify ZERO Zig or JS handle leaks!
    const PartialFailTuple = struct {
        label: []const u8,
        buf: js.Buffer,
        num: f64,
        pub const zigar_js_tuple = .{
            .variadic_index = @as(?usize, null),
            .optional_mask = @as(u64, 0),
        };
    };
    const bad_arr = try js.Array(js.Ref(js.Any)).init();
    const s_tmp = try js.String.fromSlice("allocated-before-error");
    const b_tmp = try js.Buffer.alloc(8);
    _ = try bad_arr.push(s_tmp.toRef());
    _ = try bad_arr.push(b_tmp.toRef().cast(js.Any));
    // Push a string where f64 is expected so element 2 fails with error.TypeError!
    _ = try bad_arr.push(s_tmp.toRef());
    s_tmp.deinit();
    b_tmp.deinit();
    try std.testing.expectError(error.TypeError, js.fromJsRefAlloc(PartialFailTuple, alloc, bad_arr.toRef()));
    bad_arr.deinit();
    const non_str = try js.toJsRef(f64, 123);
    try std.testing.expectError(error.TypeError, js.fromJsRefAlloc([]const u8, alloc, non_str));
    try std.testing.expect(!js.hasLastError());
    non_str.deinit();
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 6. Recursive NullishSpec: slices, required vs optional struct fields, Nullable(T), and >64-elem tuples
    {
        const s_null_arr = try js.toJsRefWithSpec([]const ?[]const u8, &.{ "hi", null }, .{ .self = .none, .elem = .null_only });
        defer s_null_arr.deinit();
        const js_sn = js.Array(js.Ref(js.Any)).fromRef(s_null_arr);
        try expectEqual(@as(usize, 2), try js_sn.len());
        const sn0 = try js_sn.get(0);
        defer sn0.deinit();
        try expect(try js.String.isString(sn0));
        const sn1 = try js_sn.get(1);
        defer sn1.deinit();
        try expect(sn1.isNull());

        const n_undef_arr = try js.toJsRefWithSpec([]const ?f64, &.{ 1.0, null }, .{ .self = .none, .elem = .undefined_only });
        defer n_undef_arr.deinit();
        const js_nu = js.Array(js.Ref(js.Any)).fromRef(n_undef_arr);
        try expectEqual(@as(usize, 2), try js_nu.len());
        const nu1 = try js_nu.get(1);
        defer nu1.deinit();
        try expect(nu1.isUndefined());

        const Payload = struct {
            req_null: ?f64,
            req_undef: ?f64,
            opt_num: ?f64 = null,
            opt_tri: js.Nullable(f64) = .@"undefined",
            items: ?[]const ?[]const u8 = null,

            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "req_null", .js_name = "reqNull", .is_optional = false, .nullish = .null_only },
                    .{ .name = "req_undef", .js_name = "reqUndef", .is_optional = false, .nullish = .undefined_only },
                    .{ .name = "opt_num", .js_name = "optNum", .is_optional = true, .nullish = .undefined_only },
                    .{ .name = "opt_tri", .js_name = "optTri", .is_optional = true, .nullish = .null_only },
                    .{
                        .name = "items",
                        .js_name = "items",
                        .is_optional = true,
                        .nullish = .{ .self = .undefined_only, .child = .{ .self = .none, .elem = .null_only } },
                    },
                },
            };
        };

        // Case A: required null/undefined preserved, optional null/.undefined omitted
        const p1_ref = try js.toJsRef(Payload, .{ .req_null = null, .req_undef = null });
        defer p1_ref.deinit();
        const p1_rec = js.Record([]const u8, js.Ref(js.Any)).fromRef(p1_ref);
        try expect(try p1_rec.has("reqNull"));
        try expect((try p1_rec.get("reqNull")).?.isNull());
        try expect(try p1_rec.has("reqUndef"));
        try expect((try p1_rec.get("reqUndef")).?.isUndefined());
        try expect(!try p1_rec.has("optNum"));
        try expect((try p1_rec.get("optNum")) == null);
        try expect(!try p1_rec.has("optTri"));
        try expect(!try p1_rec.has("items"));

        // Case B: optional Nullable(f64) set to .null MUST be emitted as null; items present preserves element null
        const p2_ref = try js.toJsRef(Payload, .{
            .req_null = 5.0,
            .req_undef = 6.0,
            .opt_tri = .@"null",
            .items = &.{ "ok", null },
        });
        defer p2_ref.deinit();
        const p2_rec = js.Record([]const u8, js.Ref(js.Any)).fromRef(p2_ref);
        try expect(try p2_rec.has("optTri"));
        try expect((try p2_rec.get("optTri")).?.isNull());
        try expect(try p2_rec.has("items"));
        const p2_items_ref = (try p2_rec.get("items")).?;
        defer p2_items_ref.deinit();
        const p2_items = js.Array(js.Ref(js.Any)).fromRef(p2_items_ref);
        try expectEqual(@as(usize, 2), try p2_items.len());
        const p2_i1 = try p2_items.get(1);
        defer p2_i1.deinit();
        try expect(p2_i1.isNull());

        // Case C: Tuple `.fields` metadata with undefined_only, null_only, optional, and variadic rest null_only
        const SpecTuple = struct {
            v: ?f64,
            w: ?[]const u8,
            opt: ?bool = null,
            rest: []const ?f64 = &.{},
            pub const zigar_js_tuple = .{
                .variadic_index = @as(?usize, 3),
                .fields = .{
                    .{ .is_optional = false, .nullish = .undefined_only },
                    .{ .is_optional = false, .nullish = .null_only },
                    .{ .is_optional = true, .nullish = .undefined_only },
                    .{ .is_optional = false, .nullish = .null_only },
                },
            };
        };
        const st_ref = try js.toJsRef(SpecTuple, .{
            .v = null,
            .w = null,
            .opt = null,
            .rest = &.{ 9.0, null },
        });
        defer st_ref.deinit();
        const st_arr = js.Array(js.Ref(js.Any)).fromRef(st_ref);
        try expectEqual(@as(usize, 5), try st_arr.len());
        try expect((try st_arr.get(0)).isUndefined());
        try expect((try st_arr.get(1)).isNull());
        try expect((try st_arr.get(2)).isUndefined());
        const st_3 = try st_arr.get(3);
        defer st_3.deinit();
        try expectEqual(@as(f64, 9.0), try js.fromJsRef(f64, st_3));
        try expect((try st_arr.get(4)).isNull());

        // Case D: 66-element tuple (>64 elements) exercises index 64 (.undefined_only) and index 65 (is_optional = true)
        const Wide66 = struct {
            @"0": bool = true, @"1": bool = true, @"2": bool = true, @"3": bool = true,
            @"4": bool = true, @"5": bool = true, @"6": bool = true, @"7": bool = true,
            @"8": bool = true, @"9": bool = true, @"10": bool = true, @"11": bool = true,
            @"12": bool = true, @"13": bool = true, @"14": bool = true, @"15": bool = true,
            @"16": bool = true, @"17": bool = true, @"18": bool = true, @"19": bool = true,
            @"20": bool = true, @"21": bool = true, @"22": bool = true, @"23": bool = true,
            @"24": bool = true, @"25": bool = true, @"26": bool = true, @"27": bool = true,
            @"28": bool = true, @"29": bool = true, @"30": bool = true, @"31": bool = true,
            @"32": bool = true, @"33": bool = true, @"34": bool = true, @"35": bool = true,
            @"36": bool = true, @"37": bool = true, @"38": bool = true, @"39": bool = true,
            @"40": bool = true, @"41": bool = true, @"42": bool = true, @"43": bool = true,
            @"44": bool = true, @"45": bool = true, @"46": bool = true, @"47": bool = true,
            @"48": bool = true, @"49": bool = true, @"50": bool = true, @"51": bool = true,
            @"52": bool = true, @"53": bool = true, @"54": bool = true, @"55": bool = true,
            @"56": bool = true, @"57": bool = true, @"58": bool = true, @"59": bool = true,
            @"60": bool = true, @"61": bool = true, @"62": bool = true, @"63": bool = true,
            @"64": ?f64,
            @"65": ?f64 = null,
            pub const zigar_js_tuple = blk: {
                const Entry = struct { is_optional: bool, nullish: js.NullishKind };
                const prefix: [64]Entry = @splat(.{ .is_optional = false, .nullish = .none });
                const suffix = [_]Entry{
                    .{ .is_optional = false, .nullish = .undefined_only },
                    .{ .is_optional = true, .nullish = .undefined_only },
                };
                break :blk .{
                    .variadic_index = @as(?usize, null),
                    .fields = prefix ++ suffix,
                };
            };
        };
        const w66_ref = try js.toJsRef(Wide66, .{ .@"64" = null });
        defer w66_ref.deinit();
        const w66_arr = js.Array(js.Ref(js.Any)).fromRef(w66_ref);
        // Element 65 (is_optional = true, null) trimmed -> length 65; element 64 (.undefined_only, null) -> undefined!
        try expectEqual(@as(usize, 65), try w66_arr.len());
        try expect((try w66_arr.get(64)).isUndefined());
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 7. M3.1b: Enums (with aliases & length-bounded 0-alloc check), open literal unions, template patterns,
    //    discriminated unions (1-probe non-fallthrough + outbound constraint check), and heterogeneous union specificity
    {
        const HttpMethod = enum(i32) {
            get = 0,
            post = 1,
            pub const get_alias: @This() = .get;
            pub const zigar_js = .{
                .is_enum = true,
                .members = .{
                    .{ .tag = "get", .js_name = "GET", .str_value = "GET" },
                    .{ .tag = "get", .js_name = "GET_ALIAS", .str_value = "GET", .is_alias = true },
                    .{ .tag = "post", .js_name = "POST", .str_value = "POST" },
                },
            };
        };
        const m_ref = try js.toJsRef(HttpMethod, .post);
        try expectEqual(HttpMethod.post, try js.fromJsRefAlloc(HttpMethod, alloc, m_ref));
        m_ref.deinit();

        const huge_str = try js.String.fromSlice("THIS_STRING_IS_WAY_LONGER_THAN_POST_AND_REJECTED_BY_BYTE_LEN");
        try std.testing.expectError(error.TypeError, js.fromJsRefAlloc(HttpMethod, alloc, huge_str.toRef()));
        huge_str.deinit();

        const NumEnum = enum(i32) {
            ok = 200,
            not_found = 404,
            pub const zigar_js = .{
                .is_enum = true,
                .members = .{
                    .{ .tag = "ok", .js_name = "Ok", .num_value = @as(f64, 200) },
                    .{ .tag = "not_found", .js_name = "NotFound", .num_value = @as(f64, 404) },
                },
            };
        };
        const ne_ref = try js.toJsRef(NumEnum, .not_found);
        try expectEqual(NumEnum.not_found, try js.fromJsRefAlloc(NumEnum, alloc, ne_ref));
        ne_ref.deinit();

        // Open literal union: "utf8" | "hex" | (string & {})
        const OpenEncoding = union(enum) {
            utf8: void,
            hex: void,
            custom_string: []const u8,
            pub fn from(val: anytype) @This() {
                return js.coerceUnion(@This(), val);
            }
            pub const zigar_js = .{
                .is_union = true,
                .is_open_literal = true,
                .variants = .{
                    .{ .tag = "utf8", .is_unit_literal = true, .str_value = "utf8" },
                    .{ .tag = "hex", .is_unit_literal = true, .str_value = "hex" },
                    .{ .tag = "custom_string", .is_custom = true, .nullish = .none },
                },
            };
        };
        const oe_known_ref = try js.toJsRef(OpenEncoding, .hex);
        const oe_known = try js.fromJsRefAlloc(OpenEncoding, alloc, oe_known_ref);
        oe_known_ref.deinit();
        try expectEqual(OpenEncoding.hex, oe_known);
        js.freeDecoded(OpenEncoding, alloc, oe_known);

        const oe_custom_in = OpenEncoding.from("latin1-custom");
        const oe_custom_ref = try js.toJsRef(OpenEncoding, oe_custom_in);
        const oe_custom = try js.fromJsRefAlloc(OpenEncoding, alloc, oe_custom_ref);
        oe_custom_ref.deinit();
        try std.testing.expectEqualStrings("latin1-custom", oe_custom.custom_string);
        js.freeDecoded(OpenEncoding, alloc, oe_custom);

        // Template literal pattern struct: `v${number}.${number}` + anti-ReDoS check
        const SemVerShort = struct {
            raw: []const u8,
            pub const zigar_js = .{
                .is_template_literal = true,
                .head = "v",
                .spans = .{
                    .{ .placeholder = js.TemplatePlaceholderKind.number, .choices = &[_][]const u8{}, .literal_tail = "." },
                    .{ .placeholder = js.TemplatePlaceholderKind.number, .choices = &[_][]const u8{}, .literal_tail = "" },
                },
            };
        };
        const sv_ok_ref = try js.toJsRef(SemVerShort, .{ .raw = "v26.1" });
        const sv_ok = try js.fromJsRefAlloc(SemVerShort, alloc, sv_ok_ref);
        sv_ok_ref.deinit();
        try std.testing.expectEqualStrings("v26.1", sv_ok.raw);
        js.freeDecoded(SemVerShort, alloc, sv_ok);

        try std.testing.expectError(error.TypeError, js.toJsRef(SemVerShort, .{ .raw = "invalid" }));
        const sv_bad_str = try js.String.fromSlice("v26.notanumber");
        try std.testing.expectError(error.TypeError, js.fromJsRefAlloc(SemVerShort, alloc, sv_bad_str.toRef()));
        sv_bad_str.deinit();

        const PathologicalTpl = struct {
            pub const head = "a";
            pub const spans = .{
                .{ .placeholder = js.TemplatePlaceholderKind.any_string, .choices = &[_][]const u8{}, .literal_tail = "a" },
                .{ .placeholder = js.TemplatePlaceholderKind.any_string, .choices = &[_][]const u8{}, .literal_tail = "a" },
                .{ .placeholder = js.TemplatePlaceholderKind.any_string, .choices = &[_][]const u8{}, .literal_tail = "a" },
                .{ .placeholder = js.TemplatePlaceholderKind.any_string, .choices = &[_][]const u8{}, .literal_tail = "b" },
            };
        };
        const a64 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        try expect(!js.matchTemplatePattern(PathologicalTpl, a64 ++ "c"));
        try expect(js.matchTemplatePattern(PathologicalTpl, a64 ++ "b"));

        // Discriminated union: `{ kind: "text", body: string } | { kind: "code" | "exit", status: number }`
        const TextMsg = struct {
            kind: []const u8 = "text",
            body: []const u8,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "kind", .js_name = "kind", .is_optional = false, .nullish = .none, .expected_str = "text" },
                    .{ .name = "body", .js_name = "body", .is_optional = false, .nullish = .none },
                },
            };
        };
        const CodeMsg = struct {
            kind: []const u8,
            status: f64,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "kind", .js_name = "kind", .is_optional = false, .nullish = .none },
                    .{ .name = "status", .js_name = "status", .is_optional = false, .nullish = .none },
                },
            };
        };
        const DiscMsg = union(enum) {
            text: TextMsg,
            code_or_exit: CodeMsg,
            pub const zigar_js = .{
                .is_union = true,
                .discriminant = "kind",
                .variants = .{
                    .{ .tag = "text", .nullish = .none, .disc_values = .{.{ .str_value = "text" }} },
                    .{
                        .tag = "code_or_exit",
                        .nullish = .none,
                        .disc_values = .{ .{ .str_value = "code" }, .{ .str_value = "exit" } },
                    },
                },
            };
        };
        const dm_ref = try js.toJsRef(DiscMsg, .{ .code_or_exit = .{ .kind = "exit", .status = 0 } });
        const dm_dec = try js.fromJsRefAlloc(DiscMsg, alloc, dm_ref);
        dm_ref.deinit();
        try expectEqual(std.meta.activeTag(dm_dec), .code_or_exit);
        try std.testing.expectEqualStrings("exit", dm_dec.code_or_exit.kind);
        try expectEqual(@as(f64, 0), dm_dec.code_or_exit.status);
        js.freeDecoded(DiscMsg, alloc, dm_dec);

        // Outbound singleton validation rejects forged discriminant!
        try std.testing.expectError(error.TypeError, js.toJsRef(TextMsg, .{ .kind = "forged", .body = "bad" }));

        // Inbound discriminated union with matched tag `"text"` but wrong `body` type MUST fail directly without leaks
        const bad_disc_rec = try js.Record([]const u8, js.Ref(js.Any)).init();
        const k_str = try js.String.fromSlice("text");
        const bad_body = try js.toJsRef(f64, 99);
        try bad_disc_rec.set("kind", k_str.toRef());
        try bad_disc_rec.set("body", bad_body);
        k_str.deinit();
        bad_body.deinit();
        try std.testing.expectError(error.TypeError, js.fromJsRefAlloc(DiscMsg, alloc, bad_disc_rec.toRef()));
        bad_disc_rec.deinit();

        // Heterogeneous union specificity: `[string] | string[] | Buffer | string | { host: string }`
        const SingleElemTuple = struct {
            @"0": []const u8,
            pub const zigar_js_tuple = .{
                .variadic_index = @as(?usize, null),
                .optional_mask = @as(u64, 0),
            };
        };
        const HostOpts = struct {
            host: []const u8,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "host", .js_name = "host", .is_optional = false, .nullish = .none },
                },
            };
        };
        const HeteroTarget = union(enum) {
            opts: HostOpts,
            str: []const u8,
            str_list: []const []const u8,
            one_tuple: SingleElemTuple,
            buf: js.Buffer,
            pub const zigar_js = .{
                .is_union = true,
                .variants = .{
                    .{ .tag = "opts", .nullish = .none },
                    .{ .tag = "str", .nullish = .none },
                    .{ .tag = "str_list", .nullish = .none },
                    .{ .tag = "one_tuple", .nullish = .none },
                    .{ .tag = "buf", .nullish = .none },
                },
            };
        };

        // 1-element array -> matches `[string]` (`one_tuple`), NOT plain struct `opts`!
        const arr1_ref = try js.toJsRef([]const []const u8, &.{"only-one"});
        const h_t1 = try js.fromJsRefAlloc(HeteroTarget, alloc, arr1_ref);
        arr1_ref.deinit();
        try expectEqual(std.meta.activeTag(h_t1), .one_tuple);
        try std.testing.expectEqualStrings("only-one", h_t1.one_tuple.@"0");
        js.freeDecoded(HeteroTarget, alloc, h_t1);

        // 2-element array -> `[string]` rejects `len > 1` (no truncation!), falls through to `string[]` (`str_list`), NEVER `opts`!
        const arr2_ref = try js.toJsRef([]const []const u8, &.{ "first", "second" });
        const h_t2 = try js.fromJsRefAlloc(HeteroTarget, alloc, arr2_ref);
        arr2_ref.deinit();
        try expectEqual(std.meta.activeTag(h_t2), .str_list);
        try expectEqual(@as(usize, 2), h_t2.str_list.len);
        js.freeDecoded(HeteroTarget, alloc, h_t2);

        // Buffer -> matches `.buf` before `opts`
        const hb = try js.Buffer.alloc(4);
        const h_tb = try js.fromJsRefAlloc(HeteroTarget, alloc, hb.toRef().cast(js.Any));
        hb.deinit();
        try expectEqual(std.meta.activeTag(h_tb), .buf);
        js.freeDecoded(HeteroTarget, alloc, h_tb);

        // Plain object `{ host: "example.com" }` -> matches `.opts`
        const ho_ref = try js.toJsRef(HostOpts, .{ .host = "example.com" });
        const h_to = try js.fromJsRefAlloc(HeteroTarget, alloc, ho_ref);
        ho_ref.deinit();
        try expectEqual(std.meta.activeTag(h_to), .opts);
        try std.testing.expectEqualStrings("example.com", h_to.opts.host);
        js.freeDecoded(HeteroTarget, alloc, h_to);

        // 8. M3.3a: Callback `ref_codec`, `pass_this` flag, runtime `tryInitFnPtr`, and `toJsRef` on `Closure`
        const MockHandle = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{ .is_handle = true };
        };
        const CbState = struct {
            seen_len: usize = 0,
            had_opt: bool = false,

            fn onData(self: *@This(), h: MockHandle, opt_tag: ?[]const u8) !MockHandle {
                _ = h;
                if (opt_tag) |t| {
                    self.seen_len += t.len;
                    self.had_opt = true;
                } else {
                    self.had_opt = false;
                }
                const out_rec = try js.Record([]const u8, js.Ref(js.Any)).init();
                return .{ .ref = .{ .handle = out_rec.handle } };
            }
        };
        var cb_state: CbState = .{};
        var typed_cl = try js.ClosureWithThis(*CbState, fn (*CbState, MockHandle, ?[]const u8) anyerror!MockHandle).tryInit(&cb_state, CbState.onData);
        defer typed_cl.deinit();

        // `toJsRef` on Closure clones its underlying Function handle cleanly
        const cl_ref = try js.toJsRef(@TypeOf(typed_cl), typed_cl);
        cl_ref.deinit();
        const cl_ptr_ref = try js.toJsRef(*const @TypeOf(typed_cl), &typed_cl);
        cl_ptr_ref.deinit();

        // Invoke underlying trampoline directly with a handle + omitted optional (`undefined`) and verify 0 handle leaks!
        const CbBackend = js.CallbackWithOptions(fn (MockHandle, ?[]const u8) MockHandle, .{ .pass_this = true, .ref_codec = true });
        try expectEqual(@as(u32, 4 | 8), @as(u32, @bitCast(js.CallbackFlags{ .pass_this = true, .ref_codec = true })));
        var backend_cb = try CbBackend.tryInit(&cb_state, CbState.onData);
        defer backend_cb.deinit();

        const WireArgs = arg_struct.ArgStruct(fn (js.Ref(js.Any), js.Ref(js.Any)) js.Ref(js.Any));
        const in_obj = try js.Record([]const u8, js.Ref(js.Any)).init();
        var wire_frame: WireArgs = .{
            .retval = js.Ref(js.Any).@"undefined",
            .@"0" = try (@as(js.Ref(js.Any), .{ .handle = in_obj.handle })).tryClone(),
            .@"1" = js.Ref(js.Any).@"undefined",
        };
        const resolved_slot = js.CallbackRegistry.resolve(backend_cb.id).?;
        try resolved_slot.entry.invoker.?(resolved_slot.entry.ctx_ptr, @ptrCast(&wire_frame));
        try expect(!cb_state.had_opt);
        wire_frame.retval.deinit();

        const tag_str = try js.String.fromSlice("chunk-42");
        wire_frame = .{
            .retval = js.Ref(js.Any).@"undefined",
            .@"0" = .{ .handle = in_obj.handle },
            .@"1" = tag_str.toRef(),
        };
        try resolved_slot.entry.invoker.?(resolved_slot.entry.ctx_ptr, @ptrCast(&wire_frame));
        try expect(cb_state.had_opt);
        try expectEqual(@as(usize, 8), cb_state.seen_len);
        wire_frame.retval.deinit();

        // Runtime `*const fn` pointer callback via `tryInitFnPtr` + passthrough aliased handle return!
        const RtFns = struct {
            fn mulTwo(x: f64) f64 {
                return x * 2.0;
            }
            fn echoHandle(h: MockHandle) MockHandle {
                return h;
            }
        };
        var rt_fn_ptr: *const fn (f64) f64 = &RtFns.mulTwo;
        _ = &rt_fn_ptr;
        var ptr_cb = try js.CallbackWithOptions(fn (f64) f64, .{ .ref_codec = true }).tryInitFnPtr(rt_fn_ptr);
        const PtrWireArgs = arg_struct.ArgStruct(fn (js.Ref(js.Any)) js.Ref(js.Any));
        const num_in = try js.toJsRef(f64, 21.0);
        var ptr_frame: PtrWireArgs = .{
            .retval = js.Ref(js.Any).@"undefined",
            .@"0" = num_in,
        };
        const ptr_slot = js.CallbackRegistry.resolve(ptr_cb.id).?;
        try ptr_slot.entry.invoker.?(ptr_slot.entry.ctx_ptr, @ptrCast(&ptr_frame));
        try expectEqual(@as(f64, 42.0), try js.fromJsRef(f64, ptr_frame.retval));
        ptr_frame.retval.deinit();
        ptr_cb.deinit();

        var echo_cb = try js.CallbackWithOptions(fn (MockHandle) MockHandle, .{ .ref_codec = true }).tryInitFn(RtFns.echoHandle);
        const echo_in = try js.Record([]const u8, js.Ref(js.Any)).init();
        var echo_frame: PtrWireArgs = .{
            .retval = js.Ref(js.Any).@"undefined",
            .@"0" = .{ .handle = echo_in.handle },
        };
        const echo_slot = js.CallbackRegistry.resolve(echo_cb.id).?;
        try echo_slot.entry.invoker.?(echo_slot.entry.ctx_ptr, @ptrCast(&echo_frame));
        try expect(!echo_frame.retval.isUndefined());
        echo_frame.retval.deinit();
        echo_cb.deinit();

        // 9. M3.3b: Comptime utility type transformers (`Partial`, `Required`, `Readonly`, `Pick`, `Omit`,
        //    enum-keyed `Record`, `NonNullable`, `Awaited`, `KeyOf`, `IndexAccess`) + wire metadata preservation
        const PlainCfg = struct {
            host: []const u8,
            port: i32,
            tls: ?bool = null,
        };
        const PickedPlain = js.Pick(PlainCfg, &.{ "host", "port" });
        try expectEqual(@as(usize, 2), @typeInfo(PickedPlain).@"struct".field_names.len);
        const OmittedPlain = js.Omit(PlainCfg, .tls);
        try expectEqual(@as(usize, 2), @typeInfo(OmittedPlain).@"struct".field_names.len);
        const PartialPlain = js.Partial(PlainCfg);
        const pp_val: PartialPlain = .{ .port = 8080 };
        try expectEqual(@as(?[]const u8, null), pp_val.host);
        try expectEqual(@as(?i32, 8080), pp_val.port);
        const ReqPlain = js.Required(PlainCfg);
        const rp_val: ReqPlain = .{ .host = "localhost", .port = 443, .tls = true };
        try expect(rp_val.tls);
        try expect(js.Readonly([]u8) == []const u8);
        try expect(js.NonNullable(?js.Nullable(i32)) == i32);
        try expect(js.Awaited(js.Promise(js.Promise([]const u8))) == []const u8);
        try expect(js.Awaited(i32) == i32);
        try expect(js.IndexAccess([]const []const u8, f64) == []const u8);
        try expect(js.IndexAccess(PlainCfg, "port") == i32);
        try expect(js.IndexAccess(PlainCfg, .host) == []const u8);

        const PlainKey = js.KeyOf(PlainCfg);
        const pk_ref = try js.toJsRef(PlainKey, .port);
        try expectEqual(PlainKey.port, try js.fromJsRefAlloc(PlainKey, alloc, pk_ref));
        pk_ref.deinit();
        const PlainRec = js.Record(PlainKey, ?i32);
        const pr_val: PlainRec = .{ .host = null, .port = 8080, .tls = null };
        try expectEqual(@as(?i32, null), pr_val.host);
        try expectEqual(@as(?i32, 8080), pr_val.port);
        const PartialPlainRec = js.Partial(PlainRec);
        const p_pr_val: PartialPlainRec = .{ .port = 8080 };
        try expectEqual(@as(?i32, null), p_pr_val.host);
        try expectEqual(@as(?i32, 8080), p_pr_val.port);

        const RoleEnum = enum {
            admin,
            content_type,
            pub const zigar_js = .{
                .is_enum = true,
                .members = .{
                    .{ .tag = "admin", .js_name = "admin", .str_value = "admin" },
                    .{ .tag = "content_type", .js_name = "content-type", .str_value = "content-type" },
                },
            };
        };
        const RoleFlags = js.Record(RoleEnum, bool);
        const rf_in: RoleFlags = .{ .admin = true, .content_type = false };
        const rf_ref = try js.toJsRef(RoleFlags, rf_in);
        const rf_raw = js.Record([]const u8, js.Ref(js.Any)).fromRef(rf_ref);
        try expect(try rf_raw.has("content-type"));
        try expect(!try rf_raw.has("content_type"));
        const rf_out = try js.fromJsRefAlloc(RoleFlags, alloc, rf_ref);
        rf_ref.deinit();
        try expect(rf_out.admin);
        try expect(!rf_out.content_type);

        // Wire-renamed struct (`max_retries` <-> `"maxRetries"`) through `Partial`, `Pick`, `Omit`, `Required`, `KeyOf`
        const WireConfig = struct {
            host_name: []const u8,
            max_retries: f64,
            opt_mode: ?[]const u8 = null,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "host_name", .js_name = "hostName", .is_optional = false, .nullish = .none },
                    .{ .name = "max_retries", .js_name = "maxRetries", .is_optional = false, .nullish = .none },
                    .{ .name = "opt_mode", .js_name = "optMode", .is_optional = true, .nullish = .undefined_only },
                },
            };
        };
        try expect(js.IndexAccess(WireConfig, "maxRetries") == f64);
        const WireKey = js.KeyOf(WireConfig);
        const wk_ref = try js.toJsRef(WireKey, .maxRetries);
        try expectEqual(WireKey.maxRetries, try js.fromJsRefAlloc(WireKey, alloc, wk_ref));
        wk_ref.deinit();

        const PartialWire = js.Partial(WireConfig);
        const pw_ref = try js.toJsRef(PartialWire, .{ .max_retries = 3 });
        const pw_raw = js.Record([]const u8, js.Ref(js.Any)).fromRef(pw_ref);
        try expect(try pw_raw.has("maxRetries"));
        try expect(!try pw_raw.has("hostName"));
        try expect(!try pw_raw.has("__zigar_js_meta"));
        const pw_out = try js.fromJsRefAlloc(PartialWire, alloc, pw_ref);
        pw_ref.deinit();
        try expectEqual(@as(?[]const u8, null), pw_out.host_name);
        try expectEqual(@as(?f64, 3), pw_out.max_retries);
        js.freeDecoded(PartialWire, alloc, pw_out);

        const PickedWire = js.Pick(WireConfig, enum { hostName, optMode });
        const ReqPicked = js.Required(PickedWire);
        const rpw_ref = try js.toJsRef(ReqPicked, .{ .host_name = "db.internal", .opt_mode = "strict" });
        const rpw_out = try js.fromJsRefAlloc(ReqPicked, alloc, rpw_ref);
        rpw_ref.deinit();
        try std.testing.expectEqualStrings("db.internal", rpw_out.host_name);
        try std.testing.expectEqualStrings("strict", rpw_out.opt_mode);
        js.freeDecoded(ReqPicked, alloc, rpw_out);

        // Inference & comptime constraint verification (`InferJsType`, `InferSliceElem`, `InferOptionalChild`, `satisfiesTypeConstraint`)
        try expect(js.InferJsType(@TypeOf("hello")) == []const u8);
        try expect(js.InferJsType(@TypeOf(42)) == f64);
        try expect(js.InferJsType(@TypeOf(&[_]i32{ 1, 2 })) == []const i32);
        try expect(js.InferConstJsType(@TypeOf("hello")) == []const u8);
        try expect(js.InferConstJsType(@TypeOf(&[_]i32{ 1, 2 })) == [2]i32);
        try expect(!js.isConstArrayPtr(@TypeOf("hello")));
        try expect(js.isConstArrayPtr(@TypeOf(&[_]i32{ 1, 2 })));
        try expect(!js.isConstArrayPtr([2]i32));

        // Fixed-length `[N]Elem` tuple array JS round-trip (`const T` deduced arrays)
        const fixed_in: [2][]const u8 = .{ "alpha", "beta" };
        const fixed_ref = try js.toJsRef([2][]const u8, fixed_in);
        const fixed_out = try js.fromJsRefAlloc([2][]const u8, alloc, fixed_ref);
        fixed_ref.deinit();
        try std.testing.expectEqualStrings("alpha", fixed_out[0]);
        try std.testing.expectEqualStrings("beta", fixed_out[1]);
        js.freeDecoded([2][]const u8, alloc, fixed_out);

        const short_arr_ref = try js.toJsRef([]const []const u8, &.{"only-one"});
        try std.testing.expectError(error.TypeError, js.fromJsRefAlloc([2][]const u8, alloc, short_arr_ref));
        short_arr_ref.deinit();
        try expect(js.InferSliceElem([]const []const u8) == []const u8);
        try expect(js.InferSliceElem(@TypeOf(&[_]i32{ 10, 20 })) == i32);
        try expect(js.InferOptionalChild(?[]const u8) == []const u8);
        try expect(js.InferOptionalChild(@TypeOf("direct")) == []const u8);
        try expect(js.InferOptionalChild(@TypeOf(null)) == js.Ref(js.Any));

        const HasId = struct { id: f64, tag: ?[]const u8 = null };
        try expect(js.satisfiesTypeConstraint(struct { id: f64, extra: bool }, HasId, 0));
        try expect(js.satisfiesTypeConstraint(struct { id: i32 }, HasId, 0));
        try expect(!js.satisfiesTypeConstraint(struct { extra: bool }, HasId, 0));
        try expect(js.satisfiesTypeConstraint(enum { hostName, maxRetries }, js.KeyOf(WireConfig), 0));
        try expect(!js.satisfiesTypeConstraint(enum { missingKey }, js.KeyOf(WireConfig), 0));
        try expect(js.satisfiesTypeConstraint([]const u8, []const u8, 0));
        try expect(js.satisfiesTypeConstraint(js.String, []const u8, 0));
        try expect(!js.satisfiesTypeConstraint(f64, []const u8, 0));
        try expect(js.satisfiesTypeConstraint(HasId, js.Ref(js.Object), 0));
        try expect(!js.satisfiesTypeConstraint(f64, js.Ref(js.Object), 0));
        try expect(js.satisfiesTypeConstraint(HasId, js.Record([]const u8, js.Ref(js.Any)), 0));

        // Structural union-to-union & unit-literal constraint satisfaction (`(A | B) extends (A | B | C)`)
        const UnionAB1 = union(enum) { str: []const u8, item: HasId };
        const UnionAB2 = union(enum) { str: []const u8, item: HasId };
        const UnionBad = union(enum) { str: []const u8, flag: bool };
        try expect(js.satisfiesTypeConstraint(UnionAB1, UnionAB2, 0));
        try expect(!js.satisfiesTypeConstraint(UnionBad, UnionAB2, 0));

        const UnitConstraint = union(enum) {
            auto,
            code_200,
            obj: HasId,
            pub const zigar_js = .{
                .variants = .{
                    .{ .tag = "auto", .js_name = "auto", .is_unit_literal = true, .str_value = "auto" },
                    .{ .tag = "code_200", .js_name = "200", .is_unit_literal = true, .num_value = @as(f64, 200) },
                    .{ .tag = "obj", .js_name = "obj" },
                },
            };
        };
        const UnitSame = union(enum) {
            auto,
            code_200,
            pub const zigar_js = .{
                .variants = .{
                    .{ .tag = "auto", .js_name = "auto", .is_unit_literal = true, .str_value = "auto" },
                    .{ .tag = "code_200", .js_name = "200", .is_unit_literal = true, .num_value = @as(f64, 200) },
                },
            };
        };
        const UnitWrong = union(enum) {
            manual,
            pub const zigar_js = .{
                .variants = .{
                    .{ .tag = "manual", .js_name = "manual", .is_unit_literal = true, .str_value = "manual" },
                },
            };
        };
        try expect(js.satisfiesTypeConstraint(UnitSame, UnitConstraint, 0));
        try expect(!js.satisfiesTypeConstraint(UnitWrong, UnitConstraint, 0));
        try expect(js.satisfiesTypeConstraint(enum { auto }, UnitConstraint, 0));
        try expect(!js.satisfiesTypeConstraint(void, UnitConstraint, 0));

        // `Required(T)` preserves `| null` and `: T | undefined` while removing `?` optionality
        const NullishFields = struct {
            a: ?[]const u8,
            b: ?[]const u8 = null,
            c: ?[]const u8,
            d: ?[]const u8 = null,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "a", .js_name = "a", .is_optional = false, .nullish = .null_only },
                    .{ .name = "b", .js_name = "b", .is_optional = true, .nullish = .null_or_undefined },
                    .{ .name = "c", .js_name = "c", .is_optional = false, .nullish = .undefined_only },
                    .{ .name = "d", .js_name = "d", .is_optional = true, .nullish = .undefined_only },
                },
            };
        };
        const ReqNul = js.Required(NullishFields);
        try expect(@FieldType(ReqNul, "a") == ?[]const u8);
        try expect(@FieldType(ReqNul, "b") == ?[]const u8);
        try expect(@FieldType(ReqNul, "c") == ?[]const u8);
        try expect(@FieldType(ReqNul, "d") == []const u8);
        inline for (@typeInfo(ReqNul).@"struct".field_names, 0..) |fnm, fi| {
            if (comptime !isHiddenMetaField(fnm)) {
                try expect(@typeInfo(ReqNul).@"struct".field_attrs[fi].default_value_ptr == null);
            }
        }
        const req_nul_in: ReqNul = .{ .a = null, .b = null, .c = null, .d = "req" };
        const req_nul_ref = try js.toJsRef(ReqNul, req_nul_in);
        const prop_a = try js.getProp(js.CallError!js.Ref(js.Any), req_nul_ref, "a");
        const prop_b = try js.getProp(js.CallError!js.Ref(js.Any), req_nul_ref, "b");
        const prop_c = try js.getProp(js.CallError!js.Ref(js.Any), req_nul_ref, "c");
        try expect(prop_a.isNull() and !prop_a.isUndefined());
        try expect(prop_b.isNull() and !prop_b.isUndefined());
        try expect(prop_c.isUndefined() and !prop_c.isNull());
        prop_a.deinit();
        prop_b.deinit();
        prop_c.deinit();
        const req_nul_out = try js.fromJsRefAlloc(ReqNul, alloc, req_nul_ref);
        req_nul_ref.deinit();
        try expect(req_nul_out.a == null and req_nul_out.b == null and req_nul_out.c == null);
        try std.testing.expectEqualStrings("req", req_nul_out.d);
        js.freeDecoded(ReqNul, alloc, req_nul_out);

        // `EnumRecord(K, ?V)` keeps every key required and serializes `null` as explicit JS `null` (not omitted)
        const PlainNullableRec = js.EnumRecord(enum { a, b }, ?[]const u8);
        inline for (@typeInfo(PlainNullableRec).@"struct".field_names, 0..) |fnm, fi| {
            if (comptime !isHiddenMetaField(fnm)) {
                try expect(@typeInfo(PlainNullableRec).@"struct".field_attrs[fi].default_value_ptr == null);
            }
        }
        const rec_nul_in: PlainNullableRec = .{ .a = null, .b = "x" };
        const rec_nul_ref = try js.toJsRef(PlainNullableRec, rec_nul_in);
        const rec_prop_a = try js.getProp(js.CallError!js.Ref(js.Any), rec_nul_ref, "a");
        try expect(rec_prop_a.isNull() and !rec_prop_a.isUndefined());
        rec_prop_a.deinit();
        const rec_nul_out = try js.fromJsRefAlloc(PlainNullableRec, alloc, rec_nul_ref);
        rec_nul_ref.deinit();
        try expect(rec_nul_out.a == null);
        try std.testing.expectEqualStrings("x", rec_nul_out.b.?);
        js.freeDecoded(PlainNullableRec, alloc, rec_nul_out);

        // Numeric enum `Record<Dir, V>`, `Pick`, and `IndexAccess` use JS numeric runtime keys ("0", "1", "-1")
        const NumDir = enum(i32) {
            up = 0,
            down = 1,
            neg = -1,
            pub const zigar_js = .{
                .is_enum = true,
                .members = .{
                    .{ .tag = "up", .js_name = "Up", .num_value = @as(f64, 0) },
                    .{ .tag = "down", .js_name = "Down", .num_value = @as(f64, 1) },
                    .{ .tag = "neg", .js_name = "Neg", .num_value = @as(f64, -1) },
                },
            };
        };
        const NumDirRec = js.Record(NumDir, []const u8);
        try expect(@hasField(NumDirRec, "0") and @hasField(NumDirRec, "1") and @hasField(NumDirRec, "1_2"));
        const nd_in: NumDirRec = .{ .@"0" = "north", .@"1" = "south", .@"1_2" = "west" };
        const nd_ref = try js.toJsRef(NumDirRec, nd_in);
        const nd_p0 = try js.getProp(js.CallError!js.String, nd_ref, "0");
        const nd_p1 = try js.getProp(js.CallError!js.String, nd_ref, "1");
        const nd_pn = try js.getProp(js.CallError!js.String, nd_ref, "-1");
        const nd_s0 = try nd_p0.toSliceAlloc(alloc);
        defer alloc.free(nd_s0);
        const nd_s1 = try nd_p1.toSliceAlloc(alloc);
        defer alloc.free(nd_s1);
        const nd_sn = try nd_pn.toSliceAlloc(alloc);
        defer alloc.free(nd_sn);
        nd_p0.deinit();
        nd_p1.deinit();
        nd_pn.deinit();
        try std.testing.expectEqualStrings("north", nd_s0);
        try std.testing.expectEqualStrings("south", nd_s1);
        try std.testing.expectEqualStrings("west", nd_sn);
        const nd_out = try js.fromJsRefAlloc(NumDirRec, alloc, nd_ref);
        nd_ref.deinit();
        try std.testing.expectEqualStrings("north", nd_out.@"0");
        try std.testing.expectEqualStrings("south", nd_out.@"1");
        try std.testing.expectEqualStrings("west", nd_out.@"1_2");
        js.freeDecoded(NumDirRec, alloc, nd_out);
        try expect(js.IndexAccess(NumDirRec, NumDir) == []const u8);
        try expect(js.IndexAccess(NumDirRec, 0) == []const u8);
        try expect(js.IndexAccess(NumDirRec, NumDir.up) == []const u8);
        try expect(js.IndexAccess(NumDirRec, -1) == []const u8);
        const PickedNumDir = js.Pick(NumDirRec, enum(i32) {
            up = 0,
            pub const zigar_js = .{
                .is_enum = true,
                .members = .{.{ .tag = "up", .js_name = "Up", .num_value = @as(f64, 0) }},
            };
        });
        try expect(@hasField(PickedNumDir, "0") and !@hasField(PickedNumDir, "1"));

        // Wire-first disambiguation when snake-cased `"-1"` (`@"1"`) collides with `"1"` (`@"1_2"`)
        const SignedDistinct = struct {
            @"1": []const u8,
            @"1_2": f64,
            host: bool,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "1", .js_name = "-1", .is_optional = false, .nullish = .none },
                    .{ .name = "1_2", .js_name = "1", .is_optional = false, .nullish = .none },
                    .{ .name = "host", .js_name = "host", .is_optional = false, .nullish = .none },
                },
            };
        };
        try expect(js.IndexAccess(SignedDistinct, 1) == f64);
        try expect(js.IndexAccess(SignedDistinct, -1) == []const u8);
        const PickPosOne = js.Pick(SignedDistinct, 1);
        try expect(@hasField(PickPosOne, "1_2") and !@hasField(PickPosOne, "1"));
        const NumericIndexed = js.IndexAccess(SignedDistinct, f64);
        try expect(@typeInfo(NumericIndexed) == .@"union" and @typeInfo(NumericIndexed).@"union".field_types.len == 2);

        // Mixed unit-literal union key spec (`0 | "host"`) in `Pick` and `IndexAccess`
        const MixedKeyUnion = union(enum) {
            num_1,
            str_host,
            pub const zigar_js = .{
                .variants = .{
                    .{ .tag = "num_1", .js_name = "1", .is_unit_literal = true, .num_value = @as(f64, 1) },
                    .{ .tag = "str_host", .js_name = "host", .is_unit_literal = true, .str_value = "host" },
                },
            };
        };
        const PickMixed = js.Pick(SignedDistinct, MixedKeyUnion);
        try expect(@hasField(PickMixed, "1_2") and @hasField(PickMixed, "host") and !@hasField(PickMixed, "1"));

        // Homomorphic `MappedValues(T, V)` (`{ [P in keyof T]: V }`) preserves optionality and wire names
        const WireFlags = js.MappedValues(WireConfig, bool);
        try expect(@FieldType(WireFlags, "host_name") == bool);
        try expect(@FieldType(WireFlags, "max_retries") == bool);
        try expect(@FieldType(WireFlags, "opt_mode") == ?bool);
        const wf_ref = try js.toJsRef(WireFlags, .{ .host_name = true, .max_retries = false });
        const wf_raw = js.Record([]const u8, js.Ref(js.Any)).fromRef(wf_ref);
        try expect(try wf_raw.has("hostName"));
        try expect(try wf_raw.has("maxRetries"));
        try expect(!try wf_raw.has("optMode"));
        const wf_out = try js.fromJsRefAlloc(WireFlags, alloc, wf_ref);
        try expect(wf_out.host_name and !wf_out.max_retries and wf_out.opt_mode == null);
        // Whereas `Required(WireFlags)` (`{ [P in keyof T]-?: boolean }`) requires `optMode` (`error.TypeError` when omitted)
        const ReqWireFlags = js.Required(WireFlags);
        try expect(@FieldType(ReqWireFlags, "opt_mode") == bool);
        try std.testing.expectError(error.TypeError, js.fromJsRefAlloc(ReqWireFlags, alloc, wf_ref));
        wf_ref.deinit();

        const OptWireFlags = js.Partial(WireFlags);
        const owf_val: OptWireFlags = .{ .host_name = true };
        try expectEqual(@as(?bool, true), owf_val.host_name);
        try expectEqual(@as(?bool, null), owf_val.max_retries);

        const ReqNullableWire = js.Required(js.MappedValues(WireConfig, ?[]const u8));
        try expect(@FieldType(ReqNullableWire, "opt_mode") == ?[]const u8);
        inline for (@typeInfo(ReqNullableWire).@"struct".field_names, 0..) |fnm, fi| {
            if (comptime !isHiddenMetaField(fnm)) {
                try expect(@typeInfo(ReqNullableWire).@"struct".field_attrs[fi].default_value_ptr == null);
            }
        }
        const rnw_ref = try js.toJsRef(ReqNullableWire, .{ .host_name = "h", .max_retries = null, .opt_mode = null });
        const rnw_opt = try js.getProp(js.CallError!js.Ref(js.Any), rnw_ref, "optMode");
        try expect(rnw_opt.isNull() and !rnw_opt.isUndefined());
        rnw_opt.deinit();
        rnw_ref.deinit();

        // Homomorphic `MappedValues` on slices, fixed arrays, tuples, and primitives
        try expect(js.MappedValues([]const f64, bool) == []const bool);
        try expect(js.MappedValues([]f64, bool) == []bool);
        try expect(js.MappedValues([3]f64, bool) == [3]bool);
        try expect(js.MappedValues(struct { f64, []const u8 }, bool) == [2]bool);
        try expect(js.MappedValues([]const u8, bool) == []const u8);
        try expect(js.MappedValues(f64, bool) == f64);
        try expect(js.MappedValues(js.BigInt, bool) == js.BigInt);
        try expect(js.IndexAccess(js.Array(f64), 0) == f64);
        comptime js.checkTypeConstraint(js.BigInt, i64);

        // 10. M3.3c: Protocol wrappers (`Disposable`, `AsyncDisposable`, `Iterator`, `AsyncIterator`),
        //     `Awaited(?Promise(T))` / `Awaited(Nullable(Promise(T)))`, `PromiseAllResult`, and protocol constraints
        try expect(js.Awaited(?js.Promise(f64)) == ?f64);
        try expect(js.Awaited(js.Nullable(js.Promise([]const u8))) == js.Nullable([]const u8));
        try expect(js.Awaited(js.Promise(js.Promise(i32))) == i32);
        try expect(js.PromiseAllResult(struct { js.Promise(f64), js.Promise([]const u8) }) == struct { f64, []const u8 });
        try expect(js.PromiseAllResult([3]js.Promise(i32)) == [3]i32);
        try expect(js.PromiseAllResult([]const js.Promise(bool)) == []bool);

        const CustomDisp = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{ .is_handle = true, .has_dispose = true };
        };
        const CustomAsyncDisp = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{ .is_handle = true, .has_async_dispose = true };
        };
        const CustomIter = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{ .is_handle = true, .has_iterator = true, .iterator_elem = f64 };
        };
        const PlainHandleOnly = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{ .is_handle = true };
        };
        try expect(js.satisfiesTypeConstraint(js.Disposable, js.Disposable, 0));
        try expect(js.satisfiesTypeConstraint(CustomDisp, js.Disposable, 0));
        try expect(!js.satisfiesTypeConstraint(PlainHandleOnly, js.Disposable, 0));
        try expect(!js.satisfiesTypeConstraint(CustomDisp, js.AsyncDisposable, 0));
        try expect(js.satisfiesTypeConstraint(CustomAsyncDisp, js.AsyncDisposable, 0));
        try expect(js.satisfiesTypeConstraint([]const f64, js.Iterator(f64), 0));
        try expect(js.satisfiesTypeConstraint([2]f64, js.Iterator(f64), 0));
        try expect(js.satisfiesTypeConstraint(js.Set(f64), js.Iterator(f64), 0));
        try expect(js.satisfiesTypeConstraint(CustomIter, js.Iterator(f64), 0));
        try expect(!js.satisfiesTypeConstraint(CustomIter, js.Iterator([]const u8), 0));
        try expect(!js.satisfiesTypeConstraint(PlainHandleOnly, js.Iterator(f64), 0));

        // Open generic intersection (`Intersect`), numeric enum value-subset constraint, and `void` optional default
        const BaseSnapParams = struct {
            file_system: ?[]const u8 = null,
            open_projects: ?[]const []const u8 = null,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "file_system", .js_name = "fileSystem", .is_optional = true, .nullish = .undefined_only },
                    .{ .name = "open_projects", .js_name = "openProjects", .is_optional = true, .nullish = .undefined_only },
                },
            };
        };
        const TightenedSnapParams = struct {
            file_system: []const u8,
            create_programs: []const u8,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "file_system", .js_name = "fileSystem", .is_optional = false, .nullish = .none },
                    .{ .name = "create_programs", .js_name = "createPrograms", .is_optional = false, .nullish = .none },
                },
            };
        };
        const MergedVoid = js.Intersect(.{ BaseSnapParams, void });
        try expect(@hasField(MergedVoid, "file_system") and @hasField(MergedVoid, "open_projects"));
        const MergedTight = js.Intersect(.{ BaseSnapParams, TightenedSnapParams });
        try expect(@FieldType(MergedTight, "file_system") == []const u8);
        try expect(@FieldType(MergedTight, "create_programs") == []const u8);
        const mt_ref = try js.toJsRef(MergedTight, .{
            .file_system = "memfs",
            .open_projects = &.{"/tsconfig.json"},
            .create_programs = "prog-1",
        });
        const mt_dec = try js.fromJsRefAlloc(MergedTight, alloc, mt_ref);
        mt_ref.deinit();
        try std.testing.expectEqualStrings("memfs", mt_dec.file_system);
        try std.testing.expectEqualStrings("prog-1", mt_dec.create_programs);
        try expectEqual(@as(usize, 1), mt_dec.open_projects.?.len);
        js.freeDecoded(MergedTight, alloc, mt_dec);

        // Handle + plain-struct intersection (`Sync & { gen: Gen }`) and branded primitives
        try expect(js.Intersect(.{ []const u8, struct { __path_brand: js.Ref(js.Any) = .{ .handle = 0 } } }) == []const u8);
        try expect(js.Intersect(.{ struct { __num_brand: js.Ref(js.Any) = .{ .handle = 0 } }, f64 }) == f64);
        try expect(js.Intersect(.{ []const u8, f64 }) == noreturn);

        const GenHandle = struct {
            ref: js.Ref(js.Any) = .{ .handle = 0 },
            pub const zigar_js = .{
                .js_name = "Gen",
                .is_handle = true,
                .is_class = false,
                .ref_field = "ref",
                .required_props = &[_][]const u8{"active"},
                .fields = .{
                    .{ .name = "active", .js_name = "active" },
                },
            };
            pub fn deinit(self: @This()) void {
                self.ref.deinit();
            }
        };
        const SyncHandle = struct {
            ref: js.Ref(js.Any) = .{ .handle = 0 },
            pub const zigar_js = .{
                .js_name = "Sync",
                .is_handle = true,
                .is_class = false,
                .ref_field = "ref",
                .required_props = &[_][]const u8{"version"},
                .fields = .{
                    .{ .name = "version", .js_name = "version" },
                },
            };
            pub fn deinit(self: @This()) void {
                self.ref.deinit();
            }
            pub fn getVersionAlloc(self: @This(), a: std.mem.Allocator) js.CallError![]const u8 {
                const raw_v = try js.getProp(js.CallError!js.Ref(js.Any), self.ref, "version");
                defer raw_v.deinit();
                return js.fromJsRefAlloc([]const u8, a, raw_v);
            }
        };
        const GenOverlay = struct {
            gen: GenHandle,
            tag_name: ?[]const u8 = null,
            pub const zigar_js = .{
                .fields = .{
                    .{ .name = "gen", .js_name = "gen", .is_optional = false, .nullish = .none },
                    .{ .name = "tag_name", .js_name = "tagName", .is_optional = true, .nullish = .undefined_only },
                },
            };
        };
        const SyncWithGen = js.Intersect(.{ SyncHandle, GenOverlay });
        const GenWithSync = js.Intersect(.{ GenOverlay, SyncHandle });
        const CbArm = js.Callback(fn (f64) f64);
        const CbWithGen = js.Intersect(.{ CbArm, GenOverlay });
        try expect(CbWithGen.is_zigar_intersect_handle);
        try expect(CbWithGen.FieldType("gen") == GenHandle);
        try expect((CbWithGen{ .ref = .{ .handle = 42 } }).as(CbArm).id == 0);
        try expect((CbWithGen{ .ref = .{ .handle = 42 } }).as(CbArm).func.handle == 42);
        try expect(SyncWithGen.zigar_js.is_handle);
        try expect(GenWithSync.zigar_js.is_handle);
        try expect(SyncWithGen.FieldType("gen") == GenHandle);
        try expect(GenWithSync.FieldType("gen") == GenHandle);
        try expect(SyncWithGen.FieldType("tagName") == ?[]const u8);
        try expect(js.IndexAccess(SyncWithGen, "gen") == GenHandle);
        try expect(js.satisfiesTypeConstraint(SyncWithGen, SyncHandle, 0));
        try expect(js.satisfiesTypeConstraint(SyncWithGen, GenOverlay, 0));
        try expect(js.satisfiesTypeConstraint(enum { gen, version }, js.KeyOf(SyncWithGen), 0));

        const bad_missing_gen = try js.Record([]const u8, js.Ref(js.Any)).init();
        {
            const ver_ref = try js.toJsRef([]const u8, "7.1.0");
            defer ver_ref.deinit();
            try bad_missing_gen.set("version", ver_ref);
        }
        try std.testing.expectError(error.TypeError, js.fromJsRefAlloc(SyncWithGen, alloc, bad_missing_gen));
        bad_missing_gen.deinit();

        const raw_gen_obj = try js.Record([]const u8, js.Ref(js.Any)).init();
        {
            const act_ref = try js.toJsRef(bool, true);
            defer act_ref.deinit();
            try raw_gen_obj.set("active", act_ref);
        }
        const raw_sync_gen = try js.Record([]const u8, js.Ref(js.Any)).init();
        {
            const ver_ref = try js.toJsRef([]const u8, "7.1.0-dev");
            defer ver_ref.deinit();
            try raw_sync_gen.set("version", ver_ref);
            try raw_sync_gen.set("gen", .{ .handle = raw_gen_obj.handle });
        }
        raw_gen_obj.deinit();

        const swg = try js.fromJsRefAlloc(SyncWithGen, alloc, raw_sync_gen);
        raw_sync_gen.deinit();
        const sync_borrowed = swg.as(SyncHandle);
        const ver_str = try sync_borrowed.getVersionAlloc(alloc);
        try std.testing.expectEqualStrings("7.1.0-dev", ver_str);
        alloc.free(ver_str);

        const sync_cloned = try swg.cloneAs(SyncHandle);
        sync_cloned.deinit();

        const gen_h = try swg.get("gen");
        {
            const act_raw = try js.getProp(js.CallError!js.Ref(js.Any), gen_h.ref, "active");
            defer act_raw.deinit();
            try expect(try js.fromJsRef(bool, act_raw));
        }
        gen_h.deinit();

        try swg.set("tag_name", "alpha");
        const tag_dec = try swg.getAlloc(alloc, "tagName");
        try std.testing.expectEqualStrings("alpha", tag_dec.?);
        alloc.free(tag_dec.?);

        const projected = try swg.projectAlloc(GenOverlay, alloc);
        projected.gen.deinit();
        if (projected.tag_name) |tn| alloc.free(tn);

        swg.deinit();

        const SuperKind = enum(i64) {
            ident = 80,
            plus_tok = 40,
            minus_tok = 41,
            pub fn toInt(self: @This()) i64 {
                return @intFromEnum(self);
            }
            pub fn fromInt(v: i64) ?@This() {
                return switch (v) {
                    80 => .ident,
                    40 => .plus_tok,
                    41 => .minus_tok,
                    else => null,
                };
            }
            pub const zigar_js = .{ .is_const = false };
        };
        const SubKindOk = enum(i64) {
            plus_token = 40,
            minus_token = 41,
            pub fn toInt(self: @This()) i64 {
                return @intFromEnum(self);
            }
            pub fn fromInt(v: i64) ?@This() {
                return switch (v) {
                    40 => .plus_token,
                    41 => .minus_token,
                    else => null,
                };
            }
            pub const zigar_js = .{ .is_const = false };
        };
        const SubKindBad = enum(i64) {
            plus_token = 40,
            star_token = 42,
            pub fn toInt(self: @This()) i64 {
                return @intFromEnum(self);
            }
            pub fn fromInt(v: i64) ?@This() {
                return switch (v) {
                    40 => .plus_token,
                    42 => .star_token,
                    else => null,
                };
            }
            pub const zigar_js = .{ .is_const = false };
        };
        try expect(js.satisfiesTypeConstraint(SubKindOk, SuperKind, 0));
        try expect(!js.satisfiesTypeConstraint(SubKindBad, SuperKind, 0));
        try expect(js.satisfiesTypeConstraint(void, ?[]const u8, 0));
        try expect(!js.satisfiesTypeConstraint(i32, ?[]const u8, 0));
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}

test "Js(#54): stateless callbacks, release-only Disposable.deinit, cyclic graph guard, and union JsException propagation" {
    const Audit54MockHost = struct {
        var next_slot: u32 = first_dynamic_slot;
        var active_handles: u32 = 0;
        var active_stateful_callbacks: u32 = 0;
        var dispose_calls: u32 = 0;
        var async_dispose_calls: u32 = 0;
        var iter_return_calls: u32 = 0;
        var equal_calls: u32 = 0;
        var stored_trampoline: usize = 0;
        var last_cb_flags: u32 = 0;
        var last_cb_id: u32 = 0;
        var captured_err: u32 = no_captured_error_handle;

        // Object identity tags in low 16 bits:
        // 0x10 = 1-cycle Node (`next` -> 0x10)
        // 0x11 / 0x12 = 2-cycle Nodes (`0x11.next = 0x12`, `0x12.next = 0x11`)
        // 0x20 = DAG Root (`left` = 0x21, `right` = 0x21)
        // 0x21 = DAG Leaf (`next = null`, `left = null`, `right = null`)
        // 0x30 = Throwing getter object (`boom` throws `error.JsException`)
        // 0x40 = Disposable/Intersect/Iterator object
        // 0x50 = 50-element JS Array of non-recursive `Point` objects (`0x2000..0x2031`)
        // 0x1000..0x1077 = 120-node acyclic `LinkedNode` chain (`0x1077.next = null`)
        // 0x3000..0x3031 = numeric values `0..49`
        fn allocObj(id_tag: u16) u32 {
            active_handles += 1;
            const slot = next_slot;
            next_slot += 1;
            return (slot << 16) | @as(u32, id_tag);
        }

        fn tagOf(h: u32) u16 {
            return @truncate(h & 0xFFFF);
        }

        pub fn releaseJsValue(h: u32) void {
            if (h >= first_dynamic_slot) {
                std.debug.assert(active_handles > 0);
                active_handles -= 1;
            }
        }

        pub fn cloneJsValue(h: u32) u32 {
            if (h <= reserved_global_this_handle) return h;
            return allocObj(tagOf(h));
        }

        pub fn equalJsValue(a: u32, b: u32) bool {
            equal_calls += 1;
            if (a == b) return true;
            if (a <= reserved_global_this_handle or b <= reserved_global_this_handle) return false;
            return tagOf(a) == tagOf(b);
        }

        pub fn getJsValueCount() u32 {
            return active_handles;
        }

        pub fn typeofJsValue(h: u32) JsType {
            if (h == reserved_undefined_handle) return .undefined;
            if (h == reserved_null_handle) return .object;
            const tag = tagOf(h);
            if (tag == 0x99) return .function;
            if (tag >= 0x3000 and tag < 0x3100) return .number;
            return .object;
        }

        pub fn tryControlLastJsError(action: u32) Error!u32 {
            switch (action) {
                0 => return captured_err,
                1 => {
                    const out = captured_err;
                    captured_err = no_captured_error_handle;
                    return out;
                },
                else => {
                    if (captured_err >= first_dynamic_slot) releaseJsValue(captured_err);
                    captured_err = no_captured_error_handle;
                    return no_captured_error_handle;
                },
            }
        }

        pub fn createZigCallback(desc_ptr: *const anyopaque, id: u32) Error!u32 {
            const desc: *const CallbackDescriptor = @ptrCast(@alignCast(desc_ptr));
            stored_trampoline = desc.trampoline_thunk;
            last_cb_flags = desc.flags;
            last_cb_id = id;
            const is_stateless = (desc.flags & @as(u32, @bitCast(CallbackFlags{ .stateless = true }))) != 0;
            if (!is_stateless) active_stateful_callbacks += 1;
            return allocObj(0x99);
        }

        pub fn releaseZigCallback(_: u32) void {
            std.debug.assert(active_stateful_callbacks > 0);
            std.debug.assert(active_handles > 0);
            active_stateful_callbacks -= 1;
            active_handles -= 1;
        }

        pub fn tryDisposeJsValue(handle: u32) Error!void {
            defer releaseJsValue(handle);
            dispose_calls += 1;
        }

        pub fn disposeJsValue(handle: u32) void {
            tryDisposeJsValue(handle) catch {};
        }

        pub fn tryAsyncDisposeJsValue(handle: u32) Error!void {
            defer releaseJsValue(handle);
            async_dispose_calls += 1;
        }

        pub fn asyncDisposeJsValue(handle: u32) void {
            tryAsyncDisposeJsValue(handle) catch {};
        }

        pub fn awaitJsPromise(
            _: u32,
            mode_raw: u32,
            _: *const anyopaque,
            arg_ptr: *anyopaque,
            _: usize,
            _: usize,
        ) E {
            const mode: AwaitMode = @enumFromInt(mode_raw);
            if (mode == .async_iterator_return) {
                iter_return_calls += 1;
                const Frame = arg_struct.ArgStruct(fn () Error!void);
                const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                frame.retval = {};
                return .SUCCESS;
            }
            return .FAULT;
        }

        pub fn invokeJsHostOp(desc_ptr: *const anyopaque, arg_ptr: *anyopaque, _: usize) E {
            const J = Js(@This());
            const desc: *const HostOpDescriptor = @ptrCast(@alignCast(desc_ptr));
            const key = if (desc.key_ptr) |p| p[0..desc.key_len] else "";
            const op: HostOp = @enumFromInt(desc.op);
            switch (op) {
                .binary_info => {
                    const sub: BinaryInfoKind = @enumFromInt(desc.flags);
                    switch (sub) {
                        .is_array => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!bool);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = (tagOf(frame.@"0".handle) == 0x50);
                            return .SUCCESS;
                        },
                        else => return .FAULT,
                    }
                },
                .collection_op => {
                    const sub: CollectionSubOp = @enumFromInt(desc.flags);
                    switch (sub) {
                        .array_len => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = if (tagOf(frame.@"0".handle) == 0x50) 50 else 0;
                            return .SUCCESS;
                        },
                        .array_get => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize) Error!J.Ref(Any));
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = .{ .handle = allocObj(@intCast(0x2000 + frame.@"1")) };
                            return .SUCCESS;
                        },
                        .value_identity => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) CallError!f64);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const tag = tagOf(frame.@"0".handle);
                            frame.retval = @floatFromInt(tag - 0x3000);
                            return .SUCCESS;
                        },
                        else => return .FAULT,
                    }
                },
                .get_prop => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Object)) Error!J.Ref(Any));
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const tag = tagOf(frame.@"0".handle);
                    if (tag == 0x10) {
                        if (std.mem.eql(u8, key, "next")) {
                            // Distinct handle slot pointing to SAME underlying JS object (0x10)!
                            frame.retval = .{ .handle = allocObj(0x10) };
                            return .SUCCESS;
                        }
                    } else if (tag == 0x11) {
                        if (std.mem.eql(u8, key, "next")) {
                            frame.retval = .{ .handle = allocObj(0x12) };
                            return .SUCCESS;
                        }
                    } else if (tag == 0x12) {
                        if (std.mem.eql(u8, key, "next")) {
                            frame.retval = .{ .handle = allocObj(0x11) };
                            return .SUCCESS;
                        }
                    } else if (tag >= 0x1000 and tag <= 0x1077) {
                        if (std.mem.eql(u8, key, "next")) {
                            frame.retval = if (tag < 0x1077)
                                .{ .handle = allocObj(tag + 1) }
                            else
                                J.Ref(Any).@"null";
                            return .SUCCESS;
                        }
                    } else if (tag >= 0x2000 and tag < 0x2050) {
                        if (std.mem.eql(u8, key, "x")) {
                            frame.retval = .{ .handle = allocObj(0x3000 + (tag - 0x2000)) };
                            return .SUCCESS;
                        }
                    } else if (tag == 0x20) {
                        if (std.mem.eql(u8, key, "left") or std.mem.eql(u8, key, "right")) {
                            frame.retval = .{ .handle = allocObj(0x21) };
                            return .SUCCESS;
                        }
                    } else if (tag == 0x21) {
                        if (std.mem.eql(u8, key, "next") or std.mem.eql(u8, key, "left") or std.mem.eql(u8, key, "right")) {
                            frame.retval = J.Ref(Any).@"null";
                            return .SUCCESS;
                        }
                    } else if (tag == 0x30) {
                        captured_err = allocObj(0xEE);
                        frame.retval = error.JsException;
                        return .SUCCESS;
                    }
                    frame.retval = J.Ref(Any).@"undefined";
                    return .SUCCESS;
                },
                .iterator_return => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!void);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    iter_return_calls += 1;
                    frame.retval = {};
                    return .SUCCESS;
                },
                else => return .FAULT,
            }
        }
    };

    const js = Js(Audit54MockHost);
    const TrampolineThunk = *const fn (*const anyopaque, *anyopaque) anyerror!void;

    // 1. H1: Stateless bare functions & runtime `*const fn` pointers remain callable after `fn_ref.deinit()`
    // with ZERO active CallbackRegistry slots and ZERO active Zig handles!
    {
        const Handlers = struct {
            fn triple(x: i32) i32 {
                return x * 3;
            }
            fn quad(x: i32) i32 {
                return x * 4;
            }
        };
        const CbReg = js.CallbackWithOptions(fn (i32) i32, .{ .ref_codec = false });
        const CbArgs = arg_struct.ArgStruct(fn (i32) i32);

        const fn_ref_comptime = try CbReg.tryStatelessFn(Handlers.triple);
        try expectEqual(@as(u32, @bitCast(CallbackFlags{ .stateless = true })), Audit54MockHost.last_cb_flags);
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
        try expectEqual(@as(u32, 0), Audit54MockHost.active_stateful_callbacks);
        const comptime_thunk: TrampolineThunk = @ptrFromInt(Audit54MockHost.stored_trampoline);
        const comptime_id = Audit54MockHost.last_cb_id;
        // Release temporary Zig handle immediately (simulating ScopedCallback.push -> defer fn_ref.deinit())!
        fn_ref_comptime.deinit();
        try expectEqual(@as(u32, 0), js.activeHandleCount());
        // Simulate async JS callback firing AFTER `fn_ref.deinit()`!
        var frame1: CbArgs = .{ .retval = 0, .@"0" = 14 };
        try comptime_thunk(@ptrFromInt(comptime_id), @ptrCast(&frame1));
        try expectEqual(@as(i32, 42), frame1.retval);

        // Runtime `*const fn` pointer:
        var rt_ptr: *const fn (i32) i32 = &Handlers.quad;
        _ = &rt_ptr;
        const fn_ref_rt = try CbReg.tryStatelessFnPtr(rt_ptr);
        const rt_thunk: TrampolineThunk = @ptrFromInt(Audit54MockHost.stored_trampoline);
        const rt_id = Audit54MockHost.last_cb_id;
        fn_ref_rt.deinit();
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
        try expectEqual(@as(u32, 0), js.activeHandleCount());
        var frame2: CbArgs = .{ .retval = 0, .@"0" = 11 };
        try rt_thunk(@ptrFromInt(rt_id), @ptrCast(&frame2));
        try expectEqual(@as(i32, 44), frame2.retval);

        // Passing the exact same runtime `*const fn` pointer yields the exact same deterministic stateless ID!
        const fn_ref_rt2 = try CbReg.tryStatelessFnPtr(rt_ptr);
        try expectEqual(rt_id, Audit54MockHost.last_cb_id);
        fn_ref_rt2.deinit();

        // `persistentClosure` explicit helper (`ref_codec = true` matches ts-zigar callback wire ABI):
        const Acc = struct {
            sum: u32 = 0,
            fn onVal(self: *@This(), v: js.Ref(js.Any)) void {
                self.sum += Audit54MockHost.tagOf(v.handle);
            }
        };
        var acc: Acc = .{};
        var pcl = try js.persistentClosure(&acc, Acc.onVal);
        try expectEqual(@as(u32, 1), js.activeCallbackCount());
        const pcl_thunk: TrampolineThunk = @ptrFromInt(Audit54MockHost.stored_trampoline);
        const RefArgs = arg_struct.ArgStruct(fn (js.Ref(js.Any)) js.CallError!void);
        const arg_h = Audit54MockHost.allocObj(0x09);
        var frame3: RefArgs = .{ .retval = {}, .@"0" = .{ .handle = arg_h } };
        try pcl_thunk(@ptrFromInt(pcl.id), @ptrCast(&frame3));
        try expectEqual(@as(u32, 9), acc.sum);
        pcl.deinit();
        try expectEqual(@as(u32, 0), js.activeCallbackCount());
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 2. H2 & M4: `Disposable.deinit()` is release-only; `Disposable.dispose()`, `Intersect.dispose()`,
    // and `Iterator.closeAndDeinit()` explicitly invoke protocol cleanup AND release the handle!
    {
        const d_non_disposing: js.Disposable = .{ .handle = Audit54MockHost.allocObj(0x40) };
        d_non_disposing.deinit();
        try expectEqual(@as(u32, 0), Audit54MockHost.dispose_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());

        const d_disposing: js.Disposable = .{ .handle = Audit54MockHost.allocObj(0x40) };
        d_disposing.dispose();
        try expectEqual(@as(u32, 1), Audit54MockHost.dispose_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());

        const PartA = struct {
            ref: js.Ref(js.Object),
            pub const zigar_js = .{ .is_handle = true };
        };
        const Inter = js.Intersect(.{ PartA, js.Disposable });
        const inter_val: Inter = .{ .ref = .{ .handle = Audit54MockHost.allocObj(0x40) } };
        inter_val.dispose();
        try expectEqual(@as(u32, 2), Audit54MockHost.dispose_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());

        const inter_async: Inter = .{ .ref = .{ .handle = Audit54MockHost.allocObj(0x40) } };
        inter_async.asyncDispose();
        try expectEqual(@as(u32, 1), Audit54MockHost.async_dispose_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());

        const it: js.Iterator(i32) = .{ .handle = Audit54MockHost.allocObj(0x40) };
        it.closeAndDeinit();
        try expectEqual(@as(u32, 1), Audit54MockHost.iter_return_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());

        const ait: js.AsyncIterator(i32) = .{ .handle = Audit54MockHost.allocObj(0x40) };
        ait.closeAndDeinit();
        try expectEqual(@as(u32, 2), Audit54MockHost.iter_return_calls);
        try expectEqual(@as(u32, 0), js.activeHandleCount());
    }

    // 3. M1: 1-cycles & 2-cycles fail with `error.Overflow` and zero leaks; recursive binary-tree DAG sharing
    // (`{ left: shared, right: shared }`) and 120-node acyclic `LinkedNode` lists decode in linear O(N) `equalJsValue`
    // calls; and non-recursive `[]const Point` slices incur ZERO `equalJsValue` host round-trips!
    {
        const Node = struct {
            next: ?*const @This() = null,
        };
        const Tree = struct {
            left: ?*const @This() = null,
            right: ?*const @This() = null,
        };
        const Point = struct {
            x: i32,
        };

        const cyc_raw: js.Ref(js.Any) = .{ .handle = Audit54MockHost.allocObj(0x10) };
        defer cyc_raw.deinit();
        try std.testing.expectError(error.Overflow, js.fromJsRefAlloc(Node, std.testing.allocator, cyc_raw));

        const cyc2_raw: js.Ref(js.Any) = .{ .handle = Audit54MockHost.allocObj(0x11) };
        defer cyc2_raw.deinit();
        try std.testing.expectError(error.Overflow, js.fromJsRefAlloc(Node, std.testing.allocator, cyc2_raw));

        const dag_raw: js.Ref(js.Any) = .{ .handle = Audit54MockHost.allocObj(0x20) };
        defer dag_raw.deinit();
        const dag = try js.fromJsRefAlloc(Tree, std.testing.allocator, dag_raw);
        defer js.freeDecoded(Tree, std.testing.allocator, dag);
        try expect(dag.left != null and dag.left.?.left == null);
        try expect(dag.right != null and dag.right.?.right == null);

        // 120-node acyclic linked list (`0x1000..0x1077`): previously failed at 22 nodes with depth=64
        // and cost 7,140 quadratic `equalJsValue` calls; now succeeds with exactly 119 linear `equalJsValue` calls!
        Audit54MockHost.equal_calls = 0;
        const deep_raw: js.Ref(js.Any) = .{ .handle = Audit54MockHost.allocObj(0x1000) };
        defer deep_raw.deinit();
        const deep_list = try js.fromJsRefAlloc(Node, std.testing.allocator, deep_raw);
        defer js.freeDecoded(Node, std.testing.allocator, deep_list);
        var count: usize = 1;
        var cur = deep_list.next;
        while (cur) |n| : (cur = n.next) count += 1;
        try expectEqual(@as(usize, 120), count);
        try expectEqual(@as(u32, 119), Audit54MockHost.equal_calls);

        // Non-recursive 50-element `[]const Point` slice: ZERO `equalJsValue` host calls!
        Audit54MockHost.equal_calls = 0;
        const pts_raw: js.Ref(js.Any) = .{ .handle = Audit54MockHost.allocObj(0x50) };
        defer pts_raw.deinit();
        const pts = try js.fromJsRefAlloc([]const Point, std.testing.allocator, pts_raw);
        defer js.freeDecoded([]const Point, std.testing.allocator, pts);
        try expectEqual(@as(usize, 50), pts.len);
        try expectEqual(@as(i32, 0), pts[0].x);
        try expectEqual(@as(i32, 49), pts[49].x);
        try expectEqual(@as(u32, 0), Audit54MockHost.equal_calls);

        // Dense 10-struct mutually recursive clique (`C0..C9`, 100 cross-edges) inside non-self-recursive `[]const C0`:
        // verifies O(V+E) shared-visited comptime reachability (would exceed >10^7 branches under per-path DFS)!
        const Clique = struct {
            const C0 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C1 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C2 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C3 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C4 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C5 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C6 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C7 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C8 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
            const C9 = struct { f0: ?*const C0 = null, f1: ?*const C1 = null, f2: ?*const C2 = null, f3: ?*const C3 = null, f4: ?*const C4 = null, f5: ?*const C5 = null, f6: ?*const C6 = null, f7: ?*const C7 = null, f8: ?*const C8 = null, f9: ?*const C9 = null };
        };
        Audit54MockHost.equal_calls = 0;
        const clique_raw: js.Ref(js.Any) = .{ .handle = Audit54MockHost.allocObj(0x50) };
        defer clique_raw.deinit();
        const clique_items = try js.fromJsRefAlloc([]const Clique.C0, std.testing.allocator, clique_raw);
        defer js.freeDecoded([]const Clique.C0, std.testing.allocator, clique_items);
        try expectEqual(@as(usize, 50), clique_items.len);
        try expect(clique_items[0].f9 == null);
        // `[]const Clique.C0` is NOT self-recursive even though `C0..C9` are mutually recursive, so 0 `equalJsValue` calls!
        try expectEqual(@as(u32, 0), Audit54MockHost.equal_calls);
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    // 4. M5: `error.JsException` thrown by a property getter during union arm decode propagates immediately
    // with `lastError` preserved rather than being swallowed as `error.TypeError`!
    {
        const ArmObj = struct {
            boom: i32,
        };
        const U = union(enum) {
            obj: ArmObj,
            num: f64,
        };
        const throw_raw: js.Ref(js.Any) = .{ .handle = Audit54MockHost.allocObj(0x30) };
        defer throw_raw.deinit();
        try std.testing.expectError(error.JsException, js.fromJsRefAlloc(U, std.testing.allocator, throw_raw));
        const err_opt = js.takeLastError();
        try expect(err_opt != null);
        err_opt.?.deinit();
    }
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}




