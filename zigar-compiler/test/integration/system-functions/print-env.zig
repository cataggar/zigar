const std = @import("std");

var gpa = std.heap.DebugAllocator(.{}).init;
const allocator = gpa.allocator();

fn getEnviron() std.process.Environ {
    const block: std.process.Environ.Block = switch (std.process.Environ.Block) {
        std.process.Environ.GlobalBlock => .global,
        std.process.Environ.PosixBlock => .{ .slice = @ptrCast(std.mem.sliceTo(std.c.environ, null)) },
        else => @compileError("Unexpected"),
    };
    return .{ .block = block };
}

pub fn get(a: std.mem.Allocator, key: []const u8) ![]u8 {
    return getEnviron().getAlloc(a, key);
}

pub fn print() !void {
    var env = try getEnviron().createMap(allocator);
    defer env.deinit();
    var iter = env.iterator();
    while (iter.next()) |entry| {
        std.debug.print("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

const module_ns = @This();
pub const @"meta(zigar)" = struct {
    pub fn isDeclString(T: type, field: std.meta.DeclEnum(T)) bool {
        return (T == module_ns and field == .get);
    }
};
