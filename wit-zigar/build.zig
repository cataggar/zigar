const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("wit-zigar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addAnonymousImport("sample_wit", .{
        .root_source_file = b.path("test/fixtures/sample.wit"),
    });

    const exe = b.addExecutable(.{
        .name = "wit-zigar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the wit-zigar CLI");
    run_step.dependOn(&run_cmd.step);

    // 1. Unit + integration tests on `src/root.zig`
    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // 2. Build-time bindgen compilation + Canonical ABI round-trip tests
    const gen_wasi_cmd = b.addRunArtifact(exe);
    gen_wasi_cmd.addArgs(&.{ "--wasi", "wasi:cli/imports@0.3.0", "-o" });
    const generated_wasi_cli = gen_wasi_cmd.addOutputFileArg("generated_wasi_cli.zig");

    const gen_sample_cmd = b.addRunArtifact(exe);
    gen_sample_cmd.addFileArg(b.path("test/fixtures/sample.wit"));
    gen_sample_cmd.addArg("-o");
    const generated_sample = gen_sample_cmd.addOutputFileArg("generated_sample.zig");

    const gen_test_mod = b.createModule(.{
        .root_source_file = b.path("test/generated_bindings_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_test_mod.addImport("wit_zigar", mod);
    gen_test_mod.addAnonymousImport("generated_wasi_cli", .{
        .root_source_file = generated_wasi_cli,
    });
    gen_test_mod.addAnonymousImport("generated_sample", .{
        .root_source_file = generated_sample,
    });

    const gen_tests = b.addTest(.{
        .root_module = gen_test_mod,
    });
    const run_gen_tests = b.addRunArtifact(gen_tests);

    const test_step = b.step("test", "Run unit and build-time bindgen integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_gen_tests.step);
}
