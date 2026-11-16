const std = @import("std");
const zigar = @import("zigar");
const libs = @import("libs50.zig");

const js = zigar.js;

// Unreferenced private descriptor inside root module
const unused = js.Module("unused-mod");

// Unreferenced public descriptor inside root module (must NOT be eagerly reflected!)
pub const unused_exported_desc = js.Module("unused-public-mod");

// Unexported nested namespace whose function calls namespace()
const unused_ns = struct {
    pub fn f() void {
        const ns = js.Module("unused-2").namespace() catch return;
        ns.deinit();
    }
};

pub fn joinPaths(alloc: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    _ = unused;
    _ = unused_ns;
    return libs.pathJoin(alloc, left, right);
}

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}
