const std = @import("std");
const node = @import("generated/root.zig");
const js = node.zigar_js;

comptime {
    if (!std.mem.eql(u8, node.http.zigar_js.wire_specifier, "node:http")) {
        @compileError("expected canonical node:http wire_specifier");
    }
    _ = node.stream_web.ReadableStream(u8);
}

pub fn activeHandles() usize {
    return js.activeHandleCount();
}

pub fn readMaxHeaderSize() !f64 {
    return node.http.max_header_size.get();
}
