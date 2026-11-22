const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_aarch64_host = target.result.cpu.arch == .aarch64 and (@import("builtin").zig_backend == .stage2_aarch64);
    const strip: ?bool = if (is_aarch64_host) true else null;
    const use_llvm: ?bool = if (is_aarch64_host) false else null;

    const gen_cmd = b.addSystemCommand(&.{
        "node",
        "../monaco-editor/generate.mjs",
        "--quiet",
    });
    gen_cmd.setCwd(b.path(""));

    const web_mod = b.createModule(.{
        .root_source_file = b.path("../monaco-editor/generated/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    app_mod.addImport("web", web_mod);

    const check_mod = b.createModule(.{
        .root_source_file = b.path("test/app_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    check_mod.addImport("web", web_mod);
    check_mod.addImport("app", app_mod);

    const check_tests = b.addTest(.{
        .root_module = check_mod,
        .use_llvm = use_llvm,
    });
    check_tests.step.dependOn(&gen_cmd.step);

    const run_check_tests = b.addRunArtifact(check_tests);
    run_check_tests.setCwd(b.path(""));

    const test_step = b.step("test", "Generate bindings and compile-check monaco-editor-hello-world Zig app");
    test_step.dependOn(&run_check_tests.step);
}
