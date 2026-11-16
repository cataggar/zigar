const std = @import("std");
const builtin = @import("builtin");
const ts_zigar = @import("ts_zigar");

const build_options = if (!builtin.cpu.arch.isWasm())
    @import("build_options")
else
    struct {
        pub const default_component_path: []const u8 = "";
        pub const build_component_script_path: []const u8 = "";
        pub const default_node_exe: []const u8 = "node";
    };

pub fn main(init: std.process.Init) u8 {
    return runMain(init) catch |err| {
        writeStderr(init.io, "ts-zigar: fatal error: ");
        writeStderr(init.io, @errorName(err));
        writeStderr(init.io, "\n");
        return 1;
    };
}

fn runMain(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const full_args = try init.minimal.args.toSlice(init.arena.allocator());
    const user_args = if (full_args.len > 0) full_args[1..] else &[_][]const u8{};

    var outcome = try ts_zigar.cli.parseArgs(allocator, user_args);
    defer outcome.deinit(allocator);

    switch (outcome) {
        .help => {
            writeStdout(io, ts_zigar.cli.help_text);
            return 0;
        },
        .version => {
            writeStdout(io, "ts-zigar ");
            writeStdout(io, ts_zigar.cli.version_string);
            writeStdout(io, "\n");
            return 0;
        },
        .err => |msg| {
            writeStderr(io, "ts-zigar: ");
            writeStderr(io, msg);
            writeStderr(io, "\n");
            return 1;
        },
        .run => |*opts| {
            if (comptime builtin.cpu.arch.isWasm()) {
                if (opts.component_path) |explicit| {
                    if (!fileExists(io, explicit)) {
                        writeStderr(io, "ts-zigar: component WASM not found: ");
                        writeStderr(io, explicit);
                        writeStderr(io, "\n");
                        return 1;
                    }
                }
            }
            var ts_host = (if (comptime builtin.cpu.arch.isWasm())
                ts_zigar.TypeScriptHost.initWasmExtern(allocator)
            else
                instantiateNativeHost(allocator, io, init.environ_map, full_args, opts)) catch |err| {
                writeStderr(io, "ts-zigar: failed to initialize TypeScript 7.1 component host: ");
                writeStderr(io, @errorName(err));
                writeStderr(io, "\n");
                return 1;
            };
            defer ts_host.deinit();

            var res = try ts_zigar.driver.runPipelineWithHost(allocator, io, &ts_host, opts);
            defer res.deinit(allocator);

            switch (res) {
                .ok => return 0,
                .err => |msg| {
                    writeStderr(io, "ts-zigar: ");
                    writeStderr(io, msg);
                    if (msg.len == 0 or msg[msg.len - 1] != '\n') {
                        writeStderr(io, "\n");
                    }
                    return 1;
                },
            }
        },
    }
}

fn instantiateNativeHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    full_args: []const []const u8,
    opts: *const ts_zigar.cli.CliOptions,
) !ts_zigar.TypeScriptHost {
    const comp_path = try resolveNativeComponentPath(allocator, io, env_map, full_args, opts);
    defer allocator.free(comp_path);

    const node_exe = resolveNodeExe(env_map);
    return ts_zigar.TypeScriptHost.spawnNode(allocator, io, .{
        .wasm_path = comp_path,
        .node_binary = node_exe,
    });
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

fn resolveNativeComponentPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    full_args: []const []const u8,
    opts: *const ts_zigar.cli.CliOptions,
) ![]u8 {
    if (opts.component_path) |explicit| {
        if (!fileExists(io, explicit)) return error.ComponentWasmNotFound;
        return try allocator.dupe(u8, explicit);
    }

    if (env_map.get("TS_ZIGAR_COMPONENT_PATH")) |env_p| {
        if (fileExists(io, env_p)) return try allocator.dupe(u8, env_p);
    }
    if (env_map.get("TS_ZIGAR_COMPONENT_WASM")) |env_p| {
        if (fileExists(io, env_p)) return try allocator.dupe(u8, env_p);
    }

    const static_candidates = [_][]const u8{
        build_options.default_component_path,
        "component/dist/typescript-compiler.component.wasm",
        "dist/typescript-compiler.component.wasm",
        "ts-zigar/component/dist/typescript-compiler.component.wasm",
        "ts-zigar/dist/typescript-compiler.component.wasm",
    };
    for (static_candidates) |cand| {
        if (fileExists(io, cand)) return try allocator.dupe(u8, cand);
    }

    if (full_args.len > 0) {
        const argv0 = full_args[0];
        if (std.mem.lastIndexOfAny(u8, argv0, "/\\")) |slash| {
            const exe_dir = argv0[0..slash];
            const rel_candidates = [_][]const u8{
                "typescript-compiler.component.wasm",
                "../dist/typescript-compiler.component.wasm",
                "../component/dist/typescript-compiler.component.wasm",
                "../../dist/typescript-compiler.component.wasm",
                "../../component/dist/typescript-compiler.component.wasm",
            };
            for (rel_candidates) |rc| {
                const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ exe_dir, rc });
                if (fileExists(io, joined)) return joined;
                allocator.free(joined);
            }
        }
    }

    // Auto-build via `build-component.mjs` if available in the source tree!
    if (build_options.build_component_script_path.len > 0 and
        build_options.default_component_path.len > 0 and
        fileExists(io, build_options.build_component_script_path))
    {
        const node_exe = resolveNodeExe(env_map);
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
            return try allocator.dupe(u8, build_options.default_component_path);
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
