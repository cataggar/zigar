const std = @import("std");
const Import = std.Build.Module.Import;
const builtin = @import("builtin");

const cfg = @import("build.cfg.zig");
const extra = @import("build.extra.zig");

pub fn build(b: *std.Build) !void {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) {
        @compileError("Unsupported Zig version");
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = @as(?bool, cfg.use_llvm) orelse default: {
        if (cfg.is_wasm) break :default true;
        if (builtin.target.cpu.arch == .x86_64 and cfg.multithreaded) break :default true;
        break :default null;
    };
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = cfg.module_name,
        .root_module = b.addModule("root", .{
            .root_source_file = .{ .cwd_relative = cfg.zigar_src_path ++ "stub.zig" },
            .target = target,
            .optimize = optimize,
            .single_threaded = !cfg.multithreaded,
        }),
        .use_llvm = use_llvm,
    });
    const zigar = b.createModule(.{
        .root_source_file = .{ .cwd_relative = cfg.zigar_src_path ++ "zigar.zig" },
    });
    const zigar_imports: []const Import = &.{.{ .name = "zigar", .module = zigar }};
    const extra_imports: []const Import = switch (@hasDecl(extra, "getImports")) {
        true => @call(.always_inline, extra.getImports, .{ b, .{
            .library = lib,
            .target = target,
            .optimize = optimize,
        } }),
        false => &.{},
    };
    const imports = try std.mem.concat(b.allocator, Import, &.{ zigar_imports, extra_imports });
    const mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = cfg.module_path },
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    mod.addIncludePath(.{ .cwd_relative = cfg.module_dir });
    lib.root_module.addImport("module", mod);
    // Zig 0.17 removed @cImport; user modules import translated C via @import("c").
    // When a "<source>.cimport.h" / "cimport.h" header sits next to the module,
    // src/compilation.js records its path here so we can wire a translate-c module
    // onto the user module under the import name "c".
    if (@TypeOf(cfg.c_import_header_path) != @TypeOf(null)) {
        const tc = b.addTranslateC(.{
            .root_source_file = .{ .cwd_relative = cfg.c_import_header_path },
            .target = target,
            .optimize = optimize,
            .link_libc = cfg.use_libc,
        });
        // resolve #include "..." relative to the module directory
        tc.addIncludePath(.{ .cwd_relative = cfg.module_dir });
        mod.addImport("c", tc.createModule());
    }
    // Zig 0.17 removed @cImport; host/native/hooks.zig instead imports C headers
    // translated via the build system. These modules are only reached on native
    // targets, so they are wired up per-target here.
    if (!cfg.is_wasm) {
        const c_dir = cfg.zigar_src_path ++ "host/native/cimport/";
        const addTC = struct {
            fn add(bb: *std.Build, root: *std.Build.Module, name: []const u8, header: []const u8, tgt: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode) void {
                const tc = bb.addTranslateC(.{
                    .root_source_file = .{ .cwd_relative = header },
                    .target = tgt,
                    .optimize = opt,
                    .link_libc = true,
                });
                root.addImport(name, tc.createModule());
            }
        }.add;
        addTC(b, lib.root_module, "errno_h", c_dir ++ "errno.h", target, optimize);
        addTC(b, lib.root_module, "stdio_h", c_dir ++ "stdio.h", target, optimize);
        if (target.result.os.tag == .windows) {
            addTC(b, lib.root_module, "windows_h", c_dir ++ "windows.h", target, optimize);
        } else {
            addTC(b, lib.root_module, "dirent_h", c_dir ++ "dirent.h", target, optimize);
            addTC(b, lib.root_module, "stat_h", c_dir ++ "stat.h", target, optimize);
        }
    }
    const extra_c_files: []const []const u8 = switch (@hasDecl(extra, "getCSourceFiles")) {
        true => @call(.always_inline, extra.getCSourceFiles, .{ b, .{
            .library = lib,
            .module = mod,
            .target = target,
            .optimize = optimize,
        } }),
        false => &.{},
    };
    for (extra_c_files) |file| {
        const path = try std.fs.path.resolve(b.allocator, &.{ cfg.module_dir, file });
        lib.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = path } });
    }
    const extra_include_paths: []const []const u8 = switch (@hasDecl(extra, "getIncludePaths")) {
        true => @call(.always_inline, extra.getIncludePaths, .{ b, .{
            .library = lib,
            .module = mod,
            .target = target,
            .optimize = optimize,
        } }),
        false => &.{},
    };
    for (extra_include_paths) |inc_path| {
        const path = try std.fs.path.resolve(b.allocator, &.{ cfg.module_dir, inc_path });
        lib.root_module.addIncludePath(.{ .cwd_relative = path });
    }
    if (cfg.use_libc) {
        lib.root_module.link_libc = true;
    }
    if (cfg.is_wasm) {
        // WASM needs to be compiled as exe
        lib.kind = .exe;
        lib.linkage = .static;
        lib.entry = .disabled;
        lib.rdynamic = true;
        lib.wasi_exec_model = .reactor;
        lib.import_memory = cfg.multithreaded;
        lib.import_table = !cfg.multithreaded;
        lib.stack_size = cfg.stack_size;
        lib.max_memory = cfg.max_memory;
    } else if (cfg.use_redirection) {
        lib.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = cfg.zigar_src_path ++ "host/native/hooks.c" } });
    }
    const options = b.addOptions();
    options.addOption(comptime_int, "eval_branch_quota", cfg.eval_branch_quota);
    options.addOption(bool, "omit_functions", cfg.omit_functions);
    options.addOption(bool, "omit_variables", cfg.omit_variables);
    options.addOption(bool, "use_redirection", cfg.use_redirection);
    options.addOption(bool, "use_pthread_emulation", cfg.use_pthread_emulation);
    lib.root_module.addOptions("options.zig", options);
    const wf = b.addUpdateSourceFiles();
    wf.addCopyFileToSource(lib.getEmittedBin(), cfg.output_path);
    if (@TypeOf(cfg.pdb_path) != @TypeOf(null) and optimize == .Debug) {
        wf.addCopyFileToSource(lib.getEmittedPdb(), cfg.pdb_path);
    }
    wf.step.dependOn(&lib.step);
    b.getInstallStep().dependOn(&wf.step);
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
