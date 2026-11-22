const std = @import("std");
const web = @import("web");
const dom = web.dom;
const monaco = web.monaco;
const js = web.zigar_js;

const WorkerSetup = struct {
    pub fn getWorkerUrl(_: *const @This(), _: []const u8, label: []const u8) []const u8 {
        if (std.mem.eql(u8, label, "typescript") or std.mem.eql(u8, label, "javascript")) {
            return "./ts.worker.js";
        }
        return "./editor.worker.js";
    }

    pub fn getWorker(_: *const @This(), _: []const u8, label: []const u8) js.CallError!dom.Worker {
        const url = if (std.mem.eql(u8, label, "json")) "./json.worker.js" else "./editor.worker.js";
        return dom.Worker.init(.{ .str = url }, null);
    }
};

test "generated .zig files in generated/ pass std.zig.Ast.parse with zero errors" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var gen_dir = try std.Io.Dir.cwd().openDir(io, "generated", .{ .iterate = true });
    defer gen_dir.close(io);

    var walker = try gen_dir.walk(alloc);
    defer walker.deinit();

    var zig_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        zig_count += 1;
        const src = try gen_dir.readFileAllocOptions(
            io,
            entry.path,
            alloc,
            .limited(16 * 1024 * 1024),
            .of(u8),
            0,
        );
        defer alloc.free(src);
        var tree = try std.zig.Ast.parse(alloc, src, .{ .mode = .zig });
        defer tree.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    }
    try std.testing.expect(zig_count >= 12);
}

test "dom and monaco-editor types, option structs, enums, and signatures compile cleanly" {
    // 1. KeyMod constants & KeyCode / MarkerSeverity / SelectionDirection enums
    try std.testing.expectEqual(@as(i32, 49), @intFromEnum(monaco.KeyCode.key_s));
    try std.testing.expectEqual(@as(i32, 8), @intFromEnum(monaco.MarkerSeverity.@"error"));
    try std.testing.expectEqual(@as(i32, 4), @intFromEnum(monaco.MarkerSeverity.warning));
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(monaco.SelectionDirection.ltr));
    try std.testing.expect(@hasDecl(monaco.KeyMod, "ctrl_cmd"));
    try std.testing.expect(@hasDecl(monaco.KeyMod, "shift"));
    try std.testing.expect(@hasDecl(monaco.KeyMod, "alt"));
    try std.testing.expect(@hasDecl(monaco.KeyMod, "chord"));

    // 2. Plain option structs default optional fields to `null`
    const opts: monaco.editor.IStandaloneEditorConstructionOptions = .{
        .value = "const answer: number = 42;\n",
        .language = "typescript",
        .theme = "vs-dark",
        .automatic_layout = true,
        .tab_size = 2,
        .read_only = false,
        .minimap = .{ .enabled = false },
    };
    try std.testing.expectEqualStrings("typescript", opts.language.?);
    try std.testing.expectEqualStrings("vs-dark", opts.theme.?);
    try std.testing.expectEqual(true, opts.automatic_layout.?);
    try std.testing.expectEqual(false, opts.minimap.?.enabled.?);
    try std.testing.expect(opts.aria_label == null);
    try std.testing.expect(opts.word_wrap == null);

    // 3. Core Monaco classes/namespaces & DOM globals are strongly typed (zero `Object` degradation)
    try std.testing.expect(@hasDecl(dom, "window"));
    try std.testing.expect(@hasDecl(dom, "document"));
    try std.testing.expect(@hasDecl(dom, "HtmlElement"));
    try std.testing.expect(@hasDecl(dom, "Worker"));
    try std.testing.expect(@hasDecl(monaco, "monaco_environment"));
    try std.testing.expect(@hasDecl(monaco, "Environment"));
    try std.testing.expect(@hasDecl(monaco, "Uri"));
    try std.testing.expect(@hasDecl(monaco, "Range"));
    try std.testing.expect(@hasDecl(monaco, "Selection"));
    try std.testing.expect(@hasDecl(monaco, "Position"));
    try std.testing.expect(@hasDecl(monaco, "editor"));
    try std.testing.expect(@hasDecl(monaco, "languages"));

    // 4. Standalone Sema verification of `MonacoEnvironment` + `dom.document.getElementById` + `monaco.editor.create`
    try std.testing.expectError(error.HostUnavailable, dom.window.get());
    try std.testing.expectError(error.HostUnavailable, dom.document.get());
    try std.testing.expectError(error.HostUnavailable, monaco.monaco_environment.get());
    try std.testing.expectError(error.HostUnavailable, monaco.Environment.init());
    try std.testing.expectError(error.HostUnavailable, monaco.Uri.parse("file:///app.ts", true));
    try std.testing.expectError(error.HostUnavailable, monaco.Range.init(1, 1, 2, 10));
    try std.testing.expectError(error.HostUnavailable, monaco.Selection.init(1, 1, 1, 5));
    try std.testing.expectError(error.HostUnavailable, monaco.Position.init(1, 1));

    // Force Sema analysis of `MonacoEnvironment` + `dom.document.getElementById` + `monaco.editor.create`
    const SemaCheck = struct {
        fn check(options: monaco.editor.IStandaloneEditorConstructionOptions) !void {
            var worker_ctx = WorkerSetup{};
            var url_cl = try js.Closure(*const WorkerSetup, WorkerSetup.getWorkerUrl).tryInit(&worker_ctx);
            defer url_cl.deinit();
            var wk_cl = try js.Closure(*const WorkerSetup, WorkerSetup.getWorker).tryInit(&worker_ctx);
            defer wk_cl.deinit();

            const env = try monaco.Environment.init();
            defer env.deinit();
            try env.setGlobalApi(false);
            try env.setGetWorkerUrl(&url_cl);
            try env.setGetWorker(&wk_cl);
            try monaco.monaco_environment.set(env);

            const doc = try dom.document.get();
            defer doc.deinit();
            if (try doc.getElementById("container")) |container| {
                defer container.deinit();
                const ed = try monaco.editor.create(container, options, null);
                defer ed.deinit();
                try ed.setValue("updated");
                try ed.dispose();
            }
        }
    };
    _ = &SemaCheck.check;
}
