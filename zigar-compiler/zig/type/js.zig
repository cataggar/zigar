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
        pub const JsType = module.JsType;
        pub const HostOp = module.HostOp;
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

        fn dispatchHostOp(
            comptime op: module.HostOp,
            comptime flags: module.HostOpFlags,
            comptime key_name: []const u8,
            comptime HostFn: type,
            args_tuple: std.meta.ArgsTuple(HostFn),
        ) FnReturnType(HostFn) {
            const Args = arg_struct.ArgStruct(HostFn);
            const RT = FnReturnType(HostFn);
            const reg = TypeRegistration(Args);
            _ = reg;
            if (comptime (op == .import_module and !flags.dynamic_key)) {
                const mod_reg = ModuleRegistration(key_name.len, key_name[0..key_name.len].*);
                _ = &mod_reg.key_arr;
            }

            const Site = struct {
                var descriptor: module.HostOpDescriptor = .{
                    .signature = signature.get(Args),
                    .op = @intFromEnum(op),
                    .flags = @bitCast(flags),
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
            const null_index: u32 = std.math.maxInt(u32);
            const max_slot_index: u32 = (1 << 20) - 2;
            const InvokerFn = *const fn (*anyopaque, *anyopaque) anyerror!void;
            const DeinitCtxFn = *const fn (*anyopaque) void;

            const SlotEntry = struct {
                ctx_ptr: *anyopaque = undefined,
                invoker: ?InvokerFn = null,
                deinit_ctx: ?DeinitCtxFn = null,
                fn_handle: u32 = module.reserved_undefined_handle,
                generation: u16 = 1,
                active_calls: u32 = 0,
                once: bool = false,
                pending_release: bool = false,
                next_free: u32 = null_index,
            };

            const SlabNode = struct {
                entries: [slab_capacity]SlotEntry = @splat(.{}),
                next: ?*SlabNode = null,
            };

            var inline_slab: SlabNode = .{};
            var slab_count: u32 = 1;
            var high_water_in_tail: usize = 0;
            var tail_slab: *SlabNode = &inline_slab;
            var free_head: u32 = null_index;
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
                const offset: usize = @intCast(slot_index % slab_capacity);
                var current: ?*SlabNode = &inline_slab;
                var idx: usize = 0;
                while (current) |node| : ({
                    current = node.next;
                    idx += 1;
                }) {
                    if (idx == slab_idx) {
                        return &node.entries[offset];
                    }
                }
                return null;
            }

            fn allocate(ctx_ptr: *anyopaque, invoker: InvokerFn, deinit_ctx: ?DeinitCtxFn, is_once: bool) !u32 {
                var slot_index: u32 = undefined;
                var entry_ptr: *SlotEntry = undefined;

                if (free_head != null_index) {
                    slot_index = free_head;
                    entry_ptr = entryAt(slot_index) orelse return error.Unexpected;
                    free_head = entry_ptr.next_free;
                } else {
                    if (high_water_in_tail >= slab_capacity) {
                        const next_global: u32 = slab_count * @as(u32, slab_capacity);
                        if (next_global > max_slot_index) return error.OutOfMemory;
                        const new_slab = try backingAllocator().create(SlabNode);
                        new_slab.* = .{};
                        tail_slab.next = new_slab;
                        tail_slab = new_slab;
                        slab_count += 1;
                        high_water_in_tail = 0;
                    }
                    slot_index = (slab_count - 1) * @as(u32, slab_capacity) + @as(u32, @intCast(high_water_in_tail));
                    if (slot_index > max_slot_index) return error.OutOfMemory;
                    entry_ptr = &tail_slab.entries[high_water_in_tail];
                    high_water_in_tail += 1;
                }

                if (entry_ptr.generation == 0) entry_ptr.generation = 1;
                entry_ptr.ctx_ptr = ctx_ptr;
                entry_ptr.invoker = invoker;
                entry_ptr.deinit_ctx = deinit_ctx;
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
                if (entry.invoker == null or entry.pending_release) return null;
                if ((entry.generation & 0x0FFF) != gen12) return null;
                return .{ .slot_index = slot_index, .entry = entry };
            }

            fn finalizeSlotRelease(slot_index: u32, entry: *SlotEntry) void {
                const deinit_ctx = entry.deinit_ctx;
                const ctx_ptr = entry.ctx_ptr;
                entry.deinit_ctx = null;
                entry.ctx_ptr = undefined;
                entry.fn_handle = module.reserved_undefined_handle;
                entry.once = false;
                entry.pending_release = false;
                entry.next_free = free_head;
                free_head = slot_index;
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
                if (entry.invoker == null or entry.pending_release or (entry.generation & 0x0FFF) != gen12) return false;

                entry.invoker = null;
                const next_gen: u16 = (entry.generation + 1) & 0x0FFF;
                entry.generation = if (next_gen == 0) 1 else next_gen;
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
                    const slot_id = try CallbackRegistry.allocate(ctx_ptr, invoker, deinit_ctx, effective_once);
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
                    const slot_id = CallbackRegistry.allocate(@ptrCast(box), &BoxedInvoker.invoke, &HeapBox.destroyBox, effective_once) catch |err| {
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
    try expectEqual(@as(usize, 16 + 3 * @sizeOf(usize)), @sizeOf(CallbackDescriptor));

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
