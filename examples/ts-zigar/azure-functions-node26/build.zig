const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gen_cmd = b.addSystemCommand(&.{ "node", "generate.mjs", "--quiet" });
    gen_cmd.setCwd(b.path(""));
    gen_cmd.has_side_effects = true;
    const gen_step = b.step("generate", "Generate @azure/functions + @types/node@26 Zig bindings");
    gen_step.dependOn(&gen_cmd.step);

    const azure_functions_mod = b.addModule("azure_functions", .{
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
                .{ .name = "azure_functions", .module = azure_functions_mod },
            },
        }),
    });
    tests.step.dependOn(&gen_cmd.step);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Compile-check generated @azure/functions + @types/node@26 Zig bindings");
    test_step.dependOn(&run_tests.step);
}
