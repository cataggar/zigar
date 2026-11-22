const std = @import("std");
const zigar = @import("zigar");

var gpa: zigar.mem.TrackingAllocator = .init(zigar.mem.allocator);
pub const tracked_allocator = gpa.allocator();

pub fn activeCount() usize {
    return gpa.activeCount();
}

pub fn activeBytes() usize {
    return gpa.activeBytes();
}

pub fn formatGreeting(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "Hello, ");
    try list.appendSlice(allocator, name);
    try list.append(allocator, '!');
    return list.toOwnedSlice(allocator);
}

pub fn exerciseInternalRealloc() !usize {
    var buf = try tracked_allocator.alloc(u8, 16);
    @memset(buf, 0x2a);
    buf = try tracked_allocator.realloc(buf, 256);
    const peak = gpa.activeBytes();
    buf = try tracked_allocator.realloc(buf, 32);
    for (buf[0..16]) |b| {
        if (b != 0x2a) return error.Unexpected;
    }
    tracked_allocator.free(buf);
    return peak;
}
