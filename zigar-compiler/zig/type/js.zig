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
    OutOfMemory,
    Unexpected,
};

pub const OverflowError = Error || error{Overflow};

pub const AllocError = Error || std.mem.Allocator.Error;

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
    _: u30 = 0,
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

fn isCallbackWrapper(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "is_zig_callback") and T.is_zig_callback,
        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .@"struct" and @hasDecl(pt.child, "is_zig_callback") and pt.child.is_zig_callback,
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
    switch (@typeInfo(V)) {
        .pointer => |pt| {
            if (pt.size == .one and comptime util.getInternalType(pt.child) == .js_value) {
                return value.*.handle;
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

        fn DynamicKeyArgType(comptime K: type) type {
            if (K == []const u8 or K == []u8 or comptime isStringLiteralPtr(K)) {
                return []const u8;
            }
            if (comptime util.getInternalType(K) == .js_value) {
                return Ref(module.Any);
            }
            switch (@typeInfo(K)) {
                .pointer => |pt| {
                    if (pt.size == .slice and pt.child == u8) return []const u8;
                    if (pt.size == .many and pt.sentinel_ptr != null and pt.child == u8) return []const u8;
                    if (pt.size == .one and comptime util.getInternalType(pt.child) == .js_value) return Ref(module.Any);
                },
                else => {},
            }
            @compileError("Dynamic JS property key must be `[]const u8` or `zigar.js.Ref(...)`, received " ++ @typeName(K));
        }

        fn coerceDynamicKey(key: anytype) DynamicKeyArgType(@TypeOf(key)) {
            const K = @TypeOf(key);
            const OutT = DynamicKeyArgType(K);
            if (OutT == []const u8) {
                if (comptime isStringLiteralPtr(K)) return key[0..];
                switch (@typeInfo(K)) {
                    .pointer => |pt| if (pt.size == .many and pt.sentinel_ptr != null) return std.mem.span(key),
                    else => {},
                }
                return key;
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

        pub fn CallbackWithOptions(comptime JsFnSig: type, comptime cb_flags: module.CallbackFlags) type {
            const fn_info = switch (@typeInfo(JsFnSig)) {
                .@"fn" => |fi| fi,
                else => @compileError("Expected a Zig function signature `fn (...) ...`, received " ++ @typeName(JsFnSig)),
            };
            const Args = arg_struct.ArgStruct(JsFnSig);
            const RT = fn_info.return_type orelse void;

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
                            var call_args: std.meta.ArgsTuple(HandlerT) = undefined;
                            call_args[0] = typed_ctx;
                            inline for (0..fn_info.param_types.len) |i| {
                                const field_name = std.fmt.comptimePrint("{d}", .{i});
                                call_args[i + 1] = @field(frame, field_name);
                            }
                            const HRet = h_info.return_type orelse void;
                            if (@typeInfo(HRet) == .error_union and @typeInfo(RT) != .error_union) {
                                frame.retval = try @call(.auto, handler, call_args);
                            } else {
                                frame.retval = @call(.auto, handler, call_args);
                            }
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
                            var call_args: std.meta.ArgsTuple(HandlerT) = undefined;
                            const FirstParamT = h_info.param_types[0].?;
                            if (comptime FirstParamT == Ctx) {
                                call_args[0] = box.ctx;
                            } else {
                                call_args[0] = &box.ctx;
                            }
                            inline for (0..fn_info.param_types.len) |i| {
                                const field_name = std.fmt.comptimePrint("{d}", .{i});
                                call_args[i + 1] = @field(frame, field_name);
                            }
                            const HRet = h_info.return_type orelse void;
                            if (@typeInfo(HRet) == .error_union and @typeInfo(RT) != .error_union) {
                                frame.retval = try @call(.auto, handler, call_args);
                            } else {
                                frame.retval = @call(.auto, handler, call_args);
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
                        fn forward(_: *u8, raw_arg: *Args) anyerror!void {
                            var call_args: std.meta.ArgsTuple(PlainFnT) = undefined;
                            inline for (0..fn_info.param_types.len) |i| {
                                const field_name = std.fmt.comptimePrint("{d}", .{i});
                                call_args[i] = @field(raw_arg, field_name);
                            }
                            const PRet = p_info.return_type orelse void;
                            if (@typeInfo(PRet) == .error_union and @typeInfo(RT) != .error_union) {
                                raw_arg.retval = try @call(.auto, plain_fn, call_args);
                            } else {
                                raw_arg.retval = @call(.auto, plain_fn, call_args);
                            }
                        }
                        fn invoke(raw_ctx: *anyopaque, raw_arg: *anyopaque) anyerror!void {
                            const typed_ctx: *u8 = @ptrCast(raw_ctx);
                            const frame: *Args = @ptrCast(@alignCast(raw_arg));
                            return forward(typed_ctx, frame);
                        }
                    };
                    return registerSlot(@ptrCast(&Stateless.dummy), &Stateless.invoke, null, is_once);
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

                pub fn @"await"(self: Self) module.Error!T {
                    return dispatchAwaitOp(.promise, T, false, self.handle, {}, null);
                }

                pub const wait = @"await";

                pub fn awaitAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError!T {
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

        pub fn Iterator(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Element = T;
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

                pub fn next(self: Self) module.Error!?T {
                    var done_flag: u8 = 0;
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

                pub fn nextAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError!?T {
                    var done_flag: u8 = 0;
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
            };
        }

        pub fn AsyncIterator(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Element = T;
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

                pub fn next(self: Self) module.Error!?T {
                    var done_flag: u8 = 0;
                    return dispatchAwaitOp(.async_iterator_next, T, false, self.handle, {}, &done_flag);
                }

                pub fn nextAlloc(self: Self, allocator: std.mem.Allocator) module.AllocError!?T {
                    var done_flag: u8 = 0;
                    return dispatchAwaitOp(.async_iterator_next, T, true, self.handle, allocator, &done_flag);
                }

                pub fn returnEarly(self: Self) module.Error!void {
                    return dispatchAwaitOp(.async_iterator_return, void, false, self.handle, {}, null);
                }

                pub const close = returnEarly;
            };
        }

        pub fn Array(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Element = T;
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
            return extern struct {
                const Self = @This();
                pub const Key = K;
                pub const Value = V;
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

test "Standard wrappers: ABI layout, Promise, binary views, collections, BigInt, Date, RegExp, and Iterators" {
    const WrapperMockHost = struct {
        const SelfHost = @This();
        var active_handles: u32 = 0;
        var next_slot: u32 = 16;
        var active_callbacks: u32 = 0;
        var await_unavailable: bool = false;
        var storage_bytes: [64]u8 = @splat(0);
        var storage_len: usize = 0;
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
            return (gen << 20) | tag;
        }

        pub fn cloneJsValue(handle: u32) u32 {
            if (handle <= reserved_global_this_handle) return handle;
            return allocSlot(handle & 0xFFFFF);
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
                    const offset = frame.@"3";
                    const copy_len = @min(frame.@"2", storage_len - offset);
                    if (copy_len > 0) {
                        const dst: [*]u8 = @ptrFromInt(frame.@"1");
                        @memcpy(dst[0..copy_len], storage_bytes[offset .. offset + copy_len]);
                    }
                    frame.retval = copy_len;
                    return .SUCCESS;
                },
                .binary_write => {
                    const Frame = arg_struct.ArgStruct(fn (J.Ref(Any), usize, usize, usize) Error!void);
                    const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                    const copy_len = frame.@"2";
                    const offset = frame.@"3";
                    if (offset + copy_len > storage_len) {
                        frame.retval = error.JsException;
                        return .SUCCESS;
                    }
                    if (copy_len > 0) {
                        const src: [*]const u8 = @ptrFromInt(frame.@"1");
                        @memcpy(storage_bytes[offset .. offset + copy_len], src[0..copy_len]);
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
                            frame.retval = storage_len;
                        },
                        .byte_offset => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            frame.retval = 0;
                        },
                        .element_length => {
                            const Frame = arg_struct.ArgStruct(fn (J.Ref(Any)) Error!usize);
                            const frame: *Frame = @ptrCast(@alignCast(arg_ptr));
                            const tag = frame.@"0".handle & 0xFFFFF;
                            const elem_size: usize = if (tag == 50 + @intFromEnum(BinaryKind.int32_array)) 4 else 1;
                            frame.retval = storage_len / elem_size;
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


