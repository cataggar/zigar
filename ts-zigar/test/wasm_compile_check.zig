//! Cross-target Wasm compilation check (`wasm32-freestanding`, `wasm32-wasi`,
//! and `wasm64-freestanding`) exercising generated `zigar:typescript@7.1.0`
//! WIT types, exported resources, `exportBindings`, `exportZigarBridge`, and
//! `zigar_abi` custom-section metadata.

const std = @import("std");
pub const ts = @import("generated_ts");
const wit_zigar_canon = @import("wit_zigar_canon");

const StubGuestImpl = struct {
    pub const canon = wit_zigar_canon;

    pub fn compiler_version() []const u8 {
        return "7.1.0";
    }

    pub fn transpile_module(_: []const u8, _: []const u8) ts.compiler.EmitOutput {
        return .{
            .output_files = &.{},
            .diagnostics = &.{},
            .emit_skipped = false,
        };
    }

    pub fn create_program(
        fs: ts.Borrow(ts.compiler.Vfs),
        _: []const []const u8,
        _: ts.compiler.CompilerOptions,
    ) ts.Result(ts.compiler.Program, []const ts.types.Diagnostic) {
        return .{ .ok = .{ .handle = fs.borrowRep() } };
    }

    pub fn extract_module_graph(
        prog: ts.Borrow(ts.compiler.Program),
        _: ts.types.ExtractConfig,
    ) ts.Result(ts.types.DeclarationGraph, []const ts.types.Diagnostic) {
        if (prog.borrowRep() < 0) return .{ .err = &.{} };
        return .{ .err = &.{} };
    }

    pub const Vfs = struct {
        pub fn dtor(_: i32) callconv(.c) void {}
        pub fn constructor(use_bundled_libs: bool) ts.Own(ts.compiler.Vfs) {
            return ts.compiler.Vfs.new(if (use_bundled_libs) 1 else 2);
        }
        pub fn write_file(self: ts.Borrow(ts.compiler.Vfs), _: []const u8, _: []const u8) void {
            _ = self.borrowRep();
        }
        pub fn read_file(self: ts.Borrow(ts.compiler.Vfs), _: []const u8) ?[]const u8 {
            return if (self.borrowRep() > 0) "" else null;
        }
        pub fn file_exists(self: ts.Borrow(ts.compiler.Vfs), _: []const u8) bool {
            return self.borrowRep() > 0;
        }
        pub fn delete_file(self: ts.Borrow(ts.compiler.Vfs), _: []const u8) bool {
            return self.borrowRep() > 0;
        }
        pub fn list_files(_: ts.Borrow(ts.compiler.Vfs), _: []const u8) []const []const u8 {
            return &.{};
        }
    };

    pub const Program = struct {
        pub fn dtor(_: i32) callconv(.c) void {}
        pub fn get_root_files(_: ts.Borrow(ts.compiler.Program)) []const []const u8 {
            return &.{};
        }
        pub fn get_syntactic_diagnostics(_: ts.Borrow(ts.compiler.Program), _: ?[]const u8) []const ts.types.Diagnostic {
            return &.{};
        }
        pub fn get_semantic_diagnostics(_: ts.Borrow(ts.compiler.Program), _: ?[]const u8) []const ts.types.Diagnostic {
            return &.{};
        }
        pub fn get_global_diagnostics(_: ts.Borrow(ts.compiler.Program)) []const ts.types.Diagnostic {
            return &.{};
        }
        pub fn emit_declarations(_: ts.Borrow(ts.compiler.Program), _: ?[]const u8) ts.compiler.EmitOutput {
            return .{
                .output_files = &.{},
                .diagnostics = &.{},
                .emit_skipped = true,
            };
        }
        pub fn get_checker(self: ts.Borrow(ts.compiler.Program)) ts.compiler.Checker {
            return .{ .handle = ts.compiler.Checker.new(self.borrowRep()).handle };
        }
    };

    pub const Checker = struct {
        pub fn dtor(_: i32) callconv(.c) void {}
        pub fn type_to_string(_: ts.Borrow(ts.compiler.Checker), _: []const u8, _: u32) ?[]const u8 {
            return null;
        }
        pub fn inspect_type_at(_: ts.Borrow(ts.compiler.Checker), _: []const u8, _: u32) ?ts.compiler.TypeInfo {
            return null;
        }
        pub fn inspect_symbol_at(_: ts.Borrow(ts.compiler.Checker), _: []const u8, _: u32) ?ts.compiler.SymbolInfo {
            return null;
        }
        pub fn resolve_module_exports(_: ts.Borrow(ts.compiler.Checker), _: []const u8) []const ts.compiler.SymbolInfo {
            return &.{};
        }
    };
};

export fn __ts_zigar_wit_compile_check() usize {
    const TypesExports = ts.types.exportBindings(StubGuestImpl);
    TypesExports.registerCoreExports();

    const CompilerExports = ts.compiler.exportBindings(StubGuestImpl);
    CompilerExports.registerCoreExports();

    const ExtractorExports = ts.extractor.exportBindings(StubGuestImpl);
    ExtractorExports.registerCoreExports();

    const WorldBridge = ts.exportZigarBridge(StubGuestImpl, null);
    const meta = ts.zigar_abi.metadata();

    return TypesExports.zigar_abi_entries.len +
        CompilerExports.zigar_abi_entries.len +
        ExtractorExports.zigar_abi_entries.len +
        meta.entries.len +
        @sizeOf(WorldBridge);
}
