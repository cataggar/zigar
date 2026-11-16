const std = @import("std");
const build_options = @import("build_options");
const hello_lib = @import("hello_lib");

pub fn main(init: std.process.Init) u8 {
    return runMain(init) catch |err| {
        writeStderr(init.io, "ts-compiler-component-hello-world failed: ");
        writeStderr(init.io, @errorName(err));
        writeStderr(init.io, "\n");
        return 1;
    };
}

fn runMain(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const node_exe = resolveNodeExe(init.environ_map);
    const component_path = try resolveOrBuildComponent(allocator, io, init.environ_map, node_exe);
    defer allocator.free(component_path);

    const report = try hello_lib.native.runDemo(allocator, io, component_path, node_exe);
    defer report.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try appendFmt(&out, allocator, "=== TypeScript 7.1 Go WASM Component Showcase (Native Zig) ===\n", .{});
    try appendFmt(&out, allocator, "Compiler version: {s}\n", .{report.compiler_version});
    try appendFmt(
        &out,
        allocator,
        "Valid program diagnostics: {d} syntactic, {d} semantic\n\n",
        .{ report.syntactic_diagnostic_count, report.semantic_diagnostic_count },
    );

    try appendFmt(&out, allocator, "--- Checker Inspection ({s}) ---\n", .{hello_lib.index_ts_path});
    try appendFmt(&out, allocator, "summarizeBatch type: {s}\n", .{report.inferred_expression_type});
    try appendFmt(&out, allocator, "Exported symbols ({d}):\n", .{report.exported_symbols.len});
    for (report.exported_symbols) |sym| {
        try appendFmt(&out, allocator, "  - {s}: {s}\n", .{ sym.name, sym.type_text });
    }

    try appendFmt(&out, allocator, "\n--- Emitted Declarations ({d} files) ---\n", .{report.emitted_declarations.len});
    for (report.emitted_declarations) |decl| {
        try appendFmt(&out, allocator, "[{s}]\n{s}\n", .{ decl.file_name, decl.contents });
    }

    try appendFmt(&out, allocator, "--- Transpiled JavaScript ({s}) ---\n{s}\n", .{
        hello_lib.index_ts_path,
        report.transpiled_js,
    });

    try appendFmt(
        &out,
        allocator,
        "--- Intentional Type Error Check ({s}, {d} diagnostic) ---\n",
        .{ hello_lib.broken_ts_path, report.broken_diagnostic_count },
    );
    try appendFmt(
        &out,
        allocator,
        "TS{d} at {s}:{d}:{d} - {s}\n\n",
        .{
            report.broken_diagnostic.code,
            report.broken_diagnostic.file_name,
            report.broken_diagnostic.line,
            report.broken_diagnostic.column,
            report.broken_diagnostic.message,
        },
    );

    try appendFmt(
        &out,
        allocator,
        "Live WIT resources after cleanup: {d}\n",
        .{report.live_resources_after_drop},
    );

    writeStdout(io, out.items);
    return 0;
}

fn appendFmt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try buf.appendSlice(allocator, formatted);
}

fn resolveNodeExe(env_map: *const std.process.Environ.Map) []const u8 {
    if (env_map.get("TS_ZIGAR_NODE")) |n| {
        if (n.len > 0) return n;
    }
    if (build_options.default_node_exe.len > 0) return build_options.default_node_exe;
    return "node";
}

fn fileExists(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn resolveOrBuildComponent(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    node_exe: []const u8,
) ![]u8 {
    if (env_map.get("TS_ZIGAR_COMPONENT_PATH")) |p| {
        if (fileExists(io, p)) return allocator.dupe(u8, p);
    }
    if (env_map.get("TS_ZIGAR_COMPONENT_WASM")) |p| {
        if (fileExists(io, p)) return allocator.dupe(u8, p);
    }
    if (fileExists(io, build_options.default_component_path)) {
        return allocator.dupe(u8, build_options.default_component_path);
    }

    if (build_options.build_component_script_path.len > 0 and
        fileExists(io, build_options.build_component_script_path))
    {
        var child = try std.process.spawn(io, .{
            .argv = &.{
                node_exe,
                build_options.build_component_script_path,
                "-o",
                build_options.default_component_path,
            },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(io);
        if (term == .exited and term.exited == 0 and fileExists(io, build_options.default_component_path)) {
            return allocator.dupe(u8, build_options.default_component_path);
        }
    }

    return error.ComponentWasmNotFound;
}

fn writeStdout(io: std.Io, bytes: []const u8) void {
    const f = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = f.writerStreaming(io, &buf);
    fw.interface.writeAll(bytes) catch return;
    fw.interface.flush() catch return;
}

fn writeStderr(io: std.Io, bytes: []const u8) void {
    const f = std.Io.File.stderr();
    var buf: [4096]u8 = undefined;
    var fw = f.writerStreaming(io, &buf);
    fw.interface.writeAll(bytes) catch return;
    fw.interface.flush() catch return;
}
