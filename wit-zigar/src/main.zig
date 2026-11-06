//! CLI entry point for `wit-zigar`: WIT-to-Zig binding generator.
//!
//! Usage:
//!   wit-zigar <file.wit | dir> [--world <name>] [--wasm64] [-o <output.zig>]
//!   wit-zigar --wasi <ns:pkg/world@ver> [--wasm64] [-o <output.zig>]
//!   wit-zigar --help

const std = @import("std");
const bindgen = @import("bindgen.zig");

const usage_text =
    \\Usage:
    \\  wit-zigar <file.wit | dir> [--world <name>] [--wasm64] [-o <output.zig>]
    \\  wit-zigar --wasi <ns:pkg/world[@ver]> [--wasm64] [-o <output.zig>]
    \\  wit-zigar --help
    \\
    \\Options:
    \\  --world <name>             Select target WIT world name
    \\  --wasi <ns:pkg/world@ver>  Generate bindings for an embedded WASI world
    \\                             (e.g. wasi:cli/command@0.3.0)
    \\  --wasm64                   Emit Memory64 (cm64) pointer/slice signatures
    \\  -o <output.zig>            Write generated Zig code to file instead of stdout
    \\  -h, --help                 Display this help and exit
    \\
;

pub const CliArgs = struct {
    help: bool = false,
    input_path: ?[]const u8 = null,
    wasi_spec: ?[]const u8 = null,
    world_name: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    arch: bindgen.Arch = .wasm32,
};

pub fn parseCliArgs(args: []const []const u8) !CliArgs {
    var parsed: CliArgs = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed.help = true;
            return parsed;
        } else if (std.mem.eql(u8, arg, "--wasm64")) {
            parsed.arch = .wasm64;
        } else if (std.mem.eql(u8, arg, "--world")) {
            i += 1;
            if (i >= args.len) return error.MissingWorldArgument;
            parsed.world_name = args[i];
        } else if (std.mem.eql(u8, arg, "--wasi")) {
            i += 1;
            if (i >= args.len) return error.MissingWasiArgument;
            if (parsed.wasi_spec != null) return error.ConflictingInputOptions;
            parsed.wasi_spec = args[i];
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputArgument;
            parsed.output_path = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (parsed.input_path != null) return error.DuplicateInputPath;
            parsed.input_path = arg;
        } else {
            return error.UnknownOption;
        }
    }
    if (parsed.wasi_spec != null and parsed.input_path != null) {
        return error.ConflictingInputOptions;
    }
    return parsed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());

    const parsed = try parseCliArgs(args);
    if (parsed.help) {
        try writeStdout(io, usage_text);
        return;
    }

    const opts = bindgen.BindgenOptions{
        .world_name = parsed.world_name,
        .arch = parsed.arch,
        .emit_runtime_helpers = true,
    };

    const generated = if (parsed.wasi_spec) |spec|
        try bindgen.generateWasiWorldBySpec(allocator, spec, opts)
    else if (parsed.input_path) |path|
        try generateFromPath(allocator, io, path, opts)
    else {
        try writeStdout(io, usage_text);
        return;
    };
    defer allocator.free(generated);

    if (parsed.output_path) |out_path| {
        const cwd = std.Io.Dir.cwd();
        var file = try cwd.createFile(io, out_path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(generated);
        try fw.interface.flush();
    } else {
        try writeStdout(io, generated);
    }
}

fn readWitDirAsDocument(
    ar: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_label: []const u8,
) !bindgen.ast.Document {
    var sources: std.ArrayList(bindgen.resolver_mod.WitSource) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wit")) continue;
        const name_copy = try ar.dupe(u8, entry.name);
        const text = try dir.readFileAlloc(io, name_copy, ar, .limited(16 * 1024 * 1024));
        try sources.append(ar, .{ .path = name_copy, .text = text });
    }

    const SortCtx = struct {
        pub fn lessThan(_: void, a: bindgen.resolver_mod.WitSource, b: bindgen.resolver_mod.WitSource) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    };
    std.mem.sort(bindgen.resolver_mod.WitSource, sources.items, {}, SortCtx.lessThan);

    const combined = try bindgen.resolver_mod.combineWitSources(ar, sources.items, dir_label, null);
    if (combined.text.len == 0) return error.EmptyWit;
    return bindgen.parser.parse(ar, combined.text, null);
}

fn generateFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    opts: bindgen.BindgenOptions,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    if (std.mem.endsWith(u8, path, ".wit")) {
        const content = try cwd.readFileAlloc(io, path, ar, .limited(16 * 1024 * 1024));
        return bindgen.generateFromWitSource(allocator, content, opts);
    }

    // Directory of `.wit` files (plus optional `deps/<subpkg>/*.wit`).
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    const main_doc = try readWitDirAsDocument(ar, io, dir, path);

    var dep_docs: std.ArrayList(bindgen.ast.Document) = .empty;
    if (dir.openDir(io, "deps", .{ .iterate = true })) |deps_dir_val| {
        var deps_dir = deps_dir_val;
        defer deps_dir.close(io);

        var subdirs: std.ArrayList([]const u8) = .empty;
        var direct_files: std.ArrayList([]const u8) = .empty;
        var deps_iter = deps_dir.iterate();
        while (try deps_iter.next(io)) |entry| {
            if (entry.kind == .directory) {
                try subdirs.append(ar, try ar.dupe(u8, entry.name));
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wit")) {
                try direct_files.append(ar, try ar.dupe(u8, entry.name));
            }
        }

        const StrSort = struct {
            pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        };
        std.mem.sort([]const u8, subdirs.items, {}, StrSort.lessThan);
        std.mem.sort([]const u8, direct_files.items, {}, StrSort.lessThan);

        for (subdirs.items) |sub_name| {
            var sub_dir = try deps_dir.openDir(io, sub_name, .{ .iterate = true });
            defer sub_dir.close(io);
            const dep_doc = try readWitDirAsDocument(ar, io, sub_dir, sub_name);
            try dep_docs.append(ar, dep_doc);
        }

        for (direct_files.items) |file_name| {
            const text = try deps_dir.readFileAlloc(io, file_name, ar, .limited(16 * 1024 * 1024));
            const dep_doc = try bindgen.parser.parse(ar, text, null);
            try dep_docs.append(ar, dep_doc);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const res = try bindgen.resolver_mod.finishWithEmbedded(ar, main_doc, dep_docs.items);
    return bindgen.generateFromResolver(allocator, res, opts);
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    const stdout_file = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = stdout_file.writer(io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

test "cli main entry point and world spec parsing" {
    _ = &main;
    const spec = bindgen.parseWorldSpec("wasi:cli/command@0.3.0").?;
    try std.testing.expectEqualStrings("wasi", spec.namespace);
    try std.testing.expectEqualStrings("cli", spec.pkg_name);
    try std.testing.expectEqualStrings("command", spec.world_name);
    try std.testing.expectEqualStrings("0.3.0", spec.version.?);

    try std.testing.expectError(
        error.DuplicateInputPath,
        parseCliArgs(&.{ "wit-zigar", "a.wit", "b.wit" }),
    );
    try std.testing.expectError(
        error.ConflictingInputOptions,
        parseCliArgs(&.{ "wit-zigar", "--wasi", "wasi:cli/imports@0.3.0", "a.wit" }),
    );

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const test_dir_path = "../.zig-cache/cli_deps_test_dir";
    cwd.deleteTree(io, test_dir_path) catch {};
    defer cwd.deleteTree(io, test_dir_path) catch {};

    try cwd.createDirPath(io, "../.zig-cache/cli_deps_test_dir/deps/dep-pkg");
    {
        var dep_file = try cwd.createFile(io, "../.zig-cache/cli_deps_test_dir/deps/dep-pkg/dep.wit", .{});
        defer dep_file.close(io);
        var buf: [256]u8 = undefined;
        var fw = dep_file.writer(io, &buf);
        try fw.interface.writeAll(
            \\package acme:dep-pkg@0.1.0;
            \\interface shared {
            \\    record token { id: u64 }
            \\}
        );
        try fw.interface.flush();
    }
    {
        var main_file = try cwd.createFile(io, "../.zig-cache/cli_deps_test_dir/main.wit", .{});
        defer main_file.close(io);
        var buf: [256]u8 = undefined;
        var fw = main_file.writer(io, &buf);
        try fw.interface.writeAll(
            \\package acme:app@0.1.0;
            \\interface api {
            \\    use acme:dep-pkg/shared@0.1.0.{token};
            \\    verify: func(t: token) -> bool;
            \\}
            \\world app-world {
            \\    import acme:dep-pkg/shared@0.1.0;
            \\    import api;
            \\}
        );
        try fw.interface.flush();
    }

    const generated = try generateFromPath(std.testing.allocator, io, test_dir_path, .{});
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const Token = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const verify_Fn =") != null);
}


