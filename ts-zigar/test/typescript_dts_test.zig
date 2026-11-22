const std = @import("std");
const ts_zigar = @import("ts_zigar");
const test_options = @import("test_options");

fn fileExists(path: []const u8) bool {
    const io = std.testing.io;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn resolveTestComponentWasm() ?[]const u8 {
    const candidates = [_][]const u8{
        "component/dist/typescript-compiler.component.wasm",
        "ts-zigar/component/dist/typescript-compiler.component.wasm",
    };
    if (std.testing.environ.getPosix("TS_ZIGAR_COMPONENT_WASM")) |env_path| {
        if (fileExists(env_path)) return env_path;
    }
    for (candidates) |cand| {
        if (fileExists(cand)) return cand;
    }
    return null;
}

fn isTruthyEnv(name: [:0]const u8) bool {
    if (std.testing.environ.getPosix(name)) |raw| {
        return std.ascii.eqlIgnoreCase(raw, "1") or
            std.ascii.eqlIgnoreCase(raw, "true") or
            std.ascii.eqlIgnoreCase(raw, "yes");
    }
    return false;
}

fn requireTs71Prerequisites() bool {
    return test_options.require_ts71 or isTruthyEnv("TS_ZIGAR_REQUIRE_TS71");
}

fn resolveTypescript71PkgDir(alloc: std.mem.Allocator) !?[]const u8 {
    if (std.testing.environ.getPosix("TS_ZIGAR_TYPESCRIPT_PKG")) |env_dir| {
        if (env_dir.len > 0) {
            const pkg_json = try std.fs.path.join(alloc, &.{ env_dir, "package.json" });
            defer alloc.free(pkg_json);
            if (fileExists(pkg_json)) return try alloc.dupe(u8, env_dir);
            const nm_pkg = try std.fs.path.join(alloc, &.{ env_dir, "node_modules", "typescript" });
            const nm_json = try std.fs.path.join(alloc, &.{ nm_pkg, "package.json" });
            defer alloc.free(nm_json);
            if (fileExists(nm_json)) return nm_pkg;
            alloc.free(nm_pkg);
        }
    }
    if (std.testing.environ.getPosix("TS_ZIGAR_CACHE_DIR")) |cache_dir| {
        if (cache_dir.len > 0) {
            const cache_pkg = try std.fs.path.join(alloc, &.{ cache_dir, "typescript-71-pkg", "node_modules", "typescript" });
            const cache_json = try std.fs.path.join(alloc, &.{ cache_pkg, "package.json" });
            defer alloc.free(cache_json);
            if (fileExists(cache_json)) return cache_pkg;
            alloc.free(cache_pkg);
        }
    }
    const candidates = [_][]const u8{
        "component/dist/typescript-71-pkg/node_modules/typescript",
        "ts-zigar/component/dist/typescript-71-pkg/node_modules/typescript",
        "../.cache/ts-zigar/typescript-71-pkg/node_modules/typescript",
        ".cache/ts-zigar/typescript-71-pkg/node_modules/typescript",
        "../../.cache/ts-zigar/typescript-71-pkg/node_modules/typescript",
    };
    for (candidates) |cand| {
        const pkg_json = try std.fs.path.join(alloc, &.{ cand, "package.json" });
        defer alloc.free(pkg_json);
        if (fileExists(pkg_json)) return try alloc.dupe(u8, cand);
    }
    return null;
}

fn resolveNodeExe() []const u8 {
    if (std.testing.environ.getPosix("TS_ZIGAR_NODE")) |node_path| {
        if (node_path.len > 0) return node_path;
    }
    return "node";
}

fn resolveTmpRoot() []const u8 {
    if (std.testing.environ.getPosix("TMPDIR")) |t| {
        if (t.len > 0) return t;
    }
    return "../.cache/tmp";
}

fn runZigCheck(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(allocator);

    if (child.stdout) |*so| {
        var rbuf: [4096]u8 = undefined;
        var reader = so.readerStreaming(io, &rbuf);
        reader.interface.appendRemainingUnlimited(allocator, &out_buf) catch {};
    }
    if (child.stderr) |*se| {
        var rbuf: [4096]u8 = undefined;
        var reader = se.readerStreaming(io, &rbuf);
        reader.interface.appendRemainingUnlimited(allocator, &err_buf) catch {};
    }

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("Command failed ({s}):\nSTDOUT:\n{s}\nSTDERR:\n{s}\n", .{
            argv[0],
            out_buf.items,
            err_buf.items,
        });
        return error.ZigCheckFailed;
    }
}

fn collectZigFiles(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, rel_prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    const dir_path = if (rel_prefix.len == 0)
        try allocator.dupe(u8, root_path)
    else
        try std.fs.path.join(allocator, &.{ root_path, rel_prefix });
    defer allocator.free(dir_path);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const rel = if (rel_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
        errdefer allocator.free(rel);

        switch (entry.kind) {
            .directory => {
                try collectZigFiles(allocator, io, root_path, rel, out);
                allocator.free(rel);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const full = try std.fs.path.join(allocator, &.{ root_path, rel });
                    allocator.free(rel);
                    try out.append(allocator, full);
                } else {
                    allocator.free(rel);
                }
            },
            else => allocator.free(rel),
        }
    }
}

test "M3.4a torture test: generate and compile Zig 0.17 bindings for TypeScript 7.1's entire .d.ts surface" {
    const must_run = requireTs71Prerequisites();
    const comp_wasm = resolveTestComponentWasm() orelse {
        if (must_run) {
            std.debug.print("Missing typescript-compiler.component.wasm while require_ts71 is enabled\n", .{});
            return error.MissingTypeScript71Component;
        }
        return error.SkipZigTest;
    };
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const ts_pkg_dir = (try resolveTypescript71PkgDir(alloc)) orelse {
        if (must_run) {
            std.debug.print("Missing staged TypeScript 7.1 package while require_ts71 is enabled\n", .{});
            return error.MissingTypeScript71Package;
        }
        return error.SkipZigTest;
    };
    defer alloc.free(ts_pkg_dir);

    const out_dir = try std.fs.path.join(alloc, &.{ resolveTmpRoot(), "ts-zigar-m3-ts71-torture-test" });
    defer alloc.free(out_dir);
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = comp_wasm,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const cli_args = [_][]const u8{
        "-t", ts_pkg_dir,
        "-d", out_dir,
    };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed == .run);

    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);
    try std.testing.expect(res.ok.module_count >= 85);

    var zig_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (zig_files.items) |p| alloc.free(p);
        zig_files.deinit(alloc);
    }
    try collectZigFiles(alloc, io, out_dir, "", &zig_files);
    try std.testing.expect(zig_files.items.len >= 85);

    for (zig_files.items) |zf| {
        try runZigCheck(alloc, io, &.{ test_options.zig_exe, "ast-check", zf });
    }

    const deep_sema_zig = try std.fs.path.join(alloc, &.{ out_dir, "__torture_deep_sema.zig" });
    defer alloc.free(deep_sema_zig);
    {
        const sema_src =
            \\const std = @import("std");
            \\const root = @import("root.zig");
            \\
            \\fn forceDeep(comptime T: type, comptime depth: usize) void {
            \\    if (depth == 0) return;
            \\    switch (@typeInfo(T)) {
            \\        .@"struct" => {
            \\            inline for (comptime std.meta.declarations(T)) |d| {
            \\                const val = @field(T, d);
            \\                if (@TypeOf(val) == type) {
            \\                    forceDeep(val, depth - 1);
            \\                } else {
            \\                    _ = &val;
            \\                }
            \\            }
            \\        },
            \\        .@"enum", .@"union" => {
            \\            inline for (comptime std.meta.declarations(T)) |d| {
            \\                const val = @field(T, d);
            \\                _ = &val;
            \\            }
            \\        },
            \\        else => {},
            \\    }
            \\}
            \\
            \\test "TypeScript 7.1 3-level Sema + subpath exports + NodeArray + SnapshotOperationParams" {
            \\    @setEvalBranchQuota(50_000_000);
            \\    forceDeep(root, 3);
            \\
            \\    try std.testing.expectEqualStrings("typescript/sync", root.typescript_sync.zigar_js.wire_specifier);
            \\    try std.testing.expectEqualStrings("typescript/fs", root.typescript_fs.zigar_js.wire_specifier);
            \\    try std.testing.expectEqualStrings("typescript/ast", root.typescript_ast.zigar_js.wire_specifier);
            \\    try std.testing.expectEqualStrings("typescript/ast/is", root.typescript_ast_is.zigar_js.wire_specifier);
            \\
            \\    const StmtArr = root.typescript_ast.NodeArray(root.typescript_ast.Statement);
            \\    try std.testing.expect(@hasDecl(StmtArr, "iterator"));
            \\    try std.testing.expect(@hasDecl(StmtArr, "pos"));
            \\    try std.testing.expect(@hasDecl(StmtArr, "end"));
            \\    try std.testing.expect(@hasDecl(StmtArr, "deinit"));
            \\
            \\    const SnapParams = root.typescript_sync.SnapshotOperationParams(root.typescript_sync.CreateSnapshotParams, void, void);
            \\    try std.testing.expect(@hasField(SnapParams, "file_system"));
            \\    try std.testing.expect(@hasField(SnapParams, "open_projects"));
            \\    try std.testing.expect(@hasField(SnapParams, "create_programs"));
            \\    try std.testing.expect(@hasField(SnapParams, "open_files"));
            \\
            \\    try std.testing.expectEqual(@as(i64, 105), root.typescript_ast.SyntaxKind.null_keyword.toInt());
            \\    try std.testing.expectEqual(
            \\        root.typescript_ast.SyntaxKind.asterisk_asterisk_token.toInt(),
            \\        root.typescript_ast.ExponentiationOperator.asterisk_asterisk_token.toInt(),
            \\    );
            \\}
            \\
        ;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = deep_sema_zig, .data = sema_src });
    }
    defer std.Io.Dir.cwd().deleteFile(io, deep_sema_zig) catch {};

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", deep_sema_zig });

    // Direct file-mode Sema verification on TypeScript 7.1's `dist/api/sync/generatorSupport.d.ts`:
    // verifies `cacheGeneratorMethod<Sync, Gen>(...): Sync & { readonly gen: Gen }` synthesizes a
    // handle+plain-struct `IntersectHandleWrapper` preserving both `Sync` and `.gen`.
    const gen_support_dts = try std.fs.path.join(alloc, &.{ ts_pkg_dir, "dist", "api", "sync", "generatorSupport.d.ts" });
    defer alloc.free(gen_support_dts);
    const gen_support_out = try std.fs.path.join(alloc, &.{ resolveTmpRoot(), "ts-zigar-m3-ts71-gensupport-test" });
    defer alloc.free(gen_support_out);
    std.Io.Dir.cwd().deleteTree(io, gen_support_out) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, gen_support_out) catch {};

    const gs_args = [_][]const u8{
        "-t", gen_support_dts,
        "-m", "generatorSupport",
        "-d", gen_support_out,
    };
    var gs_parsed = try ts_zigar.cli.parseArgs(alloc, &gs_args);
    defer gs_parsed.deinit(alloc);
    var gs_res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &gs_parsed.run);
    defer gs_res.deinit(alloc);
    if (gs_res == .err) {
        std.debug.print("generatorSupport pipeline error: {s}\n", .{gs_res.err});
    }
    try std.testing.expect(gs_res == .ok);

    const gs_sema_zig = try std.fs.path.join(alloc, &.{ gen_support_out, "__gensupport_sema.zig" });
    defer alloc.free(gs_sema_zig);
    {
        const gs_sema_src =
            \\const std = @import("std");
            \\const root = @import("root.zig");
            \\const js = root.zigar_js;
            \\const gs = root.generator_support;
            \\
            \\test "generatorSupport cacheGeneratorMethod returns IntersectHandleWrapper(Sync, struct { gen: Gen })" {
            \\    const SyncCb = js.Callback(fn (f64) f64);
            \\    const GenCb = js.Callback(fn (f64) gs.AnyApiRequestGenerator(f64));
            \\    _ = &gs.cacheGeneratorMethod;
            \\    const CallFnT = @TypeOf(gs.cacheGeneratorMethod);
            \\    try std.testing.expect(@typeInfo(CallFnT) == .@"fn");
            \\    const CallExprT = @TypeOf(gs.cacheGeneratorMethod(
            \\        SyncCb,
            \\        GenCb,
            \\        js.Object.globalThis,
            \\        .{ .str = "next" },
            \\        @as(SyncCb, undefined),
            \\        @as(GenCb, undefined),
            \\    ));
            \\    const RetT = @typeInfo(CallExprT).error_union.payload;
            \\    try std.testing.expect(RetT.is_zigar_intersect_handle);
            \\    try std.testing.expect(@hasDecl(RetT, "as"));
            \\    try std.testing.expect(@hasDecl(RetT, "get"));
            \\    try std.testing.expect(RetT.FieldType("gen") == GenCb);
            \\    try std.testing.expect(js.IndexAccess(RetT, enum { gen }) == GenCb);
            \\}
            \\
        ;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gs_sema_zig, .data = gs_sema_src });
    }
    defer std.Io.Dir.cwd().deleteFile(io, gs_sema_zig) catch {};
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", gs_sema_zig });
}
