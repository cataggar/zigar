const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_aarch64_host = target.result.cpu.arch == .aarch64 and (@import("builtin").zig_backend == .stage2_aarch64);
    const strip: ?bool = if (is_aarch64_host) true else null;
    const use_llvm: ?bool = if (is_aarch64_host) false else null;

    const gen_cmd = b.addSystemCommand(&.{
        "node",
        "generate.mjs",
        "--quiet",
    });
    gen_cmd.setCwd(b.path(""));

    const web_mod = b.createModule(.{
        .root_source_file = b.path("generated/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const check_mod = b.createModule(.{
        .root_source_file = b.path("test/bindings_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    check_mod.addImport("web", web_mod);

    const check_tests = b.addTest(.{
        .root_module = check_mod,
        .use_llvm = use_llvm,
    });
    check_tests.step.dependOn(&gen_cmd.step);

    const run_check_tests = b.addRunArtifact(check_tests);
    run_check_tests.setCwd(b.path(""));

    const test_step = b.step("test", "Generate and compile-check dom + monaco-editor Zig 0.17 bindings");
    test_step.dependOn(&run_check_tests.step);
}
