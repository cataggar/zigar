//! Unit and Canonical ABI verification suite for `ts-zigar/wit/typescript.wit`
//! (`package zigar:typescript@7.1.0; world typescript-compiler`).

const std = @import("std");
const testing = std.testing;
const wit_zigar = @import("wit_zigar");
const canon = wit_zigar.canon;
const fast_abi = wit_zigar.fast_abi;

const ts32 = @import("generated_ts_wasm32");
const ts64 = @import("generated_ts_wasm64");
const typescript_wit_source = @embedFile("typescript_wit");
const wasm32_obj_bytes = @embedFile("wasm32_obj_bytes");
const wasm64_obj_bytes = @embedFile("wasm64_obj_bytes");

fn expectMetaMatchesCanon(
    comptime FnT: type,
    comptime CoreFnT: type,
    comptime meta: anytype,
    comptime arch: canon.Arch,
) !void {
    const lower_cls = comptime canon.classifyZigFn(FnT, .{
        .arch = arch,
        .is_async = meta.is_async,
        .direction = .lower,
        .string_encoding_utf8 = meta.string_encoding_utf8,
    });
    try testing.expectEqual(meta.params_flat, @min(lower_cls.params_flat, 32));
    try testing.expectEqual(meta.results_flat, @min(lower_cls.results_flat, 32));
    try testing.expectEqual(meta.has_result, lower_cls.has_result);
    try testing.expectEqual(meta.needs_memory, lower_cls.needs_memory);
    try testing.expectEqual(meta.needs_realloc, lower_cls.lower_needs_realloc);
    if (lower_cls.contains_string) {
        try testing.expect(meta.string_encoding_utf8);
    }

    const active_opts: canon.CallOptions = .{
        .arch = arch,
        .is_async = meta.is_async,
        .direction = if (meta.is_export) .lift else .lower,
        .string_encoding_utf8 = meta.string_encoding_utf8,
    };
    const active_cls = comptime canon.classifyZigFn(FnT, active_opts);
    const core_param_fields = @typeInfo(std.meta.ArgsTuple(CoreFnT)).@"struct".field_types;
    try testing.expectEqual(active_cls.core_param_types.len, core_param_fields.len);
    inline for (active_cls.core_param_types, core_param_fields) |expected_vt, ActualParamT| {
        const ExpectedParamT = switch (expected_vt) {
            .i32 => i32,
            .i64 => i64,
            .f32 => f32,
            .f64 => f64,
        };
        try testing.expect(ActualParamT == ExpectedParamT);
    }
    const core_ret_t = @typeInfo(CoreFnT).@"fn".return_type orelse void;
    const ExpectedRetT = if (active_cls.core_result_type) |rvt| switch (rvt) {
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
    } else void;
    try testing.expect(core_ret_t == ExpectedRetT);
    const expected_is_direct = !active_cls.params_spill and !active_cls.results_indirect and !active_cls.needs_memory;
    try testing.expectEqual(meta.is_direct, expected_is_direct);

    if (meta.is_export) {
        try testing.expectEqual(meta.lift_needs_memory, active_cls.needs_memory);
        try testing.expectEqual(meta.lift_needs_realloc, active_cls.lift_needs_realloc);
        try testing.expectEqual(meta.lift_needs_post_return, active_cls.needs_post_return);
    }
}

test "typescript.wit parses, resolves, and generates valid Zig 0.17 AST for wasm32 and wasm64" {
    const alloc = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    var diag: wit_zigar.wit.parser.ParseDiagnostic = .{};
    const doc = try wit_zigar.wit.parser.parse(ar, typescript_wit_source, &diag);

    const pkg = doc.package orelse return error.MissingPackageHeader;
    try testing.expectEqualStrings("zigar", pkg.namespace);
    try testing.expectEqualStrings("typescript", pkg.name);
    try testing.expectEqualStrings("7.1.0", pkg.version.?);

    const res = wit_zigar.wit.resolver.Resolver.init(doc, &.{});
    const types_iface = res.findInterface(.{ .package = null, .name = "types" }) orelse return error.MissingTypesInterface;
    const compiler_iface = res.findInterface(.{ .package = null, .name = "compiler" }) orelse return error.MissingCompilerInterface;
    const extractor_iface = res.findInterface(.{ .package = null, .name = "extractor" }) orelse return error.MissingExtractorInterface;
    const world_hit = res.findWorld(.{ .package = null, .name = "typescript-compiler" }) orelse return error.MissingWorld;

    try testing.expect(types_iface.items.len >= 35);
    try testing.expect(compiler_iface.items.len >= 10);
    try testing.expectEqual(@as(usize, 3), extractor_iface.items.len);
    try testing.expectEqual(@as(usize, 3), world_hit.world.items.len);

    for ([_]wit_zigar.bindgen.Arch{ .wasm32, .wasm64 }) |arch| {
        const zig_src = try wit_zigar.bindgen.generateFromResolver(alloc, res, .{
            .world_name = "typescript-compiler",
            .arch = arch,
        });
        defer alloc.free(zig_src);

        const z_src = try alloc.allocSentinel(u8, zig_src.len, 0);
        defer alloc.free(z_src);
        @memcpy(z_src[0..zig_src.len], zig_src);
        var tree = try std.zig.Ast.parse(alloc, z_src, .{ .mode = .zig });
        defer tree.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), tree.errors.len);
    }
}

test "types interface IR completeness: 15-flag u16 ModifierFlags, variants, and zero recursive types" {
    try testing.expectEqualStrings("zigar:typescript/typescript-compiler@7.1.0", ts32.world_name);
    try testing.expect(!ts32.is_wasm64);
    try testing.expect(ts64.is_wasm64);

    // 15 modifier flags -> 2-byte `packed struct(u16)` in Canonical ABI (1 flat `i32` slot)
    try testing.expectEqual(@as(u32, 15), ts32.types.ModifierFlags.wit_flags_count);
    try testing.expectEqual(@as(usize, 2), @sizeOf(ts32.types.ModifierFlags));
    const mod_layout = canon.layoutOf(ts32.types.ModifierFlags, .wasm32);
    try testing.expectEqual(@as(u32, 2), mod_layout.size);
    try testing.expectEqual(@as(u32, 2), mod_layout.alignment);
    try testing.expectEqual(@as(u32, 1), mod_layout.flat_count);

    // Verify `TypeKind` covers all 36 TypeScript 7.1 type constructs (including `readonly-tuple` and `infer-type`)
    const type_kind_info = @typeInfo(ts32.types.TypeKind).@"union";
    try testing.expectEqual(@as(usize, 36), type_kind_info.field_names.len);

    // Verify the 5 `.d.ts` IR completeness constructs:
    // 1. `infer-type` + `ConditionalTypeData.infer_params`
    const cond_sample = ts32.types.TypeKind{
        .conditional = .{
            .check_type = 0,
            .extends_type = 1,
            .true_type = 2,
            .false_type = 3,
            .infer_params = &.{0},
        },
    };
    try testing.expectEqual(@as(usize, 1), cond_sample.conditional.infer_params.len);
    const infer_sample = ts32.types.TypeKind{ .infer_type = 0 };
    try testing.expectEqual(@as(u32, 0), infer_sample.infer_type);

    // 2. `readonly-tuple` distinct from `%tuple`
    const ro_tuple = ts32.types.TypeKind{ .readonly_tuple = &.{} };
    try testing.expectEqual(@as(usize, 0), ro_tuple.readonly_tuple.len);

    // 3. `SignatureNode.is_abstract`
    try testing.expect(@hasField(ts32.types.SignatureNode, "is_abstract"));

    // 4. `SymbolKey` variant (`well-known`, `unique(decl-id)`, `custom(string-id)`) on `PropNode` & `MethodNode`
    const sym_unique = ts32.types.SymbolKey{ .unique = 42 };
    try testing.expectEqual(@as(u32, 42), sym_unique.unique);
    const sym_wk = ts32.types.SymbolKey{ .well_known = .dispose };
    try testing.expectEqual(ts32.types.WellKnownSymbol.dispose, sym_wk.well_known);

    // 5. `ModuleNode.umd_namespace` and `ModuleNode.triple_slash_libs`
    try testing.expect(@hasField(ts32.types.ModuleNode, "umd_namespace"));
    try testing.expect(@hasField(ts32.types.ModuleNode, "triple_slash_libs"));

    // Verify `DeclKind` covers all 9 declaration forms
    const decl_kind_info = @typeInfo(ts32.types.DeclKind).@"union";
    try testing.expectEqual(@as(usize, 9), decl_kind_info.field_names.len);

    // Verify `DeclarationGraph` has 9 arena tables -> 18 flat slice slots (9 * 2)
    const graph_layout32 = canon.layoutOf(ts32.types.DeclarationGraph, .wasm32);
    const graph_layout64 = canon.layoutOf(ts64.types.DeclarationGraph, .wasm64);
    try testing.expectEqual(@as(u32, 18), graph_layout32.flat_count);
    try testing.expectEqual(@as(u32, 72), graph_layout32.size);
    try testing.expectEqual(@as(u32, 18), graph_layout64.flat_count);
    try testing.expectEqual(@as(u32, 144), graph_layout64.size);

    // Pure type-export interface `types` produces empty `zigar_abi_entries`
    const EmptyImpl = struct {};
    const TypesExports = ts32.types.exportBindings(EmptyImpl);
    try testing.expectEqual(@as(usize, 0), TypesExports.zigar_abi_entries.len);
}

test "Canonical ABI classification for all 18 functions and resource methods across wasm32 and wasm64" {
    // ── Top-level `compiler` exports ────────────────────────────────────────
    // `create-program`: 1 (borrow<vfs>) + 2 (list<string>) + 17 (compiler-options) = 20 flat params!
    // Exceeds MAX_FLAT_PARAMS (16) -> spills parameters to linear memory pointer;
    // results_flat = 3 > MAX_FLAT_RESULTS (1) -> returns indirect pointer!
    try testing.expectEqual(@as(u32, 20), ts32.compiler.create_program_meta.params_flat);
    try testing.expectEqual(@as(u32, 3), ts32.compiler.create_program_meta.results_flat);
    try testing.expect(!ts32.compiler.create_program_meta.is_direct);
    try testing.expect(ts32.compiler.create_program_meta.lift_needs_memory);
    try testing.expect(ts32.compiler.create_program_meta.lift_needs_realloc);
    try testing.expect(ts32.compiler.create_program_meta.lift_needs_post_return);
    try testing.expect(ts32.compiler.create_program_CoreFn == fn (i32) callconv(.c) i32);
    try testing.expect(ts64.compiler.create_program_CoreFn == fn (i64) callconv(.c) i64);

    // `transpile-module`: 4 flat params, 5 flat results -> indirect return pointer
    try testing.expectEqual(@as(u32, 4), ts32.compiler.transpile_module_meta.params_flat);
    try testing.expectEqual(@as(u32, 5), ts32.compiler.transpile_module_meta.results_flat);
    try testing.expect(ts32.compiler.transpile_module_CoreFn == fn (i32, i32, i32, i32) callconv(.c) i32);
    try testing.expect(ts64.compiler.transpile_module_CoreFn == fn (i64, i64, i64, i64) callconv(.c) i64);

    // `compiler-version`: 0 params, 2 flat results (`string`) -> indirect return pointer, no lift realloc
    try testing.expectEqual(@as(u32, 0), ts32.compiler.compiler_version_meta.params_flat);
    try testing.expectEqual(@as(u32, 2), ts32.compiler.compiler_version_meta.results_flat);
    try testing.expect(!ts32.compiler.compiler_version_meta.lift_needs_realloc);
    try testing.expect(ts32.compiler.compiler_version_meta.lift_needs_post_return);
    try testing.expect(ts32.compiler.compiler_version_CoreFn == fn () callconv(.c) i32);
    try testing.expect(ts64.compiler.compiler_version_CoreFn == fn () callconv(.c) i64);

    // ── Top-level `extractor` export ────────────────────────────────────────
    // `extract-module-graph`: 1 (borrow<program> i32) + 8 (extract-config) = 9 flat params;
    // results_flat = 1 (disc) + max(18 (declaration-graph), 2 (list<diagnostic>)) = 19 -> indirect return!
    try testing.expectEqual(@as(u32, 9), ts32.extractor.extract_module_graph_meta.params_flat);
    try testing.expectEqual(@as(u32, 19), ts32.extractor.extract_module_graph_meta.results_flat);
    try testing.expect(ts32.extractor.extract_module_graph_meta.string_encoding_utf8);
    try testing.expect(ts32.extractor.extract_module_graph_meta.lift_needs_memory);
    try testing.expect(ts32.extractor.extract_module_graph_meta.lift_needs_realloc);
    try testing.expect(ts32.extractor.extract_module_graph_meta.lift_needs_post_return);
    try testing.expect(ts32.extractor.extract_module_graph_CoreFn == fn (i32, i32, i32, i32, i32, i32, i32, i32, i32) callconv(.c) i32);
    try testing.expect(ts64.extractor.extract_module_graph_CoreFn == fn (i32, i64, i64, i64, i64, i32, i32, i32, i32) callconv(.c) i64);

    // ── Resource handle i32 invariant on both wasm32 and wasm64 ─────────────
    // `[constructor]vfs` and `[method]program.get-checker` take/return resource handles as `i32` on BOTH wasm32 and wasm64!
    try testing.expect(ts32.compiler.Vfs.constructor_CoreFn == fn (i32) callconv(.c) i32);
    try testing.expect(ts64.compiler.Vfs.constructor_CoreFn == fn (i32) callconv(.c) i32);
    try testing.expect(ts32.compiler.Vfs.constructor_meta.is_direct);
    try testing.expect(!ts32.compiler.Vfs.constructor_meta.lift_needs_memory);

    try testing.expect(ts32.compiler.Program.get_checker_CoreFn == fn (i32) callconv(.c) i32);
    try testing.expect(ts64.compiler.Program.get_checker_CoreFn == fn (i32) callconv(.c) i32);
    try testing.expect(ts32.compiler.Program.get_checker_meta.is_direct);
    try testing.expect(!ts32.compiler.Program.get_checker_meta.lift_needs_memory);

    // Cross-validate ALL 18 functions + resource methods against `canon.classifyFn` on wasm32 AND wasm64!
    inline for (.{
        .{ ts32, canon.Arch.wasm32 },
        .{ ts64, canon.Arch.wasm64 },
    }) |pair| {
        const B = pair[0];
        const arch = pair[1];

        try expectMetaMatchesCanon(B.compiler.create_program_Fn, B.compiler.create_program_CoreFn, B.compiler.create_program_meta, arch);
        try expectMetaMatchesCanon(B.compiler.transpile_module_Fn, B.compiler.transpile_module_CoreFn, B.compiler.transpile_module_meta, arch);
        try expectMetaMatchesCanon(B.compiler.compiler_version_Fn, B.compiler.compiler_version_CoreFn, B.compiler.compiler_version_meta, arch);
        try expectMetaMatchesCanon(B.extractor.extract_module_graph_Fn, B.extractor.extract_module_graph_CoreFn, B.extractor.extract_module_graph_meta, arch);

        try expectMetaMatchesCanon(B.compiler.Vfs.constructor_Fn, B.compiler.Vfs.constructor_CoreFn, B.compiler.Vfs.constructor_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Vfs.write_file_Fn, B.compiler.Vfs.write_file_CoreFn, B.compiler.Vfs.write_file_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Vfs.read_file_Fn, B.compiler.Vfs.read_file_CoreFn, B.compiler.Vfs.read_file_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Vfs.file_exists_Fn, B.compiler.Vfs.file_exists_CoreFn, B.compiler.Vfs.file_exists_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Vfs.delete_file_Fn, B.compiler.Vfs.delete_file_CoreFn, B.compiler.Vfs.delete_file_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Vfs.list_files_Fn, B.compiler.Vfs.list_files_CoreFn, B.compiler.Vfs.list_files_meta, arch);

        try expectMetaMatchesCanon(B.compiler.Program.get_root_files_Fn, B.compiler.Program.get_root_files_CoreFn, B.compiler.Program.get_root_files_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Program.get_syntactic_diagnostics_Fn, B.compiler.Program.get_syntactic_diagnostics_CoreFn, B.compiler.Program.get_syntactic_diagnostics_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Program.get_semantic_diagnostics_Fn, B.compiler.Program.get_semantic_diagnostics_CoreFn, B.compiler.Program.get_semantic_diagnostics_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Program.get_global_diagnostics_Fn, B.compiler.Program.get_global_diagnostics_CoreFn, B.compiler.Program.get_global_diagnostics_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Program.emit_declarations_Fn, B.compiler.Program.emit_declarations_CoreFn, B.compiler.Program.emit_declarations_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Program.get_checker_Fn, B.compiler.Program.get_checker_CoreFn, B.compiler.Program.get_checker_meta, arch);

        try expectMetaMatchesCanon(B.compiler.Checker.type_to_string_Fn, B.compiler.Checker.type_to_string_CoreFn, B.compiler.Checker.type_to_string_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Checker.inspect_type_at_Fn, B.compiler.Checker.inspect_type_at_CoreFn, B.compiler.Checker.inspect_type_at_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Checker.inspect_symbol_at_Fn, B.compiler.Checker.inspect_symbol_at_CoreFn, B.compiler.Checker.inspect_symbol_at_meta, arch);
        try expectMetaMatchesCanon(B.compiler.Checker.resolve_module_exports_Fn, B.compiler.Checker.resolve_module_exports_CoreFn, B.compiler.Checker.resolve_module_exports_meta, arch);
    }
}

test "Canonical ABI linear-memory round-trip: create-program (20->1 spill) and extract-module-graph (DeclarationGraph)" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    var mem_buf: [65536]u8 align(16) = @splat(0);
    var bump = canon.BumpAllocator.init(256, mem_buf.len);
    var mem_ctx = bump.memoryContext(&mem_buf);
    mem_ctx.allocator = ar;
    canon.setActiveMemoryContext(mem_ctx);
    defer canon.setActiveMemoryContext(null);

    // 1. Test `compiler.create-program` (20 flat params spilled to linear memory + indirect result)
    const CreateProgramGuest = struct {
        fn impl(
            fs: ts32.Borrow(ts32.compiler.Vfs),
            root_files: []const []const u8,
            options: ts32.compiler.CompilerOptions,
        ) ts32.Result(ts32.compiler.Program, []const ts32.types.Diagnostic) {
            if (fs.handle != 7 or root_files.len != 2 or !options.strict or options.module_resolution != .bundler) {
                return .{ .err = &.{} };
            }
            return .{ .ok = .{ .handle = 99 } };
        }
    };

    const create_opts: canon.CallOptions = .{
        .arch = .wasm32,
        .string_encoding_utf8 = true,
    };
    const create_lift = canon.CanonLift(ts32.compiler.create_program_Fn, create_opts).thunk(&CreateProgramGuest.impl);
    const prog_res = try canon.CanonLower(ts32.compiler.create_program_Fn, create_opts).call(mem_ctx, create_lift, .{
        ts32.Borrow(ts32.compiler.Vfs){ .handle = 7 },
        &[_][]const u8{ "/src/index.ts", "/src/types.d.ts" },
        ts32.compiler.CompilerOptions{
            .target = .es2024,
            .module = .esnext,
            .module_resolution = .bundler,
            .strict = true,
            .exact_optional_property_types = true,
            .no_unchecked_indexed_access = false,
            .declaration = true,
            .emit_declaration_only = true,
            .allow_js = false,
            .skip_lib_check = true,
            .base_url = "/src",
            .type_roots = &[_][]const u8{"/node_modules/@types"},
            .types = &.{},
        },
    });
    try testing.expect(prog_res == .ok);
    try testing.expectEqual(@as(i32, 99), prog_res.ok.handle);

    // 2. Test `extractor.extract-module-graph` via FastLower/FastLift with populated `DeclarationGraph`
    const ExtractorGuest = struct {
        fn extract(
            prog: ts32.Borrow(ts32.compiler.Program),
            cfg: ts32.types.ExtractConfig,
        ) ts32.Result(ts32.types.DeclarationGraph, []const ts32.types.Diagnostic) {
            if (prog.handle != 99 or !cfg.expand_utility_types) {
                return .{ .err = &.{} };
            }
            const Static = struct {
                const strings = [_][]const u8{ "index.d.ts", "greet", "name" };
                const types = [_]ts32.types.TypeNode{
                    .{ .id = 0, .kind = .string_type, .resolved_type = null },
                    .{
                        .id = 1,
                        .kind = .{ .literal = .{ .str = 1 } },
                        .resolved_type = 0,
                    },
                };
                const params = [_]ts32.types.ParamNode{
                    .{ .name = 2, .ty = 0, .optional = false, .rest = false },
                };
                const sigs = [_]ts32.types.SignatureNode{
                    .{
                        .id = 0,
                        .type_params = &.{},
                        .this_param = null,
                        .params = &params,
                        .return_type = 0,
                        .type_predicate = null,
                        .is_abstract = false,
                        .modifiers = .{},
                        .jsdoc = null,
                    },
                };
                const decls = [_]ts32.types.DeclNode{
                    .{
                        .id = 0,
                        .name = 1,
                        .export_name = 1,
                        .module = 0,
                        .modifiers = .{ .export_decl = true, .declare_ambient = true },
                        .type_params = &.{},
                        .kind = .{ .function_decl = &.{0} },
                        .merged_with = &.{},
                        .jsdoc = null,
                    },
                };
                const modules = [_]ts32.types.ModuleNode{
                    .{
                        .id = 0,
                        .specifier = 0,
                        .file_path = 0,
                        .exports = &.{0},
                        .default_export = null,
                        .export_equals = null,
                        .umd_namespace = null,
                        .star_re_exports = &.{},
                        .ambient_modules = &.{},
                        .global_augmentations = &.{},
                        .triple_slash_types = &.{},
                        .triple_slash_paths = &.{},
                        .triple_slash_libs = &.{},
                    },
                };
            };
            return .{
                .ok = .{
                    .strings = &Static.strings,
                    .modules = &Static.modules,
                    .entry_modules = &.{0},
                    .decls = &Static.decls,
                    .types = &Static.types,
                    .signatures = &Static.sigs,
                    .type_params = &.{},
                    .properties = &.{},
                    .diagnostics = &.{},
                },
            };
        }
    };

    var fast_mem: [65536]u8 align(16) = @splat(0);
    var fast_ctx = ts32.canon.MemoryContext{
        .memory = &fast_mem,
        .allocator = ar,
        .fast_frame_offset = 128,
    };
    const FastL = ts32.canon.FastLower(ts32.extractor.extract_module_graph_Fn, false);
    const FastU = ts32.canon.FastLift(ts32.extractor.extract_module_graph_Fn, ExtractorGuest.extract, false);

    const graph_res = try FastL.call(&fast_ctx, FastU.thunk(), .{
        ts32.Borrow(ts32.compiler.Program){ .handle = 99 },
        ts32.types.ExtractConfig{
            .root_files = &[_][]const u8{"/src/index.d.ts"},
            .module_specifiers = &.{},
            .follow_re_exports = true,
            .expand_utility_types = true,
            .include_jsdoc = true,
            .include_private_members = false,
        },
    });
    try testing.expect(graph_res == .ok);
    const g = graph_res.ok;
    try testing.expectEqual(@as(usize, 3), g.strings.len);
    try testing.expectEqualStrings("greet", g.strings[1]);
    try testing.expectEqual(@as(usize, 1), g.decls.len);
    try testing.expect(g.decls[0].modifiers.export_decl);
    try testing.expect(g.decls[0].modifiers.declare_ambient);
    try testing.expect(!g.decls[0].modifiers.async_mod);
    try testing.expectEqual(@as(usize, 2), g.types.len);
    try testing.expectEqual(@as(?u32, 0), g.types[1].resolved_type);

    // 3. Verify `zigar_abi` custom section encoding round-trips all 4 top-level exported functions
    const sec_bytes = try ts32.zigar_abi.encodeSection(alloc);
    defer alloc.free(sec_bytes);
    const decoded_meta = try fast_abi.decodeZigarAbiSection(alloc, sec_bytes);
    defer decoded_meta.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), decoded_meta.entries.len);
}

test "compiled wasm32 and wasm64 objects emit all 23 canonical core exports and fast ABI exports" {
    const expected_exports = [_][]const u8{
        // Top-level canonical exports
        "zigar:typescript/compiler@7.1.0#compiler-version",
        "zigar:typescript/compiler@7.1.0#transpile-module",
        "zigar:typescript/compiler@7.1.0#create-program",
        "zigar:typescript/extractor@7.1.0#extract-module-graph",
        // `vfs` resource constructor, methods, and destructor
        "zigar:typescript/compiler@7.1.0#[constructor]vfs",
        "zigar:typescript/compiler@7.1.0#[method]vfs.write-file",
        "zigar:typescript/compiler@7.1.0#[method]vfs.read-file",
        "zigar:typescript/compiler@7.1.0#[method]vfs.file-exists",
        "zigar:typescript/compiler@7.1.0#[method]vfs.delete-file",
        "zigar:typescript/compiler@7.1.0#[method]vfs.list-files",
        "zigar:typescript/compiler@7.1.0#[dtor]vfs",
        // `program` resource methods and destructor
        "zigar:typescript/compiler@7.1.0#[method]program.get-root-files",
        "zigar:typescript/compiler@7.1.0#[method]program.get-syntactic-diagnostics",
        "zigar:typescript/compiler@7.1.0#[method]program.get-semantic-diagnostics",
        "zigar:typescript/compiler@7.1.0#[method]program.get-global-diagnostics",
        "zigar:typescript/compiler@7.1.0#[method]program.emit-declarations",
        "zigar:typescript/compiler@7.1.0#[method]program.get-checker",
        "zigar:typescript/compiler@7.1.0#[dtor]program",
        // `checker` resource methods and destructor
        "zigar:typescript/compiler@7.1.0#[method]checker.type-to-string",
        "zigar:typescript/compiler@7.1.0#[method]checker.inspect-type-at",
        "zigar:typescript/compiler@7.1.0#[method]checker.inspect-symbol-at",
        "zigar:typescript/compiler@7.1.0#[method]checker.resolve-module-exports",
        "zigar:typescript/compiler@7.1.0#[dtor]checker",
        // Fast ABI exports
        "__zigar_fast_zigar:typescript/compiler@7.1.0#compiler_version",
        "__zigar_fast_zigar:typescript/compiler@7.1.0#transpile_module",
        "__zigar_fast_zigar:typescript/compiler@7.1.0#create_program",
        "__zigar_fast_zigar:typescript/extractor@7.1.0#extract_module_graph",
    };

    for ([_][]const u8{ wasm32_obj_bytes, wasm64_obj_bytes }) |wasm_bytes| {
        // Verify valid WebAssembly binary header (`\0asm` + version 1)
        try testing.expect(wasm_bytes.len > 8);
        try testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", wasm_bytes[0..8]);

        for (expected_exports) |sym| {
            if (std.mem.indexOf(u8, wasm_bytes, sym) == null) {
                std.debug.print("Missing expected Wasm export symbol: {s}\n", .{sym});
                return error.MissingWasmExportSymbol;
            }
        }
    }
}

