const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_aarch64_host = target.result.cpu.arch == .aarch64 and (@import("builtin").zig_backend == .stage2_aarch64);
    const strip: ?bool = if (is_aarch64_host) true else null;
    const use_llvm: ?bool = if (is_aarch64_host) false else null;

    // 1. `wit-zigar` runtime module + `zigar wit` CLI generator
    const wit_zigar_mod = b.createModule(.{
        .root_source_file = b.path("../../../wit-zigar/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    wit_zigar_mod.addAnonymousImport("sample_wit", .{
        .root_source_file = b.path("../../../wit-zigar/test/fixtures/sample.wit"),
    });

    const wit_zigar_exe = b.addExecutable(.{
        .name = "wit-zigar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../../../wit-zigar/src/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .strip = if (b.graph.host.result.cpu.arch == .aarch64 and (@import("builtin").zig_backend == .stage2_aarch64)) true else null,
        }),
    });

    // 2. Generate Zig 0.17 WIT bindings for `zigar:typescript@7.1.0` (`world typescript-compiler`)
    const gen_ts_cmd = b.addRunArtifact(wit_zigar_exe);
    gen_ts_cmd.addFileArg(b.path("../../../ts-zigar/wit/typescript.wit"));
    gen_ts_cmd.addArgs(&.{ "--world", "typescript-compiler", "-o" });
    const generated_ts = gen_ts_cmd.addOutputFileArg("generated_ts.zig");

    const install_wit_bindings = b.addInstallFileWithDir(generated_ts, .prefix, "wit/generated_ts.zig");
    const wit_step = b.step("wit", "Generate Zig 0.17 WIT bindings for zigar:typescript@7.1.0");
    wit_step.dependOn(&install_wit_bindings.step);

    // 3. Ensure `typescript-compiler.component.wasm` is built automatically if missing/stale
    //    (reuses `TS_ZIGAR_CACHE_DIR` and outputs to gitignored `ts-zigar/component/dist/`)
    const component_wasm_abs = b.root.joinString(
        b.allocator,
        "../../../ts-zigar/component/dist/typescript-compiler.component.wasm",
    ) catch @panic("OOM");
    const build_component_script_abs = b.root.joinString(
        b.allocator,
        "../../../ts-zigar/component/build-component.mjs",
    ) catch @panic("OOM");

    const build_component_cmd = b.addSystemCommand(&.{
        "node",
        build_component_script_abs,
        "-o",
        component_wasm_abs,
    });
    build_component_cmd.has_side_effects = true;
    const component_step = b.step("component", "Build TypeScript 7.1 Go WASM Component if missing");
    component_step.dependOn(&build_component_cmd.step);
    b.getInstallStep().dependOn(&build_component_cmd.step);

    // 4. Shared example library module (`src/lib.zig`)
    const hello_lib_mod = b.addModule("hello_lib", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    hello_lib_mod.addImport("wit_zigar", wit_zigar_mod);
    hello_lib_mod.addAnonymousImport("generated_ts", .{
        .root_source_file = generated_ts,
    });

    // Cross-target compile check: verify `src/lib.zig` (including `DebugAllocator(.{ .safety = true })`)
    // compiles cleanly to both `wasm32-wasi` and `wasm32-freestanding`
    const wasm32_wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const wit_zigar_wasm_mod = b.createModule(.{
        .root_source_file = b.path("../../../wit-zigar/src/root.zig"),
        .target = wasm32_wasi_target,
        .optimize = .ReleaseSafe,
    });
    const hello_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = wasm32_wasi_target,
        .optimize = .ReleaseSafe,
    });
    hello_wasm_mod.addImport("wit_zigar", wit_zigar_wasm_mod);
    hello_wasm_mod.addAnonymousImport("generated_ts", .{
        .root_source_file = generated_ts,
    });
    const wasm_check_obj = b.addObject(.{
        .name = "ts-compiler-hello-wasm32-check",
        .root_module = hello_wasm_mod,
    });

    const wasm32_free_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wit_zigar_free_mod = b.createModule(.{
        .root_source_file = b.path("../../../wit-zigar/src/root.zig"),
        .target = wasm32_free_target,
        .optimize = .ReleaseSafe,
    });
    const hello_free_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = wasm32_free_target,
        .optimize = .ReleaseSafe,
    });
    hello_free_mod.addImport("wit_zigar", wit_zigar_free_mod);
    hello_free_mod.addAnonymousImport("generated_ts", .{
        .root_source_file = generated_ts,
    });
    const wasm_free_check_obj = b.addObject(.{
        .name = "ts-compiler-hello-wasm32-free-check",
        .root_module = hello_free_mod,
    });

    const wasm_check_files = b.addWriteFiles();
    _ = wasm_check_files.addCopyFile(wasm_check_obj.getEmittedBin(), "ts-compiler-hello-wasm32-check.o");
    _ = wasm_check_files.addCopyFile(wasm_free_check_obj.getEmittedBin(), "ts-compiler-hello-wasm32-free-check.o");

    // 5. Build options for native executable & integration tests
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "default_component_path", component_wasm_abs);
    build_opts.addOption([]const u8, "build_component_script_path", build_component_script_abs);
    build_opts.addOption([]const u8, "default_node_exe", "node");

    // 6. Native CLI showcase (`zig build run`)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe_mod.addImport("hello_lib", hello_lib_mod);
    exe_mod.addOptions("build_options", build_opts);

    const exe = b.addExecutable(.{
        .name = "ts-compiler-component-hello-world",
        .root_module = exe_mod,
        .use_llvm = use_llvm,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    run_exe.step.dependOn(&build_component_cmd.step);
    run_exe.addPassthruArgs();

    const run_step = b.step("run", "Run the TypeScript 7.1 Go WASM Component showcase from Zig");
    run_step.dependOn(&run_exe.step);

    // 7. End-to-end Zig test suite (`zig build test`)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/example_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    test_mod.addImport("hello_lib", hello_lib_mod);
    test_mod.addOptions("build_options", build_opts);

    const example_tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = use_llvm,
    });
    const run_example_tests = b.addRunArtifact(example_tests);
    run_example_tests.has_side_effects = true;
    run_example_tests.step.dependOn(&build_component_cmd.step);

    const test_step = b.step("test", "Run end-to-end TypeScript 7.1 component tests with GPA leak checking");
    test_step.dependOn(&wasm_check_files.step);
    test_step.dependOn(&run_example_tests.step);
}
