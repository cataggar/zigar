const std = @import("std");
const testing = std.testing;
const wit_zigar = @import("wit_zigar");
const build_options = @import("build_options");

const loader = wit_zigar.component.loader;
const leb128 = wit_zigar.component.leb128;

fn hasComponentExport(exports: []const wit_zigar.component.types.ExportDecl, target_name: []const u8) bool {
    for (exports) |exp| {
        if (std.mem.eql(u8, exp.name, target_name)) {
            return exp.desc == .instance;
        }
    }
    return false;
}

fn hasImportPrefix(imports: []const wit_zigar.component.types.ImportDecl, prefix: []const u8) bool {
    for (imports) |imp| {
        if (std.mem.startsWith(u8, imp.name, prefix)) return true;
    }
    return false;
}

fn collectCoreExportNames(allocator: std.mem.Allocator, core_wasm: []const u8) ![][]const u8 {
    try testing.expect(core_wasm.len >= 8);
    try testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", core_wasm[0..8]);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);

    var pos: usize = 8;
    while (pos < core_wasm.len) {
        const sec_id = core_wasm[pos];
        pos += 1;
        const size_res = try leb128.readU32Leb128(core_wasm[pos..]);
        pos += size_res.bytes_read;
        const sec_end = pos + size_res.value;
        try testing.expect(sec_end <= core_wasm.len);

        // Core Wasm Export section (id = 7)
        if (sec_id == 7) {
            var p = pos;
            const count_res = try leb128.readU32Leb128(core_wasm[p..sec_end]);
            p += count_res.bytes_read;
            var i: u32 = 0;
            while (i < count_res.value) : (i += 1) {
                const len_res = try leb128.readU32Leb128(core_wasm[p..sec_end]);
                p += len_res.bytes_read;
                const name = core_wasm[p .. p + len_res.value];
                p += len_res.value;
                // exportdesc ::= kind:byte idx:u32
                try testing.expect(p < sec_end);
                p += 1;
                const idx_res = try leb128.readU32Leb128(core_wasm[p..sec_end]);
                p += idx_res.bytes_read;
                try names.append(allocator, name);
            }
        }
        pos = sec_end;
    }
    return names.toOwnedSlice(allocator);
}

fn containsSlice(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "wit-zigar loader validates typescript-compiler.component.wasm structure, core modules, and exports" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const wasm_bytes = cwd.readFileAlloc(
        io,
        build_options.component_wasm_path,
        testing.allocator,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            if (!build_options.require_component) return error.SkipZigTest;
            return err;
        },
        else => return err,
    };
    defer testing.allocator.free(wasm_bytes);

    // 1. Validate Component Model binary preamble (magic="\0asm", version=0x0d, layer=0x01).
    try testing.expect(wasm_bytes.len > 1024 * 1024);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", wasm_bytes[0..8]);

    // 2. Decode the entire component strictly with wit-zigar's component loader.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const comp = try loader.loadStrict(wasm_bytes, arena.allocator());

    // 3. Validate embedded core modules (Go reactor module + WASI P1->P2 adapter/trampoline modules).
    try testing.expect(comp.core_modules.len >= 1);
    const go_core_wasm = comp.core_modules[0].data;
    try testing.expect(go_core_wasm.len > 1024 * 1024);

    const core_exports = try collectCoreExportNames(arena.allocator(), go_core_wasm);
    const expected_core_exports = [_][]const u8{
        "_initialize",
        "cabi_realloc",
        "memory",
        "zigar:typescript/compiler@7.1.0#[constructor]vfs",
        "zigar:typescript/compiler@7.1.0#[method]vfs.write-file",
        "zigar:typescript/compiler@7.1.0#[method]vfs.read-file",
        "zigar:typescript/compiler@7.1.0#[method]vfs.file-exists",
        "zigar:typescript/compiler@7.1.0#[method]vfs.delete-file",
        "zigar:typescript/compiler@7.1.0#[method]vfs.list-files",
        "zigar:typescript/compiler@7.1.0#create-program",
        "zigar:typescript/compiler@7.1.0#[method]program.get-root-files",
        "zigar:typescript/compiler@7.1.0#[method]program.get-syntactic-diagnostics",
        "zigar:typescript/compiler@7.1.0#[method]program.get-semantic-diagnostics",
        "zigar:typescript/compiler@7.1.0#[method]program.get-global-diagnostics",
        "zigar:typescript/compiler@7.1.0#[method]program.emit-declarations",
        "zigar:typescript/compiler@7.1.0#[method]program.get-checker",
        "zigar:typescript/compiler@7.1.0#[method]checker.type-to-string",
        "zigar:typescript/compiler@7.1.0#[method]checker.inspect-type-at",
        "zigar:typescript/compiler@7.1.0#[method]checker.inspect-symbol-at",
        "zigar:typescript/compiler@7.1.0#[method]checker.resolve-module-exports",
        "zigar:typescript/compiler@7.1.0#transpile-module",
        "zigar:typescript/compiler@7.1.0#compiler-version",
        "zigar:typescript/extractor@7.1.0#extract-module-graph",
        "zigar:typescript/compiler@7.1.0#[dtor]vfs",
        "zigar:typescript/compiler@7.1.0#[dtor]program",
        "zigar:typescript/compiler@7.1.0#[dtor]checker",
    };
    for (expected_core_exports) |exp_name| {
        try testing.expect(containsSlice(core_exports, exp_name));
    }

    // 4. Validate component-level Canonical ABI definitions, instances, WASI P2 imports, and WIT interface exports.
    try testing.expect(comp.canons.len > 0);
    try testing.expect(comp.instances.len >= 3);
    try testing.expect(hasImportPrefix(comp.imports, "wasi:io/streams@"));
    try testing.expect(hasImportPrefix(comp.imports, "wasi:cli/environment@"));
    try testing.expect(hasImportPrefix(comp.imports, "wasi:clocks/monotonic-clock@"));

    try testing.expect(hasComponentExport(comp.exports, "zigar:typescript/types@7.1.0"));
    try testing.expect(hasComponentExport(comp.exports, "zigar:typescript/compiler@7.1.0"));
    try testing.expect(hasComponentExport(comp.exports, "zigar:typescript/extractor@7.1.0"));
}
