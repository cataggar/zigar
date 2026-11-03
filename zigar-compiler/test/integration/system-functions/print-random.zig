const std = @import("std");
var threaded_io = std.Io.Threaded.init_single_threaded;
const io = threaded_io.io();

pub fn print() !void {
    var buffer: [16]u8 = undefined;
    try io.randomSecure(&buffer);
    std.debug.print("{any}\n", .{buffer});
}
