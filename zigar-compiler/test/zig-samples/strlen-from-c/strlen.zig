const string = @import("c");

pub fn getLength(s: []const u8) usize {
    return string.strlen(s.ptr);
}
