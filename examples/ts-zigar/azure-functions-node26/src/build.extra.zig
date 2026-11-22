const std = @import("std");
const cfg = @import("build.cfg.zig");

pub fn getImports(b: *std.Build, args: anytype) []const std.Build.Module.Import {
    const azure_root_path = std.fs.path.resolve(b.allocator, &.{
        cfg.module_dir,
        "../generated/root.zig",
    }) catch @panic("OOM");
    const azure_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = azure_root_path },
        .imports = &.{
            .{ .name = "zigar", .module = args.zigar },
        },
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "azure_functions", .module = azure_mod },
    }) catch @panic("OOM");
}
