const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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

    // Reproducible TypeScript 7.1-next Go WASM Component build step (`zig build component`)
    const component_wasm_rel = "component/dist/typescript-compiler.component.wasm";
    const build_component_cmd = b.addSystemCommand(&.{
        "node",
        "component/build-component.mjs",
        "-o",
        component_wasm_rel,
    });
    build_component_cmd.setCwd(b.path(""));
    const component_step = b.step("component", "Build TypeScript 7.1-next Go WASM Component via componentize-go");
    component_step.dependOn(&build_component_cmd.step);

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

    const test_step = b.step("test", "Verify typescript.wit codegen, Canonical ABI, wasm32/wasm64 cross-compilation, and component loader");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&wasm_check_files.step);
    test_step.dependOn(&run_opt_comp_tests.step);
    test_step.dependOn(&run_opt_host_tests.step);
}
