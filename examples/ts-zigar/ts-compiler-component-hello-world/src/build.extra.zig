const std = @import("std");
const cfg = @import("build.cfg.zig");

pub fn getImports(b: *std.Build, args: anytype) []const std.Build.Module.Import {
    const wit_main_path = std.fs.path.resolve(b.allocator, &.{
        cfg.module_dir,
        "../../../../wit-zigar/src/main.zig",
    }) catch @panic("OOM");
    const wit_root_path = std.fs.path.resolve(b.allocator, &.{
        cfg.module_dir,
        "../../../../wit-zigar/src/root.zig",
    }) catch @panic("OOM");
    const ts_wit_path = std.fs.path.resolve(b.allocator, &.{
        cfg.module_dir,
        "../../../../ts-zigar/wit/typescript.wit",
    }) catch @panic("OOM");

    const wit_zigar_exe = b.addExecutable(.{
        .name = "wit-zigar",
        .root_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = wit_main_path },
            .target = b.graph.host,
            .optimize = .Debug,
            .strip = if (b.graph.host.result.cpu.arch == .aarch64 and (@import("builtin").zig_backend == .stage2_aarch64)) true else null,
        }),
    });

    const gen_cmd = b.addRunArtifact(wit_zigar_exe);
    gen_cmd.addFileArg(.{ .cwd_relative = ts_wit_path });
    gen_cmd.addArgs(&.{ "--world", "typescript-compiler", "-o" });
    const generated_ts = gen_cmd.addOutputFileArg("generated_ts.zig");

    const wit_zigar_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = wit_root_path },
        .target = args.target,
        .optimize = args.optimize,
    });
    const generated_ts_mod = b.createModule(.{
        .root_source_file = generated_ts,
        .target = args.target,
        .optimize = args.optimize,
    });

    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "wit_zigar", .module = wit_zigar_mod },
        .{ .name = "generated_ts", .module = generated_ts_mod },
    }) catch @panic("OOM");
}
