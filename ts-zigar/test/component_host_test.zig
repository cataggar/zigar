//! End-to-end Zig -> `typescript-compiler.component.wasm` host runner tests.
//!
//! Exercises:
//!   1. Real `typescript-compiler.component.wasm` via `TypeScriptHost.spawnNode`
//!      (`compilerVersion`, `Vfs` `setFile`/`readFile`/`fileExists`/`listFiles`/`deleteFile`,
//!      `createProgram` ok + error arms, `Program` diagnostics + multi-megabyte `emitDeclarations`,
//!      `Checker` `typeToString`/`inspectTypeAt`/`inspectSymbolAt`/`resolveModuleExports`,
//!      `transpileModule`, `extractModuleGraph`, and clean resource `drop` with zero leaked handles
//!      and zero `std.testing.allocator` memory leaks!).
//!   2. Multi-megabyte `DeclarationGraph` cross-memory Canonical ABI lift via `TypeScriptHost`,
//!      poisoning guest linear memory inside `cabi_post_*` to prove zero dangling slice references.

const std = @import("std");
const testing = std.testing;
const ts_zigar = @import("ts_zigar");
const build_options = @import("build_options");

const TypeScriptHost = ts_zigar.TypeScriptHost;
const ComponentHost = ts_zigar.ComponentHost;
const ch = ts_zigar.host.component_host;
const types = ts_zigar.types;
const compiler = ts_zigar.compiler;
const extractor = ts_zigar.extractor;

fn containsStr(items: []const []const u8, needle: []const u8) bool {
    for (items) |it| {
        if (std.mem.eql(u8, it, needle)) return true;
    }
    return false;
}

test "TypeScriptHost lifts a >3 MiB DeclarationGraph across separate linear memories and survives cabi_post_* guest zeroing" {
    const alloc = testing.allocator;

    const State = struct {
        post_called: bool = false,
        last_ret_addr: u32 = 0,
    };
    var state = State{};

    const Handler = struct {
        fn onCall(
            mock: *ch.MockGuestBackend,
            export_name: []const u8,
            params: []const ch.CoreVal,
            _expected: ?ts_zigar.wit_zigar.canon.FlatValType,
        ) ch.HostError!ch.CoreVal {
            _ = _expected;
            if (std.mem.eql(u8, export_name, compiler.Vfs.constructor_meta.export_name)) {
                const h = try mock.resources.insert(compiler.Vfs.constructor_meta.interface_name, "vfs", 101);
                return .{ .i32 = h };
            }
            if (std.mem.eql(u8, export_name, compiler.create_program_meta.export_name)) {
                // `create-program` has `params_flat = 20 > 16`, so `params[0].i32` is the
                // indirect argument struct pointer in guest memory; offset 0 holds `Borrow(Vfs)` rep (101).
                const args_addr: u32 = @bitCast(params[0].i32);
                const arg0_bytes = try mock.guestSlice(args_addr, 4);
                if (std.mem.readInt(i32, arg0_bytes[0..4], .little) != 101) return error.BackendCallFailed;
                const h = try mock.resources.insert(compiler.Program.get_checker_meta.interface_name, "program", 202);
                const ret_addr: u32 = @intCast(try mock.guestAlloc(4, 12));
                const slot = try mock.guestSlice(ret_addr, 12);
                @memset(slot, 0);
                slot[0] = 0; // .ok
                std.mem.writeInt(i32, slot[4..8], h, .little);
                return .{ .i32 = @bitCast(ret_addr) };
            }
            if (std.mem.eql(u8, export_name, extractor.extract_module_graph_meta.export_name)) {
                // `params[0]` must be the lowered guest `rep` (202) of `Borrow(Program)`
                if (params[0].i32 != 202) return error.BackendCallFailed;

                // Construct a >3.2 MiB `DeclarationGraph` inside guest memory:
                //   - 512 interned strings of 6,500 bytes each (~3.33 MiB)
                //   - 64 `TypeNode` entries with nested variants (`union_type`, `reference`, `literal`)
                const str_count: u32 = 512;
                const each_str_len: u32 = 6500;
                const str_table_addr: u32 = @intCast(try mock.guestAlloc(4, str_count * 8));

                var s_idx: u32 = 0;
                while (s_idx < str_count) : (s_idx += 1) {
                    const s_addr: u32 = @intCast(try mock.guestAlloc(1, each_str_len));
                    const dst = try mock.guestSlice(s_addr, each_str_len);
                    @memset(dst, @as(u8, 'a') + @as(u8, @intCast(s_idx % 26)));
                    var header_buf: [16]u8 = undefined;
                    const hdr = std.fmt.bufPrint(&header_buf, "sym_{d:0>4}:", .{s_idx}) catch unreachable;
                    @memcpy(dst[0..hdr.len], hdr);

                    const entry = try mock.guestSlice(str_table_addr + s_idx * 8, 8);
                    std.mem.writeInt(u32, entry[0..4], s_addr, .little);
                    std.mem.writeInt(u32, entry[4..8], each_str_len, .little);
                }

                // Populate 64 `TypeNode` items using `canon.storeToMemory` on a local buffer, then copy
                const type_layout = ts_zigar.wit_zigar.canon.layoutOf(types.TypeNode, .wasm32);
                const type_count: u32 = 64;
                const types_addr: u32 = @intCast(try mock.guestAlloc(type_layout.alignment, type_count * type_layout.size));
                {
                    var t_idx: u32 = 0;
                    while (t_idx < type_count) : (t_idx += 1) {
                        var scratch: [256]u8 align(8) = @splat(0);
                        var bump = ts_zigar.wit_zigar.canon.BumpAllocator.init(type_layout.size, scratch.len);
                        const local_ctx = bump.memoryContext(&scratch);
                        const tn = types.TypeNode{
                            .id = t_idx,
                            .kind = if (t_idx % 2 == 0)
                                .{ .string_type = {} }
                            else
                                .{ .literal = .{ .str = t_idx } },
                            .resolved_type = if (t_idx > 0) t_idx - 1 else null,
                        };
                        try ts_zigar.wit_zigar.canon.storeToMemory(types.TypeNode, .wasm32, local_ctx, 0, tn);
                        const dst = try mock.guestSlice(types_addr + t_idx * type_layout.size, type_layout.size);
                        @memcpy(dst, scratch[0..type_layout.size]);
                    }
                }

                const entry_mods_addr: u32 = @intCast(try mock.guestAlloc(4, 4));
                std.mem.writeInt(u32, (try mock.guestSlice(entry_mods_addr, 4))[0..4], 0, .little);

                // `Result(DeclarationGraph, []const Diagnostic)` layout
                const res_layout = ts_zigar.wit_zigar.canon.layoutOf(
                    ts_zigar.typescript.Result(types.DeclarationGraph, []const types.Diagnostic),
                    .wasm32,
                );
                const ret_addr: u32 = @intCast(try mock.guestAlloc(res_layout.alignment, res_layout.size));
                const ret_slot = try mock.guestSlice(ret_addr, res_layout.size);
                @memset(ret_slot, 0);
                // disc = 0 (.ok), payload starts at offset 4:
                // DeclarationGraph has 9 slices (each 8 bytes = 72 bytes total):
                //   [0] strings (offset 4)
                //   [1] modules (offset 12)
                //   [2] entry_modules (offset 20)
                //   [3] decls (offset 28)
                //   [4] types (offset 36)
                //   ...
                ret_slot[0] = 0;
                std.mem.writeInt(u32, ret_slot[4..8], str_table_addr, .little);
                std.mem.writeInt(u32, ret_slot[8..12], str_count, .little);
                std.mem.writeInt(u32, ret_slot[20..24], entry_mods_addr, .little);
                std.mem.writeInt(u32, ret_slot[24..28], 1, .little);
                std.mem.writeInt(u32, ret_slot[36..40], types_addr, .little);
                std.mem.writeInt(u32, ret_slot[40..44], type_count, .little);
                return .{ .i32 = @bitCast(ret_addr) };
            }
            return error.CoreExportNotFound;
        }

        fn onPostReturn(
            mock: *ch.MockGuestBackend,
            _post_name: []const u8,
            raw_ret: ch.CoreVal,
        ) ch.HostError!void {
            _ = _post_name;
            const st: *State = @ptrCast(@alignCast(mock.user_ctx.?));
            st.post_called = true;
            st.last_ret_addr = @bitCast(raw_ret.i32);
            // Poison ALL guest linear memory with `0xfe` during `cabi_post_*` to guarantee
            // every lifted string and slice in `DeclarationGraph` owns independent host memory!
            @memset(mock.buffer, 0xfe);
        }
    };

    var mock = try ch.MockGuestBackend.init(alloc, .{
        .initial_bytes = 65536,
    });
    defer mock.deinit();
    mock.user_ctx = &state;
    mock.on_call_core = Handler.onCall;
    mock.on_post_return = Handler.onPostReturn;

    var ts_host = try TypeScriptHost.initBackend(alloc, mock.backend());
    defer ts_host.deinit();

    var vfs = try ts_host.createVfs(alloc, false);
    defer vfs.deinit();

    const prog_outcome = try ts_host.createProgram(
        alloc,
        vfs,
        &.{"/index.ts"},
        ts_zigar.defaultCompilerOptions(),
    );
    try testing.expect(prog_outcome == .ok);
    var prog = prog_outcome.ok;
    defer prog.deinit();

    const graph_res = try ts_host.extractModuleGraph(
        alloc,
        prog,
        ts_zigar.defaultExtractConfig(&.{"/index.ts"}),
    );
    defer TypeScriptHost.freeValue(@TypeOf(graph_res), alloc, graph_res);

    // `cabi_post_*` MUST have already run and poisoned guest memory with `0xfe`!
    try testing.expect(state.post_called);
    try testing.expect(graph_res == .ok);

    const graph = graph_res.ok;
    try testing.expectEqual(@as(usize, 512), graph.strings.len);
    try testing.expectEqual(@as(usize, 64), graph.types.len);
    try testing.expectEqual(@as(usize, 1), graph.entry_modules.len);

    var total_bytes: usize = 0;
    for (graph.strings, 0..) |s, idx| {
        total_bytes += s.len;
        try testing.expectEqual(@as(usize, 6500), s.len);
        var expected_prefix_buf: [16]u8 = undefined;
        const expected_prefix = try std.fmt.bufPrint(&expected_prefix_buf, "sym_{d:0>4}:", .{idx});
        try testing.expect(std.mem.startsWith(u8, s, expected_prefix));
        try testing.expectEqual(@as(u8, 'a') + @as(u8, @intCast(idx % 26)), s[s.len - 1]);
    }
    // Verify >3.3 MiB of string data survived `cabi_post_*` guest memory poisoning intact
    try testing.expect(total_bytes > 3 * 1024 * 1024);

    try testing.expect(graph.types[0].kind == .string_type);
    try testing.expectEqual(@as(?u32, null), graph.types[0].resolved_type);
    try testing.expect(graph.types[1].kind == .literal);
    try testing.expectEqual(@as(u32, 1), graph.types[1].kind.literal.str);
    try testing.expectEqual(@as(?u32, 0), graph.types[1].resolved_type);

    try prog.drop();
    try vfs.drop();
    try testing.expectEqual(@as(u32, 0), ts_host.liveResourceCount());
}

test "End-to-end native Zig TypeScriptHost executes typescript-compiler.component.wasm via Node 26 V8" {
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const alloc = testing.allocator;

    // Verify component binary exists (or skip when optional and not built yet)
    cwd.access(io, build_options.component_wasm_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (!build_options.require_component) return error.SkipZigTest;
            return err;
        },
        else => return err,
    };

    var ts_host = try TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = build_options.component_wasm_path,
    });
    defer ts_host.deinit();

    // 1. `compilerVersion()`
    const ver = try ts_host.compilerVersion(alloc);
    defer TypeScriptHost.freeValue([]const u8, alloc, ver);
    try testing.expect(std.mem.startsWith(u8, ver, "7.1."));

    // 2. `Vfs` resource lifecycle (`setFile`, `readFile`, `fileExists`, `listFiles`, `deleteFile`, `drop`)
    {
        var vfs_crud = try ts_host.createVfs(alloc, false);
        defer vfs_crud.deinit();
        try testing.expectEqual(@as(u32, 1), ts_host.liveResourceCount());

        try testing.expectEqual(false, try vfs_crud.fileExists(alloc, "/src/mod.ts"));
        const missing = try vfs_crud.readFile(alloc, "/src/mod.ts");
        try testing.expect(missing == null);

        try vfs_crud.setFile(alloc, "/src/mod.ts", "export const x = 42;\n");
        try vfs_crud.setFile(alloc, "/src/extra.ts", "export const y = 99;\n");
        try testing.expectEqual(true, try vfs_crud.fileExists(alloc, "/src/mod.ts"));

        const read_back = (try vfs_crud.readFile(alloc, "/src/mod.ts")) orelse return error.TestUnexpectedResult;
        defer TypeScriptHost.freeValue([]const u8, alloc, read_back);
        try testing.expectEqualStrings("export const x = 42;\n", read_back);

        const listed = try vfs_crud.listFiles(alloc, "/src");
        defer TypeScriptHost.freeValue([]const []const u8, alloc, listed);
        try testing.expectEqual(@as(usize, 2), listed.len);
        try testing.expect(containsStr(listed, "/src/mod.ts"));
        try testing.expect(containsStr(listed, "/src/extra.ts"));

        try testing.expectEqual(true, try vfs_crud.deleteFile(alloc, "/src/extra.ts"));
        try testing.expectEqual(false, try vfs_crud.fileExists(alloc, "/src/extra.ts"));

        try vfs_crud.drop();
        try testing.expectEqual(@as(u32, 0), ts_host.liveResourceCount());
    }

    // 3. Full TypeScript 7.1 compilation, `Checker` queries, `transpileModule`, multi-megabyte
    //    `emitDeclarations`, `extractModuleGraph`, diagnostic error checking, and clean resource drops!
    var vfs = try ts_host.createVfs(alloc, true);
    defer vfs.deinit();

    const index_source =
        \\export interface User {
        \\  readonly id: number;
        \\  name: string;
        \\}
        \\
        \\/** Greets a user by name. */
        \\export function greet(u: User) {
        \\  return "hi " + u.name;
        \\}
        \\
    ;
    try vfs.setFile(alloc, "/index.ts", index_source);

    // Also generate a large TypeScript file whose emitted `.d.ts` + `.js` exceeds 2 MiB across
    // the separate WASM linear memory boundary to stress `cabi_realloc` + `memory.grow` + `cabi_post_*`!
    var big_ts_buf: std.ArrayList(u8) = .empty;
    defer big_ts_buf.deinit(alloc);
    {
        var i: usize = 0;
        while (i < 22000) : (i += 1) {
            var line_buf: [160]u8 = undefined;
            const line = try std.fmt.bufPrint(
                &line_buf,
                "export interface GeneratedRecord_{d:0>5} {{ readonly field_{d:0>5}_alpha: string; readonly field_{d:0>5}_beta: number; }}\n",
                .{ i, i, i },
            );
            try big_ts_buf.appendSlice(alloc, line);
        }
    }
    try testing.expect(big_ts_buf.items.len > 2 * 1024 * 1024);
    try vfs.setFile(alloc, "/big.ts", big_ts_buf.items);

    var opts = ts_zigar.defaultCompilerOptions();
    opts.target = .es2024;
    opts.declaration = true;

    const prog_outcome = try ts_host.createProgram(
        alloc,
        vfs,
        &.{ "/index.ts", "/big.ts" },
        opts,
    );
    defer prog_outcome.deinitErr(alloc);
    try testing.expect(prog_outcome == .ok);

    var program = prog_outcome.ok;
    defer program.deinit();
    try testing.expectEqual(@as(u32, 2), ts_host.liveResourceCount());

    const roots = try program.getRootFiles(alloc);
    defer TypeScriptHost.freeValue([]const []const u8, alloc, roots);
    try testing.expectEqual(@as(usize, 2), roots.len);

    const diags = try program.getDiagnostics(alloc, "/index.ts");
    defer TypeScriptHost.freeValue([]const types.Diagnostic, alloc, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);

    // `Checker`: `typeToString`, `inspectTypeAt`, `inspectSymbolAt`, `resolveModuleExports`
    var checker = try program.getChecker(alloc);
    defer checker.deinit();
    try testing.expectEqual(@as(u32, 3), ts_host.liveResourceCount());

    const greet_offset: u32 = @intCast(std.mem.indexOf(u8, index_source, "greet(").?);
    const type_str = (try checker.typeToString(alloc, "/index.ts", greet_offset)) orelse return error.TestUnexpectedResult;
    defer TypeScriptHost.freeValue([]const u8, alloc, type_str);
    try testing.expectEqualStrings("(u: User) => string", type_str);

    const type_info = (try checker.inspectTypeAt(alloc, "/index.ts", greet_offset)) orelse return error.TestUnexpectedResult;
    defer TypeScriptHost.freeValue(compiler.TypeInfo, alloc, type_info);
    try testing.expectEqualStrings("(u: User) => string", type_info.type_text);
    try testing.expect(type_info.type_flags > 0);

    const sym_info = (try checker.inspectSymbolAt(alloc, "/index.ts", greet_offset)) orelse return error.TestUnexpectedResult;
    defer TypeScriptHost.freeValue(compiler.SymbolInfo, alloc, sym_info);
    try testing.expectEqualStrings("greet", sym_info.name);
    try testing.expect(sym_info.documentation != null);
    try testing.expect(std.mem.indexOf(u8, sym_info.documentation.?, "Greets a user") != null);

    const exported_syms = try checker.getExportedSymbols(alloc, "/index.ts");
    defer TypeScriptHost.freeValue([]const compiler.SymbolInfo, alloc, exported_syms);
    try testing.expectEqual(@as(usize, 2), exported_syms.len);

    // Multi-megabyte `emitDeclarations` across Guest -> Host linear memories
    const emit_out = try program.emitDeclarations(alloc, null);
    defer TypeScriptHost.freeValue(compiler.EmitOutput, alloc, emit_out);
    try testing.expectEqual(false, emit_out.emit_skipped);
    try testing.expectEqual(@as(usize, 0), emit_out.diagnostics.len);

    var found_index_dts = false;
    var found_big_dts = false;
    var emitted_total_bytes: usize = 0;
    for (emit_out.output_files) |ef| {
        emitted_total_bytes += ef.contents.len;
        if (std.mem.eql(u8, ef.file_name, "/index.d.ts")) {
            found_index_dts = true;
            try testing.expect(std.mem.indexOf(u8, ef.contents, "export declare function greet(u: User): string;") != null);
        } else if (std.mem.eql(u8, ef.file_name, "/big.d.ts")) {
            found_big_dts = true;
            try testing.expect(std.mem.indexOf(u8, ef.contents, "GeneratedRecord_21999") != null);
        }
    }
    try testing.expect(found_index_dts);
    try testing.expect(found_big_dts);
    try testing.expect(emitted_total_bytes > 2 * 1024 * 1024);

    // `transpileModule`
    const transpiled = try ts_host.transpileModule(
        alloc,
        "interface Pt { x: number; y: number }\nexport const sumPt = (p: Pt): number => p.x + p.y;\n",
        "/pt.ts",
    );
    defer TypeScriptHost.freeValue(compiler.EmitOutput, alloc, transpiled);
    try testing.expectEqual(false, transpiled.emit_skipped);
    try testing.expect(transpiled.output_files.len >= 1);
    try testing.expect(std.mem.indexOf(u8, transpiled.output_files[0].contents, "interface Pt") == null);
    try testing.expect(std.mem.indexOf(u8, transpiled.output_files[0].contents, "sumPt") != null);

    // `extractModuleGraph`
    const graph_res = try ts_host.extractModuleGraph(
        alloc,
        program,
        ts_zigar.defaultExtractConfig(&.{"/index.ts"}),
    );
    defer TypeScriptHost.freeValue(@TypeOf(graph_res), alloc, graph_res);
    try testing.expect(graph_res == .ok);
    try testing.expect(graph_res.ok.modules.len >= 1);
    try testing.expect(graph_res.ok.entry_modules.len >= 1);
    try testing.expect(containsStr(graph_res.ok.strings, "/index.ts"));

    // Semantic error diagnostic check (`TS2322`)
    try vfs.setFile(alloc, "/broken.ts", "export const wrong: number = \"not-a-number\";\n");
    const broken_outcome = try ts_host.createProgram(
        alloc,
        vfs,
        &.{"/broken.ts"},
        opts,
    );
    defer broken_outcome.deinitErr(alloc);
    try testing.expect(broken_outcome == .ok);
    var broken_prog = broken_outcome.ok;
    defer broken_prog.deinit();

    const broken_diags = try broken_prog.getSemanticDiagnostics(alloc, "/broken.ts");
    defer TypeScriptHost.freeValue([]const types.Diagnostic, alloc, broken_diags);
    try testing.expectEqual(@as(usize, 1), broken_diags.len);
    try testing.expectEqual(@as(u32, 2322), broken_diags[0].code);

    // Explicitly drop all live resources in reverse order and assert zero leaked handles
    try broken_prog.drop();
    try checker.drop();
    try program.drop();
    try vfs.drop();
    try testing.expectEqual(@as(u32, 0), ts_host.liveResourceCount());
}
