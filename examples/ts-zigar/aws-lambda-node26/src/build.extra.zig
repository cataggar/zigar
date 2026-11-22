const std = @import("std");
const cfg = @import("build.cfg.zig");

pub fn getImports(b: *std.Build, args: anytype) []const std.Build.Module.Import {
    const aws_lambda_root_path = std.fs.path.resolve(b.allocator, &.{
        cfg.module_dir,
        "../generated/root.zig",
    }) catch @panic("OOM");
    const aws_lambda_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = aws_lambda_root_path },
        .imports = &.{
            .{ .name = "zigar", .module = args.zigar },
        },
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aws_lambda", .module = aws_lambda_mod },
    }) catch @panic("OOM");
}
