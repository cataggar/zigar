const std = @import("std");
const app = @import("app");

test "src/app.zig parses cleanly under Zig 0.17 std.zig.Ast" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "src/app.zig",
        alloc,
        .limited(4 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer alloc.free(src);
    var tree = try std.zig.Ast.parse(alloc, src, .{ .mode = .zig });
    defer tree.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "monaco-editor-hello-world exports and standalone host guards Sema-verify cleanly" {
    try std.testing.expect(!app.isMounted());
    try std.testing.expectEqual(@as(usize, 0), app.workerUrlRequests());
    try std.testing.expectEqual(@as(u32, 0), app.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), app.activeCallbacks());
    try std.testing.expect(std.mem.indexOf(u8, app.default_code, "Hello world!") != null);

    try std.testing.expectError(error.EditorNotMounted, app.getValue(std.testing.allocator));
    try std.testing.expectError(error.EditorNotMounted, app.setValue("// test"));
    try std.testing.expectError(error.HostUnavailable, app.configureMonacoEnvironment());
    try std.testing.expectError(error.HostUnavailable, app.mount("container"));
    try std.testing.expectError(
        error.HostUnavailable,
        app.resolveWorkerUrl(std.testing.allocator, " editor", "typescript"),
    );
    try std.testing.expectError(error.HostUnavailable, app.unmount());

    const SemaCheck = struct {
        fn verify() !void {
            try app.mount("container");
            try app.mountWithOptions("container", "const x: number = 1;\n", "typescript", "vs-dark");
            const val = try app.getValue(std.testing.allocator);
            defer std.testing.allocator.free(val);
            try app.setValue("const y: number = 2;\n");
            const url = try app.resolveWorkerUrl(std.testing.allocator, " editor", "typescript");
            defer std.testing.allocator.free(url);
            try app.unmount();
        }
    };
    _ = &SemaCheck.verify;
}
