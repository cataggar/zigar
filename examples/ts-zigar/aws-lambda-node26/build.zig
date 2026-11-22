const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const aws_lambda_mod = b.addModule("aws_lambda", .{
        .root_source_file = b.path("generated/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bindings_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aws_lambda", .module = aws_lambda_mod },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Compile-check generated @types/aws-lambda + @types/node@26 Zig bindings");
    test_step.dependOn(&run_tests.step);
}
