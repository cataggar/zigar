const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const hello_lib = @import("hello_lib");

fn containsExport(symbols: []const hello_lib.ExportedSymbolSummary, name: []const u8) bool {
    for (symbols) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return true;
    }
    return false;
}

fn findDeclaration(
    decls: []const hello_lib.EmittedDeclarationSummary,
    file_name: []const u8,
) ?[]const u8 {
    for (decls) |decl| {
        if (std.mem.eql(u8, decl.file_name, file_name)) return decl.contents;
    }
    return null;
}

test "zigar wit generated bindings expose zigar:typescript@7.1.0 compiler world" {
    const compiler = hello_lib.native.wit_bindings.compiler;
    try testing.expectEqualStrings("vfs", compiler.Vfs.resource_name);
    try testing.expectEqualStrings("program", compiler.Program.resource_name);
    try testing.expectEqualStrings("checker", compiler.Checker.resource_name);
    try testing.expect(@hasDecl(compiler, "bindHost"));
    try testing.expect(@hasDecl(hello_lib.native.wit_bindings, "bindHost"));
}

test "End-to-end Zig showcase drives TypeScript 7.1 Go WASM Component with zero leaks" {
    // `testing.allocator` is Zig's DebugAllocator/GPA — any leaked Canonical ABI or
    // application allocation fails this test automatically.
    const alloc = testing.allocator;
    const io = testing.io;

    try std.Io.Dir.cwd().access(io, build_options.default_component_path, .{});

    const report = try hello_lib.native.runDemo(
        alloc,
        io,
        build_options.default_component_path,
        build_options.default_node_exe,
    );
    defer report.deinit(alloc);

    // (a) TypeScript 7.1 compilerVersion
    try testing.expect(std.mem.startsWith(u8, report.compiler_version, "7.1."));

    // (b)-(c) Multi-file valid program has 0 syntactic and 0 semantic diagnostics
    try testing.expectEqual(@as(u32, 0), report.syntactic_diagnostic_count);
    try testing.expectEqual(@as(u32, 0), report.semantic_diagnostic_count);

    // (d) Checker inspection (`typeToString` + `resolveModuleExports`)
    try testing.expect(std.mem.indexOf(u8, report.inferred_expression_type, "ReadonlySample<SensorBatch>") != null);
    try testing.expect(std.mem.indexOf(u8, report.inferred_expression_type, "Promise<NumericOutcome<number>>") != null);
    try testing.expect(report.exported_symbols.len >= 3);
    try testing.expect(containsExport(report.exported_symbols, "SensorBatch"));
    try testing.expect(containsExport(report.exported_symbols, "summarizeBatch"));
    try testing.expect(containsExport(report.exported_symbols, "formatOutcome"));

    // (e) Emitted `.d.ts` declarations + transpiled JavaScript
    try testing.expectEqual(@as(usize, 2), report.emitted_declarations.len);
    const math_dts = findDeclaration(report.emitted_declarations, "/app/math.d.ts") orelse return error.TestUnexpectedResult;
    const index_dts = findDeclaration(report.emitted_declarations, "/app/index.d.ts") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, math_dts, "NumericOutcome") != null);
    try testing.expect(std.mem.indexOf(u8, math_dts, "declare function clamp") != null);
    try testing.expect(std.mem.indexOf(u8, index_dts, "declare function summarizeBatch") != null);
    try testing.expect(std.mem.indexOf(u8, index_dts, "Promise<NumericOutcome<number>>") != null);

    try testing.expect(std.mem.indexOf(u8, report.transpiled_js, "summarizeBatch") != null);
    try testing.expect(std.mem.indexOf(u8, report.transpiled_js, "formatOutcome") != null);
    try testing.expect(std.mem.indexOf(u8, report.transpiled_js, "interface SensorBatch") == null);

    // (f) Intentional semantic type error (`TS2322` in `/app/broken.ts`)
    try testing.expectEqual(@as(u32, 1), report.broken_diagnostic_count);
    try testing.expectEqual(@as(u32, 2322), report.broken_diagnostic.code);
    try testing.expectEqualStrings(hello_lib.broken_ts_path, report.broken_diagnostic.file_name);
    try testing.expectEqual(@as(u32, 3), report.broken_diagnostic.line);
    try testing.expectEqual(@as(u32, 14), report.broken_diagnostic.column);
    try testing.expectEqualStrings(
        "Type 'string' is not assignable to type 'number'.",
        report.broken_diagnostic.message,
    );

    // (g) All WIT resources (`broken_program`, `checker`, `program`, `vfs`) dropped cleanly
    try testing.expectEqual(@as(u32, 0), report.live_resources_after_drop);
}
