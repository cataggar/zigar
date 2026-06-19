const std = @import("std");
const compat = @import("../compat.zig");
const reify = @import("../reify.zig");
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqual = std.testing.expectEqual;

pub fn ArgStruct(comptime T: type) type {
    const f = @typeInfo(T).@"fn";
    const count = get: {
        var count = 1;
        for (compat.params(f)) |param| {
            if (param.type != null) {
                count += 1;
            }
        }
        break :get count;
    };
    const RT = if (f.return_type) |RT| switch (RT) {
        noreturn => void,
        else => RT,
    } else void;
    var fields: [count]reify.StructField = undefined;
    fields[0] = .{
        .name = "retval",
        .type = RT,
        .is_comptime = false,
        .alignment = @alignOf(RT),
        .default_value_ptr = null,
    };
    var arg_index = 0;
    for (compat.params(f)) |param| {
        if (param.type != null) {
            const name = std.fmt.comptimePrint("{d}", .{arg_index});
            fields[arg_index + 1] = .{
                .name = name,
                .type = param.type.?,
                .is_comptime = false,
                .alignment = @alignOf(param.type.?),
                .default_value_ptr = null,
            };
            arg_index += 1;
        }
    }
    return reify.Reify(.{
        .@"struct" = .{
            .layout = .auto,
            .decls = &.{},
            .fields = &fields,
            .is_tuple = false,
        },
    });
}

test "ArgStruct" {
    const ns = struct {
        fn A(a: i32, b: bool) bool {
            return if (a > 10 and b) true else false;
        }

        fn B(s: []const u8) void {
            _ = s;
        }

        fn C(alloc: std.mem.Allocator, arg1: i32, arg2: i32) bool {
            _ = alloc;
            return arg1 < arg2;
        }
    };
    const ArgA = ArgStruct(@TypeOf(ns.A));
    const fieldsA = compat.fieldsOf(ArgA);
    try expectEqual(3, fieldsA.len);
    try expectEqualSlices(u8, "retval", fieldsA[0].name);
    try expectEqualSlices(u8, "0", fieldsA[1].name);
    try expectEqualSlices(u8, "1", fieldsA[2].name);
    const ArgB = ArgStruct(@TypeOf(ns.B));
    const fieldsB = compat.fieldsOf(ArgB);
    try expectEqual(2, fieldsB.len);
    try expectEqualSlices(u8, "retval", fieldsB[0].name);
    try expectEqualSlices(u8, "0", fieldsB[1].name);
    const ArgC = ArgStruct(@TypeOf(ns.C));
    const fieldsC = compat.fieldsOf(ArgC);
    try expectEqual(4, fieldsC.len);
}
