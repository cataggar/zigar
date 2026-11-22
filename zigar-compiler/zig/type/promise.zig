const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const util = @import("util.zig");

fn releaseDiscardedJsValues(comptime V: type, value: V) void {
    switch (@typeInfo(V)) {
        .error_union => {
            if (value) |payload| {
                releaseDiscardedJsValues(@TypeOf(payload), payload);
            } else |_| {}
        },
        .optional => {
            if (value) |payload| {
                releaseDiscardedJsValues(@TypeOf(payload), payload);
            }
        },
        .@"struct" => |info| {
            if (comptime util.getInternalType(V) == .js_value) {
                if (comptime @hasDecl(V, "deinit")) {
                    value.deinit();
                }
                return;
            }
            inline for (info.fields) |field| {
                releaseDiscardedJsValues(field.type, @field(value, field.name));
            }
        },
        .@"union" => |info| {
            if (info.tag_type != null) {
                switch (value) {
                    inline else => |payload| releaseDiscardedJsValues(@TypeOf(payload), payload),
                }
            }
        },
        .array => |info| {
            for (value) |elem| {
                releaseDiscardedJsValues(info.child, elem);
            }
        },
        else => {},
    }
}

pub fn Promise(comptime T: type) type {
    return struct {
        ptr: ?*anyopaque = null,
        callback: *const fn (?*anyopaque, T) void,

        pub const payload = T;
        pub const internal_type: util.InternalType = .promise;

        pub fn init(ptr: ?*const anyopaque, cb: anytype) @This() {
            return .{
                .ptr = @constCast(ptr),
                .callback = util.getCallback(fn (?*anyopaque, T) void, cb),
            };
        }

        pub fn resolve(self: @This(), value: T) void {
            self.callback(self.ptr, value);
        }

        pub fn any(self: @This()) Promise(util.Any(T)) {
            return .{ .ptr = self.ptr, .callback = @ptrCast(self.callback) };
        }

        pub fn partition(self: @This(), allocator: std.mem.Allocator, count: usize) !@This() {
            if (count == 1) {
                return self;
            }
            const ThisPromise = @This();
            const Context = struct {
                allocator: std.mem.Allocator,
                promise: ThisPromise,
                count: usize,
                fired: bool = false,

                pub fn resolve(ctx: *@This(), value: T) void {
                    var call = false;
                    var free = false;
                    if (@typeInfo(T) == .error_union) {
                        if (value) |_| {
                            free = @atomicRmw(usize, &ctx.count, .Sub, 1, .acq_rel) == 1;
                            call = free and @cmpxchgStrong(bool, &ctx.fired, false, true, .acq_rel, .monotonic) == null;
                        } else |_| {
                            call = @cmpxchgStrong(bool, &ctx.fired, false, true, .acq_rel, .monotonic) == null;
                            free = @atomicRmw(usize, &ctx.count, .Sub, 1, .acq_rel) == 1;
                        }
                    } else {
                        free = @atomicRmw(usize, &ctx.count, .Sub, 1, .acq_rel) == 1;
                        call = free;
                    }
                    if (call) {
                        ctx.promise.resolve(value);
                    } else {
                        releaseDiscardedJsValues(T, value);
                    }
                    if (free) {
                        const allocator_copy = ctx.allocator;
                        allocator_copy.destroy(ctx);
                    }
                }
            };
            const ctx = try allocator.create(Context);
            ctx.* = .{ .allocator = allocator, .promise = self, .count = count };
            return @This().init(ctx, Context.resolve);
        }

        test "partition" {
            if (T == anyerror!u32) {
                const ns = struct {
                    var test_value: T = 0;

                    fn resolve(_: *anyopaque, value: T) void {
                        test_value = value;
                    }
                };
                var gpa = std.heap.DebugAllocator(.{}).init;
                const promise1: @This() = @This().init(null, ns.resolve);
                const multipart_promise1 = try promise1.partition(gpa.allocator(), 3);
                multipart_promise1.resolve(1);
                multipart_promise1.resolve(2);
                try expectEqual(0, ns.test_value);
                multipart_promise1.resolve(3);
                try expectEqual(3, ns.test_value);
                const promise2: @This() = @This().init(null, ns.resolve);
                const multipart_promise2 = try promise2.partition(gpa.allocator(), 3);
                multipart_promise2.resolve(error.OutOfMemory);
                try expectError(error.OutOfMemory, ns.test_value);
            }
        }
    };
}

test {
    _ = Promise(anyerror!u32);
}

test "partition releases discarded JsValue handles" {
    const MockJsVal = struct {
        handle: u32,
        pub const internal_type: util.InternalType = .js_value;

        var deinit_count: usize = 0;
        var last_deinited: u32 = 0;

        pub fn deinit(self: @This()) void {
            deinit_count += 1;
            last_deinited = self.handle;
        }
    };

    const ns = struct {
        var resolved_handle: u32 = 0;

        fn onResolve(_: ?*anyopaque, val: anyerror!MockJsVal) void {
            if (val) |v| {
                resolved_handle = v.handle;
            } else |_| {}
        }
    };

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const p = Promise(anyerror!MockJsVal).init(null, ns.onResolve);
    const mp = try p.partition(gpa.allocator(), 3);
    mp.resolve(.{ .handle = 101 });
    mp.resolve(.{ .handle = 102 });
    try expectEqual(@as(usize, 2), MockJsVal.deinit_count);
    try expectEqual(@as(u32, 102), MockJsVal.last_deinited);
    try expectEqual(@as(u32, 0), ns.resolved_handle);

    mp.resolve(.{ .handle = 103 });
    try expectEqual(@as(usize, 2), MockJsVal.deinit_count);
    try expectEqual(@as(u32, 103), ns.resolved_handle);
}

pub fn PromiseOf(comptime arg: anytype) type {
    const FT = util.Function(arg);
    const f = @typeInfo(FT).@"fn";
    return Promise(f.return_type.?);
}

pub fn PromiseArgOf(comptime arg: anytype) type {
    const FT = util.Function(arg);
    const f = @typeInfo(FT).@"fn";
    return inline for (f.param_types) |param_type| {
        if (util.getInternalType(param_type) == .promise) break param_type.?;
    } else @compileError("No promise argument: " ++ @typeName(FT));
}
