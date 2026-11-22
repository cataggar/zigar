const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const require_ts71 = b.option(
        bool,
        "require-ts71",
        "Build TypeScript 7.1 component + staged package and fail if M3.4a torture test prerequisites are missing",
    ) orelse false;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Optional test name filter(s) for zig build test",
    ) orelse &.{};
    const is_aarch64_host = target.result.cpu.arch == .aarch64 and (@import("builtin").zig_backend == .stage2_aarch64);
    const strip: ?bool = if (is_aarch64_host) true else null;
    const use_llvm: ?bool = if (is_aarch64_host) false else null;

    // `wit-zigar` library module & CLI generator tool
    const wit_zigar_mod = b.createModule(.{
        .root_source_file = b.path("../wit-zigar/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    wit_zigar_mod.addAnonymousImport("sample_wit", .{
        .root_source_file = b.path("../wit-zigar/test/fixtures/sample.wit"),
    });

    const wit_zigar_exe = b.addExecutable(.{
        .name = "wit-zigar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../wit-zigar/src/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .strip = if (b.graph.host.result.cpu.arch == .aarch64 and (@import("builtin").zig_backend == .stage2_aarch64)) true else null,
        }),
    });

    // Generate Zig 0.17 WIT bindings for `zigar:typescript@7.1.0` (`wasm32` and `wasm64`)
    const gen_wasm32_cmd = b.addRunArtifact(wit_zigar_exe);
    gen_wasm32_cmd.addFileArg(b.path("wit/typescript.wit"));
    gen_wasm32_cmd.addArgs(&.{ "--world", "typescript-compiler", "-o" });
    const generated_ts_wasm32 = gen_wasm32_cmd.addOutputFileArg("generated_ts_wasm32.zig");

    const gen_wasm64_cmd = b.addRunArtifact(wit_zigar_exe);
    gen_wasm64_cmd.addFileArg(b.path("wit/typescript.wit"));
    gen_wasm64_cmd.addArgs(&.{ "--world", "typescript-compiler", "--wasm64", "-o" });
    const generated_ts_wasm64 = gen_wasm64_cmd.addOutputFileArg("generated_ts_wasm64.zig");

    // Public `ts-zigar` module
    const ts_zigar_mod = b.addModule("ts-zigar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    ts_zigar_mod.addImport("wit_zigar", wit_zigar_mod);
    ts_zigar_mod.addAnonymousImport("generated_ts_wasm32", .{
        .root_source_file = generated_ts_wasm32,
    });
    ts_zigar_mod.addAnonymousImport("generated_ts_wasm64", .{
        .root_source_file = generated_ts_wasm64,
    });

    // Cross-compile generated WIT bindings for `wasm32-freestanding`, `wasm32-wasi`, and `wasm64-freestanding`
    const wasm32_free_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm32_wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const wasm64_free_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm64,
        .os_tag = .freestanding,
    });

    const wasm32_free_mod = b.createModule(.{
        .root_source_file = b.path("test/wasm_compile_check.zig"),
        .target = wasm32_free_target,
        .optimize = .Debug,
    });
    wasm32_free_mod.addAnonymousImport("generated_ts", .{
        .root_source_file = generated_ts_wasm32,
    });
    wasm32_free_mod.addAnonymousImport("wit_zigar_canon", .{
        .root_source_file = b.path("../wit-zigar/src/canon.zig"),
    });
    const wasm32_free_obj = b.addObject(.{
        .name = "ts-wit-wasm32-freestanding",
        .root_module = wasm32_free_mod,
    });

    const wasm32_wasi_mod = b.createModule(.{
        .root_source_file = b.path("test/wasm_compile_check.zig"),
        .target = wasm32_wasi_target,
        .optimize = .Debug,
    });
    wasm32_wasi_mod.addAnonymousImport("generated_ts", .{
        .root_source_file = generated_ts_wasm32,
    });
    wasm32_wasi_mod.addAnonymousImport("wit_zigar_canon", .{
        .root_source_file = b.path("../wit-zigar/src/canon.zig"),
    });
    const wasm32_wasi_obj = b.addObject(.{
        .name = "ts-wit-wasm32-wasi",
        .root_module = wasm32_wasi_mod,
    });

    const wasm64_free_mod = b.createModule(.{
        .root_source_file = b.path("test/wasm_compile_check.zig"),
        .target = wasm64_free_target,
        .optimize = .Debug,
    });
    wasm64_free_mod.addAnonymousImport("generated_ts", .{
        .root_source_file = generated_ts_wasm64,
    });
    wasm64_free_mod.addAnonymousImport("wit_zigar_canon", .{
        .root_source_file = b.path("../wit-zigar/src/canon.zig"),
    });
    const wasm64_free_obj = b.addObject(.{
        .name = "ts-wit-wasm64-freestanding",
        .root_module = wasm64_free_mod,
    });

    const wasm_check_files = b.addWriteFiles();
    _ = wasm_check_files.addCopyFile(wasm32_free_obj.getEmittedBin(), "ts-wit-wasm32-freestanding.o");
    _ = wasm_check_files.addCopyFile(wasm32_wasi_obj.getEmittedBin(), "ts-wit-wasm32-wasi.o");
    _ = wasm_check_files.addCopyFile(wasm64_free_obj.getEmittedBin(), "ts-wit-wasm64-freestanding.o");

    // Native Canonical ABI + AST + Wasm export symbol + round-trip tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/wit_codegen_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    test_mod.addImport("wit_zigar", wit_zigar_mod);
    test_mod.addAnonymousImport("typescript_wit", .{
        .root_source_file = b.path("wit/typescript.wit"),
    });
    test_mod.addAnonymousImport("generated_ts_wasm32", .{
        .root_source_file = generated_ts_wasm32,
    });
    test_mod.addAnonymousImport("generated_ts_wasm64", .{
        .root_source_file = generated_ts_wasm64,
    });
    test_mod.addAnonymousImport("wasm32_obj_bytes", .{
        .root_source_file = wasm32_free_obj.getEmittedBin(),
    });
    test_mod.addAnonymousImport("wasm64_obj_bytes", .{
        .root_source_file = wasm64_free_obj.getEmittedBin(),
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = use_llvm,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Reproducible TypeScript 7.1-next Go WASM Component build step (`zig build component` / `zig build build-component`)
    const component_wasm_rel = "component/dist/typescript-compiler.component.wasm";
    const component_wasm_abs = b.root.joinString(b.allocator, component_wasm_rel) catch @panic("OOM");
    const build_component_script_abs = b.root.joinString(b.allocator, "component/build-component.mjs") catch @panic("OOM");

    // Installable `ts-zigar` CLI executable (`zig build` -> `zig-out/bin/ts-zigar`, `zig build run -- <args>`)
    const cli_build_opts = b.addOptions();
    cli_build_opts.addOption([]const u8, "default_component_path", component_wasm_abs);
    cli_build_opts.addOption([]const u8, "build_component_script_path", build_component_script_abs);
    cli_build_opts.addOption([]const u8, "default_node_exe", "node");

    const cli_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    cli_exe_mod.addImport("ts_zigar", ts_zigar_mod);
    cli_exe_mod.addOptions("build_options", cli_build_opts);

    const cli_exe = b.addExecutable(.{
        .name = "ts-zigar",
        .root_module = cli_exe_mod,
        .use_llvm = use_llvm,
    });
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.step.dependOn(b.getInstallStep());
    run_cli.addPassthruArgs();
    const run_step = b.step("run", "Run the ts-zigar CLI");
    run_step.dependOn(&run_cli.step);

    const build_component_cmd = b.addSystemCommand(&.{
        "node",
        "component/build-component.mjs",
        "-o",
        component_wasm_rel,
    });
    build_component_cmd.setCwd(b.path(""));
    const component_step = b.step("component", "Build TypeScript 7.1-next Go WASM Component via componentize-go");
    component_step.dependOn(&build_component_cmd.step);
    const build_component_step = b.step("build-component", "Build TypeScript 7.1-next Go WASM Component via componentize-go");
    build_component_step.dependOn(&build_component_cmd.step);

    // Optional component loader check inside `zig build test` (validates `.component.wasm` whenever built)
    const opt_comp_opts = b.addOptions();
    opt_comp_opts.addOption([]const u8, "component_wasm_path", component_wasm_rel);
    opt_comp_opts.addOption(bool, "require_component", false);

    const opt_comp_test_mod = b.createModule(.{
        .root_source_file = b.path("test/component_loader_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    opt_comp_test_mod.addImport("wit_zigar", wit_zigar_mod);
    opt_comp_test_mod.addOptions("build_options", opt_comp_opts);

    const opt_comp_tests = b.addTest(.{
        .root_module = opt_comp_test_mod,
        .use_llvm = use_llvm,
    });
    const run_opt_comp_tests = b.addRunArtifact(opt_comp_tests);
    run_opt_comp_tests.setCwd(b.path(""));
    run_opt_comp_tests.has_side_effects = true;

    const opt_host_test_mod = b.createModule(.{
        .root_source_file = b.path("test/component_host_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    opt_host_test_mod.addImport("ts_zigar", ts_zigar_mod);
    opt_host_test_mod.addOptions("build_options", opt_comp_opts);

    const opt_host_tests = b.addTest(.{
        .root_module = opt_host_test_mod,
        .use_llvm = use_llvm,
    });
    const run_opt_host_tests = b.addRunArtifact(opt_host_tests);
    run_opt_host_tests.setCwd(b.path(""));
    run_opt_host_tests.has_side_effects = true;

    // Dedicated strict component validation + Node.js 26 integration test step (`zig build test-component`)
    const req_comp_opts = b.addOptions();
    req_comp_opts.addOption([]const u8, "component_wasm_path", component_wasm_rel);
    req_comp_opts.addOption(bool, "require_component", true);

    const req_comp_test_mod = b.createModule(.{
        .root_source_file = b.path("test/component_loader_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    req_comp_test_mod.addImport("wit_zigar", wit_zigar_mod);
    req_comp_test_mod.addOptions("build_options", req_comp_opts);

    const req_comp_tests = b.addTest(.{
        .root_module = req_comp_test_mod,
        .use_llvm = use_llvm,
    });
    const run_req_comp_tests = b.addRunArtifact(req_comp_tests);
    run_req_comp_tests.setCwd(b.path(""));
    run_req_comp_tests.has_side_effects = true;
    run_req_comp_tests.step.dependOn(&build_component_cmd.step);

    const req_host_test_mod = b.createModule(.{
        .root_source_file = b.path("test/component_host_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    req_host_test_mod.addImport("ts_zigar", ts_zigar_mod);
    req_host_test_mod.addOptions("build_options", req_comp_opts);

    const req_host_tests = b.addTest(.{
        .root_module = req_host_test_mod,
        .use_llvm = use_llvm,
    });
    const run_req_host_tests = b.addRunArtifact(req_host_tests);
    run_req_host_tests.setCwd(b.path(""));
    run_req_host_tests.has_side_effects = true;
    run_req_host_tests.step.dependOn(&build_component_cmd.step);

    const run_node_comp_tests = b.addSystemCommand(&.{
        "node",
        "--test",
        "component/test/component.test.mjs",
        "component/test/extractor.test.mjs",
    });
    run_node_comp_tests.setCwd(b.path(""));
    run_node_comp_tests.step.dependOn(&build_component_cmd.step);

    const test_component_step = b.step("test-component", "Build and validate typescript-compiler.component.wasm with wit-zigar and Node.js 26");
    test_component_step.dependOn(&run_req_comp_tests.step);
    test_component_step.dependOn(&run_req_host_tests.step);
    test_component_step.dependOn(&run_node_comp_tests.step);

    const root_unit_tests = b.addTest(.{
        .root_module = ts_zigar_mod,
        .use_llvm = use_llvm,
    });
    const run_root_unit_tests = b.addRunArtifact(root_unit_tests);

    const cli_emit_opts = b.addOptions();
    cli_emit_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);

    const cli_emit_test_mod = b.createModule(.{
        .root_source_file = b.path("test/cli_emit_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    cli_emit_test_mod.addImport("ts_zigar", ts_zigar_mod);
    cli_emit_test_mod.addOptions("test_options", cli_emit_opts);

    const cli_emit_tests = b.addTest(.{
        .root_module = cli_emit_test_mod,
        .filters = test_filters,
        .use_llvm = use_llvm,
    });
    const run_cli_emit_tests = b.addRunArtifact(cli_emit_tests);
    run_cli_emit_tests.setCwd(b.path(""));
    run_cli_emit_tests.has_side_effects = true;
    run_cli_emit_tests.step.dependOn(b.getInstallStep());

    const build_ts_pkg_cmd = b.addSystemCommand(&.{
        "node",
        "component/build-typescript-pkg.mjs",
    });
    build_ts_pkg_cmd.setCwd(b.path(""));
    const ts_pkg_step = b.step("typescript-pkg", "Stage TypeScript 7.1 npm package + native tsc API server");
    ts_pkg_step.dependOn(&build_ts_pkg_cmd.step);

    const ts_dts_opts = b.addOptions();
    ts_dts_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    ts_dts_opts.addOption(bool, "require_ts71", require_ts71);

    const ts_dts_test_mod = b.createModule(.{
        .root_source_file = b.path("test/typescript_dts_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    ts_dts_test_mod.addImport("ts_zigar", ts_zigar_mod);
    ts_dts_test_mod.addOptions("test_options", ts_dts_opts);

    const ts_dts_tests = b.addTest(.{
        .root_module = ts_dts_test_mod,
        .use_llvm = use_llvm,
    });
    const run_ts_dts_tests = b.addRunArtifact(ts_dts_tests);
    run_ts_dts_tests.setCwd(b.path(""));
    run_ts_dts_tests.has_side_effects = true;
    run_ts_dts_tests.step.dependOn(b.getInstallStep());
    if (require_ts71) {
        run_opt_comp_tests.step.dependOn(&build_component_cmd.step);
        run_opt_host_tests.step.dependOn(&build_component_cmd.step);
        run_cli_emit_tests.step.dependOn(&build_component_cmd.step);
        run_ts_dts_tests.step.dependOn(&build_component_cmd.step);
        run_ts_dts_tests.step.dependOn(&build_ts_pkg_cmd.step);
    }

    const req_ts_dts_opts = b.addOptions();
    req_ts_dts_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    req_ts_dts_opts.addOption(bool, "require_ts71", true);

    const req_ts_dts_test_mod = b.createModule(.{
        .root_source_file = b.path("test/typescript_dts_test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    req_ts_dts_test_mod.addImport("ts_zigar", ts_zigar_mod);
    req_ts_dts_test_mod.addOptions("test_options", req_ts_dts_opts);

    const req_ts_dts_tests = b.addTest(.{
        .root_module = req_ts_dts_test_mod,
        .use_llvm = use_llvm,
    });
    const run_req_ts_dts_tests = b.addRunArtifact(req_ts_dts_tests);
    run_req_ts_dts_tests.setCwd(b.path(""));
    run_req_ts_dts_tests.has_side_effects = true;
    run_req_ts_dts_tests.step.dependOn(b.getInstallStep());
    run_req_ts_dts_tests.step.dependOn(&build_component_cmd.step);
    run_req_ts_dts_tests.step.dependOn(&build_ts_pkg_cmd.step);

    const test_ts71_step = b.step("test-ts71", "Build TypeScript 7.1 component + staged package and run M3.4a torture test");
    test_ts71_step.dependOn(&run_req_ts_dts_tests.step);

    const test_step = b.step("test", "Verify typescript.wit codegen, CLI, IR, Zig 0.17 emitter, and component host");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_root_unit_tests.step);
    test_step.dependOn(&wasm_check_files.step);
    test_step.dependOn(&run_opt_comp_tests.step);
    test_step.dependOn(&run_opt_host_tests.step);
    test_step.dependOn(&run_cli_emit_tests.step);
    test_step.dependOn(&run_ts_dts_tests.step);
}
