const std = @import("std");
const zig = @import("./hello.zig");
const c = @import("c");

pub fn printZig() void {
    std.debug.print("{s}\n", .{zig.hello()});
}

pub fn printC() void {
    std.debug.print("{s}\n", .{c.hello()});
}
