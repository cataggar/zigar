//! Cross-target Wasm compilation check (`wasm32-freestanding`, `wasm32-wasi`,
//! and `wasm64-freestanding`) exercising generated `zigar:typescript@7.1.0`
//! WIT types, exported resources, `exportBindings`, `exportZigarBridge`, and
//! `zigar_abi` custom-section metadata.

const std = @import("std");
pub const ts = @import("generated_ts");

const StubGuestImpl = struct {
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
        _: ts.Borrow(ts.compiler.Vfs),
        _: []const []const u8,
        _: ts.compiler.CompilerOptions,
    ) ts.Result(ts.compiler.Program, []const ts.types.Diagnostic) {
        return .{ .ok = .{ .handle = 1 } };
    }

    pub fn extract_module_graph(
        _: ts.Borrow(ts.compiler.Program),
        _: ts.types.ExtractConfig,
    ) ts.Result(ts.types.DeclarationGraph, []const ts.types.Diagnostic) {
        return .{ .err = &.{} };
    }

    pub const Vfs = struct {
        pub fn dtor(_: i32) callconv(.c) void {}
        pub fn constructor(_: i32) callconv(.c) i32 {
            return 1;
        }
    };

    pub const Program = struct {
        pub fn dtor(_: i32) callconv(.c) void {}
        pub fn get_checker(_: i32) callconv(.c) i32 {
            return 2;
        }
    };

    pub const Checker = struct {
        pub fn dtor(_: i32) callconv(.c) void {}
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
