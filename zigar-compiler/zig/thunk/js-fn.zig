const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const E = std.os.wasi.errno_t;
const builtin = @import("builtin");

const ArgStruct = @import("../type/arg-struct.zig").ArgStruct;
const fn_binding = @import("../zigft/fn-binding.zig");
const fn_transform = @import("../zigft/fn-transform.zig");

pub const Action = enum(u32) {
    create,
    destroy,
    identify,
    get_dynamic_thunk,
};
pub const Error = error{ UnableToCreateThunk, UnableToFindThunk };

pub const ThunkController = *const fn (Action, usize) anyerror!usize;

pub fn createTargetController(comptime host: type, comptime FPT: type) ThunkController {
    const FT = switch (@typeInfo(FPT)) {
        .pointer => |pt| switch (@typeInfo(pt.child)) {
            .@"fn" => pt.child,
            else => @compileError("Not a function pointer"),
        },
        else => @compileError("Not a function pointer"),
    };
    return createThunkController(host, FT);
}

pub fn createThunkController(comptime host: type, comptime BFT: type) ThunkController {
    const tc_ns = switch (comptime builtin.target.cpu.arch.isWasm()) {
        false => struct {
            fn control(action: Action, arg: usize) anyerror!usize {
                const vars = .{
                    .@"-1" = arg,
                };
                const CT = @TypeOf(vars);
                const caller = getJscallHandler(host, BFT);
                switch (action) {
                    .create => {
                        if (fn_binding.bind(caller, vars)) |thunk| {
                            return @intFromPtr(thunk);
                        } else |_| {
                            return Error.UnableToCreateThunk;
                        }
                    },
                    .destroy => {
                        const thunk: *const BFT = @ptrFromInt(arg);
                        if (fn_binding.bound(CT, thunk)) |ctx| {
                            defer fn_binding.unbind(thunk);
                            return ctx.@"-1";
                        } else {
                            return Error.UnableToFindThunk;
                        }
                    },
                    .identify => {
                        const thunk: *const BFT = @ptrFromInt(arg);
                        if (fn_binding.bound(CT, thunk)) |ctx| {
                            return ctx.@"-1";
                        } else {
                            return Error.UnableToFindThunk;
                        }
                    },
                    .get_dynamic_thunk => return Error.UnableToCreateThunk,
                }
            }
        },
        true => struct {
            const count = 16;

            var fn_ids: [count]usize = init: {
                var array: [count]usize = undefined;
                for (&array) |*ptr| ptr.* = 0;
                break :init array;
            };
            const thunks: [count]*const BFT = init: {
                const CHT = CallHandler(BFT);
                const ch = @typeInfo(CHT).@"fn";
                const RT = ch.return_type.?;
                const handler = getJscallHandler(host, BFT);
                var array: [count]*const BFT = undefined;
                for (&array, 0..) |*ptr, index| {
                    const ns = struct {
                        inline fn call(bf_args: std.meta.ArgsTuple(BFT)) RT {
                            var ch_args: std.meta.ArgsTuple(CHT) = undefined;
                            inline for (bf_args, 0..) |arg, arg_index| {
                                ch_args[arg_index] = arg;
                            }
                            ch_args[bf_args.len] = null;
                            ch_args[bf_args.len + 1] = fn_ids[index];
                            return @call(.never_inline, handler, ch_args);
                        }
                    };
                    ptr.* = &fn_transform.spreadArgs(ns.call, ch.attrs.@"callconv");
                }
                break :init array;
            };
            const dynamic_thunk: *const BFT = init: {
                const CHT = CallHandler(BFT);
                const ch = @typeInfo(CHT).@"fn";
                const RT = ch.return_type.?;
                const handler = getJscallHandler(host, BFT);
                const ns = struct {
                    inline fn call(bf_args: std.meta.ArgsTuple(BFT)) RT {
                        const fn_id = if (@hasDecl(host, "consumePendingDynamicJsThunkId"))
                            host.consumePendingDynamicJsThunkId()
                        else
                            0;
                        var ch_args: std.meta.ArgsTuple(CHT) = undefined;
                        inline for (bf_args, 0..) |arg, arg_index| {
                            ch_args[arg_index] = arg;
                        }
                        ch_args[bf_args.len] = null;
                        ch_args[bf_args.len + 1] = fn_id;
                        return @call(.never_inline, handler, ch_args);
                    }
                };
                break :init &fn_transform.spreadArgs(ns.call, ch.attrs.@"callconv");
            };

            fn control(action: Action, arg: usize) !usize {
                switch (action) {
                    .create => {
                        const fn_id = arg;
                        return for (&fn_ids, 0..) |*ptr, index| {
                            if (ptr.* == 0) {
                                ptr.* = fn_id;
                                break @intFromPtr(thunks[index]);
                            }
                        } else Error.UnableToCreateThunk;
                    },
                    .destroy => {
                        const thunk: *const BFT = @ptrFromInt(arg);
                        return for (thunks, &fn_ids) |f, *id_ptr| {
                            if (f == thunk) {
                                defer id_ptr.* = 0;
                                break id_ptr.*;
                            }
                        } else Error.UnableToFindThunk;
                    },
                    .identify => {
                        const thunk: *const BFT = @ptrFromInt(arg);
                        return for (thunks, &fn_ids) |f, *id_ptr| {
                            if (f == thunk) {
                                break id_ptr.*;
                            }
                        } else Error.UnableToFindThunk;
                    },
                    .get_dynamic_thunk => return @intFromPtr(dynamic_thunk),
                }
            }
        },
    };
    return &tc_ns.control;
}

test "createThunkController" {
    const BFT = fn (i32, f64) usize;
    const host = struct {
        var pending_id: usize = 0;

        pub fn consumePendingDynamicJsThunkId() usize {
            const id = pending_id;
            pending_id = 0;
            return id;
        }

        fn getLanguageName() []const u8 {
            return "JavaScript";
        }

        fn handleJscall(fn_id: usize, arg_ptr: *anyopaque, arg_size: usize) E {
            if (arg_size == @sizeOf(ArgStruct(BFT))) {
                const arg_s: *ArgStruct(BFT) = @ptrCast(@alignCast(arg_ptr));
                arg_s.retval = fn_id + @as(usize, @intCast(arg_s.@"0"));
                return .SUCCESS;
            } else {
                return .FAULT;
            }
        }
    };
    const tc = createThunkController(host, BFT);
    const thunk_address = try tc(.create, 1234);
    const thunk: *const BFT = @ptrFromInt(thunk_address);
    const result = thunk(777, 3.14);
    try expectEqual(1234 + 777, result);
    if (builtin.target.cpu.arch.isWasm()) {
        const dyn_address = try tc(.get_dynamic_thunk, 0);
        try expect(dyn_address != 0 and dyn_address != thunk_address);
        const dyn_thunk: *const BFT = @ptrFromInt(dyn_address);
        host.pending_id = 5000;
        try expectEqual(5777, dyn_thunk(777, 3.14));
        try expectEqual(@as(usize, 0), host.pending_id);
        try expectEqual(777, dyn_thunk(777, 3.14));
    } else {
        try expectError(Error.UnableToCreateThunk, tc(.get_dynamic_thunk, 0));
    }
}

fn CallHandler(comptime BFT: type) type {
    const f = @typeInfo(BFT).@"fn";
    const param_count = f.param_types.len + 2;
    var param_types: [param_count]type = undefined;
    var param_attrs: [param_count]std.lang.Type.Fn.ParamAttributes = undefined;
    for (f.param_types, 0..) |param_type, i| {
        param_types[i] = param_type.?;
        param_attrs[i] = f.param_attrs[i];
    }
    param_types[param_count - 2] = ?*anyopaque;
    param_attrs[param_count - 2] = .{};
    param_types[param_count - 1] = usize;
    param_attrs[param_count - 1] = .{};
    return @Fn(&param_types, &param_attrs, f.return_type.?, f.attrs);
}

fn getJscallHandler(comptime host: type, comptime BFT: type) CallHandler(BFT) {
    const CHT = CallHandler(BFT);
    const ch = @typeInfo(CHT).@"fn";
    const RT = ch.return_type.?;
    const ns = struct {
        inline fn call(args: std.meta.ArgsTuple(CHT)) RT {
            @setEvalBranchQuota(1000000);
            // fill the argument struct
            var arg_s: ArgStruct(BFT) = undefined;
            inline for (0..ch.param_types.len - 2) |arg_index| {
                const name = std.fmt.comptimePrint("{d}", .{arg_index});
                @field(arg_s, name) = args[arg_index];
            }
            // the last two arguments are the context pointer and the function id
            const fn_id = args[ch.param_types.len - 1];
            const result = host.handleJscall(fn_id, &arg_s, @sizeOf(@TypeOf(arg_s)));
            switch (result) {
                .SUCCESS => {},
                .DEADLK => {
                    if (comptime findError(RT, .{ error.Deadlock, error.Unexpected })) |err| {
                        return err;
                    } else @panic("Promise encountered in main thread");
                },
                .PERM => {
                    if (comptime findError(RT, .{ error.Disabled, error.Unexpected })) |err| {
                        return err;
                    } else @panic("Multithreading not enabled");
                },
                else => {
                    if (comptime findError(RT, .{error.Unexpected})) |err| {
                        return err;
                    } else {
                        var buffer: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buffer, "{s} function failed", .{host.getLanguageName()}) catch unreachable;
                        @panic(msg);
                    }
                },
            }
            return arg_s.retval;
        }
    };
    return fn_transform.spreadArgs(ns.call, ch.attrs.@"callconv");
}

test "getJscallHandler" {
    const BFT = fn (i32, f64) usize;
    const host = struct {
        fn getLanguageName() []const u8 {
            return "JavaScript";
        }

        fn handleJscall(_: usize, arg_ptr: *anyopaque, arg_size: usize) E {
            if (arg_size == @sizeOf(ArgStruct(BFT))) {
                @as(*ArgStruct(BFT), @ptrCast(@alignCast(arg_ptr))).retval = 1234;
                return .SUCCESS;
            } else {
                return .FAULT;
            }
        }
    };
    const ch = getJscallHandler(host, BFT);
    const result = ch(777, 3.14, null, 1);
    try expectEqual(1234, result);
}

test "getJscallHandler (error handling)" {
    const host = struct {
        fn init(_: ?*const anyopaque) @This() {
            return .{};
        }

        fn getLanguageName() []const u8 {
            return "JavaScript";
        }

        fn handleJscall(_: usize, _: *anyopaque, _: usize) E {
            return .FAULT;
        }
    };
    const ES1 = error{ Unexpected, Cow };
    const BFT1 = fn (i32, f64) ES1!usize;
    const ch1 = getJscallHandler(host, BFT1);
    const result1 = ch1(777, 3.14, null, 1);
    try expectError(ES1.Unexpected, result1);
    const ES2 = error{ Unexpected, cow };
    const BFT2 = fn (i32, f64) ES2!usize;
    const ch2 = getJscallHandler(host, BFT2);
    const result2 = ch2(777, 3.14, null, 2);
    try expectError(ES2.Unexpected, result2);
    const BFT3 = fn (i32, f64) anyerror!usize;
    const ch3 = getJscallHandler(host, BFT3);
    const result3 = ch3(777, 3.14, null, 3);
    try expectError(ES2.Unexpected, result3);
}

fn findError(comptime T: type, comptime errors: anytype) RT: {
    break :RT if (findErrorIndex(T, errors)) |index|
        ?@TypeOf(errors[index])
    else
        ?anyerror;
} {
    return if (comptime findErrorIndex(T, errors)) |index|
        errors[index]
    else
        null;
}

fn findErrorIndex(comptime T: type, comptime errors: anytype) ?usize {
    return switch (@typeInfo(T)) {
        .error_union => |eu| inline for (errors, 0..) |err, i| {
            const name = @errorName(err);
            if (@typeInfo(eu.error_set).error_set.error_names) |error_names| {
                if (inline for (error_names) |error_name| {
                    if (std.mem.eql(u8, error_name, name)) break true;
                } else false) break i;
            } else break i;
        } else null,
        else => null,
    };
}

test "findError" {
    try expect(findError(error{ Hello, World }!i32, .{error.Hello}) != null);
    try expect(findError(anyerror!i32, .{error.Cow}) != null);
    try expect(findError(error{ Hello, World }!i32, .{error.Cow}) == null);
}
